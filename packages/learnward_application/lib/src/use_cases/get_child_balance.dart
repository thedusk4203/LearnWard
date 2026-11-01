import 'package:learnward_domain/learnward_domain.dart';

import '../ports/growth_repository.dart';

/// Use case to fetch a child's cumulative Study XP and spendable Reward Points balance.
final class GetChildBalance {
  const GetChildBalance(this._repository);

  final GrowthRepository _repository;

  Future<ChildBalance?> call(ChildId childId) {
    return _repository.getChildBalance(childId);
  }
}
