// ignore_for_file: prefer_initializing_formals

import 'package:learnward_domain/learnward_domain.dart';

import '../ports/auth_session_port.dart';
import '../ports/clock.dart';
import '../ports/pending_reward_command_store.dart';
import '../ports/recovery_authorization_port.dart';
import '../ports/reward_repository.dart';
import '../services/jitter_source.dart';
import '../services/recovery_coordinator.dart';

final class RedeemStoreReward {
  RedeemStoreReward(
    this._repository,
    this._commandStore, {
    this.uuidGenerator,
    AuthSessionPort? authSessionPort,
    RecoveryAuthorizationPort? authorizationPort,
    Clock? clock,
    JitterSource? jitterSource,
    RecoveryCoordinator? coordinator,
  }) : _authSessionPort = authSessionPort,
       _authorizationPort = authorizationPort,
       _clock = clock ?? const SystemClock(),
       _jitterSource = jitterSource ?? const DeterministicJitterSource(),
       _coordinator = coordinator;

  final RewardRepository _repository;
  final PendingRewardCommandStore _commandStore;
  final String Function()? uuidGenerator;
  final AuthSessionPort? _authSessionPort;
  final RecoveryAuthorizationPort? _authorizationPort;
  final Clock _clock;
  final JitterSource _jitterSource;
  final RecoveryCoordinator? _coordinator;

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
      recoveryState: null,
    );

    if (existing != null) {
      final canReplayExisting =
          actorUserId != null &&
          actorUserId.isNotEmpty &&
          existing.actorUserId != null &&
          existing.actorUserId == actorUserId &&
          existing.canAutoReplay;

      if (!canReplayExisting) {
        throw StateError(
          'Cannot dispatch reward command: an unresolved pending command exists '
          '(id: ${existing.commandId}, recoveryState: ${existing.recoveryState.wireValue}, '
          'dispatchState: ${existing.dispatchState.wireValue}) that is ineligible for automatic replay. '
          'Reconciliation is required.',
        );
      }
    } else {
      if (actorUserId == null || actorUserId.isEmpty) {
        throw StateError(
          'Cannot dispatch reward command: authenticated actor identity is required but was missing or empty.',
        );
      }
    }

    final effectiveAuthPort =
        _authSessionPort ??
        _DirectActorSessionPort(
          actorUserId: actorUserId,
          role: actorRole,
          clock: _clock,
        );

    final effectiveAuthzPort =
        _authorizationPort ?? const _PermissiveAuthorizationPort();

    final coordinator =
        _coordinator ??
        RecoveryCoordinator(
          commandStore: _commandStore,
          rewardRepository: _repository,
          authSessionPort: effectiveAuthPort,
          authorizationPort: effectiveAuthzPort,
          clock: _clock,
          jitterSource: _jitterSource,
          uuidGenerator: uuidGenerator,
        );

    final result = await coordinator.execute(
      operation: RewardCommandOperation.redeemReward,
      familyId: familyId.value,
      childId: childId.value,
      rewardId: rewardId.value,
      requestedCommandId: commandId,
      trigger: CommandExecutionTrigger.foreground,
    );

    return switch (result) {
      CommandCommittedResult(redemption: final res) => res!,
      CommandTerminalRejectionResult(
        originalError: final err,
        errorMessage: final msg,
      ) =>
        err != null ? throw err : throw StateError(msg),
      CommandScheduledResult(
        originalError: final err,
        errorMessage: final msg,
      ) =>
        err != null
            ? throw err
            : throw StateError(msg ?? 'Scheduled for retry'),
      CommandPendingOriginalActorResult(
        originalError: final err,
        reason: final r,
      ) =>
        err != null ? throw err : throw StateError('Cannot replay: $r'),
      CommandQuarantinedResult(originalError: final err, reason: final r) =>
        err != null ? throw err : throw StateError('Cannot replay: $r'),
      CommandAlreadyInFlightResult(commandId: final id) => throw StateError(
        'Command $id is already in flight',
      ),
      CommandAuthUnavailableResult(reason: final r) => throw StateError(r),
    };
  }
}

final class _DirectActorSessionPort implements AuthSessionPort {
  const _DirectActorSessionPort({
    required this.actorUserId,
    this.role,
    required this.clock,
  });

  final String? actorUserId;
  final String? role;
  final Clock clock;

  @override
  String? get currentSessionGeneration =>
      actorUserId != null ? 'gen-$actorUserId' : null;

  @override
  Stream<String?> get sessionGenerationStream =>
      Stream.value(currentSessionGeneration);

  @override
  Future<ValidatedActorContext?> validateForMutation() async {
    if (actorUserId == null || actorUserId!.isEmpty) return null;
    return ValidatedActorContext(
      userId: actorUserId!,
      sessionGeneration: currentSessionGeneration!,
      observedAt: clock.now().toUtc(),
      role: role,
    );
  }
}

final class _PermissiveAuthorizationPort implements RecoveryAuthorizationPort {
  const _PermissiveAuthorizationPort();

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) async {
    return TargetAuthorizationStatus.authorized;
  }
}
