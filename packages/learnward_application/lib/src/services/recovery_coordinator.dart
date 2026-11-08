// ignore_for_file: prefer_initializing_formals

import 'dart:async';
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

/// Trigger source initiating a command execution attempt.
enum CommandExecutionTrigger {
  /// Invoked by foreground user action (e.g. tapping "Spin Wheel" or "Get Reward").
  foreground,

  /// Invoked by foreground user tapping explicit retry on an unresolved pending command.
  foregroundRetry,

  /// Invoked by the background/app-active outbox recovery dispatcher.
  recovery,
}

/// Abstract result representing the outcome of a coordinator execution attempt.
sealed class CommandExecutionResult {
  const CommandExecutionResult();
}

/// The command was definitively executed and confirmed on the server, and the
/// durable journal row has been safely completed.
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

/// The command was scheduled for a future retry attempt under exponential backoff.
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
      'CommandScheduledResult(commandId: $commandId, nextAttemptAt: $nextAttemptAt, retryCount: $retryCount)';
}

/// The command is currently held by another worker or an unexpired active lease.
final class CommandAlreadyInFlightResult extends CommandExecutionResult {
  const CommandAlreadyInFlightResult({required this.commandId});

  final String commandId;

  @override
  String toString() => 'CommandAlreadyInFlightResult(commandId: $commandId)';
}

/// The command belongs to a different original actor and was paused in SQLite.
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

/// The command belongs to a family that does not match the active UI family selection.
/// Mutation RPC is aborted and the lease is released without quarantining or terminal rejection.
final class CommandFamilyMismatchResult extends CommandExecutionResult {
  const CommandFamilyMismatchResult({
    required this.commandId,
    required this.commandFamilyId,
    required this.activeFamilyId,
  });

  final String commandId;
  final String commandFamilyId;
  final String? activeFamilyId;

  @override
  String toString() =>
      'CommandFamilyMismatchResult(commandId: $commandId, commandFamilyId: $commandFamilyId, activeFamilyId: $activeFamilyId)';
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
    String? Function()? activeFamilyIdProvider,
    Clock clock = const SystemClock(),
    JitterSource jitterSource = const RandomJitterSource(),
    String Function()? uuidGenerator,
    Duration defaultLeaseDuration = const Duration(seconds: 30),
  }) : _commandStore = commandStore,
       _wheelRepository = wheelRepository,
       _rewardRepository = rewardRepository,
       _authSessionPort = authSessionPort,
       _authorizationPort = authorizationPort,
       _activeFamilyIdProvider = activeFamilyIdProvider,
       _clock = clock,
       _jitterSource = jitterSource,
       _uuidGenerator = uuidGenerator,
       _defaultLeaseDuration = defaultLeaseDuration;

  final PendingRewardCommandStore _commandStore;
  final WheelRepository? _wheelRepository;
  final RewardRepository? _rewardRepository;
  final AuthSessionPort _authSessionPort;
  final RecoveryAuthorizationPort _authorizationPort;
  final String? Function()? _activeFamilyIdProvider;
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

    // Active UI family match pre-check (R24-3-03)
    if (_activeFamilyIdProvider != null) {
      final currentActiveFamily = _activeFamilyIdProvider();
      if (currentActiveFamily != null && currentActiveFamily != familyId) {
        return CommandFamilyMismatchResult(
          commandId: requestedCommandId ?? 'unassigned',
          commandFamilyId: familyId,
          activeFamilyId: currentActiveFamily,
        );
      }
    }

    final authStatus = await _authorizationPort.verifyTarget(
      context: context,
      familyId: familyId,
      childId: childId,
      operation: operation,
    );

    // M01 / H05: Handle preflight definitive denial or confirmed revocation
    if (authStatus == TargetAuthorizationStatus.definitelyDenied ||
        authStatus == TargetAuthorizationStatus.confirmedRevoked) {
      final denialReason =
          authStatus == TargetAuthorizationStatus.confirmedRevoked
          ? 'Device grant confirmed revoked prior to execution.'
          : 'Target family/child authorization definitively denied.';

      // If an existing command was targeted, acquire claim and safely transition it to quarantine in SQLite.
      if (requestedCommandId != null) {
        final existing = await _commandStore.getPendingCommand(
          requestedCommandId,
        );
        if (existing != null &&
            existing.recoveryState == CommandRecoveryState.active) {
          final claimToken = await _commandStore.acquireClaim(
            commandId: existing.commandId,
            actorUserId: context.userId,
            leaseDuration: const Duration(seconds: 10),
            now: now,
          );
          if (claimToken == null) {
            // CAS failure: command is currently leased or locked by another worker
            return CommandAlreadyInFlightResult(commandId: existing.commandId);
          }
          final transitioned = await _commandStore.transitionRecoveryState(
            commandId: existing.commandId,
            leaseToken: claimToken,
            newState: CommandRecoveryState.quarantinedUnknownOutcome,
            lastErrorMessage: denialReason,
          );
          if (!transitioned) {
            // CAS failure: state transition failed (e.g. lease expired or preempted)
            return CommandAlreadyInFlightResult(commandId: existing.commandId);
          }
        }
      }

      return CommandQuarantinedResult(
        commandId: requestedCommandId ?? 'unassigned',
        reason: denialReason,
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
      // W3 / H04: Strict requested ID lookup. Missing retry ID fails closed!
      command = await _commandStore.getPendingCommand(requestedCommandId);
      if (command == null) {
        return CommandQuarantinedResult(
          commandId: requestedCommandId,
          reason:
              'Pending command not found for requested retry ID: $requestedCommandId',
        );
      }

      // W3 / H04: Validate stored immutable payload against invocation arguments.
      final matchesTarget =
          command.operation == operation &&
          command.familyId == familyId &&
          command.childId == childId &&
          (operation != RewardCommandOperation.redeemReward ||
              command.rewardId == rewardId);

      if (!matchesTarget) {
        return CommandQuarantinedResult(
          commandId: command.commandId,
          reason:
              'Mismatched command payload for existing command ID ${command.commandId}. '
              'Expected op=$operation, fam=$familyId, child=$childId, reward=$rewardId; '
              'Stored op=${command.operation}, fam=${command.familyId}, child=${command.childId}, reward=${command.rewardId}',
        );
      }
    } else {
      // requestedCommandId is null
      if (trigger == CommandExecutionTrigger.recovery ||
          trigger == CommandExecutionTrigger.foregroundRetry) {
        // Missing explicit retry ID must fail closed!
        return const CommandAuthUnavailableResult(
          reason: 'Missing explicit retry ID for recovery dispatch.',
        );
      }

      // Fresh foreground user intent: check if an unresolved command already exists
      PendingRewardCommand? existingPending;
      if (operation == RewardCommandOperation.spinWheel) {
        existingPending = await _commandStore.findPendingSpinCommand(
          familyId: familyId,
          childId: childId,
          recoveryState: null,
        );
      } else if (operation == RewardCommandOperation.redeemReward &&
          rewardId != null) {
        existingPending = await _commandStore.findPendingRedeemCommand(
          familyId: familyId,
          childId: childId,
          rewardId: rewardId,
          recoveryState: null,
        );
      }

      if (existingPending != null &&
          (existingPending.recoveryState == CommandRecoveryState.active ||
              existingPending.dispatchState ==
                  CommandDispatchState.possiblyDispatched)) {
        // Unresolved pending command exists for this target. Cannot create replacement command!
        return CommandAlreadyInFlightResult(
          commandId: existingPending.commandId,
        );
      }

      // Truly fresh foreground intent: generate new UUID and save as never_dispatched
      final newCommandId = _generateUuid();
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

    // Check actor match (R24-3-02: must run before claim and before confirmedCommitted reconciliation!)
    if (command.actorUserId != null && command.actorUserId != context.userId) {
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

    // Active family check on loaded command (R24-3-03)
    if (_activeFamilyIdProvider != null) {
      final currentActive = _activeFamilyIdProvider();
      if (currentActive != null && currentActive != command.familyId) {
        return CommandFamilyMismatchResult(
          commandId: command.commandId,
          commandFamilyId: command.familyId,
          activeFamilyId: currentActive,
        );
      }
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

    // STEP 2 — ATOMICALLY ACQUIRE CLAIM (OR REUSE ACTIVE UNEXPIRED CLAIM HELD BY CALLER)
    String? leaseToken;
    final isExistingLeaseValid =
        command.leaseToken != null &&
        command.leaseExpiresAt != null &&
        command.leaseExpiresAt!.isAfter(now) &&
        command.actorUserId == context.userId;

    if (isExistingLeaseValid) {
      leaseToken = command.leaseToken;
    } else {
      leaseToken = await _commandStore.acquireClaim(
        commandId: command.commandId,
        actorUserId: context.userId,
        leaseDuration: leaseDuration,
        now: now,
      );
    }

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

    // STEP 3 — REVALIDATE AUTH/AUTHORIZATION AFTER CLAIM
    if (_authSessionPort.currentSessionGeneration !=
        context.sessionGeneration) {
      // Session epoch changed during claim acquisition: release claim and fail closed
      await _commandStore.releaseClaim(
        commandId: command.commandId,
        leaseToken: leaseToken,
        nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 1)),
        lastErrorMessage: 'Session epoch changed during claim acquisition.',
      );
      return const CommandAuthUnavailableResult(
        reason: 'Session epoch changed during claim acquisition.',
      );
    }

    // STEP 4 — DURABLE PRE-SEND MARKER (TOKEN-FENCED)
    // If command was already confirmedCommitted, skip markPossiblyDispatched.
    if (command.dispatchState != CommandDispatchState.confirmedCommitted) {
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
    }

    // STEP 5 — FINAL LIVE AUTH & TARGET & FAMILY GATE IMMEDIATELY BEFORE RPC (W5 / M02, R24-3-03)
    final freshContext = await _authSessionPort.validateForMutation();
    if (freshContext == null ||
        freshContext.userId != context.userId ||
        _authSessionPort.currentSessionGeneration !=
            context.sessionGeneration) {
      // Session or actor invalidated immediately before RPC: ZERO RPC!
      await _commandStore.releaseClaim(
        commandId: command.commandId,
        leaseToken: leaseToken,
        nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 1)),
        lastErrorMessage:
            'Session or actor invalidated immediately prior to remote RPC.',
      );
      return const CommandAuthUnavailableResult(
        reason: 'Session or actor changed immediately prior to remote RPC.',
      );
    }

    // In-flight active UI family recheck immediately before RPC (R24-3-03)
    if (_activeFamilyIdProvider != null) {
      final currentActive = _activeFamilyIdProvider();
      if (currentActive != null && currentActive != command.familyId) {
        await _commandStore.releaseClaim(
          commandId: command.commandId,
          leaseToken: leaseToken,
          nextAttemptAt: _clock.now().toUtc(),
          lastErrorMessage:
              'Active family changed to $currentActive prior to remote RPC.',
        );
        return CommandFamilyMismatchResult(
          commandId: command.commandId,
          commandFamilyId: command.familyId,
          activeFamilyId: currentActive,
        );
      }
    }

    final freshAuth = await _authorizationPort.verifyTarget(
      context: freshContext,
      familyId: command.familyId,
      childId: command.childId!,
      operation: command.operation,
    );

    if (freshAuth == TargetAuthorizationStatus.confirmedRevoked ||
        freshAuth == TargetAuthorizationStatus.definitelyDenied) {
      final reason = freshAuth == TargetAuthorizationStatus.confirmedRevoked
          ? 'Device grant confirmed revoked prior to RPC.'
          : 'Target authorization definitely denied prior to RPC.';

      final transitioned = await _commandStore.transitionRecoveryState(
        commandId: command.commandId,
        leaseToken: leaseToken,
        newState: CommandRecoveryState.quarantinedUnknownOutcome,
        lastErrorMessage: reason,
      );
      if (!transitioned) {
        // Lost lease ownership / CAS failure (R24-3-04)
        return CommandAlreadyInFlightResult(commandId: command.commandId);
      }
      return CommandQuarantinedResult(
        commandId: command.commandId,
        reason: reason,
      );
    }

    if (freshAuth == TargetAuthorizationStatus.unverified) {
      // Network or authorization verification unavailable immediately before RPC:
      // Release claim with backoff, ZERO RPC executed!
      await _commandStore.releaseClaim(
        commandId: command.commandId,
        leaseToken: leaseToken,
        nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 5)),
        lastErrorMessage:
            'Target authorization unverified immediately prior to remote RPC.',
      );
      return const CommandAuthUnavailableResult(
        reason:
            'Target authorization unverified immediately prior to remote RPC.',
      );
    }

    // STEP 6 — AUTHORITATIVE REMOTE RPC EXECUTION (OR RECONCILIATION FOR confirmedCommitted)
    // Strictly execute using the validated stored immutable command payload under active lease!
    try {
      if (command.operation == RewardCommandOperation.spinWheel) {
        final wheelRepo = _wheelRepository;
        if (wheelRepo == null) {
          throw StateError(
            'WheelRepository not provided to RecoveryCoordinator',
          );
        }

        final result = await wheelRepo.spinRewardWheel(
          commandId: command.commandId,
          childId: ChildId(command.childId!),
        );

        // STEP 7A — DEFINITIVE SUCCESS UNDER CURRENT LEASE
        final completed = await _commandStore.completeCommand(
          commandId: command.commandId,
          leaseToken: leaseToken,
        );

        if (!completed) {
          // Lost lease ownership! Another worker preempted or lease expired (R24-3-04).
          return CommandAlreadyInFlightResult(commandId: command.commandId);
        }

        return CommandCommittedResult(
          commandId: command.commandId,
          wheelResult: result,
        );
      } else if (command.operation == RewardCommandOperation.redeemReward) {
        final rewardRepo = _rewardRepository;
        if (rewardRepo == null) {
          throw StateError(
            'RewardRepository not provided to RecoveryCoordinator',
          );
        }

        final result = await rewardRepo.redeemStoreReward(
          commandId: command.commandId,
          childId: ChildId(command.childId!),
          rewardId: RewardId(command.rewardId!),
        );

        // STEP 7A — DEFINITIVE SUCCESS UNDER CURRENT LEASE
        final completed = await _commandStore.completeCommand(
          commandId: command.commandId,
          leaseToken: leaseToken,
        );

        if (!completed) {
          // Lost lease ownership! Another worker preempted or lease expired (R24-3-04).
          return CommandAlreadyInFlightResult(commandId: command.commandId);
        }

        return CommandCommittedResult(
          commandId: command.commandId,
          redemption: result,
        );
      } else {
        throw UnsupportedError(
          'Operation ${command.operation} is out of scope for Slice 4A-1',
        );
      }
    } catch (e) {
      // STEP 7B — ERROR DISPOSITION UNDER CURRENT LEASE
      final classified = RecoveryErrorClassifier.classify(e);

      switch (classified.action) {
        case ClassifiedErrorAction.terminalWhitelisted:
          // Whitelisted business error: complete/delete journal with token fencing
          final completed = await _commandStore.completeCommand(
            commandId: command.commandId,
            leaseToken: leaseToken,
          );

          if (!completed) {
            // Lost lease ownership / CAS failure (R24-3-04)
            return CommandAlreadyInFlightResult(commandId: command.commandId);
          }

          return CommandTerminalRejectionResult(
            commandId: command.commandId,
            errorCode: classified.errorCode ?? 'TERMINAL_ERROR',
            errorMessage: classified.sanitizedMessage,
            originalError: e,
          );

        case ClassifiedErrorAction.deviceRevoked:
        case ClassifiedErrorAction.quarantineUnknownOutcome:
          // Ambiguous authorization failure, 42501, or unwhitelisted error
          final transitioned = await _commandStore.transitionRecoveryState(
            commandId: command.commandId,
            leaseToken: leaseToken,
            newState: CommandRecoveryState.quarantinedUnknownOutcome,
            lastErrorMessage: classified.sanitizedMessage,
          );

          if (!transitioned) {
            // Lost lease ownership / CAS failure (R24-3-04)
            return CommandAlreadyInFlightResult(commandId: command.commandId);
          }

          return CommandQuarantinedResult(
            commandId: command.commandId,
            reason: classified.sanitizedMessage,
            originalError: e,
          );

        case ClassifiedErrorAction.transientRetryable:
          // W4 / H03: Calculate bounded exponential backoff with full jitter anchored AFTER failure
          final postFailureNow = _clock.now().toUtc();
          final latestRow = await _commandStore.getPendingCommand(
            command.commandId,
          );
          final currentRetry = latestRow?.retryCount ?? command.retryCount;
          final n = currentRetry + 1;

          // cap = min(60s, 2s * 2^(n-1))
          final capSeconds = min(60.0, 2.0 * pow(2.0, n - 1));
          final jitterUniform = _jitterSource.sampleUniform();
          var waitSeconds = jitterUniform * capSeconds;

          // Scheduler flood guard: at least 1 second minimum wait to prevent thundering herd (unless explicitly deterministic in tests)
          if (_jitterSource is! DeterministicJitterSource &&
              waitSeconds < 1.0) {
            waitSeconds = 1.0;
          }

          final nextAttemptAt = postFailureNow.add(
            Duration(milliseconds: (waitSeconds * 1000).toInt()),
          );

          final released = await _commandStore.releaseClaim(
            commandId: command.commandId,
            leaseToken: leaseToken,
            nextAttemptAt: nextAttemptAt,
            lastErrorMessage: classified.sanitizedMessage,
          );

          if (!released) {
            // Lost lease ownership / CAS failure (R24-3-04)
            return CommandAlreadyInFlightResult(commandId: command.commandId);
          }

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
