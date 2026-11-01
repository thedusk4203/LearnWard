import '../exceptions/domain_exceptions.dart';
import '../value_objects/identifiers.dart';
import '../value_objects/reward_enums.dart';

/// Pure domain entity representing an atomic reward claim and fulfillment record.
final class RewardRedemption {
  RewardRedemption({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.rewardId,
    required this.origin,
    required this.rpCostMinor,
    required this.status,
    required this.rewardSnapshot,
    this.cancellationReason,
    this.fulfilledAt,
    this.fulfilledByUserId,
    required this.createdAt,
    required this.updatedAt,
  }) {
    if (rpCostMinor < 0) {
      throw const InvalidRedemptionException(
        'Redemption rpCostMinor must be non-negative.',
      );
    }
    if (status == RewardRedemptionStatus.cancelled &&
        (cancellationReason == null || cancellationReason!.trim().length < 2)) {
      throw const InvalidRedemptionException(
        'Cancelled redemptions must provide a valid cancellation reason.',
      );
    }
  }

  final RewardRedemptionId id;
  final FamilyId familyId;
  final ChildId childId;
  final RewardId rewardId;
  final RewardOrigin origin;
  final int rpCostMinor;
  final RewardRedemptionStatus status;
  final Map<String, dynamic> rewardSnapshot;
  final String? cancellationReason;
  final DateTime? fulfilledAt;
  final String? fulfilledByUserId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Price in display RP units.
  double get rpCost => rpCostMinor / 100.0;

  bool get isPending => status == RewardRedemptionStatus.pendingFulfillment;
  bool get isFulfilled => status == RewardRedemptionStatus.fulfilled;
  bool get isCancelled => status == RewardRedemptionStatus.cancelled;
  bool get isTerminal => status.isTerminal;

  String get rewardTitle => rewardSnapshot['title'] as String? ?? 'Reward';
  String? get rewardDescription => rewardSnapshot['description'] as String?;
  String get rewardCategory =>
      rewardSnapshot['category'] as String? ?? 'privilege';
  String get iconKey => rewardSnapshot['icon_key'] as String? ?? 'default_star';

  RewardRedemption copyWith({
    RewardRedemptionStatus? status,
    String? cancellationReason,
    DateTime? fulfilledAt,
    String? fulfilledByUserId,
    DateTime? updatedAt,
  }) {
    return RewardRedemption(
      id: id,
      familyId: familyId,
      childId: childId,
      rewardId: rewardId,
      origin: origin,
      rpCostMinor: rpCostMinor,
      status: status ?? this.status,
      rewardSnapshot: rewardSnapshot,
      cancellationReason: cancellationReason ?? this.cancellationReason,
      fulfilledAt: fulfilledAt ?? this.fulfilledAt,
      fulfilledByUserId: fulfilledByUserId ?? this.fulfilledByUserId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RewardRedemption && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'RewardRedemption(id: $id, child: $childId, reward: $rewardTitle, cost: $rpCost RP, status: ${status.value})';
}
