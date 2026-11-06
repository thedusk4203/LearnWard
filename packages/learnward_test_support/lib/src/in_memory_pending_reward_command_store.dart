import 'package:learnward_application/learnward_application.dart';

/// In-memory implementation of [PendingRewardCommandStore] for fast unit/widget tests.
final class InMemoryPendingRewardCommandStore
    implements PendingRewardCommandStore {
  final Map<String, PendingRewardCommand> _commands = {};

  @override
  Future<void> savePendingCommand(PendingRewardCommand command) async {
    _commands[command.commandId] = command;
  }

  @override
  Future<PendingRewardCommand?> getPendingCommand(String commandId) async {
    return _commands[commandId];
  }

  @override
  Future<PendingRewardCommand?> findPendingSpinCommand({
    required String familyId,
    required String childId,
    CommandRecoveryState recoveryState = CommandRecoveryState.active,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == RewardCommandOperation.spinWheel &&
          cmd.familyId == familyId &&
          cmd.childId == childId &&
          cmd.recoveryState == recoveryState) {
        return cmd;
      }
    }
    return null;
  }

  @override
  Future<PendingRewardCommand?> findPendingRedeemCommand({
    required String familyId,
    required String childId,
    required String rewardId,
    CommandRecoveryState recoveryState = CommandRecoveryState.active,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == RewardCommandOperation.redeemReward &&
          cmd.familyId == familyId &&
          cmd.childId == childId &&
          cmd.rewardId == rewardId &&
          cmd.recoveryState == recoveryState) {
        return cmd;
      }
    }
    return null;
  }

  @override
  Future<PendingRewardCommand?> findPendingRedemptionCommand({
    required RewardCommandOperation operation,
    required String redemptionId,
    CommandRecoveryState recoveryState = CommandRecoveryState.active,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == operation &&
          cmd.redemptionId == redemptionId &&
          cmd.recoveryState == recoveryState) {
        return cmd;
      }
    }
    return null;
  }

  @override
  Future<List<PendingRewardCommand>> listPendingCommands({
    String? familyId,
    String? childId,
    CommandRecoveryState? recoveryState,
    CommandDispatchState? dispatchState,
  }) async {
    final list = _commands.values.where((cmd) {
      if (familyId != null && cmd.familyId != familyId) return false;
      if (childId != null && cmd.childId != childId) return false;
      if (recoveryState != null && cmd.recoveryState != recoveryState) {
        return false;
      }
      if (dispatchState != null && cmd.dispatchState != dispatchState) {
        return false;
      }
      return true;
    }).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<void> deletePendingCommand(String commandId) async {
    _commands.remove(commandId);
  }
}
