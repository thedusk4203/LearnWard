import 'package:learnward_domain/learnward_domain.dart';

import '../ports/growth_repository.dart';

/// Use case to fetch the most recent GrowthEvent for a child.
final class GetLatestGrowthEvent {
  const GetLatestGrowthEvent(this._repository);

  final GrowthRepository _repository;

  Future<GrowthEvent?> call(ChildId childId) {
    return _repository.getLatestGrowthEvent(childId);
  }
}
