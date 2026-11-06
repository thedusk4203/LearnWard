import 'dart:math';

import 'package:learnward_domain/learnward_domain.dart';

import '../ports/command_lifecycle_states.dart';
import '../ports/pending_reward_command_store.dart';
import '../ports/wheel_repository.dart';

/// Server-authoritative use-case for spinning the Celebration Wheel with durable journaling.
final class SpinRewardWheel {
  const SpinRewardWheel(
    this._repository,
    this._commandStore, {
    this.uuidGenerator,
  });

  final WheelRepository _repository;
  final PendingRewardCommandStore _commandStore;
  final String Function()? uuidGenerator;

  Future<WheelSpinResult> call({
    required FamilyId familyId,
    required ChildId childId,
    String? commandId,
    String? actorUserId,
    String? actorRole,
  }) async {
    final existing = await _commandStore.findPendingSpinCommand(
      familyId: familyId.value,
      childId: childId.value,
      actorUserId: actorUserId,
    );

    final canReplayExisting =
        existing != null &&
        existing.recoveryState == CommandRecoveryState.active &&
        existing.dispatchState != CommandDispatchState.unknownLegacy &&
        existing.dispatchState != CommandDispatchState.confirmedCommitted &&
        (actorUserId == null ||
            existing.actorUserId == null ||
            existing.actorUserId == actorUserId);

    final actualCommandId = canReplayExisting
        ? existing.commandId
        : commandId ?? (uuidGenerator?.call() ?? _generateUuid());

    if (existing == null || !canReplayExisting) {
      await _commandStore.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: actualCommandId,
          familyId: familyId.value,
          childId: childId.value,
          actorUserId: actorUserId,
          actorRole: actorRole,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }

    try {
      final result = await _repository.spinRewardWheel(
        commandId: actualCommandId,
        childId: childId,
      );

      await _commandStore.deletePendingCommand(actualCommandId);
      return result;
    } catch (e) {
      if (_isTerminalError(e)) {
        await _commandStore.deletePendingCommand(actualCommandId);
      }
      rethrow;
    }
  }

  static bool _isTerminalError(Object error) {
    final msg = error.toString();
    if (msg.contains('LW201') || // Insufficient RP
        msg.contains('LW202') || // Daily cap reached
        msg.contains('LW203') || // Pool size < 3
        msg.contains('LW206') || // Wheel disabled
        msg.contains('LW004') || // Timezone / invalid
        msg.contains('42501') || // Permission denied
        msg.contains('P0002') || // Child not found
        msg.contains('22000') || // Bad argument
        msg.contains('InvalidWheelException')) {
      return true;
    }
    return false;
  }

  static String _generateUuid() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}
