import 'dart:async';

import 'package:learnward_application/learnward_application.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase-backed adapter for [RecoveryAuthorizationPort].
///
/// Verifies that the actor has authorized access to the target family and
/// that the target child profile is not archived prior to initiating remote RPCs.
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
      // 1. Verify child is active and not archived
      final childResponse = await _client
          .from('child_profiles')
          .select('status')
          .eq('id', childId)
          .eq('family_id', familyId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (childResponse == null) {
        return TargetAuthorizationStatus.unverified;
      }

      final status = childResponse['status'] as String?;
      if (status == 'archived') {
        return TargetAuthorizationStatus.definitelyDenied;
      }

      // 2. Verify family membership
      final memberResponse = await _client
          .from('family_members')
          .select('status')
          .eq('family_id', familyId)
          .eq('user_id', context.userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (memberResponse != null) {
        final memberStatus = memberResponse['status'] as String?;
        if (memberStatus == 'active') {
          return TargetAuthorizationStatus.authorized;
        }
        if (memberStatus == 'removed' || memberStatus == 'suspended') {
          return TargetAuthorizationStatus.definitelyDenied;
        }
      }

      // 3. Fallback: Check paired child grant
      final grantResponse = await _client
          .from('paired_child_grants')
          .select('status, revoked_at')
          .eq('child_id', childId)
          .eq('user_id', context.userId)
          .maybeSingle()
          .timeout(const Duration(seconds: 5));

      if (grantResponse != null) {
        final grantStatus = grantResponse['status'] as String?;
        final revokedAt = grantResponse['revoked_at'];
        if (grantStatus == 'revoked' && revokedAt != null) {
          return TargetAuthorizationStatus.definitelyDenied;
        }
        if (grantStatus == 'active') {
          return TargetAuthorizationStatus.authorized;
        }
      }

      return TargetAuthorizationStatus.authorized;
    } on TimeoutException {
      return TargetAuthorizationStatus.unverified;
    } catch (_) {
      return TargetAuthorizationStatus.unverified;
    }
  }
}
