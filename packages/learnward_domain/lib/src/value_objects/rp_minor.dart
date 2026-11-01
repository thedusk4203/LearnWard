/// Value object representing Reward Points (RP) stored in integer minor units.
///
/// 100 minor units equals 1.00 RP (e.g. 1250 rp_minor = 12.50 RP).
/// This prevents binary floating point representation issues and rounding drift.
final class RpMinor implements Comparable<RpMinor> {
  const RpMinor(this.value);

  /// Conversion factor between major currency units and minor units (100 minor = 1.00 RP).
  static const int factor = 100;

  static const RpMinor zero = RpMinor(0);

  /// Integer minor units.
  final int value;

  /// Returns the value as a floating point decimal RP for presentation only.
  double toDouble() => value / factor;

  /// Creates [RpMinor] from a decimal RP value with deterministic rounding.
  factory RpMinor.fromDouble(double rp) {
    if (!rp.isFinite) {
      throw ArgumentError('RP must be a finite number: $rp');
    }
    return RpMinor((rp * factor).round());
  }

  /// Formats the RP value to two decimal places (e.g. "12.50", "0.00").
  String formatRp() {
    return (value / factor).toStringAsFixed(2);
  }

  RpMinor operator +(RpMinor other) => RpMinor(value + other.value);
  RpMinor operator -(RpMinor other) => RpMinor(value - other.value);
  RpMinor operator *(num multiplier) => RpMinor((value * multiplier).round());

  bool get isNegative => value < 0;
  bool get isZero => value == 0;
  bool get isPositive => value > 0;

  @override
  int compareTo(RpMinor other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RpMinor && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'RpMinor($value [${formatRp()} RP])';
}
