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
    this.retryCount = 0,
    this.nextAttemptAt,
    this.lastErrorMessage,
    this.leaseToken,
    this.leaseExpiresAt,
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

  // Phase 6 Slice 4A-0 Additions (v6):
  final int retryCount;
  final DateTime? nextAttemptAt;
  final String? lastErrorMessage;
  final String? leaseToken;
  final DateTime? leaseExpiresAt;

  /// Whether this command is eligible for automatic retry/replay.
  /// Fails closed if the command is quarantined, legacy unknown, confirmed committed,
  /// or missing actor binding.
  bool get canAutoReplay =>
      recoveryState == CommandRecoveryState.active &&
      dispatchState != CommandDispatchState.unknownLegacy &&
      dispatchState != CommandDispatchState.confirmedCommitted &&
      actorUserId != null &&
      actorUserId!.isNotEmpty;

  PendingRewardCommand copyWith({
    Object? id = _sentinel,
    RewardCommandOperation? operation,
    String? commandId,
    String? familyId,
    Object? childId = _sentinel,
    Object? rewardId = _sentinel,
    Object? redemptionId = _sentinel,
    Object? cancellationReason = _sentinel,
    DateTime? createdAt,
    Object? actorUserId = _sentinel,
    Object? actorRole = _sentinel,
    int? schemaVersion,
    CommandRecoveryState? recoveryState,
    CommandDispatchState? dispatchState,
    int? retryCount,
    Object? nextAttemptAt = _sentinel,
    Object? lastErrorMessage = _sentinel,
    Object? leaseToken = _sentinel,
    Object? leaseExpiresAt = _sentinel,
  }) {
    return PendingRewardCommand(
      id: identical(id, _sentinel) ? this.id : id as int?,
      operation: operation ?? this.operation,
      commandId: commandId ?? this.commandId,
      familyId: familyId ?? this.familyId,
      childId: identical(childId, _sentinel)
          ? this.childId
          : childId as String?,
      rewardId: identical(rewardId, _sentinel)
          ? this.rewardId
          : rewardId as String?,
      redemptionId: identical(redemptionId, _sentinel)
          ? this.redemptionId
          : redemptionId as String?,
      cancellationReason: identical(cancellationReason, _sentinel)
          ? this.cancellationReason
          : cancellationReason as String?,
      createdAt: createdAt ?? this.createdAt,
      actorUserId: identical(actorUserId, _sentinel)
          ? this.actorUserId
          : actorUserId as String?,
      actorRole: identical(actorRole, _sentinel)
          ? this.actorRole
          : actorRole as String?,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      recoveryState: recoveryState ?? this.recoveryState,
      dispatchState: dispatchState ?? this.dispatchState,
      retryCount: retryCount ?? this.retryCount,
      nextAttemptAt: identical(nextAttemptAt, _sentinel)
          ? this.nextAttemptAt
          : nextAttemptAt as DateTime?,
      lastErrorMessage: identical(lastErrorMessage, _sentinel)
          ? this.lastErrorMessage
          : lastErrorMessage as String?,
      leaseToken: identical(leaseToken, _sentinel)
          ? this.leaseToken
          : leaseToken as String?,
      leaseExpiresAt: identical(leaseExpiresAt, _sentinel)
          ? this.leaseExpiresAt
          : leaseExpiresAt as DateTime?,
    );
  }

  /// Convenience copy helper that explicitly clears active lease metadata.
  PendingRewardCommand clearLease() =>
      copyWith(leaseToken: null, leaseExpiresAt: null);
}

const Object _sentinel = Object();

/// Port for durable local journal of pending reward commands.
abstract interface class PendingRewardCommandStore {
  /// Saves a pending command into the durable local journal.
  Future<void> savePendingCommand(
    PendingRewardCommand command, {
    DateTime? now,
  });

  /// Retrieves an existing pending command by its unique commandId.
  Future<PendingRewardCommand?> getPendingCommand(String commandId);

  /// Finds an existing pending spin command for a given family and child.
  Future<PendingRewardCommand?> findPendingSpinCommand({
    required String familyId,
    required String childId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  });

  /// Finds an existing pending redeem command for a given family, child and reward.
  Future<PendingRewardCommand?> findPendingRedeemCommand({
    required String familyId,
    required String childId,
    required String rewardId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  });

  /// Finds an existing pending fulfillment/cancellation command for a redemption.
  Future<PendingRewardCommand?> findPendingRedemptionCommand({
    required RewardCommandOperation operation,
    required String redemptionId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
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

  // ---------------------------------------------------------------------------
  // PHASE 6 SLICE 4A-0: ATOMIC CAS STORE OPERATIONS & FENCING
  // ---------------------------------------------------------------------------

  /// Atomically attempts to acquire an exclusive execution claim lease.
  /// Returns granted leaseToken on success, or null if claim failed / already in-flight.
  /// [actorUserId] MUST be sourced from the authenticated session context, NEVER copied from the pending command.
  Future<String?> acquireClaim({
    required String commandId,
    required String actorUserId,
    required Duration leaseDuration,
    DateTime? now,
    String? overrideLeaseToken,
  });

  /// Releases an active claim back to scheduled retry with updated backoff.
  /// Atomically increments the retry counter directly within SQLite (`retry_count = retry_count + 1`).
  /// The caller MUST NOT supply a retryCount parameter.
  /// Conditional on [leaseToken].
  Future<bool> releaseClaim({
    required String commandId,
    required String leaseToken,
    required DateTime nextAttemptAt,
    String? lastErrorMessage,
  });

  /// Deletes a successfully completed command from the journal.
  /// Conditional on [leaseToken].
  Future<bool> completeCommand({
    required String commandId,
    required String leaseToken,
  });

  /// Transitions recovery state under an existing active lease.
  /// Conditional on [leaseToken].
  Future<bool> transitionRecoveryState({
    required String commandId,
    required String leaseToken,
    required CommandRecoveryState newState,
    String? lastErrorMessage,
  });

  /// Atomically transitions an active mismatched command to pendingOriginalActor.
  /// Non-dispatch SQLite CAS: requires actor_user_id IS NOT NULL AND actor_user_id <> [authenticatedActorId].
  /// Respects unexpired active leases; clears lease metadata only on success.
  Future<bool> pauseMismatchedActorCommand({
    required String commandId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  });

  /// Atomically transitions a pendingOriginalActor command back to active upon original actor sign-in.
  /// Non-dispatch SQLite CAS: requires actor_user_id == [authenticatedActorId].
  /// Respects active leases; clears lease metadata only on success.
  Future<bool> resumeOriginalActorCommand({
    required String commandId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  });

  /// Lists claimable commands due for execution by the authenticated actor.
  /// Matches rows where actor_user_id == [actorUserId], recovery_state == 'active',
  /// operation IN ('spin_wheel', 'redeem_reward'), dispatch_state IN ('never_dispatched', 'possibly_dispatched'),
  /// (next_attempt_at IS NULL OR next_attempt_at <= clock.now()),
  /// and ((lease_token IS NULL AND lease_expires_at IS NULL) OR (lease_token IS NOT NULL AND lease_expires_at <= clock.now())).
  Future<List<PendingRewardCommand>> listClaimableCommands({
    required String actorUserId,
    required int limit,
    DateTime? now,
  });

  /// Discovers active commands belonging to a different actor for the family.
  /// Used by the outbox scanner to discover candidates for [pauseMismatchedActorCommand].
  Future<List<PendingRewardCommand>> listMismatchedActiveCommands({
    required String familyId,
    required String authenticatedActorId,
    required int limit,
    DateTime? now,
  });

  /// Discovers paused commands belonging to the current actor for the family.
  /// Used upon actor sign-in to discover candidates for [resumeOriginalActorCommand].
  Future<List<PendingRewardCommand>> listPausedOriginalActorCommands({
    required String familyId,
    required String authenticatedActorId,
    required int limit,
    DateTime? now,
  });
}
