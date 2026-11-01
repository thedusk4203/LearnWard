import 'package:learnward_domain/learnward_domain.dart';

import '../ports/growth_repository.dart';

/// Catches up any unprocessed verified learning events to generate GrowthEvents.
final class CatchUpUnprocessedGrowth {
  const CatchUpUnprocessedGrowth(this._repository);

  final GrowthRepository _repository;

  Future<int> execute(FamilyId familyId) {
    return _repository.catchUpUnprocessedGrowth(familyId);
  }
}
