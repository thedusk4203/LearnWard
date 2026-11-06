import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  group('File-Backed SQLite Restart Persistence & Network Recovery', () {
    late Directory tempDir;
    late File dbFile;
    late MockServerRewardRepository server;

    final familyId = FamilyId('fam-restart-1');
    final childId = ChildId('child-restart-1');
    final rewardId = RewardId('rew-restart-1');

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_restart_suite_');
      dbFile = File('${tempDir.path}/commands_restart.sqlite');
      server = MockServerRewardRepository();
      server.childBalances[childId.value] = 5000; // 50.00 RP
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('Redeem: persists command to disk, survives AppDatabase restart, retries safely with exactly 1 debit and clears disk journal', () async {
      // --- Process / Session 1: Initial Attempt with response-loss ---
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final redeemUseCaseA = RedeemStoreReward(server, dbA);
      server.simulateLossOnNextCommit = true;

      await expectLater(
        redeemUseCaseA(
          familyId: familyId,
          rewardId: rewardId,
          childId: childId,
          actorUserId: 'usr-child-1',
        ),
        throwsA(isA<SocketException>()),
      );

      // Server committed 1 debit before response was lost
      expect(server.debitCount, 1);
      expect(server.childBalances[childId.value], 3500);

      // Close dbA to simulate process termination / app kill
      await dbA.close();

      // --- Process / Session 2: Fresh App Launch Reopening SQLite File ---
      final dbB = AppDatabase(NativeDatabase(dbFile));

      // Verify exact pending command payload survived the database reopen
      final pendingOnDisk = await dbB.findPendingRedeemCommand(
        familyId: familyId.value,
        childId: childId.value,
        rewardId: rewardId.value,
      );
      expect(
        pendingOnDisk,
        isNotNull,
        reason: 'Command must persist across database reopen',
      );
      expect(pendingOnDisk!.operation, RewardCommandOperation.redeemReward);
      expect(pendingOnDisk.familyId, familyId.value);
      expect(pendingOnDisk.childId, childId.value);
      expect(pendingOnDisk.rewardId, rewardId.value);
      final persistedCommandId = pendingOnDisk.commandId;
      expect(persistedCommandId, isNotEmpty);

      // Verify dispatchState is possiblyDispatched
      expect(
        pendingOnDisk.dispatchState,
        CommandDispatchState.possiblyDispatched,
      );
      expect(pendingOnDisk.actorUserId, 'usr-child-1');

      // Retry redemption with dbB on fresh app session
      final redeemUseCaseB = RedeemStoreReward(server, dbB);
      final recovered = await redeemUseCaseB(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
        actorUserId: 'usr-child-1',
      );

      // Assert exactly 1 server debit occurred (server deduplicated via cached receipt)
      expect(
        server.debitCount,
        1,
        reason: 'Retry must not trigger a second debit',
      );
      expect(server.childBalances[childId.value], 3500);
      expect(recovered.rpCostMinor, 1500);
      expect(server.commandReceipts[persistedCommandId], recovered.id.value);

      // Verify journal row is deleted from disk after confirmed outcome
      final remainingOnDisk = await dbB.listPendingCommands();
      expect(remainingOnDisk, isEmpty);

      // Verify subsequent user action generates a fresh command and performs 2nd debit
      final subsequent = await redeemUseCaseB(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
        actorUserId: 'usr-child-1',
      );
      expect(
        server.debitCount,
        2,
        reason: 'Subsequent new claim executes second debit',
      );
      expect(server.childBalances[childId.value], 2000);
      expect(subsequent.id, isNot(recovered.id));

      await dbB.close();
    });

    test('Cancel: persists original cancellation reason to disk, survives restart, retries safely with exactly 1 refund and preserves reason', () async {
      // Initial setup: create an existing redemption on the server
      final initialDb = AppDatabase(NativeDatabase(dbFile));
      final initialRedeem = RedeemStoreReward(server, initialDb);
      final redemption = await initialRedeem(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
      );
      expect(server.childBalances[childId.value], 3500);
      await initialDb.close();

      // --- Session 1: Parent cancels with response-loss ---
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final cancelUseCaseA = CancelRewardRedemption(server, dbA);
      server.simulateLossOnNextCommit = true;

      await expectLater(
        cancelUseCaseA(
          familyId: familyId,
          redemptionId: redemption.id,
          cancellationReason: 'Event rained out on Saturday',
        ),
        throwsA(isA<SocketException>()),
      );

      // Server committed refund before loss
      expect(server.refundCount, 1);
      expect(server.childBalances[childId.value], 5000);

      // Close dbA to simulate process crash
      await dbA.close();

      // --- Session 2: Reopen SQLite file in new instance ---
      final dbB = AppDatabase(NativeDatabase(dbFile));

      // Verify pending cancel command and ORIGINAL cancellation reason survived on disk
      final pendingCancel = await dbB.findPendingRedemptionCommand(
        operation: RewardCommandOperation.cancelReward,
        redemptionId: redemption.id.value,
      );
      expect(pendingCancel, isNotNull);
      expect(
        pendingCancel!.cancellationReason,
        'Event rained out on Saturday',
        reason: 'Original cancellation reason must survive database restart',
      );
      expect(pendingCancel.familyId, familyId.value);
      final cancelCommandId = pendingCancel.commandId;

      // Parent retries cancellation (even if retry UI supplies different reason)
      final cancelUseCaseB = CancelRewardRedemption(server, dbB);
      final recovered = await cancelUseCaseB(
        familyId: familyId,
        redemptionId: redemption.id,
        cancellationReason: 'Ignored alternate reason text',
      );

      // Verify exactly 1 refund (NO double refund) and original reason preserved
      expect(server.refundCount, 1);
      expect(server.childBalances[childId.value], 5000);
      expect(recovered.status, RewardRedemptionStatus.cancelled);
      expect(
        recovered.cancellationReason,
        'Event rained out on Saturday',
        reason: 'Must preserve original reason from persisted journal',
      );
      expect(server.commandReceipts[cancelCommandId], redemption.id.value);

      // Disk journal cleared on success
      expect(await dbB.listPendingCommands(), isEmpty);

      await dbB.close();
    });

    test('Fulfill: persists command to disk, survives restart, retries safely without duplicate fulfillment and clears disk journal', () async {
      // Initial setup: create redemption
      final initialDb = AppDatabase(NativeDatabase(dbFile));
      final initialRedeem = RedeemStoreReward(server, initialDb);
      final redemption = await initialRedeem(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
      );
      await initialDb.close();

      // --- Session 1: Parent fulfills with timeout after commit ---
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final fulfillUseCaseA = FulfillRewardRedemption(server, dbA);
      server.simulateLossOnNextCommit = true;

      await expectLater(
        fulfillUseCaseA(familyId: familyId, redemptionId: redemption.id),
        throwsA(isA<TimeoutException>()),
      );

      // Server committed fulfillment
      expect(
        server.redemptions[redemption.id.value]!.status,
        RewardRedemptionStatus.fulfilled,
      );

      // Close dbA (simulate process exit)
      await dbA.close();

      // --- Session 2: Reopen SQLite file in new instance ---
      final dbB = AppDatabase(NativeDatabase(dbFile));

      // Verify pending fulfill command survived on disk
      final pendingFulfill = await dbB.findPendingRedemptionCommand(
        operation: RewardCommandOperation.fulfillReward,
        redemptionId: redemption.id.value,
      );
      expect(pendingFulfill, isNotNull);
      expect(pendingFulfill!.familyId, familyId.value);
      expect(pendingFulfill.redemptionId, redemption.id.value);
      final fulfillCommandId = pendingFulfill.commandId;

      // Retry fulfillment
      final fulfillUseCaseB = FulfillRewardRedemption(server, dbB);
      final recovered = await fulfillUseCaseB(
        familyId: familyId,
        redemptionId: redemption.id,
      );

      expect(recovered.status, RewardRedemptionStatus.fulfilled);
      expect(server.commandReceipts[fulfillCommandId], redemption.id.value);

      // Journal cleared on success
      expect(await dbB.listPendingCommands(), isEmpty);

      await dbB.close();
    });

    test('Terminal errors after restart immediately delete row from SQLite file and rethrow', () async {
      // Persist a pending command on dbA
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final command = PendingRewardCommand(
        operation: RewardCommandOperation.redeemReward,
        commandId: 'cmd-term-001',
        familyId: familyId.value,
        childId: childId.value,
        rewardId: rewardId.value,
        actorUserId: 'usr-child-1',
        createdAt: DateTime.now().toUtc(),
      );
      await dbA.savePendingCommand(command);
      await dbA.close();

      // Reopen in dbB
      final dbB = AppDatabase(NativeDatabase(dbFile));
      expect(await dbB.getPendingCommand('cmd-term-001'), isNotNull);

      // Balance drops to 0, causing LW201 terminal error on retry
      server.childBalances[childId.value] = 0;

      final redeemUseCaseB = RedeemStoreReward(server, dbB);
      await expectLater(
        redeemUseCaseB(
          commandId: 'cmd-term-001',
          familyId: familyId,
          rewardId: rewardId,
          childId: childId,
          actorUserId: 'usr-child-1',
        ),
        throwsA(isA<InvalidRewardException>()),
      );

      // Must be deleted from SQLite file on terminal business error
      expect(await dbB.getPendingCommand('cmd-term-001'), isNull);
      expect(await dbB.listPendingCommands(), isEmpty);

      await dbB.close();
    });
  });
}
