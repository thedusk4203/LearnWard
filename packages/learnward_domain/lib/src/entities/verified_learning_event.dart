import '../value_objects/assessment_enums.dart';
import '../value_objects/assessment_score.dart';
import '../value_objects/identifiers.dart';

/// Immutable canonical snapshot representing a parent-verified academic learning event.
final class VerifiedLearningEvent {
  const VerifiedLearningEvent({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.assessmentId,
    required this.subject,
    required this.title,
    required this.type,
    required this.difficulty,
    required this.score,
    required this.occurredAt,
    required this.verifiedAt,
    required this.verifiedByUserId,
    required this.reviewEventId,
  });

  final String id;
  final FamilyId familyId;
  final ChildId childId;
  final AssessmentId assessmentId;
  final String subject;
  final String title;
  final AssessmentType type;
  final AssessmentDifficulty difficulty;
  final AssessmentScore score;
  final DateTime occurredAt;
  final DateTime verifiedAt;
  final String verifiedByUserId;
  final String reviewEventId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VerifiedLearningEvent && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'VerifiedLearningEvent($id, $subject - $title, score: $score, verifiedAt: $verifiedAt)';
}
