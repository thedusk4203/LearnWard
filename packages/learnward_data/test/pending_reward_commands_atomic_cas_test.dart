import 'dart:io';

import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:test/test.dart';

void main() {
  group(
    'PendingRewardCommandStore Atomic CAS & Fencing (File-Backed SQLite)',
    () {
      late Directory tempDir;
      late File dbFile;
      late AppDatabase database;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync(
          'learnward_atomic_cas_test_',
        );
        dbFile = File('${tempDir.path}/atomic_cas.sqlite');
        database = AppDatabase(NativeDatabase(dbFile));
      });

      tearDown(() async {
        await database.close();
        if (tempDir.existsSync()) {
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      });

      test('simultaneous claim by two workers grants claim to one and rejects the other', () async {
        final now = DateTime.utc(2026, 11, 7, 12, 0, 0);
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-spin-race',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'actor-user-1',
          actorRole: 'child',
          createdAt: now,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        await database.savePendingCommand(cmd);

        // Worker 1 acquires claim
        final token1 = await database.acquireClaim(
          commandId: 'cmd-spin-race',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 30),
          now: now,
        );
        expect(token1, isNotNull);

        // Worker 2 attempts simultaneous claim on the same command
        final token2 = await database.acquireClaim(
          commandId: 'cmd-spin-race',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 30),
          now: now.add(const Duration(seconds: 1)),
        );
        expect(token2, isNull);
      });

      test('cross-actor claim is rejected at the query boundary', () async {
        final now = DateTime.utc(2026, 11, 7, 12, 0, 0);
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-redeem-cross-actor',
          familyId: 'fam-1',
          childId: 'child-1',
          rewardId: 'rew-1',
          actorUserId: 'actor-user-1',
          actorRole: 'child',
          createdAt: now,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await database.savePendingCommand(cmd);

        // Attempting to claim with actor-user-2 fails
        final token = await database.acquireClaim(
          commandId: 'cmd-redeem-cross-actor',
          actorUserId: 'actor-user-2',
          leaseDuration: const Duration(seconds: 30),
          now: now,
        );
        expect(token, isNull);
      });

      test('lease expiry allows reclamation with a new lease token', () async {
        final t0 = DateTime.utc(2026, 11, 7, 12, 0, 0);
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-spin-expiry',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'actor-user-1',
          actorRole: 'child',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        await database.savePendingCommand(cmd);

        // Worker 1 claims for 10 seconds
        final token1 = await database.acquireClaim(
          commandId: 'cmd-spin-expiry',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 10),
          now: t0,
        );
        expect(token1, isNotNull);

        // At t0 + 5s, lease is active -> cannot claim
        expect(
          await database.acquireClaim(
            commandId: 'cmd-spin-expiry',
            actorUserId: 'actor-user-1',
            leaseDuration: const Duration(seconds: 10),
            now: t0.add(const Duration(seconds: 5)),
          ),
          isNull,
        );

        // At t0 + 11s, lease has expired -> Worker 2 reclaims with new token
        final token2 = await database.acquireClaim(
          commandId: 'cmd-spin-expiry',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 10),
          now: t0.add(const Duration(seconds: 11)),
        );
        expect(token2, isNotNull);
        expect(token2, isNot(equals(token1)));
      });

      test(
        'partial lease metadata fails closed and prevents claiming',
        () async {
          final now = DateTime.utc(2026, 11, 7, 12, 0, 0);
          final cmd = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-partial-lease',
            familyId: 'fam-1',
            childId: 'child-1',
            actorUserId: 'actor-user-1',
            actorRole: 'child',
            createdAt: now,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.neverDispatched,
          );
          await database.savePendingCommand(cmd);

          // Corrupt lease metadata to partial: lease_token set, lease_expires_at null
          await database.customStatement(
            "UPDATE pending_reward_commands SET lease_token = 'orphan-token', lease_expires_at = NULL WHERE command_id = 'cmd-partial-lease';",
          );

          // acquireClaim fails closed
          expect(
            await database.acquireClaim(
              commandId: 'cmd-partial-lease',
              actorUserId: 'actor-user-1',
              leaseDuration: const Duration(seconds: 30),
              now: now,
            ),
            isNull,
          );

          // listClaimableCommands ignores partial metadata row
          expect(
            await database.listClaimableCommands(
              actorUserId: 'actor-user-1',
              limit: 10,
              now: now,
            ),
            isEmpty,
          );

          // Corrupt to other partial: lease_token null, lease_expires_at set
          await database.customStatement(
            "UPDATE pending_reward_commands SET lease_token = NULL, lease_expires_at = 1731000000 WHERE command_id = 'cmd-partial-lease';",
          );
          expect(
            await database.acquireClaim(
              commandId: 'cmd-partial-lease',
              actorUserId: 'actor-user-1',
              leaseDuration: const Duration(seconds: 30),
              now: now,
            ),
            isNull,
          );
        },
      );

      test(
        'stale worker cannot complete, release, or mutate newer claim',
        () async {
          final t0 = DateTime.utc(2026, 11, 7, 12, 0, 0);
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
          await database.savePendingCommand(cmd);

          // Worker 1 acquires claim with token1 for 10 seconds
          final token1 = (await database.acquireClaim(
            commandId: 'cmd-stale-fencing',
            actorUserId: 'actor-user-1',
            leaseDuration: const Duration(seconds: 10),
            now: t0,
          ))!;

          // Lease expires at t0 + 11s, Worker 2 claims with token2
          final token2 = (await database.acquireClaim(
            commandId: 'cmd-stale-fencing',
            actorUserId: 'actor-user-1',
            leaseDuration: const Duration(seconds: 10),
            now: t0.add(const Duration(seconds: 11)),
          ))!;

          // Stale Worker 1 attempts releaseClaim with expired token1 -> fails
          final releaseStale = await database.releaseClaim(
            commandId: 'cmd-stale-fencing',
            leaseToken: token1,
            nextAttemptAt: t0.add(const Duration(minutes: 5)),
            lastErrorMessage: 'Stale error',
          );
          expect(releaseStale, isFalse);

          // Stale Worker 1 attempts completeCommand with expired token1 -> fails, row preserved
          final completeStale = await database.completeCommand(
            commandId: 'cmd-stale-fencing',
            leaseToken: token1,
          );
          expect(completeStale, isFalse);

          final row = await database.getPendingCommand('cmd-stale-fencing');
          expect(row, isNotNull);
          expect(row!.leaseToken, equals(token2));

          // Worker 2 completes cleanly with token2 -> succeeds, row deleted
          final completeFresh = await database.completeCommand(
            commandId: 'cmd-stale-fencing',
            leaseToken: token2,
          );
          expect(completeFresh, isTrue);
          expect(await database.getPendingCommand('cmd-stale-fencing'), isNull);
        },
      );

      test('atomic retry counter increment directly within SQLite', () async {
        final t0 = DateTime.utc(2026, 11, 7, 12, 0, 0);
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-retry-inc',
          familyId: 'fam-1',
          childId: 'child-1',
          rewardId: 'rew-1',
          actorUserId: 'actor-user-1',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        await database.savePendingCommand(cmd);

        // Initial retryCount is 0
        expect(
          (await database.getPendingCommand('cmd-retry-inc'))!.retryCount,
          0,
        );

        // Attempt 1: Claim and release
        final token1 = (await database.acquireClaim(
          commandId: 'cmd-retry-inc',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 10),
          now: t0,
        ))!;
        await database.releaseClaim(
          commandId: 'cmd-retry-inc',
          leaseToken: token1,
          nextAttemptAt: t0.add(const Duration(seconds: 2)),
          lastErrorMessage: 'Transient timeout 1',
        );
        final afterAttempt1 = await database.getPendingCommand('cmd-retry-inc');
        expect(afterAttempt1!.retryCount, 1);
        expect(afterAttempt1.lastErrorMessage, 'Transient timeout 1');
        expect(afterAttempt1.leaseToken, isNull);

        // Attempt 2: Claim at t0 + 3s and release
        final token2 = (await database.acquireClaim(
          commandId: 'cmd-retry-inc',
          actorUserId: 'actor-user-1',
          leaseDuration: const Duration(seconds: 10),
          now: t0.add(const Duration(seconds: 3)),
        ))!;
        await database.releaseClaim(
          commandId: 'cmd-retry-inc',
          leaseToken: token2,
          nextAttemptAt: t0.add(const Duration(seconds: 10)),
          lastErrorMessage: 'Transient timeout 2',
        );
        final afterAttempt2 = await database.getPendingCommand('cmd-retry-inc');
        expect(afterAttempt2!.retryCount, 2);
        expect(afterAttempt2.lastErrorMessage, 'Transient timeout 2');
      });

      test('retry schedule and backoff state persist across database close and reopen', () async {
        final t0 = DateTime.utc(2026, 11, 7, 12, 0, 0);
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
        await database.savePendingCommand(cmd);

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

        final reloaded = await database.getPendingCommand(
          'cmd-persist-schedule',
        );
        expect(reloaded, isNotNull);
        expect(reloaded!.retryCount, 1);
        expect(reloaded.nextAttemptAt, retryDeadline);

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
          final now = DateTime.utc(2026, 11, 7, 12, 0, 0);
          final cmd = PendingRewardCommand(
            operation: RewardCommandOperation.redeemReward,
            commandId: 'cmd-mismatch-cycle',
            familyId: 'fam-1',
            childId: 'child-1',
            rewardId: 'rew-1',
            actorUserId: 'user-A',
            actorRole: 'child',
            createdAt: now,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
          );
          await database.savePendingCommand(cmd);

          // User B logs in -> discovers command authored by User A
          final mismatched = await database.listMismatchedActiveCommands(
            familyId: 'fam-1',
            authenticatedActorId: 'user-B',
            limit: 10,
            now: now,
          );
          expect(mismatched.length, 1);
          expect(mismatched.first.commandId, 'cmd-mismatch-cycle');

          // Pause mismatched command
          final pauseSuccess = await database.pauseMismatchedActorCommand(
            commandId: 'cmd-mismatch-cycle',
            familyId: 'fam-1',
            authenticatedActorId: 'user-B',
            mismatchReason: 'Paused: User A is not logged in',
            now: now,
          );
          expect(pauseSuccess, isTrue);

          final pausedCmd = await database.getPendingCommand(
            'cmd-mismatch-cycle',
          );
          expect(
            pausedCmd!.recoveryState,
            CommandRecoveryState.pendingOriginalActor,
          );
          expect(
            pausedCmd.lastErrorMessage,
            contains('User A is not logged in'),
          );
          expect(pausedCmd.actorUserId, 'user-A');

          // User B cannot claim paused command
          expect(
            await database.acquireClaim(
              commandId: 'cmd-mismatch-cycle',
              actorUserId: 'user-B',
              leaseDuration: const Duration(seconds: 30),
              now: now,
            ),
            isNull,
          );

          // User A logs back in -> discovers paused command
          final pausedForA = await database.listPausedOriginalActorCommands(
            familyId: 'fam-1',
            authenticatedActorId: 'user-A',
            limit: 10,
            now: now,
          );
          expect(pausedForA.length, 1);
          expect(pausedForA.first.commandId, 'cmd-mismatch-cycle');

          // User A resumes command
          final resumeSuccess = await database.resumeOriginalActorCommand(
            commandId: 'cmd-mismatch-cycle',
            familyId: 'fam-1',
            authenticatedActorId: 'user-A',
            now: now,
          );
          expect(resumeSuccess, isTrue);

          final resumedCmd = await database.getPendingCommand(
            'cmd-mismatch-cycle',
          );
          expect(resumedCmd!.recoveryState, CommandRecoveryState.active);
          expect(resumedCmd.lastErrorMessage, isNull);

          // User A can now acquire claim normally
          final claimToken = await database.acquireClaim(
            commandId: 'cmd-mismatch-cycle',
            actorUserId: 'user-A',
            leaseDuration: const Duration(seconds: 30),
            now: now,
          );
          expect(claimToken, isNotNull);
        },
      );

      test(
        'pause versus claim race: active lease prevents mismatch pause',
        () async {
          final now = DateTime.utc(2026, 11, 7, 12, 0, 0);
          final cmd = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-pause-race',
            familyId: 'fam-1',
            childId: 'child-1',
            actorUserId: 'user-A',
            createdAt: now,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
          );
          await database.savePendingCommand(cmd);

          // Worker acquires active lease for User A
          final token = await database.acquireClaim(
            commandId: 'cmd-pause-race',
            actorUserId: 'user-A',
            leaseDuration: const Duration(seconds: 30),
            now: now,
          );
          expect(token, isNotNull);

          // Concurrent sweep under User B attempts to pause the actively leased command
          final pauseAttempt = await database.pauseMismatchedActorCommand(
            commandId: 'cmd-pause-race',
            familyId: 'fam-1',
            authenticatedActorId: 'user-B',
            mismatchReason: 'Paused: User A is not logged in',
            now: now,
          );
          // Active lease blocks pause
          expect(pauseAttempt, isFalse);

          final row = await database.getPendingCommand('cmd-pause-race');
          expect(row!.recoveryState, CommandRecoveryState.active);
          expect(row.leaseToken, equals(token));
        },
      );

      test(
        'foreground savePendingCommand rejects overwriting active lease',
        () async {
          final now = DateTime.utc(2026, 11, 7, 12, 0, 0);
          final cmd = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-foreground-fence',
            familyId: 'fam-1',
            childId: 'child-1',
            actorUserId: 'user-A',
            createdAt: now,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
          );
          await database.savePendingCommand(cmd);

          // Background dispatcher acquires claim
          final token = (await database.acquireClaim(
            commandId: 'cmd-foreground-fence',
            actorUserId: 'user-A',
            leaseDuration: const Duration(seconds: 30),
            now: now,
          ))!;

          // Foreground attempts blind overwrite with null or different leaseToken -> throws StateError
          expect(
            () => database.savePendingCommand(cmd),
            throwsA(isA<StateError>()),
          );

          // Foreground updating with matching leaseToken succeeds
          final updatedWithToken = cmd.copyWith(leaseToken: token);
          await database.savePendingCommand(updatedWithToken);
        },
      );

      test(
        'quarantined, unknown legacy and terminal records cannot be claimed',
        () async {
          final now = DateTime.utc(2026, 11, 7, 12, 0, 0);
          final quarantined = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-quarantined',
            familyId: 'fam-1',
            childId: 'child-1',
            actorUserId: 'user-A',
            createdAt: now,
            recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
            dispatchState: CommandDispatchState.unknownLegacy,
          );
          await database.savePendingCommand(quarantined);

          final token = await database.acquireClaim(
            commandId: 'cmd-quarantined',
            actorUserId: 'user-A',
            leaseDuration: const Duration(seconds: 30),
            now: now,
          );
          expect(token, isNull);
        },
      );
    },
  );
}
