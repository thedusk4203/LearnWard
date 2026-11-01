import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_repository.dart';

/// Use case to verify an assessment and produce canonical learning evidence.
final class VerifyAssessment {
  const VerifyAssessment(this._repository);

  final AssessmentRepository _repository;

  Future<Assessment> call({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    String? notes,
  }) {
    return _repository.verifyAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
      notes: notes,
    );
  }
}
