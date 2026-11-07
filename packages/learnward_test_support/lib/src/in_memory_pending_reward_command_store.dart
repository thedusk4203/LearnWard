import 'dart:math';

import 'package:learnward_application/learnward_application.dart';

/// In-memory implementation of [PendingRewardCommandStore] for fast unit/widget tests.
final class InMemoryPendingRewardCommandStore
    implements PendingRewardCommandStore {
  final Map<String, PendingRewardCommand> _commands = {};

  static String _generateLeaseToken() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  bool _isLeaseAvailable(PendingRewardCommand cmd, DateTime effectiveNow) {
    final isUnleased = cmd.leaseToken == null && cmd.leaseExpiresAt == null;
    final isExpired =
        cmd.leaseToken != null &&
        cmd.leaseExpiresAt != null &&
        !cmd.leaseExpiresAt!.isAfter(effectiveNow);
    return isUnleased || isExpired;
  }

  @override
  Future<void> savePendingCommand(
    PendingRewardCommand command, {
    DateTime? now,
  }) async {
    final hasPartialLease =
        (command.leaseToken != null && command.leaseExpiresAt == null) ||
        (command.leaseToken == null && command.leaseExpiresAt != null);
    if (hasPartialLease) {
      throw ArgumentError(
        'Cannot save pending command ${command.commandId}: partial lease metadata '
        '(leaseToken=${command.leaseToken}, leaseExpiresAt=${command.leaseExpiresAt})',
      );
    }

    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final existing = _commands[command.commandId];

    if (existing == null) {
      _commands[command.commandId] = command.copyWith(
        createdAt: command.createdAt.toUtc(),
        nextAttemptAt: command.nextAttemptAt?.toUtc(),
        leaseToken: null,
        leaseExpiresAt: null,
      );
      return;
    }

    final hasActiveLease =
        existing.leaseToken != null &&
        existing.leaseExpiresAt != null &&
        existing.leaseExpiresAt!.isAfter(effectiveNow);

    if (hasActiveLease) {
      throw StateError(
        'Cannot overwrite pending command ${command.commandId}: held by an active lease',
      );
    }

    _commands[command.commandId] = existing.copyWith(
      operation: command.operation,
      familyId: command.familyId,
      childId: command.childId ?? existing.childId,
      rewardId: command.rewardId ?? existing.rewardId,
      redemptionId: command.redemptionId ?? existing.redemptionId,
      cancellationReason:
          command.cancellationReason ?? existing.cancellationReason,
      actorUserId: existing.actorUserId ?? command.actorUserId,
      actorRole: existing.actorRole ?? command.actorRole,
      recoveryState: existing.recoveryState != CommandRecoveryState.active
          ? existing.recoveryState
          : command.recoveryState,
      dispatchState:
          existing.dispatchState == CommandDispatchState.possiblyDispatched
          ? CommandDispatchState.possiblyDispatched
          : command.dispatchState,
      retryCount: existing.retryCount > command.retryCount
          ? existing.retryCount
          : command.retryCount,
      nextAttemptAt: existing.nextAttemptAt ?? command.nextAttemptAt?.toUtc(),
      lastErrorMessage: existing.lastErrorMessage ?? command.lastErrorMessage,
      leaseToken: null,
      leaseExpiresAt: null,
    );
  }

  @override
  Future<PendingRewardCommand?> getPendingCommand(String commandId) async {
    return _commands[commandId];
  }

  @override
  Future<PendingRewardCommand?> findPendingSpinCommand({
    required String familyId,
    required String childId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == RewardCommandOperation.spinWheel &&
          cmd.familyId == familyId &&
          cmd.childId == childId &&
          (recoveryState == null || cmd.recoveryState == recoveryState) &&
          (actorUserId == null || cmd.actorUserId == actorUserId)) {
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
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == RewardCommandOperation.redeemReward &&
          cmd.familyId == familyId &&
          cmd.childId == childId &&
          cmd.rewardId == rewardId &&
          (recoveryState == null || cmd.recoveryState == recoveryState) &&
          (actorUserId == null || cmd.actorUserId == actorUserId)) {
        return cmd;
      }
    }
    return null;
  }

  @override
  Future<PendingRewardCommand?> findPendingRedemptionCommand({
    required RewardCommandOperation operation,
    required String redemptionId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == operation &&
          cmd.redemptionId == redemptionId &&
          (recoveryState == null || cmd.recoveryState == recoveryState) &&
          (actorUserId == null || cmd.actorUserId == actorUserId)) {
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
    final cmd = _commands[commandId];
    if (cmd == null) return;
    if (cmd.leaseToken == null && cmd.leaseExpiresAt == null) {
      _commands.remove(commandId);
    }
  }

  // ---------------------------------------------------------------------------
  // PHASE 6 SLICE 4A-0: ATOMIC CAS STORE OPERATIONS & FENCING
  // ---------------------------------------------------------------------------

  @override
  Future<String?> acquireClaim({
    required String commandId,
    required String actorUserId,
    required Duration leaseDuration,
    DateTime? now,
    String? overrideLeaseToken,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final cmd = _commands[commandId];
    if (cmd == null) return null;

    if (cmd.actorUserId != actorUserId) return null;
    if (cmd.recoveryState != CommandRecoveryState.active) return null;
    if (cmd.operation != RewardCommandOperation.spinWheel &&
        cmd.operation != RewardCommandOperation.redeemReward) {
      return null;
    }
    if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
        cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
      return null;
    }
    if (cmd.nextAttemptAt != null && cmd.nextAttemptAt!.isAfter(effectiveNow)) {
      return null;
    }
    if (!_isLeaseAvailable(cmd, effectiveNow)) {
      return null;
    }

    final newLeaseToken = overrideLeaseToken ?? _generateLeaseToken();
    final leaseExpiresAt = effectiveNow.add(leaseDuration);

    _commands[commandId] = cmd.copyWith(
      leaseToken: newLeaseToken,
      leaseExpiresAt: leaseExpiresAt,
    );
    return newLeaseToken;
  }

  @override
  Future<bool> releaseClaim({
    required String commandId,
    required String leaseToken,
    required DateTime nextAttemptAt,
    String? lastErrorMessage,
  }) async {
    final cmd = _commands[commandId];
    if (cmd == null) return false;
    if (cmd.leaseToken != leaseToken) return false;

    _commands[commandId] = cmd.copyWith(
      retryCount: cmd.retryCount + 1,
      nextAttemptAt: nextAttemptAt.toUtc(),
      lastErrorMessage: lastErrorMessage,
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return true;
  }

  @override
  Future<bool> completeCommand({
    required String commandId,
    required String leaseToken,
  }) async {
    final cmd = _commands[commandId];
    if (cmd == null) return false;
    if (cmd.leaseToken != leaseToken) return false;

    _commands.remove(commandId);
    return true;
  }

  @override
  Future<bool> transitionRecoveryState({
    required String commandId,
    required String leaseToken,
    required CommandRecoveryState newState,
    String? lastErrorMessage,
  }) async {
    final cmd = _commands[commandId];
    if (cmd == null) return false;
    if (cmd.leaseToken != leaseToken) return false;

    _commands[commandId] = cmd.copyWith(
      recoveryState: newState,
      lastErrorMessage: lastErrorMessage,
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return true;
  }

  @override
  Future<bool> pauseMismatchedActorCommand({
    required String commandId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final cmd = _commands[commandId];
    if (cmd == null) return false;

    if (cmd.familyId != familyId) return false;
    if (cmd.actorUserId == null || cmd.actorUserId == authenticatedActorId) {
      return false;
    }
    if (cmd.recoveryState != CommandRecoveryState.active) return false;
    if (cmd.operation != RewardCommandOperation.spinWheel &&
        cmd.operation != RewardCommandOperation.redeemReward) {
      return false;
    }
    if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
        cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
      return false;
    }
    if (!_isLeaseAvailable(cmd, effectiveNow)) {
      return false;
    }

    _commands[commandId] = cmd.copyWith(
      recoveryState: CommandRecoveryState.pendingOriginalActor,
      lastErrorMessage: mismatchReason,
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return true;
  }

  @override
  Future<bool> resumeOriginalActorCommand({
    required String commandId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final cmd = _commands[commandId];
    if (cmd == null) return false;

    if (cmd.familyId != familyId) return false;
    if (cmd.actorUserId != authenticatedActorId) return false;
    if (cmd.recoveryState != CommandRecoveryState.pendingOriginalActor) {
      return false;
    }
    if (cmd.operation != RewardCommandOperation.spinWheel &&
        cmd.operation != RewardCommandOperation.redeemReward) {
      return false;
    }
    if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
        cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
      return false;
    }
    if (!_isLeaseAvailable(cmd, effectiveNow)) {
      return false;
    }

    _commands[commandId] = cmd.copyWith(
      recoveryState: CommandRecoveryState.active,
      lastErrorMessage: null,
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return true;
  }

  @override
  Future<List<PendingRewardCommand>> listClaimableCommands({
    required String actorUserId,
    required int limit,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final list = _commands.values.where((cmd) {
      if (cmd.actorUserId != actorUserId) return false;
      if (cmd.recoveryState != CommandRecoveryState.active) return false;
      if (cmd.operation != RewardCommandOperation.spinWheel &&
          cmd.operation != RewardCommandOperation.redeemReward) {
        return false;
      }
      if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
          cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
        return false;
      }
      if (cmd.nextAttemptAt != null &&
          cmd.nextAttemptAt!.isAfter(effectiveNow)) {
        return false;
      }
      if (!_isLeaseAvailable(cmd, effectiveNow)) {
        return false;
      }
      return true;
    }).toList();

    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<PendingRewardCommand>> listMismatchedActiveCommands({
    required String familyId,
    required String authenticatedActorId,
    required int limit,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final list = _commands.values.where((cmd) {
      if (cmd.familyId != familyId) return false;
      if (cmd.actorUserId == null || cmd.actorUserId == authenticatedActorId) {
        return false;
      }
      if (cmd.recoveryState != CommandRecoveryState.active) return false;
      if (cmd.operation != RewardCommandOperation.spinWheel &&
          cmd.operation != RewardCommandOperation.redeemReward) {
        return false;
      }
      if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
          cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
        return false;
      }
      if (!_isLeaseAvailable(cmd, effectiveNow)) {
        return false;
      }
      return true;
    }).toList();

    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<PendingRewardCommand>> listPausedOriginalActorCommands({
    required String familyId,
    required String authenticatedActorId,
    required int limit,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final list = _commands.values.where((cmd) {
      if (cmd.familyId != familyId) return false;
      if (cmd.actorUserId != authenticatedActorId) return false;
      if (cmd.recoveryState != CommandRecoveryState.pendingOriginalActor) {
        return false;
      }
      if (cmd.operation != RewardCommandOperation.spinWheel &&
          cmd.operation != RewardCommandOperation.redeemReward) {
        return false;
      }
      if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
          cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
        return false;
      }
      if (!_isLeaseAvailable(cmd, effectiveNow)) {
        return false;
      }
      return true;
    }).toList();

    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list.take(limit).toList();
  }
}
