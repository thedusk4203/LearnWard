import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward_application/learnward_application.dart';

void main() {
  group(
    'InMemoryRepositories PendingRewardCommandStore Invariants & Fencing',
    () {
      late PendingRewardCommandStore store;
      final t0 = DateTime.utc(2026, 11, 7, 10, 0, 0);

      setUp(() {
        store = InMemoryPendingRewardCommandStore();
      });

      test('releaseClaim clears both leaseToken and leaseExpiresAt and fences subsequent operations', () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-rel-1',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'user-1',
          createdAt: t0,
        );
        await store.savePendingCommand(cmd, now: t0);

        final token = await store.acquireClaim(
          commandId: 'cmd-mobile-rel-1',
          actorUserId: 'user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        );
        expect(token, isNotNull);

        final nextAttempt = t0.add(const Duration(minutes: 5));
        final released = await store.releaseClaim(
          commandId: 'cmd-mobile-rel-1',
          leaseToken: token!,
          nextAttemptAt: nextAttempt,
          lastErrorMessage: 'Temporary network failure',
        );
        expect(released, isTrue);

        final persisted = await store.getPendingCommand('cmd-mobile-rel-1');
        expect(persisted, isNotNull);
        expect(persisted!.leaseToken, isNull);
        expect(persisted.leaseExpiresAt, isNull);
        expect(persisted.retryCount, 1);
        expect(persisted.nextAttemptAt, nextAttempt);
        expect(persisted.lastErrorMessage, 'Temporary network failure');

        // The original token can NO LONGER complete, release, or transition this command
        expect(
          await store.completeCommand(
            commandId: 'cmd-mobile-rel-1',
            leaseToken: token,
          ),
          isFalse,
        );
        expect(
          await store.releaseClaim(
            commandId: 'cmd-mobile-rel-1',
            leaseToken: token,
            nextAttemptAt: nextAttempt,
          ),
          isFalse,
        );
        expect(
          await store.transitionRecoveryState(
            commandId: 'cmd-mobile-rel-1',
            leaseToken: token,
            newState: CommandRecoveryState.quarantinedUnknownOutcome,
          ),
          isFalse,
        );
      });

      test('transitionRecoveryState clears leaseToken and leaseExpiresAt and fences subsequent operations', () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-trans-1',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'user-1',
          createdAt: t0,
        );
        await store.savePendingCommand(cmd, now: t0);

        final token = (await store.acquireClaim(
          commandId: 'cmd-mobile-trans-1',
          actorUserId: 'user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        ))!;

        final transitioned = await store.transitionRecoveryState(
          commandId: 'cmd-mobile-trans-1',
          leaseToken: token,
          newState: CommandRecoveryState.quarantinedUnknownOutcome,
          lastErrorMessage: 'Security violation',
        );
        expect(transitioned, isTrue);

        final persisted = await store.getPendingCommand('cmd-mobile-trans-1');
        expect(
          persisted!.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(persisted.leaseToken, isNull);
        expect(persisted.leaseExpiresAt, isNull);
        expect(persisted.lastErrorMessage, 'Security violation');

        // Old token is fenced
        expect(
          await store.completeCommand(
            commandId: 'cmd-mobile-trans-1',
            leaseToken: token,
          ),
          isFalse,
        );
      });

      test('pause and resume clear lease metadata and error message', () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-pause-1',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'user-original',
          createdAt: t0,
        );
        await store.savePendingCommand(cmd, now: t0);

        final paused = await store.pauseMismatchedActorCommand(
          commandId: 'cmd-mobile-pause-1',
          familyId: 'fam-1',
          authenticatedActorId: 'user-different',
          mismatchReason: 'Signed in as different user',
          now: t0,
        );
        expect(paused, isTrue);

        var persisted = await store.getPendingCommand('cmd-mobile-pause-1');
        expect(
          persisted!.recoveryState,
          CommandRecoveryState.pendingOriginalActor,
        );
        expect(persisted.leaseToken, isNull);
        expect(persisted.leaseExpiresAt, isNull);
        expect(persisted.lastErrorMessage, 'Signed in as different user');

        final resumed = await store.resumeOriginalActorCommand(
          commandId: 'cmd-mobile-pause-1',
          familyId: 'fam-1',
          authenticatedActorId: 'user-original',
          now: t0.add(const Duration(minutes: 1)),
        );
        expect(resumed, isTrue);

        persisted = await store.getPendingCommand('cmd-mobile-pause-1');
        expect(persisted!.recoveryState, CommandRecoveryState.active);
        expect(persisted.leaseToken, isNull);
        expect(persisted.leaseExpiresAt, isNull);
        expect(persisted.lastErrorMessage, isNull);
      });

      test(
        'savePendingCommand rejects active lease overwrite and partial leases',
        () async {
          final cmd = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-mobile-save-fence-1',
            familyId: 'fam-1',
            childId: 'child-1',
            actorUserId: 'user-1',
            createdAt: t0,
          );
          await store.savePendingCommand(cmd, now: t0);

          final token = (await store.acquireClaim(
            commandId: 'cmd-mobile-save-fence-1',
            actorUserId: 'user-1',
            leaseDuration: const Duration(seconds: 30),
            now: t0,
          ))!;

          // Attempt foreground save while lease is active -> throws StateError
          expect(
            () => store.savePendingCommand(
              cmd,
              now: t0.add(const Duration(seconds: 5)),
            ),
            throwsA(isA<StateError>()),
          );

          // Even attempting to pass matching leaseToken throws StateError / ArgumentError
          final withToken = cmd.copyWith(leaseToken: token);
          expect(
            () => store.savePendingCommand(
              withToken,
              now: t0.add(const Duration(seconds: 5)),
            ),
            throwsA(isA<ArgumentError>()),
          );

          // Full lease with matching token still throws StateError because active lease is protected
          final withFullLease = cmd.copyWith(
            leaseToken: token,
            leaseExpiresAt: t0.add(const Duration(seconds: 30)),
          );
          expect(
            () => store.savePendingCommand(
              withFullLease,
              now: t0.add(const Duration(seconds: 5)),
            ),
            throwsA(isA<StateError>()),
          );

          // After lease expires, foreground save succeeds and clears expired lease
          await store.savePendingCommand(
            cmd,
            now: t0.add(const Duration(seconds: 35)),
          );
          final reloaded = await store.getPendingCommand(
            'cmd-mobile-save-fence-1',
          );
          expect(reloaded!.leaseToken, isNull);
          expect(reloaded.leaseExpiresAt, isNull);
        },
      );

      test(
        'deletePendingCommand fences active, expired, and malformed lease rows',
        () async {
          // 1. Unclaimed: deleted successfully
          final uncl = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-mobile-del-unclaimed',
            familyId: 'fam-1',
            createdAt: t0,
          );
          await store.savePendingCommand(uncl, now: t0);
          await store.deletePendingCommand('cmd-mobile-del-unclaimed');
          expect(
            await store.getPendingCommand('cmd-mobile-del-unclaimed'),
            isNull,
          );

          // 2. Active lease: deletePendingCommand does NOT delete
          final active = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-mobile-del-active',
            familyId: 'fam-1',
            actorUserId: 'user-1',
            createdAt: t0,
          );
          await store.savePendingCommand(active, now: t0);
          final token = (await store.acquireClaim(
            commandId: 'cmd-mobile-del-active',
            actorUserId: 'user-1',
            leaseDuration: const Duration(seconds: 30),
            now: t0,
          ))!;
          await store.deletePendingCommand('cmd-mobile-del-active');
          expect(
            await store.getPendingCommand('cmd-mobile-del-active'),
            isNotNull,
          );

          // 3. Expired lease: deletePendingCommand does NOT delete
          await store.deletePendingCommand('cmd-mobile-del-active');
          expect(
            await store.getPendingCommand('cmd-mobile-del-active'),
            isNotNull,
          );

          // completeCommand with valid token deletes it
          final completed = await store.completeCommand(
            commandId: 'cmd-mobile-del-active',
            leaseToken: token,
          );
          expect(completed, isTrue);
          expect(
            await store.getPendingCommand('cmd-mobile-del-active'),
            isNull,
          );
        },
      );
    },
  );
}
