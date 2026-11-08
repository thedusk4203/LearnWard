/// Raised when family domain invariants are violated.
final class InvalidFamilyException implements Exception {
  const InvalidFamilyException(this.message);

  final String message;

  @override
  String toString() => 'InvalidFamilyException: $message';
}

/// Raised when child profile domain invariants are violated.
final class InvalidChildProfileException implements Exception {
  const InvalidChildProfileException(this.message);

  final String message;

  @override
  String toString() => 'InvalidChildProfileException: $message';
}

/// Raised when assessment domain invariants are violated.
final class InvalidAssessmentException implements Exception {
  const InvalidAssessmentException(this.message);

  final String message;

  @override
  String toString() => 'InvalidAssessmentException: $message';
}

/// Interface for authoritative backend error signals carrying structured codes.
abstract interface class BackendRpcError {
  String? get code;
  String get message;
}

/// Raised when reward catalog invariants are violated.
final class InvalidRewardException implements Exception, BackendRpcError {
  const InvalidRewardException(this.message, {String? code})
    : _explicitCode = code;

  @override
  final String message;

  final String? _explicitCode;

  @override
  String? get code {
    if (_explicitCode != null) return _explicitCode;
    final match = RegExp(r'\b(LW\d{3})\b').firstMatch(message);
    return match?.group(1);
  }

  @override
  String toString() => 'InvalidRewardException: $message';
}

/// Raised when reward redemption invariants are violated.
final class InvalidRedemptionException implements Exception {
  const InvalidRedemptionException(this.message);

  final String message;

  @override
  String toString() => 'InvalidRedemptionException: $message';
}

/// Raised when wheel or wheel settings domain invariants are violated.
final class InvalidWheelException implements Exception, BackendRpcError {
  const InvalidWheelException(this.message, {String? code})
    : _explicitCode = code;

  @override
  final String message;

  final String? _explicitCode;

  @override
  String? get code {
    if (_explicitCode != null) return _explicitCode;
    final match = RegExp(r'\b(LW\d{3})\b').firstMatch(message);
    return match?.group(1);
  }

  @override
  String toString() => 'InvalidWheelException: $message';
}

/// Raised when learning or mastery domain invariants are violated.
final class InvalidLearningException implements Exception {
  const InvalidLearningException(this.message);

  final String message;

  @override
  String toString() => 'InvalidLearningException: $message';
}
