import 'dart:async';
import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  group('Durable Reward Command Idempotency across Restarts', () {
    late InMemoryPendingRewardCommandStore commandStore;
    late MockServerRewardRepository server;
    late FakeAuthSessionPort authPort;
    late FakeRecoveryAuthorizationPort authzPort;

    final familyId = FamilyId('fam-test-1');
    final childId = ChildId('child-test-1');
    final rewardId = RewardId('rew-test-1');

    RedeemStoreReward createRedeemUseCase({
      AuthSessionPort? auth,
      RecoveryAuthorizationPort? authz,
    }) {
      return RedeemStoreReward(
        server,
        commandStore,
        authSessionPort: auth ?? authPort,
        authorizationPort: authz ?? authzPort,
        jitterSource: const DeterministicJitterSource(0.0),
      );
    }

    setUp(() {
      commandStore = InMemoryPendingRewardCommandStore();
      server = MockServerRewardRepository();
      server.childBalances[childId.value] = 5000; // 50.00 RP
      authPort = FakeAuthSessionPort(activeUserId: 'actor-child-1');
      authzPort = FakeRecoveryAuthorizationPort();
    });

    test('H02: RedeemStoreReward constructor fails closed with ArgumentError without trusted coordinator or ports', () {
      expect(
        () => RedeemStoreReward(server, commandStore),
        throwsArgumentError,
      );
    });

    test('Redeem commit-response-loss: exactly 1 debit across failure and restart, subsequent action gets new command ID', () async {
      // 1. Initial attempt with simulated response loss and authenticated actor
      var redeemUseCase = createRedeemUseCase();
      server.simulateLossOnNextCommit = true;

      await expectLater(
        redeemUseCase(
          familyId: familyId,
          rewardId: rewardId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<SocketException>()),
      );

      // Server committed 1 debit
      expect(server.debitCount, 1);
      expect(server.childBalances[childId.value], 3500);

      // Client preserved pending command in journal with possibly_dispatched state
      final pendingList = await commandStore.listPendingCommands(
        familyId: familyId.value,
        childId: childId.value,
      );
      expect(pendingList.length, 1);
      final firstCommandId = pendingList.first.commandId;
      expect(pendingList.first.actorUserId, 'actor-child-1');
      expect(
        pendingList.first.dispatchState,
        CommandDispatchState.possiblyDispatched,
      );

      // 2. Simulate complete application restart (new use case instance reading persistent store)
      redeemUseCase = createRedeemUseCase();

      // 3. User retries claim or screen recovers with matching actor and explicit commandId
      final recoveredRedemption = await redeemUseCase(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
        commandId: firstCommandId,
        actorUserId: 'actor-child-1',
      );

      // Verify NO duplicate debit occurred
      expect(
        server.debitCount,
        1,
        reason: 'Exactly 1 debit occurred across restart',
      );
      expect(server.childBalances[childId.value], 3500);
      expect(recoveredRedemption.rpCostMinor, 1500);

      // Journal is now cleared upon confirmed outcome
      final afterPending = await commandStore.listPendingCommands();
      expect(afterPending, isEmpty);

      // 4. Subsequent intentional claim by user
      final subsequentRedemption = await redeemUseCase(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
        actorUserId: 'actor-child-1',
      );

      // Verified new command ID and second legitimate debit
      expect(
        server.debitCount,
        2,
        reason: 'Subsequent action performs second debit',
      );
      expect(server.childBalances[childId.value], 2000);
      expect(subsequentRedemption.id, isNot(recoveredRedemption.id));

      // The first and subsequent command IDs are distinct
      expect(server.commandReceipts.keys.toList(), contains(firstCommandId));
      expect(server.commandReceipts.keys.length, 2);
    });

    test(
      'Redeem fail closed: cannot replay when actor is missing or mismatched',
      () async {
        await commandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.redeemReward,
            commandId: 'cmd-redeem-no-actor',
            familyId: familyId.value,
            childId: childId.value,
            rewardId: rewardId.value,
            createdAt: DateTime.now().toUtc(),
          ),
        );

        final redeemUseCase = createRedeemUseCase();

        // Attempting to dispatch must fail closed with StateError, not touch server
        await expectLater(
          () => redeemUseCase(
            familyId: familyId,
            rewardId: rewardId,
            childId: childId,
            commandId: 'cmd-redeem-no-actor',
            actorUserId: 'actor-child-1',
          ),
          throwsA(isA<StateError>()),
        );

        // Clean up and test actor mismatch
        await commandStore.deletePendingCommand('cmd-redeem-no-actor');
        await commandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.redeemReward,
            commandId: 'cmd-redeem-actor-1',
            familyId: familyId.value,
            childId: childId.value,
            rewardId: rewardId.value,
            actorUserId: 'actor-child-1',
            createdAt: DateTime.now().toUtc(),
          ),
        );

        final redeemUseCaseDiffActor = createRedeemUseCase(
          auth: FakeAuthSessionPort(activeUserId: 'actor-different'),
        );

        await expectLater(
          () => redeemUseCaseDiffActor(
            familyId: familyId,
            rewardId: rewardId,
            childId: childId,
            commandId: 'cmd-redeem-actor-1',
            actorUserId: 'actor-different',
          ),
          throwsA(isA<StateError>()),
        );

        await commandStore.deletePendingCommand('cmd-redeem-actor-1');
      },
    );

    test('Redeem fail closed: cannot replay when existing command is quarantined or legacy unknown', () async {
      // Quarantined
      await commandStore.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-redeem-quarantined',
          familyId: familyId.value,
          childId: childId.value,
          rewardId: rewardId.value,
          actorUserId: 'actor-child-1',
          recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
          createdAt: DateTime.now().toUtc(),
        ),
      );

      final redeemUseCase = createRedeemUseCase();
      await expectLater(
        () => redeemUseCase(
          familyId: familyId,
          rewardId: rewardId,
          childId: childId,
          commandId: 'cmd-redeem-quarantined',
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<StateError>()),
      );
      await commandStore.deletePendingCommand('cmd-redeem-quarantined');

      // Legacy unknown
      await commandStore.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-redeem-legacy',
          familyId: familyId.value,
          childId: childId.value,
          rewardId: rewardId.value,
          actorUserId: 'actor-child-1',
          dispatchState: CommandDispatchState.unknownLegacy,
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await expectLater(
        () => redeemUseCase(
          familyId: familyId,
          rewardId: rewardId,
          childId: childId,
          commandId: 'cmd-redeem-legacy',
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<StateError>()),
      );
      await commandStore.deletePendingCommand('cmd-redeem-legacy');
    });

    test('Fulfill commit-response-loss: exactly 1 transition across failure and restart, subsequent action gets new command ID', () async {
      // Setup existing redemption
      final redeemUseCase = createRedeemUseCase();
      final redemption = await redeemUseCase(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
        actorUserId: 'actor-child-1',
      );

      // 1. Initial fulfill attempt with simulated timeout after server commit
      var fulfillUseCase = FulfillRewardRedemption(server, commandStore);
      server.simulateLossOnNextCommit = true;

      await expectLater(
        fulfillUseCase(familyId: familyId, redemptionId: redemption.id),
        throwsA(isA<TimeoutException>()),
      );

      // Server committed the status to fulfilled
      expect(
        server.redemptions[redemption.id.value]!.status,
        RewardRedemptionStatus.fulfilled,
      );

      // Client journal holds pending fulfill command
      final pending = await commandStore.findPendingRedemptionCommand(
        operation: RewardCommandOperation.fulfillReward,
        redemptionId: redemption.id.value,
      );
      expect(pending, isNotNull);
      final fulfillCommandId = pending!.commandId;

      // 2. Simulate app restart
      fulfillUseCase = FulfillRewardRedemption(server, commandStore);

      // 3. Retry fulfillment
      final recovered = await fulfillUseCase(
        familyId: familyId,
        redemptionId: redemption.id,
      );

      expect(recovered.status, RewardRedemptionStatus.fulfilled);
      expect(await commandStore.listPendingCommands(), isEmpty);

      // Server only has 1 receipt for this fulfillment
      expect(server.commandReceipts[fulfillCommandId], redemption.id.value);
    });

    test('Cancel commit-response-loss: exactly 1 refund across failure and restart with preserved reason', () async {
      // Setup existing redemption
      final redeemUseCase = createRedeemUseCase();
      final redemption = await redeemUseCase(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
        actorUserId: 'actor-child-1',
      );
      expect(server.childBalances[childId.value], 3500);

      // 1. Initial cancel attempt with commit-response-loss
      var cancelUseCase = CancelRewardRedemption(server, commandStore);
      server.simulateLossOnNextCommit = true;

      await expectLater(
        cancelUseCase(
          familyId: familyId,
          redemptionId: redemption.id,
          cancellationReason: 'Activity unavailable this weekend',
        ),
        throwsA(isA<SocketException>()),
      );

      // Server committed refund
      expect(server.refundCount, 1);
      expect(server.childBalances[childId.value], 5000);

      // Client journal holds pending cancel command and cancellationReason
      final pending = await commandStore.findPendingRedemptionCommand(
        operation: RewardCommandOperation.cancelReward,
        redemptionId: redemption.id.value,
      );
      expect(pending, isNotNull);
      expect(pending!.cancellationReason, 'Activity unavailable this weekend');
      final cancelCommandId = pending.commandId;

      // 2. Simulate app restart
      cancelUseCase = CancelRewardRedemption(server, commandStore);

      // 3. Retry cancellation
      final recovered = await cancelUseCase(
        familyId: familyId,
        redemptionId: redemption.id,
        cancellationReason:
            'Different text ignored because journal preserves original',
      );

      // Verified exactly 1 refund, NOT double refund!
      expect(server.refundCount, 1);
      expect(server.childBalances[childId.value], 5000);
      expect(recovered.status, RewardRedemptionStatus.cancelled);
      expect(recovered.cancellationReason, 'Activity unavailable this weekend');

      // Journal cleared upon success
      expect(await commandStore.listPendingCommands(), isEmpty);
      expect(server.commandReceipts[cancelCommandId], redemption.id.value);
    });

    test('Terminal errors (e.g. LW201 Insufficient RP) immediately clear journal entry and rethrow', () async {
      // Balance is 0
      server.childBalances[childId.value] = 0;

      final redeemUseCase = createRedeemUseCase();

      await expectLater(
        redeemUseCase(
          familyId: familyId,
          rewardId: rewardId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<InvalidRewardException>()),
      );

      // Journal must NOT retain pending command on terminal business error
      expect(await commandStore.listPendingCommands(), isEmpty);
      expect(server.debitCount, 0);
    });

    test('Test D: missing or unauthenticated session during new redemption fails closed, zero server calls, zero journal entries', () async {
      server.redeemCallCount = 0;
      server.debitCount = 0;
      authPort.invalidateSession(); // Unauthenticated session
      final redeemUseCase = createRedeemUseCase();

      await expectLater(
        () => redeemUseCase(
          familyId: familyId,
          rewardId: rewardId,
          childId: childId,
          actorUserId: 'actor-child-1',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        server.redeemCallCount,
        equals(0),
        reason: 'Zero server calls on missing session',
      );
      expect(
        server.debitCount,
        equals(0),
        reason: 'Zero debits on missing session',
      );
      expect(
        await commandStore.listPendingCommands(),
        isEmpty,
        reason: 'Zero journal entries on missing session',
      );
    });
  });
}
