import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_repository.dart';

/// Use case to create a new assessment draft.
final class CreateAssessmentDraft {
  const CreateAssessmentDraft(this._repository);

  final AssessmentRepository _repository;

  Future<Assessment> call({
    required FamilyId familyId,
    required ChildId childId,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
  }) {
    return _repository.createDraft(
      familyId: familyId,
      childId: childId,
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      occurredAt: occurredAt,
    );
  }
}
