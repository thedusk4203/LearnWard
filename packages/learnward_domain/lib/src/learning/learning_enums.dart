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
