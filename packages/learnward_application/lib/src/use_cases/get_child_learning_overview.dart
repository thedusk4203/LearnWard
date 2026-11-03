import 'package:learnward_domain/learnward_domain.dart';

import '../ports/learning_repository.dart';

/// Retrieves the Phase 5.2 child learning overview across all active subjects,
/// topics, skills, coverage counts, freshness, and recovery signals.
final class GetChildLearningOverview {
  const GetChildLearningOverview(this._repository);

  final LearningRepository _repository;

  Future<LearningOverview> call({required ChildId childId}) {
    return _repository.getChildLearningOverview(childId: childId);
  }
}

typedef GetChildLearningOverviewUseCase = GetChildLearningOverview;
