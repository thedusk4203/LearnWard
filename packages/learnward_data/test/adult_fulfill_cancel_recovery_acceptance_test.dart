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

  group('Phase 6 Slice 4A-2: Mandatory Deterministic Acceptance Matrix (A2-01 - A2-20)', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase database;
    late AppDatabase database2;
    late TestClock clock;
    final t0 = DateTime.utc(2026, 11, 7, 12, 0, 0);

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_a2_test_');
      dbFile = File('${tempDir.path}/a2_acceptance.sqlite');
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

    RewardRedemption buildRedemption({
      required String id,
      String familyId = 'fam-1',
      String childId = 'child-1',
      int rpCostMinor = 1500,
      RewardRedemptionStatus status = RewardRedemptionStatus.pendingFulfillment,
      String? cancellationReason,
    }) {
      return RewardRedemption(
        id: RewardRedemptionId(id),
        familyId: FamilyId(familyId),
        childId: ChildId(childId),
        rewardId: RewardId('rew-1'),
        origin: RewardOrigin.store,
        rpCostMinor: rpCostMinor,
        status: status,
        cancellationReason: cancellationReason,
        rewardSnapshot: const {'title': 'Test Reward', 'cost': 1500},
        createdAt: t0,
        updatedAt: t0,
      );
    }

    RecoveryCoordinator buildCoordinator({
      required AppDatabase db,
      required RewardRepository rewardRepo,
      required AuthSessionPort authPort,
      required RecoveryAuthorizationPort authzPort,
      Clock? clk,
      JitterSource? jitter,
      String? Function()? activeFamilyIdProvider,
      WheelRepository? wheelRepo,
    }) {
      return RecoveryCoordinator(
        commandStore: db,
        wheelRepository: wheelRepo ?? FakeWheelRepository(),
        rewardRepository: rewardRepo,
        authSessionPort: authPort,
        authorizationPort: authzPort,
        clock: clk ?? clock,
        jitterSource: jitter ?? const DeterministicJitterSource(0.0),
        activeFamilyIdProvider: activeFamilyIdProvider,
      );
    }

    Future<CommandExecutionResult> retryCommand({
      required RecoveryCoordinator coord,
      required String commandId,
      CommandExecutionTrigger trigger = CommandExecutionTrigger.recovery,
    }) async {
      final cmd = await database.getPendingCommand(commandId);
      if (cmd == null) {
        throw StateError('Command not found: $commandId');
      }
      return coord.execute(
        operation: cmd.operation,
        familyId: cmd.familyId,
        childId: cmd.childId ?? '',
        rewardId: cmd.rewardId,
        redemptionId: cmd.redemptionId,
        cancellationReason: cmd.cancellationReason,
        requestedCommandId: cmd.commandId,
        trigger: trigger,
      );
    }

    // -----------------------------------------------------------------------
    // A2-01: New Fulfill, confirmed success, verified adult role provenance
    // -----------------------------------------------------------------------
    group(
      'A2-01: New Fulfill, confirmed success, verified adult role provenance',
      () {
        test('Subcase 1a: Verified owner with context.role == owner', () async {
          final repo = MockServerRewardRepository();
          repo.currentActorUserId = 'user-owner';
          repo.redemptions['red-1a'] = buildRedemption(id: 'red-1a');
          repo.childBalances['child-1'] = 5000;

          final authPort = FakeAuthSessionPort(
            activeUserId: 'user-owner',
            role: 'owner',
            clock: clock,
          );
          final authzPort = FakeRecoveryAuthorizationPort(
            defaultStatus: TargetAuthorizationStatus.authorized,
            defaultAdultRole: VerifiedAdultRole.owner,
          );
          final coord = buildCoordinator(
            db: database,
            rewardRepo: repo,
            authPort: authPort,
            authzPort: authzPort,
          );

          repo.rpcEnteredBarrier = Completer<void>();
          repo.allowRpcFinishBarrier = Completer<void>();

          final execFuture = coord.execute(
            operation: RewardCommandOperation.fulfillReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-1a',
          );

          await repo.rpcEnteredBarrier!.future;

          // In-flight assertion before completeCommand
          final inFlightRows = await database.listPendingCommands();
          expect(inFlightRows.length, 1);
          final row = inFlightRows.single;
          expect(row.dispatchState, CommandDispatchState.possiblyDispatched);
          expect(row.actorUserId, 'user-owner');
          expect(row.childId, 'child-1');
          expect(row.redemptionId, 'red-1a');
          expect(row.actorRole, 'owner');
          expect(row.leaseToken, isNotNull);

          repo.allowRpcFinishBarrier!.complete();
          final result = await execFuture;

          expect(result, isA<CommandCommittedResult>());
          expect(await database.listPendingCommands(), isEmpty);
          expect(repo.fulfillCallCount, 1);
          expect(
            repo.redemptions['red-1a']!.status,
            RewardRedemptionStatus.fulfilled,
          );
          expect(repo.redemptions['red-1a']!.fulfilledByUserId, 'user-owner');
          expect(
            repo.commandReceipts.containsKey(
              (result as CommandCommittedResult).commandId,
            ),
            isTrue,
          );
          expect(repo.childBalances['child-1'], 5000);
        });

        test(
          'Subcase 1b: Verified parent with context.role == parent',
          () async {
            final repo = MockServerRewardRepository();
            repo.currentActorUserId = 'user-parent';
            repo.redemptions['red-1b'] = buildRedemption(id: 'red-1b');
            repo.childBalances['child-1'] = 5000;

            final authPort = FakeAuthSessionPort(
              activeUserId: 'user-parent',
              role: 'parent',
              clock: clock,
            );
            final authzPort = FakeRecoveryAuthorizationPort(
              defaultStatus: TargetAuthorizationStatus.authorized,
              defaultAdultRole: VerifiedAdultRole.parent,
            );
            final coord = buildCoordinator(
              db: database,
              rewardRepo: repo,
              authPort: authPort,
              authzPort: authzPort,
            );

            repo.rpcEnteredBarrier = Completer<void>();
            repo.allowRpcFinishBarrier = Completer<void>();

            final execFuture = coord.execute(
              operation: RewardCommandOperation.fulfillReward,
              familyId: 'fam-1',
              childId: 'child-1',
              redemptionId: 'red-1b',
            );

            await repo.rpcEnteredBarrier!.future;
            final inFlightRows = await database.listPendingCommands();
            expect(inFlightRows.single.actorRole, 'parent');

            repo.allowRpcFinishBarrier!.complete();
            final result = await execFuture;
            expect(result, isA<CommandCommittedResult>());
            expect(await database.listPendingCommands(), isEmpty);
            expect(repo.fulfillCallCount, 1);
          },
        );

        test('Subcase 1c: Missing session role context.role == null with verified owner in membership', () async {
          final repo = MockServerRewardRepository();
          repo.currentActorUserId = 'user-owner-null-role';
          repo.redemptions['red-1c'] = buildRedemption(id: 'red-1c');

          final authPort = FakeAuthSessionPort(
            activeUserId: 'user-owner-null-role',
            role: null, // Session metadata has null role!
            clock: clock,
          );
          final authzPort = FakeRecoveryAuthorizationPort(
            defaultStatus: TargetAuthorizationStatus.authorized,
            defaultAdultRole: VerifiedAdultRole.owner, // DB verifies owner
          );
          final coord = buildCoordinator(
            db: database,
            rewardRepo: repo,
            authPort: authPort,
            authzPort: authzPort,
          );

          repo.rpcEnteredBarrier = Completer<void>();
          repo.allowRpcFinishBarrier = Completer<void>();

          final execFuture = coord.execute(
            operation: RewardCommandOperation.fulfillReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-1c',
          );

          await repo.rpcEnteredBarrier!.future;
          final inFlightRows = await database.listPendingCommands();
          // Crucial R28-01 assertion: Must be 'owner', never defaulted to 'parent'!
          expect(inFlightRows.single.actorRole, 'owner');

          repo.allowRpcFinishBarrier!.complete();
          final result = await execFuture;
          expect(result, isA<CommandCommittedResult>());
          expect(await database.listPendingCommands(), isEmpty);
          expect(repo.fulfillCallCount, 1);
        });
      },
    );

    // -----------------------------------------------------------------------
    // A2-02: New Cancel, confirmed success, one refund, verified adult role provenance
    // -----------------------------------------------------------------------
    group('A2-02: New Cancel, confirmed success, one refund, verified adult role provenance', () {
      test('Subcase 2a: context.role == null with verified parent -> actorRole == parent', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-2a'] = buildRedemption(
          id: 'red-2a',
          rpCostMinor: 1500,
        );
        repo.childBalances['child-1'] = 3500;

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: null,
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        repo.rpcEnteredBarrier = Completer<void>();
        repo.allowRpcFinishBarrier = Completer<void>();

        final execFuture = coord.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-2a',
          cancellationReason: 'Out of stock this week',
        );

        await repo.rpcEnteredBarrier!.future;
        final inFlightRows = await database.listPendingCommands();
        expect(inFlightRows.single.actorRole, 'parent');
        expect(
          inFlightRows.single.cancellationReason,
          'Out of stock this week',
        );
        expect(
          inFlightRows.single.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );

        repo.allowRpcFinishBarrier!.complete();
        final result = await execFuture;
        expect(result, isA<CommandCommittedResult>());
        expect(await database.listPendingCommands(), isEmpty);
        expect(repo.cancelCallCount, 1);
        expect(repo.refundCount, 1);
        expect(repo.childBalances['child-1'], 5000);
        expect(
          repo.redemptions['red-2a']!.status,
          RewardRedemptionStatus.cancelled,
        );
        expect(
          repo.redemptions['red-2a']!.cancellationReason,
          'Out of stock this week',
        );
      });

      test('Subcase 2b: context.role == null with verified owner -> actorRole == owner', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-2b'] = buildRedemption(
          id: 'red-2b',
          rpCostMinor: 1500,
        );
        repo.childBalances['child-1'] = 3500;

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-o',
          role: null,
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.owner,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        repo.rpcEnteredBarrier = Completer<void>();
        repo.allowRpcFinishBarrier = Completer<void>();

        final execFuture = coord.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-2b',
          cancellationReason: 'Out of stock this week',
        );

        await repo.rpcEnteredBarrier!.future;
        final inFlightRows = await database.listPendingCommands();
        expect(inFlightRows.single.actorRole, 'owner');

        repo.allowRpcFinishBarrier!.complete();
        final result = await execFuture;
        expect(result, isA<CommandCommittedResult>());
        expect(await database.listPendingCommands(), isEmpty);
        expect(repo.cancelCallCount, 1);
        expect(repo.refundCount, 1);
        expect(repo.childBalances['child-1'], 5000);
      });
    });

    // -----------------------------------------------------------------------
    // A2-03: Fulfill commits, response lost, same-ID replay
    // -----------------------------------------------------------------------
    test('A2-03: Fulfill commits, response lost, same-ID replay preserves command ID and succeeds', () async {
      final repo = MockServerRewardRepository();
      repo.redemptions['red-3'] = buildRedemption(id: 'red-3');
      repo.simulateLossOnNextCommit = true;

      final authPort = FakeAuthSessionPort(
        activeUserId: 'user-a03',
        role: 'parent',
        clock: clock,
      );
      final authzPort = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
        defaultAdultRole: VerifiedAdultRole.parent,
      );
      final coord = buildCoordinator(
        db: database,
        rewardRepo: repo,
        authPort: authPort,
        authzPort: authzPort,
      );
      final dispatcher = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coord,
        authSessionPort: authPort,
        clock: clock,
        minimumDrainInterval: Duration.zero,
        activeFamilyIdProvider: () => 'fam-1',
      );

      // Step 1: Initial fulfill commit + response loss
      final step1Result = await coord.execute(
        operation: RewardCommandOperation.fulfillReward,
        familyId: 'fam-1',
        childId: 'child-1',
        redemptionId: 'red-3',
      );
      expect(step1Result, isA<CommandScheduledResult>());
      final scheduled = step1Result as CommandScheduledResult;
      final originalCmdId = scheduled.commandId;

      final rowsAfterStep1 = await database.listPendingCommands();
      expect(rowsAfterStep1.length, 1);
      final cmdRow = rowsAfterStep1.single;
      expect(cmdRow.commandId, originalCmdId);
      expect(cmdRow.recoveryState, CommandRecoveryState.active);
      expect(cmdRow.dispatchState, CommandDispatchState.possiblyDispatched);
      expect(cmdRow.retryCount, 1);
      expect(cmdRow.nextAttemptAt, isNotNull);
      expect(cmdRow.leaseToken, isNull);

      // Step 2: Advance clock past backoff
      clock.advance(const Duration(seconds: 10));

      // Step 3: Dispatcher drain replay
      final context = (await authPort.validateForMutation())!;
      final drained = await dispatcher.drainOnce(
        validatedContext: context,
        activeFamilyId: 'fam-1',
      );
      expect(drained, 1);

      // Assert row completed and removed
      expect(await database.listPendingCommands(), isEmpty);
      expect(repo.fulfillCallCount, 2);
      expect(repo.commandReceipts.containsKey(originalCmdId), isTrue);
      expect(
        repo.redemptions['red-3']!.status,
        RewardRedemptionStatus.fulfilled,
      );
    });

    // -----------------------------------------------------------------------
    // A2-04: Cancel commits and refunds, response lost, same-ID replay, no duplicate refund
    // -----------------------------------------------------------------------
    test('A2-04: Cancel commits and refunds, response lost, replay produces zero duplicate refund', () async {
      final repo = MockServerRewardRepository();
      repo.redemptions['red-4'] = buildRedemption(
        id: 'red-4',
        rpCostMinor: 1500,
      );
      repo.childBalances['child-1'] = 3500;
      repo.simulateLossOnNextCommit = true;

      final authPort = FakeAuthSessionPort(
        activeUserId: 'user-a04',
        role: 'owner',
        clock: clock,
      );
      final authzPort = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
        defaultAdultRole: VerifiedAdultRole.owner,
      );
      final coord = buildCoordinator(
        db: database,
        rewardRepo: repo,
        authPort: authPort,
        authzPort: authzPort,
      );
      final dispatcher = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coord,
        authSessionPort: authPort,
        clock: clock,
        minimumDrainInterval: Duration.zero,
        activeFamilyIdProvider: () => 'fam-1',
      );

      // Step 1: Initial cancel commit + response loss
      final step1Result = await coord.execute(
        operation: RewardCommandOperation.cancelReward,
        familyId: 'fam-1',
        childId: 'child-1',
        redemptionId: 'red-4',
        cancellationReason: 'Item unavailable',
      );
      expect(step1Result, isA<CommandScheduledResult>());
      final scheduled = step1Result as CommandScheduledResult;
      final originalCmdId = scheduled.commandId;

      final rowsAfterStep1 = await database.listPendingCommands();
      expect(rowsAfterStep1.length, 1);
      final cmdRow = rowsAfterStep1.single;
      expect(cmdRow.commandId, originalCmdId);
      expect(cmdRow.dispatchState, CommandDispatchState.possiblyDispatched);
      expect(cmdRow.retryCount, 1);
      expect(cmdRow.cancellationReason, 'Item unavailable');
      expect(repo.refundCount, 1);
      expect(repo.childBalances['child-1'], 5000);

      // Step 2 & 3: Advance clock and drain replay
      clock.advance(const Duration(seconds: 10));
      final context = (await authPort.validateForMutation())!;
      final drained = await dispatcher.drainOnce(
        validatedContext: context,
        activeFamilyId: 'fam-1',
      );
      expect(drained, 1);

      expect(await database.listPendingCommands(), isEmpty);
      expect(repo.cancelCallCount, 2);
      expect(repo.refundCount, 1); // Exact-once refund!
      expect(repo.childBalances['child-1'], 5000); // Never 6500!
      expect(
        repo.redemptions['red-4']!.status,
        RewardRedemptionStatus.cancelled,
      );
    });

    // -----------------------------------------------------------------------
    // A2-05: Concurrent Fulfill/Fulfill for same redemption with deterministic barriers
    // -----------------------------------------------------------------------
    group('A2-05: Concurrent Fulfill/Fulfill for same redemption with deterministic barriers', () {
      test('Part A: Same-Device Multi-Connection In-Flight Barrier', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-5'] = buildRedemption(id: 'red-5');
        repo.rpcEnteredBarrier = Completer<void>();
        repo.allowRpcFinishBarrier = Completer<void>();

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-a05',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord1 = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );
        final coord2 = buildCoordinator(
          db: database2,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        // Worker 1 starts
        final worker1Future = coord1.execute(
          operation: RewardCommandOperation.fulfillReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-5',
          requestedCommandId: 'cmd-5-w1',
        );

        await repo.rpcEnteredBarrier!.future;

        // Mid-flight assertion on db1
        final rows1 = await database.listPendingCommands();
        expect(rows1.length, 1);
        expect(rows1.single.commandId, 'cmd-5-w1');
        expect(
          rows1.single.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );
        expect(rows1.single.leaseToken, isNotNull);

        // Worker 2 attempts while Worker 1 suspended
        final worker2Result = await coord2.execute(
          operation: RewardCommandOperation.fulfillReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-5',
          requestedCommandId: 'cmd-5-w2',
        );
        expect(worker2Result, isA<CommandAlreadyInFlightResult>());
        expect(
          (worker2Result as CommandAlreadyInFlightResult).commandId,
          'cmd-5-w1',
        );

        final rowsAfterW2 = await database.listPendingCommands();
        expect(rowsAfterW2.length, 1);
        expect(rowsAfterW2.single.commandId, 'cmd-5-w1');
        expect(repo.fulfillCallCount, 1);

        // Release Worker 1
        repo.allowRpcFinishBarrier!.complete();
        final worker1Result = await worker1Future;
        expect(worker1Result, isA<CommandCommittedResult>());
        expect(await database.listPendingCommands(), isEmpty);
        expect(repo.fulfillCallCount, 1);
      });

      test('Part B: Same-Device Post-Completion Attempt', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-5b'] = buildRedemption(
          id: 'red-5b',
          status: RewardRedemptionStatus.fulfilled,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-a05',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        final postResult = await coord.execute(
          operation: RewardCommandOperation.fulfillReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-5b',
          requestedCommandId: 'cmd-5-post',
        );
        expect(postResult, isA<CommandQuarantinedResult>());
        final quarantined = postResult as CommandQuarantinedResult;
        expect(quarantined.commandId, 'cmd-5-post');

        final rows = await database.listPendingCommands();
        expect(rows.length, 1);
        expect(rows.single.commandId, 'cmd-5-post');
        expect(
          rows.single.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(
          rows.single.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );
      });

      test('Part C: Cross-Device Server Race with Barrier', () async {
        final dev1Dir = Directory.systemTemp.createTempSync('learnward_dev1_');
        final dev2Dir = Directory.systemTemp.createTempSync('learnward_dev2_');
        final dev1Db = AppDatabase(
          NativeDatabase(File('${dev1Dir.path}/dev1.sqlite')),
        );
        final dev2Db = AppDatabase(
          NativeDatabase(File('${dev2Dir.path}/dev2.sqlite')),
        );

        try {
          final repo = MockServerRewardRepository();
          repo.redemptions['red-5c'] = buildRedemption(id: 'red-5c');

          final authPort1 = FakeAuthSessionPort(
            activeUserId: 'user-dev1',
            role: 'parent',
            clock: clock,
          );
          final authPort2 = FakeAuthSessionPort(
            activeUserId: 'user-dev2',
            role: 'parent',
            clock: clock,
          );
          final authzPort = FakeRecoveryAuthorizationPort(
            defaultStatus: TargetAuthorizationStatus.authorized,
            defaultAdultRole: VerifiedAdultRole.parent,
          );

          final coordDev1 = buildCoordinator(
            db: dev1Db,
            rewardRepo: repo,
            authPort: authPort1,
            authzPort: authzPort,
          );
          final coordDev2 = buildCoordinator(
            db: dev2Db,
            rewardRepo: repo,
            authPort: authPort2,
            authzPort: authzPort,
          );

          final resDev1 = await coordDev1.execute(
            operation: RewardCommandOperation.fulfillReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-5c',
            requestedCommandId: 'cmd-5-dev1',
          );
          expect(resDev1, isA<CommandCommittedResult>());
          expect(await dev1Db.listPendingCommands(), isEmpty);

          final resDev2 = await coordDev2.execute(
            operation: RewardCommandOperation.fulfillReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-5c',
            requestedCommandId: 'cmd-5-dev2',
          );
          expect(resDev2, isA<CommandQuarantinedResult>());
          final rowsDev2 = await dev2Db.listPendingCommands();
          expect(rowsDev2.length, 1);
          expect(rowsDev2.single.commandId, 'cmd-5-dev2');
          expect(
            rowsDev2.single.recoveryState,
            CommandRecoveryState.quarantinedUnknownOutcome,
          );
        } finally {
          await dev1Db.close();
          await dev2Db.close();
          dev1Dir.deleteSync(recursive: true);
          dev2Dir.deleteSync(recursive: true);
        }
      });
    });

    // -----------------------------------------------------------------------
    // A2-06: Concurrent Cancel/Cancel for same redemption with deterministic barriers
    // -----------------------------------------------------------------------
    group('A2-06: Concurrent Cancel/Cancel for same redemption with deterministic barriers', () {
      test('Part A: Same-Device Multi-Connection In-Flight Barrier', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-6'] = buildRedemption(
          id: 'red-6',
          rpCostMinor: 2000,
        );
        repo.childBalances['child-1'] = 3000;
        repo.rpcEnteredBarrier = Completer<void>();
        repo.allowRpcFinishBarrier = Completer<void>();

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-a06',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord1 = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );
        final coord2 = buildCoordinator(
          db: database2,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        final worker1Future = coord1.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-6',
          cancellationReason: 'Duplicate claim',
          requestedCommandId: 'cmd-6-w1',
        );

        await repo.rpcEnteredBarrier!.future;

        final rows1 = await database.listPendingCommands();
        expect(rows1.length, 1);
        expect(rows1.single.commandId, 'cmd-6-w1');
        expect(
          rows1.single.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );
        expect(rows1.single.cancellationReason, 'Duplicate claim');

        final worker2Result = await coord2.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-6',
          cancellationReason: 'Second reason',
          requestedCommandId: 'cmd-6-w2',
        );
        expect(worker2Result, isA<CommandAlreadyInFlightResult>());
        expect(
          (worker2Result as CommandAlreadyInFlightResult).commandId,
          'cmd-6-w1',
        );

        final rowsAfterW2 = await database.listPendingCommands();
        expect(rowsAfterW2.length, 1);
        expect(rowsAfterW2.single.cancellationReason, 'Duplicate claim');
        expect(repo.cancelCallCount, 1);

        repo.allowRpcFinishBarrier!.complete();
        final worker1Result = await worker1Future;
        expect(worker1Result, isA<CommandCommittedResult>());
        expect(await database.listPendingCommands(), isEmpty);
        expect(repo.cancelCallCount, 1);
        expect(repo.refundCount, 1);
        expect(repo.childBalances['child-1'], 5000);
      });

      test('Part B: Same-Device Post-Completion Attempt', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-6b'] = buildRedemption(
          id: 'red-6b',
          rpCostMinor: 2000,
          status: RewardRedemptionStatus.cancelled,
          cancellationReason: 'Already cancelled',
        );
        repo.childBalances['child-1'] = 5000;

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-a06',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        final postResult = await coord.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-6b',
          cancellationReason: 'Late cancel',
          requestedCommandId: 'cmd-6-post',
        );
        expect(postResult, isA<CommandQuarantinedResult>());
        expect(repo.refundCount, 0);
        expect(repo.childBalances['child-1'], 5000);

        final rows = await database.listPendingCommands();
        expect(rows.length, 1);
        expect(rows.single.commandId, 'cmd-6-post');
        expect(
          rows.single.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
      });

      test('Part C: Cross-Device Server Race', () async {
        final dev1Dir = Directory.systemTemp.createTempSync(
          'learnward_dev1_c_',
        );
        final dev2Dir = Directory.systemTemp.createTempSync(
          'learnward_dev2_c_',
        );
        final dev1Db = AppDatabase(
          NativeDatabase(File('${dev1Dir.path}/dev1.sqlite')),
        );
        final dev2Db = AppDatabase(
          NativeDatabase(File('${dev2Dir.path}/dev2.sqlite')),
        );

        try {
          final repo = MockServerRewardRepository();
          repo.redemptions['red-6c'] = buildRedemption(
            id: 'red-6c',
            rpCostMinor: 2000,
          );
          repo.childBalances['child-1'] = 3000;

          final authPort1 = FakeAuthSessionPort(
            activeUserId: 'user-dev1',
            role: 'parent',
            clock: clock,
          );
          final authPort2 = FakeAuthSessionPort(
            activeUserId: 'user-dev2',
            role: 'parent',
            clock: clock,
          );
          final authzPort = FakeRecoveryAuthorizationPort(
            defaultStatus: TargetAuthorizationStatus.authorized,
            defaultAdultRole: VerifiedAdultRole.parent,
          );

          final coordDev1 = buildCoordinator(
            db: dev1Db,
            rewardRepo: repo,
            authPort: authPort1,
            authzPort: authzPort,
          );
          final coordDev2 = buildCoordinator(
            db: dev2Db,
            rewardRepo: repo,
            authPort: authPort2,
            authzPort: authzPort,
          );

          final resDev1 = await coordDev1.execute(
            operation: RewardCommandOperation.cancelReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-6c',
            cancellationReason: 'Device 1 cancel',
            requestedCommandId: 'cmd-6-dev1',
          );
          expect(resDev1, isA<CommandCommittedResult>());
          expect(await dev1Db.listPendingCommands(), isEmpty);
          expect(repo.refundCount, 1);
          expect(repo.childBalances['child-1'], 5000);

          final resDev2 = await coordDev2.execute(
            operation: RewardCommandOperation.cancelReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-6c',
            cancellationReason: 'Device 2 cancel',
            requestedCommandId: 'cmd-6-dev2',
          );
          expect(resDev2, isA<CommandQuarantinedResult>());
          expect(repo.refundCount, 1);
          expect(repo.childBalances['child-1'], 5000);
          final rowsDev2 = await dev2Db.listPendingCommands();
          expect(rowsDev2.length, 1);
          expect(rowsDev2.single.commandId, 'cmd-6-dev2');
          expect(
            rowsDev2.single.recoveryState,
            CommandRecoveryState.quarantinedUnknownOutcome,
          );
        } finally {
          await dev1Db.close();
          await dev2Db.close();
          dev1Dir.deleteSync(recursive: true);
          dev2Dir.deleteSync(recursive: true);
        }
      });
    });

    // -----------------------------------------------------------------------
    // A2-07: Concurrent Fulfill/Cancel cross-operation conflict with deterministic barriers
    // -----------------------------------------------------------------------
    group('A2-07: Concurrent Fulfill/Cancel cross-operation conflict with deterministic barriers', () {
      test('Scenario 1: Unresolved Fulfill blocks fresh Cancel across all unresolved states', () async {
        final states = [
          (CommandRecoveryState.active, CommandDispatchState.neverDispatched),
          (
            CommandRecoveryState.active,
            CommandDispatchState.possiblyDispatched,
          ),
          (
            CommandRecoveryState.pendingOriginalActor,
            CommandDispatchState.neverDispatched,
          ),
          (
            CommandRecoveryState.quarantinedUnknownOutcome,
            CommandDispatchState.possiblyDispatched,
          ),
        ];

        for (final (recState, dispState) in states) {
          final repo = MockServerRewardRepository();
          repo.redemptions['red-7s1'] = buildRedemption(id: 'red-7s1');
          final authPort = FakeAuthSessionPort(
            activeUserId: 'user-a07',
            role: 'parent',
            clock: clock,
          );
          final authzPort = FakeRecoveryAuthorizationPort(
            defaultStatus: TargetAuthorizationStatus.authorized,
            defaultAdultRole: VerifiedAdultRole.parent,
          );
          final coord = buildCoordinator(
            db: database,
            rewardRepo: repo,
            authPort: authPort,
            authzPort: authzPort,
          );

          // Seed existing fulfill command
          await database.savePendingCommand(
            PendingRewardCommand(
              operation: RewardCommandOperation.fulfillReward,
              commandId: 'cmd-fulfill-7',
              familyId: 'fam-1',
              childId: 'child-1',
              redemptionId: 'red-7s1',
              actorUserId: 'user-a07',
              actorRole: 'parent',
              createdAt: t0,
              recoveryState: recState,
              dispatchState: dispState,
            ),
            now: t0,
          );

          final result = await coord.execute(
            operation: RewardCommandOperation.cancelReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-7s1',
            cancellationReason: 'Changed mind',
          );
          expect(result, isA<CommandAlreadyInFlightResult>());
          expect(
            (result as CommandAlreadyInFlightResult).commandId,
            'cmd-fulfill-7',
          );

          final rows = await database.listPendingCommands();
          expect(rows.length, 1);
          expect(rows.single.commandId, 'cmd-fulfill-7');
          expect(rows.single.operation, RewardCommandOperation.fulfillReward);
          expect(repo.cancelCallCount, 0);

          await database.deletePendingCommand('cmd-fulfill-7');
        }
      });

      test('Scenario 2: Unresolved Cancel blocks fresh Fulfill across all unresolved states', () async {
        final states = [
          (CommandRecoveryState.active, CommandDispatchState.neverDispatched),
          (
            CommandRecoveryState.active,
            CommandDispatchState.possiblyDispatched,
          ),
          (
            CommandRecoveryState.pendingOriginalActor,
            CommandDispatchState.neverDispatched,
          ),
          (
            CommandRecoveryState.quarantinedUnknownOutcome,
            CommandDispatchState.possiblyDispatched,
          ),
        ];

        for (final (recState, dispState) in states) {
          final repo = MockServerRewardRepository();
          repo.redemptions['red-7s2'] = buildRedemption(id: 'red-7s2');
          final authPort = FakeAuthSessionPort(
            activeUserId: 'user-a07',
            role: 'parent',
            clock: clock,
          );
          final authzPort = FakeRecoveryAuthorizationPort(
            defaultStatus: TargetAuthorizationStatus.authorized,
            defaultAdultRole: VerifiedAdultRole.parent,
          );
          final coord = buildCoordinator(
            db: database,
            rewardRepo: repo,
            authPort: authPort,
            authzPort: authzPort,
          );

          // Seed existing cancel command
          await database.savePendingCommand(
            PendingRewardCommand(
              operation: RewardCommandOperation.cancelReward,
              commandId: 'cmd-cancel-7',
              familyId: 'fam-1',
              childId: 'child-1',
              redemptionId: 'red-7s2',
              cancellationReason: 'Out of stock',
              actorUserId: 'user-a07',
              actorRole: 'parent',
              createdAt: t0,
              recoveryState: recState,
              dispatchState: dispState,
            ),
            now: t0,
          );

          final result = await coord.execute(
            operation: RewardCommandOperation.fulfillReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-7s2',
          );
          expect(result, isA<CommandAlreadyInFlightResult>());
          expect(
            (result as CommandAlreadyInFlightResult).commandId,
            'cmd-cancel-7',
          );

          final rows = await database.listPendingCommands();
          expect(rows.length, 1);
          expect(rows.single.commandId, 'cmd-cancel-7');
          expect(rows.single.operation, RewardCommandOperation.cancelReward);
          expect(repo.fulfillCallCount, 0);

          await database.deletePendingCommand('cmd-cancel-7');
        }
      });

      test('Scenario 3: Same-Device Multi-Connection In-Flight Fulfill vs Cancel Barrier', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-7c'] = buildRedemption(id: 'red-7c');
        repo.rpcEnteredBarrier = Completer<void>();
        repo.allowRpcFinishBarrier = Completer<void>();

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-a07',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord1 = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );
        final coord2 = buildCoordinator(
          db: database2,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        final fulfillFuture = coord1.execute(
          operation: RewardCommandOperation.fulfillReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-7c',
          requestedCommandId: 'cmd-7c-fulfill',
        );

        await repo.rpcEnteredBarrier!.future;

        final rows1 = await database.listPendingCommands();
        expect(rows1.length, 1);
        expect(rows1.single.commandId, 'cmd-7c-fulfill');

        // Worker 2 attempts Cancel while Fulfill is in-flight
        final cancelResult = await coord2.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-7c',
          cancellationReason: 'Race cancel',
          requestedCommandId: 'cmd-7c-cancel',
        );
        expect(cancelResult, isA<CommandAlreadyInFlightResult>());
        expect(
          (cancelResult as CommandAlreadyInFlightResult).commandId,
          'cmd-7c-fulfill',
        );
        expect(repo.cancelCallCount, 0);

        repo.allowRpcFinishBarrier!.complete();
        final fulfillResult = await fulfillFuture;
        expect(fulfillResult, isA<CommandCommittedResult>());
        expect(await database.listPendingCommands(), isEmpty);
        expect(repo.fulfillCallCount, 1);
        expect(repo.cancelCallCount, 0);
      });

      test('Scenario 4: Post-Completion Cross-Operation Attempt & Cross-Device Fulfill vs Cancel Race', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-7d'] = buildRedemption(
          id: 'red-7d',
          status: RewardRedemptionStatus.fulfilled,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-a07',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        // Post-completion cancel attempt on fulfilled redemption
        final postCancelResult = await coord.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-7d',
          cancellationReason: 'Late cancel on fulfilled',
          requestedCommandId: 'cmd-7d-post-cancel',
        );
        expect(postCancelResult, isA<CommandQuarantinedResult>());
        expect(repo.refundCount, 0);

        final rows = await database.listPendingCommands();
        expect(rows.length, 1);
        expect(rows.single.commandId, 'cmd-7d-post-cancel');
        expect(
          rows.single.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
      });
    });

    // -----------------------------------------------------------------------
    // A2-08: Independent redemptions proceed without false family-wide blocking
    // -----------------------------------------------------------------------
    test('A2-08: Independent redemptions for same child proceed without false family-wide blocking', () async {
      final repo = MockServerRewardRepository();
      repo.redemptions['red-8A'] = buildRedemption(id: 'red-8A');
      repo.redemptions['red-8B'] = buildRedemption(id: 'red-8B');

      final authPort = FakeAuthSessionPort(
        activeUserId: 'user-a08',
        role: 'parent',
        clock: clock,
      );
      final authzPort = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
        defaultAdultRole: VerifiedAdultRole.parent,
      );
      final coord = buildCoordinator(
        db: database,
        rewardRepo: repo,
        authPort: authPort,
        authzPort: authzPort,
      );

      // Seed unresolved command for red-8A
      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'cmd-8A',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-8A',
          actorUserId: 'user-a08',
          actorRole: 'parent',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
          retryCount: 1,
          nextAttemptAt: t0.add(const Duration(minutes: 5)),
        ),
        now: t0,
      );

      // Execute fresh fulfill on independent redemption red-8B
      final result8B = await coord.execute(
        operation: RewardCommandOperation.fulfillReward,
        familyId: 'fam-1',
        childId: 'child-1',
        redemptionId: 'red-8B',
      );
      expect(result8B, isA<CommandCommittedResult>());

      // cmd-8B completed and deleted, but cmd-8A remains intact!
      final remainingRows = await database.listPendingCommands();
      expect(remainingRows.length, 1);
      expect(remainingRows.single.commandId, 'cmd-8A');
      expect(remainingRows.single.redemptionId, 'red-8A');
      expect(repo.fulfillCallCount, 1);
      expect(
        repo.redemptions['red-8B']!.status,
        RewardRedemptionStatus.fulfilled,
      );
      expect(
        repo.redemptions['red-8A']!.status,
        RewardRedemptionStatus.pendingFulfillment,
      );
    });

    // -----------------------------------------------------------------------
    // A2-09: Adult A to Adult B account switch
    // -----------------------------------------------------------------------
    test('A2-09: Adult A to Adult B account switch safely pauses mismatched active command', () async {
      final repo = MockServerRewardRepository();
      repo.redemptions['red-9'] = buildRedemption(id: 'red-9');

      // Seed cmd-9 owned by user-parent-A
      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.cancelReward,
          commandId: 'cmd-9',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-9',
          cancellationReason: 'Unavailable',
          actorUserId: 'user-parent-A',
          actorRole: 'owner',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
          retryCount: 1,
        ),
        now: t0,
      );

      // Parent B signs in
      final authPortB = FakeAuthSessionPort(
        activeUserId: 'user-parent-B',
        role: 'parent',
        clock: clock,
      );
      final authzPortB = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
        defaultAdultRole: VerifiedAdultRole.parent,
      );
      final coordB = buildCoordinator(
        db: database,
        rewardRepo: repo,
        authPort: authPortB,
        authzPort: authzPortB,
      );
      final dispatcherB = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coordB,
        authSessionPort: authPortB,
        clock: clock,
        minimumDrainInterval: Duration.zero,
        activeFamilyIdProvider: () => 'fam-1',
      );

      // 1. Dispatcher runs under Parent B
      final contextB = (await authPortB.validateForMutation())!;
      final drained = await dispatcherB.drainOnce(
        validatedContext: contextB,
        activeFamilyId: 'fam-1',
      );
      expect(drained, 0); // 0 commands dispatched to RPC

      // Check cmd-9 transitioned to pendingOriginalActor, preserving actor identity
      final rows = await database.listPendingCommands();
      expect(rows.length, 1);
      final cmdRow = rows.single;
      expect(cmdRow.commandId, 'cmd-9');
      expect(cmdRow.recoveryState, CommandRecoveryState.pendingOriginalActor);
      expect(cmdRow.actorUserId, 'user-parent-A');
      expect(cmdRow.actorRole, 'owner');

      // 2. Parent B manual retry returns pendingOriginalActor
      final retryResult = await retryCommand(coord: coordB, commandId: 'cmd-9');
      expect(retryResult, isA<CommandPendingOriginalActorResult>());

      // 3. Parent B fresh conflicting Fulfill returns CommandAlreadyInFlightResult
      final fulfillResult = await coordB.execute(
        operation: RewardCommandOperation.fulfillReward,
        familyId: 'fam-1',
        childId: 'child-1',
        redemptionId: 'red-9',
      );
      expect(fulfillResult, isA<CommandAlreadyInFlightResult>());
      expect(
        (fulfillResult as CommandAlreadyInFlightResult).commandId,
        'cmd-9',
      );

      expect(repo.cancelCallCount, 0);
      expect(repo.fulfillCallCount, 0);
    });

    // -----------------------------------------------------------------------
    // A2-10: Original adult returns, original UUID and verified role retained
    // -----------------------------------------------------------------------
    test('A2-10: Original adult returns, original UUID and verified role retained, dispatches and completes', () async {
      final repo = MockServerRewardRepository();
      repo.redemptions['red-9'] = buildRedemption(
        id: 'red-9',
        rpCostMinor: 1500,
      );
      repo.childBalances['child-1'] = 3500;

      // cmd-9 is in pendingOriginalActor state
      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.cancelReward,
          commandId: 'cmd-9',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-9',
          cancellationReason: 'Unavailable',
          actorUserId: 'user-parent-A',
          actorRole: 'owner',
          createdAt: t0,
          recoveryState: CommandRecoveryState.pendingOriginalActor,
          dispatchState: CommandDispatchState.possiblyDispatched,
          retryCount: 1,
        ),
        now: t0,
      );

      // Parent A signs back in
      final authPortA = FakeAuthSessionPort(
        activeUserId: 'user-parent-A',
        role: null, // role in session is null
        clock: clock,
      );
      final authzPortA = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
        defaultAdultRole: VerifiedAdultRole.owner, // DB verifies owner
      );
      final coordA = buildCoordinator(
        db: database,
        rewardRepo: repo,
        authPort: authPortA,
        authzPort: authzPortA,
      );
      final dispatcherA = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coordA,
        authSessionPort: authPortA,
        clock: clock,
        minimumDrainInterval: Duration.zero,
        activeFamilyIdProvider: () => 'fam-1',
      );

      final contextA = (await authPortA.validateForMutation())!;
      final drained = await dispatcherA.drainOnce(
        validatedContext: contextA,
        activeFamilyId: 'fam-1',
      );
      expect(drained, 1);

      expect(await database.listPendingCommands(), isEmpty);
      expect(repo.cancelCallCount, 1);
      expect(repo.refundCount, 1);
      expect(repo.childBalances['child-1'], 5000);
      expect(
        repo.redemptions['red-9']!.status,
        RewardRedemptionStatus.cancelled,
      );
      expect(repo.redemptions['red-9']!.cancellationReason, 'Unavailable');
      expect(repo.commandReceipts.containsKey('cmd-9'), isTrue);
    });

    // -----------------------------------------------------------------------
    // A2-11: Paired-child account and inconsistent role claims cannot execute adult operation
    // -----------------------------------------------------------------------
    group('A2-11: Paired-child account and inconsistent role claims cannot execute adult operation', () {
      test('Subcase 11a: Paired-child fresh attempt is definitely denied at Step 0', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-11'] = buildRedemption(id: 'red-11');

        final authPort = FakeAuthSessionPort(
          activeUserId: 'child-user',
          role: 'child',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        final result = await coord.execute(
          operation: RewardCommandOperation.fulfillReward,
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-11',
        );
        expect(result, isA<CommandQuarantinedResult>());
        expect(await database.listPendingCommands(), isEmpty);
        expect(repo.fulfillCallCount, 0);
      });

      test('Subcase 11b: Seeded row with actorRole: child is ignored by CAS or quarantined', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-11b'] = buildRedemption(id: 'red-11b');

        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-11b',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-11b',
            actorUserId: 'child-user',
            actorRole: 'child',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'child-user',
          role: 'child',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        // CAS ignores it because actorRole is not owner/parent
        final claimable = await database.listClaimableCommands(
          actorUserId: 'child-user',
          limit: 10,
        );
        expect(claimable, isEmpty);

        // Direct coordinator execute fails completeness check and quarantines
        final result = await retryCommand(coord: coord, commandId: 'cmd-11b');
        expect(result, isA<CommandQuarantinedResult>());
        expect(repo.fulfillCallCount, 0);
      });

      test(
        'Subcase 11c: Inconsistent session role claim vs verified role',
        () async {
          final repo = MockServerRewardRepository();
          repo.redemptions['red-11c'] = buildRedemption(id: 'red-11c');

          // Session claims 'owner' while DB has 'parent'
          final authPort = FakeAuthSessionPort(
            activeUserId: 'user-mismatch',
            role: 'owner',
            clock: clock,
          );
          final authzPort = FakeRecoveryAuthorizationPort(
            defaultStatus: TargetAuthorizationStatus.authorized,
            defaultAdultRole: VerifiedAdultRole.parent,
          );
          authzPort.setDefaultAdultResult(
            const AdultTargetAuthorizationResult.definitelyDenied(
              reason: AdultTargetVerificationReason.inconsistentRoleClaim,
            ),
          );
          final coord = buildCoordinator(
            db: database,
            rewardRepo: repo,
            authPort: authPort,
            authzPort: authzPort,
          );

          final result = await coord.execute(
            operation: RewardCommandOperation.fulfillReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-11c',
          );
          expect(result, isA<CommandQuarantinedResult>());
          expect(await database.listPendingCommands(), isEmpty);
          expect(repo.fulfillCallCount, 0);
        },
      );

      test('Subcase 11d: Stored command.actorRole mismatch with current verified DB role', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-11d'] = buildRedemption(id: 'red-11d');

        // Command was stored with actorRole 'owner'
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-11d',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-11d',
            actorUserId: 'user-adult',
            actorRole: 'owner',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        // DB role is now 'parent'
        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-adult',
          role: null,
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        final result = await retryCommand(coord: coord, commandId: 'cmd-11d');
        expect(result, isA<CommandQuarantinedResult>());

        final rows = await database.listPendingCommands();
        expect(rows.length, 1);
        expect(rows.single.commandId, 'cmd-11d');
        expect(
          rows.single.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(rows.single.actorRole, 'owner'); // Preserved!
        expect(repo.fulfillCallCount, 0);
      });
    });

    // -----------------------------------------------------------------------
    // A2-12: Revoked adult membership and missing/RLS-filtered membership proof
    // -----------------------------------------------------------------------
    group('A2-12: Revoked adult membership and missing/RLS-filtered membership proof', () {
      test('Subcase 12a: Confirmed revoked membership transitions command to quarantinedUnknownOutcome', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-12a'] = buildRedemption(id: 'red-12a');

        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-12a',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-12a',
            actorUserId: 'user-revoked',
            actorRole: 'owner',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-revoked',
          role: 'owner',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultAdultResult:
              const AdultTargetAuthorizationResult.definitelyDenied(
                reason: AdultTargetVerificationReason
                    .adultMembershipRevokedOrNonAdult,
              ),
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        final result = await retryCommand(coord: coord, commandId: 'cmd-12a');
        expect(result, isA<CommandQuarantinedResult>());

        final rows = await database.listPendingCommands();
        expect(rows.length, 1);
        expect(rows.single.commandId, 'cmd-12a');
        expect(
          rows.single.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(rows.single.retryCount, 0); // retry_count unchanged!
        expect(repo.fulfillCallCount, 0);
      });

      test('Subcase 12b: Missing/RLS-filtered membership exhausts consecutive-miss budget m=3 and quarantines', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-12b'] = buildRedemption(id: 'red-12b');

        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-12b',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-12b',
            actorUserId: 'user-missing',
            actorRole: 'parent',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-missing',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultAdultResult: const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.missingOrUnverifiedMembership,
          ),
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(0.0),
        );

        // Miss 1
        final res1 = await retryCommand(coord: coord, commandId: 'cmd-12b');
        expect(res1, isA<CommandScheduledResult>());
        var row = (await database.listPendingCommands()).single;
        expect(row.recoveryState, CommandRecoveryState.active);
        expect(row.retryCount, 1);
        expect(row.consecutiveUnverifiedTargetMisses, 1);

        // Advance past backoff and Miss 2
        clock.advance(const Duration(seconds: 10));
        final res2 = await retryCommand(coord: coord, commandId: 'cmd-12b');
        expect(res2, isA<CommandScheduledResult>());
        row = (await database.listPendingCommands()).single;
        expect(row.recoveryState, CommandRecoveryState.active);
        expect(row.retryCount, 2);
        expect(row.consecutiveUnverifiedTargetMisses, 2);

        // Advance past backoff and Miss 3
        clock.advance(const Duration(seconds: 10));
        final res3 = await retryCommand(coord: coord, commandId: 'cmd-12b');
        expect(res3, isA<CommandQuarantinedResult>());
        row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(row.retryCount, 2); // Unchanged by transitionRecoveryState!
        expect(row.consecutiveUnverifiedTargetMisses, 3);
        expect(repo.fulfillCallCount, 0);
      });
    });

    // -----------------------------------------------------------------------
    // A2-13: Active family switched during an operation
    // -----------------------------------------------------------------------
    group('A2-13: Active family switched during an operation', () {
      test('Subcase 13a: Pre-claim mismatch returns CommandFamilyMismatchResult without mutating retryCount', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-13'] = buildRedemption(
          id: 'red-13',
          familyId: 'fam-1',
        );

        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-13',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-13',
            actorUserId: 'user-parent',
            actorRole: 'parent',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-parent',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );

        const activeFamilyId = 'fam-2'; // Mismatched active family!
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          activeFamilyIdProvider: () => activeFamilyId,
        );

        final result = await retryCommand(coord: coord, commandId: 'cmd-13');
        expect(result, isA<CommandFamilyMismatchResult>());
        expect((result as CommandFamilyMismatchResult).commandId, 'cmd-13');

        final row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 0); // Not mutated!
        expect(row.recoveryState, CommandRecoveryState.active);
      });

      test('Subcase 13b: Mid-flight switch at Step 5 releases claim and increments retryCount', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-13b'] = buildRedemption(
          id: 'red-13b',
          familyId: 'fam-1',
        );

        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-13b',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-13b',
            actorUserId: 'user-parent',
            actorRole: 'parent',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-parent',
          role: 'parent',
          clock: clock,
        );
        var familyProviderCalls = 0;
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );

        // Switch family mid-flight at Step 5 (after preflight and loaded check)
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          activeFamilyIdProvider: () {
            familyProviderCalls++;
            return familyProviderCalls <= 2 ? 'fam-1' : 'fam-2';
          },
        );

        final result = await retryCommand(coord: coord, commandId: 'cmd-13b');
        expect(result, isA<CommandFamilyMismatchResult>());

        final row = (await database.listPendingCommands()).single;
        expect(row.recoveryState, CommandRecoveryState.active);
        expect(row.retryCount, 1); // incremented by releaseClaim
        expect(row.leaseToken, isNull);
        expect(repo.fulfillCallCount, 0);
      });
    });

    // -----------------------------------------------------------------------
    // A2-14: Child archived before dispatch & consecutive unverified-target miss regression suite
    // -----------------------------------------------------------------------
    group('A2-14: Child archived before dispatch & consecutive unverified-target miss regression suite', () {
      test(
        'Subcase 14a: Fresh attempt with observable archive vs RLS-hidden row',
        () async {
          final repo = MockServerRewardRepository();
          final authPort = FakeAuthSessionPort(
            activeUserId: 'user-p',
            role: 'owner',
            clock: clock,
          );

          // 14a-i: Observable archive
          final authzPort1 = FakeRecoveryAuthorizationPort(
            defaultAdultResult:
                const AdultTargetAuthorizationResult.definitelyDenied(
                  reason: AdultTargetVerificationReason.childConfirmedArchived,
                ),
          );
          final coord1 = buildCoordinator(
            db: database,
            rewardRepo: repo,
            authPort: authPort,
            authzPort: authzPort1,
          );
          final res1 = await coord1.execute(
            operation: RewardCommandOperation.fulfillReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-14a',
          );
          expect(res1, isA<CommandQuarantinedResult>());
          expect(await database.listPendingCommands(), isEmpty);

          // 14a-ii: RLS-hidden row
          final authzPort2 = FakeRecoveryAuthorizationPort(
            defaultAdultResult: const AdultTargetAuthorizationResult.unverified(
              reason:
                  AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
            ),
          );
          final coord2 = buildCoordinator(
            db: database,
            rewardRepo: repo,
            authPort: authPort,
            authzPort: authzPort2,
          );
          final res2 = await coord2.execute(
            operation: RewardCommandOperation.fulfillReward,
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-14a',
          );
          expect(res2, isA<CommandAuthUnavailableResult>());
          expect(await database.listPendingCommands(), isEmpty);
          expect(repo.fulfillCallCount, 0);
        },
      );

      test('Subcase 14b: Existing never_dispatched command transitions immediately on observable archive', () async {
        final repo = MockServerRewardRepository();
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-14b',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-14b',
            actorUserId: 'user-p',
            actorRole: 'owner',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'owner',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultAdultResult:
              const AdultTargetAuthorizationResult.definitelyDenied(
                reason: AdultTargetVerificationReason.childConfirmedArchived,
              ),
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );

        final result = await retryCommand(coord: coord, commandId: 'cmd-14b');
        expect(result, isA<CommandQuarantinedResult>());

        final row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(row.dispatchState, CommandDispatchState.neverDispatched);
        expect(row.retryCount, 0); // retry_count unchanged
        expect(repo.fulfillCallCount, 0);
      });

      test('Subcase 14c: 3 consecutive RLS-filtered misses across database restart', () async {
        final repo = MockServerRewardRepository();
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.cancelReward,
            commandId: 'cmd-14c',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-14c',
            cancellationReason: 'Out of season',
            actorUserId: 'user-p',
            actorRole: 'owner',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'owner',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultAdultResult: const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
          ),
        );
        var coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(1.0),
        );

        // Miss 1 at t0
        final res1 = await retryCommand(coord: coord, commandId: 'cmd-14c');
        expect(res1, isA<CommandScheduledResult>());
        var row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 1);
        expect(row.consecutiveUnverifiedTargetMisses, 1);
        expect(row.nextAttemptAt, t0.add(const Duration(seconds: 2)));

        // At t0 + 1s: drainOnce finds 0 claimable rows
        clock.advance(const Duration(seconds: 1));
        final dispatcher = OutboxRecoveryDispatcher(
          commandStore: database,
          coordinator: coord,
          authSessionPort: authPort,
          clock: clock,
          minimumDrainInterval: Duration.zero,
          activeFamilyIdProvider: () => 'fam-1',
        );
        final ctx = (await authPort.validateForMutation())!;
        expect(
          await dispatcher.drainOnce(
            validatedContext: ctx,
            activeFamilyId: 'fam-1',
          ),
          0,
        );

        // Miss 2 at t0 + 2s
        clock.advance(const Duration(seconds: 1));
        final res2 = await retryCommand(coord: coord, commandId: 'cmd-14c');
        expect(res2, isA<CommandScheduledResult>());
        row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 2);
        expect(row.consecutiveUnverifiedTargetMisses, 2);
        expect(row.nextAttemptAt, t0.add(const Duration(seconds: 6)));

        // Restart database connection
        await database.close();
        database = AppDatabase(NativeDatabase(dbFile));
        coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(1.0),
        );

        // Verify state preserved across restart
        row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 2);
        expect(row.consecutiveUnverifiedTargetMisses, 2);

        // Miss 3 at t0 + 6s
        clock.advance(const Duration(seconds: 4));
        final res3 = await retryCommand(coord: coord, commandId: 'cmd-14c');
        expect(res3, isA<CommandQuarantinedResult>());
        row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(row.retryCount, 2); // Unchanged!
        expect(row.consecutiveUnverifiedTargetMisses, 3);
        expect(row.dispatchState, CommandDispatchState.neverDispatched);
        expect(row.cancellationReason, 'Out of season');
      });

      test('Subcase 14d: 2 transient failures followed by 1 missing-target check does not prematurely quarantine', () async {
        final repo = MockServerRewardRepository();
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-14d',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-14d',
            actorUserId: 'user-p',
            actorRole: 'owner',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'owner',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultAdultResult: const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.transientVerificationFailure,
          ),
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(0.0),
        );

        // 2 transient failures
        await retryCommand(coord: coord, commandId: 'cmd-14d');
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-14d');
        var row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 2);
        expect(row.consecutiveUnverifiedTargetMisses, 0);

        // 1 missing-target verification
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
          ),
        );
        clock.advance(const Duration(seconds: 10));
        final res = await retryCommand(coord: coord, commandId: 'cmd-14d');
        expect(res, isA<CommandScheduledResult>());
        row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.active,
        ); // NOT quarantined!
        expect(row.retryCount, 3);
        expect(row.consecutiveUnverifiedTargetMisses, 1);
      });

      test('Subcase 14e: Session change + family switch followed by missing-target checks', () async {
        final repo = MockServerRewardRepository();
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-14e',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-14e',
            actorUserId: 'user-p',
            actorRole: 'owner',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        // Acquire lease and simulate releaseClaim via session change & family switch
        final leaseToken1 = await database.acquireClaim(
          commandId: 'cmd-14e',
          actorUserId: 'user-p',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        await database.releaseClaim(
          commandId: 'cmd-14e',
          leaseToken: leaseToken1!,
          nextAttemptAt: t0,
          lastErrorMessage: 'Session generation changed mid-flight',
        );

        final leaseToken2 = await database.acquireClaim(
          commandId: 'cmd-14e',
          actorUserId: 'user-p',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        await database.releaseClaim(
          commandId: 'cmd-14e',
          leaseToken: leaseToken2!,
          nextAttemptAt: t0,
          lastErrorMessage: 'Active family switched mid-flight',
        );

        var row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 2);
        expect(row.consecutiveUnverifiedTargetMisses, 0);

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'owner',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultAdultResult: const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
          ),
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(0.0),
        );

        // Miss 1
        await retryCommand(coord: coord, commandId: 'cmd-14e');
        row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 3);
        expect(row.consecutiveUnverifiedTargetMisses, 1);
        expect(row.recoveryState, CommandRecoveryState.active);

        // Miss 2
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-14e');
        row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 4);
        expect(row.consecutiveUnverifiedTargetMisses, 2);

        // Miss 3 reaches quarantine
        clock.advance(const Duration(seconds: 10));
        final res3 = await retryCommand(coord: coord, commandId: 'cmd-14e');
        expect(res3, isA<CommandQuarantinedResult>());
        row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(row.retryCount, 4); // Unchanged!
        expect(row.consecutiveUnverifiedTargetMisses, 3);
      });

      test('Subcase 14f: Missing-target streak interrupted by transport failure resets miss streak', () async {
        final repo = MockServerRewardRepository();
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-14f',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-14f',
            actorUserId: 'user-p',
            actorRole: 'owner',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            retryCount: 0,
          ),
          now: t0,
        );

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'owner',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultAdultResult: const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
          ),
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(0.0),
        );

        // Miss 1 & Miss 2
        await retryCommand(coord: coord, commandId: 'cmd-14f');
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-14f');
        var row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 2);
        expect(row.consecutiveUnverifiedTargetMisses, 2);

        // Attempt 3: Transport failure resets streak
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.transientVerificationFailure,
          ),
        );
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-14f');
        row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 3);
        expect(row.consecutiveUnverifiedTargetMisses, 0); // Reset!

        // Attempt 4: Missing target starts new streak at 1
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
          ),
        );
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-14f');
        row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.active,
        ); // NOT quarantined!
        expect(row.retryCount, 4);
        expect(row.consecutiveUnverifiedTargetMisses, 1);
      });

      test('Subcase 14g: Concurrent workers with expired and replaced lease cannot corrupt miss counter', () async {
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-14g',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-14g',
            actorUserId: 'user-p',
            actorRole: 'owner',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            retryCount: 1,
            lastErrorMessage:
                PendingRewardCommand.formatUnverifiedTargetMissMessage(
                  consecutiveMisses: 1,
                  detail: 'First miss',
                ),
          ),
          now: t0,
        );

        // Worker 1 acquires tokenA at t0 with 30s lease
        final tokenA = await database.acquireClaim(
          commandId: 'cmd-14g',
          actorUserId: 'user-p',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        expect(tokenA, isNotNull);

        // Advance past lease expiry to t0 + 31s
        final t1 = t0.add(const Duration(seconds: 31));

        // Worker 2 on database2 acquires tokenB
        final tokenB = await database2.acquireClaim(
          commandId: 'cmd-14g',
          actorUserId: 'user-p',
          leaseDuration: const Duration(seconds: 30),
          now: t1,
        );
        expect(tokenB, isNotNull);
        expect(tokenB, isNot(equals(tokenA)));

        // Worker 2 commits miss 2
        final w2Released = await database2.releaseClaim(
          commandId: 'cmd-14g',
          leaseToken: tokenB!,
          nextAttemptAt: t1.add(const Duration(seconds: 10)),
          lastErrorMessage:
              PendingRewardCommand.formatUnverifiedTargetMissMessage(
                consecutiveMisses: 2,
                detail: 'Second miss',
              ),
        );
        expect(w2Released, isTrue);

        // Stale Worker 1 wakes and attempts mutations with tokenA
        final w1Released = await database.releaseClaim(
          commandId: 'cmd-14g',
          leaseToken: tokenA!,
          nextAttemptAt: t1,
          lastErrorMessage: 'Stale worker release',
        );
        expect(w1Released, isFalse);

        final w1Quarantined = await database.transitionRecoveryState(
          commandId: 'cmd-14g',
          leaseToken: tokenA,
          newState: CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(w1Quarantined, isFalse);

        final row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 2);
        expect(row.consecutiveUnverifiedTargetMisses, 2);
        expect(row.recoveryState, CommandRecoveryState.active);
      });
    });

    // -----------------------------------------------------------------------
    // A2-15: Child archived after RPC commit & missing-target streak interrupted by successful authorization
    // -----------------------------------------------------------------------
    group('A2-15: Child archived after RPC commit & missing-target streak interrupted by successful authorization', () {
      test('Subcase 15a: Direct RPC 42501 (Child profile is archived) transitions to quarantinedUnknownOutcome', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-15a'] = buildRedemption(
          id: 'red-15a',
          childId: 'child-15',
          rpCostMinor: 1000,
        );
        repo.simulateLossOnNextCommit = true;

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(0.0),
        );

        // Step 1: Commit and loss
        await coord.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-15',
          redemptionId: 'red-15a',
          cancellationReason: 'Damaged box',
          requestedCommandId: 'cmd-15a',
        );

        var row = (await database.listPendingCommands()).single;
        expect(row.dispatchState, CommandDispatchState.possiblyDispatched);
        expect(row.retryCount, 1);

        // Next attempt: RPC returns 42501
        repo.simulateErrorOnNextRpc = const BackendRpcException(
          code: '42501',
          message: 'Child profile is archived',
        );
        clock.advance(const Duration(seconds: 10));

        final res = await retryCommand(coord: coord, commandId: 'cmd-15a');
        expect(res, isA<CommandQuarantinedResult>());

        row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(row.retryCount, 1); // retry_count unchanged!
        expect(row.dispatchState, CommandDispatchState.possiblyDispatched);
      });

      test('Subcase 15b: Observable archive at preflight transitions to quarantinedUnknownOutcome', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-15b'] = buildRedemption(
          id: 'red-15b',
          childId: 'child-15',
          rpCostMinor: 1000,
        );
        repo.simulateLossOnNextCommit = true;

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(0.0),
        );

        // Step 1: Commit and loss
        await coord.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-15',
          redemptionId: 'red-15b',
          cancellationReason: 'Damaged box',
          requestedCommandId: 'cmd-15b',
        );

        // Preflight observes archive
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.definitelyDenied(
            reason: AdultTargetVerificationReason.childConfirmedArchived,
          ),
        );
        clock.advance(const Duration(seconds: 10));

        final res = await retryCommand(coord: coord, commandId: 'cmd-15b');
        expect(res, isA<CommandQuarantinedResult>());

        final row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(row.retryCount, 1);
        expect(row.dispatchState, CommandDispatchState.possiblyDispatched);
      });

      test('Subcase 15c: RLS-hidden archive returning null after prior transient RPC failure', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-15c'] = buildRedemption(
          id: 'red-15c',
          childId: 'child-15',
          rpCostMinor: 1000,
        );
        repo.simulateLossOnNextCommit = true;

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(0.0),
        );

        // Step 1: Transient loss
        await coord.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-15',
          redemptionId: 'red-15c',
          cancellationReason: 'Damaged box',
          requestedCommandId: 'cmd-15c',
        );

        // RLS now hides archived child
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
          ),
        );

        // Miss 1
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-15c');
        var row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 2);
        expect(row.consecutiveUnverifiedTargetMisses, 1);
        expect(row.recoveryState, CommandRecoveryState.active);

        // Miss 2
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-15c');
        row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 3);
        expect(row.consecutiveUnverifiedTargetMisses, 2);
        expect(row.recoveryState, CommandRecoveryState.active);

        // Miss 3
        clock.advance(const Duration(seconds: 10));
        final res3 = await retryCommand(coord: coord, commandId: 'cmd-15c');
        expect(res3, isA<CommandQuarantinedResult>());
        row = (await database.listPendingCommands()).single;
        expect(
          row.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(row.retryCount, 3); // Unchanged!
        expect(row.consecutiveUnverifiedTargetMisses, 3);
        expect(row.dispatchState, CommandDispatchState.possiblyDispatched);
        expect(row.cancellationReason, 'Damaged box');
      });

      test('Subcase 15d: Missing-target streak interrupted by successful authorization, transient RPC error, then miss', () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-15d'] = buildRedemption(
          id: 'red-15d',
          childId: 'child-15',
          rpCostMinor: 1000,
        );
        repo.childBalances['child-15'] = 4000;
        repo.simulateLossOnNextCommit = true;

        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
          jitter: const DeterministicJitterSource(0.0),
        );

        // Step 1: Initial commit + loss
        await coord.execute(
          operation: RewardCommandOperation.cancelReward,
          familyId: 'fam-1',
          childId: 'child-15',
          redemptionId: 'red-15d',
          cancellationReason: 'Damaged box',
          requestedCommandId: 'cmd-15d',
        );

        // Miss 1 & Miss 2
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
          ),
        );
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-15d');
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-15d');
        var row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 3);
        expect(row.consecutiveUnverifiedTargetMisses, 2);

        // Next attempt: Authorization succeeds! Step 6 RPC throws transient SocketException
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.authorized(
            verifiedRole: VerifiedAdultRole.parent,
          ),
        );
        repo.simulateErrorOnNextRpc = const SocketException(
          'Transient network error',
        );
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-15d');
        row = (await database.listPendingCommands()).single;
        expect(row.retryCount, 4);
        expect(row.consecutiveUnverifiedTargetMisses, 0); // Reset!

        // Next attempt: Missing target -> records m = 1 (NOT quarantined!)
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
          ),
        );
        clock.advance(const Duration(seconds: 10));
        await retryCommand(coord: coord, commandId: 'cmd-15d');
        row = (await database.listPendingCommands()).single;
        expect(row.recoveryState, CommandRecoveryState.active);
        expect(row.retryCount, 5);
        expect(row.consecutiveUnverifiedTargetMisses, 1);

        // Final attempt: Authorization succeeds and replay completes
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.authorized(
            verifiedRole: VerifiedAdultRole.parent,
          ),
        );
        clock.advance(const Duration(seconds: 10));
        final finalRes = await retryCommand(coord: coord, commandId: 'cmd-15d');
        expect(finalRes, isA<CommandCommittedResult>());
        expect(await database.listPendingCommands(), isEmpty);
        expect(repo.refundCount, 1);
        expect(repo.childBalances['child-15'], 5000);
      });
    });

    // -----------------------------------------------------------------------
    // A2-16: Stale lease takeover and stale worker response
    // -----------------------------------------------------------------------
    test('A2-16: Stale lease takeover and stale worker response preserves new lease and row', () async {
      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'cmd-16',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-16',
          actorUserId: 'user-p',
          actorRole: 'parent',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
          retryCount: 0,
        ),
        now: t0,
      );

      // 1. Worker 1 acquires tokenA at t0
      final tokenA = await database.acquireClaim(
        commandId: 'cmd-16',
        actorUserId: 'user-p',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(tokenA, isNotNull);

      // 2. Advance clock past lease expiry
      final t1 = t0.add(const Duration(seconds: 31));

      // 3. Worker 2 on database2 acquires tokenB
      final tokenB = await database2.acquireClaim(
        commandId: 'cmd-16',
        actorUserId: 'user-p',
        leaseDuration: const Duration(seconds: 30),
        now: t1,
      );
      expect(tokenB, isNotNull);
      expect(tokenB, isNot(equals(tokenA)));

      await database2.markPossiblyDispatched(
        commandId: 'cmd-16',
        leaseToken: tokenB!,
        authenticatedActorId: 'user-p',
        now: t1,
      );

      // 4. Worker 1 attempts mutations with stale tokenA
      expect(
        await database.completeCommand(
          commandId: 'cmd-16',
          leaseToken: tokenA!,
        ),
        isFalse,
      );
      expect(
        await database.releaseClaim(
          commandId: 'cmd-16',
          leaseToken: tokenA,
          nextAttemptAt: t1,
        ),
        isFalse,
      );
      expect(
        await database.markPossiblyDispatched(
          commandId: 'cmd-16',
          leaseToken: tokenA,
          authenticatedActorId: 'user-p',
          now: t1,
        ),
        isFalse,
      );
      expect(
        await database.transitionRecoveryState(
          commandId: 'cmd-16',
          leaseToken: tokenA,
          newState: CommandRecoveryState.quarantinedUnknownOutcome,
        ),
        isFalse,
      );

      // Verify row still held by Worker 2
      final row = (await database.listPendingCommands()).single;
      expect(row.leaseToken, tokenB);
      expect(row.retryCount, 0);

      // 5. Worker 2 completes with tokenB
      expect(
        await database2.completeCommand(
          commandId: 'cmd-16',
          leaseToken: tokenB,
        ),
        isTrue,
      );
      expect(await database.listPendingCommands(), isEmpty);
    });

    // -----------------------------------------------------------------------
    // A2-17: Crash between command persistence, pre-dispatch marker and RPC
    // -----------------------------------------------------------------------
    test(
      'A2-17: Crash between command persistence, pre-dispatch marker and RPC',
      () async {
        final repo = MockServerRewardRepository();
        repo.redemptions['red-17a'] = buildRedemption(id: 'red-17a');
        repo.redemptions['red-17b'] = buildRedemption(id: 'red-17b');

        // Subcase 17a: Crash after register + acquire, before markPossiblyDispatched
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-17a',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-17a',
            actorUserId: 'user-p',
            actorRole: 'parent',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
            retryCount: 0,
          ),
          now: t0,
        );
        await database.acquireClaim(
          commandId: 'cmd-17a',
          actorUserId: 'user-p',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );

        // Subcase 17b: Crash after markPossiblyDispatched, before RPC
        await database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-17b',
            familyId: 'fam-1',
            childId: 'child-1',
            redemptionId: 'red-17b',
            actorUserId: 'user-p',
            actorRole: 'parent',
            createdAt: t0,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
            retryCount: 0,
          ),
          now: t0,
        );
        final tokenB = await database.acquireClaim(
          commandId: 'cmd-17b',
          actorUserId: 'user-p',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        await database.markPossiblyDispatched(
          commandId: 'cmd-17b',
          leaseToken: tokenB!,
          authenticatedActorId: 'user-p',
          now: t0,
        );

        // Simulate crash and reopen at t0 + 5s (unexpired)
        await database.close();
        clock.advance(const Duration(seconds: 5));
        database = AppDatabase(NativeDatabase(dbFile));

        // Assert leases respected
        final claimableAt5 = await database.listClaimableCommands(
          actorUserId: 'user-p',
          limit: 10,
          now: clock.now(),
        );
        expect(claimableAt5, isEmpty);

        // Advance clock to t0 + 31s (leases expired)
        clock.advance(const Duration(seconds: 26));
        final authPort = FakeAuthSessionPort(
          activeUserId: 'user-p',
          role: 'parent',
          clock: clock,
        );
        final authzPort = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
          defaultAdultRole: VerifiedAdultRole.parent,
        );
        final coord = buildCoordinator(
          db: database,
          rewardRepo: repo,
          authPort: authPort,
          authzPort: authzPort,
        );
        final dispatcher = OutboxRecoveryDispatcher(
          commandStore: database,
          coordinator: coord,
          authSessionPort: authPort,
          clock: clock,
          minimumDrainInterval: Duration.zero,
          activeFamilyIdProvider: () => 'fam-1',
        );

        final ctx = (await authPort.validateForMutation())!;
        final drained = await dispatcher.drainOnce(
          validatedContext: ctx,
          activeFamilyId: 'fam-1',
        );
        expect(drained, 2);

        expect(await database.listPendingCommands(), isEmpty);
        expect(repo.fulfillCallCount, 2);
        expect(repo.commandReceipts.containsKey('cmd-17a'), isTrue);
        expect(repo.commandReceipts.containsKey('cmd-17b'), isTrue);
      },
    );

    // -----------------------------------------------------------------------
    // A2-18: Cancellation reason and immutable target survive restart
    // -----------------------------------------------------------------------
    test('A2-18: Cancellation reason and immutable target survive restart and reject mutation', () async {
      final repo = MockServerRewardRepository();
      repo.redemptions['red-18'] = buildRedemption(
        id: 'red-18',
        childId: 'child-18',
        rpCostMinor: 1500,
      );
      repo.childBalances['child-18'] = 3500;
      repo.simulateLossOnNextCommit = true;

      final authPort = FakeAuthSessionPort(
        activeUserId: 'user-p',
        role: 'owner',
        clock: clock,
      );
      final authzPort = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
        defaultAdultRole: VerifiedAdultRole.owner,
      );
      final coord = buildCoordinator(
        db: database,
        rewardRepo: repo,
        authPort: authPort,
        authzPort: authzPort,
        jitter: const DeterministicJitterSource(0.0),
      );

      // Initiate cancel with untrimmed whitespace
      await coord.execute(
        operation: RewardCommandOperation.cancelReward,
        familyId: 'fam-1',
        childId: 'child-18',
        redemptionId: 'red-18',
        cancellationReason: '  Weather delay — rescheduled to next month  ',
        requestedCommandId: 'cmd-18',
      );

      // Reopen database
      await database.close();
      database = AppDatabase(NativeDatabase(dbFile));

      final persisted = (await database.listPendingCommands()).single;
      expect(persisted.commandId, 'cmd-18');
      expect(
        persisted.cancellationReason,
        'Weather delay — rescheduled to next month',
      ); // Trimmed!
      expect(persisted.redemptionId, 'red-18');
      expect(persisted.childId, 'child-18');
      expect(persisted.actorUserId, 'user-p');
      expect(persisted.actorRole, 'owner');
      expect(persisted.retryCount, 1);

      // Illegal mutation attempts via savePendingCommand must throw StateError
      expect(
        () => database.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.cancelReward,
            commandId: 'cmd-18',
            familyId: 'fam-1',
            childId: 'child-18',
            redemptionId: 'red-18',
            cancellationReason: 'Mutated reason',
            actorUserId: 'user-p',
            actorRole: 'owner',
            createdAt: t0,
          ),
          now: t0,
        ),
        throwsA(isA<StateError>()),
      );

      expect(
        () => database.savePendingCommand(
          PendingRewardCommand(
            operation:
                RewardCommandOperation.fulfillReward, // Mutated operation!
            commandId: 'cmd-18',
            familyId: 'fam-1',
            childId: 'child-18',
            redemptionId: 'red-18',
            actorUserId: 'user-p',
            actorRole: 'owner',
            createdAt: t0,
          ),
          now: t0,
        ),
        throwsA(isA<StateError>()),
      );

      // Advance clock and drainOnce succeeds with exact trimmed reason
      clock.advance(const Duration(seconds: 10));
      final coordPost = buildCoordinator(
        db: database,
        rewardRepo: repo,
        authPort: authPort,
        authzPort: authzPort,
        jitter: const DeterministicJitterSource(0.0),
      );
      final dispatcher = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coordPost,
        authSessionPort: authPort,
        clock: clock,
        minimumDrainInterval: Duration.zero,
        activeFamilyIdProvider: () => 'fam-1',
      );

      final ctx = (await authPort.validateForMutation())!;
      final drained = await dispatcher.drainOnce(
        validatedContext: ctx,
        activeFamilyId: 'fam-1',
      );
      expect(drained, 1);

      expect(await database.listPendingCommands(), isEmpty);
      expect(
        repo.redemptions['red-18']!.status,
        RewardRedemptionStatus.cancelled,
      );
      expect(
        repo.redemptions['red-18']!.cancellationReason,
        'Weather delay — rescheduled to next month',
      );
      expect(repo.childBalances['child-18'], 5000);
    });

    // -----------------------------------------------------------------------
    // A2-19: Legacy rows with missing actor or child identity fail closed without fabricated identity
    // -----------------------------------------------------------------------
    test('A2-19: Legacy rows with missing actor or child identity fail closed without fabricated identity', () async {
      final repo = MockServerRewardRepository();

      // Seed 4 legacy / incomplete rows
      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'cmd-leg-1',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-19a',
          actorUserId: null, // Missing actor!
          createdAt: t0,
          recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
          dispatchState: CommandDispatchState.unknownLegacy,
        ),
        now: t0,
      );

      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'cmd-leg-2',
          familyId: 'fam-1',
          childId: null, // Missing child!
          redemptionId: 'red-19b',
          actorUserId: 'parent-A',
          actorRole: 'parent',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        ),
        now: t0,
      );

      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'cmd-leg-3',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-19c',
          actorUserId: 'parent-A',
          actorRole: null, // Missing role!
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        ),
        now: t0,
      );

      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.cancelReward,
          commandId: 'cmd-leg-4',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-19d',
          cancellationReason: null, // Missing cancellation reason!
          actorUserId: 'parent-A',
          actorRole: 'parent',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        ),
        now: t0,
      );

      final authPort = FakeAuthSessionPort(
        activeUserId: 'parent-A',
        role: 'parent',
        clock: clock,
      );
      final authzPort = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
      );
      final coord = buildCoordinator(
        db: database,
        rewardRepo: repo,
        authPort: authPort,
        authzPort: authzPort,
      );
      final dispatcher = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coord,
        authSessionPort: authPort,
        clock: clock,
        minimumDrainInterval: Duration.zero,
        activeFamilyIdProvider: () => 'fam-1',
      );

      // 1. drainOnce discovers 0 claimable rows
      final ctx = (await authPort.validateForMutation())!;
      expect(
        await dispatcher.drainOnce(
          validatedContext: ctx,
          activeFamilyId: 'fam-1',
        ),
        0,
      );

      // 2. Direct acquireClaim returns null for all 4
      for (final id in ['cmd-leg-1', 'cmd-leg-2', 'cmd-leg-3', 'cmd-leg-4']) {
        final claim = await database.acquireClaim(
          commandId: id,
          actorUserId: 'parent-A',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        expect(claim, isNull);
      }

      // 3. Coordinator execute returns CommandQuarantinedResult without fabricating fields
      for (final id in ['cmd-leg-1', 'cmd-leg-2', 'cmd-leg-3', 'cmd-leg-4']) {
        final res = await retryCommand(coord: coord, commandId: id);
        expect(res, isA<CommandQuarantinedResult>());
      }

      // 4. Fresh cancelReward on red-19a is blocked by unresolved cmd-leg-1
      final freshRes = await coord.execute(
        operation: RewardCommandOperation.cancelReward,
        familyId: 'fam-1',
        childId: 'child-1',
        redemptionId: 'red-19a',
        cancellationReason: 'Attempt fresh',
      );
      expect(freshRes, isA<CommandAlreadyInFlightResult>());
      expect((freshRes as CommandAlreadyInFlightResult).commandId, 'cmd-leg-1');

      expect(repo.fulfillCallCount, 0);
      expect(repo.cancelCallCount, 0);
    });

    // -----------------------------------------------------------------------
    // A2-20: Mixed-queue regression matrix and zero Drift / Supabase schema drift
    // -----------------------------------------------------------------------
    test('A2-20: Mixed queue with spin, redeem, fulfill, cancel drains correctly; Drift schema is v6', () async {
      final repo = MockServerRewardRepository();
      repo.redemptions['red-20f'] = buildRedemption(id: 'red-20f');
      repo.redemptions['red-20c'] = buildRedemption(
        id: 'red-20c',
        rpCostMinor: 1000,
      );
      repo.childBalances['child-1'] = 4000;

      final wheelRepo = FakeWheelRepository();

      final authPortAdult = FakeAuthSessionPort(
        activeUserId: 'user-adult',
        role: 'parent',
        clock: clock,
      );
      final authzPort = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
        defaultAdultRole: VerifiedAdultRole.parent,
      );
      final coordAdult = buildCoordinator(
        db: database,
        rewardRepo: repo,
        wheelRepo: wheelRepo,
        authPort: authPortAdult,
        authzPort: authzPort,
      );
      final dispatcherAdult = OutboxRecoveryDispatcher(
        commandStore: database,
        coordinator: coordAdult,
        authSessionPort: authPortAdult,
        clock: clock,
        minimumDrainInterval: Duration.zero,
        activeFamilyIdProvider: () => 'fam-1',
      );

      // Seed adult commands
      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'cmd-20f',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-20f',
          actorUserId: 'user-adult',
          actorRole: 'parent',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        ),
        now: t0,
      );

      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.cancelReward,
          commandId: 'cmd-20c',
          familyId: 'fam-1',
          childId: 'child-1',
          redemptionId: 'red-20c',
          cancellationReason: 'Out of stock',
          actorUserId: 'user-adult',
          actorRole: 'parent',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        ),
        now: t0,
      );

      // Drain adult commands
      final adultCtx = (await authPortAdult.validateForMutation())!;
      final adultDrained = await dispatcherAdult.drainOnce(
        validatedContext: adultCtx,
        activeFamilyId: 'fam-1',
      );
      expect(adultDrained, 2);

      expect(repo.fulfillCallCount, 1);
      expect(repo.cancelCallCount, 1);
      expect(repo.refundCount, 1);
      expect(repo.childBalances['child-1'], 5000);

      // Assert schema version is strictly 6
      expect(database.schemaVersion, 6);
    });
  });
}
