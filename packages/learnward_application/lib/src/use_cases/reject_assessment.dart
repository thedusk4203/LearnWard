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
    required String reason,
  }) {
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw const InvalidAssessmentException(
        'Rejection reason cannot be empty.',
      );
    }
    if (trimmed.length > 500) {
      throw const InvalidAssessmentException(
        'Rejection reason must not exceed 500 characters.',
      );
    }
    return _repository.rejectAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
      reason: trimmed,
    );
  }
}
