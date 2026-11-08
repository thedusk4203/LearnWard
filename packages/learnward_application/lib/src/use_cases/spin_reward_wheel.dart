// ignore_for_file: prefer_initializing_formals

import 'package:learnward_domain/learnward_domain.dart';

import '../ports/auth_session_port.dart';
import '../ports/clock.dart';
import '../ports/pending_reward_command_store.dart';
import '../ports/recovery_authorization_port.dart';
import '../ports/wheel_repository.dart';
import '../services/jitter_source.dart';
import '../services/recovery_coordinator.dart';

/// Server-authoritative use-case for spinning the Celebration Wheel with durable journaling.
final class SpinRewardWheel {
  SpinRewardWheel(
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
       _jitterSource = jitterSource ?? const RandomJitterSource(),
       _coordinator = coordinator {
    if (_coordinator == null &&
        (_authSessionPort == null || _authorizationPort == null)) {
      throw ArgumentError(
        'SpinRewardWheel requires either an explicit RecoveryCoordinator or both '
        'trusted AuthSessionPort and RecoveryAuthorizationPort.',
      );
    }
  }

  final WheelRepository _repository;
  final PendingRewardCommandStore _commandStore;
  final String Function()? uuidGenerator;
  final AuthSessionPort? _authSessionPort;
  final RecoveryAuthorizationPort? _authorizationPort;
  final Clock _clock;
  final JitterSource _jitterSource;
  final RecoveryCoordinator? _coordinator;

  Future<WheelSpinResult> call({
    required FamilyId familyId,
    required ChildId childId,
    String? commandId,
    @Deprecated('Actor identity must be obtained from trusted AuthSessionPort')
    String? actorUserId,
    @Deprecated('Actor role must be obtained from trusted AuthSessionPort')
    String? actorRole,
  }) async {
    final coordinator =
        _coordinator ??
        RecoveryCoordinator(
          commandStore: _commandStore,
          wheelRepository: _repository,
          authSessionPort: _authSessionPort!,
          authorizationPort: _authorizationPort!,
          clock: _clock,
          jitterSource: _jitterSource,
          uuidGenerator: uuidGenerator,
        );

    final result = await coordinator.execute(
      operation: RewardCommandOperation.spinWheel,
      familyId: familyId.value,
      childId: childId.value,
      requestedCommandId: commandId,
      trigger: CommandExecutionTrigger.foreground,
    );

    return switch (result) {
      CommandCommittedResult(wheelResult: final res) =>
        res ?? (throw StateError('Command committed without domain result')),
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
      CommandFamilyMismatchResult(
        commandFamilyId: final cf,
        activeFamilyId: final af,
      ) =>
        throw StateError(
          'Command belongs to family $cf but active family is $af',
        ),
      CommandAuthUnavailableResult(reason: final r) => throw StateError(r),
    };
  }
}
