import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  group('AppDatabase PendingRewardCommandStore', () {
    final now = DateTime.utc(2026, 11, 1, 12, 0, 0);

    test('saves, retrieves, and deletes a pending redeem command', () async {
      final command = PendingRewardCommand(
        operation: RewardCommandOperation.redeemReward,
        commandId: 'cmd-redeem-001',
        familyId: 'fam-1',
        childId: 'child-1',
        rewardId: 'rew-1',
        createdAt: now,
      );

      await database.savePendingCommand(command);

      final retrieved = await database.getPendingCommand('cmd-redeem-001');
      expect(retrieved, isNotNull);
      expect(retrieved!.operation, RewardCommandOperation.redeemReward);
      expect(retrieved.commandId, 'cmd-redeem-001');
      expect(retrieved.familyId, 'fam-1');
      expect(retrieved.childId, 'child-1');
      expect(retrieved.rewardId, 'rew-1');

      // Find by composite keys
      final byKeys = await database.findPendingRedeemCommand(
        familyId: 'fam-1',
        childId: 'child-1',
        rewardId: 'rew-1',
      );
      expect(byKeys, isNotNull);
      expect(byKeys!.commandId, 'cmd-redeem-001');

      // Delete upon completion
      await database.deletePendingCommand('cmd-redeem-001');
      expect(await database.getPendingCommand('cmd-redeem-001'), isNull);
      expect(
        await database.findPendingRedeemCommand(
          familyId: 'fam-1',
          childId: 'child-1',
          rewardId: 'rew-1',
        ),
        isNull,
      );
    });

    test(
      'saves and finds pending fulfill and cancel commands by redemptionId',
      () async {
        final fulfillCmd = PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'cmd-fulfill-001',
          familyId: 'fam-1',
          redemptionId: 'red-001',
          createdAt: now,
        );
        final cancelCmd = PendingRewardCommand(
          operation: RewardCommandOperation.cancelReward,
          commandId: 'cmd-cancel-002',
          familyId: 'fam-1',
          redemptionId: 'red-002',
          cancellationReason: 'Activity unavailable',
          createdAt: now.add(const Duration(seconds: 10)),
        );

        await database.savePendingCommand(fulfillCmd);
        await database.savePendingCommand(cancelCmd);

        final foundFulfill = await database.findPendingRedemptionCommand(
          operation: RewardCommandOperation.fulfillReward,
          redemptionId: 'red-001',
        );
        expect(foundFulfill, isNotNull);
        expect(foundFulfill!.commandId, 'cmd-fulfill-001');

        final foundCancel = await database.findPendingRedemptionCommand(
          operation: RewardCommandOperation.cancelReward,
          redemptionId: 'red-002',
        );
        expect(foundCancel, isNotNull);
        expect(foundCancel!.commandId, 'cmd-cancel-002');
        expect(foundCancel.cancellationReason, 'Activity unavailable');

        // Listing filtered by family
        final allFam1 = await database.listPendingCommands(familyId: 'fam-1');
        expect(allFam1.length, 2);
      },
    );

    test(
      'replaces pending command on duplicate commandId without duplicate rows',
      () async {
        final cmd1 = PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-same-id',
          familyId: 'fam-1',
          childId: 'child-1',
          rewardId: 'rew-1',
          createdAt: now,
        );
        final cmd2 = PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-same-id',
          familyId: 'fam-1',
          childId: 'child-1',
          rewardId: 'rew-1',
          createdAt: now.add(const Duration(minutes: 5)),
        );

        await database.savePendingCommand(cmd1);
        await database.savePendingCommand(cmd2);

        final all = await database.listPendingCommands();
        expect(all.length, 1);
        expect(all.first.commandId, 'cmd-same-id');
      },
    );
  });
}
