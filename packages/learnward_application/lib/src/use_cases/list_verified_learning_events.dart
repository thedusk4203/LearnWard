import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_repository.dart';

/// Use case to retrieve the immutable verified learning history for a child.
final class ListVerifiedLearningEvents {
  const ListVerifiedLearningEvents(this._repository);

  final AssessmentRepository _repository;

  Future<List<VerifiedLearningEvent>> call(ChildId childId) {
    return _repository.listVerifiedLearningEvents(childId);
  }
}
