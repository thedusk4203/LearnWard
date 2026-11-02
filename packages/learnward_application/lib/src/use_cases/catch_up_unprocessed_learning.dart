import 'package:learnward_domain/learnward_domain.dart';

import '../ports/learning_repository.dart';

/// Catches up unprocessed verified learning events for a family into mastery states.
final class CatchUpUnprocessedLearning {
  const CatchUpUnprocessedLearning(this._repository);

  final LearningRepository _repository;

  Future<Map<String, dynamic>> call(FamilyId familyId) {
    return _repository.catchUpUnprocessedLearning(familyId);
  }
}
