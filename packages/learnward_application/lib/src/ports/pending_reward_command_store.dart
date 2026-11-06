import 'command_lifecycle_states.dart';

/// Operation types for pending reward command journal.
enum RewardCommandOperation {
  redeemReward('redeem_reward'),
  fulfillReward('fulfill_reward'),
  cancelReward('cancel_reward'),
  spinWheel('spin_wheel');

  const RewardCommandOperation(this.wireValue);
  final String wireValue;

  static RewardCommandOperation fromString(String value) {
    for (final op in RewardCommandOperation.values) {
      if (op.wireValue == value) return op;
    }
    throw ArgumentError.value(value, 'value', 'Unknown RewardCommandOperation');
  }
}

/// Durable local journal entry for a pending reward command to guarantee restart-safe idempotency.
final class PendingRewardCommand {
  const PendingRewardCommand({
    this.id,
    required this.operation,
    required this.commandId,
    required this.familyId,
    this.childId,
    this.rewardId,
    this.redemptionId,
    this.cancellationReason,
    required this.createdAt,
    this.actorUserId,
    this.actorRole,
    this.schemaVersion = 1,
    this.recoveryState = CommandRecoveryState.active,
    this.dispatchState = CommandDispatchState.neverDispatched,
  });

  final int? id;
  final RewardCommandOperation operation;
  final String commandId;
  final String familyId;
  final String? childId;
  final String? rewardId;
  final String? redemptionId;
  final String? cancellationReason;
  final DateTime createdAt;

  // Phase 6.1 Additions (v5):
  final String? actorUserId;
  final String? actorRole;
  final int schemaVersion;
  final CommandRecoveryState recoveryState;
  final CommandDispatchState dispatchState;

  /// Whether this command is eligible for automatic retry/replay.
  /// Fails closed if the command is quarantined, legacy unknown, or missing actor binding.
  bool get canAutoReplay =>
      recoveryState == CommandRecoveryState.active &&
      dispatchState != CommandDispatchState.unknownLegacy &&
      actorUserId != null &&
      actorUserId!.isNotEmpty;

  PendingRewardCommand copyWith({
    int? id,
    RewardCommandOperation? operation,
    String? commandId,
    String? familyId,
    String? childId,
    String? rewardId,
    String? redemptionId,
    String? cancellationReason,
    DateTime? createdAt,
    String? actorUserId,
    String? actorRole,
    int? schemaVersion,
    CommandRecoveryState? recoveryState,
    CommandDispatchState? dispatchState,
  }) {
    return PendingRewardCommand(
      id: id ?? this.id,
      operation: operation ?? this.operation,
      commandId: commandId ?? this.commandId,
      familyId: familyId ?? this.familyId,
      childId: childId ?? this.childId,
      rewardId: rewardId ?? this.rewardId,
      redemptionId: redemptionId ?? this.redemptionId,
      cancellationReason: cancellationReason ?? this.cancellationReason,
      createdAt: createdAt ?? this.createdAt,
      actorUserId: actorUserId ?? this.actorUserId,
      actorRole: actorRole ?? this.actorRole,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      recoveryState: recoveryState ?? this.recoveryState,
      dispatchState: dispatchState ?? this.dispatchState,
    );
  }
}

/// Port for durable local journal of pending reward commands.
abstract interface class PendingRewardCommandStore {
  /// Saves a pending command into the durable local journal.
  Future<void> savePendingCommand(PendingRewardCommand command);

  /// Retrieves an existing pending command by its unique commandId.
  Future<PendingRewardCommand?> getPendingCommand(String commandId);

  /// Finds an existing pending spin command for a given family and child.
  Future<PendingRewardCommand?> findPendingSpinCommand({
    required String familyId,
    required String childId,
    CommandRecoveryState recoveryState = CommandRecoveryState.active,
  });

  /// Finds an existing pending redeem command for a given family, child and reward.
  Future<PendingRewardCommand?> findPendingRedeemCommand({
    required String familyId,
    required String childId,
    required String rewardId,
    CommandRecoveryState recoveryState = CommandRecoveryState.active,
  });

  /// Finds an existing pending fulfillment/cancellation command for a redemption.
  Future<PendingRewardCommand?> findPendingRedemptionCommand({
    required RewardCommandOperation operation,
    required String redemptionId,
    CommandRecoveryState recoveryState = CommandRecoveryState.active,
  });

  /// Lists all pending commands, optionally filtered by family, child, and states.
  Future<List<PendingRewardCommand>> listPendingCommands({
    String? familyId,
    String? childId,
    CommandRecoveryState? recoveryState,
    CommandDispatchState? dispatchState,
  });

  /// Removes a pending command from the journal upon confirmed server outcome or terminal error.
  Future<void> deletePendingCommand(String commandId);
}
