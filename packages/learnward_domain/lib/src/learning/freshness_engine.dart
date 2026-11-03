import 'learning_enums.dart';
import 'learning_recommendation_models.dart';

/// Pure Dart implementation of LearnWard Freshness Engine v0.1.
///
/// Evaluates dynamic freshness (`recent | aging | needs_refresh | unknown`)
/// at read time relative to server-authoritative [asOf] without mutating
/// mastery scores or sticky attainment.
class FreshnessEngine {
  const FreshnessEngine();

  static const Duration recentBoundary = Duration(days: 14);
  static const Duration agingBoundary = Duration(days: 45);

  /// Evaluates [MasteryFreshness] and integer [daysSinceLastEvidence] from
  /// [latestEffectiveOccurredAt] (the maximum `effective_occurred_at` among
  /// Phase 5.2-visible evidence `effective_occurred_at <= asOf && verified_at <= asOf`)
  /// relative to [asOf].
  static FreshnessEvaluation evaluate({
    required DateTime? latestEffectiveOccurredAt,
    required DateTime asOf,
  }) {
    if (latestEffectiveOccurredAt == null) {
      return const FreshnessEvaluation(
        freshness: MasteryFreshness.unknown,
        daysSinceLastEvidence: null,
      );
    }

    final elapsed = asOf.isAfter(latestEffectiveOccurredAt)
        ? asOf.difference(latestEffectiveOccurredAt)
        : Duration.zero;

    final MasteryFreshness freshness;
    if (elapsed <= recentBoundary) {
      freshness = MasteryFreshness.recent;
    } else if (elapsed <= agingBoundary) {
      freshness = MasteryFreshness.aging;
    } else {
      freshness = MasteryFreshness.needsRefresh;
    }

    return FreshnessEvaluation(
      freshness: freshness,
      daysSinceLastEvidence: elapsed.inDays,
    );
  }
}
