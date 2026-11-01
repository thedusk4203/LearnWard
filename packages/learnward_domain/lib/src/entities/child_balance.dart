import '../value_objects/identifiers.dart';
import '../value_objects/rp_minor.dart';
import '../value_objects/xp_amount.dart';

/// Projected read model of a child's cumulative Study XP and spendable Reward Points (RP).
///
/// Ledgers remain the single source of truth; this projection enables low-latency reads.
final class ChildBalance {
  const ChildBalance({
    required this.familyId,
    required this.childId,
    required this.xpTotal,
    required this.rpBalanceMinor,
    required this.updatedAt,
  });

  final FamilyId familyId;
  final ChildId childId;

  /// Cumulative Study XP (progression). Never decremented or spent.
  final XpAmount xpTotal;

  /// Current spendable Reward Points in integer minor units (100 = 1.00 RP).
  final RpMinor rpBalanceMinor;

  final DateTime updatedAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChildBalance &&
          other.familyId == familyId &&
          other.childId == childId;

  @override
  int get hashCode => Object.hash(familyId, childId);

  @override
  String toString() =>
      'ChildBalance($childId: ${xpTotal.value} XP, ${rpBalanceMinor.formatRp()} RP)';
}
