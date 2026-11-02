import 'package:learnward_domain/learnward_domain.dart';

import '../ports/learning_repository.dart';

/// Retrieves current mastery and confidence projections for a child.
final class GetChildMastery {
  const GetChildMastery(this._repository);

  final LearningRepository _repository;

  Future<List<ChildMasteryProjection>> call({
    required ChildId childId,
    DateTime? asOf,
  }) {
    return _repository.getChildMastery(childId: childId, asOf: asOf);
  }
}
