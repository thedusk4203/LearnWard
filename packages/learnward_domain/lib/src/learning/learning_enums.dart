// Enums for LearnWard Phase 5 Learning Engine & Mastery.

enum LearningNodeType {
  subject('subject', 0.35),
  domain('domain', 0.50),
  topic('topic', 0.75),
  skill('skill', 1.00);

  const LearningNodeType(this.value, this.specificityWeight);

  final String value;
  final double specificityWeight;

  static LearningNodeType fromValue(String value) {
    return LearningNodeType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown LearningNodeType: $value'),
    );
  }
}

enum ScoreSource {
  assessmentTotal('assessment_total'),
  componentScore('component_score'),
  itemGroup('item_group');

  const ScoreSource(this.value);

  final String value;

  static ScoreSource fromValue(String value) {
    return ScoreSource.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown ScoreSource: $value'),
    );
  }
}

enum MasteryBand {
  noData('no_data'),
  emerging('emerging'),
  developing('developing'),
  secure('secure'),
  masteryCandidate('mastery_candidate'),
  mastered('mastered');

  const MasteryBand(this.value);

  final String value;

  static MasteryBand fromValue(String value) {
    return MasteryBand.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown MasteryBand: $value'),
    );
  }
}

enum ConfidenceBand {
  low('low'),
  medium('medium'),
  high('high');

  const ConfidenceBand(this.value);

  final String value;

  static ConfidenceBand fromValue(String value) {
    return ConfidenceBand.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown ConfidenceBand: $value'),
    );
  }
}

enum CatalogLifecycleStatus {
  draft('draft'),
  active('active'),
  retired('retired');

  const CatalogLifecycleStatus(this.value);

  final String value;

  static CatalogLifecycleStatus fromValue(String value) {
    return CatalogLifecycleStatus.values.firstWhere(
      (e) => e.value == value,
      orElse: () =>
          throw ArgumentError('Unknown CatalogLifecycleStatus: $value'),
    );
  }
}

/// Canonical Freshness classification for LearnWard Phase 5.2.
enum MasteryFreshness {
  recent('recent'),
  aging('aging'),
  needsRefresh('needs_refresh'),
  unknown('unknown');

  const MasteryFreshness(this.value);

  final String value;

  static MasteryFreshness fromValue(String value) {
    return MasteryFreshness.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown MasteryFreshness: $value'),
    );
  }
}

/// Canonical Recovery signal for LearnWard Phase 5.2.
enum RecoverySignal {
  none('none'),
  reviewSuggested('review_suggested');

  const RecoverySignal(this.value);

  final String value;

  static RecoverySignal fromValue(String value) {
    return RecoverySignal.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown RecoverySignal: $value'),
    );
  }
}

/// Mutually exclusive Next Challenge priority classes (1 = highest priority).
enum RecommendationPriority {
  recovery('recovery', 1),
  refresh('refresh', 2),
  developing('developing', 3),
  unlock('unlock', 4),
  explore('explore', 5);

  const RecommendationPriority(this.value, this.rank);

  final String value;
  final int rank;

  static RecommendationPriority fromValue(String value) {
    return RecommendationPriority.values.firstWhere(
      (e) => e.value == value,
      orElse: () =>
          throw ArgumentError('Unknown RecommendationPriority: $value'),
    );
  }
}

/// Deterministic 1-to-1 reason code for each Next Challenge priority class.
enum NextChallengeReason {
  recoveryRecentErrors('recovery_recent_errors'),
  refreshStaleSecureSkill('refresh_stale_secure_skill'),
  developingKeepPracticing('developing_keep_practicing'),
  unlockPrerequisitesMastered('unlock_prerequisites_mastered'),
  exploreAvailableSkill('explore_available_skill');

  const NextChallengeReason(this.value);

  final String value;

  static NextChallengeReason fromValue(String value) {
    return NextChallengeReason.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown NextChallengeReason: $value'),
    );
  }
}

/// Recommended difficulty aligned 1:1 with the frozen 4-value difficulty vocabulary.
enum RecommendedDifficulty {
  belowLevel('below_level'),
  normal('normal'),
  hard('hard'),
  challenge('challenge');

  const RecommendedDifficulty(this.value);

  final String value;

  static RecommendedDifficulty fromValue(String value) {
    return RecommendedDifficulty.values.firstWhere(
      (e) => e.value == value,
      orElse: () =>
          throw ArgumentError('Unknown RecommendedDifficulty: $value'),
    );
  }
}
