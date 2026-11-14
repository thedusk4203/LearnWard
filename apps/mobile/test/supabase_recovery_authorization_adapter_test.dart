import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learnward/app/bootstrap/supabase_auth_session_adapter.dart';
import 'package:learnward/app/bootstrap/supabase_recovery_authorization_adapter.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Configurable mock HTTP client for PostgREST request testing.
class _MockPostgrestHttpClient extends http.BaseClient {
  _MockPostgrestHttpClient();

  Map<String, dynamic>? grantRow;
  Map<String, dynamic>? childProfileRow;
  Map<String, dynamic>? membershipRow;
  bool simulateTimeout = false;
  bool simulateNetworkError = false;

  final List<http.BaseRequest> recordedRequests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    recordedRequests.add(request);

    if (simulateTimeout) {
      await Future<void>.delayed(const Duration(seconds: 10));
    }
    if (simulateNetworkError) {
      throw http.ClientException('Connection reset by peer');
    }

    final path = request.url.path;

    Map<String, dynamic>? targetRow;
    if (path.contains('child_device_grants')) {
      targetRow = grantRow;
    } else if (path.contains('child_profiles')) {
      targetRow = childProfileRow;
    } else if (path.contains('family_memberships')) {
      targetRow = membershipRow;
    }

    if (targetRow != null) {
      final body = utf8.encode(jsonEncode([targetRow]));
      return http.StreamedResponse(
        Stream.value(body),
        200,
        request: request,
        headers: {'content-type': 'application/json', 'content-range': '0-0/1'},
      );
    } else {
      final body = utf8.encode(jsonEncode([]));
      return http.StreamedResponse(
        Stream.value(body),
        200,
        request: request,
        headers: {'content-type': 'application/json', 'content-range': '*/0'},
      );
    }
  }
}

void main() {
  group('SupabaseRecoveryAuthorizationAdapter Production Contract (H01, H05)', () {
    late _MockPostgrestHttpClient mockHttp;
    late SupabaseClient client;
    late SupabaseRecoveryAuthorizationAdapter adapter;

    final context = ValidatedActorContext(
      userId: 'usr-actor-1',
      sessionGeneration: 'gen-test-1',
      observedAt: DateTime.utc(2026, 11, 7, 12, 0, 0),
      role: 'child',
    );

    setUp(() {
      mockHttp = _MockPostgrestHttpClient();
      client = SupabaseClient(
        'https://test.supabase.co',
        'test-anon-key',
        httpClient: mockHttp,
      );
      adapter = SupabaseRecoveryAuthorizationAdapter(client);
    });

    test(
      '1. Active child device grant + active child profile returns authorized',
      () async {
        mockHttp.grantRow = {
          'family_id': 'fam-1',
          'child_id': 'ch-1',
          'auth_user_id': 'usr-actor-1',
          'status': 'active',
          'revoked_at': null,
        };
        mockHttp.childProfileRow = {
          'id': 'ch-1',
          'family_id': 'fam-1',
          'status': 'active',
        };

        final status = await adapter.verifyTarget(
          context: context,
          familyId: 'fam-1',
          childId: 'ch-1',
          operation: RewardCommandOperation.spinWheel,
        );

        expect(status, equals(TargetAuthorizationStatus.authorized));
      },
    );

    test('2. Confirmed revoked child grant (status=revoked AND revoked_at != null) returns confirmedRevoked', () async {
      mockHttp.grantRow = {
        'family_id': 'fam-1',
        'child_id': 'ch-1',
        'auth_user_id': 'usr-actor-1',
        'status': 'revoked',
        'revoked_at': '2026-11-07T12:00:00Z',
      };

      final status = await adapter.verifyTarget(
        context: context,
        familyId: 'fam-1',
        childId: 'ch-1',
        operation: RewardCommandOperation.spinWheel,
      );

      expect(status, equals(TargetAuthorizationStatus.confirmedRevoked));
    });

    test('3. Child grant revoked without revoked_at (malformed/ambiguous) fails closed to unverified', () async {
      mockHttp.grantRow = {
        'family_id': 'fam-1',
        'child_id': 'ch-1',
        'auth_user_id': 'usr-actor-1',
        'status': 'revoked',
        'revoked_at': null,
      };

      final status = await adapter.verifyTarget(
        context: context,
        familyId: 'fam-1',
        childId: 'ch-1',
        operation: RewardCommandOperation.spinWheel,
      );

      expect(status, equals(TargetAuthorizationStatus.unverified));
    });

    test(
      '4. Adult active parent membership + active child returns authorized',
      () async {
        mockHttp.grantRow = null; // No child device grant
        mockHttp.membershipRow = {
          'family_id': 'fam-1',
          'auth_user_id': 'usr-actor-1',
          'status': 'active',
          'role': 'parent',
        };
        mockHttp.childProfileRow = {
          'id': 'ch-1',
          'family_id': 'fam-1',
          'status': 'active',
        };

        final status = await adapter.verifyTarget(
          context: context,
          familyId: 'fam-1',
          childId: 'ch-1',
          operation: RewardCommandOperation.spinWheel,
        );

        expect(status, equals(TargetAuthorizationStatus.authorized));
      },
    );

    test('5. Archived child profile returns definitelyDenied', () async {
      mockHttp.grantRow = {
        'family_id': 'fam-1',
        'child_id': 'ch-1',
        'auth_user_id': 'usr-actor-1',
        'status': 'active',
        'revoked_at': null,
      };
      mockHttp.childProfileRow = {
        'id': 'ch-1',
        'family_id': 'fam-1',
        'status': 'archived',
      };

      final status = await adapter.verifyTarget(
        context: context,
        familyId: 'fam-1',
        childId: 'ch-1',
        operation: RewardCommandOperation.spinWheel,
      );

      expect(status, equals(TargetAuthorizationStatus.definitelyDenied));
    });

    test('6. Revoked adult membership returns definitelyDenied', () async {
      mockHttp.grantRow = null;
      mockHttp.membershipRow = {
        'family_id': 'fam-1',
        'auth_user_id': 'usr-actor-1',
        'status': 'revoked',
        'role': 'parent',
      };

      final status = await adapter.verifyTarget(
        context: context,
        familyId: 'fam-1',
        childId: 'ch-1',
        operation: RewardCommandOperation.spinWheel,
      );

      expect(status, equals(TargetAuthorizationStatus.definitelyDenied));
    });

    test(
      '7. Network error / HTTP exception returns unverified fail-closed',
      () async {
        mockHttp.simulateNetworkError = true;

        final status = await adapter.verifyTarget(
          context: context,
          familyId: 'fam-1',
          childId: 'ch-1',
          operation: RewardCommandOperation.spinWheel,
        );

        expect(status, equals(TargetAuthorizationStatus.unverified));
      },
    );

    test('8. RLS filter hides rows (empty response) returns unverified fail-closed (NEVER authorized)', () async {
      mockHttp.grantRow = null;
      mockHttp.membershipRow = null;
      mockHttp.childProfileRow = null;

      final status = await adapter.verifyTarget(
        context: context,
        familyId: 'fam-other',
        childId: 'ch-other',
        operation: RewardCommandOperation.spinWheel,
      );

      expect(status, equals(TargetAuthorizationStatus.unverified));
    });
  });

  group('SupabaseRecoveryAuthorizationAdapter.verifyAssessmentTarget (WP3)', () {
    late _MockPostgrestHttpClient mockHttp;
    late SupabaseClient client;
    late SupabaseRecoveryAuthorizationAdapter adapter;

    final parentContext = ValidatedActorContext(
      userId: 'usr-parent-1',
      sessionGeneration: 'gen-parent-1',
      observedAt: DateTime.utc(2026, 11, 14, 12, 0, 0),
      role: 'parent',
    );

    setUp(() {
      mockHttp = _MockPostgrestHttpClient();
      client = SupabaseClient(
        'https://test.supabase.co',
        'test-anon-key',
        httpClient: mockHttp,
      );
      adapter = SupabaseRecoveryAuthorizationAdapter(client);
    });

    test('authorized active parent and active child returns authorized with VerifiedAdultRole.parent', () async {
      mockHttp.grantRow = null;
      mockHttp.membershipRow = {
        'family_id': 'fam-1',
        'auth_user_id': 'usr-parent-1',
        'status': 'active',
        'role': 'parent',
      };
      mockHttp.childProfileRow = {
        'id': 'ch-1',
        'family_id': 'fam-1',
        'status': 'active',
      };

      final res = await adapter.verifyAssessmentTarget(
        context: parentContext,
        familyId: 'fam-1',
        childId: 'ch-1',
      );

      expect(res.status, TargetAuthorizationStatus.authorized);
      expect(res.verifiedRole, VerifiedAdultRole.parent);
      expect(
        res.reason,
        AdultTargetVerificationReason.authorizedActiveAdultAndChild,
      );
    });

    test(
      'revoked child grant with revoked_at returns confirmedRevoked',
      () async {
        mockHttp.grantRow = {
          'family_id': 'fam-1',
          'child_id': 'ch-1',
          'auth_user_id': 'usr-parent-1',
          'status': 'revoked',
          'revoked_at': '2026-11-14T11:00:00Z',
        };

        final res = await adapter.verifyAssessmentTarget(
          context: parentContext,
          familyId: 'fam-1',
          childId: 'ch-1',
        );

        expect(res.status, TargetAuthorizationStatus.confirmedRevoked);
        expect(res.verifiedRole, isNull);
      },
    );

    test(
      'archived child profile returns definitelyDenied(childConfirmedArchived)',
      () async {
        mockHttp.grantRow = null;
        mockHttp.membershipRow = {
          'family_id': 'fam-1',
          'auth_user_id': 'usr-parent-1',
          'status': 'active',
          'role': 'parent',
        };
        mockHttp.childProfileRow = {
          'id': 'ch-1',
          'family_id': 'fam-1',
          'status': 'archived',
        };

        final res = await adapter.verifyAssessmentTarget(
          context: parentContext,
          familyId: 'fam-1',
          childId: 'ch-1',
        );

        expect(res.status, TargetAuthorizationStatus.definitelyDenied);
        expect(
          res.reason,
          AdultTargetVerificationReason.childConfirmedArchived,
        );
      },
    );

    test('revoked or non-adult family membership returns definitelyDenied(adultMembershipRevokedOrNonAdult)', () async {
      mockHttp.grantRow = null;
      mockHttp.membershipRow = {
        'family_id': 'fam-1',
        'auth_user_id': 'usr-parent-1',
        'status': 'revoked',
        'role': 'parent',
      };

      final resRevoked = await adapter.verifyAssessmentTarget(
        context: parentContext,
        familyId: 'fam-1',
        childId: 'ch-1',
      );
      expect(resRevoked.status, TargetAuthorizationStatus.definitelyDenied);
      expect(
        resRevoked.reason,
        AdultTargetVerificationReason.adultMembershipRevokedOrNonAdult,
      );

      mockHttp.membershipRow = {
        'family_id': 'fam-1',
        'auth_user_id': 'usr-parent-1',
        'status': 'active',
        'role': 'child',
      };
      final resNonAdult = await adapter.verifyAssessmentTarget(
        context: parentContext,
        familyId: 'fam-1',
        childId: 'ch-1',
      );
      expect(resNonAdult.status, TargetAuthorizationStatus.definitelyDenied);
      expect(
        resNonAdult.reason,
        AdultTargetVerificationReason.adultMembershipRevokedOrNonAdult,
      );
    });

    test('paired child session (context.role == child or active grant) returns definitelyDenied(pairedChildSessionDenied)', () async {
      final childCtx = ValidatedActorContext(
        userId: 'usr-child-1',
        sessionGeneration: 'gen-child-1',
        observedAt: DateTime.utc(2026, 11, 14, 12, 0, 0),
        role: 'child',
      );
      final resRole = await adapter.verifyAssessmentTarget(
        context: childCtx,
        familyId: 'fam-1',
        childId: 'ch-1',
      );
      expect(resRole.status, TargetAuthorizationStatus.definitelyDenied);
      expect(
        resRole.reason,
        AdultTargetVerificationReason.pairedChildSessionDenied,
      );

      mockHttp.grantRow = {
        'family_id': 'fam-1',
        'child_id': 'ch-1',
        'auth_user_id': 'usr-parent-1',
        'status': 'active',
        'revoked_at': null,
      };
      final resGrant = await adapter.verifyAssessmentTarget(
        context: parentContext,
        familyId: 'fam-1',
        childId: 'ch-1',
      );
      expect(resGrant.status, TargetAuthorizationStatus.definitelyDenied);
      expect(
        resGrant.reason,
        AdultTargetVerificationReason.pairedChildSessionDenied,
      );
    });

    test(
      'inconsistent role claim returns definitelyDenied(inconsistentRoleClaim)',
      () async {
        mockHttp.grantRow = null;
        mockHttp.membershipRow = {
          'family_id': 'fam-1',
          'auth_user_id': 'usr-parent-1',
          'status': 'active',
          'role': 'parent',
        };
        final claimedOwnerCtx = ValidatedActorContext(
          userId: 'usr-parent-1',
          sessionGeneration: 'gen-parent-1',
          observedAt: DateTime.utc(2026, 11, 14, 12, 0, 0),
          role: 'owner',
        );

        final res = await adapter.verifyAssessmentTarget(
          context: claimedOwnerCtx,
          familyId: 'fam-1',
          childId: 'ch-1',
        );
        expect(res.status, TargetAuthorizationStatus.definitelyDenied);
        expect(res.reason, AdultTargetVerificationReason.inconsistentRoleClaim);
      },
    );

    test('missing membership, missing child row, and transport failures fail closed as unverified', () async {
      mockHttp.grantRow = null;
      mockHttp.membershipRow = null;
      mockHttp.childProfileRow = null;

      final missingMember = await adapter.verifyAssessmentTarget(
        context: parentContext,
        familyId: 'fam-1',
        childId: 'ch-1',
      );
      expect(missingMember.status, TargetAuthorizationStatus.unverified);
      expect(
        missingMember.reason,
        AdultTargetVerificationReason.missingOrUnverifiedMembership,
      );

      mockHttp.membershipRow = {
        'family_id': 'fam-1',
        'auth_user_id': 'usr-parent-1',
        'status': 'active',
        'role': 'owner',
      };
      mockHttp.childProfileRow = null;
      final ownerContext = ValidatedActorContext(
        userId: 'usr-parent-1',
        sessionGeneration: 'gen-parent-1',
        observedAt: DateTime.utc(2026, 11, 14, 12, 0, 0),
        role: 'owner',
      );
      final missingChild = await adapter.verifyAssessmentTarget(
        context: ownerContext,
        familyId: 'fam-1',
        childId: 'ch-1',
      );
      expect(missingChild.status, TargetAuthorizationStatus.unverified);
      expect(
        missingChild.reason,
        AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
      );

      mockHttp.simulateNetworkError = true;
      final networkFail = await adapter.verifyAssessmentTarget(
        context: ownerContext,
        familyId: 'fam-1',
        childId: 'ch-1',
      );
      expect(networkFail.status, TargetAuthorizationStatus.unverified);
      expect(
        networkFail.reason,
        AdultTargetVerificationReason.transientVerificationFailure,
      );
    });
  });

  group('SupabaseAuthSessionAdapter Stream Error Fail-Closed Contract (R24-2-01, R24-3-07, A21, M04)', () {
    test(
      'validateForMutation returns null when client has no session',
      () async {
        final client = SupabaseClient(
          'https://test.supabase.co',
          'test-anon-key',
        );
        final adapter = SupabaseAuthSessionAdapter(client);
        addTearDown(adapter.dispose);

        expect(adapter.currentSessionGeneration, isNull);
        final validated = await adapter.validateForMutation();
        expect(validated, isNull);
      },
    );

    test('R24-3-07: validateForMutation fails closed when cached session does not match bound identity', () async {
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-anon-key',
      );
      final authStreamController = StreamController<AuthState>.broadcast();
      addTearDown(authStreamController.close);

      final user1 = User(
        id: 'user-r24-bound-1',
        appMetadata: {'role': 'parent'},
        userMetadata: {},
        aud: 'authenticated',
        createdAt: DateTime.now().toIso8601String(),
      );
      final session1 = Session(
        accessToken: 'token-bound-1',
        tokenType: 'bearer',
        user: user1,
        expiresIn: 3600,
      );
      Session? liveSession = session1;

      final authAdapter = SupabaseAuthSessionAdapter(
        client,
        authStateStream: authStreamController.stream,
        currentSessionProvider: () => liveSession,
      );
      addTearDown(authAdapter.dispose);

      // Initially matches bound session identity
      expect(
        authAdapter.currentSessionGeneration,
        equals('gen-user-r24-bound-1-1'),
      );
      final valid = await authAdapter.validateForMutation();
      expect(valid, isNotNull);
      expect(valid!.userId, equals('user-r24-bound-1'));

      // Live session accessToken changed before stream event is delivered
      final mismatchedSession = Session(
        accessToken: 'token-new-before-stream-event',
        tokenType: 'bearer',
        user: user1,
        expiresIn: 3600,
      );
      liveSession = mismatchedSession;

      // validateForMutation strictly fails closed on identity mismatch!
      final resultOnMismatch = await authAdapter.validateForMutation();
      expect(
        resultOnMismatch,
        isNull,
        reason: 'Live session mismatch with bound session must fail closed',
      );
      expect(authAdapter.currentSessionGeneration, isNull);

      // When the stream event arrives for the new session, generation rotates to epoch 2
      authStreamController.add(
        AuthState(AuthChangeEvent.tokenRefreshed, mismatchedSession),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        authAdapter.currentSessionGeneration,
        equals('gen-user-r24-bound-1-2'),
      );
      final recovered = await authAdapter.validateForMutation();
      expect(recovered, isNotNull);
      expect(recovered!.sessionGeneration, equals('gen-user-r24-bound-1-2'));
    });

    test('R24-2-01: stream error with cached non-expired session fails closed sticky without resurrection', () async {
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-anon-key',
      );
      final authStreamController = StreamController<AuthState>.broadcast();
      addTearDown(authStreamController.close);

      final user = User(
        id: 'user-r24-1',
        appMetadata: {'role': 'parent'},
        userMetadata: {},
        aud: 'authenticated',
        createdAt: DateTime.now().toIso8601String(),
      );
      final sessionV1 = Session(
        accessToken: 'token-v1-abc',
        tokenType: 'bearer',
        user: user,
        expiresIn: 3600,
      );
      Session? cachedSession = sessionV1;

      final authAdapter = SupabaseAuthSessionAdapter(
        client,
        authStateStream: authStreamController.stream,
        currentSessionProvider: () => cachedSession,
      );
      addTearDown(authAdapter.dispose);

      // 1. Initial valid state with monotonic epoch 1
      expect(authAdapter.currentSessionGeneration, equals('gen-user-r24-1-1'));
      final initialContext = await authAdapter.validateForMutation();
      expect(initialContext, isNotNull);
      expect(initialContext!.sessionGeneration, equals('gen-user-r24-1-1'));

      // 2. Stream error event occurs (token refresh network error or disruption)
      authStreamController.addError(
        Exception('Auth refresh failed (network disruption)'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 3. Generation is immediately invalidated
      expect(authAdapter.currentSessionGeneration, isNull);

      // 4. Critical invariant: validateForMutation MUST NOT resurrect from cached unexpired session!
      final contextAfterError = await authAdapter.validateForMutation();
      expect(
        contextAfterError,
        isNull,
        reason: 'Sticky invalid state must prevent session resurrection from cached session',
      );

      // 5. Monotonic recovery upon genuine positive refresh event
      final sessionV2 = Session(
        accessToken: 'token-v2-xyz',
        tokenType: 'bearer',
        user: user,
        expiresIn: 3600,
      );
      cachedSession = sessionV2;
      authStreamController.add(
        AuthState(AuthChangeEvent.tokenRefreshed, sessionV2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 6. Monotonically incremented epoch 2
      expect(authAdapter.currentSessionGeneration, equals('gen-user-r24-1-2'));
      final contextAfterRecovery = await authAdapter.validateForMutation();
      expect(contextAfterRecovery, isNotNull);
      expect(
        contextAfterRecovery!.sessionGeneration,
        equals('gen-user-r24-1-2'),
      );
    });
  });
}
