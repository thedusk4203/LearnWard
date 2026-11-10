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

  static const int maxConsecutiveUnverifiedTargetMisses = 3;

  static final RegExp _unverifiedTargetMissPattern = RegExp(
    r'^\[UNVERIFIED_TARGET_MISS:([1-3])/3\]\s+(\S.*)$',
  );

  /// Durably parsed count of consecutive RLS-filtered / missing-target verification
  /// misses (`rlsFilteredOrMissingTargetRow` or `missingOrUnverifiedMembership`).
  ///
  /// Strictly parses the canonical marker `[UNVERIFIED_TARGET_MISS:m/3]` where `m` is 1, 2, or 3
  /// followed by a valid suffix detail.
  /// Separate from [retryCount] (`R28-05`): returns `0` when [lastErrorMessage] is null,
  /// malformed, out-of-range, noncanonical, truncated, or was last written by any other exit
  /// (transient RPC error, transient verification timeout, session generation change,
  /// active family switch, or actor pause/resume).
  int get consecutiveUnverifiedTargetMisses =>
      parseUnverifiedTargetMisses(lastErrorMessage);

  /// Strictly parses consecutive unverified target misses from a message string.
  /// Returns `0` for null, malformed, noncanonical, out-of-range, or truncated strings.
  static int parseUnverifiedTargetMisses(String? message) {
    if (message == null) return 0;
    final match = _unverifiedTargetMissPattern.firstMatch(message.trimRight());
    if (match == null) return 0;
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  /// Formats the canonical durable consecutive-miss prefix stored in [lastErrorMessage].
  static String formatUnverifiedTargetMissMessage({
    required int consecutiveMisses,
    required String detail,
    int maxMisses = maxConsecutiveUnverifiedTargetMisses,
  }) {
    if (consecutiveMisses < 1 ||
        consecutiveMisses > maxConsecutiveUnverifiedTargetMisses) {
      throw ArgumentError.value(
        consecutiveMisses,
        'consecutiveMisses',
        'Must be between 1 and $maxConsecutiveUnverifiedTargetMisses',
      );
    }
    if (maxMisses != maxConsecutiveUnverifiedTargetMisses) {
      throw ArgumentError.value(
        maxMisses,
        'maxMisses',
        'Must be $maxConsecutiveUnverifiedTargetMisses',
      );
    }
    final trimmedDetail = detail.trim();
    if (trimmedDetail.isEmpty) {
      throw ArgumentError.value(detail, 'detail', 'Detail cannot be empty');
    }
    return '[UNVERIFIED_TARGET_MISS:$consecutiveMisses/$maxMisses] $trimmedDetail';
  }

  /// Whether this command is eligible for automatic retry/replay.
  /// Fails closed if the command is quarantined, legacy unknown, confirmed committed,
  /// or missing actor binding.
  bool get canAutoReplay =>
      recoveryState == CommandRecoveryState.active &&
      dispatchState != CommandDispatchState.unknownLegacy &&
      dispatchState != CommandDispatchState.confirmedCommitted &&
      actorUserId != null &&
      actorUserId!.isNotEmpty &&
      (operation == RewardCommandOperation.spinWheel ||
          operation == RewardCommandOperation.redeemReward ||
          operation == RewardCommandOperation.fulfillReward ||
          operation == RewardCommandOperation.cancelReward);

  /// Whether this command represents an unresolved operation that must block
  /// fresh command creation for the same logical target (R24-5-03).
  bool get isUnresolved => _isCommandUnresolvedImpl(
    recoveryState: recoveryState,
    dispatchState: dispatchState,
  );

  /// Alias for [isUnresolved] matching the specification contract naming.
  bool get isCommandUnresolved => isUnresolved;

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

/// Result of an atomic attempt to register a fresh foreground pending command (R24-4-01).
sealed class RegisterFreshCommandResult {
  const RegisterFreshCommandResult();
}

/// Checks whether a command's state combination represents an unresolved operation
/// that must block fresh command creation for the same logical target (R24-5-03, R24-6-01).
///
/// Precedence contract:
/// 1. Uncertain provenance fails closed: Any command with [CommandRecoveryState.quarantinedUnknownOutcome]
///    or [CommandDispatchState.unknownLegacy] is quarantined until server-authorized reconciliation,
///    even if paired with confirmedCommitted or terminalError.
/// 2. Actor binding fails closed: Any command paused under [CommandRecoveryState.pendingOriginalActor]
///    must not be bypassed with a new UUID by another session.
/// 3. Definitively resolved terminal failure: [CommandRecoveryState.terminalError] on non-legacy,
///    non-quarantined commands permits legitimate fresh user intent.
/// 4. Definitively resolved terminal success: [CommandDispatchState.confirmedCommitted] on active,
///    non-legacy, non-quarantined commands permits legitimate fresh user intent.
/// 5. Active uncommitted commands: [CommandRecoveryState.active] with [CommandDispatchState.neverDispatched]
///    or [CommandDispatchState.possiblyDispatched] continue to block duplicate logical operations.
bool isCommandUnresolved({
  required CommandRecoveryState recoveryState,
  required CommandDispatchState dispatchState,
}) => _isCommandUnresolvedImpl(
  recoveryState: recoveryState,
  dispatchState: dispatchState,
);

bool _isCommandUnresolvedImpl({
  required CommandRecoveryState recoveryState,
  required CommandDispatchState dispatchState,
}) {
  // 1. Quarantined or unknown legacy outcomes fail closed until explicit reconciliation.
  // Uncertain provenance takes precedence over confirmedCommitted and terminalError (R24-6-01).
  if (recoveryState == CommandRecoveryState.quarantinedUnknownOutcome ||
      dispatchState == CommandDispatchState.unknownLegacy) {
    return true;
  }

  // 2. Commands paused pending the original authenticated actor fail closed.
  // Another session cannot bypass the pending command by allocating a new UUID (R24-6-01).
  if (recoveryState == CommandRecoveryState.pendingOriginalActor) {
    return true;
  }

  // 3. Definitively resolved terminal errors (on non-quarantined, non-legacy commands).
  if (recoveryState == CommandRecoveryState.terminalError) {
    return false;
  }

  // 4. Definitively resolved terminal success (confirmed committed by server/receipt).
  if (dispatchState == CommandDispatchState.confirmedCommitted) {
    return false;
  }

  // 5. Existing active/possibly-dispatched commands continue to block duplicate logical operations.
  if (recoveryState == CommandRecoveryState.active) {
    if (dispatchState == CommandDispatchState.neverDispatched ||
        dispatchState == CommandDispatchState.possiblyDispatched) {
      return true;
    }
  }

  return false;
}

/// A fresh command was successfully inserted because no active unresolved
/// command existed for this logical operation.
final class FreshCommandRegistered extends RegisterFreshCommandResult {
  const FreshCommandRegistered(this.command);
  final PendingRewardCommand command;
}

/// An active unresolved command already exists for this logical operation.
/// The fresh command was NOT inserted; the preexisting unresolved command is returned.
final class PreexistingCommandFound extends RegisterFreshCommandResult {
  const PreexistingCommandFound(this.existingCommand);
  final PendingRewardCommand existingCommand;
}

/// Port for durable local journal of pending reward commands.
abstract interface class PendingRewardCommandStore {
  /// Atomically registers a fresh pending command only if no unresolved pending command
  /// (as evaluated by [isCommandUnresolved], R24-5-03) already exists for the same
  /// logical operation (familyId, childId, operation, and optional rewardId).
  ///
  /// Serialized in SQLite via transaction, preventing check-then-insert races between concurrent calls (R24-4-01).
  Future<RegisterFreshCommandResult> registerFreshCommand({
    required PendingRewardCommand command,
    DateTime? now,
  });

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

  /// Atomically commits a token-fenced pre-dispatch marker ('possibly_dispatched')
  /// directly before remote mutating RPC execution.
  ///
  /// Requires matching [leaseToken], unexpired lease ([now] < lease_expires_at),
  /// actor_user_id == [authenticatedActorId], recovery_state == 'active',
  /// valid operation predicate (spin/redeem or adult fulfill/cancel), and
  /// dispatch_state IN ('never_dispatched', 'possibly_dispatched').
  ///
  /// Atomically resets any stale `[UNVERIFIED_TARGET_MISS:%` prefix in `last_error_message`
  /// upon successful target authorization (R28-05).
  Future<bool> markPossiblyDispatched({
    required String commandId,
    required String leaseToken,
    required String authenticatedActorId,
    required DateTime now,
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
  /// When [familyId] is provided, additionally filters by family_id == [familyId].
  Future<List<PendingRewardCommand>> listClaimableCommands({
    required String actorUserId,
    required int limit,
    DateTime? now,
    String? familyId,
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
