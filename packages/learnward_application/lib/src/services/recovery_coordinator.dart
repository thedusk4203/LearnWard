// ignore_for_file: prefer_initializing_formals

import 'dart:math';

import 'package:learnward_domain/learnward_domain.dart';

import '../ports/auth_session_port.dart';
import '../ports/clock.dart';
import '../ports/command_lifecycle_states.dart';
import '../ports/pending_reward_command_store.dart';
import '../ports/recovery_authorization_port.dart';
import '../ports/reward_repository.dart';
import '../ports/wheel_repository.dart';
import 'jitter_source.dart';
import 'recovery_error_classifier.dart';

/// Trigger origin for reward command execution.
enum CommandExecutionTrigger {
  /// Direct user action in the foreground (e.g. tapping spin or redeem).
  foreground,

  /// Automated background recovery drainage.
  recovery,
}

/// Unified result of a reward command execution attempt.
sealed class CommandExecutionResult {
  const CommandExecutionResult();
}

/// The command committed definitively on the server and was completed from journal.
final class CommandCommittedResult extends CommandExecutionResult {
  const CommandCommittedResult({
    required this.commandId,
    this.wheelResult,
    this.redemption,
  });

  final String commandId;
  final WheelSpinResult? wheelResult;
  final RewardRedemption? redemption;

  @override
  String toString() => 'CommandCommittedResult(commandId: $commandId)';
}

/// The command is already held by an active lease / in-flight worker.
final class CommandAlreadyInFlightResult extends CommandExecutionResult {
  const CommandAlreadyInFlightResult({required this.commandId});

  final String commandId;

  @override
  String toString() => 'CommandAlreadyInFlightResult(commandId: $commandId)';
}

/// The command encountered a retryable error and was rescheduled with exponential backoff.
final class CommandScheduledResult extends CommandExecutionResult {
  const CommandScheduledResult({
    required this.commandId,
    required this.nextAttemptAt,
    required this.retryCount,
    this.errorMessage,
    this.originalError,
  });

  final String commandId;
  final DateTime nextAttemptAt;
  final int retryCount;
  final String? errorMessage;
  final Object? originalError;

  @override
  String toString() =>
      'CommandScheduledResult(commandId: $commandId, retryCount: $retryCount, nextAttemptAt: $nextAttemptAt)';
}

/// The command belongs to a different original actor and was paused (pendingOriginalActor).
final class CommandPendingOriginalActorResult extends CommandExecutionResult {
  const CommandPendingOriginalActorResult({
    required this.commandId,
    required this.originalActorId,
    required this.reason,
    this.originalError,
  });

  final String commandId;
  final String originalActorId;
  final String reason;
  final Object? originalError;

  @override
  String toString() =>
      'CommandPendingOriginalActorResult(commandId: $commandId, originalActorId: $originalActorId)';
}

/// The command was transitioned to quarantinedUnknownOutcome due to ambiguous or unrecoverable state.
final class CommandQuarantinedResult extends CommandExecutionResult {
  const CommandQuarantinedResult({
    required this.commandId,
    required this.reason,
    this.originalError,
  });

  final String commandId;
  final String reason;
  final Object? originalError;

  @override
  String toString() =>
      'CommandQuarantinedResult(commandId: $commandId, reason: $reason)';
}

/// The command was definitively rejected by a terminal business rule (LW201, LW202, LW203, LW205, LW206).
final class CommandTerminalRejectionResult extends CommandExecutionResult {
  const CommandTerminalRejectionResult({
    required this.commandId,
    required this.errorCode,
    required this.errorMessage,
    this.originalError,
  });

  final String commandId;
  final String errorCode;
  final String errorMessage;
  final Object? originalError;

  @override
  String toString() =>
      'CommandTerminalRejectionResult(commandId: $commandId, code: $errorCode, message: $errorMessage)';
}

/// Authentication or session validation was unavailable; zero mutation RPC sent.
final class CommandAuthUnavailableResult extends CommandExecutionResult {
  const CommandAuthUnavailableResult({required this.reason});

  final String reason;

  @override
  String toString() => 'CommandAuthUnavailableResult(reason: $reason)';
}

/// Central application coordinator for actor-aware, restart-safe recovery of
/// [RewardCommandOperation.spinWheel] and [RewardCommandOperation.redeemReward].
final class RecoveryCoordinator {
  const RecoveryCoordinator({
    required PendingRewardCommandStore commandStore,
    WheelRepository? wheelRepository,
    RewardRepository? rewardRepository,
    required AuthSessionPort authSessionPort,
    required RecoveryAuthorizationPort authorizationPort,
    Clock clock = const SystemClock(),
    JitterSource jitterSource = const DeterministicJitterSource(),
    String Function()? uuidGenerator,
    Duration defaultLeaseDuration = const Duration(seconds: 30),
  }) : _commandStore = commandStore,
       _wheelRepository = wheelRepository,
       _rewardRepository = rewardRepository,
       _authSessionPort = authSessionPort,
       _authorizationPort = authorizationPort,
       _clock = clock,
       _jitterSource = jitterSource,
       _uuidGenerator = uuidGenerator,
       _defaultLeaseDuration = defaultLeaseDuration;

  final PendingRewardCommandStore _commandStore;
  final WheelRepository? _wheelRepository;
  final RewardRepository? _rewardRepository;
  final AuthSessionPort _authSessionPort;
  final RecoveryAuthorizationPort _authorizationPort;
  final Clock _clock;
  final JitterSource _jitterSource;
  final String Function()? _uuidGenerator;
  final Duration _defaultLeaseDuration;

  /// Executes a single Spin or Redeem command through the shared, locked recovery pipeline.
  Future<CommandExecutionResult> execute({
    required RewardCommandOperation operation,
    required String familyId,
    required String childId,
    String? rewardId,
    String? requestedCommandId,
    CommandExecutionTrigger trigger = CommandExecutionTrigger.foreground,
    Duration? overrideLeaseDuration,
  }) async {
    final now = _clock.now().toUtc();
    final leaseDuration = overrideLeaseDuration ?? _defaultLeaseDuration;

    // STEP 0 — GATE: Authenticated actor context & target authorization preflight
    final context = await _authSessionPort.validateForMutation();
    if (context == null) {
      return const CommandAuthUnavailableResult(
        reason: 'Missing or expired authenticated user session.',
      );
    }

    final authStatus = await _authorizationPort.verifyTarget(
      context: context,
      familyId: familyId,
      childId: childId,
      operation: operation,
    );

    if (authStatus == TargetAuthorizationStatus.definitelyDenied) {
      return CommandQuarantinedResult(
        commandId: requestedCommandId ?? 'unassigned',
        reason: 'Target family/child authorization definitively denied.',
      );
    }

    if (authStatus == TargetAuthorizationStatus.unverified) {
      return const CommandAuthUnavailableResult(
        reason: 'Target authorization could not be verified.',
      );
    }

    // STEP 1 — SELECT IDENTITY: Find exact existing command or create new
    PendingRewardCommand? command;

    if (requestedCommandId != null) {
      command = await _commandStore.getPendingCommand(requestedCommandId);
    } else if (operation == RewardCommandOperation.spinWheel) {
      command = await _commandStore.findPendingSpinCommand(
        familyId: familyId,
        childId: childId,
        recoveryState: null,
      );
    } else if (operation == RewardCommandOperation.redeemReward) {
      if (rewardId != null) {
        command = await _commandStore.findPendingRedeemCommand(
          familyId: familyId,
          childId: childId,
          rewardId: rewardId,
          recoveryState: null,
        );
      }
    }

    if (command != null) {
      // Validate existing command invariants
      if (command.dispatchState == CommandDispatchState.unknownLegacy ||
          command.recoveryState ==
              CommandRecoveryState.quarantinedUnknownOutcome ||
          command.recoveryState == CommandRecoveryState.terminalError) {
        return CommandQuarantinedResult(
          commandId: command.commandId,
          reason: 'Command is quarantined or legacy unknown.',
        );
      }

      if (command.dispatchState == CommandDispatchState.confirmedCommitted) {
        return CommandCommittedResult(commandId: command.commandId);
      }

      // Check actor match
      if (command.actorUserId != null &&
          command.actorUserId != context.userId) {
        if (trigger == CommandExecutionTrigger.recovery) {
          await _commandStore.pauseMismatchedActorCommand(
            commandId: command.commandId,
            familyId: familyId,
            authenticatedActorId: context.userId,
            mismatchReason: 'Signed in as different user',
            now: now,
          );
        }
        return CommandPendingOriginalActorResult(
          commandId: command.commandId,
          originalActorId: command.actorUserId!,
          reason: 'Actor mismatch with authenticated session',
        );
      }

      // Gating for recovery trigger on nextAttemptAt
      if (trigger == CommandExecutionTrigger.recovery &&
          command.nextAttemptAt != null &&
          command.nextAttemptAt!.isAfter(now)) {
        return CommandScheduledResult(
          commandId: command.commandId,
          nextAttemptAt: command.nextAttemptAt!,
          retryCount: command.retryCount,
        );
      }
    } else {
      // No existing command found
      if (trigger == CommandExecutionTrigger.recovery) {
        return const CommandAuthUnavailableResult(
          reason: 'No recoverable pending command found.',
        );
      }

      // Fresh foreground intent: generate stable ID and save never_dispatched
      final newCommandId = requestedCommandId ?? _generateUuid();
      final freshCmd = PendingRewardCommand(
        operation: operation,
        commandId: newCommandId,
        familyId: familyId,
        childId: childId,
        rewardId: rewardId,
        createdAt: now,
        actorUserId: context.userId,
        actorRole: context.role,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );

      await _commandStore.savePendingCommand(freshCmd, now: now);
      command = freshCmd;
    }

    // STEP 2 — ATOMICALLY ACQUIRE CLAIM
    final leaseToken = await _commandStore.acquireClaim(
      commandId: command.commandId,
      actorUserId: context.userId,
      leaseDuration: leaseDuration,
      now: now,
    );

    if (leaseToken == null) {
      final latest = await _commandStore.getPendingCommand(command.commandId);
      if (latest != null &&
          latest.nextAttemptAt != null &&
          latest.nextAttemptAt!.isAfter(now)) {
        return CommandScheduledResult(
          commandId: command.commandId,
          nextAttemptAt: latest.nextAttemptAt!,
          retryCount: latest.retryCount,
          errorMessage: latest.lastErrorMessage,
        );
      }
      return CommandAlreadyInFlightResult(commandId: command.commandId);
    }

    // STEP 3 — REVALIDATE AUTH/AUTHORIZATION
    if (_authSessionPort.currentSessionGeneration !=
        context.sessionGeneration) {
      // Session epoch changed during claim acquisition
      return const CommandAuthUnavailableResult(
        reason: 'Session epoch changed during claim acquisition.',
      );
    }

    // STEP 4 — DURABLE PRE-SEND MARKER (TOKEN-FENCED)
    final markSuccess = await _commandStore.markPossiblyDispatched(
      commandId: command.commandId,
      leaseToken: leaseToken,
      authenticatedActorId: context.userId,
      now: _clock.now().toUtc(),
    );

    if (!markSuccess) {
      // Token-fenced marker failed (e.g. lease expired or was taken over)
      return CommandAlreadyInFlightResult(commandId: command.commandId);
    }

    // STEP 5 — FINAL SESSION GATE IMMEDIATELY BEFORE RPC
    if (_authSessionPort.currentSessionGeneration !=
        context.sessionGeneration) {
      return const CommandAuthUnavailableResult(
        reason: 'Session changed immediately prior to remote RPC.',
      );
    }

    // STEP 6 — REMOTE RPC EXECUTION
    try {
      if (operation == RewardCommandOperation.spinWheel) {
        final wheelRepo = _wheelRepository;
        if (wheelRepo == null) {
          throw StateError(
            'WheelRepository not provided to RecoveryCoordinator',
          );
        }

        final result = await wheelRepo.spinRewardWheel(
          commandId: command.commandId,
          childId: ChildId(childId),
        );

        // STEP 7A — DEFINITIVE SUCCESS UNDER CURRENT LEASE
        await _commandStore.completeCommand(
          commandId: command.commandId,
          leaseToken: leaseToken,
        );

        return CommandCommittedResult(
          commandId: command.commandId,
          wheelResult: result,
        );
      } else if (operation == RewardCommandOperation.redeemReward) {
        final rewardRepo = _rewardRepository;
        if (rewardRepo == null) {
          throw StateError(
            'RewardRepository not provided to RecoveryCoordinator',
          );
        }

        final result = await rewardRepo.redeemStoreReward(
          commandId: command.commandId,
          childId: ChildId(childId),
          rewardId: RewardId(rewardId!),
        );

        // STEP 7A — DEFINITIVE SUCCESS UNDER CURRENT LEASE
        await _commandStore.completeCommand(
          commandId: command.commandId,
          leaseToken: leaseToken,
        );

        return CommandCommittedResult(
          commandId: command.commandId,
          redemption: result,
        );
      } else {
        throw UnsupportedError(
          'Operation $operation is out of scope for Slice 4A-1',
        );
      }
    } catch (e) {
      // STEP 7B — ERROR DISPOSITION UNDER CURRENT LEASE
      final classified = RecoveryErrorClassifier.classify(e);

      switch (classified.action) {
        case ClassifiedErrorAction.terminalWhitelisted:
          // Whitelisted business error: delete journal with token fencing
          await _commandStore.completeCommand(
            commandId: command.commandId,
            leaseToken: leaseToken,
          );
          return CommandTerminalRejectionResult(
            commandId: command.commandId,
            errorCode: classified.errorCode ?? 'TERMINAL_ERROR',
            errorMessage: classified.sanitizedMessage,
            originalError: e,
          );

        case ClassifiedErrorAction.deviceRevoked:
          await _commandStore.transitionRecoveryState(
            commandId: command.commandId,
            leaseToken: leaseToken,
            newState: CommandRecoveryState.quarantinedUnknownOutcome,
            lastErrorMessage: classified.sanitizedMessage,
          );
          return CommandQuarantinedResult(
            commandId: command.commandId,
            reason: classified.sanitizedMessage,
            originalError: e,
          );

        case ClassifiedErrorAction.quarantineUnknownOutcome:
          await _commandStore.transitionRecoveryState(
            commandId: command.commandId,
            leaseToken: leaseToken,
            newState: CommandRecoveryState.quarantinedUnknownOutcome,
            lastErrorMessage: classified.sanitizedMessage,
          );
          return CommandQuarantinedResult(
            commandId: command.commandId,
            reason: classified.sanitizedMessage,
            originalError: e,
          );

        case ClassifiedErrorAction.transientRetryable:
          // Calculate bounded exponential backoff with full jitter
          // Failure number n = persistedRetryCount + 1
          final latestRow = await _commandStore.getPendingCommand(
            command.commandId,
          );
          final currentRetry = latestRow?.retryCount ?? command.retryCount;
          final n = currentRetry + 1;

          // cap = min(60s, 2s * 2^(n-1))
          final capSeconds = min(60.0, 2.0 * pow(2.0, n - 1));
          final jitterUniform = _jitterSource.sampleUniform();
          final waitSeconds = jitterUniform * capSeconds;
          final nextAttemptAt = now.add(
            Duration(milliseconds: (waitSeconds * 1000).toInt()),
          );

          await _commandStore.releaseClaim(
            commandId: command.commandId,
            leaseToken: leaseToken,
            nextAttemptAt: nextAttemptAt,
            lastErrorMessage: classified.sanitizedMessage,
          );

          return CommandScheduledResult(
            commandId: command.commandId,
            nextAttemptAt: nextAttemptAt,
            retryCount: n,
            errorMessage: classified.sanitizedMessage,
            originalError: e,
          );
      }
    }
  }

  String _generateUuid() {
    if (_uuidGenerator != null) return _uuidGenerator();
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}
