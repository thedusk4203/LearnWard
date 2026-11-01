import '../value_objects/assessment_enums.dart';
import '../value_objects/normalized_score.dart';
import '../value_objects/subject_key.dart';
import 'comparable_result.dart';

/// Inputs supplied to Growth Engine v0.1 to calculate deterministic Growth and economic awards.
final class GrowthInput {
  const GrowthInput({
    required this.currentEventId,
    required this.subjectKey,
    required this.currentScore,
    required this.difficulty,
    required this.assessmentType,
    required this.occurredAt,
    required this.verifiedAt,
    required this.gradeLevel,
    this.comparableHistory = const [],
    this.personalGoal,
  });

  /// Identifier of the target VerifiedLearningEvent (excluded from baseline calculation).
  final String currentEventId;

  /// Canonical subject key for longitudinal comparability.
  final SubjectKey subjectKey;

  /// Verified normalized score on the 0–10 scale.
  final NormalizedScore currentScore;

  /// Difficulty band of current assessment.
  final AssessmentDifficulty difficulty;

  /// Assessment type of current assessment.
  final AssessmentType assessmentType;

  /// Grade level snapshot of current assessment for longitudinal comparability (null if unknown).
  final int? gradeLevel;

  /// Timestamp when the learning activity occurred.
  final DateTime occurredAt;

  /// Timestamp when parent verification was performed.
  final DateTime verifiedAt;

  /// List of candidate historical verified records for the child.
  final List<ComparableResult> comparableHistory;

  /// Explicit personal goal target (deferred in Phase 3).
  final double? personalGoal;
}
