import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class UpdateReward {
  const UpdateReward(this._repository);

  final RewardRepository _repository;

  Future<Reward> call(Reward reward) {
    return _repository.updateReward(reward);
  }
}
