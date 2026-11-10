import 'dart:async';

import 'package:learnward_domain/learnward_domain.dart';

import '../ports/pending_reward_command_store.dart';

/// Prescribed disposition action for classified recovery errors.
enum ClassifiedErrorAction {
  /// Definitive, whitelisted business failure (LW201, LW202, LW203, LW205, LW206).
  /// Safe to complete command with token-fencing so new intent can use a new UUID.
  terminalWhitelisted,

  /// Positive confirmation of paired child device grant revocation.
  /// Transitions command to quarantinedUnknownOutcome and halts dispatcher.
  deviceRevoked,

  /// Ambiguous authorization failure, archived child, or unwhitelisted error (42501, LW204, etc.).
  /// Transitions command to quarantinedUnknownOutcome and halts retry loops without deletion.
  quarantineUnknownOutcome,

  /// Transient transport, socket, timeout, or 5xx error.
  /// Eligible for durable exponential backoff and retry under new lease.
  transientRetryable,
}

/// Structured outcome of error classification.
final class ClassifiedError {
  const ClassifiedError({
    required this.action,
    required this.sanitizedMessage,
    this.errorCode,
  });

  final ClassifiedErrorAction action;
  final String sanitizedMessage;
  final String? errorCode;

  @override
  String toString() =>
      'ClassifiedError(action: $action, code: $errorCode, message: $sanitizedMessage)';
}

/// Classifies RPC and network exceptions into deterministic recovery actions.
final class RecoveryErrorClassifier {
  /// Whitelisted terminal business error codes for Spin and Redeem.
  /// LW201: Insufficient RP
  /// LW202: Wheel daily cap reached
  /// LW203: Eligible wheel reward pool below 3
  /// LW205: Store reward no longer active/available
  /// LW206: Wheel disabled
  static const Set<String> _spinWheelWhitelistedCodes = {
    'LW201',
    'LW202',
    'LW203',
    'LW206',
  };

  static const Set<String> _redeemRewardWhitelistedCodes = {'LW201', 'LW205'};

  static const Set<String> _allLegacyWhitelistedCodes = {
    'LW201',
    'LW202',
    'LW203',
    'LW205',
    'LW206',
  };

  /// Classifies [error] according to authoritative typed backend evidence.
  ///
  /// Enforces:
  /// - Authoritative structured backend codes take absolute precedence over message text (R24-4-04).
  /// - Terminal business rejection REQUIRES an authoritative, positively typed
  ///   error code signal from the backend RPC adapter. Arbitrary string matches
  ///   are never treated as terminal rejections.
  /// - Adult operations (`fulfill_reward` and `cancel_reward`) never whitelist any error codes for automatic deletion.
  /// - Transport/timeout/socket exceptions are transient retryable only when no
  ///   authoritative terminal code is present.
  static ClassifiedError classify(
    Object error, {
    RewardCommandOperation? operation,
  }) {
    // 1. Authoritative structured backend code takes precedence over untrusted message text (R24-4-04)
    if (error is BackendRpcError && error.code != null) {
      final code = error.code!;
      final message = _sanitizeMessage(error.message);

      final Set<String> whitelisted;
      if (operation == RewardCommandOperation.fulfillReward ||
          operation == RewardCommandOperation.cancelReward) {
        whitelisted = const <String>{};
      } else if (operation == RewardCommandOperation.spinWheel) {
        whitelisted = _spinWheelWhitelistedCodes;
      } else if (operation == RewardCommandOperation.redeemReward) {
        whitelisted = _redeemRewardWhitelistedCodes;
      } else {
        whitelisted = _allLegacyWhitelistedCodes;
      }

      if (whitelisted.contains(code)) {
        return ClassifiedError(
          action: ClassifiedErrorAction.terminalWhitelisted,
          sanitizedMessage: message,
          errorCode: code,
        );
      }

      if (code == '42501') {
        return const ClassifiedError(
          action: ClassifiedErrorAction.quarantineUnknownOutcome,
          sanitizedMessage: 'Authorization failure or permission denied.',
          errorCode: '42501',
        );
      }

      if (code == '500' || code == '502' || code == '503' || code == '504') {
        return ClassifiedError(
          action: ClassifiedErrorAction.transientRetryable,
          sanitizedMessage:
              'Network communication failure. Retrying scheduled.',
          errorCode: code,
        );
      }

      // Non-whitelisted backend codes (LW204, P0002, 22000, unknown LW*)
      return ClassifiedError(
        action: ClassifiedErrorAction.quarantineUnknownOutcome,
        sanitizedMessage: message,
        errorCode: code,
      );
    }

    final str = error.toString();

    // 2. Transient network / timeout / transport errors (when no structured code exists)
    if (error is TimeoutException ||
        error.runtimeType.toString().contains('SocketException') ||
        error.runtimeType.toString().contains('ClientException') ||
        error.runtimeType.toString().contains('HttpException') ||
        str.contains('TimeoutException') ||
        str.contains('SocketException') ||
        str.contains('ClientException') ||
        str.contains('connection reset') ||
        str.contains('connection refused') ||
        str.contains('Network is unreachable') ||
        RegExp(r'\b(500|502|503|504)\b').hasMatch(str) ||
        RegExp(
          r'\b(timed out|timeout)\b',
          caseSensitive: false,
        ).hasMatch(str)) {
      return const ClassifiedError(
        action: ClassifiedErrorAction.transientRetryable,
        sanitizedMessage: 'Network communication failure. Retrying scheduled.',
        errorCode: 'TRANSIENT_NETWORK',
      );
    }

    // 3. Authorization or permission denied fallback (untyped)
    if (str.contains('42501') ||
        str.contains('permission denied') ||
        str.contains('violates row-level security') ||
        str.contains('unauthorized')) {
      return const ClassifiedError(
        action: ClassifiedErrorAction.quarantineUnknownOutcome,
        sanitizedMessage: 'Authorization failure or permission denied.',
        errorCode: '42501',
      );
    }

    // 4. Fail-closed fallback: quarantine unknown outcome to prevent data corruption
    return ClassifiedError(
      action: ClassifiedErrorAction.quarantineUnknownOutcome,
      sanitizedMessage: _sanitizeMessage(str),
      errorCode: 'UNKNOWN_ERROR',
    );
  }

  static String _sanitizeMessage(String raw) {
    if (raw.length > 200) {
      return '${raw.substring(0, 197)}...';
    }
    return raw;
  }
}
