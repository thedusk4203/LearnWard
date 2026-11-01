import '../exceptions/domain_exceptions.dart';
import '../value_objects/assessment_enums.dart';
import '../value_objects/assessment_score.dart';
import '../value_objects/entry_context.dart';
import '../value_objects/identifiers.dart';
import '../value_objects/subject_key.dart';

/// Represents an academic result in LearnWard.
final class Assessment {
  Assessment({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.subjectKey,
    required String subject,
    required String title,
    required this.type,
    this.difficulty = AssessmentDifficulty.normal,
    required this.score,
    this.entryContext = EntryContext.adult,
    this.status = AssessmentStatus.draft,
    required this.occurredAt,
    this.version = 1,
    required this.createdByUserId,
    required this.createdAt,
    required this.updatedAt,
  }) : subject = _validateSubject(subject),
       title = _validateTitle(title) {
    if (version < 1) {
      throw const InvalidAssessmentException('Version must be >= 1.');
    }
  }

  final AssessmentId id;
  final FamilyId familyId;
  final ChildId childId;
  final SubjectKey subjectKey;
  final String subject;
  final String title;
  final AssessmentType type;
  final AssessmentDifficulty difficulty;
  final AssessmentScore score;
  final EntryContext entryContext;
  final AssessmentStatus status;
  final DateTime occurredAt;
  final int version;
  final String createdByUserId;
  final DateTime createdAt;
  final DateTime updatedAt;

  static String _validateSubject(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 100) {
      throw const InvalidAssessmentException(
        'Assessment subject must be between 1 and 100 characters.',
      );
    }
    return trimmed;
  }

  static String _validateTitle(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 150) {
      throw const InvalidAssessmentException(
        'Assessment title must be between 1 and 150 characters.',
      );
    }
    return trimmed;
  }

  Assessment copyWith({
    SubjectKey? subjectKey,
    String? subject,
    String? title,
    AssessmentType? type,
    AssessmentDifficulty? difficulty,
    AssessmentScore? score,
    AssessmentStatus? status,
    DateTime? occurredAt,
    int? version,
    DateTime? updatedAt,
  }) {
    if (this.status.isTerminal) {
      throw const InvalidAssessmentException(
        'Terminal assessments cannot be modified.',
      );
    }

    return Assessment(
      id: id,
      familyId: familyId,
      childId: childId,
      subjectKey: subjectKey ?? this.subjectKey,
      subject: subject ?? this.subject,
      title: title ?? this.title,
      type: type ?? this.type,
      difficulty: difficulty ?? this.difficulty,
      score: score ?? this.score,
      entryContext: entryContext,
      status: status ?? this.status,
      occurredAt: occurredAt ?? this.occurredAt,
      version: version ?? this.version,
      createdByUserId: createdByUserId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Assessment && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Assessment($id, ${subjectKey.value}: $subject - $title, status: ${status.value}, score: $score)';
}
