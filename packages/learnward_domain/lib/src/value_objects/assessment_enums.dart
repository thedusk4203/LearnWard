/// Standard academic assessment types supported in LearnWard.
enum AssessmentType {
  quiz('quiz'),
  exam('exam'),
  homework('homework'),
  practice('practice'),
  other('other');

  const AssessmentType(this.value);

  final String value;

  static AssessmentType fromValue(String value) {
    return AssessmentType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown AssessmentType: $value'),
    );
  }
}

/// Difficulty band of an assessment relative to child's expected level.
enum AssessmentDifficulty {
  belowLevel('below_level'),
  normal('normal'),
  hard('hard'),
  challenge('challenge');

  const AssessmentDifficulty(this.value);

  final String value;

  static AssessmentDifficulty fromValue(String value) {
    return AssessmentDifficulty.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown AssessmentDifficulty: $value'),
    );
  }
}

/// Ingestion status of an academic assessment.
enum AssessmentStatus {
  draft('draft'),
  pendingReview('pending_review'),
  verified('verified'),
  rejected('rejected');

  const AssessmentStatus(this.value);

  final String value;

  bool get isTerminal => this == verified || this == rejected;

  static AssessmentStatus fromValue(String value) {
    return AssessmentStatus.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown AssessmentStatus: $value'),
    );
  }
}
