// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import '../ports/auth_session_port.dart';
import '../ports/clock.dart';
import '../ports/pending_reward_command_store.dart';
import 'recovery_coordinator.dart';

/// App-active background dispatcher that drains eligible pending reward commands
/// under strict actor and family boundaries.
final class OutboxRecoveryDispatcher {
  OutboxRecoveryDispatcher({
    required PendingRewardCommandStore commandStore,
    required RecoveryCoordinator coordinator,
    required AuthSessionPort authSessionPort,
    String? Function()? activeFamilyIdProvider,
    Clock clock = const SystemClock(),
    this.maxConcurrentRpcs = 2,
    this.minimumDrainInterval = const Duration(seconds: 1),
  }) : _commandStore = commandStore,
       _coordinator = coordinator,
       _authSessionPort = authSessionPort,
       _activeFamilyIdProvider = activeFamilyIdProvider,
       _clock = clock;

  final PendingRewardCommandStore _commandStore;
  final RecoveryCoordinator _coordinator;
  final AuthSessionPort _authSessionPort;
  final String? Function()? _activeFamilyIdProvider;
  final Clock _clock;
  final int maxConcurrentRpcs;
  final Duration minimumDrainInterval;

  bool _isDraining = false;
  DateTime? _lastDrainCompletedAt;

  /// Whether a drain pass is currently in-flight.
  bool get isDraining => _isDraining;

  /// Drains eligible commands for the given [validatedContext] and [activeFamilyId].
  ///
  /// Guarantees:
  /// - At most one drain runs at a time for this dispatcher instance.
  /// - Enforces a scheduler flood guard of at least [minimumDrainInterval] between drain passes.
  /// - Mandatory trusted session validation using [_authSessionPort].
  /// - Only commands belonging to [activeFamilyId] are queried (no cross-family starvation).
  /// - Aborts immediately if the active UI family switches mid-drain.
  /// - Mismatched actor commands in this family are safely paused.
  /// - Returning original actor commands in this family are safely resumed.
  /// - At most [maxConcurrentRpcs] are executed concurrently (flood guard).
  Future<int> drainOnce({
    required ValidatedActorContext validatedContext,
    required String activeFamilyId,
    int limit = 10,
  }) async {
    if (_isDraining) return 0;

    final now = _clock.now().toUtc();

    // Flood guard: enforce minimum interval between successive drain passes
    if (_lastDrainCompletedAt != null &&
        now.difference(_lastDrainCompletedAt!) < minimumDrainInterval) {
      return 0;
    }

    _isDraining = true;

    try {
      // Mandatory trusted session revalidation (R24-2-04)
      final freshContext = await _authSessionPort.validateForMutation();
      if (freshContext == null ||
          freshContext.userId != validatedContext.userId ||
          freshContext.sessionGeneration !=
              validatedContext.sessionGeneration) {
        // Stale, lost, or mismatched context snapshot: abort drain safely
        return 0;
      }

      // Live active family check prior to querying (R24-2-03)
      if (_activeFamilyIdProvider != null) {
        final currentActive = _activeFamilyIdProvider();
        if (currentActive == null || currentActive != activeFamilyId) {
          return 0;
        }
      }

      // 1. Pause any active commands in this family that belong to a different actor
      final mismatched = await _commandStore.listMismatchedActiveCommands(
        familyId: activeFamilyId,
        authenticatedActorId: validatedContext.userId,
        limit: limit,
        now: now,
      );
      for (final cmd in mismatched) {
        await _commandStore.pauseMismatchedActorCommand(
          commandId: cmd.commandId,
          familyId: activeFamilyId,
          authenticatedActorId: validatedContext.userId,
          mismatchReason: 'Signed in as different actor',
          now: now,
        );
      }

      // 2. Resume any paused commands in this family belonging to the returning actor
      final paused = await _commandStore.listPausedOriginalActorCommands(
        familyId: activeFamilyId,
        authenticatedActorId: validatedContext.userId,
        limit: limit,
        now: now,
      );
      for (final cmd in paused) {
        await _commandStore.resumeOriginalActorCommand(
          commandId: cmd.commandId,
          familyId: activeFamilyId,
          authenticatedActorId: validatedContext.userId,
          now: now,
        );
      }

      // 3. List claimable commands strictly scoped to the active family
      final claimable = await _commandStore.listClaimableCommands(
        actorUserId: validatedContext.userId,
        limit: limit,
        familyId: activeFamilyId,
        now: now,
      );

      if (claimable.isEmpty) return 0;

      // 4. Bounded concurrent dispatch (max 2 parallel RPCs)
      var processedCount = 0;
      final pool = <Future<void>>{};

      for (final cmd in claimable) {
        if (cmd.childId == null) continue;

        // Verify active family hasn't switched mid-drain
        if (_activeFamilyIdProvider != null) {
          final currentActive = _activeFamilyIdProvider();
          if (currentActive != cmd.familyId) {
            continue;
          }
        }

        late final Future<void> future;
        future = () async {
          try {
            // Live active family check immediately prior to coordinator execution
            if (_activeFamilyIdProvider != null) {
              final currentActive = _activeFamilyIdProvider();
              if (currentActive != cmd.familyId) {
                return;
              }
            }

            await _coordinator.execute(
              operation: cmd.operation,
              familyId: cmd.familyId,
              childId: cmd.childId!,
              rewardId: cmd.rewardId,
              requestedCommandId: cmd.commandId,
              trigger: CommandExecutionTrigger.recovery,
            );
            processedCount++;
          } finally {
            pool.remove(future);
          }
        }();

        pool.add(future);

        if (pool.length >= maxConcurrentRpcs) {
          await Future.any(pool);
        }
      }

      if (pool.isNotEmpty) {
        await Future.wait(pool);
      }

      return processedCount;
    } finally {
      _lastDrainCompletedAt = _clock.now().toUtc();
      _isDraining = false;
    }
  }
}
