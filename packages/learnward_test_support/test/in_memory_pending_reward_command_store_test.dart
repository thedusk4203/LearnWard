import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  group('PendingRewardCommand.copyWith Nullable Update Semantics', () {
    test('explicitly clears nullable fields when passed null', () {
      final t0 = DateTime.utc(2026, 11, 7, 10, 0, 0);
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-copy-1',
        familyId: 'fam-1',
        childId: 'child-1',
        rewardId: 'reward-1',
        redemptionId: 'redempt-1',
        cancellationReason: 'reason-1',
        createdAt: t0,
        actorUserId: 'user-1',
        actorRole: 'parent',
        retryCount: 2,
        nextAttemptAt: t0.add(const Duration(minutes: 5)),
        lastErrorMessage: 'Temporary error',
        leaseToken: 'lease-tok-1',
        leaseExpiresAt: t0.add(const Duration(seconds: 30)),
      );

      // Nullable fields can be cleared by passing null
      final cleared = cmd.copyWith(
        leaseToken: null,
        leaseExpiresAt: null,
        lastErrorMessage: null,
        nextAttemptAt: null,
        childId: null,
        rewardId: null,
        redemptionId: null,
        cancellationReason: null,
        actorUserId: null,
        actorRole: null,
      );

      expect(cleared.leaseToken, isNull);
      expect(cleared.leaseExpiresAt, isNull);
      expect(cleared.lastErrorMessage, isNull);
      expect(cleared.nextAttemptAt, isNull);
      expect(cleared.childId, isNull);
      expect(cleared.rewardId, isNull);
      expect(cleared.redemptionId, isNull);
      expect(cleared.cancellationReason, isNull);
      expect(cleared.actorUserId, isNull);
      expect(cleared.actorRole, isNull);

      // Preserved non-nullable and omitted fields
      expect(cleared.commandId, 'cmd-copy-1');
      expect(cleared.familyId, 'fam-1');
      expect(cleared.retryCount, 2);
    });

    test('omitted fields are preserved without change', () {
      final t0 = DateTime.utc(2026, 11, 7, 10, 0, 0);
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-copy-2',
        familyId: 'fam-1',
        createdAt: t0,
        leaseToken: 'lease-tok-2',
        leaseExpiresAt: t0.add(const Duration(seconds: 30)),
        lastErrorMessage: 'Error message',
      );

      final updated = cmd.copyWith(retryCount: 5);
      expect(updated.retryCount, 5);
      expect(updated.leaseToken, 'lease-tok-2');
      expect(updated.leaseExpiresAt, t0.add(const Duration(seconds: 30)));
      expect(updated.lastErrorMessage, 'Error message');
    });

    test(
      'clearLease helper explicitly clears leaseToken and leaseExpiresAt',
      () {
        final t0 = DateTime.utc(2026, 11, 7, 10, 0, 0);
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-copy-3',
          familyId: 'fam-1',
          createdAt: t0,
          leaseToken: 'lease-tok-3',
          leaseExpiresAt: t0.add(const Duration(seconds: 30)),
        );

        final cleared = cmd.clearLease();
        expect(cleared.leaseToken, isNull);
        expect(cleared.leaseExpiresAt, isNull);
        expect(cleared.commandId, 'cmd-copy-3');
      },
    );
  });

  group('InMemoryPendingRewardCommandStore Invariants & Fencing', () {
    late InMemoryPendingRewardCommandStore store;
    final t0 = DateTime.utc(2026, 11, 7, 10, 0, 0);

    setUp(() {
      store = InMemoryPendingRewardCommandStore();
    });

    test('releaseClaim clears both leaseToken and leaseExpiresAt and fences subsequent operations', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-rel-1',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'user-1',
        createdAt: t0,
      );
      await store.savePendingCommand(cmd, now: t0);

      final token = await store.acquireClaim(
        commandId: 'cmd-rel-1',
        actorUserId: 'user-1',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(token, isNotNull);

      final nextAttempt = t0.add(const Duration(minutes: 5));
      final released = await store.releaseClaim(
        commandId: 'cmd-rel-1',
        leaseToken: token!,
        nextAttemptAt: nextAttempt,
        lastErrorMessage: 'Failed to dispatch',
      );
      expect(released, isTrue);

      final persisted = await store.getPendingCommand('cmd-rel-1');
      expect(persisted, isNotNull);
      expect(persisted!.leaseToken, isNull);
      expect(persisted.leaseExpiresAt, isNull);
      expect(persisted.retryCount, 1);
      expect(persisted.nextAttemptAt, nextAttempt);
      expect(persisted.lastErrorMessage, 'Failed to dispatch');

      // The original token can NO LONGER complete, release, or transition this command
      expect(
        await store.completeCommand(commandId: 'cmd-rel-1', leaseToken: token),
        isFalse,
      );
      expect(
        await store.releaseClaim(
          commandId: 'cmd-rel-1',
          leaseToken: token,
          nextAttemptAt: nextAttempt,
        ),
        isFalse,
      );
      expect(
        await store.transitionRecoveryState(
          commandId: 'cmd-rel-1',
          leaseToken: token,
          newState: CommandRecoveryState.quarantinedUnknownOutcome,
        ),
        isFalse,
      );
    });

    test('transitionRecoveryState clears leaseToken and leaseExpiresAt and fences subsequent operations', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-trans-1',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'user-1',
        createdAt: t0,
      );
      await store.savePendingCommand(cmd, now: t0);

      final token = (await store.acquireClaim(
        commandId: 'cmd-trans-1',
        actorUserId: 'user-1',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      ))!;

      final transitioned = await store.transitionRecoveryState(
        commandId: 'cmd-trans-1',
        leaseToken: token,
        newState: CommandRecoveryState.quarantinedUnknownOutcome,
        lastErrorMessage: 'Security violation',
      );
      expect(transitioned, isTrue);

      final persisted = await store.getPendingCommand('cmd-trans-1');
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
          commandId: 'cmd-trans-1',
          leaseToken: token,
        ),
        isFalse,
      );
    });

    test('pause and resume clear lease metadata and error message', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-pause-1',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'user-original',
        createdAt: t0,
      );
      await store.savePendingCommand(cmd, now: t0);

      // Pause from different actor session
      final paused = await store.pauseMismatchedActorCommand(
        commandId: 'cmd-pause-1',
        familyId: 'fam-1',
        authenticatedActorId: 'user-different',
        mismatchReason: 'Signed in as different user',
        now: t0,
      );
      expect(paused, isTrue);

      var persisted = await store.getPendingCommand('cmd-pause-1');
      expect(
        persisted!.recoveryState,
        CommandRecoveryState.pendingOriginalActor,
      );
      expect(persisted.leaseToken, isNull);
      expect(persisted.leaseExpiresAt, isNull);
      expect(persisted.lastErrorMessage, 'Signed in as different user');

      // Resume from original actor session
      final resumed = await store.resumeOriginalActorCommand(
        commandId: 'cmd-pause-1',
        familyId: 'fam-1',
        authenticatedActorId: 'user-original',
        now: t0.add(const Duration(minutes: 1)),
      );
      expect(resumed, isTrue);

      persisted = await store.getPendingCommand('cmd-pause-1');
      expect(persisted!.recoveryState, CommandRecoveryState.active);
      expect(persisted.leaseToken, isNull);
      expect(persisted.leaseExpiresAt, isNull);
      expect(persisted.lastErrorMessage, isNull);
    });

    test('savePendingCommand rejects active lease overwrite and partial leases', () async {
      final cmd = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: 'cmd-save-fence-1',
        familyId: 'fam-1',
        childId: 'child-1',
        actorUserId: 'user-1',
        createdAt: t0,
      );
      await store.savePendingCommand(cmd, now: t0);

      // Acquire claim
      final token = (await store.acquireClaim(
        commandId: 'cmd-save-fence-1',
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

      // Even attempting to pass matching leaseToken throws StateError
      final withToken = cmd.copyWith(leaseToken: token);
      expect(
        () => store.savePendingCommand(
          withToken,
          now: t0.add(const Duration(seconds: 5)),
        ),
        throwsA(
          isA<ArgumentError>(),
        ), // Partial lease: leaseToken without leaseExpiresAt
      );

      // Passing both leaseToken and leaseExpiresAt is still rejected because active lease is protected
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
      final reloaded = await store.getPendingCommand('cmd-save-fence-1');
      expect(reloaded!.leaseToken, isNull);
      expect(reloaded.leaseExpiresAt, isNull);
    });

    test(
      'deletePendingCommand fences active, expired, and malformed lease rows',
      () async {
        // 1. Unclaimed: deleted successfully
        final uncl = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-del-unclaimed',
          familyId: 'fam-1',
          createdAt: t0,
        );
        await store.savePendingCommand(uncl, now: t0);
        await store.deletePendingCommand('cmd-del-unclaimed');
        expect(await store.getPendingCommand('cmd-del-unclaimed'), isNull);

        // 2. Active lease: deletePendingCommand does NOT delete
        final active = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-del-active',
          familyId: 'fam-1',
          actorUserId: 'user-1',
          createdAt: t0,
        );
        await store.savePendingCommand(active, now: t0);
        final token = (await store.acquireClaim(
          commandId: 'cmd-del-active',
          actorUserId: 'user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        ))!;
        await store.deletePendingCommand('cmd-del-active');
        expect(await store.getPendingCommand('cmd-del-active'), isNotNull);

        // 3. Expired lease: deletePendingCommand does NOT delete (must use completeCommand or re-claim)
        final reloaded = (await store.getPendingCommand('cmd-del-active'))!;
        expect(reloaded.leaseToken, isNotNull);
        // Wait for expiration:
        await store.deletePendingCommand('cmd-del-active');
        expect(await store.getPendingCommand('cmd-del-active'), isNotNull);

        // completeCommand with valid token deletes it
        final completed = await store.completeCommand(
          commandId: 'cmd-del-active',
          leaseToken: token,
        );
        expect(completed, isTrue);
        expect(await store.getPendingCommand('cmd-del-active'), isNull);
      },
    );
  });
}
