import 'package:learnward_domain/learnward_domain.dart';

import 'auth_session_port.dart';
import 'containment_session_models.dart';
import 'recovery_authorization_port.dart';

/// Specific reason why an active adult's target child is unavailable under server state/RLS.
enum TargetChildUnavailabilityReason {
  confirmedArchived,
  notActiveOrRlsHidden,
  familyMismatch,
}

/// Specific reason why a paired-child session could not verify active device access.
enum PairedChildUnverifiedReason {
  grantVerificationTimeoutOrError,
  grantUncertain42501,
  grantMissingForPairedIdentity,
  childProfileUnavailableOrArchived,
  grantStatusMalformedOrAmbiguous,
}

/// Exhaustive 8-way outcome model returned by [ContainmentAuthorizationVerifier] (`D2.4`).
sealed class ContainmentVerificationOutcome {
  const ContainmentVerificationOutcome();
}

/// 1. Positive non-anonymous active adult (`owner`/`parent`) with zero paired-child grants.
final class AuthorizedActiveAdult extends ContainmentVerificationOutcome {
  AuthorizedActiveAdult({
    required this.verifiedRole,
    required this.verifiedFamily,
    required List<Family> verifiedFamilies,
    required Map<String, VerifiedAdultRole> verifiedRolesByFamilyId,
    this.verifiedChild,
  }) : verifiedFamilies = List.unmodifiable(verifiedFamilies),
       verifiedRolesByFamilyId = Map.unmodifiable(verifiedRolesByFamilyId);

  final VerifiedAdultRole verifiedRole;
  final Family verifiedFamily;
  final List<Family> verifiedFamilies;
  final Map<String, VerifiedAdultRole> verifiedRolesByFamilyId;
  final ChildProfile? verifiedChild;

  @override
  String toString() =>
      'AuthorizedActiveAdult(verifiedRole: ${verifiedRole.wireValue}, '
      'familyId: ${verifiedFamily.id.value}, '
      'familyCount: ${verifiedFamilies.length}, '
      'hasVerifiedChild: ${verifiedChild != null})';
}

/// 2. Positive active adult confirmed, but requested/persisted target child is
/// archived or hidden (`0` rows under Phase 6.1 RLS `status = 'active'`).
final class AuthorizedAdultChildUnavailable
    extends ContainmentVerificationOutcome {
  AuthorizedAdultChildUnavailable({
    required this.verifiedRole,
    required this.verifiedFamily,
    required List<Family> verifiedFamilies,
    required Map<String, VerifiedAdultRole> verifiedRolesByFamilyId,
    required this.reason,
    this.targetChildId,
    this.targetFamilyId,
  }) : verifiedFamilies = List.unmodifiable(verifiedFamilies),
       verifiedRolesByFamilyId = Map.unmodifiable(verifiedRolesByFamilyId);

  final VerifiedAdultRole verifiedRole;
  final Family verifiedFamily;
  final List<Family> verifiedFamilies;
  final Map<String, VerifiedAdultRole> verifiedRolesByFamilyId;
  final TargetChildUnavailabilityReason reason;
  final ChildId? targetChildId;
  final FamilyId? targetFamilyId;

  @override
  String toString() =>
      'AuthorizedAdultChildUnavailable(verifiedRole: ${verifiedRole.wireValue}, '
      'familyId: ${verifiedFamily.id.value}, reason: ${reason.name})';
}

/// 3. Clean HTTP 200 `0` rows on both `child_device_grants` and `family_memberships`
/// for a non-anonymous, non-paired-child actor. Neutral onboarding state only.
final class NoActiveFamilyMembershipObserved
    extends ContainmentVerificationOutcome {
  const NoActiveFamilyMembershipObserved();

  @override
  String toString() => 'NoActiveFamilyMembershipObserved()';
}

/// 4. Positive active `child_device_grants` row AND matching active child/family rows.
final class AuthorizedPairedChild extends ContainmentVerificationOutcome {
  const AuthorizedPairedChild({
    required this.verifiedChild,
    required this.verifiedFamily,
    required this.grantId,
  });

  final ChildProfile verifiedChild;
  final Family verifiedFamily;
  final String grantId;

  @override
  String toString() =>
      'AuthorizedPairedChild(childId: ${verifiedChild.id.value}, '
      'familyId: ${verifiedFamily.id.value}, grantId: $grantId)';
}

/// 5. Positive proof of paired-child device revocation (`status == 'revoked' && revoked_at != null`).
final class ConfirmedPairedChildGrantRevoked
    extends ContainmentVerificationOutcome {
  const ConfirmedPairedChildGrantRevoked({
    required this.revokedAt,
    this.grantId,
  });

  final DateTime revokedAt;
  final String? grantId;

  @override
  String toString() =>
      'ConfirmedPairedChildGrantRevoked(revokedAt: ${revokedAt.toUtc().toIso8601String()})';
}

/// 6. Session carries a paired-child signal (`isAnonymous`, `role == 'child'`,
/// `paired_child_device` envelope, or non-revoked grant) without positive active proof.
final class PairedChildUnverified extends ContainmentVerificationOutcome {
  const PairedChildUnverified({required this.reason, this.diagnosticCode});

  final PairedChildUnverifiedReason reason;
  final String? diagnosticCode;

  @override
  String toString() =>
      'PairedChildUnverified(reason: ${reason.name}'
      '${diagnosticCode != null ? ', diagnosticCode: $diagnosticCode' : ''})';
}

/// 7. Explicit `status == 'revoked'` `family_memberships` row positively
/// observed (never inferred from RLS 0 rows, `invited`, or malformed rows).
final class ConfirmedAdultMembershipRevoked
    extends ContainmentVerificationOutcome {
  const ConfirmedAdultMembershipRevoked({required this.reason});

  final String reason;

  @override
  String toString() => 'ConfirmedAdultMembershipRevoked(reason: $reason)';
}

/// 8. Transport error, timeout, stale actor context, uncertain `42501`, or
/// non-active `invited` / malformed membership data preventing positive
/// verification for a non-paired-child session.
final class SessionAuthorizationUnverified
    extends ContainmentVerificationOutcome {
  const SessionAuthorizationUnverified({
    required this.reason,
    this.diagnosticCode,
    this.allowsOfflineChildContainment = true,
  });

  final String reason;
  final String? diagnosticCode;
  final bool allowsOfflineChildContainment;

  @override
  String toString() =>
      'SessionAuthorizationUnverified(reason: $reason'
      '${diagnosticCode != null ? ', diagnosticCode: $diagnosticCode' : ''}'
      '${allowsOfflineChildContainment ? '' : ', allowsOfflineChildContainment: false'})';
}

/// Read-only authorization verifier separating Supabase Auth identity hints from
/// authoritative database grants, memberships, and child profile state.
abstract interface class ContainmentAuthorizationVerifier {
  Future<ContainmentVerificationOutcome> verifySession({
    required ValidatedActorContext context,
    PersistedChildModeSession? persistedChildSession,
    FamilyId? preferredFamilyId,
    ChildId? targetChildId,
    FamilyId? targetFamilyId,
  });
}
