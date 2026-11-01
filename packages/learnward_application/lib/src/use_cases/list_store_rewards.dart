import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class ListStoreRewards {
  const ListStoreRewards(this._repository);

  final RewardRepository _repository;

  Future<List<Reward>> call({required FamilyId familyId, ChildId? childId}) {
    return _repository.listStoreRewards(familyId: familyId, childId: childId);
  }
}
