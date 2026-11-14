import 'auth_session_port.dart';
import 'pending_reward_command_store.dart';

/// Preflight target authorization status.
enum TargetAuthorizationStatus {
  /// Positive proof of authorization for the target family and child.
  authorized,

  /// Definitive denial (e.g. child archived, not a family member).
  definitelyDenied,

  /// Positive proof of child device grant revocation (status = 'revoked' AND revoked_at != null).
  confirmedRevoked,

  /// Ambiguous or network failure; cannot definitively confirm or deny.
  unverified,
}

/// Authoritative adult family membership role verified from `public.family_memberships`.
enum VerifiedAdultRole {
  owner('owner'),
  parent('parent');

  const VerifiedAdultRole(this.wireValue);
  final String wireValue;

  static VerifiedAdultRole? tryFromWire(String? value) {
    for (final role in VerifiedAdultRole.values) {
      if (role.wireValue == value) return role;
    }
    return null;
  }
}

/// Specific verification outcome reason for adult redemption target checks.
enum AdultTargetVerificationReason {
  /// Active `owner`/`parent` in `family_memberships`, matching `reward_redemptions(id, family_id, child_id)`,
  /// and active `child_profiles(id, family_id, status = 'active')`.
  authorizedActiveAdultAndChild,

  /// Positive proof of paired-child device grant revocation (`status = 'revoked' AND revoked_at != null`).
  childDeviceGrantRevoked,

  /// Caller is a paired-child session (`context.role == 'child'` or active `child_device_grants` row).
  pairedChildSessionDenied,

  /// `family_memberships` row has `status = 'revoked'` or `role NOT IN ('owner', 'parent')`.
  adultMembershipRevokedOrNonAdult,

  /// Non-null `context.role` conflicts with verified `family_memberships.role`, or stored
  /// `command.actorRole` conflicts with verified `family_memberships.role`.
  inconsistentRoleClaim,

  /// Missing/empty `redemptionId` or `childId`, or non-adult `operation`.
  invalidTargetInput,

  /// `reward_redemptions` row belongs to a different `family_id` or `child_id`.
  redemptionTargetMismatch,

  /// Positive proof that `child_profiles.status == 'archived'`.
  childConfirmedArchived,

  /// `family_memberships` query completed without transport error but returned `null` (0 rows / RLS-filtered).
  missingOrUnverifiedMembership,

  /// Active adult membership verified, but `reward_redemptions` or `child_profiles` query completed
  /// without transport error and returned `null` (0 rows — e.g. RLS-hidden archived child or missing row).
  rlsFilteredOrMissingTargetRow,

  /// Network timeout, `SocketException`, or PostgREST/transport exception during verification.
  transientVerificationFailure,
}

/// Typed result of authoritative adult redemption target and role verification.
final class AdultTargetAuthorizationResult {
  const AdultTargetAuthorizationResult._({
    required this.status,
    required this.reason,
    this.verifiedRole,
  }) : assert(
         status != TargetAuthorizationStatus.authorized || verifiedRole != null,
         'TargetAuthorizationStatus.authorized requires a non-null verifiedRole.',
       ),
       assert(
         status == TargetAuthorizationStatus.authorized || verifiedRole == null,
         'Non-authorized status must not carry a verifiedRole.',
       );

  const AdultTargetAuthorizationResult.authorized({
    required VerifiedAdultRole verifiedRole,
  }) : this._(
         status: TargetAuthorizationStatus.authorized,
         reason: AdultTargetVerificationReason.authorizedActiveAdultAndChild,
         verifiedRole: verifiedRole,
       );

  const AdultTargetAuthorizationResult.definitelyDenied({
    required AdultTargetVerificationReason reason,
  }) : this._(
         status: TargetAuthorizationStatus.definitelyDenied,
         reason: reason,
       );

  const AdultTargetAuthorizationResult.confirmedRevoked({
    AdultTargetVerificationReason reason =
        AdultTargetVerificationReason.childDeviceGrantRevoked,
  }) : this._(
         status: TargetAuthorizationStatus.confirmedRevoked,
         reason: reason,
       );

  const AdultTargetAuthorizationResult.unverified({
    required AdultTargetVerificationReason reason,
  }) : this._(status: TargetAuthorizationStatus.unverified, reason: reason);

  final TargetAuthorizationStatus status;
  final AdultTargetVerificationReason reason;

  /// Positively verified role (`owner` or `parent`) from `public.family_memberships`.
  /// Non-null iff [status] == [TargetAuthorizationStatus.authorized].
  final VerifiedAdultRole? verifiedRole;
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

  /// Authoritative adult target and role verification for `fulfill_reward` and `cancel_reward`.
  Future<AdultTargetAuthorizationResult> verifyAdultRedemptionTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required String redemptionId,
    required RewardCommandOperation operation,
  });

  /// Verifies that [context] currently belongs to an active adult/parent
  /// guardian account for [familyId] and that [childId] belongs to that
  /// family before dispatching or retrying an assessment draft/evidence/submit
  /// action.
  ///
  /// Defaults to `unverified` unless overridden so test stubs implementing
  /// [RecoveryAuthorizationPort] fail closed until wired. Wait — concrete
  /// production/test adapters MUST implement this explicitly; keeping it
  /// abstract guarantees compile-time coverage of all adapters.
  Future<AdultTargetAuthorizationResult> verifyAssessmentTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
  });
}
