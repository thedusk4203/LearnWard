import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class DeleteReward {
  const DeleteReward(this._repository);

  final RewardRepository _repository;

  Future<void> call({required FamilyId familyId, required RewardId rewardId}) {
    return _repository.deleteReward(familyId: familyId, rewardId: rewardId);
  }
}
