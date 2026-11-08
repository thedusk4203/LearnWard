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

      final token = await database2.acquireClaim(
        commandId: 'cmd-redeem-cross-actor',
        actorUserId: 'actor-user-2',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(token, isNull);

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

      final tokenMid = await database2.acquireClaim(
        commandId: 'cmd-lease-expiry',
        actorUserId: 'actor-user-1',
        leaseDuration: const Duration(seconds: 15),
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(tokenMid, isNull);

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

      final claim1 = await database.acquireClaim(
        commandId: 'cmd-partial-1',
        actorUserId: 'actor-user-1',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(claim1, isNull);

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

        final tokenA = (await database.acquireClaim(
          commandId: 'cmd-stale-fencing',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 10),
          now: t0,
        ))!;

        final tokenB = (await database2.acquireClaim(
          commandId: 'cmd-stale-fencing',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0.add(const Duration(seconds: 15)),
        ))!;
        expect(tokenB, isNot(equals(tokenA)));

        final completeResult = await database.completeCommand(
          commandId: 'cmd-stale-fencing',
          leaseToken: tokenA,
        );
        expect(completeResult, isFalse);

        final releaseResult = await database.releaseClaim(
          commandId: 'cmd-stale-fencing',
          leaseToken: tokenA,
          nextAttemptAt: t0.add(const Duration(minutes: 5)),
        );
        expect(releaseResult, isFalse);

        final transitionResult = await database.transitionRecoveryState(
          commandId: 'cmd-stale-fencing',
          leaseToken: tokenA,
          newState: CommandRecoveryState.terminalError,
        );
        expect(transitionResult, isFalse);

        final current = await database.getPendingCommand('cmd-stale-fencing');
        expect(current!.leaseToken, tokenB);
        expect(current.recoveryState, CommandRecoveryState.active);

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

      await database.close();
      database = AppDatabase(NativeDatabase(dbFile));

      final reloaded = await database.getPendingCommand('cmd-persist-schedule');
      expect(reloaded, isNotNull);
      expect(reloaded!.retryCount, 1);
      expect(reloaded.nextAttemptAt, retryDeadline);
      expect(reloaded.leaseToken, isNull);
      expect(reloaded.leaseExpiresAt, isNull);

      final claimableBefore = await database.listClaimableCommands(
        actorUserId: 'actor-user-1',
        limit: 10,
        now: t0.add(const Duration(minutes: 10)),
      );
      expect(claimableBefore, isEmpty);

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

        final mismatched = await database.listMismatchedActiveCommands(
          familyId: 'fam-1',
          authenticatedActorId: 'new-actor-id',
          limit: 10,
          now: t0,
        );
        expect(mismatched.length, 1);
        expect(mismatched.first.commandId, 'cmd-actor-cas');

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

        final resumeCandidates = await database.listPausedOriginalActorCommands(
          familyId: 'fam-1',
          authenticatedActorId: 'original-actor-id',
          limit: 10,
          now: t0.add(const Duration(minutes: 1)),
        );
        expect(resumeCandidates.length, 1);
        expect(resumeCandidates.first.commandId, 'cmd-actor-cas');

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

        final token = (await database.acquireClaim(
          commandId: 'cmd-pause-race',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        ))!;
        expect(token, isNotNull);

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

      final token = (await database.acquireClaim(
        commandId: 'cmd-foreground-fence',
        actorUserId: 'user-A',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      ))!;

      expect(
        () => database2.savePendingCommand(
          cmd,
          now: t0.add(const Duration(seconds: 5)),
        ),
        throwsA(isA<StateError>()),
      );

      final partialToken = cmd.copyWith(leaseToken: token);
      expect(
        () => database2.savePendingCommand(
          partialToken,
          now: t0.add(const Duration(seconds: 5)),
        ),
        throwsA(isA<ArgumentError>()),
      );

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

      // After lease expires, foreground save with identical identity succeeds and clears expired lease
      final updatedForeground = cmd.copyWith(
        lastErrorMessage: 'Retrying foreground',
      );
      await database2.savePendingCommand(
        updatedForeground,
        now: t0.add(const Duration(seconds: 35)),
      );

      final persisted = await database.getPendingCommand(
        'cmd-foreground-fence',
      );
      expect(persisted!.lastErrorMessage, 'Retrying foreground');
      expect(persisted.leaseToken, isNull);
      expect(persisted.leaseExpiresAt, isNull);
    });

    test(
      'HIGH 1: existing command identity fields are strictly immutable',
      () async {
        final original = PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-immutable-identity',
          familyId: 'fam-1',
          childId: 'child-1',
          rewardId: 'reward-1',
          redemptionId: 'redemption-1',
          cancellationReason: 'cancelled-by-parent',
          actorUserId: 'user-actor-1',
          actorRole: 'parent',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await database.savePendingCommand(original, now: t0);

        // Attempt mutating operation
        expect(
          () => database.savePendingCommand(
            original.copyWith(operation: RewardCommandOperation.spinWheel),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating familyId
        expect(
          () => database.savePendingCommand(
            original.copyWith(familyId: 'fam-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating childId (different string or null)
        expect(
          () => database.savePendingCommand(
            original.copyWith(childId: 'child-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => database.savePendingCommand(
            original.copyWith(childId: null),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating rewardId
        expect(
          () => database.savePendingCommand(
            original.copyWith(rewardId: 'reward-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating redemptionId
        expect(
          () => database.savePendingCommand(
            original.copyWith(redemptionId: 'redemption-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating cancellationReason
        expect(
          () => database.savePendingCommand(
            original.copyWith(cancellationReason: 'other-reason'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating actorUserId
        expect(
          () => database.savePendingCommand(
            original.copyWith(actorUserId: 'user-actor-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating actorRole
        expect(
          () => database.savePendingCommand(
            original.copyWith(actorRole: 'child'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Assert record in database remains byte-for-byte identical
        final reloaded = await database.getPendingCommand(
          'cmd-immutable-identity',
        );
        expect(reloaded!.operation, RewardCommandOperation.redeemReward);
        expect(reloaded.familyId, 'fam-1');
        expect(reloaded.childId, 'child-1');
        expect(reloaded.rewardId, 'reward-1');
        expect(reloaded.redemptionId, 'redemption-1');
        expect(reloaded.cancellationReason, 'cancelled-by-parent');
        expect(reloaded.actorUserId, 'user-actor-1');
        expect(reloaded.actorRole, 'parent');

        // Legitimate retry with identical identity payload succeeds
        final retry = original.copyWith(
          nextAttemptAt: t0.add(const Duration(minutes: 5)),
        );
        await database.savePendingCommand(retry, now: t0);
        final postRetry = await database.getPendingCommand(
          'cmd-immutable-identity',
        );
        expect(postRetry!.nextAttemptAt, t0.add(const Duration(minutes: 5)));
        expect(postRetry.familyId, 'fam-1');
      },
    );

    test('HIGH 2: irreversible dispatch provenance and legacy quarantine enforcement', () async {
      // 1. Existing unknown_legacy with NULL actor -> save fresh-looking snapshot with actor and possibly_dispatched -> rejected
      final legacyEpoch = t0.millisecondsSinceEpoch ~/ 1000;
      await database.customStatement(
        '''
          INSERT INTO pending_reward_commands (
            operation, command_id, family_id, child_id, created_at, actor_user_id,
            recovery_state, dispatch_state, retry_count
          ) VALUES
            ('spin_wheel', 'cmd-legacy-quarantine', 'fam-1', 'ch-1', ?, NULL, 'active', 'unknown_legacy', 0);
          ''',
        [legacyEpoch],
      );

      final freshLooking = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-legacy-quarantine',
        familyId: 'fam-1',
        childId: 'ch-1',
        actorUserId: 'fresh-user-1',
        actorRole: 'parent',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      expect(
        () => database.savePendingCommand(freshLooking, now: t0),
        throwsA(isA<StateError>()),
      );
      final legacyRow = await database.getPendingCommand(
        'cmd-legacy-quarantine',
      );
      expect(legacyRow!.dispatchState, CommandDispatchState.unknownLegacy);
      expect(legacyRow.actorUserId, isNull);

      // 2. Existing confirmed_committed -> attempt possibly_dispatched -> rejected
      await database.customStatement(
        '''
          INSERT INTO pending_reward_commands (
            operation, command_id, family_id, child_id, created_at, actor_user_id,
            recovery_state, dispatch_state, retry_count
          ) VALUES
            ('spin_wheel', 'cmd-committed', 'fam-1', 'ch-1', ?, 'user-1', 'active', 'confirmed_committed', 0);
          ''',
        [legacyEpoch],
      );
      final committedCmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-committed',
        familyId: 'fam-1',
        childId: 'ch-1',
        actorUserId: 'user-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      expect(
        () => database.savePendingCommand(committedCmd, now: t0),
        throwsA(isA<StateError>()),
      );
      final committedRow = await database.getPendingCommand('cmd-committed');
      expect(
        committedRow!.dispatchState,
        CommandDispatchState.confirmedCommitted,
      );

      // 3. Existing possibly_dispatched -> attempt never_dispatched -> provenance cannot regress
      final inFlightCmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-inflight',
        familyId: 'fam-1',
        childId: 'ch-1',
        actorUserId: 'user-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      await database.savePendingCommand(inFlightCmd, now: t0);

      final regressAttempt = inFlightCmd.copyWith(
        dispatchState: CommandDispatchState.neverDispatched,
        lastErrorMessage: 'Attempting downgrade',
      );
      await database.savePendingCommand(regressAttempt, now: t0);
      final postDowngrade = await database.getPendingCommand('cmd-inflight');
      expect(
        postDowngrade!.dispatchState,
        CommandDispatchState.possiblyDispatched,
        reason: 'Provenance must remain possibly_dispatched and never regress to never_dispatched',
      );

      // 4. Existing quarantined_unknown_outcome -> attempt active save -> rejected
      final quarantinedCmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-quarantine-rec',
        familyId: 'fam-1',
        childId: 'ch-1',
        actorUserId: 'user-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
        dispatchState: CommandDispatchState.possiblyDispatched,
      );
      // Direct insert of quarantined state
      await database.customStatement(
        '''
          INSERT INTO pending_reward_commands (
            operation, command_id, family_id, child_id, created_at, actor_user_id,
            recovery_state, dispatch_state, retry_count
          ) VALUES
            ('spin_wheel', 'cmd-quarantine-rec', 'fam-1', 'ch-1', ?, 'user-1', 'quarantined_unknown_outcome', 'possibly_dispatched', 0);
          ''',
        [legacyEpoch],
      );
      expect(
        () => database.savePendingCommand(
          quarantinedCmd.copyWith(recoveryState: CommandRecoveryState.active),
          now: t0,
        ),
        throwsA(isA<StateError>()),
      );
      final stillQuarantined = await database.getPendingCommand(
        'cmd-quarantine-rec',
      );
      expect(
        stillQuarantined!.recoveryState,
        CommandRecoveryState.quarantinedUnknownOutcome,
      );

      // 5. Fresh eligible command -> legitimate never_dispatched to possibly_dispatched works
      final freshCmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-fresh-dispatch',
        familyId: 'fam-1',
        childId: 'ch-1',
        actorUserId: 'user-1',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(freshCmd, now: t0);
      expect(
        (await database.getPendingCommand('cmd-fresh-dispatch'))!.dispatchState,
        CommandDispatchState.neverDispatched,
      );

      // Legitimate pre-dispatch transition
      await database.savePendingCommand(
        freshCmd.copyWith(
          dispatchState: CommandDispatchState.possiblyDispatched,
        ),
        now: t0,
      );
      expect(
        (await database.getPendingCommand('cmd-fresh-dispatch'))!.dispatchState,
        CommandDispatchState.possiblyDispatched,
      );
    });

    test('MEDIUM: deletePendingCommand fences active, genuinely expired, and malformed lease states', () async {
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
      await database2.deletePendingCommand('cmd-del-sqlite-active');
      expect(
        await database.getPendingCommand('cmd-del-sqlite-active'),
        isNotNull,
      );

      // 3. Genuinely expired lease: construct an expired lease and verify deletePendingCommand does NOT delete
      final expiredCmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-del-sqlite-expired',
        familyId: 'fam-1',
        actorUserId: 'user-A',
        createdAt: t0,
      );
      await database.savePendingCommand(expiredCmd, now: t0);
      final expiredToken = (await database.acquireClaim(
        commandId: 'cmd-del-sqlite-expired',
        actorUserId: 'user-A',
        leaseDuration: const Duration(seconds: 5),
        now: t0,
      ))!;
      final effectiveExpiry = t0.add(const Duration(seconds: 10));
      final rowBefore = await database.getPendingCommand(
        'cmd-del-sqlite-expired',
      );
      expect(rowBefore!.leaseExpiresAt!.isBefore(effectiveExpiry), isTrue);

      await database2.deletePendingCommand('cmd-del-sqlite-expired');
      expect(
        await database.getPendingCommand('cmd-del-sqlite-expired'),
        isNotNull,
        reason: 'Expired lease must not be deleted by deletePendingCommand; requires completeCommand or reclamation',
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
      expect(await database.getPendingCommand('cmd-del-malformed'), isNotNull);

      // 5. Complete claimed command using completeCommand with valid token succeeds
      final completed = await database.completeCommand(
        commandId: 'cmd-del-sqlite-active',
        leaseToken: token,
      );
      expect(completed, isTrue);
      expect(await database.getPendingCommand('cmd-del-sqlite-active'), isNull);

      final completedExpired = await database.completeCommand(
        commandId: 'cmd-del-sqlite-expired',
        leaseToken: expiredToken,
      );
      expect(completedExpired, isTrue);
      expect(
        await database.getPendingCommand('cmd-del-sqlite-expired'),
        isNull,
      );
    });

    test(
      'quarantined, unknown legacy and terminal records cannot be claimed',
      () async {
        final epochSeconds = t0.millisecondsSinceEpoch ~/ 1000;
        await database.customStatement(
          '''
          INSERT INTO pending_reward_commands (
            operation, command_id, family_id, child_id, created_at, actor_user_id,
            recovery_state, dispatch_state, retry_count
          ) VALUES
            ('spin_wheel', 'cmd-quarantined', 'fam-1', 'ch-1', ?, 'user-A', 'quarantined_unknown_outcome', 'unknown_legacy', 0);
          ''',
          [epochSeconds],
        );

        final token = await database2.acquireClaim(
          commandId: 'cmd-quarantined',
          actorUserId: 'user-A',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        expect(token, isNull);
      },
    );

    test('markPossiblyDispatched commits pre-dispatch marker under active lease and rejects wrong token, expired lease, or wrong actor', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-mark-dispatch-1',
        familyId: 'fam-1',
        childId: 'ch-1',
        actorUserId: 'user-A',
        createdAt: t0,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmd, now: t0);

      final token = (await database.acquireClaim(
        commandId: 'cmd-mark-dispatch-1',
        actorUserId: 'user-A',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      ))!;

      // Rejects wrong token
      final wrongTokenResult = await database2.markPossiblyDispatched(
        commandId: 'cmd-mark-dispatch-1',
        leaseToken: 'wrong-token',
        authenticatedActorId: 'user-A',
        now: t0.add(const Duration(seconds: 5)),
      );
      expect(wrongTokenResult, isFalse);

      // Rejects wrong actor
      final wrongActorResult = await database2.markPossiblyDispatched(
        commandId: 'cmd-mark-dispatch-1',
        leaseToken: token,
        authenticatedActorId: 'user-B',
        now: t0.add(const Duration(seconds: 5)),
      );
      expect(wrongActorResult, isFalse);

      // Rejects expired lease
      final expiredResult = await database2.markPossiblyDispatched(
        commandId: 'cmd-mark-dispatch-1',
        leaseToken: token,
        authenticatedActorId: 'user-A',
        now: t0.add(const Duration(seconds: 35)),
      );
      expect(expiredResult, isFalse);

      // Valid call succeeds
      final successResult = await database2.markPossiblyDispatched(
        commandId: 'cmd-mark-dispatch-1',
        leaseToken: token,
        authenticatedActorId: 'user-A',
        now: t0.add(const Duration(seconds: 10)),
      );
      expect(successResult, isTrue);

      // Verify row is now possibly_dispatched while retaining active lease
      final persisted = await database.getPendingCommand('cmd-mark-dispatch-1');
      expect(persisted!.dispatchState, CommandDispatchState.possiblyDispatched);
      expect(persisted.leaseToken, token);
      expect(persisted.leaseExpiresAt, isNotNull);
    });

    test('listClaimableCommands filters by familyId preventing cross-family starvation', () async {
      final cmdFam1 = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-fam-1',
        familyId: 'fam-1',
        childId: 'ch-1',
        actorUserId: 'user-shared',
        createdAt: t0,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      final cmdFam2 = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-fam-2',
        familyId: 'fam-2',
        childId: 'ch-2',
        actorUserId: 'user-shared',
        createdAt: t0.subtract(const Duration(minutes: 5)), // Older row
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(cmdFam2, now: t0);
      await database.savePendingCommand(cmdFam1, now: t0);

      // Querying for fam-1 returns only fam-1 row despite fam-2 row being older
      final fam1List = await database.listClaimableCommands(
        actorUserId: 'user-shared',
        limit: 10,
        familyId: 'fam-1',
        now: t0,
      );
      expect(fam1List.length, 1);
      expect(fam1List.first.commandId, 'cmd-fam-1');

      // Querying for fam-2 returns only fam-2 row
      final fam2List = await database.listClaimableCommands(
        actorUserId: 'user-shared',
        limit: 10,
        familyId: 'fam-2',
        now: t0,
      );
      expect(fam2List.length, 1);
      expect(fam2List.first.commandId, 'cmd-fam-2');
    });

    test('R24-4-01: concurrent foreground fresh-command creation across independent SQLite connections cannot allocate distinct UUIDs', () async {
      final familyId = FamilyId('fam-race-1');
      final childId = ChildId('child-race-1');

      final sampleRewards = [
        Reward(
          id: RewardId('rew-1'),
          familyId: familyId,
          title: 'Prize 1',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.common,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
        Reward(
          id: RewardId('rew-2'),
          familyId: familyId,
          title: 'Prize 2',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.special,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
        Reward(
          id: RewardId('rew-3'),
          familyId: familyId,
          title: 'Prize 3',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.rare,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
      ];

      final wheelRepo = _DelayedFakeWheelRepository(
        initialRewards: sampleRewards,
        delay: const Duration(milliseconds: 50),
      );
      final authPort1 = FakeAuthSessionPort(
        activeUserId: 'actor-race-1',
        sessionGeneration: 'gen-1',
      );
      final authPort2 = FakeAuthSessionPort(
        activeUserId: 'actor-race-1',
        sessionGeneration: 'gen-1',
      );

      final coord1 = RecoveryCoordinator(
        commandStore: database, // Connection 1
        wheelRepository: wheelRepo,
        authSessionPort: authPort1,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () => familyId.value,
      );

      final coord2 = RecoveryCoordinator(
        commandStore: database2, // Connection 2 on the exact same SQLite file
        wheelRepository: wheelRepo,
        authSessionPort: authPort2,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () => familyId.value,
      );

      // Concurrently execute fresh foreground spin intent (requestedCommandId is null!)
      final results = await Future.wait([
        coord1.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: familyId.value,
          childId: childId.value,
          trigger: CommandExecutionTrigger.foreground,
        ),
        coord2.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: familyId.value,
          childId: childId.value,
          trigger: CommandExecutionTrigger.foreground,
        ),
      ]);

      // Exactly ONE coordinator call creates the command and executes the RPC
      // The concurrent call returns CommandAlreadyInFlightResult
      final committed = results.whereType<CommandCommittedResult>().toList();
      final inFlight = results
          .whereType<CommandAlreadyInFlightResult>()
          .toList();

      expect(committed.length, equals(1));
      expect(inFlight.length, equals(1));

      // BOTH results reference the EXACT SAME command ID (never two distinct UUIDs!)
      expect(inFlight.first.commandId, equals(committed.first.commandId));

      // In the SQLite database, exactly ONE command row was ever inserted
      final allCommands = await database.listPendingCommands();
      expect(allCommands.length, lessThanOrEqualTo(1));

      // Authoritative remote RPC was dispatched exactly once
      expect(wheelRepo.spinCallCount, equals(1));
    });

    test('R24-5-01: pre-claim active-family mismatch does NOT release or mutate unexpired lease', () async {
      final familyId = FamilyId('fam-lease-protect-1');
      final otherFamilyId = FamilyId('fam-other-2');
      final childId = ChildId('child-lease-1');
      const cmdId = 'cmd-lease-protect-1';

      final sampleRewards = [
        Reward(
          id: RewardId('rew-1'),
          familyId: familyId,
          title: 'Prize 1',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.common,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
        Reward(
          id: RewardId('rew-2'),
          familyId: familyId,
          title: 'Prize 2',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.special,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
        Reward(
          id: RewardId('rew-3'),
          familyId: familyId,
          title: 'Prize 3',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.rare,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
      ];

      final wheelRepo = FakeWheelRepository(initialRewards: sampleRewards);
      final authPortB = FakeAuthSessionPort(
        activeUserId: 'worker-B',
        sessionGeneration: 'gen-B',
      );

      // Seed initial command in SQLite
      final initialCmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: cmdId,
        familyId: familyId.value,
        childId: childId.value,
        actorUserId: 'worker-A',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await database.savePendingCommand(initialCmd, now: t0);

      // Worker A acquires an unexpired lease via database (Connection 1)
      final leaseTokenA = await database.acquireClaim(
        commandId: cmdId,
        actorUserId: 'worker-A',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(leaseTokenA, isNotNull);

      // Worker B uses database2 (Connection 2) with active family set to otherFamilyId
      final coordB = RecoveryCoordinator(
        commandStore: database2,
        wheelRepository: wheelRepo,
        authSessionPort: authPortB,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () => otherFamilyId.value,
      );

      // Worker B attempts to execute referencing the same command ID
      final resultB = await coordB.execute(
        operation: RewardCommandOperation.spinWheel,
        familyId: familyId.value,
        childId: childId.value,
        requestedCommandId: cmdId,
      );

      // Assert B gets family mismatch, 0 RPC
      expect(resultB, isA<CommandFamilyMismatchResult>());
      expect(wheelRepo.spinCallCount, 0);

      // Assert the lease in SQLite is completely untouched:
      // identical lease token and expiry, unchanged retry count, no premature reclamation
      final row = await database.getPendingCommand(cmdId);
      expect(row, isNotNull);
      expect(row!.leaseToken, equals(leaseTokenA));
      expect(row.leaseExpiresAt, equals(t0.add(const Duration(seconds: 30))));
      expect(row.retryCount, equals(0));
      expect(row.lastErrorMessage, isNull);

      // Premature reclamation is blocked: Worker B cannot claim the unexpired lease
      final prematureClaim = await database2.acquireClaim(
        commandId: cmdId,
        actorUserId: 'worker-B',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(prematureClaim, isNull);
    });

    test('R24-5-02: two coordinator executions for the same command ID allow at most one mutating RPC (Spin)', () async {
      final familyId = FamilyId('fam-r24-5-02-spin');
      final childId = ChildId('child-r24-5-02-spin');
      const cmdId = 'cmd-spin-concurrent-claim';

      final sampleRewards = [
        Reward(
          id: RewardId('rew-1'),
          familyId: familyId,
          title: 'Prize 1',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.common,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
        Reward(
          id: RewardId('rew-2'),
          familyId: familyId,
          title: 'Prize 2',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.special,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
        Reward(
          id: RewardId('rew-3'),
          familyId: familyId,
          title: 'Prize 3',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.rare,
          iconKey: 'star',
          createdAt: t0,
          updatedAt: t0,
        ),
      ];

      final wheelRepo = _DelayedFakeWheelRepository(
        initialRewards: sampleRewards,
        delay: const Duration(milliseconds: 50),
      );
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-claim',
        sessionGeneration: 'gen-claim',
      );

      // Seed the command in SQLite
      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: cmdId,
          familyId: familyId.value,
          childId: childId.value,
          actorUserId: 'actor-claim',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        ),
        now: t0,
      );

      final coord1 = RecoveryCoordinator(
        commandStore: database, // Connection 1
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () => familyId.value,
      );
      final coord2 = RecoveryCoordinator(
        commandStore: database2, // Connection 2
        wheelRepository: wheelRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () => familyId.value,
      );

      // Concurrently execute with the same command ID
      final results = await Future.wait([
        coord1.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: familyId.value,
          childId: childId.value,
          requestedCommandId: cmdId,
        ),
        coord2.execute(
          operation: RewardCommandOperation.spinWheel,
          familyId: familyId.value,
          childId: childId.value,
          requestedCommandId: cmdId,
        ),
      ]);

      final committed = results.whereType<CommandCommittedResult>().toList();
      final inFlight = results
          .whereType<CommandAlreadyInFlightResult>()
          .toList();

      expect(committed.length, equals(1));
      expect(inFlight.length, equals(1));
      expect(wheelRepo.spinCallCount, equals(1));
    });

    test('R24-5-02: two coordinator executions for the same command ID allow at most one mutating RPC (Redeem)', () async {
      final familyId = FamilyId('fam-r24-5-02-redeem');
      final childId = ChildId('child-r24-5-02-redeem');
      final rewardId = RewardId('rew-redeem-1');
      const cmdId = 'cmd-redeem-concurrent-claim';

      final rewardRepo = _DelayedMockServerRewardRepository(
        delay: const Duration(milliseconds: 50),
      );
      rewardRepo.childBalances[childId.value] = 5000;

      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-redeem',
        sessionGeneration: 'gen-redeem',
      );

      // Seed the command in SQLite
      await database.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: cmdId,
          familyId: familyId.value,
          childId: childId.value,
          rewardId: rewardId.value,
          actorUserId: 'actor-redeem',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        ),
        now: t0,
      );

      final coord1 = RecoveryCoordinator(
        commandStore: database, // Connection 1
        rewardRepository: rewardRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () => familyId.value,
      );
      final coord2 = RecoveryCoordinator(
        commandStore: database2, // Connection 2
        rewardRepository: rewardRepo,
        authSessionPort: authPort,
        authorizationPort: FakeRecoveryAuthorizationPort(),
        activeFamilyIdProvider: () => familyId.value,
      );

      // Concurrently execute with the same command ID
      final results = await Future.wait([
        coord1.execute(
          operation: RewardCommandOperation.redeemReward,
          familyId: familyId.value,
          childId: childId.value,
          rewardId: rewardId.value,
          requestedCommandId: cmdId,
        ),
        coord2.execute(
          operation: RewardCommandOperation.redeemReward,
          familyId: familyId.value,
          childId: childId.value,
          rewardId: rewardId.value,
          requestedCommandId: cmdId,
        ),
      ]);

      final committed = results.whereType<CommandCommittedResult>().toList();
      final inFlight = results
          .whereType<CommandAlreadyInFlightResult>()
          .toList();

      expect(committed.length, equals(1));
      expect(inFlight.length, equals(1));
      expect(rewardRepo.debitCount, equals(1));
    });

    group('R24-5-03: Fresh-command unresolved-state matrix (recoveryState × dispatchState)', () {
      for (final recovery in CommandRecoveryState.values) {
        for (final dispatch in CommandDispatchState.values) {
          test('registerFreshCommand predicate for $recovery × $dispatch in SQLite', () async {
            final cmdId = 'cmd-matrix-${recovery.name}-${dispatch.name}';
            final existing = PendingRewardCommand(
              operation: RewardCommandOperation.spinWheel,
              commandId: cmdId,
              familyId: 'fam-matrix',
              childId: 'child-matrix',
              actorUserId: 'actor-matrix',
              createdAt: t0,
              recoveryState: recovery,
              dispatchState: dispatch,
            );
            await database.savePendingCommand(existing, now: t0);

            final freshCandidate = PendingRewardCommand(
              operation: RewardCommandOperation.spinWheel,
              commandId: 'cmd-fresh-candidate',
              familyId: 'fam-matrix',
              childId: 'child-matrix',
              actorUserId: 'actor-matrix',
              createdAt: t0,
              recoveryState: CommandRecoveryState.active,
              dispatchState: CommandDispatchState.neverDispatched,
            );

            final result = await database.registerFreshCommand(
              command: freshCandidate,
              now: t0,
            );

            final expectedUnresolved = isCommandUnresolved(
              recoveryState: recovery,
              dispatchState: dispatch,
            );

            if (expectedUnresolved) {
              expect(
                result,
                isA<PreexistingCommandFound>(),
                reason:
                    '$recovery × $dispatch is unresolved and MUST block duplicate fresh commands',
              );
            } else {
              expect(
                result,
                isA<FreshCommandRegistered>(),
                reason:
                    '$recovery × $dispatch is confirmed terminal and MUST allow fresh user intent',
              );
            }

            // Cleanup row for next combination
            await database.customStatement(
              'DELETE FROM pending_reward_commands WHERE command_id = ?',
              [cmdId],
            );
            await database.customStatement(
              'DELETE FROM pending_reward_commands WHERE command_id = ?',
              ['cmd-fresh-candidate'],
            );
          });
        }
      }
    });
  });
}

final class _DelayedFakeWheelRepository implements WheelRepository {
  _DelayedFakeWheelRepository({
    required List<Reward> initialRewards,
    required this.delay,
  }) : _inner = FakeWheelRepository(initialRewards: initialRewards);

  final FakeWheelRepository _inner;
  final Duration delay;

  int get spinCallCount => _inner.spinCallCount;

  @override
  Future<WheelSpinResult> spinRewardWheel({
    required String commandId,
    required ChildId childId,
  }) async {
    await Future<void>.delayed(delay);
    return _inner.spinRewardWheel(commandId: commandId, childId: childId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      _inner.noSuchMethod(invocation);
}

final class _DelayedMockServerRewardRepository implements RewardRepository {
  _DelayedMockServerRewardRepository({required this.delay})
    : _inner = MockServerRewardRepository();

  final MockServerRewardRepository _inner;
  final Duration delay;

  int get debitCount => _inner.debitCount;
  Map<String, int> get childBalances => _inner.childBalances;

  @override
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) async {
    await Future<void>.delayed(delay);
    return _inner.redeemStoreReward(
      commandId: commandId,
      rewardId: rewardId,
      childId: childId,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      _inner.noSuchMethod(invocation);
}
