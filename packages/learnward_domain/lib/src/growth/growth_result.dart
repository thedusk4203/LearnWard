import 'growth_breakdown.dart';

/// Complete deterministic result produced by the Growth Engine.
final class GrowthResult {
  const GrowthResult({
    required this.engineVersion,
    required this.breakdown,
    required this.inputsSnapshot,
  });

  /// The version of the Growth Engine that produced this calculation.
  final String engineVersion;

  /// Detailed explainable breakdown of the calculation.
  final GrowthBreakdown breakdown;

  /// Audit snapshot of inputs and comparable history used at processing time.
  final Map<String, dynamic> inputsSnapshot;
}
