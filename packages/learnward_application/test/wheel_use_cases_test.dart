import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  late FakeWheelRepository fakeRepo;
  late InMemoryPendingRewardCommandStore fakeCommandStore;
  late FakeAuthSessionPort fakeAuth;
  late FakeRecoveryAuthorizationPort fakeAuthz;

  final familyId = FamilyId('fam-wheel-1');
  final childId = ChildId('ch-wheel-1');
  final siblingId = ChildId('ch-wheel-2');
  final now = DateTime.utc(2026, 11, 2, 10, 0);

  SpinRewardWheel createSpinUseCase({
    AuthSessionPort? authPort,
    RecoveryAuthorizationPort? authzPort,
  }) {
    return SpinRewardWheel(
      fakeRepo,
      fakeCommandStore,
      authSessionPort: authPort ?? fakeAuth,
      authorizationPort: authzPort ?? fakeAuthz,
      jitterSource: const DeterministicJitterSource(0.0),
    );
  }

  setUp(() {
    fakeCommandStore = InMemoryPendingRewardCommandStore();
    fakeRepo = FakeWheelRepository(randomSeed: 42);
    fakeAuth = FakeAuthSessionPort(activeUserId: 'actor-child-1');
    fakeAuthz = FakeRecoveryAuthorizationPort();

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
        title: 'Book of Choice',
        category: RewardCategory.privilege,
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
        targetChildId: siblingId, // Only sibling can spin/see this
        title: 'Sibling Only Reward',
        category: RewardCategory.privilege,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: WheelTier.common,
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  group('GetWheelSettings & GetEligibleWheelRewards Queries', () {
    test('returns default wheel settings when none are configured', () async {
      final getSettings = GetWheelSettings(fakeRepo);
      final settings = await getSettings(familyId: familyId);

      expect(settings.familyId, equals(familyId));
      expect(settings.spinCostMinor, equals(1000));
      expect(settings.dailySpinCap, equals(3));
      expect(settings.isEnabled, isTrue);
    });

    test('returns configured wheel settings when present', () async {
      final custom = WheelSettings(
        familyId: familyId,
        spinCostMinor: 500,
        dailySpinCap: 5,
        isEnabled: true,
        createdAt: now,
        updatedAt: now,
      );
      fakeRepo.setSettings(familyId.value, custom);

      final getSettings = GetWheelSettings(fakeRepo);
      final settings = await getSettings(familyId: familyId);

      expect(settings.spinCostMinor, equals(500));
      expect(settings.dailySpinCap, equals(5));
      expect(settings.isEnabled, isTrue);
    });

    test(
      'returns only eligible rewards matching childId or all-child pool',
      () async {
        final getRewards = ListWheelRewards(fakeRepo);
        final rewards = await getRewards(familyId: familyId, childId: childId);

        expect(rewards.length, equals(3));
        expect(rewards.any((r) => r.id.value == 'rw-1'), isTrue);
        expect(rewards.any((r) => r.id.value == 'rw-2'), isTrue);
        expect(rewards.any((r) => r.id.value == 'rw-3'), isTrue);
        expect(rewards.any((r) => r.id.value == 'rw-sibling'), isFalse);
      },
    );
  });

  group('SpinRewardWheel Use Case & Durable Command Journaling', () {
    test('H02: constructor fails closed with ArgumentError without trusted coordinator or ports', () {
      expect(
        () => SpinRewardWheel(fakeRepo, fakeCommandStore),
        throwsArgumentError,
      );
    });

    test('successful spin records command in journal, executes RPC, then deletes journal entry', () async {
      final spinUseCase = createSpinUseCase();

      final result = await spinUseCase(
        familyId: familyId,
        childId: childId,
        actorUserId: 'actor-child-1',
      );

      expect(result.spinCostMinor, equals(1000));
      expect(result.rewardTitle, isNotEmpty);
      expect(result.selectionSnapshot.orderedPool.length, equals(3));

      // Journal entry must be cleaned up on success
      final pending = await fakeCommandStore.listPendingCommands();
      expect(pending, isEmpty);
    });

    test('network failure before RPC leaves command durable in store with possibly_dispatched; retry reuses exact same commandId', () async {
      final spinUseCase = createSpinUseCase();
      fakeRepo.failNextWithNetwork = true;

      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<Exception>()),
      );

      // Verify command is in pending store with possibly_dispatched
      final pendingList = await fakeCommandStore.listPendingCommands();
      expect(pendingList, isNotEmpty);
      final commandId = pendingList.first.commandId;
      final pending = await fakeCommandStore.getPendingCommand(commandId);
      expect(pending, isNotNull);
      expect(pending!.commandId, equals(commandId));
      expect(
        pending.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );
      expect(pending.operation, equals(RewardCommandOperation.spinWheel));

      // Retry exact same command ID with network restored
      fakeRepo.failNextWithNetwork = false;
      final retryResult = await spinUseCase(
        familyId: familyId,
        childId: childId,
        commandId: commandId,
        actorUserId: 'actor-child-1',
      );

      expect(retryResult.rewardTitle, isNotEmpty);

      // Store is now cleaned up
      expect(await fakeCommandStore.getPendingCommand(commandId), isNull);
    });

    test('commit-response-loss: server executes spin, receipt drops; retry returns exact same result with zero double-debit', () async {
      final spinUseCase = createSpinUseCase();
      fakeRepo.failAfterCommitResponseLost = true;

      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<Exception>()),
      );

      // Command remains pending locally with possibly_dispatched
      final pendingList = await fakeCommandStore.listPendingCommands();
      expect(pendingList, isNotEmpty);
      final commandId = pendingList.first.commandId;
      final pending = await fakeCommandStore.getPendingCommand(commandId);
      expect(pending, isNotNull);
      expect(
        pending!.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );

      // Exactly 1 server spin occurred despite client failure
      expect(fakeRepo.spinCallCount, equals(1));
      final originalReceipt = fakeRepo.lastCommittedResult!;

      // Retry: server recognizes idempotency key, returns cached receipt, increments nothing
      final spinUseCase2 = createSpinUseCase();
      final replayResult = await spinUseCase2(
        familyId: familyId,
        childId: childId,
        commandId: commandId,
        actorUserId: 'actor-child-1',
      );

      expect(fakeRepo.spinCallCount, equals(1)); // NO double execution!
      expect(replayResult.spinId, equals(originalReceipt.spinId));
      expect(replayResult.rewardId, equals(originalReceipt.rewardId));
      expect(replayResult.rewardTitle, equals(originalReceipt.rewardTitle));

      // Journal entry cleaned up after replay confirms success
      expect(await fakeCommandStore.getPendingCommand(commandId), isNull);
    });

    test('different actor cannot auto-replay pending spin; fails closed until original actor returns', () async {
      // 1. Child-1 attempts spin and loses connection
      final spinUseCaseChild1 = createSpinUseCase(
        authPort: FakeAuthSessionPort(activeUserId: 'actor-child-1'),
      );
      fakeRepo.failNextWithNetwork = true;

      await expectLater(
        () => spinUseCaseChild1(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<Exception>()),
      );

      final pendingList = await fakeCommandStore.listPendingCommands();
      expect(pendingList, isNotEmpty);
      final commandId = pendingList.first.commandId;

      // 2. Sibling signs in and attempts to spin
      final spinUseCaseChild2 = createSpinUseCase(
        authPort: FakeAuthSessionPort(activeUserId: 'actor-child-2'),
      );

      // Attempting to dispatch must fail closed with StateError, not touch server
      fakeRepo.failNextWithNetwork = false;
      await expectLater(
        () => spinUseCaseChild2(
          familyId: familyId,
          childId: childId,
          commandId: commandId,
          actorUserId: 'actor-child-2',
        ),
        throwsA(isA<StateError>()),
      );

      // Verify command remains bound to actor-child-1
      final stored = await fakeCommandStore.getPendingCommand(commandId);
      expect(stored, isNotNull);
      expect(stored!.actorUserId, equals('actor-child-1'));

      // 3. Original actor returns and replays
      final replayResult = await spinUseCaseChild1(
        familyId: familyId,
        childId: childId,
        commandId: commandId,
        actorUserId: 'actor-child-1',
      );

      expect(replayResult.rewardTitle, isNotEmpty);
      expect(await fakeCommandStore.getPendingCommand(commandId), isNull);
    });

    test('fail closed: cannot replay when existing command is quarantined or legacy unknown', () async {
      await fakeCommandStore.savePendingCommand(
        PendingRewardCommand(
          commandId: 'cmd-quarantine',
          operation: RewardCommandOperation.spinWheel,
          familyId: familyId.value,
          childId: childId.value,
          createdAt: now,
          actorUserId: 'actor-child-1',
          dispatchState: CommandDispatchState.unknownLegacy,
          recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
        ),
      );

      final spinUseCase = createSpinUseCase();
      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          commandId: 'cmd-quarantine',
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      '42501 permission error does NOT delete pending journal command',
      () async {
        final spinUseCase = createSpinUseCase();
        fakeRepo.failNextWithPermissionError = true;

        await expectLater(
          () => spinUseCase(
            familyId: familyId,
            childId: childId,
            actorUserId: 'actor-child-1',
          ),
          throwsA(isA<Exception>()),
        );

        // Stored command MUST be preserved (transitions to quarantinedUnknownOutcome, never deleted)
        final stored = await fakeCommandStore.findPendingSpinCommand(
          familyId: familyId.value,
          childId: childId.value,
          recoveryState: null,
        );
        expect(stored, isNotNull);
        expect(stored!.commandId, isNotEmpty);
        expect(
          stored.recoveryState,
          equals(CommandRecoveryState.quarantinedUnknownOutcome),
        );
      },
    );

    test('terminal business error (e.g. LW202, LW203, LW206) cleans up journal entry and rethrows', () async {
      fakeRepo.failWithInvalidWheel = true;
      final spinUseCase = createSpinUseCase();

      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<InvalidWheelException>()),
      );

      // Journal MUST be cleared on terminal rejection (do not poison journal)
      expect(await fakeCommandStore.listPendingCommands(), isEmpty);
    });

    test('Test C: missing or unauthenticated session during new spin fails closed, zero server calls, zero journal entries', () async {
      fakeRepo.spinCallCount = 0;
      fakeAuth.invalidateSession(); // Unauthenticated session
      final spinUseCase = createSpinUseCase();

      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        fakeRepo.spinCallCount,
        equals(0),
        reason: 'Zero server calls on missing session',
      );
      expect(
        await fakeCommandStore.listPendingCommands(),
        isEmpty,
        reason: 'Zero journal entries on missing session',
      );
    });

    test('Test E: valid authenticated actor creates one new command with possibly_dispatched persisted before RPC', () async {
      fakeAuth.setSession(userId: 'actor-valid-child-1');
      final spinUseCase = createSpinUseCase();
      fakeRepo.failNextWithNetwork = true;

      await expectLater(
        () => spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-valid-child-1',
          actorRole: 'child',
        ),
        throwsA(isA<Exception>()),
      );

      final pendingList = await fakeCommandStore.listPendingCommands();
      expect(pendingList.length, equals(1));
      final pending = pendingList.first;
      expect(pending.actorUserId, equals('actor-valid-child-1'));
      expect(
        pending.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );
      expect(pending.commandId, isNotEmpty);
    });
  });
}
