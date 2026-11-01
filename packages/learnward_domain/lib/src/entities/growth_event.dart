import '../value_objects/identifiers.dart';
import '../value_objects/rp_minor.dart';
import '../value_objects/xp_amount.dart';

/// Immutable calculation audit record generated when a VerifiedLearningEvent is processed.
final class GrowthEvent {
  const GrowthEvent({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.verifiedLearningEventId,
    required this.assessmentId,
    required this.engineVersion,
    required this.normalizedScore,
    this.baselineScore,
    required this.baselineSampleCount,
    this.growthDelta,
    this.historicalBest,
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
    required this.inputsSnapshot,
    required this.createdAt,
  });

  final String id;
  final FamilyId familyId;
  final ChildId childId;
  final String verifiedLearningEventId;
  final AssessmentId assessmentId;
  final String engineVersion;

  final double normalizedScore;
  final double? baselineScore;
  final int baselineSampleCount;
  final double? growthDelta;
  final double? historicalBest;

  final RpMinor scoreRpMinor;
  final RpMinor growthRpMinor;
  final RpMinor highPerformerRpMinor;
  final RpMinor goalRpMinor;
  final RpMinor personalBestRpMinor;
  final RpMinor difficultyRpMinor;
  final RpMinor recoveryRpMinor;
  final bool belowLevelAdjustment;
  final RpMinor totalRpMinor;
  final XpAmount xpAwarded;

  final Map<String, dynamic> inputsSnapshot;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is GrowthEvent && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'GrowthEvent($id, score: $normalizedScore, total: ${totalRpMinor.formatRp()} RP, ${xpAwarded.value} XP)';
}
