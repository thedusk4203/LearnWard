import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  group('File-Backed SQLite Restart Persistence & Network Recovery', () {
    late Directory tempDir;
    late File dbFile;
    late MockServerRewardRepository server;
    late FakeAuthSessionPort defaultAuth;
    late FakeRecoveryAuthorizationPort defaultAuthz;
    late FakeAuthSessionPort parentAuth;
    late FakeRecoveryAuthorizationPort parentAuthz;

    final familyId = FamilyId('fam-restart-1');
    final childId = ChildId('child-restart-1');
    final rewardId = RewardId('rew-restart-1');

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_restart_suite_');
      dbFile = File('${tempDir.path}/commands_restart.sqlite');
      server = MockServerRewardRepository();
      server.childBalances[childId.value] = 5000; // 50.00 RP
      defaultAuth = FakeAuthSessionPort(
        activeUserId: 'usr-child-1',
        role: 'child',
      );
      defaultAuthz = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
      );
      parentAuth = FakeAuthSessionPort(
        activeUserId: 'usr-parent-1',
        role: 'parent',
      );
      parentAuthz = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
        defaultAdultRole: VerifiedAdultRole.parent,
      );
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
      final redeemUseCaseA = RedeemStoreReward(
        server,
        dbA,
        authSessionPort: defaultAuth,
        authorizationPort: defaultAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
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
      final redeemUseCaseB = RedeemStoreReward(
        server,
        dbB,
        authSessionPort: defaultAuth,
        authorizationPort: defaultAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
      final recovered = await redeemUseCaseB(
        commandId: persistedCommandId,
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
      final initialRedeem = RedeemStoreReward(
        server,
        initialDb,
        authSessionPort: defaultAuth,
        authorizationPort: defaultAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
      final redemption = await initialRedeem(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
        actorUserId: 'usr-child-1',
      );
      expect(server.childBalances[childId.value], 3500);
      await initialDb.close();

      // --- Session 1: Parent cancels with response-loss ---
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final cancelUseCaseA = CancelRewardRedemption(
        server,
        dbA,
        authSessionPort: parentAuth,
        authorizationPort: parentAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
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
      final cancelUseCaseB = CancelRewardRedemption(
        server,
        dbB,
        authSessionPort: parentAuth,
        authorizationPort: parentAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
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
      final initialRedeem = RedeemStoreReward(
        server,
        initialDb,
        authSessionPort: defaultAuth,
        authorizationPort: defaultAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
      final redemption = await initialRedeem(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
        actorUserId: 'usr-child-1',
      );
      await initialDb.close();

      // --- Session 1: Parent fulfills with timeout after commit ---
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final fulfillUseCaseA = FulfillRewardRedemption(
        server,
        dbA,
        authSessionPort: parentAuth,
        authorizationPort: parentAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
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
      final fulfillUseCaseB = FulfillRewardRedemption(
        server,
        dbB,
        authSessionPort: parentAuth,
        authorizationPort: parentAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
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

      final redeemUseCaseB = RedeemStoreReward(
        server,
        dbB,
        authSessionPort: defaultAuth,
        authorizationPort: defaultAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
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

    test('Test A: Fresh draft timeout -> legacy saveLocalDraft fails closed (R33-03) -> close SQLite -> reopen on real file-backed SQLite: preserves original content, possibly_dispatched, and exact command IDs', () async {
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final draftId = 'draft-fresh-timeout-001';
      final createCmdId = 'cmd-create-timeout-111';
      final submitCmdId = 'cmd-submit-timeout-222';
      final evidenceId = 'evi-timeout-333';

      // 1. Fresh draft attempted to submit: marked possibly_dispatched before network RPC
      final inFlightDraft = LocalAssessmentDraft(
        localDraftId: draftId,
        familyId: familyId.value,
        childId: childId.value,
        createCommandId: createCmdId,
        submitCommandId: submitCmdId,
        evidenceId: evidenceId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Quiz 1',
        assessmentType: 'quiz',
        difficulty: 'normal',
        rawScore: 9.0,
        maxScore: 10.0,
        occurredAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        submissionStatus: DraftSubmissionStatus.submittingAssessment,
        dispatchState: CommandDispatchState.possiblyDispatched,
        actorUserId: 'usr-child-1',
        actorRole: 'child',
      );
      await dbA.saveLocalDraft(inFlightDraft);

      // 2. Network drop occurs. Stale legacy saveLocalDraft attempt while still on screen must fail closed.
      final persistedBeforeSave = await dbA.getLocalDraft(draftId);
      expect(persistedBeforeSave, isNotNull);
      expect(
        persistedBeforeSave!.dispatchState,
        CommandDispatchState.possiblyDispatched,
      );

      final editedDraft = persistedBeforeSave.copyWith(
        title: 'Quiz 1 (Edited After Timeout)',
        rawScore: 9.5,
        updatedAt: DateTime.now().toUtc(),
      );
      await expectLater(
        () => dbA.saveLocalDraft(editedDraft),
        throwsA(isA<DraftWriteConflictException>()),
      );

      // 3. Close SQLite database (simulating process termination / crash)
      await dbA.close();

      // 4. Reopen on real file-backed SQLite
      final dbB = AppDatabase(NativeDatabase(dbFile));
      final recoveredDraft = await dbB.getLocalDraft(draftId);

      expect(recoveredDraft, isNotNull);
      expect(recoveredDraft!.localDraftId, equals(draftId));
      expect(recoveredDraft.createCommandId, equals(createCmdId));
      expect(recoveredDraft.submitCommandId, equals(submitCmdId));
      expect(recoveredDraft.evidenceId, equals(evidenceId));
      expect(
        recoveredDraft.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
        reason: 'possibly_dispatched must NEVER roll back to never_dispatched',
      );
      expect(
        recoveredDraft.submissionStatus,
        equals(DraftSubmissionStatus.submittingAssessment),
      );
      expect(recoveredDraft.title, equals('Quiz 1'));
      expect(recoveredDraft.rawScore, equals(9.0));
      expect(recoveredDraft.actorUserId, equals('usr-child-1'));

      await dbB.close();
    });

    test('Test B: Existing unknown_legacy draft rejects legacy saveLocalDraft and remains quarantined after reopen', () async {
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final legacyDraftId = 'draft-legacy-quarantine-002';

      // 1. Seed quarantined legacy draft (Drift v4 uninstrumented migration)
      final legacyDraft = LocalAssessmentDraft(
        localDraftId: legacyDraftId,
        familyId: familyId.value,
        childId: childId.value,
        createCommandId: null,
        submitCommandId: null,
        subjectKey: SubjectKey.english,
        subject: 'English',
        title: 'Legacy Essay',
        assessmentType: 'project',
        difficulty: 'normal',
        rawScore: 8.0,
        maxScore: 10.0,
        occurredAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        submissionStatus: DraftSubmissionStatus.draft,
        dispatchState: CommandDispatchState.unknownLegacy,
        actorUserId: 'usr-legacy-actor',
      );
      await dbA.saveLocalDraft(legacyDraft);

      // 2. Legacy saveLocalDraft must fail closed on unknown_legacy draft
      final loaded = await dbA.getLocalDraft(legacyDraftId);
      expect(loaded, isNotNull);
      expect(loaded!.isLegacyUnknown, isTrue);

      final editedLegacy = loaded.copyWith(
        title: 'Legacy Essay (Edited Locally)',
        rawScore: 8.5,
        updatedAt: DateTime.now().toUtc(),
      );
      await expectLater(
        () => dbA.saveLocalDraft(editedLegacy),
        throwsA(isA<DraftWriteConflictException>()),
      );

      // 3. Close and reopen to ensure disk integrity
      await dbA.close();

      final dbB = AppDatabase(NativeDatabase(dbFile));
      final recovered = await dbB.getLocalDraft(legacyDraftId);

      expect(recovered, isNotNull);
      expect(recovered!.isLegacyUnknown, isTrue);
      expect(
        recovered.dispatchState,
        equals(CommandDispatchState.unknownLegacy),
        reason: 'Local editing must never promote unknown_legacy draft',
      );
      expect(
        recovered.canAutoSubmit,
        isFalse,
        reason: 'Quarantined draft must remain ineligible for auto submission',
      );
      expect(recovered.title, equals('Legacy Essay'));
      expect(recovered.rawScore, equals(8.0));

      await dbB.close();
    });
  });
}
