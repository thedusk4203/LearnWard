import 'dart:async';

import 'package:learnward_application/learnward_application.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase-backed production adapter for [RecoveryAuthorizationPort].
///
/// Strictly queries frozen database relations:
/// - `public.family_memberships(family_id, auth_user_id, role, status)`
/// - `public.child_device_grants(family_id, child_id, auth_user_id, status, revoked_at)`
/// - `public.child_profiles(id, family_id, status)`
///
/// Enforces fail-closed authorization semantics:
/// - Returns [TargetAuthorizationStatus.authorized] ONLY upon positive evidence of active
///   adult membership or active paired-child grant with an active child profile.
/// - Returns [TargetAuthorizationStatus.confirmedRevoked] ONLY upon positive proof of
///   child device grant revocation (`status = 'revoked'` AND `revoked_at IS NOT NULL`).
/// - Returns [TargetAuthorizationStatus.definitelyDenied] upon positive proof of
///   archived child or revoked adult membership.
/// - Returns [TargetAuthorizationStatus.unverified] on missing rows (RLS filtered),
///   network failures, timeouts, or ambiguous errors. NEVER fails open.
final class SupabaseRecoveryAuthorizationAdapter
    implements RecoveryAuthorizationPort {
  const SupabaseRecoveryAuthorizationAdapter(this._client);

  final SupabaseClient _client;

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) async {
    try {
      // 1. Check child device grant for the authenticated actor.
      // Under RLS policy child_device_grants_select, the actor can always select
      // its own grant row where auth_user_id = auth.uid().
      final grantResponse = await _client
          .from('child_device_grants')
          .select('status, revoked_at')
          .eq('family_id', familyId)
          .eq('child_id', childId)
          .eq('auth_user_id', context.userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (grantResponse != null) {
        final grantStatus = grantResponse['status'] as String?;
        final revokedAt = grantResponse['revoked_at'];

        // Positive evidence of device revocation
        if (grantStatus == 'revoked' && revokedAt != null) {
          return TargetAuthorizationStatus.confirmedRevoked;
        }

        if (grantStatus == 'active') {
          // Verify target child profile is active and not archived
          final childResponse = await _client
              .from('child_profiles')
              .select('status')
              .eq('id', childId)
              .eq('family_id', familyId)
              .maybeSingle()
              .timeout(const Duration(seconds: 5));

          if (childResponse != null) {
            final childStatus = childResponse['status'] as String?;
            if (childStatus == 'active') {
              return TargetAuthorizationStatus.authorized;
            }
            if (childStatus == 'archived') {
              return TargetAuthorizationStatus.definitelyDenied;
            }
          }
          return TargetAuthorizationStatus.unverified;
        }
      }

      // 2. Check family membership for adult actors (owner / parent).
      // Under RLS policy family_memberships_select, active adults can query memberships.
      final memberResponse = await _client
          .from('family_memberships')
          .select('status, role')
          .eq('family_id', familyId)
          .eq('auth_user_id', context.userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (memberResponse != null) {
        final memberStatus = memberResponse['status'] as String?;
        final role = memberResponse['role'] as String?;

        if (memberStatus == 'revoked') {
          return TargetAuthorizationStatus.definitelyDenied;
        }

        if (memberStatus == 'active' && (role == 'owner' || role == 'parent')) {
          // Verify target child profile is active
          final childResponse = await _client
              .from('child_profiles')
              .select('status')
              .eq('id', childId)
              .eq('family_id', familyId)
              .maybeSingle()
              .timeout(const Duration(seconds: 5));

          if (childResponse != null) {
            final childStatus = childResponse['status'] as String?;
            if (childStatus == 'active') {
              return TargetAuthorizationStatus.authorized;
            }
            if (childStatus == 'archived') {
              return TargetAuthorizationStatus.definitelyDenied;
            }
          }
          return TargetAuthorizationStatus.unverified;
        }
      }

      // 3. Neither active membership nor active device grant confirmed.
      // An RLS-filtered missing row is unverified, NEVER authorized. Fail closed!
      return TargetAuthorizationStatus.unverified;
    } on TimeoutException {
      return TargetAuthorizationStatus.unverified;
    } catch (_) {
      return TargetAuthorizationStatus.unverified;
    }
  }

  @override
  Future<AdultTargetAuthorizationResult> verifyAdultRedemptionTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required String redemptionId,
    required RewardCommandOperation operation,
  }) async {
    if (operation != RewardCommandOperation.fulfillReward &&
        operation != RewardCommandOperation.cancelReward) {
      return const AdultTargetAuthorizationResult.definitelyDenied(
        reason: AdultTargetVerificationReason.invalidTargetInput,
      );
    }
    if (familyId.trim().isEmpty ||
        childId.trim().isEmpty ||
        redemptionId.trim().isEmpty) {
      return const AdultTargetAuthorizationResult.definitelyDenied(
        reason: AdultTargetVerificationReason.invalidTargetInput,
      );
    }
    if (context.role == 'child') {
      return const AdultTargetAuthorizationResult.definitelyDenied(
        reason: AdultTargetVerificationReason.pairedChildSessionDenied,
      );
    }

    try {
      // 1. Reject paired-child device grants (`child_device_grants_select` allows reading own row).
      final grantResponse = await _client
          .from('child_device_grants')
          .select('status, revoked_at')
          .eq('family_id', familyId)
          .eq('auth_user_id', context.userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (grantResponse != null) {
        final grantStatus = grantResponse['status'] as String?;
        final revokedAt = grantResponse['revoked_at'];
        if (grantStatus == 'revoked' && revokedAt != null) {
          return const AdultTargetAuthorizationResult.confirmedRevoked();
        }
        return const AdultTargetAuthorizationResult.definitelyDenied(
          reason: AdultTargetVerificationReason.pairedChildSessionDenied,
        );
      }

      // 2. Positively verify active adult membership and derive authoritative role (`owner` or `parent`).
      final memberResponse = await _client
          .from('family_memberships')
          .select('status, role')
          .eq('family_id', familyId)
          .eq('auth_user_id', context.userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (memberResponse == null) {
        return const AdultTargetAuthorizationResult.unverified(
          reason: AdultTargetVerificationReason.missingOrUnverifiedMembership,
        );
      }

      final memberStatus = memberResponse['status'] as String?;
      final verifiedRole = VerifiedAdultRole.tryFromWire(
        memberResponse['role'] as String?,
      );

      if (memberStatus == 'revoked' ||
          memberStatus != 'active' ||
          verifiedRole == null) {
        return const AdultTargetAuthorizationResult.definitelyDenied(
          reason:
              AdultTargetVerificationReason.adultMembershipRevokedOrNonAdult,
        );
      }

      // If session metadata carries a non-null role claim, it must match the verified DB role.
      if (context.role != null && context.role != verifiedRole.wireValue) {
        return const AdultTargetAuthorizationResult.definitelyDenied(
          reason: AdultTargetVerificationReason.inconsistentRoleClaim,
        );
      }

      // 3. Verify target redemption belongs to (familyId, childId).
      final redemptionResponse = await _client
          .from('reward_redemptions')
          .select('id, family_id, child_id')
          .eq('id', redemptionId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (redemptionResponse != null) {
        final redFamilyId = redemptionResponse['family_id'] as String?;
        final redChildId = redemptionResponse['child_id'] as String?;
        if (redFamilyId != familyId || redChildId != childId) {
          return const AdultTargetAuthorizationResult.definitelyDenied(
            reason: AdultTargetVerificationReason.redemptionTargetMismatch,
          );
        }
      }

      // 4. Verify target child profile status (even if redemptionResponse was null, check child_profiles
      // in case observable archive status is available).
      final childResponse = await _client
          .from('child_profiles')
          .select('status')
          .eq('id', childId)
          .eq('family_id', familyId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (childResponse != null) {
        final childStatus = childResponse['status'] as String?;
        if (childStatus == 'archived') {
          return const AdultTargetAuthorizationResult.definitelyDenied(
            reason: AdultTargetVerificationReason.childConfirmedArchived,
          );
        }
        if (childStatus == 'active' && redemptionResponse != null) {
          return AdultTargetAuthorizationResult.authorized(
            verifiedRole: verifiedRole,
          );
        }
      }

      // Active adult membership was positively verified, and no network error occurred,
      // but redemptionResponse or childResponse returned null (e.g. RLS-filtered archived child or missing row).
      return const AdultTargetAuthorizationResult.unverified(
        reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
      );
    } on TimeoutException {
      return const AdultTargetAuthorizationResult.unverified(
        reason: AdultTargetVerificationReason.transientVerificationFailure,
      );
    } catch (_) {
      return const AdultTargetAuthorizationResult.unverified(
        reason: AdultTargetVerificationReason.transientVerificationFailure,
      );
    }
  }
}
