import 'dart:async';
import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

/// Simulated server-authoritative reward repository that models network loss
/// after server commit (commit-response-loss).
class MockServerRewardRepository implements RewardRepository {
  final Map<String, RewardRedemption> redemptions = {};
  final Map<String, String> commandReceipts = {}; // commandId -> redemptionId
  final Map<String, int> childBalances = {}; // childId -> rpBalanceMinor

  int debitCount = 0;
  int refundCount = 0;
  bool simulateLossOnNextCommit = false;

  @override
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) async {
    // 1. Idempotency check via server command receipt
    if (commandReceipts.containsKey(commandId)) {
      final redemptionId = commandReceipts[commandId]!;
      return redemptions[redemptionId]!;
    }

    // 2. Debit balance
    const cost = 1500;
    final current = childBalances[childId.value] ?? 5000;
    if (current < cost) {
      throw const InvalidRewardException('LW201: Insufficient RP balance');
    }
    childBalances[childId.value] = current - cost;
    debitCount++;

    // 3. Create redemption
    final redemptionId = 'redemption-${redemptions.length + 1}';
    final now = DateTime.now().toUtc();
    final redemption = RewardRedemption(
      id: RewardRedemptionId(redemptionId),
      familyId: FamilyId('fam-test-1'),
      childId: childId,
      rewardId: rewardId,
      origin: RewardOrigin.store,
      rpCostMinor: cost,
      status: RewardRedemptionStatus.pendingFulfillment,
      rewardSnapshot: {'title': 'Test Reward', 'cost': cost},
      createdAt: now,
      updatedAt: now,
    );

    redemptions[redemptionId] = redemption;
    commandReceipts[commandId] = redemptionId;

    // 4. Simulate commit-response-loss if configured
    if (simulateLossOnNextCommit) {
      simulateLossOnNextCommit = false;
      throw const SocketException(
        'Connection lost after server committed redemption',
      );
    }

    return redemption;
  }

  @override
  Future<RewardRedemption> fulfillRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
  }) async {
    if (commandReceipts.containsKey(commandId)) {
      final existingId = commandReceipts[commandId]!;
      return redemptions[existingId]!;
    }

    final existing = redemptions[redemptionId.value];
    if (existing == null) {
      throw const InvalidRedemptionException('Not found');
    }
    if (existing.status != RewardRedemptionStatus.pendingFulfillment) {
      throw InvalidRedemptionException(
        'LW204: Terminal status: ${existing.status}',
      );
    }

    final updated = existing.copyWith(
      status: RewardRedemptionStatus.fulfilled,
      fulfilledAt: DateTime.now().toUtc(),
      fulfilledByUserId: 'parent-user-1',
    );
    redemptions[redemptionId.value] = updated;
    commandReceipts[commandId] = redemptionId.value;

    if (simulateLossOnNextCommit) {
      simulateLossOnNextCommit = false;
      throw TimeoutException('Request timed out after fulfill committed');
    }

    return updated;
  }

  @override
  Future<RewardRedemption> cancelRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
    required String cancellationReason,
  }) async {
    if (commandReceipts.containsKey(commandId)) {
      final existingId = commandReceipts[commandId]!;
      return redemptions[existingId]!;
    }

    final existing = redemptions[redemptionId.value];
    if (existing == null) {
      throw const InvalidRedemptionException('Not found');
    }
    if (existing.status != RewardRedemptionStatus.pendingFulfillment) {
      throw InvalidRedemptionException(
        'LW204: Terminal status: ${existing.status}',
      );
    }

    // Refund compensating RP
    final current = childBalances[existing.childId.value] ?? 0;
    childBalances[existing.childId.value] = current + existing.rpCostMinor;
    refundCount++;

    final updated = existing.copyWith(
      status: RewardRedemptionStatus.cancelled,
      cancellationReason: cancellationReason,
    );
    redemptions[redemptionId.value] = updated;
    commandReceipts[commandId] = redemptionId.value;

    if (simulateLossOnNextCommit) {
      simulateLossOnNextCommit = false;
      throw const SocketException('Network aborted after refund committed');
    }

    return updated;
  }

  @override
  Future<Reward> createReward({
    required FamilyId familyId,
    required String title,
    String? description,
    required RewardCategory category,
    String iconKey = 'default_star',
    bool storeEnabled = true,
    int? storeCostMinor,
    bool wheelEnabled = false,
    WheelTier? wheelTier,
    ChildId? targetChildId,
  }) async => throw UnimplementedError();

  @override
  Future<Reward> updateReward(Reward reward) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteReward({
    required FamilyId familyId,
    required RewardId rewardId,
  }) async => throw UnimplementedError();

  @override
  Future<Reward?> getReward({
    required FamilyId familyId,
    required RewardId rewardId,
  }) async => throw UnimplementedError();

  @override
  Future<List<Reward>> listFamilyRewards({
    required FamilyId familyId,
    bool? activeOnly,
  }) async => throw UnimplementedError();

  @override
  Future<List<Reward>> listStoreRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) async => throw UnimplementedError();

  @override
  Future<List<RewardRedemption>> listRedemptions({
    required FamilyId familyId,
    ChildId? childId,
    RewardRedemptionStatus? status,
  }) async => throw UnimplementedError();
}

void main() {
  group('Durable Reward Command Idempotency across Restarts', () {
    late InMemoryPendingRewardCommandStore commandStore;
    late MockServerRewardRepository server;

    final familyId = FamilyId('fam-test-1');
    final childId = ChildId('child-test-1');
    final rewardId = RewardId('rew-test-1');

    setUp(() {
      commandStore = InMemoryPendingRewardCommandStore();
      server = MockServerRewardRepository();
      server.childBalances[childId.value] = 5000; // 50.00 RP
    });

    test('Redeem commit-response-loss: exactly 1 debit across failure and restart, subsequent action gets new command ID', () async {
      // 1. Initial attempt with simulated response loss
      var redeemUseCase = RedeemStoreReward(server, commandStore: commandStore);
      server.simulateLossOnNextCommit = true;

      await expectLater(
        redeemUseCase(familyId: familyId, rewardId: rewardId, childId: childId),
        throwsA(isA<SocketException>()),
      );

      // Server committed 1 debit
      expect(server.debitCount, 1);
      expect(server.childBalances[childId.value], 3500);

      // Client preserved pending command in journal
      final pendingList = await commandStore.listPendingCommands(
        familyId: familyId.value,
        childId: childId.value,
      );
      expect(pendingList.length, 1);
      final firstCommandId = pendingList.first.commandId;

      // 2. Simulate complete application restart (new use case instance reading persistent store)
      redeemUseCase = RedeemStoreReward(server, commandStore: commandStore);

      // 3. User retries claim or screen recovers
      final recoveredRedemption = await redeemUseCase(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
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

    test('Fulfill commit-response-loss: exactly 1 transition across failure and restart, subsequent action gets new command ID', () async {
      // Setup existing redemption
      final redeemUseCase = RedeemStoreReward(
        server,
        commandStore: commandStore,
      );
      final redemption = await redeemUseCase(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
      );

      // 1. Initial fulfill attempt with simulated timeout after server commit
      var fulfillUseCase = FulfillRewardRedemption(
        server,
        commandStore: commandStore,
      );
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
      fulfillUseCase = FulfillRewardRedemption(
        server,
        commandStore: commandStore,
      );

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
      final redeemUseCase = RedeemStoreReward(
        server,
        commandStore: commandStore,
      );
      final redemption = await redeemUseCase(
        familyId: familyId,
        rewardId: rewardId,
        childId: childId,
      );
      expect(server.childBalances[childId.value], 3500);

      // 1. Initial cancel attempt with commit-response-loss
      var cancelUseCase = CancelRewardRedemption(
        server,
        commandStore: commandStore,
      );
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
      cancelUseCase = CancelRewardRedemption(
        server,
        commandStore: commandStore,
      );

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

      final redeemUseCase = RedeemStoreReward(
        server,
        commandStore: commandStore,
      );

      await expectLater(
        redeemUseCase(familyId: familyId, rewardId: rewardId, childId: childId),
        throwsA(isA<InvalidRewardException>()),
      );

      // Journal must NOT retain pending command on terminal business error
      expect(await commandStore.listPendingCommands(), isEmpty);
      expect(server.debitCount, 0);
    });
  });
}
