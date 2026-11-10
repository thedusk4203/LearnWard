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
/// [RewardCommandOperation.spinWheel], [RewardCommandOperation.redeemReward],
/// [RewardCommandOperation.fulfillReward], and [RewardCommandOperation.cancelReward].
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

  static const int maxConsecutiveUnverifiedTargetMisses =
      PendingRewardCommand.maxConsecutiveUnverifiedTargetMisses;

  Duration _calculateBackoff(int n, {double minFloorSeconds = 1.0}) {
    final capSeconds = min(60.0, 2.0 * pow(2.0, n - 1));
    final jitterUniform = _jitterSource.sampleUniform();
    var waitSeconds = jitterUniform * capSeconds;

    if (_jitterSource is! DeterministicJitterSource &&
        waitSeconds < minFloorSeconds) {
      waitSeconds = minFloorSeconds;
    }

    return Duration(milliseconds: (waitSeconds * 1000).toInt());
  }

  /// Executes a single reward command through the shared, locked recovery pipeline.
  Future<CommandExecutionResult> execute({
    required RewardCommandOperation operation,
    required String familyId,
    required String childId,
    String? rewardId,
    String? redemptionId,
    String? cancellationReason,
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

    // Active UI family match pre-check (R24-3-03, R24-4-05, R24-5-01)
    // Pre-claim family mismatch must return without mutating the journal or releasing other leases.
    if (_activeFamilyIdProvider != null) {
      final currentActiveFamily = _activeFamilyIdProvider();
      if (currentActiveFamily == null || currentActiveFamily != familyId) {
        return CommandFamilyMismatchResult(
          commandId: requestedCommandId ?? 'unassigned',
          commandFamilyId: familyId,
          activeFamilyId: currentActiveFamily,
        );
      }
    }

    final isAdultOp =
        operation == RewardCommandOperation.fulfillReward ||
        operation == RewardCommandOperation.cancelReward;

    PendingRewardCommand? existing;
    AdultTargetAuthorizationResult? adultAuth;

    if (requestedCommandId != null) {
      existing = await _commandStore.getPendingCommand(requestedCommandId);
      if (existing == null) {
        if (trigger == CommandExecutionTrigger.recovery ||
            trigger == CommandExecutionTrigger.foregroundRetry) {
          return CommandQuarantinedResult(
            commandId: requestedCommandId,
            reason:
                'Pending command not found for requested retry ID: $requestedCommandId',
          );
        }
      }
    }

    if (isAdultOp) {
      // Step 0 for adult operations: check existing row first if requested
      if (existing != null) {
        if (existing.dispatchState == CommandDispatchState.unknownLegacy ||
            existing.recoveryState ==
                CommandRecoveryState.quarantinedUnknownOutcome ||
            existing.recoveryState == CommandRecoveryState.terminalError) {
          return CommandQuarantinedResult(
            commandId: existing.commandId,
            reason:
                'Command is quarantined or legacy unknown: recovery=${existing.recoveryState.wireValue}, dispatch=${existing.dispatchState.wireValue}',
          );
        }

        // Actor mismatch check (R24-3-02)
        if (existing.actorUserId != null &&
            existing.actorUserId!.isNotEmpty &&
            existing.actorUserId != context.userId) {
          if (trigger == CommandExecutionTrigger.recovery) {
            await _commandStore.pauseMismatchedActorCommand(
              commandId: existing.commandId,
              familyId: existing.familyId,
              authenticatedActorId: context.userId,
              mismatchReason: 'Signed in as different user',
              now: now,
            );
          }
          return CommandPendingOriginalActorResult(
            commandId: existing.commandId,
            originalActorId: existing.actorUserId!,
            reason: 'Actor mismatch with authenticated session',
          );
        }

        // Completeness gate (A2-19)
        final bool isComplete =
            existing.actorUserId != null &&
            existing.actorUserId!.isNotEmpty &&
            existing.childId != null &&
            existing.childId!.isNotEmpty &&
            existing.redemptionId != null &&
            existing.redemptionId!.isNotEmpty &&
            (existing.actorRole == 'owner' || existing.actorRole == 'parent');

        if (!isComplete) {
          return CommandQuarantinedResult(
            commandId: existing.commandId,
            reason: 'Incomplete or legacy command identity',
          );
        }

        if (operation == RewardCommandOperation.cancelReward &&
            (existing.cancellationReason == null ||
                existing.cancellationReason!.trim().length < 2)) {
          return CommandQuarantinedResult(
            commandId: existing.commandId,
            reason: 'Incomplete or legacy command identity: cancellation reason is required',
          );
        }

        if (operation == RewardCommandOperation.fulfillReward &&
            existing.cancellationReason != null) {
          return CommandQuarantinedResult(
            commandId: existing.commandId,
            reason: 'Incomplete or legacy command identity: fulfill command must not have cancellation reason',
          );
        }

        // Target match check
        final cleanRequestedReason = cancellationReason?.trim();
        final matchesTarget =
            existing.operation == operation &&
            existing.familyId == familyId &&
            existing.childId == childId &&
            existing.redemptionId == redemptionId &&
            (operation != RewardCommandOperation.cancelReward ||
                existing.cancellationReason == cleanRequestedReason);

        if (!matchesTarget) {
          return CommandQuarantinedResult(
            commandId: existing.commandId,
            reason:
                'Mismatched command payload for existing command ID ${existing.commandId}.',
          );
        }

        // Recovery schedule check
        if (trigger == CommandExecutionTrigger.recovery &&
            existing.nextAttemptAt != null &&
            existing.nextAttemptAt!.isAfter(now)) {
          return CommandScheduledResult(
            commandId: existing.commandId,
            nextAttemptAt: existing.nextAttemptAt!,
            retryCount: existing.retryCount,
          );
        }
      }

      // Verify adult redemption target
      adultAuth = await _authorizationPort.verifyAdultRedemptionTarget(
        context: context,
        familyId: familyId,
        childId: childId,
        redemptionId: redemptionId ?? '',
        operation: operation,
      );

      // Verified role consistency check on existing row
      if (existing != null &&
          adultAuth.status == TargetAuthorizationStatus.authorized) {
        if (adultAuth.verifiedRole!.wireValue != existing.actorRole) {
          adultAuth = const AdultTargetAuthorizationResult.definitelyDenied(
            reason: AdultTargetVerificationReason.inconsistentRoleClaim,
          );
        }
      }

      if (adultAuth.status == TargetAuthorizationStatus.definitelyDenied ||
          adultAuth.status == TargetAuthorizationStatus.confirmedRevoked) {
        final denialReason =
            adultAuth.reason ==
                AdultTargetVerificationReason.childConfirmedArchived
            ? 'Target child profile is confirmed archived.'
            : adultAuth.status == TargetAuthorizationStatus.confirmedRevoked
            ? 'Device grant confirmed revoked prior to execution.'
            : 'Target adult authorization definitively denied (${adultAuth.reason.name}).';

        if (existing != null &&
            existing.recoveryState == CommandRecoveryState.active) {
          final claimToken = await _commandStore.acquireClaim(
            commandId: existing.commandId,
            actorUserId: context.userId,
            leaseDuration: const Duration(seconds: 10),
            now: now,
          );
          if (claimToken == null) {
            return CommandAlreadyInFlightResult(commandId: existing.commandId);
          }
          final transitioned = await _commandStore.transitionRecoveryState(
            commandId: existing.commandId,
            leaseToken: claimToken,
            newState: CommandRecoveryState.quarantinedUnknownOutcome,
            lastErrorMessage: denialReason,
          );
          if (!transitioned) {
            return CommandAlreadyInFlightResult(commandId: existing.commandId);
          }
        }

        return CommandQuarantinedResult(
          commandId: requestedCommandId ?? 'unassigned',
          reason: denialReason,
        );
      }

      if (adultAuth.status == TargetAuthorizationStatus.unverified) {
        if (requestedCommandId == null) {
          return const CommandAuthUnavailableResult(
            reason: 'Target authorization could not be verified.',
          );
        }

        if (existing != null) {
          if (existing.recoveryState != CommandRecoveryState.active) {
            return CommandQuarantinedResult(
              commandId: existing.commandId,
              reason: 'Command is not active',
            );
          }

          final claimToken = await _commandStore.acquireClaim(
            commandId: existing.commandId,
            actorUserId: context.userId,
            leaseDuration: const Duration(seconds: 10),
            now: now,
          );
          if (claimToken == null) {
            final latest = await _commandStore.getPendingCommand(
              existing.commandId,
            );
            if (latest != null &&
                latest.nextAttemptAt != null &&
                latest.nextAttemptAt!.isAfter(now)) {
              return CommandScheduledResult(
                commandId: existing.commandId,
                nextAttemptAt: latest.nextAttemptAt!,
                retryCount: latest.retryCount,
                errorMessage: latest.lastErrorMessage,
              );
            }
            return CommandAlreadyInFlightResult(commandId: existing.commandId);
          }

          final latest = await _commandStore.getPendingCommand(
            existing.commandId,
          );
          if (latest == null || latest.leaseToken != claimToken) {
            return CommandAlreadyInFlightResult(commandId: existing.commandId);
          }

          final nextGlobalRetry = latest.retryCount + 1;
          final backoffDuration = _calculateBackoff(
            nextGlobalRetry,
            minFloorSeconds: 5.0,
          );
          final nextAttemptAt = now.add(backoffDuration);

          if (adultAuth.reason ==
                  AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow ||
              adultAuth.reason ==
                  AdultTargetVerificationReason.missingOrUnverifiedMembership) {
            final nextMissCount = latest.consecutiveUnverifiedTargetMisses + 1;
            if (nextMissCount >= maxConsecutiveUnverifiedTargetMisses) {
              final quarantineReason =
                  PendingRewardCommand.formatUnverifiedTargetMissMessage(
                    consecutiveMisses: nextMissCount,
                    detail:
                        'Target remained unverified (missing or RLS-filtered row, no positive archive proof) after $maxConsecutiveUnverifiedTargetMisses consecutive verification misses; quarantined for manual review.',
                  );
              final transitioned = await _commandStore.transitionRecoveryState(
                commandId: existing.commandId,
                leaseToken: claimToken,
                newState: CommandRecoveryState.quarantinedUnknownOutcome,
                lastErrorMessage: quarantineReason,
              );
              if (!transitioned) {
                return CommandAlreadyInFlightResult(
                  commandId: existing.commandId,
                );
              }
              return CommandQuarantinedResult(
                commandId: existing.commandId,
                reason: quarantineReason,
              );
            } else {
              final missMessage =
                  PendingRewardCommand.formatUnverifiedTargetMissMessage(
                    consecutiveMisses: nextMissCount,
                    detail:
                        'Target row unverified (missing or RLS-filtered, no positive archive proof); consecutive miss $nextMissCount/$maxConsecutiveUnverifiedTargetMisses.',
                  );
              final released = await _commandStore.releaseClaim(
                commandId: existing.commandId,
                leaseToken: claimToken,
                nextAttemptAt: nextAttemptAt,
                lastErrorMessage: missMessage,
              );
              if (!released) {
                return CommandAlreadyInFlightResult(
                  commandId: existing.commandId,
                );
              }
              return CommandScheduledResult(
                commandId: existing.commandId,
                nextAttemptAt: nextAttemptAt,
                retryCount: nextGlobalRetry,
                errorMessage: missMessage,
              );
            }
          } else {
            // Transient verification failure
            const failureMessage =
                'Temporary target verification failure (network/timeout); retry scheduled.';
            final released = await _commandStore.releaseClaim(
              commandId: existing.commandId,
              leaseToken: claimToken,
              nextAttemptAt: nextAttemptAt,
              lastErrorMessage: failureMessage,
            );
            if (!released) {
              return CommandAlreadyInFlightResult(
                commandId: existing.commandId,
              );
            }
            return const CommandAuthUnavailableResult(reason: failureMessage);
          }
        }
      }
    } else {
      // Step 0 for child operations (spin_wheel, redeem_reward)
      final authStatus = await _authorizationPort.verifyTarget(
        context: context,
        familyId: familyId,
        childId: childId,
        operation: operation,
      );

      if (authStatus == TargetAuthorizationStatus.definitelyDenied ||
          authStatus == TargetAuthorizationStatus.confirmedRevoked) {
        final denialReason =
            authStatus == TargetAuthorizationStatus.confirmedRevoked
            ? 'Device grant confirmed revoked prior to execution.'
            : 'Target family/child authorization definitively denied.';

        if (requestedCommandId != null) {
          final existingChild = await _commandStore.getPendingCommand(
            requestedCommandId,
          );
          if (existingChild != null &&
              existingChild.recoveryState == CommandRecoveryState.active) {
            final claimToken = await _commandStore.acquireClaim(
              commandId: existingChild.commandId,
              actorUserId: context.userId,
              leaseDuration: const Duration(seconds: 10),
              now: now,
            );
            if (claimToken == null) {
              return CommandAlreadyInFlightResult(
                commandId: existingChild.commandId,
              );
            }
            final transitioned = await _commandStore.transitionRecoveryState(
              commandId: existingChild.commandId,
              leaseToken: claimToken,
              newState: CommandRecoveryState.quarantinedUnknownOutcome,
              lastErrorMessage: denialReason,
            );
            if (!transitioned) {
              return CommandAlreadyInFlightResult(
                commandId: existingChild.commandId,
              );
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
    }

    // STEP 1 — SELECT IDENTITY: Find exact existing command or create new
    PendingRewardCommand? command;

    if (existing != null) {
      command = existing;

      final cleanRequestedReason = cancellationReason?.trim();
      final matchesTarget =
          command.operation == operation &&
          command.familyId == familyId &&
          command.childId == childId &&
          (operation != RewardCommandOperation.redeemReward ||
              command.rewardId == rewardId) &&
          ((operation != RewardCommandOperation.fulfillReward &&
                  operation != RewardCommandOperation.cancelReward) ||
              command.redemptionId == redemptionId) &&
          (operation != RewardCommandOperation.cancelReward ||
              command.cancellationReason == cleanRequestedReason);

      if (!matchesTarget) {
        return CommandQuarantinedResult(
          commandId: command.commandId,
          reason:
              'Mismatched command payload for existing command ID ${command.commandId}.',
        );
      }

      // Safe Manual Resume for Original Adult (R29-02)
      if (isAdultOp &&
          command.recoveryState == CommandRecoveryState.pendingOriginalActor) {
        if (trigger == CommandExecutionTrigger.foregroundRetry) {
          // Re-verify session generation and active family before atomic resume
          if (_authSessionPort.currentSessionGeneration !=
              context.sessionGeneration) {
            return const CommandAuthUnavailableResult(
              reason: 'Session epoch changed prior to manual resumption.',
            );
          }
          if (_activeFamilyIdProvider != null) {
            final currentActiveFamily = _activeFamilyIdProvider();
            if (currentActiveFamily == null ||
                currentActiveFamily != command.familyId) {
              return CommandFamilyMismatchResult(
                commandId: command.commandId,
                commandFamilyId: command.familyId,
                activeFamilyId: currentActiveFamily,
              );
            }
          }

          final resumed = await _commandStore.resumeOriginalActorCommand(
            commandId: command.commandId,
            familyId: command.familyId,
            authenticatedActorId: context.userId,
            now: now,
          );

          if (resumed) {
            final refreshed = await _commandStore.getPendingCommand(
              command.commandId,
            );
            if (refreshed == null) {
              return CommandQuarantinedResult(
                commandId: command.commandId,
                reason: 'Pending command missing after manual resumption.',
              );
            }
            command = refreshed;
            existing = refreshed;
          } else {
            final latest = await _commandStore.getPendingCommand(
              command.commandId,
            );
            if (latest == null) {
              return CommandQuarantinedResult(
                commandId: command.commandId,
                reason: 'Pending command missing during manual resumption.',
              );
            }
            if (latest.recoveryState == CommandRecoveryState.active) {
              command = latest;
              existing = latest;
            } else if (latest.recoveryState ==
                    CommandRecoveryState.quarantinedUnknownOutcome ||
                latest.recoveryState == CommandRecoveryState.terminalError) {
              return CommandQuarantinedResult(
                commandId: command.commandId,
                reason:
                    'Command transitioned to quarantined or terminal state.',
              );
            } else if (latest.actorUserId != context.userId) {
              return CommandPendingOriginalActorResult(
                commandId: command.commandId,
                originalActorId: latest.actorUserId ?? '',
                reason: 'Actor mismatch with authenticated session',
              );
            } else {
              // Active lease contention or unfulfilled CAS condition
              return CommandAlreadyInFlightResult(commandId: command.commandId);
            }
          }
        } else {
          return CommandPendingOriginalActorResult(
            commandId: command.commandId,
            originalActorId: command.actorUserId ?? '',
            reason: 'Command is paused pending original actor confirmation.',
          );
        }
      }
    } else {
      if (trigger == CommandExecutionTrigger.recovery ||
          trigger == CommandExecutionTrigger.foregroundRetry) {
        return const CommandAuthUnavailableResult(
          reason: 'Missing explicit retry ID for recovery dispatch.',
        );
      }

      String? cleanReason;
      if (operation == RewardCommandOperation.cancelReward) {
        cleanReason = cancellationReason?.trim() ?? '';
        if (cleanReason.length < 2) {
          return const CommandQuarantinedResult(
            commandId: 'unassigned',
            reason: 'Cancellation reason must be at least 2 characters.',
          );
        }
      }

      final newCommandId = requestedCommandId ?? _generateUuid();
      final String? actorRole = isAdultOp
          ? adultAuth!.verifiedRole!.wireValue
          : context.role;

      final freshCmd = PendingRewardCommand(
        operation: operation,
        commandId: newCommandId,
        familyId: familyId,
        childId: childId,
        rewardId: rewardId,
        redemptionId: redemptionId,
        cancellationReason: operation == RewardCommandOperation.cancelReward
            ? cleanReason
            : null,
        createdAt: now,
        actorUserId: context.userId,
        actorRole: actorRole,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );

      final regResult = await _commandStore.registerFreshCommand(
        command: freshCmd,
        now: now,
      );

      switch (regResult) {
        case FreshCommandRegistered(command: final newlyCreated):
          command = newlyCreated;
        case PreexistingCommandFound(existingCommand: final preexisting):
          return CommandAlreadyInFlightResult(commandId: preexisting.commandId);
      }
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

    if (command.recoveryState == CommandRecoveryState.pendingOriginalActor) {
      return CommandPendingOriginalActorResult(
        commandId: command.commandId,
        originalActorId: command.actorUserId ?? '',
        reason: 'Command is paused pending original actor confirmation.',
      );
    }

    // Check actor match (R24-3-02)
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

    // Active family check on loaded command (R24-3-03, R24-4-05)
    if (_activeFamilyIdProvider != null) {
      final currentActive = _activeFamilyIdProvider();
      if (currentActive == null || currentActive != command.familyId) {
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

    // STEP 2 — ATOMICALLY ACQUIRE EXCLUSIVE CLAIM LEASE (R24-4-02, R24-5-02)
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

    // STEP 3 — REVALIDATE AUTH/AUTHORIZATION AFTER CLAIM
    if (_authSessionPort.currentSessionGeneration !=
        context.sessionGeneration) {
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
    if (command.dispatchState != CommandDispatchState.confirmedCommitted) {
      final markSuccess = await _commandStore.markPossiblyDispatched(
        commandId: command.commandId,
        leaseToken: leaseToken,
        authenticatedActorId: context.userId,
        now: _clock.now().toUtc(),
      );

      if (!markSuccess) {
        return CommandAlreadyInFlightResult(commandId: command.commandId);
      }
    }

    // STEP 5 — FINAL LIVE AUTH & TARGET & FAMILY GATE IMMEDIATELY BEFORE RPC (W5 / M02, R24-3-03)
    final freshContext = await _authSessionPort.validateForMutation();
    if (freshContext == null ||
        freshContext.userId != context.userId ||
        _authSessionPort.currentSessionGeneration !=
            context.sessionGeneration) {
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

    if (_activeFamilyIdProvider != null) {
      final currentActive = _activeFamilyIdProvider();
      if (currentActive == null || currentActive != command.familyId) {
        await _commandStore.releaseClaim(
          commandId: command.commandId,
          leaseToken: leaseToken,
          nextAttemptAt: _clock.now().toUtc(),
          lastErrorMessage: currentActive == null
              ? 'Active family selection cleared prior to remote RPC.'
              : 'Active family changed to $currentActive prior to remote RPC.',
        );
        return CommandFamilyMismatchResult(
          commandId: command.commandId,
          commandFamilyId: command.familyId,
          activeFamilyId: currentActive,
        );
      }
    }

    if (isAdultOp) {
      final freshAdultAuth = await _authorizationPort
          .verifyAdultRedemptionTarget(
            context: freshContext,
            familyId: command.familyId,
            childId: command.childId!,
            redemptionId: command.redemptionId!,
            operation: command.operation,
          );

      if (freshAdultAuth.status == TargetAuthorizationStatus.authorized) {
        if (freshAdultAuth.verifiedRole!.wireValue != command.actorRole) {
          await _commandStore.transitionRecoveryState(
            commandId: command.commandId,
            leaseToken: leaseToken,
            newState: CommandRecoveryState.quarantinedUnknownOutcome,
            lastErrorMessage: 'Actor membership role changed from stored role.',
          );
          return CommandQuarantinedResult(
            commandId: command.commandId,
            reason: 'Actor membership role changed from stored role.',
          );
        }
      } else if (freshAdultAuth.status ==
              TargetAuthorizationStatus.definitelyDenied ||
          freshAdultAuth.status == TargetAuthorizationStatus.confirmedRevoked) {
        final reason =
            freshAdultAuth.reason ==
                AdultTargetVerificationReason.childConfirmedArchived
            ? 'Target child profile is confirmed archived.'
            : 'Target adult authorization definitely denied prior to RPC.';

        final transitioned = await _commandStore.transitionRecoveryState(
          commandId: command.commandId,
          leaseToken: leaseToken,
          newState: CommandRecoveryState.quarantinedUnknownOutcome,
          lastErrorMessage: reason,
        );
        if (!transitioned) {
          return CommandAlreadyInFlightResult(commandId: command.commandId);
        }
        return CommandQuarantinedResult(
          commandId: command.commandId,
          reason: reason,
        );
      } else if (freshAdultAuth.status ==
          TargetAuthorizationStatus.unverified) {
        final latest = await _commandStore.getPendingCommand(command.commandId);
        if (latest == null || latest.leaseToken != leaseToken) {
          return CommandAlreadyInFlightResult(commandId: command.commandId);
        }

        final nextGlobalRetry = latest.retryCount + 1;
        final backoffDuration = _calculateBackoff(
          nextGlobalRetry,
          minFloorSeconds: 5.0,
        );
        final nextAttemptAt = _clock.now().toUtc().add(backoffDuration);

        if (freshAdultAuth.reason ==
                AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow ||
            freshAdultAuth.reason ==
                AdultTargetVerificationReason.missingOrUnverifiedMembership) {
          final nextMissCount = latest.consecutiveUnverifiedTargetMisses + 1;
          if (nextMissCount >= maxConsecutiveUnverifiedTargetMisses) {
            final quarantineReason =
                PendingRewardCommand.formatUnverifiedTargetMissMessage(
                  consecutiveMisses: nextMissCount,
                  detail:
                      'Target remained unverified (missing or RLS-filtered row, no positive archive proof) after $maxConsecutiveUnverifiedTargetMisses consecutive verification misses; quarantined for manual review.',
                );
            final transitioned = await _commandStore.transitionRecoveryState(
              commandId: command.commandId,
              leaseToken: leaseToken,
              newState: CommandRecoveryState.quarantinedUnknownOutcome,
              lastErrorMessage: quarantineReason,
            );
            if (!transitioned) {
              return CommandAlreadyInFlightResult(commandId: command.commandId);
            }
            return CommandQuarantinedResult(
              commandId: command.commandId,
              reason: quarantineReason,
            );
          } else {
            final missMessage =
                PendingRewardCommand.formatUnverifiedTargetMissMessage(
                  consecutiveMisses: nextMissCount,
                  detail:
                      'Target row unverified (missing or RLS-filtered, no positive archive proof); consecutive miss $nextMissCount/$maxConsecutiveUnverifiedTargetMisses.',
                );
            final released = await _commandStore.releaseClaim(
              commandId: command.commandId,
              leaseToken: leaseToken,
              nextAttemptAt: nextAttemptAt,
              lastErrorMessage: missMessage,
            );
            if (!released) {
              return CommandAlreadyInFlightResult(commandId: command.commandId);
            }
            return CommandScheduledResult(
              commandId: command.commandId,
              nextAttemptAt: nextAttemptAt,
              retryCount: nextGlobalRetry,
              errorMessage: missMessage,
            );
          }
        } else {
          // Transient verification failure
          const failureMessage =
              'Temporary target verification failure (network/timeout); retry scheduled.';
          final released = await _commandStore.releaseClaim(
            commandId: command.commandId,
            leaseToken: leaseToken,
            nextAttemptAt: nextAttemptAt,
            lastErrorMessage: failureMessage,
          );
          if (!released) {
            return CommandAlreadyInFlightResult(commandId: command.commandId);
          }
          return const CommandAuthUnavailableResult(reason: failureMessage);
        }
      }
    } else {
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
          return CommandAlreadyInFlightResult(commandId: command.commandId);
        }
        return CommandQuarantinedResult(
          commandId: command.commandId,
          reason: reason,
        );
      }

      if (freshAuth == TargetAuthorizationStatus.unverified) {
        await _commandStore.releaseClaim(
          commandId: command.commandId,
          leaseToken: leaseToken,
          nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 5)),
          lastErrorMessage: 'Target authorization unverified immediately prior to remote RPC.',
        );
        return const CommandAuthUnavailableResult(
          reason: 'Target authorization unverified immediately prior to remote RPC.',
        );
      }
    }

    // STEP 6 — AUTHORITATIVE REMOTE RPC EXECUTION
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

        final postRpcContext = await _authSessionPort.validateForMutation();
        if (postRpcContext == null ||
            postRpcContext.userId != context.userId ||
            _authSessionPort.currentSessionGeneration !=
                context.sessionGeneration) {
          await _commandStore.releaseClaim(
            commandId: command.commandId,
            leaseToken: leaseToken,
            nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 1)),
            lastErrorMessage:
                'Session invalidated or actor logged out while RPC in-flight.',
          );
          return const CommandAuthUnavailableResult(
            reason:
                'Session invalidated or actor logged out while RPC in-flight.',
          );
        }

        final completed = await _commandStore.completeCommand(
          commandId: command.commandId,
          leaseToken: leaseToken,
        );

        if (!completed) {
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

        final postRpcContext = await _authSessionPort.validateForMutation();
        if (postRpcContext == null ||
            postRpcContext.userId != context.userId ||
            _authSessionPort.currentSessionGeneration !=
                context.sessionGeneration) {
          await _commandStore.releaseClaim(
            commandId: command.commandId,
            leaseToken: leaseToken,
            nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 1)),
            lastErrorMessage:
                'Session invalidated or actor logged out while RPC in-flight.',
          );
          return const CommandAuthUnavailableResult(
            reason:
                'Session invalidated or actor logged out while RPC in-flight.',
          );
        }

        final completed = await _commandStore.completeCommand(
          commandId: command.commandId,
          leaseToken: leaseToken,
        );

        if (!completed) {
          return CommandAlreadyInFlightResult(commandId: command.commandId);
        }

        return CommandCommittedResult(
          commandId: command.commandId,
          redemption: result,
        );
      } else if (command.operation == RewardCommandOperation.fulfillReward) {
        final rewardRepo = _rewardRepository;
        if (rewardRepo == null) {
          throw StateError(
            'RewardRepository not provided to RecoveryCoordinator',
          );
        }

        final result = await rewardRepo.fulfillRewardRedemption(
          commandId: command.commandId,
          redemptionId: RewardRedemptionId(command.redemptionId!),
        );

        final postRpcContext = await _authSessionPort.validateForMutation();
        if (postRpcContext == null ||
            postRpcContext.userId != context.userId ||
            _authSessionPort.currentSessionGeneration !=
                context.sessionGeneration) {
          await _commandStore.releaseClaim(
            commandId: command.commandId,
            leaseToken: leaseToken,
            nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 1)),
            lastErrorMessage:
                'Session invalidated or actor logged out while RPC in-flight.',
          );
          return const CommandAuthUnavailableResult(
            reason:
                'Session invalidated or actor logged out while RPC in-flight.',
          );
        }

        final completed = await _commandStore.completeCommand(
          commandId: command.commandId,
          leaseToken: leaseToken,
        );

        if (!completed) {
          return CommandAlreadyInFlightResult(commandId: command.commandId);
        }

        return CommandCommittedResult(
          commandId: command.commandId,
          redemption: result,
        );
      } else if (command.operation == RewardCommandOperation.cancelReward) {
        final rewardRepo = _rewardRepository;
        if (rewardRepo == null) {
          throw StateError(
            'RewardRepository not provided to RecoveryCoordinator',
          );
        }

        final result = await rewardRepo.cancelRewardRedemption(
          commandId: command.commandId,
          redemptionId: RewardRedemptionId(command.redemptionId!),
          cancellationReason: command.cancellationReason!,
        );

        final postRpcContext = await _authSessionPort.validateForMutation();
        if (postRpcContext == null ||
            postRpcContext.userId != context.userId ||
            _authSessionPort.currentSessionGeneration !=
                context.sessionGeneration) {
          await _commandStore.releaseClaim(
            commandId: command.commandId,
            leaseToken: leaseToken,
            nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 1)),
            lastErrorMessage:
                'Session invalidated or actor logged out while RPC in-flight.',
          );
          return const CommandAuthUnavailableResult(
            reason:
                'Session invalidated or actor logged out while RPC in-flight.',
          );
        }

        final completed = await _commandStore.completeCommand(
          commandId: command.commandId,
          leaseToken: leaseToken,
        );

        if (!completed) {
          return CommandAlreadyInFlightResult(commandId: command.commandId);
        }

        return CommandCommittedResult(
          commandId: command.commandId,
          redemption: result,
        );
      } else {
        throw UnsupportedError(
          'Operation ${command.operation} is out of scope',
        );
      }
    } catch (e) {
      final postRpcContext = await _authSessionPort.validateForMutation();
      if (postRpcContext == null ||
          postRpcContext.userId != context.userId ||
          _authSessionPort.currentSessionGeneration !=
              context.sessionGeneration) {
        await _commandStore.releaseClaim(
          commandId: command.commandId,
          leaseToken: leaseToken,
          nextAttemptAt: _clock.now().toUtc().add(const Duration(seconds: 1)),
          lastErrorMessage:
              'Session invalidated or actor logged out while RPC in-flight.',
        );
        return const CommandAuthUnavailableResult(
          reason:
              'Session invalidated or actor logged out while RPC in-flight.',
        );
      }

      // STEP 7B — ERROR DISPOSITION UNDER CURRENT LEASE
      final classified = RecoveryErrorClassifier.classify(
        e,
        operation: command.operation,
      );

      switch (classified.action) {
        case ClassifiedErrorAction.terminalWhitelisted:
          final completed = await _commandStore.completeCommand(
            commandId: command.commandId,
            leaseToken: leaseToken,
          );

          if (!completed) {
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
          final transitioned = await _commandStore.transitionRecoveryState(
            commandId: command.commandId,
            leaseToken: leaseToken,
            newState: CommandRecoveryState.quarantinedUnknownOutcome,
            lastErrorMessage: classified.sanitizedMessage,
          );

          if (!transitioned) {
            return CommandAlreadyInFlightResult(commandId: command.commandId);
          }

          return CommandQuarantinedResult(
            commandId: command.commandId,
            reason: classified.sanitizedMessage,
            originalError: e,
          );

        case ClassifiedErrorAction.transientRetryable:
          final postFailureNow = _clock.now().toUtc();
          final latestRow = await _commandStore.getPendingCommand(
            command.commandId,
          );
          final currentRetry = latestRow?.retryCount ?? command.retryCount;
          final n = currentRetry + 1;
          final backoff = _calculateBackoff(n, minFloorSeconds: 1.0);
          final nextAttemptAt = postFailureNow.add(backoff);

          final released = await _commandStore.releaseClaim(
            commandId: command.commandId,
            leaseToken: leaseToken,
            nextAttemptAt: nextAttemptAt,
            lastErrorMessage: classified.sanitizedMessage,
          );

          if (!released) {
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
