import 'learning_enums.dart';
import 'learning_models.dart';
import 'learning_recommendation_models.dart';
import 'mastery_engine.dart';

/// Pure Dart implementation of LearnWard Recovery Engine v0.1.
///
/// Evaluates `RecoverySignal` (`none | review_suggested`) deterministically via
/// canonical academic chronology replay (`effective_occurred_at ASC, verified_at ASC,
/// verified_learning_event_id ASC`), dual temporal visibility
/// (`effective_occurred_at <= asOf && verified_at <= asOf`), and a 30-day
/// recency expiry window.
class RecoveryEngine {
  const RecoveryEngine();

  static const Duration recencyWindow = Duration(days: 30);

  /// Evaluates recovery state for a single node at [asOf].
  ///
  /// - Applies ONLY to `topic` and `skill` nodes (`subject` and `domain` always return `none`).
  /// - Filters evidence to `scoreSource in {componentScore, itemGroup}` (`assessmentTotal`
  ///   is completely ignored and can neither raise nor clear recovery).
  /// - Enforces dual temporal visibility (`!effectiveOccurredAt.isAfter(asOf) && !verifiedAt.isAfter(asOf)`).
  static RecoveryEvaluation evaluate({
    required LearningNodeType nodeType,
    required Iterable<LearningEvidenceEvent> evidence,
    required DateTime asOf,
  }) {
    if (nodeType != LearningNodeType.topic &&
        nodeType != LearningNodeType.skill) {
      return const RecoveryEvaluation(
        signal: RecoverySignal.none,
        latestUnresolvedWeaknessAt: null,
      );
    }

    final eligible = evidence.where((ev) {
      if (ev.scoreSource != ScoreSource.componentScore &&
          ev.scoreSource != ScoreSource.itemGroup) {
        return false;
      }
      if (ev.effectiveOccurredAt.isAfter(asOf)) return false;
      if (ev.verifiedAt.isAfter(asOf)) return false;
      return true;
    });

    final sorted = MasteryEngine.sortCanonical(eligible);

    var state = RecoverySignal.none;
    DateTime? latestWeakAt;

    for (final ev in sorted) {
      if (_isQualifyingWeak(ev)) {
        state = RecoverySignal.reviewSuggested;
        latestWeakAt = ev.effectiveOccurredAt;
      } else if (_isQualifyingClear(ev)) {
        state = RecoverySignal.none;
        latestWeakAt = null;
      }
    }

    if (state == RecoverySignal.reviewSuggested && latestWeakAt != null) {
      final elapsed = asOf.difference(latestWeakAt);
      if (elapsed <= recencyWindow) {
        return RecoveryEvaluation(
          signal: RecoverySignal.reviewSuggested,
          latestUnresolvedWeaknessAt: latestWeakAt,
        );
      }
    }

    return const RecoveryEvaluation(
      signal: RecoverySignal.none,
      latestUnresolvedWeaknessAt: null,
    );
  }

  static bool _isQualifyingWeak(LearningEvidenceEvent ev) {
    if (ev.scoreSource == ScoreSource.itemGroup) {
      final items = ev.itemCount;
      final correct = ev.correctCount;
      if (items == null || correct == null) return false;
      final incorrect = items - correct;
      return ev.performancePct < 70.0 && items >= 3 && incorrect >= 2;
    }
    if (ev.scoreSource == ScoreSource.componentScore) {
      return ev.performancePct <= 50.0;
    }
    return false;
  }

  static bool _isQualifyingClear(LearningEvidenceEvent ev) {
    return (ev.scoreSource == ScoreSource.componentScore ||
            ev.scoreSource == ScoreSource.itemGroup) &&
        ev.performancePct >= 70.0;
  }
}
