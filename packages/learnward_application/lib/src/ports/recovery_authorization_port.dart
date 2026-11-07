import 'auth_session_port.dart';
import 'pending_reward_command_store.dart';

/// Preflight target authorization status.
enum TargetAuthorizationStatus {
  /// Positive proof of authorization for the target family and child.
  authorized,

  /// Definitive denial (e.g. child archived, not a family member, grant revoked).
  definitelyDenied,

  /// Ambiguous or network failure; cannot definitively confirm or deny.
  unverified,
}

/// Port for preflight verification of target family, child and operation eligibility.
abstract interface class RecoveryAuthorizationPort {
  /// Verifies whether the [context] is authorized to perform [operation]
  /// for the specified [familyId] and [childId].
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  });
}
