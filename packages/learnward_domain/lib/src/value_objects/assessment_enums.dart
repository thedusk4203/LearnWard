/// Academic assessment type band for longitudinal comparability.
enum AssessmentTypeBand { evaluative, formative, other }

/// Standard academic assessment types supported in LearnWard.
enum AssessmentType {
  quiz('quiz'),
  exam('exam'),
  homework('homework'),
  practice('practice'),
  other('other');

  const AssessmentType(this.value);

  final String value;

  /// Compatibility band for longitudinal comparison in Growth Engine v0.1:
  /// - Evaluative: quiz, exam
  /// - Formative: homework, practice
  /// - Other: other
  AssessmentTypeBand get band {
    switch (this) {
      case AssessmentType.quiz:
      case AssessmentType.exam:
        return AssessmentTypeBand.evaluative;
      case AssessmentType.homework:
      case AssessmentType.practice:
        return AssessmentTypeBand.formative;
      case AssessmentType.other:
        return AssessmentTypeBand.other;
    }
  }

  /// Whether another assessment type is in the same comparability band.
  bool isCompatibleWith(AssessmentType other) => band == other.band;

  static AssessmentType fromValue(String value) {
    return AssessmentType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown AssessmentType: $value'),
    );
  }
}

/// Difficulty band for longitudinal comparability in Growth Engine v0.1.
enum AssessmentDifficultyBand { belowLevel, standard, challenge }

/// Difficulty band of an assessment relative to child's expected level.
enum AssessmentDifficulty {
  belowLevel('below_level'),
  normal('normal'),
  hard('hard'),
  challenge('challenge');

  const AssessmentDifficulty(this.value);

  final String value;

  /// Compatibility band for longitudinal comparison in Growth Engine v0.1:
  /// - BelowLevel: below_level (isolated anti-farming band)
  /// - Standard: normal, hard (mutually comparable core curriculum)
  /// - Challenge: challenge (isolated advanced band)
  AssessmentDifficultyBand get band {
    switch (this) {
      case AssessmentDifficulty.belowLevel:
        return AssessmentDifficultyBand.belowLevel;
      case AssessmentDifficulty.normal:
      case AssessmentDifficulty.hard:
        return AssessmentDifficultyBand.standard;
      case AssessmentDifficulty.challenge:
        return AssessmentDifficultyBand.challenge;
    }
  }

  /// Whether another difficulty is in the same comparability band.
  bool isCompatibleWith(AssessmentDifficulty other) => band == other.band;

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
