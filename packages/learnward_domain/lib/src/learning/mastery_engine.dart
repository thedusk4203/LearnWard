import 'learning_models.dart';

/// Calculation step snapshot for mastery audit trail.
final class MasteryCalculationStep {
  const MasteryCalculationStep({
    required this.step,
    required this.type,
    required this.verifiedLearningEventId,
    required this.performancePct,
    required this.alphaEffective,
    required this.resultScore,
  });

  final int step;
  final String type;
  final String verifiedLearningEventId;
  final double performancePct;
  final double alphaEffective;
  final double resultScore;

  Map<String, dynamic> toJson() => {
    'step': step,
    'type': type,
    'vle_id': verifiedLearningEventId,
    'performance_pct': performancePct,
    'alpha_effective': alphaEffective,
    'result_score': resultScore,
  };
}

/// Result of evaluating or rebuilding mastery for a learning node.
final class NodeMasteryRebuildResult {
  const NodeMasteryRebuildResult({
    required this.masteryScore,
    required this.effectiveEvidenceCount,
    required this.distinctAssessmentCount,
    required this.steps,
  });

  final double masteryScore;
  final int effectiveEvidenceCount;
  final int distinctAssessmentCount;
  final List<MasteryCalculationStep> steps;
}

/// Pure Dart implementation of LearnWard Mastery Engine v0.1.
class MasteryEngine {
  const MasteryEngine();

  static const double baseAlpha = 0.35;

  /// Calculates effective alpha from node specificity weight and assessment level weight.
  /// Governed by: alpha_effective = round(0.35 * specificity_weight * level_weight, 4)
  static double calculateEffectiveAlpha({
    required double specificityWeight,
    required double levelWeight,
  }) {
    final raw = baseAlpha * specificityWeight * levelWeight;
    return (raw * 10000).round() / 10000.0;
  }

  /// Sorts learning evidence events in canonical academic chronology:
  /// 1. effective_occurred_at ASC
  /// 2. verified_at ASC
  /// 3. verified_learning_event_id ASC
  static List<LearningEvidenceEvent> sortCanonical(
    Iterable<LearningEvidenceEvent> evidence,
  ) {
    final list = List<LearningEvidenceEvent>.from(evidence);
    list.sort((a, b) {
      final occCmp = a.effectiveOccurredAt.compareTo(b.effectiveOccurredAt);
      if (occCmp != 0) return occCmp;
      final verCmp = a.verifiedAt.compareTo(b.verifiedAt);
      if (verCmp != 0) return verCmp;
      return a.verifiedLearningEventId.compareTo(b.verifiedLearningEventId);
    });
    return list;
  }

  /// Rebuilds mastery score for a single learning node from complete historical evidence.
  /// Follows Option A initialization (M_1 = P_1) and subsequent EWMA updates.
  static NodeMasteryRebuildResult rebuildNodeMastery(
    Iterable<LearningEvidenceEvent> evidence,
  ) {
    final sorted = sortCanonical(evidence);
    if (sorted.isEmpty) {
      return const NodeMasteryRebuildResult(
        masteryScore: 0.0,
        effectiveEvidenceCount: 0,
        distinctAssessmentCount: 0,
        steps: [],
      );
    }

    double currentScore = 0.0;
    final steps = <MasteryCalculationStep>[];
    final distinctVles = <String>{};

    for (var i = 0; i < sorted.length; i++) {
      final ev = sorted[i];
      distinctVles.add(ev.verifiedLearningEventId);

      if (i == 0) {
        // Option A initialization: M_1 = P_1
        currentScore = (ev.performancePct * 100).round() / 100.0;
        steps.add(
          MasteryCalculationStep(
            step: 1,
            type: 'initial',
            verifiedLearningEventId: ev.verifiedLearningEventId,
            performancePct: ev.performancePct,
            alphaEffective: 1.0,
            resultScore: currentScore,
          ),
        );
      } else {
        // Subsequent observations: EWMA
        final alphaEff = calculateEffectiveAlpha(
          specificityWeight: ev.specificityWeight,
          levelWeight: ev.levelWeight,
        );
        final delta = ev.performancePct - currentScore;
        final updated = currentScore + alphaEff * delta;
        currentScore = (updated * 100).round() / 100.0;

        steps.add(
          MasteryCalculationStep(
            step: i + 1,
            type: 'ewma',
            verifiedLearningEventId: ev.verifiedLearningEventId,
            performancePct: ev.performancePct,
            alphaEffective: alphaEff,
            resultScore: currentScore,
          ),
        );
      }
    }

    return NodeMasteryRebuildResult(
      masteryScore: currentScore,
      effectiveEvidenceCount: sorted.length,
      distinctAssessmentCount: distinctVles.length,
      steps: steps,
    );
  }

  /// Evaluates level weight based on difficulty string.
  /// normal, hard, challenge -> 1.00; below_level -> 0.50
  static double getLevelWeight(String difficulty) {
    switch (difficulty.toLowerCase()) {
      case 'below_level':
        return 0.50;
      case 'normal':
      case 'hard':
      case 'challenge':
      default:
        return 1.00;
    }
  }

  /// Aggregates component scores into a single performance percentage:
  /// sum(raw_score) / sum(max_score) * 100.0
  static double aggregateComponentScores(
    List<({double rawScore, double maxScore})> scores,
  ) {
    if (scores.isEmpty) return 0.0;
    var totalRaw = 0.0;
    var totalMax = 0.0;
    for (final s in scores) {
      totalRaw += s.rawScore;
      totalMax += s.maxScore;
    }
    if (totalMax <= 0.0) return 0.0;
    final pct = (totalRaw / totalMax) * 100.0;
    return (pct * 100).round() / 100.0;
  }

  /// Aggregates item groups into a single performance percentage:
  /// sum(correct_count) / sum(item_count) * 100.0
  static double aggregateItemGroups(
    List<({int correctCount, int itemCount})> groups,
  ) {
    if (groups.isEmpty) return 0.0;
    var totalCorrect = 0;
    var totalItems = 0;
    for (final g in groups) {
      totalCorrect += g.correctCount;
      totalItems += g.itemCount;
    }
    if (totalItems <= 0) return 0.0;
    final pct = (totalCorrect / totalItems) * 100.0;
    return (pct * 100).round() / 100.0;
  }
}
