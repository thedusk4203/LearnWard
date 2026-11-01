import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class FulfillRewardRedemption {
  const FulfillRewardRedemption(this._repository);

  final RewardRepository _repository;

  Future<RewardRedemption> call({
    required String commandId,
    required RewardRedemptionId redemptionId,
  }) {
    return _repository.fulfillRewardRedemption(
      commandId: commandId,
      redemptionId: redemptionId,
    );
  }
}
