import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class ListRewardRedemptions {
  const ListRewardRedemptions(this._repository);

  final RewardRepository _repository;

  Future<List<RewardRedemption>> call({
    required FamilyId familyId,
    ChildId? childId,
    RewardRedemptionStatus? status,
  }) {
    return _repository.listRedemptions(
      familyId: familyId,
      childId: childId,
      status: status,
    );
  }
}
