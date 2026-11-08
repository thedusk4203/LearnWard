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
  const SupabaseRecoveryAuthorizationAdapter(
    this._client, {
    this._activeFamilyIdProvider,
  });

  final SupabaseClient _client;
  final String? Function()? _activeFamilyIdProvider;

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) async {
    try {
      // 0. Enforce active UI family match if active family provider is bound
      if (_activeFamilyIdProvider != null) {
        final currentActiveFamily = _activeFamilyIdProvider();
        if (currentActiveFamily != null && currentActiveFamily != familyId) {
          return TargetAuthorizationStatus.definitelyDenied;
        }
      }

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
}
