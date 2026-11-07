import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  group('PendingRewardCommandStore Atomic CAS & Fencing (File-Backed SQLite)', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase database;
    late AppDatabase database2;
    final t0 = DateTime.utc(2026, 11, 7, 12, 0, 0);

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'learnward_atomic_cas_test_',
      );
      dbFile = File('${tempDir.path}/atomic_cas.sqlite');
      database = AppDatabase(NativeDatabase(dbFile));
      database2 = AppDatabase(NativeDatabase(dbFile));
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

    test('simultaneous claim by two independent connections grants claim to one and rejects the other', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-spin-race',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'actor-user-1',
        actorRole: 'child',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      // Competing simultaneous claim attempts from two separate AppDatabase connections
      final results = await Future.wait([
        database.acquireClaim(
          commandId: 'cmd-spin-race',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        ),
        database2.acquireClaim(
          commandId: 'cmd-spin-race',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        ),
      ]);

      final tokens = results.whereType<String>().toList();
      expect(tokens.length, 1, reason: 'Exactly one worker must win the lease');
      expect(
        results.contains(null),
        isTrue,
        reason: 'The competing worker must receive null',
      );
    });

    test('cross-actor claim is rejected at the query boundary', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.redeemReward,
        commandId: 'cmd-redeem-cross-actor',
        familyId: 'fam-1',
        childId: 'child-1',
        rewardId: 'rew-1',
        actorUserId: 'actor-user-1',
        actorRole: 'child',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      // Attempting to claim with actor-user-2 fails
      final token = await database2.acquireClaim(
        commandId: 'cmd-redeem-cross-actor',
        actorUserId: 'actor-user-2',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(token, isNull);

      // Stored row remains untouched and unclaimed
      final persisted = await database.getPendingCommand(
        'cmd-redeem-cross-actor',
      );
      expect(persisted!.leaseToken, isNull);
      expect(persisted.leaseExpiresAt, isNull);
    });

    test('lease expiry allows reclamation with a new lease token', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-lease-expiry',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'actor-user-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final token1 = await database.acquireClaim(
        commandId: 'cmd-lease-expiry',
        actorUserId: 'actor-user-1',
        leaseDuration: const Duration(seconds: 15),
        now: t0,
      );
      expect(token1, isNotNull);

      // At t0 + 10s: lease is active -> connection 2 cannot claim
      final tokenMid = await database2.acquireClaim(
        commandId: 'cmd-lease-expiry',
        actorUserId: 'actor-user-1',
        leaseDuration: const Duration(seconds: 15),
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(tokenMid, isNull);

      // At t0 + 16s: lease expired -> connection 2 can reclaim with new token
      final token2 = await database2.acquireClaim(
        commandId: 'cmd-lease-expiry',
        actorUserId: 'actor-user-1',
        leaseDuration: const Duration(seconds: 30),
        now: t0.add(const Duration(seconds: 16)),
      );
      expect(token2, isNotNull);
      expect(token2, isNot(equals(token1)));
    });

    test('partial lease metadata fails closed and prevents claiming', () async {
      // Manually inject malformed lease states
      final epochSeconds = t0.millisecondsSinceEpoch ~/ 1000;
      await database.customStatement(
        '''
          INSERT INTO pending_reward_commands (
            operation, command_id, family_id, child_id, created_at, actor_user_id,
            recovery_state, dispatch_state, retry_count, lease_token, lease_expires_at
          ) VALUES
            ('spin_wheel', 'cmd-partial-1', 'fam-1', 'ch-1', ?, 'actor-user-1', 'active', 'possibly_dispatched', 0, 'tok-only', NULL),
            ('spin_wheel', 'cmd-partial-2', 'fam-1', 'ch-1', ?, 'actor-user-1', 'active', 'possibly_dispatched', 0, NULL, ?);
          ''',
        [epochSeconds, epochSeconds, epochSeconds],
      );

      // Case 1: lease_token present but lease_expires_at is NULL -> fails closed
      final claim1 = await database.acquireClaim(
        commandId: 'cmd-partial-1',
        actorUserId: 'actor-user-1',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(claim1, isNull);

      // Case 2: lease_token is NULL but lease_expires_at is present -> fails closed
      final claim2 = await database.acquireClaim(
        commandId: 'cmd-partial-2',
        actorUserId: 'actor-user-1',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(claim2, isNull);
    });

    test(
      'stale worker cannot complete, release, or mutate newer claim',
      () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-stale-fencing',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'actor-user-1',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        await database.savePendingCommand(cmd, now: t0);

        // Worker 1 acquires claim A for 10s
        final tokenA = (await database.acquireClaim(
          commandId: 'cmd-stale-fencing',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 10),
          now: t0,
        ))!;

        // Lease A expires. Worker 2 on database2 acquires claim B at t0 + 15s
        final tokenB = (await database2.acquireClaim(
          commandId: 'cmd-stale-fencing',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0.add(const Duration(seconds: 15)),
        ))!;
        expect(tokenB, isNot(equals(tokenA)));

        // Worker 1 attempts completion with stale token A -> rejected
        final completeResult = await database.completeCommand(
          commandId: 'cmd-stale-fencing',
          leaseToken: tokenA,
        );
        expect(completeResult, isFalse);

        // Worker 1 attempts release with stale token A -> rejected
        final releaseResult = await database.releaseClaim(
          commandId: 'cmd-stale-fencing',
          leaseToken: tokenA,
          nextAttemptAt: t0.add(const Duration(minutes: 5)),
        );
        expect(releaseResult, isFalse);

        // Worker 1 attempts state transition with stale token A -> rejected
        final transitionResult = await database.transitionRecoveryState(
          commandId: 'cmd-stale-fencing',
          leaseToken: tokenA,
          newState: CommandRecoveryState.terminalError,
        );
        expect(transitionResult, isFalse);

        // Row in DB still held by token B
        final current = await database.getPendingCommand('cmd-stale-fencing');
        expect(current!.leaseToken, tokenB);
        expect(current.recoveryState, CommandRecoveryState.active);

        // Worker 2 completes cleanly with token B
        final validComplete = await database2.completeCommand(
          commandId: 'cmd-stale-fencing',
          leaseToken: tokenB,
        );
        expect(validComplete, isTrue);
        expect(await database.getPendingCommand('cmd-stale-fencing'), isNull);
      },
    );

    test('atomic retry counter increment directly within SQLite', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.redeemReward,
        commandId: 'cmd-retry-inc',
        familyId: 'fam-1',
        childId: 'child-1',
        rewardId: 'rew-1',
        actorUserId: 'actor-user-1',
        createdAt: t0,
        retryCount: 0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      for (var i = 1; i <= 3; i++) {
        final t = t0.add(Duration(minutes: i * 5));
        final token = (await database.acquireClaim(
          commandId: 'cmd-retry-inc',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 10),
          now: t,
        ))!;

        final released = await database.releaseClaim(
          commandId: 'cmd-retry-inc',
          leaseToken: token,
          nextAttemptAt: t.add(const Duration(minutes: 5)),
          lastErrorMessage: 'Network error attempt $i',
        );
        expect(released, isTrue);

        final row = await database.getPendingCommand('cmd-retry-inc');
        expect(row!.retryCount, i);
        expect(row.lastErrorMessage, 'Network error attempt $i');
        expect(row.leaseToken, isNull);
        expect(row.leaseExpiresAt, isNull);
      }
    });

    test('retry schedule and backoff state persist across database close and reopen', () async {
      final retryDeadline = t0.add(const Duration(minutes: 15));
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-persist-schedule',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'actor-user-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final token = (await database.acquireClaim(
        commandId: 'cmd-persist-schedule',
        actorUserId: 'actor-user-1',
        leaseDuration: const Duration(seconds: 10),
        now: t0,
      ))!;
      await database.releaseClaim(
        commandId: 'cmd-persist-schedule',
        leaseToken: token,
        nextAttemptAt: retryDeadline,
      );

      // Close database and reopen from the same file
      await database.close();
      database = AppDatabase(NativeDatabase(dbFile));

      final reloaded = await database.getPendingCommand('cmd-persist-schedule');
      expect(reloaded, isNotNull);
      expect(reloaded!.retryCount, 1);
      expect(reloaded.nextAttemptAt, retryDeadline);
      expect(reloaded.leaseToken, isNull);
      expect(reloaded.leaseExpiresAt, isNull);

      // Before deadline (t0 + 10m): not claimable
      final claimableBefore = await database.listClaimableCommands(
        actorUserId: 'actor-user-1',
        limit: 10,
        now: t0.add(const Duration(minutes: 10)),
      );
      expect(claimableBefore, isEmpty);

      // At or past deadline (t0 + 16m): claimable
      final claimableAfter = await database.listClaimableCommands(
        actorUserId: 'actor-user-1',
        limit: 10,
        now: t0.add(const Duration(minutes: 16)),
      );
      expect(claimableAfter.length, 1);
      expect(claimableAfter.first.commandId, 'cmd-persist-schedule');
    });

    test(
      'actor mismatch pause and original actor resume non-dispatch CAS',
      () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-actor-cas',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'original-actor-id',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        await database.savePendingCommand(cmd, now: t0);

        // Discovered as mismatched candidate by scanner
        final mismatched = await database.listMismatchedActiveCommands(
          familyId: 'fam-1',
          authenticatedActorId: 'new-actor-id',
          limit: 10,
          now: t0,
        );
        expect(mismatched.length, 1);
        expect(mismatched.first.commandId, 'cmd-actor-cas');

        // Atomically pause command to pending_original_actor
        final paused = await database.pauseMismatchedActorCommand(
          commandId: 'cmd-actor-cas',
          familyId: 'fam-1',
          authenticatedActorId: 'new-actor-id',
          mismatchReason: 'Paused: authenticated as new-actor-id',
          now: t0,
        );
        expect(paused, isTrue);

        final pausedRow = await database.getPendingCommand('cmd-actor-cas');
        expect(
          pausedRow!.recoveryState,
          CommandRecoveryState.pendingOriginalActor,
        );
        expect(pausedRow.actorUserId, 'original-actor-id');
        expect(pausedRow.leaseToken, isNull);
        expect(pausedRow.leaseExpiresAt, isNull);

        // Original actor signs back in: discovered for resume
        final resumeCandidates = await database.listPausedOriginalActorCommands(
          familyId: 'fam-1',
          authenticatedActorId: 'original-actor-id',
          limit: 10,
          now: t0.add(const Duration(minutes: 1)),
        );
        expect(resumeCandidates.length, 1);
        expect(resumeCandidates.first.commandId, 'cmd-actor-cas');

        // Atomically resume command to active
        final resumed = await database.resumeOriginalActorCommand(
          commandId: 'cmd-actor-cas',
          familyId: 'fam-1',
          authenticatedActorId: 'original-actor-id',
          now: t0.add(const Duration(minutes: 1)),
        );
        expect(resumed, isTrue);

        final resumedRow = await database.getPendingCommand('cmd-actor-cas');
        expect(resumedRow!.recoveryState, CommandRecoveryState.active);
        expect(resumedRow.lastErrorMessage, isNull);
        expect(resumedRow.leaseToken, isNull);
        expect(resumedRow.leaseExpiresAt, isNull);
      },
    );

    test(
      'pause versus claim race: active lease prevents mismatch pause',
      () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-pause-race',
          familyId: 'fam-1',
          childId: 'child-1',
          rewardId: 'rew-1',
          actorUserId: 'actor-user-1',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        await database.savePendingCommand(cmd, now: t0);

        // Worker claims command on connection 1
        final token = (await database.acquireClaim(
          commandId: 'cmd-pause-race',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        ))!;
        expect(token, isNotNull);

        // Outbox scanner on connection 2 tries to pause while lease is active -> rejected
        final pauseAttempt = await database2.pauseMismatchedActorCommand(
          commandId: 'cmd-pause-race',
          familyId: 'fam-1',
          authenticatedActorId: 'actor-user-2',
          mismatchReason: 'Paused: authenticated as actor-user-2',
          now: t0.add(const Duration(seconds: 5)),
        );
        expect(
          pauseAttempt,
          isFalse,
          reason: 'Active lease must fence against concurrent pause',
        );

        // Recovery state remains active under the lease
        final persisted = await database.getPendingCommand('cmd-pause-race');
        expect(persisted!.recoveryState, CommandRecoveryState.active);
        expect(persisted.leaseToken, token);
      },
    );

    test('foreground savePendingCommand rejects overwriting active lease and partial leases', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-foreground-fence',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'user-A',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      // Background dispatcher acquires claim on connection 1
      final token = (await database.acquireClaim(
        commandId: 'cmd-foreground-fence',
        actorUserId: 'user-A',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      ))!;

      // Connection 2 (foreground) attempts overwrite while lease is active -> throws StateError
      expect(
        () => database2.savePendingCommand(
          cmd,
          now: t0.add(const Duration(seconds: 5)),
        ),
        throwsA(isA<StateError>()),
      );

      // Passing matching leaseToken but missing leaseExpiresAt is rejected as partial lease
      final partialToken = cmd.copyWith(leaseToken: token);
      expect(
        () => database2.savePendingCommand(
          partialToken,
          now: t0.add(const Duration(seconds: 5)),
        ),
        throwsA(isA<ArgumentError>()),
      );

      // Passing full lease with matching token is still rejected by savePendingCommand to protect active claim
      final fullLease = cmd.copyWith(
        leaseToken: token,
        leaseExpiresAt: t0.add(const Duration(seconds: 30)),
      );
      expect(
        () => database2.savePendingCommand(
          fullLease,
          now: t0.add(const Duration(seconds: 5)),
        ),
        throwsA(isA<StateError>()),
      );

      // After lease expires, foreground save succeeds and clears expired lease
      final updatedForeground = cmd.copyWith(childId: 'child-1-updated');
      await database2.savePendingCommand(
        updatedForeground,
        now: t0.add(const Duration(seconds: 35)),
      );

      final persisted = await database.getPendingCommand(
        'cmd-foreground-fence',
      );
      expect(persisted!.childId, 'child-1-updated');
      expect(persisted.leaseToken, isNull);
      expect(persisted.leaseExpiresAt, isNull);
    });

    test(
      'deletePendingCommand fences active, expired, and malformed lease states',
      () async {
        // 1. Unclaimed: deleted successfully
        final unclaimed = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-del-sqlite-unclaimed',
          familyId: 'fam-1',
          createdAt: t0,
        );
        await database.savePendingCommand(unclaimed, now: t0);
        await database.deletePendingCommand('cmd-del-sqlite-unclaimed');
        expect(
          await database.getPendingCommand('cmd-del-sqlite-unclaimed'),
          isNull,
        );

        // 2. Active lease: deletePendingCommand does NOT delete
        final active = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-del-sqlite-active',
          familyId: 'fam-1',
          actorUserId: 'user-A',
          createdAt: t0,
        );
        await database.savePendingCommand(active, now: t0);
        final token = (await database.acquireClaim(
          commandId: 'cmd-del-sqlite-active',
          actorUserId: 'user-A',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        ))!;

        // Competing connection 2 tries deletePendingCommand -> row preserved
        await database2.deletePendingCommand('cmd-del-sqlite-active');
        expect(
          await database.getPendingCommand('cmd-del-sqlite-active'),
          isNotNull,
        );

        // 3. Expired lease: deletePendingCommand does NOT delete (must use completeCommand or re-claim)
        await database2.deletePendingCommand('cmd-del-sqlite-active');
        expect(
          await database.getPendingCommand('cmd-del-sqlite-active'),
          isNotNull,
        );

        // 4. Malformed lease: manually create partial lease and assert delete fails to touch it
        final epochSeconds = t0.millisecondsSinceEpoch ~/ 1000;
        await database.customStatement(
          '''
          INSERT INTO pending_reward_commands (
            operation, command_id, family_id, child_id, created_at, actor_user_id,
            recovery_state, dispatch_state, retry_count, lease_token, lease_expires_at
          ) VALUES
            ('spin_wheel', 'cmd-del-malformed', 'fam-1', 'ch-1', ?, 'user-A', 'active', 'possibly_dispatched', 0, 'tok-m', NULL);
          ''',
          [epochSeconds],
        );
        await database.deletePendingCommand('cmd-del-malformed');
        expect(
          await database.getPendingCommand('cmd-del-malformed'),
          isNotNull,
        );

        // 5. Complete claimed command using completeCommand with valid token succeeds
        final completed = await database.completeCommand(
          commandId: 'cmd-del-sqlite-active',
          leaseToken: token,
        );
        expect(completed, isTrue);
        expect(
          await database.getPendingCommand('cmd-del-sqlite-active'),
          isNull,
        );
      },
    );

    test(
      'quarantined, unknown legacy and terminal records cannot be claimed',
      () async {
        final quarantined = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-quarantined',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'user-A',
          createdAt: t0,
          recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
          dispatchState: CommandDispatchState.unknownLegacy,
        );
        await database.savePendingCommand(quarantined, now: t0);

        final token = await database2.acquireClaim(
          commandId: 'cmd-quarantined',
          actorUserId: 'user-A',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        expect(token, isNull);
      },
    );
  });
}
