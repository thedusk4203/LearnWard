import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class ListFamilyRewards {
  const ListFamilyRewards(this._repository);

  final RewardRepository _repository;

  Future<List<Reward>> call({required FamilyId familyId, bool? activeOnly}) {
    return _repository.listFamilyRewards(
      familyId: familyId,
      activeOnly: activeOnly,
    );
  }
}
