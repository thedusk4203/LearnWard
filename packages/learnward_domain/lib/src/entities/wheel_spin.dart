import '../value_objects/identifiers.dart';
import '../value_objects/reward_enums.dart';
import '../value_objects/wheel_models.dart';

/// Pure domain entity representing an immutable wheel spin record.
final class WheelSpin {
  WheelSpin({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.rewardId,
    required this.redemptionId,
    this.origin = RewardOrigin.wheel,
    required this.spinCostMinor,
    required this.selectionSnapshot,
    required this.createdAt,
  });

  final WheelSpinId id;
  final FamilyId familyId;
  final ChildId childId;
  final RewardId rewardId;
  final RewardRedemptionId redemptionId;
  final RewardOrigin origin;
  final int spinCostMinor;
  final WheelSelectionSnapshot selectionSnapshot;
  final DateTime createdAt;

  double get spinCostRp => spinCostMinor / 100.0;

  factory WheelSpin.fromJson(Map<String, dynamic> json) {
    return WheelSpin(
      id: WheelSpinId(json['id'] as String),
      familyId: FamilyId(json['family_id'] as String),
      childId: ChildId(json['child_id'] as String),
      rewardId: RewardId(json['reward_id'] as String),
      redemptionId: RewardRedemptionId(json['redemption_id'] as String),
      origin: json['origin'] != null
          ? RewardOrigin.fromString(json['origin'] as String)
          : RewardOrigin.wheel,
      spinCostMinor: json['spin_cost_minor'] as int,
      selectionSnapshot: WheelSelectionSnapshot.fromJson(
        json['selection_snapshot'] as Map<String, dynamic>,
      ),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id.value,
      'family_id': familyId.value,
      'child_id': childId.value,
      'reward_id': rewardId.value,
      'redemption_id': redemptionId.value,
      'origin': origin.toJson(),
      'spin_cost_minor': spinCostMinor,
      'selection_snapshot': selectionSnapshot.toJson(),
      'created_at': createdAt.toIso8601String(),
    };
  }
}
