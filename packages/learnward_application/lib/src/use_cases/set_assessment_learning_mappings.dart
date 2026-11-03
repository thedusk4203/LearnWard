import 'package:learnward_domain/learnward_domain.dart';

import '../ports/learning_repository.dart';

/// Sets or updates learning node mappings for an assessment in pending_review status.
final class SetAssessmentLearningMappings {
  const SetAssessmentLearningMappings(this._repository);

  final LearningRepository _repository;

  Future<List<AssessmentLearningMapping>> call({
    required AssessmentId assessmentId,
    required List<AssessmentLearningMapping> mappings,
  }) {
    return _repository.setAssessmentLearningMappings(
      assessmentId: assessmentId,
      mappings: mappings,
    );
  }
}
