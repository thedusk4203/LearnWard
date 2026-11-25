// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Read-only Supabase/PostgREST implementation of [ContainmentAuthorizationVerifier].
///
/// Enforces the 4-layer separation of identity vs DB authority (`docs/25` D2.3–D2.4):
/// 1. Validates live actor context freshness/structure.
/// 2. Queries `public.child_device_grants` FIRST (authoritative over `appMetadata.role`).
/// 3. Queries `public.family_memberships` SECOND ONLY when no grant or paired-child signal exists,
///    without requiring or blocking on optional `appMetadata.role` hints.
/// 4. Distinguishes clean HTTP 200 zero-row results ([NoActiveFamilyMembershipObserved])
///    from positive revocation ([ConfirmedAdultMembershipRevoked] / [ConfirmedPairedChildGrantRevoked])
///    and from transport/42501 uncertainty ([SessionAuthorizationUnverified] / [PairedChildUnverified]).
/// 5. Checks target `public.child_profiles` active/archived/0-row visibility when scoped to a child.
final class SupabaseContainmentAuthorizationVerifier
    implements ContainmentAuthorizationVerifier {
  const SupabaseContainmentAuthorizationVerifier(
    this._client, {
    Clock clock = const SystemClock(),
    Duration timeout = const Duration(seconds: 5),
  }) : _clock = clock,
       _timeout = timeout;

  final SupabaseClient _client;
  final Clock _clock;
  final Duration _timeout;

  static const String _grantColumns =
      'id, family_id, child_id, auth_user_id, status, revoked_at';
  static const String _membershipColumns =
      'family_id, auth_user_id, role, status, joined_at, revoked_at';
  static const String _familyColumns =
      'id, name, timezone, locale, created_by_user_id, created_at, archived_at';
  static const String _childColumns =
      'id, family_id, display_name, school_grade, birth_year, avatar_key, status, created_at, archived_at';

  @override
  Future<ContainmentVerificationOutcome> verifySession({
    required ValidatedActorContext context,
    PersistedChildModeSession? persistedChildSession,
    FamilyId? preferredFamilyId,
    ChildId? targetChildId,
    FamilyId? targetFamilyId,
  }) async {
    final nowUtc = _clock.now().toUtc();
    if (context.userId.trim().isEmpty ||
        context.sessionGeneration.trim().isEmpty ||
        !context.isValidAt(nowUtc)) {
      return const SessionAuthorizationUnverified(
        reason: 'stale_or_invalid_actor_context',
      );
    }

    final persistedPairedForActor =
        persistedChildSession != null &&
        persistedChildSession.modeKind ==
            PersistedChildModeKind.pairedChildDevice &&
        persistedChildSession.actorUserId == context.userId;

    final hasPairedChildSignal =
        context.isAnonymous ||
        context.role == 'child' ||
        persistedPairedForActor;

    final sameActorSharedSession =
        persistedChildSession != null &&
            persistedChildSession.modeKind ==
                PersistedChildModeKind.sharedDeviceAdult &&
            persistedChildSession.actorUserId == context.userId
        ? persistedChildSession
        : null;

    final effectiveTargetChildId =
        targetChildId ?? sameActorSharedSession?.childId;
    final effectiveTargetFamilyId =
        targetFamilyId ?? sameActorSharedSession?.familyId;

    // Step 1: Query `public.child_device_grants` FIRST (always).
    final List<Map<String, dynamic>> grantRows;
    try {
      final dynamic grantsRaw = await _client
          .from('child_device_grants')
          .select(_grantColumns)
          .eq('auth_user_id', context.userId)
          .timeout(_timeout);
      final parsedGrants = _asRowList(grantsRaw);
      if (parsedGrants == null) {
        return hasPairedChildSignal
            ? const PairedChildUnverified(
                reason:
                    PairedChildUnverifiedReason.grantStatusMalformedOrAmbiguous,
              )
            : const SessionAuthorizationUnverified(
                reason: 'grant_response_not_list',
              );
      }
      grantRows = parsedGrants
          .where((row) => row['auth_user_id'] == context.userId)
          .toList(growable: false);
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        return hasPairedChildSignal
            ? const PairedChildUnverified(
                reason: PairedChildUnverifiedReason.grantUncertain42501,
                diagnosticCode: '42501',
              )
            : const SessionAuthorizationUnverified(
                reason: 'grant_query_permission_denied_42501',
                diagnosticCode: '42501',
              );
      }
      return hasPairedChildSignal
          ? PairedChildUnverified(
              reason:
                  PairedChildUnverifiedReason.grantVerificationTimeoutOrError,
              diagnosticCode: e.code,
            )
          : SessionAuthorizationUnverified(
              reason: 'grant_query_postgrest_error',
              diagnosticCode: e.code,
            );
    } on TimeoutException {
      return hasPairedChildSignal
          ? const PairedChildUnverified(
              reason:
                  PairedChildUnverifiedReason.grantVerificationTimeoutOrError,
              diagnosticCode: 'timeout',
            )
          : const SessionAuthorizationUnverified(
              reason: 'grant_query_timeout',
              diagnosticCode: 'timeout',
            );
    } catch (_) {
      return hasPairedChildSignal
          ? const PairedChildUnverified(
              reason:
                  PairedChildUnverifiedReason.grantVerificationTimeoutOrError,
            )
          : const SessionAuthorizationUnverified(
              reason: 'grant_query_transport_failure',
            );
    }

    if (grantRows.isNotEmpty) {
      return _resolveGrantRows(grantRows);
    }

    // Zero grant rows for an explicit paired-child / anonymous signal MUST fail
    // closed without ever falling through to family_memberships.
    if (hasPairedChildSignal) {
      return const PairedChildUnverified(
        reason: PairedChildUnverifiedReason.grantMissingForPairedIdentity,
      );
    }

    // Step 2: Query `public.family_memberships` SECOND (`!hasPairedChildSignal`).
    final List<Map<String, dynamic>> membershipRows;
    try {
      final dynamic membershipsRaw = await _client
          .from('family_memberships')
          .select(_membershipColumns)
          .eq('auth_user_id', context.userId)
          .timeout(_timeout);
      final parsedMemberships = _asRowList(membershipsRaw);
      if (parsedMemberships == null) {
        return const SessionAuthorizationUnverified(
          reason: 'membership_response_not_list',
        );
      }
      membershipRows = parsedMemberships
          .where((row) => row['auth_user_id'] == context.userId)
          .toList(growable: false);
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        return const SessionAuthorizationUnverified(
          reason: 'membership_query_permission_denied_42501',
          diagnosticCode: '42501',
        );
      }
      return SessionAuthorizationUnverified(
        reason: 'membership_query_postgrest_error',
        diagnosticCode: e.code,
      );
    } on TimeoutException {
      return const SessionAuthorizationUnverified(
        reason: 'membership_query_timeout',
        diagnosticCode: 'timeout',
      );
    } catch (_) {
      return const SessionAuthorizationUnverified(
        reason: 'membership_query_transport_failure',
      );
    }

    // Clean HTTP 200 zero-row result on both grants and memberships.
    if (membershipRows.isEmpty) {
      return const NoActiveFamilyMembershipObserved();
    }

    final verifiedRolesByFamilyId = <String, VerifiedAdultRole>{};
    for (final row in membershipRows) {
      final status = row['status'] as String?;
      final role = VerifiedAdultRole.tryFromWire(row['role'] as String?);
      final familyIdRaw = row['family_id'] as String?;
      if (status == 'active' &&
          role != null &&
          familyIdRaw != null &&
          familyIdRaw.trim().isNotEmpty) {
        verifiedRolesByFamilyId[familyIdRaw.trim()] = role;
      }
    }

    if (verifiedRolesByFamilyId.isEmpty) {
      return const ConfirmedAdultMembershipRevoked(
        reason: 'adult_membership_revoked_or_non_adult',
      );
    }

    // Fetch authoritative Family rows for verified active adult memberships.
    final activeFamilyIds = verifiedRolesByFamilyId.keys.toList(
      growable: false,
    );
    final List<Family> verifiedFamilies;
    try {
      final dynamic familiesRaw = await _client
          .from('families')
          .select(_familyColumns)
          .inFilter('id', activeFamilyIds)
          .order('created_at', ascending: false)
          .timeout(_timeout);
      final familyRows = _asRowList(familiesRaw);
      if (familyRows == null) {
        return const SessionAuthorizationUnverified(
          reason: 'families_response_not_list',
        );
      }
      verifiedFamilies = familyRows
          .map(_tryParseFamily)
          .whereType<Family>()
          .where(
            (f) =>
                !f.isArchived &&
                verifiedRolesByFamilyId.containsKey(f.id.value),
          )
          .toList(growable: false);
    } on PostgrestException catch (e) {
      return SessionAuthorizationUnverified(
        reason: e.code == '42501'
            ? 'families_query_permission_denied_42501'
            : 'families_query_postgrest_error',
        diagnosticCode: e.code,
      );
    } on TimeoutException {
      return const SessionAuthorizationUnverified(
        reason: 'families_query_timeout',
        diagnosticCode: 'timeout',
      );
    } catch (_) {
      return const SessionAuthorizationUnverified(
        reason: 'families_query_transport_failure',
      );
    }

    if (verifiedFamilies.isEmpty) {
      return const SessionAuthorizationUnverified(
        reason: 'verified_family_row_missing_or_archived',
      );
    }

    final scopedRolesByFamilyId = <String, VerifiedAdultRole>{
      for (final family in verifiedFamilies)
        family.id.value: verifiedRolesByFamilyId[family.id.value]!,
    };

    Family primaryFamily = verifiedFamilies.first;
    if (effectiveTargetFamilyId != null) {
      for (final family in verifiedFamilies) {
        if (family.id == effectiveTargetFamilyId) {
          primaryFamily = family;
          break;
        }
      }
    } else if (preferredFamilyId != null) {
      for (final family in verifiedFamilies) {
        if (family.id == preferredFamilyId) {
          primaryFamily = family;
          break;
        }
      }
    }
    final primaryRole = scopedRolesByFamilyId[primaryFamily.id.value]!;

    // Step 3: Check target child active/archived visibility when scoped to a child.
    if (effectiveTargetChildId == null) {
      return AuthorizedActiveAdult(
        verifiedRole: primaryRole,
        verifiedFamily: primaryFamily,
        verifiedFamilies: verifiedFamilies,
        verifiedRolesByFamilyId: scopedRolesByFamilyId,
      );
    }

    if (effectiveTargetFamilyId == null ||
        !scopedRolesByFamilyId.containsKey(effectiveTargetFamilyId.value)) {
      return AuthorizedAdultChildUnavailable(
        verifiedRole: primaryRole,
        verifiedFamily: primaryFamily,
        verifiedFamilies: verifiedFamilies,
        verifiedRolesByFamilyId: scopedRolesByFamilyId,
        reason: TargetChildUnavailabilityReason.familyMismatch,
        targetChildId: effectiveTargetChildId,
        targetFamilyId: effectiveTargetFamilyId,
      );
    }

    final targetFamily = verifiedFamilies.firstWhere(
      (f) => f.id == effectiveTargetFamilyId,
    );
    final targetRole = scopedRolesByFamilyId[targetFamily.id.value]!;

    try {
      final childRow = await _client
          .from('child_profiles')
          .select(_childColumns)
          .eq('id', effectiveTargetChildId.value)
          .eq('family_id', targetFamily.id.value)
          .maybeSingle()
          .timeout(_timeout);

      if (childRow == null) {
        return AuthorizedAdultChildUnavailable(
          verifiedRole: targetRole,
          verifiedFamily: targetFamily,
          verifiedFamilies: verifiedFamilies,
          verifiedRolesByFamilyId: scopedRolesByFamilyId,
          reason: TargetChildUnavailabilityReason.notActiveOrRlsHidden,
          targetChildId: effectiveTargetChildId,
          targetFamilyId: targetFamily.id,
        );
      }

      final statusRaw = childRow['status'] as String?;
      if (statusRaw == 'archived' || childRow['archived_at'] != null) {
        return AuthorizedAdultChildUnavailable(
          verifiedRole: targetRole,
          verifiedFamily: targetFamily,
          verifiedFamilies: verifiedFamilies,
          verifiedRolesByFamilyId: scopedRolesByFamilyId,
          reason: TargetChildUnavailabilityReason.confirmedArchived,
          targetChildId: effectiveTargetChildId,
          targetFamilyId: targetFamily.id,
        );
      }

      if (statusRaw != 'active') {
        return AuthorizedAdultChildUnavailable(
          verifiedRole: targetRole,
          verifiedFamily: targetFamily,
          verifiedFamilies: verifiedFamilies,
          verifiedRolesByFamilyId: scopedRolesByFamilyId,
          reason: TargetChildUnavailabilityReason.notActiveOrRlsHidden,
          targetChildId: effectiveTargetChildId,
          targetFamilyId: targetFamily.id,
        );
      }

      final child = _tryParseChildProfile(childRow);
      if (child == null ||
          child.id != effectiveTargetChildId ||
          child.familyId != targetFamily.id ||
          !child.isActive ||
          child.isArchived) {
        return const SessionAuthorizationUnverified(
          reason: 'child_profile_malformed_row',
        );
      }

      return AuthorizedActiveAdult(
        verifiedRole: targetRole,
        verifiedFamily: targetFamily,
        verifiedFamilies: verifiedFamilies,
        verifiedRolesByFamilyId: scopedRolesByFamilyId,
        verifiedChild: child,
      );
    } on PostgrestException catch (e) {
      return SessionAuthorizationUnverified(
        reason: e.code == '42501'
            ? 'child_profile_query_permission_denied_42501'
            : 'child_profile_query_postgrest_error',
        diagnosticCode: e.code,
      );
    } on TimeoutException {
      return const SessionAuthorizationUnverified(
        reason: 'child_profile_query_timeout',
        diagnosticCode: 'timeout',
      );
    } catch (_) {
      return const SessionAuthorizationUnverified(
        reason: 'child_profile_query_transport_failure',
      );
    }
  }

  Future<ContainmentVerificationOutcome> _resolveGrantRows(
    List<Map<String, dynamic>> grantRows,
  ) async {
    final activeGrants = grantRows
        .where((row) => row['status'] == 'active')
        .toList(growable: false);
    if (activeGrants.isNotEmpty) {
      final grant = activeGrants.first;
      final grantId = grant['id'] as String?;
      final grantFamilyId = grant['family_id'] as String?;
      final grantChildId = grant['child_id'] as String?;
      if (grantId == null ||
          grantId.trim().isEmpty ||
          grantFamilyId == null ||
          grantFamilyId.trim().isEmpty ||
          grantChildId == null ||
          grantChildId.trim().isEmpty) {
        return const PairedChildUnverified(
          reason: PairedChildUnverifiedReason.grantStatusMalformedOrAmbiguous,
        );
      }

      try {
        final childRow = await _client
            .from('child_profiles')
            .select(_childColumns)
            .eq('id', grantChildId.trim())
            .eq('family_id', grantFamilyId.trim())
            .maybeSingle()
            .timeout(_timeout);

        if (childRow == null) {
          return const PairedChildUnverified(
            reason:
                PairedChildUnverifiedReason.childProfileUnavailableOrArchived,
          );
        }

        final child = _tryParseChildProfile(childRow);
        if (child == null || !child.isActive || child.isArchived) {
          return const PairedChildUnverified(
            reason:
                PairedChildUnverifiedReason.childProfileUnavailableOrArchived,
          );
        }

        final familyRow = await _client
            .from('families')
            .select(_familyColumns)
            .eq('id', grantFamilyId.trim())
            .maybeSingle()
            .timeout(_timeout);
        if (familyRow == null) {
          return const PairedChildUnverified(
            reason:
                PairedChildUnverifiedReason.childProfileUnavailableOrArchived,
          );
        }

        final family = _tryParseFamily(familyRow);
        if (family == null || family.isArchived) {
          return const PairedChildUnverified(
            reason:
                PairedChildUnverifiedReason.childProfileUnavailableOrArchived,
          );
        }

        return AuthorizedPairedChild(
          verifiedChild: child,
          verifiedFamily: family,
          grantId: grantId.trim(),
        );
      } on PostgrestException catch (e) {
        return PairedChildUnverified(
          reason: PairedChildUnverifiedReason.childProfileUnavailableOrArchived,
          diagnosticCode: e.code,
        );
      } on TimeoutException {
        return const PairedChildUnverified(
          reason: PairedChildUnverifiedReason.childProfileUnavailableOrArchived,
          diagnosticCode: 'timeout',
        );
      } catch (_) {
        return const PairedChildUnverified(
          reason: PairedChildUnverifiedReason.childProfileUnavailableOrArchived,
        );
      }
    }

    for (final row in grantRows) {
      if (row['status'] == 'revoked' && row['revoked_at'] != null) {
        final revokedAt = DateTime.tryParse(row['revoked_at'].toString())
            ?.toUtc();
        if (revokedAt != null) {
          return ConfirmedPairedChildGrantRevoked(
            revokedAt: revokedAt,
            grantId: (row['id'] as String?)?.trim(),
          );
        }
      }
    }

    return const PairedChildUnverified(
      reason: PairedChildUnverifiedReason.grantStatusMalformedOrAmbiguous,
    );
  }

  static List<Map<String, dynamic>>? _asRowList(dynamic raw) {
    if (raw is! List) {
      return null;
    }
    final rows = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is! Map) {
        return null;
      }
      rows.add(Map<String, dynamic>.from(entry));
    }
    return rows;
  }

  static Family? _tryParseFamily(Map<String, dynamic> row) {
    try {
      return Family(
        id: FamilyId((row['id'] as String).trim()),
        name: row['name'] as String,
        timezone: row['timezone'] as String,
        locale: row['locale'] as String,
        createdByUserId: row['created_by_user_id'] as String,
        createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
        archivedAt: row['archived_at'] != null
            ? DateTime.parse(row['archived_at'] as String).toUtc()
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  static ChildProfile? _tryParseChildProfile(Map<String, dynamic> row) {
    try {
      return ChildProfile(
        id: ChildId((row['id'] as String).trim()),
        familyId: FamilyId((row['family_id'] as String).trim()),
        displayName: row['display_name'] as String,
        schoolGrade: row['school_grade'] as int?,
        birthYear: row['birth_year'] as int?,
        avatarKey: row['avatar_key'] as String?,
        status: ChildProfileStatus.parse(row['status'] as String),
        createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
        archivedAt: row['archived_at'] != null
            ? DateTime.parse(row['archived_at'] as String).toUtc()
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}
