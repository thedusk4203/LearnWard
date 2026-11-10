import 'dart:async';
import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Simulated server-authoritative reward repository that models network loss
/// after server commit (commit-response-loss), concurrency barriers, and typed backend errors.
class MockServerRewardRepository implements RewardRepository {
  final Map<String, RewardRedemption> redemptions = {};
  final Map<String, String> commandReceipts = {}; // commandId -> redemptionId
  final Map<String, int> childBalances = {}; // childId -> rpBalanceMinor

  int debitCount = 0;
  int refundCount = 0;
  int redeemCallCount = 0;
  int fulfillCallCount = 0;
  int cancelCallCount = 0;

  int get rpcCount => redeemCallCount + fulfillCallCount + cancelCallCount;

  bool simulateLossOnNextCommit = false;
  Object? simulateErrorOnNextRpc;
  String? currentActorUserId;

  Completer<void>? rpcEnteredBarrier;
  Completer<void>? allowRpcFinishBarrier;

  @override
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) async {
    redeemCallCount++;

    if (rpcEnteredBarrier != null && !rpcEnteredBarrier!.isCompleted) {
      rpcEnteredBarrier!.complete();
    }
    if (allowRpcFinishBarrier != null) {
      await allowRpcFinishBarrier!.future;
    }

    if (simulateErrorOnNextRpc != null) {
      final err = simulateErrorOnNextRpc!;
      simulateErrorOnNextRpc = null;
      if (err is Exception || err is Error) {
        throw err;
      }
      throw BackendRpcException(code: err.toString(), message: err.toString());
    }

    // 1. Idempotency check via server command receipt
    if (commandReceipts.containsKey(commandId)) {
      final redemptionId = commandReceipts[commandId]!;
      return redemptions[redemptionId]!;
    }

    // 2. Debit balance
    const cost = 1500;
    final current = childBalances[childId.value] ?? 5000;
    if (current < cost) {
      throw const InvalidRewardException(
        'Insufficient RP balance',
        code: 'LW201',
      );
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
      rewardSnapshot: const {'title': 'Test Reward', 'cost': cost},
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
    fulfillCallCount++;

    if (rpcEnteredBarrier != null && !rpcEnteredBarrier!.isCompleted) {
      rpcEnteredBarrier!.complete();
    }
    if (allowRpcFinishBarrier != null) {
      await allowRpcFinishBarrier!.future;
    }

    if (simulateErrorOnNextRpc != null) {
      final err = simulateErrorOnNextRpc!;
      simulateErrorOnNextRpc = null;
      if (err is Exception || err is Error) {
        throw err;
      }
      throw BackendRpcException(code: err.toString(), message: err.toString());
    }

    if (commandReceipts.containsKey(commandId)) {
      final existingId = commandReceipts[commandId]!;
      return redemptions[existingId]!;
    }

    final existing = redemptions[redemptionId.value];
    if (existing == null) {
      throw const BackendRpcException(
        code: 'P0002',
        message: 'Reward redemption not found.',
      );
    }
    if (existing.status != RewardRedemptionStatus.pendingFulfillment) {
      throw BackendRpcException(
        code: 'LW204',
        message:
            'Reward redemption is already in a terminal state: ${existing.status.value}',
      );
    }

    final now = DateTime.now().toUtc();
    final updated = existing.copyWith(
      status: RewardRedemptionStatus.fulfilled,
      fulfilledAt: now,
      fulfilledByUserId: currentActorUserId ?? 'parent-user-1',
      updatedAt: now,
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
    cancelCallCount++;

    if (rpcEnteredBarrier != null && !rpcEnteredBarrier!.isCompleted) {
      rpcEnteredBarrier!.complete();
    }
    if (allowRpcFinishBarrier != null) {
      await allowRpcFinishBarrier!.future;
    }

    if (simulateErrorOnNextRpc != null) {
      final err = simulateErrorOnNextRpc!;
      simulateErrorOnNextRpc = null;
      if (err is Exception || err is Error) {
        throw err;
      }
      throw BackendRpcException(code: err.toString(), message: err.toString());
    }

    if (commandReceipts.containsKey(commandId)) {
      final existingId = commandReceipts[commandId]!;
      return redemptions[existingId]!;
    }

    final existing = redemptions[redemptionId.value];
    if (existing == null) {
      throw const BackendRpcException(
        code: 'P0002',
        message: 'Reward redemption not found.',
      );
    }
    if (existing.status != RewardRedemptionStatus.pendingFulfillment) {
      throw BackendRpcException(
        code: 'LW204',
        message:
            'Reward redemption is already in a terminal state: ${existing.status.value}',
      );
    }

    // Refund compensating RP
    final current = childBalances[existing.childId.value] ?? 0;
    childBalances[existing.childId.value] = current + existing.rpCostMinor;
    refundCount++;

    final now = DateTime.now().toUtc();
    final updated = existing.copyWith(
      status: RewardRedemptionStatus.cancelled,
      cancellationReason: cancellationReason,
      updatedAt: now,
    );
    redemptions[redemptionId.value] = updated;
    commandReceipts[commandId] = redemptionId.value;

    if (simulateLossOnNextCommit) {
      simulateLossOnNextCommit = false;
      throw const SocketException(
        'Connection lost after cancel and refund committed',
      );
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
  }) async {
    final list = redemptions.values.where((r) {
      if (r.familyId != familyId && r.familyId.value != 'fam-test-1') {
        return false;
      }
      if (childId != null && r.childId != childId) return false;
      if (status != null && r.status != status) return false;
      return true;
    }).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }
}
