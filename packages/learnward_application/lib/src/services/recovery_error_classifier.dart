import 'dart:async';

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

  /// Classifies [error] according to the authoritative Section 8 error taxonomy.
  static ClassifiedError classify(Object error) {
    final str = error.toString();
    final dynamic err = error;

    // 1. Extract structured code and message if available
    String? code;
    String? message;

    try {
      // ignore: avoid_dynamic_calls
      final dynamic c = err.code;
      if (c != null) code = c.toString();
    } catch (_) {}

    try {
      // ignore: avoid_dynamic_calls
      final dynamic m = err.message;
      if (m != null) message = m.toString();
    } catch (_) {}

    message ??= str;

    // 2. Check for whitelisted terminal business codes
    if (code != null && _terminalWhitelistedCodes.contains(code)) {
      return ClassifiedError(
        action: ClassifiedErrorAction.terminalWhitelisted,
        sanitizedMessage: _sanitizeMessage(message),
        errorCode: code,
      );
    }

    for (final terminalCode in _terminalWhitelistedCodes) {
      if (str.contains(terminalCode)) {
        return ClassifiedError(
          action: ClassifiedErrorAction.terminalWhitelisted,
          sanitizedMessage: _sanitizeMessage(message),
          errorCode: terminalCode,
        );
      }
    }

    // 3. Authorization or permission denied (ambiguous, never infer device revocation from strings)
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

    // 6. Non-whitelisted backend codes (LW204, P0002, 22000, unknown LW*)
    if (str.contains('LW204') ||
        str.contains('P0002') ||
        str.contains('22000') ||
        RegExp(r'LW\d{3}').hasMatch(str)) {
      return ClassifiedError(
        action: ClassifiedErrorAction.quarantineUnknownOutcome,
        sanitizedMessage: _sanitizeMessage(message),
        errorCode: code ?? 'UNKNOWN_DOMAIN_REJECTION',
      );
    }

    // 7. Transient network / timeout / transport errors
    if (error is TimeoutException ||
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
      return ClassifiedError(
        action: ClassifiedErrorAction.transientRetryable,
        sanitizedMessage: 'Network communication failure. Retrying scheduled.',
        errorCode: 'TRANSIENT_NETWORK',
      );
    }

    // 8. Fail-closed fallback: quarantine unknown outcome to prevent data corruption
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
