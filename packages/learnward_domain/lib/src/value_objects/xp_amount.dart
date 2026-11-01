/// Value object representing Study XP (permanent academic progression points).
///
/// Study XP represents cumulative learning effort, unlocks levels, and is never spent.
final class XpAmount implements Comparable<XpAmount> {
  const XpAmount(this.value)
    : assert(value >= 0, 'XP amount must be non-negative');

  static const XpAmount zero = XpAmount(0);

  final int value;

  XpAmount operator +(XpAmount other) => XpAmount(value + other.value);

  @override
  int compareTo(XpAmount other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is XpAmount && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'XpAmount($value XP)';
}
