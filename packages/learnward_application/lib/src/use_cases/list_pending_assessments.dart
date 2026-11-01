import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_repository.dart';

/// Use case to retrieve all pending assessment submissions for a family or child.
final class ListPendingAssessments {
  const ListPendingAssessments(this._repository);

  final AssessmentRepository _repository;

  Future<List<Assessment>> forFamily(FamilyId familyId) {
    return _repository.listAssessmentsByFamily(
      familyId,
      status: AssessmentStatus.pendingReview,
    );
  }

  Future<List<Assessment>> forChild(ChildId childId) {
    return _repository.listAssessmentsByChild(
      childId,
      status: AssessmentStatus.pendingReview,
    );
  }
}
