import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_repository.dart';

/// Use case to update an existing assessment draft.
final class UpdateAssessmentDraft {
  const UpdateAssessmentDraft(this._repository);

  final AssessmentRepository _repository;

  Future<Assessment> call({
    required AssessmentId assessmentId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    required int expectedVersion,
  }) {
    return _repository.updateDraft(
      assessmentId: assessmentId,
      subjectKey: subjectKey,
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      occurredAt: occurredAt,
      expectedVersion: expectedVersion,
    );
  }
}
