import '../value_objects/rp_minor.dart';
import '../value_objects/xp_amount.dart';

/// Itemized explainable breakdown of a Growth Engine calculation.
///
/// Ensures parents and children can answer "Why did I get this amount?" without opaque formulas.
final class GrowthBreakdown {
  const GrowthBreakdown({
    required this.normalizedScore,
    required this.baselineScore,
    required this.baselineSampleCount,
    required this.growthDelta,
    required this.historicalBest,
    required this.scoreRpMinor,
    required this.growthRpMinor,
    required this.highPerformerRpMinor,
    required this.goalRpMinor,
    required this.personalBestRpMinor,
    required this.difficultyRpMinor,
    required this.recoveryRpMinor,
    required this.belowLevelAdjustment,
    required this.totalRpMinor,
    required this.xpAwarded,
  });

  /// The normalized score on a 0–10 scale.
  final double normalizedScore;

  /// Rolling baseline calculated as mean of last 3 comparable verified results, or null if < 3 records.
  final double? baselineScore;

  /// Number of comparable samples used (at least 3 required for a valid baseline).
  final int baselineSampleCount;

  /// Improvement delta (normalizedScore - baselineScore), or null if baseline is unavailable.
  final double? growthDelta;

  /// Highest comparable score prior to this event, or null if no prior history.
  final double? historicalBest;

  /// Base score component in integer RP minor units (100 = 1.00 RP).
  final RpMinor scoreRpMinor;

  /// Growth bonus component based on improvement delta vs baseline.
  final RpMinor growthRpMinor;

  /// High-performer maintenance bonus (+1 RP if baseline >= 8.5 and current >= 8.5).
  final RpMinor highPerformerRpMinor;

  /// Goal achievement bonus (deferred in Phase 3, 0 RP).
  final RpMinor goalRpMinor;

  /// Personal best bonus (+1 RP if exceeds historical best by at least 0.25).
  final RpMinor personalBestRpMinor;

  /// Difficulty / challenge bonus (+1 for hard, +2 for challenge if score >= 5.0).
  final RpMinor difficultyRpMinor;

  /// Mistake recovery bonus (deferred in Phase 3, 0 RP).
  final RpMinor recoveryRpMinor;

  /// Whether anti-farming reduction was applied for below-level difficulty.
  final bool belowLevelAdjustment;

  /// Total authoritative RP award.
  final RpMinor totalRpMinor;

  /// Total permanent Study XP awarded (10 + 2 * total RP).
  final XpAmount xpAwarded;

  /// Whether a trustworthy 3-sample baseline existed.
  bool get hasBaseline => baselineScore != null && baselineSampleCount >= 3;
}
