import '../exceptions/domain_exceptions.dart';
import '../value_objects/identifiers.dart';
import '../value_objects/reward_enums.dart';

/// Pure domain entity representing a family reward catalog item.
final class Reward {
  Reward({
    required this.id,
    required this.familyId,
    required this.title,
    this.description,
    required this.category,
    this.iconKey = 'default_star',
    this.storeEnabled = true,
    this.storeCostMinor,
    this.wheelEnabled = false,
    this.wheelTier,
    this.targetChildId,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  }) {
    final trimmedTitle = title.trim();
    if (trimmedTitle.length < 2 || trimmedTitle.length > 100) {
      throw const InvalidRewardException(
        'Reward title must be between 2 and 100 characters.',
      );
    }
    if (description != null && description!.trim().length > 500) {
      throw const InvalidRewardException(
        'Reward description cannot exceed 500 characters.',
      );
    }
    if (storeEnabled) {
      if (storeCostMinor == null || storeCostMinor! <= 0) {
        throw const InvalidRewardException(
          'Store-enabled rewards must have a positive store cost in minor units.',
        );
      }
    }
    if (wheelEnabled && wheelTier == null) {
      throw const InvalidRewardException(
        'Wheel-enabled rewards must define a wheel tier.',
      );
    }
  }

  final RewardId id;
  final FamilyId familyId;
  final String title;
  final String? description;
  final RewardCategory category;
  final String iconKey;
  final bool storeEnabled;
  final int? storeCostMinor;
  final bool wheelEnabled;
  final WheelTier? wheelTier;
  final ChildId? targetChildId;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Store price in display RP units ($1.00\text{ RP} = 100\text{ minor units}$).
  double? get storeCostRp =>
      storeCostMinor != null ? storeCostMinor! / 100.0 : null;

  /// Whether a specific child is eligible to redeem/win this reward.
  bool isEligibleFor(ChildId childId) =>
      targetChildId == null || targetChildId == childId;

  Reward copyWith({
    String? title,
    String? description,
    RewardCategory? category,
    String? iconKey,
    bool? storeEnabled,
    int? storeCostMinor,
    bool? wheelEnabled,
    WheelTier? wheelTier,
    ChildId? targetChildId,
    bool? isActive,
    DateTime? updatedAt,
  }) {
    return Reward(
      id: id,
      familyId: familyId,
      title: title ?? this.title,
      description: description ?? this.description,
      category: category ?? this.category,
      iconKey: iconKey ?? this.iconKey,
      storeEnabled: storeEnabled ?? this.storeEnabled,
      storeCostMinor: storeCostMinor ?? this.storeCostMinor,
      wheelEnabled: wheelEnabled ?? this.wheelEnabled,
      wheelTier: wheelTier ?? this.wheelTier,
      targetChildId: targetChildId ?? this.targetChildId,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Reward && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Reward(id: $id, title: $title, category: ${category.value}, costMinor: $storeCostMinor, active: $isActive)';
}
