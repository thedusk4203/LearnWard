import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class CancelRewardRedemption {
  const CancelRewardRedemption(this._repository);

  final RewardRepository _repository;

  Future<RewardRedemption> call({
    required String commandId,
    required RewardRedemptionId redemptionId,
    required String cancellationReason,
  }) {
    return _repository.cancelRewardRedemption(
      commandId: commandId,
      redemptionId: redemptionId,
      cancellationReason: cancellationReason,
    );
  }
}
