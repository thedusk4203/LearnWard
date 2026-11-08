import 'dart:async';

import 'package:learnward_domain/learnward_domain.dart';

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
  static const Set<String> _terminalWhitelistedCodes = {
    'LW201',
    'LW202',
    'LW203',
    'LW205',
    'LW206',
  };

  /// Classifies [error] according to authoritative typed backend evidence.
  ///
  /// Enforces:
  /// - Transport/timeout/socket exceptions are transient retryable, even if their
  ///   message happens to mention an error code substring (R24-2-02).
  /// - Terminal business rejection REQUIRES an authoritative, positively typed
  ///   error code signal from the backend RPC adapter. Arbitrary string matches
  ///   are never treated as terminal rejections.
  static ClassifiedError classify(Object error) {
    final str = error.toString();

    // 1. Transient network / timeout / transport errors FIRST
    if (error is TimeoutException ||
        error.runtimeType.toString().contains('SocketException') ||
        error.runtimeType.toString().contains('ClientException') ||
        error.runtimeType.toString().contains('HttpException') ||
        str.contains('TimeoutException') ||
        str.contains('timeout') ||
        str.contains('SocketException') ||
        str.contains('ClientException') ||
        str.contains('connection reset') ||
        str.contains('connection refused') ||
        str.contains('Network is unreachable') ||
        str.contains('500') ||
        str.contains('502') ||
        str.contains('503') ||
        str.contains('504')) {
      return const ClassifiedError(
        action: ClassifiedErrorAction.transientRetryable,
        sanitizedMessage: 'Network communication failure. Retrying scheduled.',
        errorCode: 'TRANSIENT_NETWORK',
      );
    }

    // 2. Extract structured authoritative code and message if available
    String? code;
    String? message;

    if (error is BackendRpcError) {
      code = error.code;
      message = error.message;
    }

    message ??= str;

    // 3. Check for whitelisted terminal business codes ONLY via structured code
    if (code != null && _terminalWhitelistedCodes.contains(code)) {
      return ClassifiedError(
        action: ClassifiedErrorAction.terminalWhitelisted,
        sanitizedMessage: _sanitizeMessage(message),
        errorCode: code,
      );
    }

    // 4. Authorization or permission denied (ambiguous, never infer device revocation from strings)
    // 42501 or permission denied halts retry loops without deletion.
    if (code == '42501' ||
        str.contains('42501') ||
        str.contains('permission denied') ||
        str.contains('violates row-level security') ||
        str.contains('unauthorized')) {
      return ClassifiedError(
        action: ClassifiedErrorAction.quarantineUnknownOutcome,
        sanitizedMessage: 'Authorization failure or permission denied.',
        errorCode: code ?? '42501',
      );
    }

    // 5. Non-whitelisted backend codes (LW204, P0002, 22000, unknown LW*)
    if (code == 'LW204' ||
        code == 'P0002' ||
        code == '22000' ||
        (code != null && RegExp(r'^LW\d{3}$').hasMatch(code))) {
      return ClassifiedError(
        action: ClassifiedErrorAction.quarantineUnknownOutcome,
        sanitizedMessage: _sanitizeMessage(message),
        errorCode: code,
      );
    }

    // 6. Fail-closed fallback: quarantine unknown outcome to prevent data corruption
    return ClassifiedError(
      action: ClassifiedErrorAction.quarantineUnknownOutcome,
      sanitizedMessage: _sanitizeMessage(message),
      errorCode: code ?? 'UNKNOWN_ERROR',
    );
  }

  static String _sanitizeMessage(String raw) {
    if (raw.length > 200) {
      return '${raw.substring(0, 197)}...';
    }
    return raw;
  }
}
