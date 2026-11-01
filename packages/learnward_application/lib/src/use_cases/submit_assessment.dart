import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_repository.dart';

/// Use case to submit an assessment draft for adult review.
final class SubmitAssessment {
  const SubmitAssessment(this._repository);

  final AssessmentRepository _repository;

  Future<Assessment> call({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) {
    return _repository.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
    );
  }
}
