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

/// Raised when reward catalog invariants are violated.
final class InvalidRewardException implements Exception {
  const InvalidRewardException(this.message);

  final String message;

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
final class InvalidWheelException implements Exception {
  const InvalidWheelException(this.message);

  final String message;

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
