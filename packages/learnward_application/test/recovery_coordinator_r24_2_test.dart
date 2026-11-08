import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

final class _TestClock implements Clock {
  const _TestClock(this.nowUtc);
  final DateTime nowUtc;

  @override
  DateTime now() => nowUtc;
}

void main() {
  final t0 = DateTime.utc(2026, 11, 8, 12);
  final clock = _TestClock(t0);

  List<Reward> buildSampleRewards(FamilyId familyId, ChildId childId) {
    return [
      Reward(
        id: RewardId('rew-1'),
        familyId: familyId,
        title: '30 min Screen Time',
        category: RewardCategory.privilege,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: WheelTier.common,
        iconKey: 'screen_time',
        createdAt: t0,
        updatedAt: t0,
      ),
      Reward(
        id: RewardId('rew-2'),
        familyId: familyId,
        title: 'Choose Dinner',
        category: RewardCategory.privilege,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: WheelTier.special,
        iconKey: 'dinner',
        createdAt: t0,
        updatedAt: t0,
      ),
      Reward(
        id: RewardId('rew-3'),
        familyId: familyId,
        title: 'New Book',
        category: RewardCategory.privilege,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: WheelTier.rare,
        iconKey: 'book',
        createdAt: t0,
        updatedAt: t0,
      ),
    ];
  }

  group('RecoveryCoordinator R24-2 Findings Verification', () {
    test('R24-2-05: preflight denial with CAS failure reports in-flight and keeps journal intact', () async {
      final store = InMemoryPendingRewardCommandStore();
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-1',
        sessionGeneration: 'gen-1',
      );

      // Pre-insert an active command that is already leased by another worker
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-r24-cas',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'actor-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await store.savePendingCommand(cmd, now: t0);

      // Another worker acquires the lease
      final rivalLease = await store.acquireClaim(
        commandId: 'cmd-r24-cas',
        actorUserId: 'actor-1',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(rivalLease, isNotNull);

      // Target authorization port denies authorization
      final denyingAuthz = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.definitelyDenied,
      );

      final coordinator = RecoveryCoordinator(
        commandStore: store,
        authSessionPort: authPort,
        authorizationPort: denyingAuthz,
        clock: clock,
      );

      // Preflight denial occurs, but acquireClaim fails because lease is active with another worker
      final result = await coordinator.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: 'fam-1',
        childId: 'child-1',
        requestedCommandId: 'cmd-r24-cas',
        trigger: CommandExecutionTrigger.recovery,
      );

      // Must report CAS failure as in-flight / uncertain, NOT quarantine!
      expect(result, isA<CommandAlreadyInFlightResult>());
      expect(
        (result as CommandAlreadyInFlightResult).commandId,
        equals('cmd-r24-cas'),
      );

      // Journal command remains intact as active under its original lease!
      final persisted = await store.getPendingCommand('cmd-r24-cas');
      expect(persisted!.recoveryState, equals(CommandRecoveryState.active));
      expect(persisted.leaseToken, equals(rivalLease));
    });

    test('R24-2-05: confirmed_committed command safely reconciles domain result and completes journal', () async {
      final store = InMemoryPendingRewardCommandStore();
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-1',
        sessionGeneration: 'gen-1',
      );
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(
          FamilyId('fam-1'),
          ChildId('child-1'),
        ),
      );

      // Pre-insert a confirmed_committed row
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-r24-reconcile',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'actor-1',
        createdAt: t0,
        leaseToken: 'tok-reconcile',
        leaseExpiresAt: t0.add(const Duration(minutes: 5)),
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.confirmedCommitted,
      );
      await store.savePendingCommand(cmd, now: t0);

      final coordinator = RecoveryCoordinator(
        commandStore: store,
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );

      final result = await coordinator.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: 'fam-1',
        childId: 'child-1',
        requestedCommandId: 'cmd-r24-reconcile',
        trigger: CommandExecutionTrigger.recovery,
      );

      // Successfully reconciles with domain result!
      expect(result, isA<CommandCommittedResult>());
      final committed = result as CommandCommittedResult;
      expect(committed.wheelResult, isNotNull);
      expect(committed.wheelResult!.familyId.value, equals('fam-1'));
    });

    test('R24-2-05: SpinRewardWheel use case safely receives reconciled domain result without null-check exception', () async {
      final store = InMemoryPendingRewardCommandStore();
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-1',
        sessionGeneration: 'gen-1',
      );
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(
          FamilyId('fam-1'),
          ChildId('child-1'),
        ),
      );

      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-usecase-reconcile',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'actor-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.confirmedCommitted,
      );
      await store.savePendingCommand(cmd, now: t0);

      final coordinator = RecoveryCoordinator(
        commandStore: store,
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );

      final spinUseCase = SpinRewardWheel(
        wheelRepo,
        store,
        coordinator: coordinator,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
      );

      final spinResult = await spinUseCase(
        familyId: FamilyId('fam-1'),
        childId: ChildId('child-1'),
        commandId: 'cmd-usecase-reconcile',
      );

      expect(spinResult, isNotNull);
      expect(spinResult.familyId.value, equals('fam-1'));
    });

    test('R24-4-02: preexisting live lease cannot be adopted by another execution attempt to initiate RPC', () async {
      final store = InMemoryPendingRewardCommandStore();
      final familyId = FamilyId('fam-1');
      final childId = ChildId('child-1');
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(familyId, childId),
      );
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-1',
        sessionGeneration: 'gen-1',
        clock: clock,
      );

      // Prepopulate an unexpired lease held in the database
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-preleased',
        familyId: familyId.value,
        childId: childId.value,
        actorUserId: 'actor-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
        leaseToken: 'preexisting-token',
        leaseExpiresAt: t0.add(const Duration(seconds: 30)),
      );
      store.seedRawCommand(cmd);

      final coordinator = RecoveryCoordinator(
        commandStore: store,
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );

      final result = await coordinator.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: familyId.value,
        childId: childId.value,
        requestedCommandId: 'cmd-preleased',
      );

      // Must NOT adopt the preexisting lease and must NOT dispatch an RPC!
      expect(result, isA<CommandAlreadyInFlightResult>());
      expect(wheelRepo.spinCallCount, 0);

      // But if the caller explicitly supplies its owned matching unexpired lease token, it succeeds
      final ownedResult = await coordinator.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: familyId.value,
        childId: childId.value,
        requestedCommandId: 'cmd-preleased',
        callerOwnedLeaseToken: 'preexisting-token',
      );
      expect(ownedResult, isA<CommandCommittedResult>());
      expect(wheelRepo.spinCallCount, 1);
    });

    test('R24-4-05: null active-family provider fails closed with zero RPC and no quarantine', () async {
      final store = InMemoryPendingRewardCommandStore();
      final familyId = FamilyId('fam-active-null');
      final childId = ChildId('child-1');
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(familyId, childId),
      );
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-1',
        sessionGeneration: 'gen-1',
        clock: clock,
      );

      final coordinator = RecoveryCoordinator(
        commandStore: store,
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () =>
            null, // Explicit null active family selection
        clock: clock,
      );

      final result = await coordinator.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: familyId.value,
        childId: childId.value,
      );

      expect(result, isA<CommandFamilyMismatchResult>());
      final mismatch = result as CommandFamilyMismatchResult;
      expect(mismatch.commandFamilyId, equals('fam-active-null'));
      expect(mismatch.activeFamilyId, isNull);
      expect(wheelRepo.spinCallCount, 0);

      // Verify SpinRewardWheel use-case throws StateError
      final spinUseCase = SpinRewardWheel(
        wheelRepo,
        store,
        coordinator: coordinator,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
      );

      expect(
        () => spinUseCase(familyId: familyId, childId: childId),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(
              'Command belongs to family fam-active-null but active family is null',
            ),
          ),
        ),
      );
    });

    test('R24-4-05: attempting to execute stale-family command returns mismatch and releases claim without RPC', () async {
      final store = InMemoryPendingRewardCommandStore();
      final staleFamilyId = FamilyId('fam-stale');
      final activeFamilyId = FamilyId('fam-current');
      final childId = ChildId('child-1');
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(staleFamilyId, childId),
      );
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-1',
        sessionGeneration: 'gen-1',
        clock: clock,
      );

      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-stale-family',
        familyId: staleFamilyId.value,
        childId: childId.value,
        actorUserId: 'actor-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await store.savePendingCommand(cmd, now: t0);

      final coordinator = RecoveryCoordinator(
        commandStore: store,
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () => activeFamilyId.value,
        clock: clock,
      );

      final result = await coordinator.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: staleFamilyId.value,
        childId: childId.value,
        requestedCommandId: 'cmd-stale-family',
        trigger: CommandExecutionTrigger.recovery,
      );

      expect(result, isA<CommandFamilyMismatchResult>());
      final mismatch = result as CommandFamilyMismatchResult;
      expect(mismatch.commandFamilyId, equals('fam-stale'));
      expect(mismatch.activeFamilyId, equals('fam-current'));
      expect(wheelRepo.spinCallCount, 0);

      // Verify command is intact and not quarantined
      final retained = await store.getPendingCommand('cmd-stale-family');
      expect(retained, isNotNull);
      expect(retained!.recoveryState, equals(CommandRecoveryState.active));
    });
  });
}
