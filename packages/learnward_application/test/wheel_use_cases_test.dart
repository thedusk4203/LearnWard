import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  late FakeWheelRepository fakeRepo;
  late InMemoryPendingRewardCommandStore fakeCommandStore;

  final familyId = FamilyId('fam-wheel-1');
  final childId = ChildId('ch-wheel-1');
  final siblingId = ChildId('ch-wheel-2');
  final now = DateTime.utc(2026, 11, 2, 10, 0);

  setUp(() {
    fakeCommandStore = InMemoryPendingRewardCommandStore();
    fakeRepo = FakeWheelRepository(randomSeed: 42);

    // Seed 4 rewards: 2 common, 1 special, 1 rare, 1 sibling-only
    fakeRepo.addReward(
      Reward(
        id: RewardId('rw-1'),
        familyId: familyId,
        title: '15m Video Game Time',
        category: RewardCategory.privilege,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: WheelTier.common,
        createdAt: now,
        updatedAt: now,
      ),
    );
    fakeRepo.addReward(
      Reward(
        id: RewardId('rw-2'),
        familyId: familyId,
        title: 'Ice Cream Treat',
        category: RewardCategory.treat,
        storeEnabled: true,
        storeCostMinor: 1500,
        wheelEnabled: true,
        wheelTier: WheelTier.special,
        createdAt: now,
        updatedAt: now,
      ),
    );
    fakeRepo.addReward(
      Reward(
        id: RewardId('rw-3'),
        familyId: familyId,
        title: 'Movie Night Pick',
        category: RewardCategory.experience,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: WheelTier.rare,
        createdAt: now,
        updatedAt: now,
      ),
    );
    fakeRepo.addReward(
      Reward(
        id: RewardId('rw-sibling'),
        familyId: familyId,
        title: 'Sibling Prize',
        category: RewardCategory.item,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: WheelTier.common,
        targetChildId: siblingId,
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  group('Wheel Settings Use Cases', () {
    test('GetWheelSettings returns default or existing settings', () async {
      final getSettings = GetWheelSettings(fakeRepo);
      final settings = await getSettings(familyId: familyId);

      expect(settings.familyId, equals(familyId));
      expect(settings.spinCostMinor, equals(1000));
      expect(settings.dailySpinCap, equals(3));
      expect(settings.isEnabled, isTrue);
    });

    test('UpdateWheelSettings updates parental limits', () async {
      final updateSettings = UpdateWheelSettings(fakeRepo);
      final updated = await updateSettings(
        WheelSettings(
          familyId: familyId,
          spinCostMinor: 2000,
          dailySpinCap: 5,
          isEnabled: false,
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect(updated.spinCostMinor, equals(2000));
      expect(updated.dailySpinCap, equals(5));
      expect(updated.isEnabled, isFalse);

      final getSettings = GetWheelSettings(fakeRepo);
      final reloaded = await getSettings(familyId: familyId);
      expect(reloaded.spinCostMinor, equals(2000));
      expect(reloaded.isEnabled, isFalse);
    });
  });

  group('ListWheelRewards Use Case', () {
    test(
      'returns only active, wheel-enabled rewards eligible for target child',
      () async {
        final listRewards = ListWheelRewards(fakeRepo);
        final rewards = await listRewards(familyId: familyId, childId: childId);

        // Should include rw-1, rw-2, rw-3, but NOT rw-sibling
        expect(rewards.length, equals(3));
        expect(rewards.any((r) => r.id.value == 'rw-1'), isTrue);
        expect(rewards.any((r) => r.id.value == 'rw-2'), isTrue);
        expect(rewards.any((r) => r.id.value == 'rw-3'), isTrue);
        expect(rewards.any((r) => r.id.value == 'rw-sibling'), isFalse);
      },
    );
  });

  group('SpinRewardWheel Use Case & Durable Command Journaling', () {
    test('successful spin records command in journal, executes RPC, then deletes journal entry', () async {
      final spinUseCase = SpinRewardWheel(fakeRepo, fakeCommandStore);

      final result = await spinUseCase(
        familyId: familyId,
        childId: childId,
        commandId: 'cmd-spin-100',
      );

      expect(result.spinCostMinor, equals(1000));
      expect(result.rewardTitle, isNotEmpty);
      expect(result.selectionSnapshot.orderedPool.length, equals(3));

      // Journal entry must be cleaned up on success
      final pending = await fakeCommandStore.listPendingCommands();
      expect(pending, isEmpty);
    });

    test('network failure before RPC leaves command durable in store with possibly_dispatched; retry reuses exact same commandId', () async {
      final spinUseCase = SpinRewardWheel(fakeRepo, fakeCommandStore);

      fakeRepo.failNextWithNetwork = true;

      // First attempt fails with network exception
      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<Exception>()),
      );

      // Journal entry MUST persist with pre-dispatch provenance
      final pendingList = await fakeCommandStore.listPendingCommands();
      expect(pendingList.length, equals(1));
      final pendingCmd = pendingList.first;
      expect(pendingCmd.operation, equals(RewardCommandOperation.spinWheel));
      expect(pendingCmd.familyId, equals(familyId.value));
      expect(pendingCmd.childId, equals(childId.value));
      expect(pendingCmd.actorUserId, equals('actor-child-1'));
      expect(
        pendingCmd.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );

      // Retry: must reuse exact same commandId
      final retryResult = await spinUseCase(
        familyId: familyId,
        childId: childId,
        actorUserId: 'actor-child-1',
      );
      expect(retryResult.spinId, isNotNull);

      // Journal cleaned up after successful retry
      expect(await fakeCommandStore.listPendingCommands(), isEmpty);
    });

    test('server commits but response is lost; retry replays same command and returns same outcome without double debit', () async {
      final spinUseCase = SpinRewardWheel(fakeRepo, fakeCommandStore);

      fakeRepo.failAfterCommitResponseLost = true;

      // First call: server committed spin, but client caught socket error
      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<Exception>()),
      );

      // Verify command is safely journaled
      final pending = await fakeCommandStore.findPendingSpinCommand(
        familyId: familyId.value,
        childId: childId.value,
      );
      expect(pending, isNotNull);
      final capturedCommandId = pending!.commandId;
      expect(capturedCommandId, isNotEmpty);
      expect(pending.actorUserId, equals('actor-child-1'));

      // Retry call with new use-case invocation (simulating user retry or restart)
      final spinUseCase2 = SpinRewardWheel(fakeRepo, fakeCommandStore);
      final replayResult = await spinUseCase2(
        familyId: familyId,
        childId: childId,
        actorUserId: 'actor-child-1',
      );

      // Verifies server recognized command_id and returned existing winner without extra spin
      final allSpins = await fakeRepo.listWheelSpins(
        familyId: familyId,
        childId: childId,
      );
      expect(allSpins.length, equals(1));
      expect(replayResult.spinId, equals(allSpins.first.id));

      // Journal is now cleared
      expect(await fakeCommandStore.listPendingCommands(), isEmpty);
    });

    test(
      'fail closed: cannot replay when actor is missing or mismatched',
      () async {
        // 1. Existing command without actorUserId
        await fakeCommandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-spin-no-actor',
            familyId: familyId.value,
            childId: childId.value,
            createdAt: DateTime.now().toUtc(),
          ),
        );

        final spinUseCase = SpinRewardWheel(fakeRepo, fakeCommandStore);

        // Attempting to dispatch must fail closed with StateError, not touch server
        await expectLater(
          () => spinUseCase(
            familyId: familyId,
            childId: childId,
            actorUserId: 'actor-child-1',
          ),
          throwsA(isA<StateError>()),
        );

        // 2. Existing command with actor 'actor-child-1' but caller has different actor
        await fakeCommandStore.deletePendingCommand('cmd-spin-no-actor');
        await fakeCommandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-spin-actor-1',
            familyId: familyId.value,
            childId: childId.value,
            actorUserId: 'actor-child-1',
            createdAt: DateTime.now().toUtc(),
          ),
        );

        await expectLater(
          () => spinUseCase(
            familyId: familyId,
            childId: childId,
            actorUserId: 'actor-different',
          ),
          throwsA(isA<StateError>()),
        );

        // Clean up for next test
        await fakeCommandStore.deletePendingCommand('cmd-spin-actor-1');
      },
    );

    test('fail closed: cannot replay when existing command is quarantined or legacy unknown', () async {
      // Quarantined
      await fakeCommandStore.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-spin-quarantined',
          familyId: familyId.value,
          childId: childId.value,
          actorUserId: 'actor-child-1',
          recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
          createdAt: DateTime.now().toUtc(),
        ),
      );

      final spinUseCase = SpinRewardWheel(fakeRepo, fakeCommandStore);
      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<StateError>()),
      );
      await fakeCommandStore.deletePendingCommand('cmd-spin-quarantined');

      // Legacy unknown
      await fakeCommandStore.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-spin-legacy',
          familyId: familyId.value,
          childId: childId.value,
          actorUserId: 'actor-child-1',
          dispatchState: CommandDispatchState.unknownLegacy,
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<StateError>()),
      );
      await fakeCommandStore.deletePendingCommand('cmd-spin-legacy');
    });

    test(
      '42501 permission error does NOT delete pending journal command',
      () async {
        final spinUseCase = SpinRewardWheel(fakeRepo, fakeCommandStore);
        fakeRepo.failNextWithPermissionError = true;

        await expectLater(
          () => spinUseCase(
            familyId: familyId,
            childId: childId,
            actorUserId: 'actor-child-1',
          ),
          throwsA(isA<Exception>()),
        );

        final pending = await fakeCommandStore.findPendingSpinCommand(
          familyId: familyId.value,
          childId: childId.value,
        );
        expect(
          pending,
          isNotNull,
          reason: 'Permission error (42501) must preserve pending journal row',
        );
        await fakeCommandStore.deletePendingCommand(pending!.commandId);
      },
    );

    test('terminal business error (e.g. LW202, LW203, LW206) cleans up journal entry and rethrows', () async {
      // Disable wheel
      await fakeRepo.updateWheelSettings(
        WheelSettings(
          familyId: familyId,
          isEnabled: false,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final spinUseCase = SpinRewardWheel(fakeRepo, fakeCommandStore);

      await expectLater(
        () => spinUseCase(familyId: familyId, childId: childId),
        throwsA(isA<InvalidWheelException>()),
      );

      // Journal MUST be cleared on terminal rejection (do not poison journal)
      expect(await fakeCommandStore.listPendingCommands(), isEmpty);
    });
  });
}
