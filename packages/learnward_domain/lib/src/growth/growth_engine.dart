import '../value_objects/assessment_enums.dart';
import '../value_objects/rp_minor.dart';
import '../value_objects/xp_amount.dart';
import 'growth_breakdown.dart';
import 'growth_input.dart';
import 'growth_result.dart';

/// Pure, deterministic Growth Engine v0.1 implementation.
///
/// Converts a verified academic result into an explainable combination of:
/// - Reward Points (RP in integer minor units: 100 = 1.00 RP),
/// - Study XP (permanent academic progression points).
///
/// Implements the frozen formula:
/// `RP = Score + Growth + Goal + Personal Best + Challenge + Recovery`
/// with integer minor units and unambiguous rounding policies.
final class GrowthEngine {
  const GrowthEngine._();

  /// Canonical engine version identifier for auditability and replay stability.
  static const String engineVersion = 'growth-v0.1';

  /// Minimum historical sample count required to compute a valid rolling baseline.
  static const int minimumBaselineSamples = 3;

  /// High-performer ceiling score threshold (8.5 / 10.0).
  static const double highPerformerThreshold = 8.5;

  /// Minimum margin required to establish a new Personal Best (+0.25 vs prior best).
  static const double personalBestMargin = 0.25;

  /// Minimum score threshold required to qualify for the Challenge difficulty bonus (5.0 / 10.0).
  static const double challengeQualificationScore = 5.0;

  /// Anti-farming factor applied to base RP for below-level activities (25%).
  static const double belowLevelFactor = 0.25;

  /// Pure deterministic calculation of Growth, RP components, and Study XP.
  static GrowthResult calculate(GrowthInput input) {
    final currentScoreValue = input.currentScore.value;

    // 1. Filter strictly prior comparable records:
    // - Must not be the current event.
    // - Must match canonical subjectKey.
    // - Must have occurred strictly before the current event (or verified earlier if concurrent).
    // - Must match assessment type compatibility band (evaluative: quiz/exam, formative: homework/practice, other).
    // - Must match difficulty compatibility band (standard: normal/hard, challenge, below_level).
    final comparables = input.comparableHistory.where((c) {
      if (c.id == input.currentEventId) return false;
      if (c.subjectKey != input.subjectKey) return false;
      if (c.gradeLevel != input.gradeLevel) return false;

      final isPrior =
          c.occurredAt.isBefore(input.occurredAt) ||
          (c.occurredAt.isAtSameMomentAs(input.occurredAt) &&
              c.verifiedAt.isBefore(input.verifiedAt));
      if (!isPrior) return false;

      // Assessment type compatibility
      if (!input.assessmentType.isCompatibleWith(c.assessmentType)) {
        return false;
      }

      // Difficulty band compatibility
      if (!input.difficulty.isCompatibleWith(c.difficulty)) {
        return false;
      }

      return true;
    }).toList();

    // 2. Sort chronologically descending (most recent prior result first).
    comparables.sort((a, b) {
      final timeCmp = b.occurredAt.compareTo(a.occurredAt);
      if (timeCmp != 0) return timeCmp;
      return b.verifiedAt.compareTo(a.verifiedAt);
    });

    // 3. Compute rolling baseline from the last 3 comparable records.
    final double? baselineScore;
    final int baselineSampleCount;
    final double? growthDelta;

    if (comparables.length >= minimumBaselineSamples) {
      final lastThree = comparables.take(minimumBaselineSamples).toList();
      final sum = lastThree.fold<double>(
        0.0,
        (acc, c) => acc + c.normalizedScore,
      );
      baselineScore = _roundToTwoDecimals(sum / minimumBaselineSamples);
      baselineSampleCount = minimumBaselineSamples;
      growthDelta = _roundToTwoDecimals(currentScoreValue - baselineScore);
    } else {
      baselineScore = null;
      baselineSampleCount = comparables.length;
      growthDelta = null;
    }

    // 4. Compute prior historical best (across all comparable prior records).
    final double? historicalBest;
    if (comparables.isNotEmpty) {
      final best = comparables
          .map((c) => c.normalizedScore)
          .reduce((a, b) => a > b ? a : b);
      historicalBest = _roundToTwoDecimals(best);
    } else {
      historicalBest = null;
    }

    // 5. Calculate economic components based on difficulty & performance.
    final bool isBelowLevel =
        input.difficulty == AssessmentDifficulty.belowLevel;
    final int standardScoreMinor = (currentScoreValue * RpMinor.factor).round();

    final RpMinor scoreRpMinor;
    final RpMinor growthRpMinor;
    final RpMinor highPerformerRpMinor;
    final RpMinor personalBestRpMinor;
    final RpMinor difficultyRpMinor;
    final RpMinor goalRpMinor = RpMinor.zero; // Explicitly deferred in Phase 3
    final RpMinor recoveryRpMinor =
        RpMinor.zero; // Explicitly deferred in Phase 3

    if (isBelowLevel) {
      // Below-level protection:
      // Base RP reduced to 25% of standard base amount.
      // Growth and Personal Best bonuses disabled to prevent easy farming.
      scoreRpMinor = RpMinor((standardScoreMinor * belowLevelFactor).round());
      growthRpMinor = RpMinor.zero;
      highPerformerRpMinor = RpMinor.zero;
      personalBestRpMinor = RpMinor.zero;
      difficultyRpMinor = RpMinor.zero;
    } else {
      scoreRpMinor = RpMinor(standardScoreMinor);

      // Growth bonus:
      // delta < +0.50  -> +0 RP
      // +0.50 .. +0.99 -> +1 RP
      // +1.00 .. +1.49 -> +2 RP
      // +1.50 .. +1.99 -> +3 RP
      // >= +2.00       -> +4 RP
      if (growthDelta != null) {
        if (growthDelta >= 2.0) {
          growthRpMinor = const RpMinor(400);
        } else if (growthDelta >= 1.5) {
          growthRpMinor = const RpMinor(300);
        } else if (growthDelta >= 1.0) {
          growthRpMinor = const RpMinor(200);
        } else if (growthDelta >= 0.5) {
          growthRpMinor = const RpMinor(100);
        } else {
          growthRpMinor = RpMinor.zero;
        }
      } else {
        growthRpMinor = RpMinor.zero;
      }

      // High-performer protection:
      // baseline >= 8.5 AND current >= 8.5 -> +1 RP (100 minor)
      if (baselineScore != null &&
          baselineScore >= highPerformerThreshold &&
          currentScoreValue >= highPerformerThreshold) {
        highPerformerRpMinor = const RpMinor(100);
      } else {
        highPerformerRpMinor = RpMinor.zero;
      }

      // Personal Best bonus:
      // Exceeds prior comparable historical best by at least 0.25 -> +1 RP (100 minor)
      if (historicalBest != null &&
          _roundToTwoDecimals(currentScoreValue - historicalBest) >=
              personalBestMargin) {
        personalBestRpMinor = const RpMinor(100);
      } else {
        personalBestRpMinor = RpMinor.zero;
      }

      // Difficulty bonus:
      // normal    -> +0 RP
      // hard      -> +1 RP
      // challenge -> +2 RP only if score >= 5.0
      switch (input.difficulty) {
        case AssessmentDifficulty.challenge:
          difficultyRpMinor = currentScoreValue >= challengeQualificationScore
              ? const RpMinor(200)
              : RpMinor.zero;
        case AssessmentDifficulty.hard:
          difficultyRpMinor = const RpMinor(100);
        case AssessmentDifficulty.normal:
        case AssessmentDifficulty.belowLevel:
          difficultyRpMinor = RpMinor.zero;
      }
    }

    final totalRpMinor =
        scoreRpMinor +
        growthRpMinor +
        highPerformerRpMinor +
        personalBestRpMinor +
        difficultyRpMinor +
        goalRpMinor +
        recoveryRpMinor;

    // 6. Calculate Study XP:
    // XP = 10 + 2 * RP_awarded
    final int xpValue =
        10 + (2.0 * totalRpMinor.value / RpMinor.factor).round();
    final xpAwarded = XpAmount(xpValue);

    final breakdown = GrowthBreakdown(
      normalizedScore: _roundToTwoDecimals(currentScoreValue),
      baselineScore: baselineScore,
      baselineSampleCount: baselineSampleCount,
      growthDelta: growthDelta,
      historicalBest: historicalBest,
      scoreRpMinor: scoreRpMinor,
      growthRpMinor: growthRpMinor,
      highPerformerRpMinor: highPerformerRpMinor,
      goalRpMinor: goalRpMinor,
      personalBestRpMinor: personalBestRpMinor,
      difficultyRpMinor: difficultyRpMinor,
      recoveryRpMinor: recoveryRpMinor,
      belowLevelAdjustment: isBelowLevel,
      totalRpMinor: totalRpMinor,
      xpAwarded: xpAwarded,
    );

    final inputsSnapshot = <String, dynamic>{
      'engine_version': engineVersion,
      'current_event_id': input.currentEventId,
      'subject_key': input.subjectKey.value,
      'grade_level': input.gradeLevel,
      'normalized_score': currentScoreValue,
      'difficulty': input.difficulty.value,
      'assessment_type': input.assessmentType.value,
      'occurred_at': input.occurredAt.toIso8601String(),
      'verified_at': input.verifiedAt.toIso8601String(),
      'baseline_samples_used': comparables
          .take(minimumBaselineSamples)
          .map(
            (c) => {
              'id': c.id,
              'score': c.normalizedScore,
              'occurred_at': c.occurredAt.toIso8601String(),
              'assessment_type': c.assessmentType.value,
              'difficulty': c.difficulty.value,
              'grade_level': c.gradeLevel,
            },
          )
          .toList(),
      'comparable_count': comparables.length,
      'historical_best': historicalBest,
    };

    return GrowthResult(
      engineVersion: engineVersion,
      breakdown: breakdown,
      inputsSnapshot: inputsSnapshot,
    );
  }

  static double _roundToTwoDecimals(double value) {
    return (value * 100).round() / 100.0;
  }
}
