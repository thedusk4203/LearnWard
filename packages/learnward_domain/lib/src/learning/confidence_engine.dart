import 'learning_enums.dart';
import 'learning_models.dart';

/// Result of evaluating confidence and mastery bands for a node at a given point in time.
final class NodeConfidenceEvaluation {
  const NodeConfidenceEvaluation({
    required this.confidenceUnits,
    required this.distinctRecentVles,
    required this.confidenceBand,
    required this.masteryBand,
  });

  final double confidenceUnits;
  final int distinctRecentVles;
  final ConfidenceBand confidenceBand;
  final MasteryBand masteryBand;
}

/// Pure Dart implementation of LearnWard Confidence Engine v0.1.
class ConfidenceEngine {
  const ConfidenceEngine();

  static const int rollingWindowDays = 60;

  /// Evaluates confidence units, confidence band, and final mastery band for a node
  /// relative to server-authoritative [asOf] timestamp.
  static NodeConfidenceEvaluation evaluate({
    required double? masteryScore,
    required Iterable<LearningEvidenceEvent> evidence,
    required DateTime asOf,
  }) {
    final windowStart = asOf.subtract(const Duration(days: rollingWindowDays));
    final distinctVles = <String>{};
    var totalUnits = 0.0;

    for (final ev in evidence) {
      if (ev.effectiveOccurredAt.isAfter(asOf)) continue;
      if (ev.effectiveOccurredAt.isBefore(windowStart)) continue;

      totalUnits += ev.specificityWeight * ev.levelWeight;
      distinctVles.add(ev.verifiedLearningEventId);
    }

    final roundedUnits = (totalUnits * 100).round() / 100.0;
    final distinctCount = distinctVles.length;

    // Evaluate ConfidenceBand
    final ConfidenceBand confBand;
    if (roundedUnits > 3.5 && distinctCount >= 2) {
      confBand = ConfidenceBand.high;
    } else if (roundedUnits >= 1.5) {
      confBand = ConfidenceBand.medium;
    } else {
      confBand = ConfidenceBand.low;
    }

    // Evaluate MasteryBand
    final MasteryBand mastBand;
    if (masteryScore == null || distinctCount == 0) {
      mastBand = MasteryBand.noData;
    } else if (masteryScore >= 85.0 &&
        confBand == ConfidenceBand.high &&
        distinctCount >= 2) {
      mastBand = MasteryBand.mastered;
    } else if (masteryScore >= 85.0) {
      mastBand = MasteryBand.masteryCandidate;
    } else if (masteryScore >= 70.0) {
      mastBand = MasteryBand.secure;
    } else if (masteryScore >= 50.0) {
      mastBand = MasteryBand.developing;
    } else {
      mastBand = MasteryBand.emerging;
    }

    return NodeConfidenceEvaluation(
      confidenceUnits: roundedUnits,
      distinctRecentVles: distinctCount,
      confidenceBand: confBand,
      masteryBand: mastBand,
    );
  }
}
