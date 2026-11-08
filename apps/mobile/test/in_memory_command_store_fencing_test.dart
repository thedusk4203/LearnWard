import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward_application/learnward_application.dart';

void main() {
  group(
    'InMemoryRepositories PendingRewardCommandStore Invariants & Fencing',
    () {
      late InMemoryPendingRewardCommandStore store;
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

          // 3. Genuinely expired lease: construct an expired lease and verify deletePendingCommand does NOT delete
          final expiredCmd = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-mobile-del-expired',
            familyId: 'fam-1',
            actorUserId: 'user-1',
            createdAt: t0,
          );
          await store.savePendingCommand(expiredCmd, now: t0);
          final expiredToken = (await store.acquireClaim(
            commandId: 'cmd-mobile-del-expired',
            actorUserId: 'user-1',
            leaseDuration: const Duration(seconds: 5),
            now: t0,
          ))!;
          // Advance time past lease expiration
          final effectiveExpiry = t0.add(const Duration(seconds: 10));
          final rowBefore = await store.getPendingCommand(
            'cmd-mobile-del-expired',
          );
          expect(rowBefore!.leaseExpiresAt!.isBefore(effectiveExpiry), isTrue);

          await store.deletePendingCommand('cmd-mobile-del-expired');
          expect(
            await store.getPendingCommand('cmd-mobile-del-expired'),
            isNotNull,
            reason: 'Expired lease must not be deleted by deletePendingCommand; requires completeCommand or reclamation',
          );

          // 4. Malformed lease: inject partial lease and assert deletePendingCommand fails to touch it
          final malformedCmd = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-mobile-del-malformed',
            familyId: 'fam-1',
            actorUserId: 'user-1',
            createdAt: t0,
            leaseToken: 'malformed-token',
            leaseExpiresAt: null,
          );
          store.seedRawCommand(malformedCmd);
          await store.deletePendingCommand('cmd-mobile-del-malformed');
          expect(
            await store.getPendingCommand('cmd-mobile-del-malformed'),
            isNotNull,
          );

          // 5. Complete claimed command using completeCommand with valid token succeeds
          final completed = await store.completeCommand(
            commandId: 'cmd-mobile-del-active',
            leaseToken: token,
          );
          expect(completed, isTrue);
          expect(
            await store.getPendingCommand('cmd-mobile-del-active'),
            isNull,
          );

          final completedExpired = await store.completeCommand(
            commandId: 'cmd-mobile-del-expired',
            leaseToken: expiredToken,
          );
          expect(completedExpired, isTrue);
          expect(
            await store.getPendingCommand('cmd-mobile-del-expired'),
            isNull,
          );
        },
      );

      test('HIGH 1: existing command identity fields are strictly immutable in memory', () async {
        final original = PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-mobile-immutable',
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
        await store.savePendingCommand(original, now: t0);

        // Attempt mutating operation
        expect(
          () => store.savePendingCommand(
            original.copyWith(operation: RewardCommandOperation.spinWheel),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating familyId
        expect(
          () => store.savePendingCommand(
            original.copyWith(familyId: 'fam-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating childId
        expect(
          () => store.savePendingCommand(
            original.copyWith(childId: 'child-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => store.savePendingCommand(
            original.copyWith(childId: null),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating rewardId
        expect(
          () => store.savePendingCommand(
            original.copyWith(rewardId: 'reward-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating redemptionId
        expect(
          () => store.savePendingCommand(
            original.copyWith(redemptionId: 'redemption-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating cancellationReason
        expect(
          () => store.savePendingCommand(
            original.copyWith(cancellationReason: 'other-reason'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating actorUserId
        expect(
          () => store.savePendingCommand(
            original.copyWith(actorUserId: 'user-actor-2'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Attempt mutating actorRole
        expect(
          () => store.savePendingCommand(
            original.copyWith(actorRole: 'child'),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // Assert stored record remains byte-for-byte identical
        final reloaded = await store.getPendingCommand('cmd-mobile-immutable');
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
        await store.savePendingCommand(retry, now: t0);
        final postRetry = await store.getPendingCommand('cmd-mobile-immutable');
        expect(postRetry!.nextAttemptAt, t0.add(const Duration(minutes: 5)));
        expect(postRetry.familyId, 'fam-1');
      });

      test('HIGH 2: irreversible dispatch provenance and legacy quarantine enforcement in memory', () async {
        // 1. Existing unknown_legacy with NULL actor -> save fresh-looking snapshot with actor and possibly_dispatched -> rejected
        final legacy = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-legacy',
          familyId: 'fam-1',
          childId: 'ch-1',
          createdAt: t0,
          dispatchState: CommandDispatchState.unknownLegacy,
        );
        store.seedRawCommand(legacy);

        final freshLooking = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-legacy',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'fresh-user-1',
          actorRole: 'parent',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        expect(
          () => store.savePendingCommand(freshLooking, now: t0),
          throwsA(isA<StateError>()),
        );
        final legacyRow = await store.getPendingCommand('cmd-mobile-legacy');
        expect(legacyRow!.dispatchState, CommandDispatchState.unknownLegacy);
        expect(legacyRow.actorUserId, isNull);

        // 2. Existing confirmed_committed -> attempt possibly_dispatched -> rejected
        final committed = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-committed',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'user-1',
          createdAt: t0,
          dispatchState: CommandDispatchState.confirmedCommitted,
        );
        store.seedRawCommand(committed);

        final committedAttempt = committed.copyWith(
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        expect(
          () => store.savePendingCommand(committedAttempt, now: t0),
          throwsA(isA<StateError>()),
        );
        final committedRow = await store.getPendingCommand(
          'cmd-mobile-committed',
        );
        expect(
          committedRow!.dispatchState,
          CommandDispatchState.confirmedCommitted,
        );

        // 3. Existing possibly_dispatched -> attempt never_dispatched -> provenance cannot regress
        final inFlightCmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-inflight',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'user-1',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        await store.savePendingCommand(inFlightCmd, now: t0);

        final regressAttempt = inFlightCmd.copyWith(
          dispatchState: CommandDispatchState.neverDispatched,
          lastErrorMessage: 'Attempting downgrade',
        );
        await store.savePendingCommand(regressAttempt, now: t0);
        final postDowngrade = await store.getPendingCommand(
          'cmd-mobile-inflight',
        );
        expect(
          postDowngrade!.dispatchState,
          CommandDispatchState.possiblyDispatched,
          reason: 'Provenance must remain possibly_dispatched and never regress to never_dispatched',
        );

        // 4. Existing quarantined_unknown_outcome -> attempt active save -> rejected
        final quarantinedCmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-quarantine-rec',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'user-1',
          createdAt: t0,
          recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        store.seedRawCommand(quarantinedCmd);
        expect(
          () => store.savePendingCommand(
            quarantinedCmd.copyWith(recoveryState: CommandRecoveryState.active),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );
        final stillQuarantined = await store.getPendingCommand(
          'cmd-mobile-quarantine-rec',
        );
        expect(
          stillQuarantined!.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );

        // 5. Fresh eligible command -> legitimate never_dispatched to possibly_dispatched works
        final freshCmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-fresh',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'user-1',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await store.savePendingCommand(freshCmd, now: t0);
        expect(
          (await store.getPendingCommand('cmd-mobile-fresh'))!.dispatchState,
          CommandDispatchState.neverDispatched,
        );

        // Legitimate pre-dispatch transition
        await store.savePendingCommand(
          freshCmd.copyWith(
            dispatchState: CommandDispatchState.possiblyDispatched,
          ),
          now: t0,
        );
        expect(
          (await store.getPendingCommand('cmd-mobile-fresh'))!.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );
      });

      test('MEDIUM: malformed persisted lease fails closed in memory for save and claim', () async {
        // 1. Partial lease: leaseToken present, leaseExpiresAt null
        final partial1 = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-partial-1',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'user-1',
          createdAt: t0,
          leaseToken: 'tok-only',
          leaseExpiresAt: null,
        );
        store.seedRawCommand(partial1);

        // acquireClaim fails closed
        expect(
          await store.acquireClaim(
            commandId: 'cmd-mobile-partial-1',
            actorUserId: 'user-1',
            leaseDuration: const Duration(seconds: 30),
            now: t0,
          ),
          isNull,
        );

        // savePendingCommand fails closed with StateError when existing row has malformed lease
        expect(
          () => store.savePendingCommand(
            partial1.copyWith(
              leaseToken: null,
              leaseExpiresAt: null,
              lastErrorMessage: 'Try update',
            ),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );

        // 2. Partial lease: leaseToken null, leaseExpiresAt present
        final partial2 = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-partial-2',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'user-1',
          createdAt: t0,
          leaseToken: null,
          leaseExpiresAt: t0.add(const Duration(seconds: 30)),
        );
        store.seedRawCommand(partial2);

        // acquireClaim fails closed
        expect(
          await store.acquireClaim(
            commandId: 'cmd-mobile-partial-2',
            actorUserId: 'user-1',
            leaseDuration: const Duration(seconds: 30),
            now: t0,
          ),
          isNull,
        );

        // savePendingCommand fails closed with StateError when existing row has malformed lease
        expect(
          () => store.savePendingCommand(
            partial2.copyWith(
              leaseToken: null,
              leaseExpiresAt: null,
              lastErrorMessage: 'Try update',
            ),
            now: t0,
          ),
          throwsA(isA<StateError>()),
        );
      });

      test('markPossiblyDispatched commits pre-dispatch marker under active lease and rejects wrong token, expired lease, or wrong actor in mobile store', () async {
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-mark-1',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'user-1',
          createdAt: t0,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await store.savePendingCommand(cmd, now: t0);

        final token = (await store.acquireClaim(
          commandId: 'cmd-mobile-mark-1',
          actorUserId: 'user-1',
          leaseDuration: const Duration(seconds: 30),
          now: t0,
        ))!;

        // Rejects wrong token
        expect(
          await store.markPossiblyDispatched(
            commandId: 'cmd-mobile-mark-1',
            leaseToken: 'wrong-token',
            authenticatedActorId: 'user-1',
            now: t0.add(const Duration(seconds: 5)),
          ),
          isFalse,
        );

        // Rejects wrong actor
        expect(
          await store.markPossiblyDispatched(
            commandId: 'cmd-mobile-mark-1',
            leaseToken: token,
            authenticatedActorId: 'user-different',
            now: t0.add(const Duration(seconds: 5)),
          ),
          isFalse,
        );

        // Rejects expired lease
        expect(
          await store.markPossiblyDispatched(
            commandId: 'cmd-mobile-mark-1',
            leaseToken: token,
            authenticatedActorId: 'user-1',
            now: t0.add(const Duration(seconds: 35)),
          ),
          isFalse,
        );

        // Valid call succeeds
        expect(
          await store.markPossiblyDispatched(
            commandId: 'cmd-mobile-mark-1',
            leaseToken: token,
            authenticatedActorId: 'user-1',
            now: t0.add(const Duration(seconds: 10)),
          ),
          isTrue,
        );

        final persisted = await store.getPendingCommand('cmd-mobile-mark-1');
        expect(
          persisted!.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );
        expect(persisted.leaseToken, token);
        expect(persisted.leaseExpiresAt, isNotNull);
      });

      test('listClaimableCommands filters by familyId in mobile store preventing cross-family starvation', () async {
        final cmdFam1 = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-fam-1',
          familyId: 'fam-1',
          childId: 'ch-1',
          actorUserId: 'user-shared',
          createdAt: t0,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        final cmdFam2 = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-mobile-fam-2',
          familyId: 'fam-2',
          childId: 'ch-2',
          actorUserId: 'user-shared',
          createdAt: t0.subtract(const Duration(minutes: 5)),
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await store.savePendingCommand(cmdFam2, now: t0);
        await store.savePendingCommand(cmdFam1, now: t0);

        final fam1List = await store.listClaimableCommands(
          actorUserId: 'user-shared',
          limit: 10,
          familyId: 'fam-1',
          now: t0,
        );
        expect(fam1List.length, 1);
        expect(fam1List.first.commandId, 'cmd-mobile-fam-1');

        final fam2List = await store.listClaimableCommands(
          actorUserId: 'user-shared',
          limit: 10,
          familyId: 'fam-2',
          now: t0,
        );
        expect(fam2List.length, 1);
        expect(fam2List.first.commandId, 'cmd-mobile-fam-2');
      });
    },
  );
}
