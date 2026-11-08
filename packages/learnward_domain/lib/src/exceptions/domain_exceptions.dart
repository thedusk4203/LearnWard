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

/// Authoritative backend RPC error carrying an explicit structured code.
final class BackendRpcException implements Exception, BackendRpcError {
  const BackendRpcException({
    required this.message,
    required this.code,
    this.details,
  });

  @override
  final String message;

  @override
  final String? code;

  final Object? details;

  @override
  String toString() => 'BackendRpcException(code: $code, message: $message)';
}

/// Raised when reward catalog invariants are violated.
final class InvalidRewardException implements Exception, BackendRpcError {
  const InvalidRewardException(this.message, {String? code})
    : _explicitCode = code;

  @override
  final String message;

  final String? _explicitCode;

  @override
  String? get code => _explicitCode;

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
  String? get code => _explicitCode;

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
