import 'dart:math';

import 'package:learnward_domain/learnward_domain.dart';

import '../ports/command_lifecycle_states.dart';
import '../ports/pending_reward_command_store.dart';
import '../ports/reward_repository.dart';

final class RedeemStoreReward {
  const RedeemStoreReward(
    this._repository,
    this._commandStore, {
    this.uuidGenerator,
  });

  final RewardRepository _repository;
  final PendingRewardCommandStore _commandStore;
  final String Function()? uuidGenerator;

  Future<RewardRedemption> call({
    required FamilyId familyId,
    required RewardId rewardId,
    required ChildId childId,
    String? commandId,
    String? actorUserId,
    String? actorRole,
  }) async {
    final existing = await _commandStore.findPendingRedeemCommand(
      familyId: familyId.value,
      childId: childId.value,
      rewardId: rewardId.value,
      actorUserId: actorUserId,
    );

    final canReplayExisting =
        existing != null &&
        existing.recoveryState == CommandRecoveryState.active &&
        existing.dispatchState != CommandDispatchState.unknownLegacy &&
        existing.dispatchState != CommandDispatchState.confirmedCommitted &&
        (actorUserId == null ||
            existing.actorUserId == null ||
            existing.actorUserId == actorUserId);

    final actualCommandId = canReplayExisting
        ? existing.commandId
        : commandId ?? (uuidGenerator?.call() ?? _generateUuid());

    if (existing == null || !canReplayExisting) {
      await _commandStore.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: actualCommandId,
          familyId: familyId.value,
          childId: childId.value,
          rewardId: rewardId.value,
          actorUserId: actorUserId,
          actorRole: actorRole,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }

    try {
      final redemption = await _repository.redeemStoreReward(
        commandId: actualCommandId,
        rewardId: rewardId,
        childId: childId,
      );

      await _commandStore.deletePendingCommand(actualCommandId);
      return redemption;
    } catch (e) {
      if (_isTerminalError(e)) {
        await _commandStore.deletePendingCommand(actualCommandId);
      }
      rethrow;
    }
  }

  static bool _isTerminalError(Object error) {
    final msg = error.toString();
    if (msg.contains('LW201') ||
        msg.contains('LW204') ||
        msg.contains('LW205') ||
        msg.contains('LW206') ||
        msg.contains('LW004') ||
        msg.contains('42501') ||
        msg.contains('InvalidRedemptionException') ||
        msg.contains('InvalidRewardException')) {
      return true;
    }
    return false;
  }

  static String _generateUuid() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}
