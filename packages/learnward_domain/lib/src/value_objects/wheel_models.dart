import '../value_objects/identifiers.dart';
import '../value_objects/reward_enums.dart';

/// An individual reward in the active Wheel pool with its calculated weight and interval.
final class WheelPoolItem {
  WheelPoolItem({
    required this.rewardId,
    required this.title,
    required this.category,
    required this.iconKey,
    required this.tier,
    required this.weight,
    required this.intervalStart,
    required this.intervalEnd,
    required this.probabilityPct,
  });

  final RewardId rewardId;
  final String title;
  final RewardCategory category;
  final String iconKey;
  final WheelTier tier;
  final int weight;
  final int intervalStart;
  final int intervalEnd;
  final double probabilityPct;

  factory WheelPoolItem.fromJson(Map<String, dynamic> json) {
    return WheelPoolItem(
      rewardId: RewardId(json['reward_id'] as String),
      title: json['title'] as String,
      category: RewardCategory.fromString(json['category'] as String),
      iconKey: json['icon_key'] as String? ?? 'default_star',
      tier: WheelTier.fromString(json['tier'] as String),
      weight: json['weight'] as int,
      intervalStart: json['interval_start'] as int,
      intervalEnd: json['interval_end'] as int,
      probabilityPct: (json['probability_pct'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'reward_id': rewardId.value,
      'title': title,
      'category': category.toJson(),
      'icon_key': iconKey,
      'tier': tier.toJson(),
      'weight': weight,
      'interval_start': intervalStart,
      'interval_end': intervalEnd,
      'probability_pct': probabilityPct,
    };
  }
}

/// Immutable server-committed selection/audit snapshot of the Wheel pool and random draw state at spin time.
final class WheelSelectionSnapshot {
  WheelSelectionSnapshot({
    required this.wheelConfigVersion,
    required this.spinCostMinor,
    required this.deterministicOrdering,
    required this.totalWeight,
    required this.randomDraw,
    required this.winningRewardId,
    required this.orderedPool,
  });

  final String wheelConfigVersion;
  final int spinCostMinor;
  final String deterministicOrdering;
  final int totalWeight;
  final int randomDraw;
  final RewardId winningRewardId;
  final List<WheelPoolItem> orderedPool;

  factory WheelSelectionSnapshot.fromJson(Map<String, dynamic> json) {
    final rawPool = json['ordered_pool'] as List<dynamic>? ?? [];
    return WheelSelectionSnapshot(
      wheelConfigVersion:
          json['wheel_config_version'] as String? ?? 'wheel-v0.1',
      spinCostMinor: json['spin_cost_minor'] as int? ?? 1000,
      deterministicOrdering:
          json['deterministic_ordering'] as String? ?? 'reward_id_asc',
      totalWeight: json['total_weight'] as int,
      randomDraw: json['random_draw'] as int,
      winningRewardId: RewardId(json['winning_reward_id'] as String),
      orderedPool: rawPool
          .map((item) => WheelPoolItem.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'wheel_config_version': wheelConfigVersion,
      'spin_cost_minor': spinCostMinor,
      'deterministic_ordering': deterministicOrdering,
      'total_weight': totalWeight,
      'random_draw': randomDraw,
      'winning_reward_id': winningRewardId.value,
      'ordered_pool': orderedPool.map((p) => p.toJson()).toList(),
    };
  }
}

/// Authoritative result returned by the spin_reward_wheel RPC.
final class WheelSpinResult {
  WheelSpinResult({
    required this.spinId,
    required this.redemptionId,
    required this.familyId,
    required this.childId,
    required this.rewardId,
    required this.rewardTitle,
    required this.rewardCategory,
    required this.rewardIconKey,
    required this.wheelTier,
    required this.spinCostMinor,
    required this.newBalanceMinor,
    required this.selectionSnapshot,
    required this.createdAt,
  });

  final WheelSpinId spinId;
  final RewardRedemptionId redemptionId;
  final FamilyId familyId;
  final ChildId childId;
  final RewardId rewardId;
  final String rewardTitle;
  final RewardCategory rewardCategory;
  final String rewardIconKey;
  final WheelTier wheelTier;
  final int spinCostMinor;
  final int newBalanceMinor;
  final WheelSelectionSnapshot selectionSnapshot;
  final DateTime createdAt;

  double get spinCostRp => spinCostMinor / 100.0;
  double get newBalanceRp => newBalanceMinor / 100.0;

  factory WheelSpinResult.fromJson(Map<String, dynamic> json) {
    return WheelSpinResult(
      spinId: WheelSpinId(json['spin_id'] as String),
      redemptionId: RewardRedemptionId(json['redemption_id'] as String),
      familyId: FamilyId(json['family_id'] as String),
      childId: ChildId(json['child_id'] as String),
      rewardId: RewardId(json['reward_id'] as String),
      rewardTitle: json['reward_title'] as String,
      rewardCategory: RewardCategory.fromString(
        json['reward_category'] as String,
      ),
      rewardIconKey: json['reward_icon_key'] as String? ?? 'default_star',
      wheelTier: WheelTier.fromString(json['wheel_tier'] as String),
      spinCostMinor: json['spin_cost_minor'] as int,
      newBalanceMinor: json['new_balance_minor'] as int,
      selectionSnapshot: WheelSelectionSnapshot.fromJson(
        json['selection_snapshot'] as Map<String, dynamic>,
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'spin_id': spinId.value,
      'redemption_id': redemptionId.value,
      'family_id': familyId.value,
      'child_id': childId.value,
      'reward_id': rewardId.value,
      'reward_title': rewardTitle,
      'reward_category': rewardCategory.toJson(),
      'reward_icon_key': rewardIconKey,
      'wheel_tier': wheelTier.toJson(),
      'spin_cost_minor': spinCostMinor,
      'new_balance_minor': newBalanceMinor,
      'selection_snapshot': selectionSnapshot.toJson(),
      'created_at': createdAt.toIso8601String(),
    };
  }
}

/// Server-authoritative status of the Wheel for a specific child, derived from
/// family wheel settings and timezone-bounded daily calendar calculations.
final class WheelStatus {
  WheelStatus({
    required this.familyId,
    required this.childId,
    required this.spinCostMinor,
    required this.dailySpinCap,
    required this.isEnabled,
    required this.spinsToday,
    required this.spinsRemaining,
    required this.eligibleRewardCount,
    required this.localDayStart,
    required this.localDayEnd,
  });

  final FamilyId familyId;
  final ChildId childId;
  final int spinCostMinor;
  final int dailySpinCap;
  final bool isEnabled;
  final int spinsToday;
  final int spinsRemaining;
  final int eligibleRewardCount;
  final DateTime localDayStart;
  final DateTime localDayEnd;

  double get spinCostRp => spinCostMinor / 100.0;
  bool get canSpin =>
      isEnabled && spinsRemaining > 0 && eligibleRewardCount >= 3;

  factory WheelStatus.fromJson(Map<String, dynamic> json) {
    return WheelStatus(
      familyId: FamilyId(json['family_id'] as String),
      childId: ChildId(json['child_id'] as String),
      spinCostMinor: json['spin_cost_minor'] as int? ?? 1000,
      dailySpinCap: json['daily_spin_cap'] as int? ?? 3,
      isEnabled: json['is_enabled'] as bool? ?? true,
      spinsToday: json['spins_today'] as int? ?? 0,
      spinsRemaining: json['spins_remaining'] as int? ?? 0,
      eligibleRewardCount: json['eligible_reward_count'] as int? ?? 0,
      localDayStart: DateTime.parse(json['local_day_start'] as String),
      localDayEnd: DateTime.parse(json['local_day_end'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'family_id': familyId.value,
      'child_id': childId.value,
      'spin_cost_minor': spinCostMinor,
      'daily_spin_cap': dailySpinCap,
      'is_enabled': isEnabled,
      'spins_today': spinsToday,
      'spins_remaining': spinsRemaining,
      'eligible_reward_count': eligibleRewardCount,
      'local_day_start': localDayStart.toIso8601String(),
      'local_day_end': localDayEnd.toIso8601String(),
    };
  }
}
