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
