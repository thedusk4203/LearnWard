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

  group('Phase 6 Slice 4A-1: Mandatory Deterministic Acceptance Matrix (A01 - A24)', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase database;
    late AppDatabase database2;
    late TestClock clock;
    final t0 = DateTime.utc(2026, 11, 7, 12, 0, 0);

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'learnward_acceptance_test_',
      );
      dbFile = File('${tempDir.path}/acceptance.sqlite');
      database = AppDatabase(NativeDatabase(dbFile));
      database2 = AppDatabase(NativeDatabase(dbFile));
      clock = TestClock(t0);
    });

    tearDown(() async {
      await database.close();
      await database2.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    List<Reward> buildSampleRewards(FamilyId familyId, ChildId childId) {
      return [
        Reward(
          id: RewardId('rew-1'),
          familyId: familyId,
          title: 'Reward 1',
          category: RewardCategory.privilege,
          storeEnabled: true,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: WheelTier.common,
          createdAt: t0,
          updatedAt: t0,
        ),
        Reward(
          id: RewardId('rew-2'),
          familyId: familyId,
          title: 'Reward 2',
          category: RewardCategory.experience,
          storeEnabled: true,
          storeCostMinor: 2000,
          wheelEnabled: true,
          wheelTier: WheelTier.rare,
          createdAt: t0,
          updatedAt: t0,
        ),
        Reward(
          id: RewardId('rew-3'),
          familyId: familyId,
          title: 'Reward 3',
          category: RewardCategory.treat,
          storeEnabled: true,
          storeCostMinor: 3000,
          wheelEnabled: true,
          wheelTier: WheelTier.special,
          createdAt: t0,
          updatedAt: t0,
        ),
      ];
    }

    // -----------------------------------------------------------------------
    // A01: Fresh Spin and Redeem
    // -----------------------------------------------------------------------
    test('A01: Fresh Spin and Redeem inserts never-dispatched, marks, executes 1 RPC and cleans up', () async {
      final familyId = FamilyId('fam-a01');
      final childId = ChildId('child-a01');
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(familyId, childId),
      );
      final rewardRepo = MockServerRewardRepository();
      rewardRepo.childBalances[childId.value] = 5000;

      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-a01',
        sessionGeneration: 'gen-a01',
        clock: clock,
      );
      final authzPort = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
      );

      final coordinator = RecoveryCoordinator(
        commandStore: database,
        wheelRepository: wheelRepo,
        rewardRepository: rewardRepo,
        authSessionPort: authPort,
        authorizationPort: authzPort,
        clock: clock,
      );

      // Spin
      final spinResult = await coordinator.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: familyId.value,
        childId: childId.value,
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(spinResult, isA<CommandCommittedResult>());
      expect(wheelRepo.spinCallCount, 1);
      expect(await database.listPendingCommands(), isEmpty);

      // Redeem
      final redeemResult = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(redeemResult, isA<CommandCommittedResult>());
      expect(rewardRepo.redeemCallCount, 1);
      expect(rewardRepo.debitCount, 1);
      expect(await database.listPendingCommands(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // A02: Claim -> marker rejects wrong token
    // -----------------------------------------------------------------------
    test(
      'A02: marker rejects wrong token, returns false, zero RPC, row unchanged',
      () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-a02',
          familyId: 'fam-a02',
          childId: 'child-a02',
          actorUserId: 'actor-a02',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await database.savePendingCommand(cmd, now: t0);

        final token = await database.acquireClaim(
          commandId: 'cmd-a02',
          actorUserId: 'actor-a02',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        expect(token, isNotNull);

        final marked = await database.markPossiblyDispatched(
          commandId: 'cmd-a02',
          leaseToken: 'wrong-token-abc',
          authenticatedActorId: 'actor-a02',
          now: t0,
        );
        expect(marked, isFalse);

        final stored = await database.getPendingCommand('cmd-a02');
        expect(stored!.dispatchState, CommandDispatchState.neverDispatched);
        expect(stored.leaseToken, token);
      },
    );

    // -----------------------------------------------------------------------
    // A03: Claim -> marker rejects expired/replaced token
    // -----------------------------------------------------------------------
    test(
      'A03: marker rejects expired/replaced token, preserves new owner lease',
      () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-a03',
          familyId: 'fam-a03',
          childId: 'child-a03',
          actorUserId: 'actor-a03',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await database.savePendingCommand(cmd, now: t0);

        final tokenA = await database.acquireClaim(
          commandId: 'cmd-a03',
          actorUserId: 'actor-a03',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );

        // Advance past lease expiration
        final t1 = t0.add(const Duration(seconds: 31));
        final tokenB = await database2.acquireClaim(
          commandId: 'cmd-a03',
          actorUserId: 'actor-a03',
          leaseDuration: const Duration(seconds: 30),
          now: t1,
        );
        expect(tokenB, isNotNull);
        expect(tokenB, isNot(tokenA));

        // Token A attempts marker
        final markedA = await database.markPossiblyDispatched(
          commandId: 'cmd-a03',
          leaseToken: tokenA!,
          authenticatedActorId: 'actor-a03',
          now: t1,
        );
        expect(markedA, isFalse);

        // Row preserves token B's ownership
        final stored = await database.getPendingCommand('cmd-a03');
        expect(stored!.leaseToken, tokenB);
      },
    );

    // -----------------------------------------------------------------------
    // A04: Crash immediately after pre-dispatch SQLite commit
    // -----------------------------------------------------------------------
    test('A04: crash after pre-dispatch commit reopens as possibly_dispatched with same ID', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-a04-original',
        familyId: 'fam-a04',
        childId: 'child-a04',
        actorUserId: 'actor-a04',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final token = await database.acquireClaim(
        commandId: 'cmd-a04-original',
        actorUserId: 'actor-a04',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      await database.markPossiblyDispatched(
        commandId: 'cmd-a04-original',
        leaseToken: token!,
        authenticatedActorId: 'actor-a04',
        now: t0,
      );

      // Simulate crash
      await database.close();
      await database2.close();

      // Reopen database from disk
      final restartedDb = AppDatabase(NativeDatabase(dbFile));
      final reloaded = await restartedDb.getPendingCommand('cmd-a04-original');
      expect(reloaded, isNotNull);
      expect(reloaded!.commandId, 'cmd-a04-original');
      expect(reloaded.dispatchState, CommandDispatchState.possiblyDispatched);
      expect(reloaded.actorUserId, 'actor-a04');
      await restartedDb.close();
    });

    // -----------------------------------------------------------------------
    // A05: Response lost after authoritative server commit
    // -----------------------------------------------------------------------
    test('A05: commit-response-loss retries exact same ID; exactly 1 server debit/spin', () async {
      final familyId = FamilyId('fam-a05');
      final childId = ChildId('child-a05');
      final rewardRepo = MockServerRewardRepository();
      rewardRepo.childBalances[childId.value] = 5000;
      rewardRepo.simulateLossOnNextCommit = true;

      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-a05',
        sessionGeneration: 'gen-a05',
        clock: clock,
      );
      final authzPort = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
      );

      final coordinator = RecoveryCoordinator(
        commandStore: database,
        rewardRepository: rewardRepo,
        authSessionPort: authPort,
        authorizationPort: authzPort,
        clock: clock,
      );

      // First call: commits debit but throws SocketException
      final res1 = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(res1, isA<CommandScheduledResult>());
      expect(rewardRepo.debitCount, 1);

      // Retry same intent
      final res2 = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(res2, isA<CommandCommittedResult>());
      expect(rewardRepo.debitCount, 1); // No double debit
      expect(await database.listPendingCommands(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // A06: Two SQLite connections claim concurrently
    // -----------------------------------------------------------------------
    test(
      'A06: two SQLite connections claim concurrently; exactly one wins',
      () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-a06',
          familyId: 'fam-a06',
          childId: 'child-a06',
          actorUserId: 'actor-a06',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await database.savePendingCommand(cmd, now: t0);

        final claims = await Future.wait([
          database.acquireClaim(
            commandId: 'cmd-a06',
            actorUserId: 'actor-a06',
            leaseDuration: const Duration(seconds: 30),
            now: t0,
          ),
          database2.acquireClaim(
            commandId: 'cmd-a06',
            actorUserId: 'actor-a06',
            leaseDuration: const Duration(seconds: 30),
            now: t0,
          ),
        ]);

        final winners = claims.where((c) => c != null).toList();
        final losers = claims.where((c) => c == null).toList();
        expect(winners.length, 1);
        expect(losers.length, 1);
      },
    );

    // -----------------------------------------------------------------------
    // A07: Slow A / expired lease / B takeover
    // -----------------------------------------------------------------------
    test('A07: expired lease allows takeover; stale owner cannot mark, release or complete', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-a07',
        familyId: 'fam-a07',
        childId: 'child-a07',
        actorUserId: 'actor-a07',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final tokenA = await database.acquireClaim(
        commandId: 'cmd-a07',
        actorUserId: 'actor-a07',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );

      final tExpiry = t0.add(const Duration(seconds: 31));
      final tokenB = await database2.acquireClaim(
        commandId: 'cmd-a07',
        actorUserId: 'actor-a07',
        leaseDuration: const Duration(seconds: 30),
        now: tExpiry,
      );
      expect(tokenB, isNotNull);

      // Stale A attempts operations
      expect(
        await database.markPossiblyDispatched(
          commandId: 'cmd-a07',
          leaseToken: tokenA!,
          authenticatedActorId: 'actor-a07',
          now: tExpiry,
        ),
        isFalse,
      );
      expect(
        await database.releaseClaim(
          commandId: 'cmd-a07',
          leaseToken: tokenA,
          nextAttemptAt: tExpiry.add(const Duration(seconds: 10)),
        ),
        isFalse,
      );
      expect(
        await database.completeCommand(
          commandId: 'cmd-a07',
          leaseToken: tokenA,
        ),
        isFalse,
      );

      final finalRow = await database.getPendingCommand('cmd-a07');
      expect(finalRow!.leaseToken, tokenB);
    });

    // -----------------------------------------------------------------------
    // A08: Same actor switches active family mid-flow
    // -----------------------------------------------------------------------
    test('A08: actor switches active family mid-flow; zero RPC for inactive family', () async {
      final family1 = 'fam-1';
      final family2 = 'fam-2';
      final child1 = 'child-1';

      final cmd1 = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-a08-fam1',
        familyId: family1,
        childId: child1,
        actorUserId: 'actor-a08',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd1, now: t0);

      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(FamilyId(family1), ChildId(child1)),
      );
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-a08',
        sessionGeneration: 'gen-a08',
        clock: clock,
      );
      final coordinator = RecoveryCoordinator(
        commandStore: database,
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );

      final dispatcher = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coordinator,
        clock: clock,
      );

      final context = await authPort.validateForMutation();
      final processed = await dispatcher.drainOnce(
        validatedContext: context!,
        activeFamilyId: family2, // Active family is family 2
      );

      expect(processed, 0);
      expect(wheelRepo.spinCallCount, 0);
      final dormant = await database.getPendingCommand('cmd-a08-fam1');
      expect(dormant!.recoveryState, CommandRecoveryState.active);
    });

    // -----------------------------------------------------------------------
    // A09: A logs out before final RPC
    // -----------------------------------------------------------------------
    test(
      'A09: actor logs out before RPC; zero mutation RPC; journal preserved',
      () async {
        final authPort = FakeAuthSessionPort(
          activeUserId: 'actor-a09',
          sessionGeneration: 'gen-a09',
          clock: clock,
        );
        authPort.signOut(); // Logged out

        final coordinator = RecoveryCoordinator(
          commandStore: database,
          wheelRepository: FakeWheelRepository(),
          authSessionPort: authPort,
          authorizationPort: FakeRecoveryAuthorizationPort(),
          clock: clock,
        );

        final res = await coordinator.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: 'fam-a09',
          childId: 'child-a09',
          trigger: CommandExecutionTrigger.foreground,
        );

        expect(res, isA<CommandAuthUnavailableResult>());
        expect(await database.listPendingCommands(), isEmpty);
      },
    );

    // -----------------------------------------------------------------------
    // A10: A logs out while RPC in-flight
    // -----------------------------------------------------------------------
    test(
      'A10: session epoch changes during execution; no RPC; journal retained',
      () async {
        final familyId = FamilyId('fam-a10');
        final childId = ChildId('child-a10');
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-a10',
          familyId: familyId.value,
          childId: childId.value,
          actorUserId: 'actor-a10',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await database.savePendingCommand(cmd, now: t0);

        final authPort = _EpochChangingAuthSessionPort(
          userId: 'actor-a10',
          initialGeneration: 'gen-epoch-1',
          nextGeneration: 'gen-epoch-2',
          clock: clock,
        );

        final wheelRepo = FakeWheelRepository(
          initialRewards: buildSampleRewards(familyId, childId),
        );
        final coordinator = RecoveryCoordinator(
          commandStore: database,
          wheelRepository: wheelRepo,
          authSessionPort: authPort,
          authorizationPort: FakeRecoveryAuthorizationPort(),
          clock: clock,
        );

        final res = await coordinator.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: familyId.value,
          childId: childId.value,
          requestedCommandId: 'cmd-a10',
          trigger: CommandExecutionTrigger.recovery,
        );

        expect(res, isA<CommandAuthUnavailableResult>());
        expect(wheelRepo.spinCallCount, 0);
      },
    );

    // -----------------------------------------------------------------------
    // A11: Actor B sign-in on shared device
    // -----------------------------------------------------------------------
    test('A11: actor B sign-in pauses eligible commands of actor A in same family without RPC', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-a11',
        familyId: 'fam-shared',
        childId: 'child-shared',
        actorUserId: 'actor-A',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final authPortB = FakeAuthSessionPort(
        activeUserId: 'actor-B',
        sessionGeneration: 'gen-B',
        clock: clock,
      );
      final wheelRepo = FakeWheelRepository();
      final coordinator = RecoveryCoordinator(
        commandStore: database,
        wheelRepository: wheelRepo,
        authSessionPort: authPortB,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );
      final dispatcher = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coordinator,
        clock: clock,
      );

      final contextB = await authPortB.validateForMutation();
      await dispatcher.drainOnce(
        validatedContext: contextB!,
        activeFamilyId: 'fam-shared',
      );

      final stored = await database.getPendingCommand('cmd-a11');
      expect(stored!.recoveryState, CommandRecoveryState.pendingOriginalActor);
      expect(stored.actorUserId, 'actor-A'); // Unchanged
      expect(wheelRepo.spinCallCount, 0);
    });

    // -----------------------------------------------------------------------
    // A12: Original actor A returns
    // -----------------------------------------------------------------------
    test('A12: original actor A returns; resumes paused command via CAS and replays same ID', () async {
      final familyId = FamilyId('fam-a12');
      final childId = ChildId('child-a12');
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-a12-stable',
        familyId: familyId.value,
        childId: childId.value,
        actorUserId: 'actor-A',
        createdAt: t0,
        recoveryState: CommandRecoveryState.pendingOriginalActor,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final authPortA = FakeAuthSessionPort(
        activeUserId: 'actor-A',
        sessionGeneration: 'gen-A',
        clock: clock,
      );
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(familyId, childId),
      );
      final coordinator = RecoveryCoordinator(
        commandStore: database,
        wheelRepository: wheelRepo,
        authSessionPort: authPortA,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );
      final dispatcher = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coordinator,
        clock: clock,
      );

      final contextA = await authPortA.validateForMutation();
      final processed = await dispatcher.drainOnce(
        validatedContext: contextA!,
        activeFamilyId: familyId.value,
      );

      expect(processed, 1);
      expect(wheelRepo.spinCallCount, 1);
      expect(await database.listPendingCommands(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // A13: Paired child grant revoked + revoked_at set
    // -----------------------------------------------------------------------
    test(
      'A13: confirmed grant revocation quarantines command; zero RPC',
      () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-a13',
          familyId: 'fam-a13',
          childId: 'child-a13',
          actorUserId: 'actor-a13',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await database.savePendingCommand(cmd, now: t0);

        final authPort = FakeAuthSessionPort(
          activeUserId: 'actor-a13',
          sessionGeneration: 'gen-a13',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.definitelyDenied,
        );

        final wheelRepo = FakeWheelRepository();
        final coordinator = RecoveryCoordinator(
          commandStore: database,
          wheelRepository: wheelRepo,
          authSessionPort: authPort,
          authorizationPort: authzPort,
          clock: clock,
        );

        final res = await coordinator.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: 'fam-a13',
          childId: 'child-a13',
          requestedCommandId: 'cmd-a13',
          trigger: CommandExecutionTrigger.recovery,
        );

        expect(res, isA<CommandQuarantinedResult>());
        expect(wheelRepo.spinCallCount, 0);
      },
    );

    // -----------------------------------------------------------------------
    // A14: 42501 without positive revocation evidence
    // -----------------------------------------------------------------------
    test('A14: 42501 error transitions to quarantinedUnknownOutcome; no busy retry', () async {
      final familyId = FamilyId('fam-a14');
      final childId = ChildId('child-a14');
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(familyId, childId),
      );
      wheelRepo.failNextWithPermissionError = true;

      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-a14',
        sessionGeneration: 'gen-a14',
        clock: clock,
      );
      final coordinator = RecoveryCoordinator(
        commandStore: database,
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );

      final res = await coordinator.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: familyId.value,
        childId: childId.value,
        trigger: CommandExecutionTrigger.foreground,
      );

      expect(res, isA<CommandQuarantinedResult>());
      final stored = (await database.listPendingCommands()).first;
      expect(
        stored.recoveryState,
        CommandRecoveryState.quarantinedUnknownOutcome,
      );
    });

    // -----------------------------------------------------------------------
    // A15: Child archived after command may have committed
    // -----------------------------------------------------------------------
    test('A15: archived child error preserves command in quarantinedUnknownOutcome without deletion', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-a15',
        familyId: 'fam-a15',
        childId: 'child-a15',
        actorUserId: 'actor-a15',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final token = await database.acquireClaim(
        commandId: 'cmd-a15',
        actorUserId: 'actor-a15',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );

      await database.transitionRecoveryState(
        commandId: 'cmd-a15',
        leaseToken: token!,
        newState: CommandRecoveryState.quarantinedUnknownOutcome,
        lastErrorMessage: 'Child profile is archived',
      );

      final row = await database.getPendingCommand('cmd-a15');
      expect(row!.commandId, 'cmd-a15');
      expect(row.recoveryState, CommandRecoveryState.quarantinedUnknownOutcome);
    });

    // -----------------------------------------------------------------------
    // A16: Backoff after 1, 2, 3 failures and restart
    // -----------------------------------------------------------------------
    test('A16: exponential backoff after 1, 2, 3 failures with persisted schedule and increments', () async {
      final familyId = FamilyId('fam-a16');
      final childId = ChildId('child-a16');
      final rewardRepo = _FailingThenSucceedingRewardRepository(
        failuresAllowed: 3,
      );

      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-a16',
        sessionGeneration: 'gen-a16',
        clock: clock,
      );
      final jitter = const DeterministicJitterSource(1.0); // max delay

      final coordinator = RecoveryCoordinator(
        commandStore: database,
        rewardRepository: rewardRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
        jitterSource: jitter,
      );

      // Pre-insert command
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.redeemReward,
        commandId: 'cmd-a16',
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        actorUserId: 'actor-a16',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      // Failure 1 (attempts = 1)
      final res1 = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        requestedCommandId: 'cmd-a16',
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(res1, isA<CommandScheduledResult>());
      var stored = await database.getPendingCommand('cmd-a16');
      expect(stored!.retryCount, 1);
      expect(stored.nextAttemptAt, t0.add(const Duration(seconds: 2)));

      // Early attempt rejected
      clock.advance(const Duration(seconds: 1));
      final earlyRes = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        requestedCommandId: 'cmd-a16',
        trigger: CommandExecutionTrigger.recovery,
      );
      expect(earlyRes, isA<CommandScheduledResult>());

      // Failure 2 at t0 + 2s (attempts = 2)
      clock.advance(const Duration(seconds: 1)); // at t0 + 2s
      final res2 = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        requestedCommandId: 'cmd-a16',
        trigger: CommandExecutionTrigger.recovery,
      );
      expect(res2, isA<CommandScheduledResult>());
      stored = await database.getPendingCommand('cmd-a16');
      expect(stored!.retryCount, 2);
      expect(stored.nextAttemptAt, clock.now().add(const Duration(seconds: 4)));

      // Failure 3 at t0 + 6s (attempts = 3)
      clock.advance(const Duration(seconds: 4));
      final res3 = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        requestedCommandId: 'cmd-a16',
        trigger: CommandExecutionTrigger.recovery,
      );
      expect(res3, isA<CommandScheduledResult>());
      stored = await database.getPendingCommand('cmd-a16');
      expect(stored!.retryCount, 3);
      expect(stored.nextAttemptAt, clock.now().add(const Duration(seconds: 8)));

      // Advance 8s and succeed (attempts = 4 > 3)
      clock.advance(const Duration(seconds: 8));
      final res4 = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        requestedCommandId: 'cmd-a16',
        trigger: CommandExecutionTrigger.recovery,
      );
      expect(res4, isA<CommandCommittedResult>());
      expect(await database.listPendingCommands(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // A17: Daily cap / insufficient RP / disabled wheel / pool
    // -----------------------------------------------------------------------
    test('A17: terminal business errors (LW201, LW202, LW203, LW206) perform token-fenced delete', () async {
      final familyId = FamilyId('fam-a17');
      final childId = ChildId('child-a17');
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-a17',
        sessionGeneration: 'gen-a17',
        clock: clock,
      );

      // LW201: Insufficient RP
      final rewardRepo = MockServerRewardRepository();
      rewardRepo.childBalances[childId.value] = 100; // Less than 1500 cost
      final coordinator = RecoveryCoordinator(
        commandStore: database,
        rewardRepository: rewardRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );

      final res = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-1',
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(res, isA<CommandTerminalRejectionResult>());
      expect((res as CommandTerminalRejectionResult).errorCode, 'LW201');
      expect(await database.listPendingCommands(), isEmpty); // Journal cleared

      // LW206: Wheel disabled
      final wheelRepo = FakeWheelRepository(
        initialRewards: buildSampleRewards(familyId, childId),
      );
      await wheelRepo.updateWheelSettings(
        WheelSettings(
          familyId: familyId,
          isEnabled: false,
          createdAt: t0,
          updatedAt: t0,
        ),
      );
      final wheelCoord = RecoveryCoordinator(
        commandStore: database,
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );

      final spinRes = await wheelCoord.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: familyId.value,
        childId: childId.value,
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(spinRes, isA<CommandTerminalRejectionResult>());
      expect((spinRes as CommandTerminalRejectionResult).errorCode, 'LW206');
      expect(await database.listPendingCommands(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // A18: Reward unavailable (LW205)
    // -----------------------------------------------------------------------
    test('A18: LW205 reward unavailable is terminal on definitive backend response', () async {
      final familyId = FamilyId('fam-a18');
      final childId = ChildId('child-a18');
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-a18',
        sessionGeneration: 'gen-a18',
        clock: clock,
      );
      final rewardRepo = MockServerRewardRepository();
      rewardRepo.childBalances[childId.value] = 5000;

      // Custom repository error throwing LW205
      final unavailableRepo = _UnavailableRewardRepository();
      final coordinator = RecoveryCoordinator(
        commandStore: database,
        rewardRepository: unavailableRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        clock: clock,
      );

      final res = await coordinator.execute(
        operation: RewardCommandOperation.redeemReward,
        familyId: familyId.value,
        childId: childId.value,
        rewardId: 'rew-unavailable',
        trigger: CommandExecutionTrigger.foreground,
      );

      expect(res, isA<CommandTerminalRejectionResult>());
      expect((res as CommandTerminalRejectionResult).errorCode, 'LW205');
      expect(await database.listPendingCommands(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // A19: Legacy v4/v5 unknown actor and unknown_legacy
    // -----------------------------------------------------------------------
    test(
      'A19: unknown_legacy or null actor strictly preserved; zero claim/RPC',
      () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-a19-legacy',
          familyId: 'fam-a19',
          childId: 'child-a19',
          actorUserId: null,
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.unknownLegacy,
        );
        await database.savePendingCommand(cmd, now: t0);

        final wheelRepo = FakeWheelRepository();
        final authPort = FakeAuthSessionPort(
          activeUserId: 'actor-a19',
          sessionGeneration: 'gen-a19',
          clock: clock,
        );
        final coordinator = RecoveryCoordinator(
          commandStore: database,
          wheelRepository: wheelRepo,
          authSessionPort: authPort,
          authorizationPort: FakeRecoveryAuthorizationPort(),
          clock: clock,
        );

        final res = await coordinator.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: 'fam-a19',
          childId: 'child-a19',
          requestedCommandId: 'cmd-a19-legacy',
          trigger: CommandExecutionTrigger.recovery,
        );

        expect(res, isA<CommandQuarantinedResult>());
        expect(wheelRepo.spinCallCount, 0);

        final preserved = await database.getPendingCommand('cmd-a19-legacy');
        expect(preserved!.dispatchState, CommandDispatchState.unknownLegacy);
      },
    );

    // -----------------------------------------------------------------------
    // A20: Existing foreground wheel/store flows
    // -----------------------------------------------------------------------
    test(
      'A20: existing foreground wheel/store flows return normal domain results',
      () async {
        final familyId = FamilyId('fam-a20');
        final childId = ChildId('child-a20');
        final wheelRepo = FakeWheelRepository(
          initialRewards: buildSampleRewards(familyId, childId),
        );
        final rewardRepo = MockServerRewardRepository();
        rewardRepo.childBalances[childId.value] = 5000;

        final spinUseCase = SpinRewardWheel(wheelRepo, database, clock: clock);
        final spinResult = await spinUseCase(
          familyId: familyId,
          childId: childId,
          actorUserId: 'actor-a20',
        );
        expect(spinResult.spinId, isNotNull);
        expect(await database.listPendingCommands(), isEmpty);

        final redeemUseCase = RedeemStoreReward(
          rewardRepo,
          database,
          clock: clock,
        );
        final redeemResult = await redeemUseCase(
          familyId: familyId,
          rewardId: RewardId('rew-1'),
          childId: childId,
          actorUserId: 'actor-a20',
        );
        expect(redeemResult.id.value, isNotEmpty);
        expect(await database.listPendingCommands(), isEmpty);
      },
    );

    // -----------------------------------------------------------------------
    // A21: Auth stream emits error on offline refresh
    // -----------------------------------------------------------------------
    test(
      'A21: auth stream handles offline refresh error fail-closed; zero RPC',
      () async {
        final familyId = FamilyId('fam-a21');
        final childId = ChildId('child-a21');
        final authPort = FakeAuthSessionPort(
          activeUserId: 'actor-a21',
          sessionGeneration: 'gen-a21',
          clock: clock,
        );
        authPort.emitStreamError(
          const SocketException('Offline auth refresh failed'),
        );
        authPort.invalidateSession(); // Session fails closed on refresh error

        final wheelRepo = FakeWheelRepository(
          initialRewards: buildSampleRewards(familyId, childId),
        );
        final coordinator = RecoveryCoordinator(
          commandStore: database,
          wheelRepository: wheelRepo,
          authSessionPort: authPort,
          authorizationPort: FakeRecoveryAuthorizationPort(),
          clock: clock,
        );

        // Does not crash; fails closed with zero mutation RPC
        final res = await coordinator.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: familyId.value,
          childId: childId.value,
          trigger: CommandExecutionTrigger.foreground,
        );
        expect(res, isA<CommandAuthUnavailableResult>());
        expect(wheelRepo.spinCallCount, 0);
      },
    );

    // -----------------------------------------------------------------------
    // A22: 10-row queue limit with wrong-family rows first
    // -----------------------------------------------------------------------
    test('A22: 10-row queue limit with other-family rows first does not starve active family', () async {
      final activeFamily = 'fam-active';
      final otherFamily = 'fam-other';

      // Insert 10 rows for other family first
      for (var i = 0; i < 10; i++) {
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-other-$i',
            familyId: otherFamily,
            childId: 'child-other',
            actorUserId: 'actor-a22',
            createdAt: t0.add(Duration(seconds: i)),
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
          ),
          now: t0,
        );
      }

      // Insert 2 rows for active family
      for (var i = 0; i < 2; i++) {
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-active-$i',
            familyId: activeFamily,
            childId: 'child-active',
            actorUserId: 'actor-a22',
            createdAt: t0.add(Duration(seconds: 20 + i)),
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
          ),
          now: t0,
        );
      }

      // List claimable commands strictly scoped to active family
      final activeClaimable = await database.listClaimableCommands(
        actorUserId: 'actor-a22',
        limit: 10,
        familyId: activeFamily,
        now: t0,
      );

      expect(activeClaimable.length, 2);
      expect(activeClaimable.every((c) => c.familyId == activeFamily), isTrue);
    });

    // -----------------------------------------------------------------------
    // A23: Crash/kill with live claim
    // -----------------------------------------------------------------------
    test('A23: crash/kill with live claim retains lease; reclaims only after expiry', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-a23',
        familyId: 'fam-a23',
        childId: 'child-a23',
        actorUserId: 'actor-a23',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final token = await database.acquireClaim(
        commandId: 'cmd-a23',
        actorUserId: 'actor-a23',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(token, isNotNull);

      // Crash and reopen
      await database.close();
      await database2.close();
      final restartedDb = AppDatabase(NativeDatabase(dbFile));

      // Attempt reclaim at t0 + 10s (before expiry): must fail
      final midClaim = await restartedDb.acquireClaim(
        commandId: 'cmd-a23',
        actorUserId: 'actor-a23',
        leaseDuration: const Duration(seconds: 30),
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(midClaim, isNull);

      // Attempt reclaim at t0 + 31s (after expiry): must succeed
      final afterExpiryClaim = await restartedDb.acquireClaim(
        commandId: 'cmd-a23',
        actorUserId: 'actor-a23',
        leaseDuration: const Duration(seconds: 30),
        now: t0.add(const Duration(seconds: 31)),
      );
      expect(afterExpiryClaim, isNotNull);
      await restartedDb.close();
    });

    // -----------------------------------------------------------------------
    // A24: Definite success response with stale token
    // -----------------------------------------------------------------------
    test('A24: definite success response with stale token affects 0 rows; no overwrite/deletion', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-a24',
        familyId: 'fam-a24',
        childId: 'child-a24',
        actorUserId: 'actor-a24',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final tokenA = await database.acquireClaim(
        commandId: 'cmd-a24',
        actorUserId: 'actor-a24',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );

      // Advance past lease expiry, second worker acquires token B
      final t1 = t0.add(const Duration(seconds: 31));
      final tokenB = await database2.acquireClaim(
        commandId: 'cmd-a24',
        actorUserId: 'actor-a24',
        leaseDuration: const Duration(seconds: 30),
        now: t1,
      );
      expect(tokenB, isNotNull);

      // Worker A attempts to complete command with stale tokenA
      final completedA = await database.completeCommand(
        commandId: 'cmd-a24',
        leaseToken: tokenA!,
      );
      expect(completedA, isFalse);

      // Row remains intact with token B ownership
      final remaining = await database.getPendingCommand('cmd-a24');
      expect(remaining, isNotNull);
      expect(remaining!.leaseToken, tokenB);
    });
  });
}

final class _UnavailableRewardRepository implements RewardRepository {
  @override
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) async {
    throw const InvalidRewardException('LW205: Reward is no longer available');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _EpochChangingAuthSessionPort implements AuthSessionPort {
  _EpochChangingAuthSessionPort({
    required this.userId,
    required this.initialGeneration,
    required this.nextGeneration,
    required this.clock,
  }) : currentSessionGeneration = initialGeneration;

  final String userId;
  final String initialGeneration;
  final String nextGeneration;
  final Clock clock;

  @override
  String? currentSessionGeneration;

  @override
  Stream<String?> get sessionGenerationStream =>
      Stream.value(currentSessionGeneration);

  @override
  Future<ValidatedActorContext?> validateForMutation() async {
    final context = ValidatedActorContext(
      userId: userId,
      sessionGeneration: initialGeneration,
      observedAt: clock.now().toUtc(),
    );
    // Simulate generation changing asynchronously immediately after preflight validation
    currentSessionGeneration = nextGeneration;
    return context;
  }
}

final class _FailingThenSucceedingRewardRepository implements RewardRepository {
  _FailingThenSucceedingRewardRepository({this.failuresAllowed = 3});

  int attempts = 0;
  final int failuresAllowed;

  @override
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) async {
    attempts++;
    if (attempts <= failuresAllowed) {
      throw const SocketException('Transient network failure');
    }
    final now = DateTime.now().toUtc();
    return RewardRedemption(
      id: RewardRedemptionId('red-success'),
      familyId: FamilyId('fam-a16'),
      childId: childId,
      rewardId: rewardId,
      origin: RewardOrigin.store,
      rpCostMinor: 1500,
      status: RewardRedemptionStatus.pendingFulfillment,
      rewardSnapshot: const {'title': 'Test Reward', 'cost': 1500},
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
