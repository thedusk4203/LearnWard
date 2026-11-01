import 'dart:math';

import 'package:learnward_domain/learnward_domain.dart';

import '../ports/pending_reward_command_store.dart';
import '../ports/reward_repository.dart';

final class CancelRewardRedemption {
  const CancelRewardRedemption(
    this._repository, {
    this.commandStore,
    this.uuidGenerator,
  });

  final RewardRepository _repository;
  final PendingRewardCommandStore? commandStore;
  final String Function()? uuidGenerator;

  Future<RewardRedemption> call({
    String? commandId,
    FamilyId? familyId,
    required RewardRedemptionId redemptionId,
    required String cancellationReason,
  }) async {
    if (commandStore == null || familyId == null) {
      final actualCommandId =
          commandId ?? (uuidGenerator?.call() ?? _generateUuid());
      return _repository.cancelRewardRedemption(
        commandId: actualCommandId,
        redemptionId: redemptionId,
        cancellationReason: cancellationReason,
      );
    }

    final existing = await commandStore!.findPendingRedemptionCommand(
      operation: RewardCommandOperation.cancelReward,
      redemptionId: redemptionId.value,
    );

    final actualCommandId =
        existing?.commandId ??
        commandId ??
        (uuidGenerator?.call() ?? _generateUuid());
    final actualReason = existing?.cancellationReason ?? cancellationReason;

    if (existing == null) {
      await commandStore!.savePendingCommand(
        PendingRewardCommand(
          operation: RewardCommandOperation.cancelReward,
          commandId: actualCommandId,
          familyId: familyId.value,
          redemptionId: redemptionId.value,
          cancellationReason: actualReason,
          createdAt: DateTime.now().toUtc(),
        ),
      );
    }

    try {
      final result = await _repository.cancelRewardRedemption(
        commandId: actualCommandId,
        redemptionId: redemptionId,
        cancellationReason: actualReason,
      );

      await commandStore!.deletePendingCommand(actualCommandId);
      return result;
    } catch (e) {
      if (_isTerminalError(e)) {
        await commandStore!.deletePendingCommand(actualCommandId);
      }
      rethrow;
    }
  }

  static bool _isTerminalError(Object error) {
    final msg = error.toString();
    if (msg.contains('LW204') ||
        msg.contains('LW004') ||
        msg.contains('42501') ||
        msg.contains('InvalidRedemptionException')) {
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
