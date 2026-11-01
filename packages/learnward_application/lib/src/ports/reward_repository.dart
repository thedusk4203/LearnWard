import 'package:learnward_domain/learnward_domain.dart';

/// Application port for managing reward catalog, store redemptions and fulfillment.
abstract interface class RewardRepository {
  /// Create a new reward in the family catalog.
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
  });

  /// Update an existing reward.
  Future<Reward> updateReward(Reward reward);

  /// Delete a reward (if unreferenced by redemptions/spins).
  Future<void> deleteReward({
    required FamilyId familyId,
    required RewardId rewardId,
  });

  /// Retrieve a specific reward by ID.
  Future<Reward?> getReward({
    required FamilyId familyId,
    required RewardId rewardId,
  });

  /// List all rewards in a family catalog, optionally filtering active only.
  Future<List<Reward>> listFamilyRewards({
    required FamilyId familyId,
    bool? activeOnly,
  });

  /// List active Store-enabled rewards, optionally filtered for a specific child.
  Future<List<Reward>> listStoreRewards({
    required FamilyId familyId,
    ChildId? childId,
  });

  /// Atomically redeem a Store reward for a child via trusted RPC.
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  });

  /// Mark a pending redemption as fulfilled by a parent via trusted RPC.
  Future<RewardRedemption> fulfillRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
  });

  /// Cancel a pending redemption and credit compensating refund via trusted RPC.
  Future<RewardRedemption> cancelRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
    required String cancellationReason,
  });

  /// List redemptions in a family, optionally filtered by child and status.
  Future<List<RewardRedemption>> listRedemptions({
    required FamilyId familyId,
    ChildId? childId,
    RewardRedemptionStatus? status,
  });
}
