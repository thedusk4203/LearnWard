import 'package:learnward_domain/learnward_domain.dart';

import '../ports/growth_repository.dart';

/// Use case to fetch the chronological history of GrowthEvents for a child.
final class ListGrowthEvents {
  const ListGrowthEvents(this._repository);

  final GrowthRepository _repository;

  Future<List<GrowthEvent>> call(ChildId childId) {
    return _repository.listGrowthEvents(childId);
  }
}
