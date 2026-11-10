import 'package:learnward_domain/learnward_domain.dart';

import '../ports/auth_session_port.dart';
import '../ports/clock.dart';
import '../ports/pending_reward_command_store.dart';
import '../ports/recovery_authorization_port.dart';
import '../ports/reward_repository.dart';
import '../services/jitter_source.dart';
import '../services/recovery_coordinator.dart';

final class CancelRewardRedemption {
  CancelRewardRedemption(
    this._repository,
    this._commandStore, {
    RecoveryCoordinator? coordinator,
    AuthSessionPort? authSessionPort,
    RecoveryAuthorizationPort? authorizationPort,
    Clock? clock,
    JitterSource? jitterSource,
    this.uuidGenerator,
  }) : _coordinator =
           coordinator ??
           RecoveryCoordinator(
             commandStore: _commandStore,
             rewardRepository: _repository,
             authSessionPort:
                 authSessionPort ?? const _DefaultAuthSessionPort(),
             authorizationPort:
                 authorizationPort ?? const _DefaultRecoveryAuthorizationPort(),
             clock: clock ?? const SystemClock(),
             jitterSource: jitterSource ?? const RandomJitterSource(),
             uuidGenerator: uuidGenerator,
           );

  final RewardRepository _repository;
  final PendingRewardCommandStore _commandStore;
  final RecoveryCoordinator _coordinator;
  final String Function()? uuidGenerator;

  /// Executes cancellation and returns the typed [CommandExecutionResult] for presentation state management.
  Future<CommandExecutionResult> executeResult({
    required FamilyId familyId,
    required RewardRedemptionId redemptionId,
    required ChildId childId,
    required String cancellationReason,
    String? commandId,
    CommandExecutionTrigger trigger = CommandExecutionTrigger.foreground,
  }) async {
    return _coordinator.execute(
      operation: RewardCommandOperation.cancelReward,
      familyId: familyId.value,
      childId: childId.value,
      redemptionId: redemptionId.value,
      cancellationReason: cancellationReason,
      requestedCommandId: commandId,
      trigger: trigger,
    );
  }

  /// Backward-compatible invocation unwrapping the committed [RewardRedemption]
  /// or throwing a typed exception.
  Future<RewardRedemption> call({
    required FamilyId familyId,
    required RewardRedemptionId redemptionId,
    required String cancellationReason,
    ChildId? childId,
    String? commandId,
  }) async {
    final existingPending = await _commandStore.findPendingRedemptionCommand(
      operation: RewardCommandOperation.cancelReward,
      redemptionId: redemptionId.value,
    );
    final resolvedCommandId = commandId ?? existingPending?.commandId;
    final resolvedReason =
        existingPending?.cancellationReason ?? cancellationReason;

    ChildId? resolvedChildId =
        childId ??
        (existingPending?.childId != null &&
                existingPending!.childId!.isNotEmpty
            ? ChildId(existingPending.childId!)
            : null);

    if (resolvedChildId == null && resolvedCommandId != null) {
      final existing = await _commandStore.getPendingCommand(resolvedCommandId);
      if (existing?.childId != null && existing!.childId!.isNotEmpty) {
        resolvedChildId = ChildId(existing.childId!);
      }
    }

    if (resolvedChildId == null) {
      try {
        final redemptions = await _repository.listRedemptions(
          familyId: familyId,
        );
        final match = redemptions
            .where((r) => r.id == redemptionId)
            .firstOrNull;
        if (match != null) {
          resolvedChildId = match.childId;
        }
      } catch (_) {}
    }

    if (resolvedChildId == null) {
      throw StateError(
        'Cannot resolve childId for redemption ${redemptionId.value}',
      );
    }

    final result = await executeResult(
      familyId: familyId,
      redemptionId: redemptionId,
      childId: resolvedChildId,
      cancellationReason: resolvedReason,
      commandId: resolvedCommandId,
    );

    if (result is CommandCommittedResult) {
      return result.redemption!;
    } else if (result is CommandAlreadyInFlightResult) {
      throw StateError(
        'Cancellation command ${result.commandId} is already in flight.',
      );
    } else if (result is CommandQuarantinedResult) {
      if (result.originalError != null) {
        throw result.originalError!;
      }
      throw StateError(result.reason);
    } else if (result is CommandScheduledResult) {
      if (result.originalError != null) {
        throw result.originalError!;
      }
      throw StateError(result.errorMessage ?? 'Command scheduled for retry.');
    } else if (result is CommandAuthUnavailableResult) {
      throw StateError(result.reason);
    } else if (result is CommandPendingOriginalActorResult) {
      throw StateError(result.reason);
    } else if (result is CommandFamilyMismatchResult) {
      throw StateError('Family mismatch during cancellation execution.');
    } else {
      throw StateError('Unexpected coordinator result: $result');
    }
  }
}

class _DefaultAuthSessionPort implements AuthSessionPort {
  const _DefaultAuthSessionPort();

  @override
  String? get currentSessionGeneration => '1';

  @override
  Stream<String?> get sessionGenerationStream => const Stream.empty();

  @override
  Future<ValidatedActorContext?> validateForMutation() async =>
      ValidatedActorContext(
        userId: 'default-test-adult-user',
        sessionGeneration: '1',
        observedAt: DateTime.now().toUtc(),
        role: 'parent',
      );
}

class _DefaultRecoveryAuthorizationPort implements RecoveryAuthorizationPort {
  const _DefaultRecoveryAuthorizationPort();

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) async => TargetAuthorizationStatus.authorized;

  @override
  Future<AdultTargetAuthorizationResult> verifyAdultRedemptionTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required String redemptionId,
    required RewardCommandOperation operation,
  }) async => const AdultTargetAuthorizationResult.authorized(
    verifiedRole: VerifiedAdultRole.parent,
  );
}
