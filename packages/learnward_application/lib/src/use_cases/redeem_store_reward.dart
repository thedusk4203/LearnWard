import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class RedeemStoreReward {
  const RedeemStoreReward(this._repository);

  final RewardRepository _repository;

  Future<RewardRedemption> call({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) {
    return _repository.redeemStoreReward(
      commandId: commandId,
      rewardId: rewardId,
      childId: childId,
    );
  }
}
