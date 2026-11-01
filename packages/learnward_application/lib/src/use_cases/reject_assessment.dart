import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_repository.dart';

/// Use case to reject an assessment submission with feedback notes.
final class RejectAssessment {
  const RejectAssessment(this._repository);

  final AssessmentRepository _repository;

  Future<Assessment> call({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    String? reason,
  }) {
    return _repository.rejectAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
      reason: reason,
    );
  }
}
