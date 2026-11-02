import 'package:learnward_domain/learnward_domain.dart';

import '../ports/learning_repository.dart';

/// Retrieves learning mappings for an assessment.
final class GetAssessmentLearningMappings {
  const GetAssessmentLearningMappings(this._repository);

  final LearningRepository _repository;

  Future<List<AssessmentLearningMapping>> call(AssessmentId assessmentId) {
    return _repository.getAssessmentLearningMappings(assessmentId);
  }
}
