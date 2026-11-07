/// Port and value objects for authenticated session validation.
library;

/// Validated actor context representing an active, authorized user session.
///
/// Contains identity and session generation metadata without exposing
/// sensitive auth credentials or access tokens.
final class ValidatedActorContext {
  const ValidatedActorContext({
    required this.userId,
    required this.sessionGeneration,
    required this.observedAt,
    this.role,
  });

  /// The verified user ID of the authenticated actor.
  final String userId;

  /// An opaque, changing token representing the specific auth session epoch/generation.
  /// Any user switch, logout, or re-authentication invalidates prior generations.
  final String sessionGeneration;

  /// The timestamp when this session validity was observed.
  final DateTime observedAt;

  /// Optional actor role (e.g. 'parent', 'child', 'owner').
  final String? role;

  /// Checks if this observation is still within an acceptable time-to-live.
  bool isValidAt(DateTime now, {Duration ttl = const Duration(minutes: 5)}) {
    return now.difference(observedAt) <= ttl;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ValidatedActorContext &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          sessionGeneration == other.sessionGeneration &&
          observedAt == other.observedAt &&
          role == other.role;

  @override
  int get hashCode =>
      userId.hashCode ^
      sessionGeneration.hashCode ^
      observedAt.hashCode ^
      role.hashCode;

  @override
  String toString() =>
      'ValidatedActorContext(userId: $userId, sessionGeneration: $sessionGeneration, observedAt: $observedAt)';
}

/// Port for verifying active authenticated session state prior to executing mutating RPCs.
abstract interface class AuthSessionPort {
  /// Validates the current session for mutation.
  ///
  /// Returns a [ValidatedActorContext] if the session is currently active,
  /// verified, and fresh. Returns `null` if unauthenticated or invalid.
  Future<ValidatedActorContext?> validateForMutation();

  /// Live stream of session generation changes (or null when signed out).
  Stream<String?> get sessionGenerationStream;

  /// The currently observed session generation token (null if signed out).
  String? get currentSessionGeneration;
}
