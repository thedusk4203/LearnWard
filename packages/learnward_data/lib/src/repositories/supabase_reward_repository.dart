import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase implementation of [RewardRepository] interacting with
/// `rewards`, `reward_redemptions` tables and trusted RPCs.
final class SupabaseRewardRepository implements RewardRepository {
  SupabaseRewardRepository(this._client);

  final SupabaseClient _client;

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
  }) async {
    final row = await _client
        .from('rewards')
        .insert({
          'family_id': familyId.value,
          'title': title.trim(),
          'description': description?.trim(),
          'category': category.value,
          'icon_key': iconKey,
          'store_enabled': storeEnabled,
          'store_cost_minor': storeCostMinor,
          'wheel_enabled': wheelEnabled,
          'wheel_tier': wheelTier?.value,
          'target_child_id': targetChildId?.value,
        })
        .select()
        .single();

    return _mapReward(Map<String, dynamic>.from(row));
  }

  @override
  Future<Reward> updateReward(Reward reward) async {
    final row = await _client
        .from('rewards')
        .update({
          'title': reward.title.trim(),
          'description': reward.description?.trim(),
          'category': reward.category.value,
          'icon_key': reward.iconKey,
          'store_enabled': reward.storeEnabled,
          'store_cost_minor': reward.storeCostMinor,
          'wheel_enabled': reward.wheelEnabled,
          'wheel_tier': reward.wheelTier?.value,
          'target_child_id': reward.targetChildId?.value,
          'is_active': reward.isActive,
        })
        .eq('id', reward.id.value)
        .eq('family_id', reward.familyId.value)
        .select()
        .single();

    return _mapReward(Map<String, dynamic>.from(row));
  }

  @override
  Future<void> deleteReward({
    required FamilyId familyId,
    required RewardId rewardId,
  }) async {
    await _client
        .from('rewards')
        .delete()
        .eq('id', rewardId.value)
        .eq('family_id', familyId.value);
  }

  @override
  Future<Reward?> getReward({
    required FamilyId familyId,
    required RewardId rewardId,
  }) async {
    final row = await _client
        .from('rewards')
        .select()
        .eq('id', rewardId.value)
        .eq('family_id', familyId.value)
        .maybeSingle();

    if (row == null) return null;
    return _mapReward(Map<String, dynamic>.from(row));
  }

  @override
  Future<List<Reward>> listFamilyRewards({
    required FamilyId familyId,
    bool? activeOnly,
  }) async {
    var query = _client
        .from('rewards')
        .select()
        .eq('family_id', familyId.value);

    if (activeOnly == true) {
      query = query.eq('is_active', true);
    }

    final rows = await query.order('created_at', ascending: false);
    return rows
        .map((r) => _mapReward(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  @override
  Future<List<Reward>> listStoreRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) async {
    final rows = await _client
        .from('rewards')
        .select()
        .eq('family_id', familyId.value)
        .eq('store_enabled', true)
        .eq('is_active', true)
        .order('store_cost_minor', ascending: true);

    final list = rows
        .map((r) => _mapReward(Map<String, dynamic>.from(r as Map)))
        .toList();

    if (childId != null) {
      return list.where((r) => r.isEligibleFor(childId)).toList();
    }
    return list;
  }

  @override
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'redeem_store_reward',
      params: {
        'p_reward_id': rewardId.value,
        'p_command_id': commandId,
        'p_child_id': childId.value,
      },
    );

    return _mapRedemption(response);
  }

  @override
  Future<RewardRedemption> fulfillRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'fulfill_reward_redemption',
      params: {
        'p_redemption_id': redemptionId.value,
        'p_command_id': commandId,
      },
    );

    return _mapRedemption(response);
  }

  @override
  Future<RewardRedemption> cancelRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
    required String cancellationReason,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'cancel_reward_redemption',
      params: {
        'p_redemption_id': redemptionId.value,
        'p_command_id': commandId,
        'p_cancellation_reason': cancellationReason,
      },
    );

    return _mapRedemption(response);
  }

  @override
  Future<List<RewardRedemption>> listRedemptions({
    required FamilyId familyId,
    ChildId? childId,
    RewardRedemptionStatus? status,
  }) async {
    var query = _client
        .from('reward_redemptions')
        .select()
        .eq('family_id', familyId.value);

    if (childId != null) {
      query = query.eq('child_id', childId.value);
    }
    if (status != null) {
      query = query.eq('status', status.value);
    }

    final rows = await query.order('created_at', ascending: false);
    return rows
        .map((r) => _mapRedemption(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  Reward _mapReward(Map<String, dynamic> row) {
    return Reward(
      id: RewardId(row['id'] as String),
      familyId: FamilyId(row['family_id'] as String),
      title: row['title'] as String,
      description: row['description'] as String?,
      category: RewardCategory.fromString(row['category'] as String),
      iconKey: row['icon_key'] as String? ?? 'default_star',
      storeEnabled: row['store_enabled'] as bool? ?? true,
      storeCostMinor: (row['store_cost_minor'] as num?)?.toInt(),
      wheelEnabled: row['wheel_enabled'] as bool? ?? false,
      wheelTier: row['wheel_tier'] != null
          ? WheelTier.fromString(row['wheel_tier'] as String)
          : null,
      targetChildId: row['target_child_id'] != null
          ? ChildId(row['target_child_id'] as String)
          : null,
      isActive: row['is_active'] as bool? ?? true,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  RewardRedemption _mapRedemption(Map<String, dynamic> row) {
    return RewardRedemption(
      id: RewardRedemptionId(row['id'] as String),
      familyId: FamilyId(row['family_id'] as String),
      childId: ChildId(row['child_id'] as String),
      rewardId: RewardId(row['reward_id'] as String),
      origin: RewardOrigin.fromString(row['origin'] as String),
      rpCostMinor: (row['rp_cost_minor'] as num).toInt(),
      status: RewardRedemptionStatus.fromString(row['status'] as String),
      rewardSnapshot: row['reward_snapshot'] != null
          ? Map<String, dynamic>.from(row['reward_snapshot'] as Map)
          : <String, dynamic>{},
      cancellationReason: row['cancellation_reason'] as String?,
      fulfilledAt: row['fulfilled_at'] != null
          ? DateTime.parse(row['fulfilled_at'] as String)
          : null,
      fulfilledByUserId: row['fulfilled_by_user_id'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}
