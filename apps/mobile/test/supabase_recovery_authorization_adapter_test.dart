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

    test('9. R24-2-03: returns definitelyDenied when active family provider indicates UI family switched', () async {
      const currentActiveFamily = 'fam-active';
      final switchingAdapter = SupabaseRecoveryAuthorizationAdapter(
        client,
        activeFamilyIdProvider: () => currentActiveFamily,
      );

      // Verify target command for fam-inactive
      final status = await switchingAdapter.verifyTarget(
        context: context,
        familyId: 'fam-inactive',
        childId: 'ch-1',
        operation: RewardCommandOperation.spinWheel,
      );

      expect(status, equals(TargetAuthorizationStatus.definitelyDenied));
    });
  });

  group('SupabaseAuthSessionAdapter Stream Error Fail-Closed Contract (R24-2-01, A21, M04)', () {
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
