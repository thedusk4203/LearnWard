import '../value_objects/assessment_enums.dart';
import '../value_objects/subject_key.dart';

/// Historical verified learning result used for rolling baseline and comparability checks.
final class ComparableResult {
  const ComparableResult({
    required this.id,
    required this.subjectKey,
    required this.normalizedScore,
    required this.difficulty,
    required this.assessmentType,
    required this.occurredAt,
    required this.verifiedAt,
    this.gradeLevel = 5,
  });

  final String id;
  final SubjectKey subjectKey;
  final double normalizedScore;
  final AssessmentDifficulty difficulty;
  final AssessmentType assessmentType;
  final DateTime occurredAt;
  final DateTime verifiedAt;
  final int gradeLevel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ComparableResult && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'ComparableResult($id, ${subjectKey.value}, score: $normalizedScore, grade: $gradeLevel, $difficulty, occurred: $occurredAt)';
}
