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
        headers: {'content-type': 'application/json'},
      );
    } else {
      final body = utf8.encode(jsonEncode([]));
      return http.StreamedResponse(
        Stream.value(body),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }
  }
}

void main() {
  group(
    'SupabaseRecoveryAuthorizationAdapter Production Contract (H01, H05)',
    () {
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

      test('1. Valid paired child grant with active child profile returns authorized', () async {
        mockHttp.grantRow = {'status': 'active', 'revoked_at': null};
        mockHttp.childProfileRow = {'status': 'active'};

        final status = await adapter.verifyTarget(
          context: context,
          familyId: 'fam-1',
          childId: 'child-1',
          operation: RewardCommandOperation.spinWheel,
        );

        expect(status, equals(TargetAuthorizationStatus.authorized));
        // Verifies exact table names queried
        expect(
          mockHttp.recordedRequests.any(
            (r) => r.url.path.contains('child_device_grants'),
          ),
          isTrue,
        );
        expect(
          mockHttp.recordedRequests.any(
            (r) => r.url.path.contains('child_profiles'),
          ),
          isTrue,
        );
      });

      test('2. Positive own-grant revocation (status=revoked AND revoked_at != null) returns confirmedRevoked (H05)', () async {
        mockHttp.grantRow = {
          'status': 'revoked',
          'revoked_at': '2026-11-07T12:00:00Z',
        };

        final status = await adapter.verifyTarget(
          context: context,
          familyId: 'fam-1',
          childId: 'child-1',
          operation: RewardCommandOperation.spinWheel,
        );

        expect(status, equals(TargetAuthorizationStatus.confirmedRevoked));
        // Child profile check skipped when positive revocation is found
        expect(
          mockHttp.recordedRequests.any(
            (r) => r.url.path.contains('child_profiles'),
          ),
          isFalse,
        );
      });

      test('3. Active child grant with archived child profile returns definitelyDenied', () async {
        mockHttp.grantRow = {'status': 'active', 'revoked_at': null};
        mockHttp.childProfileRow = {'status': 'archived'};

        final status = await adapter.verifyTarget(
          context: context,
          familyId: 'fam-1',
          childId: 'child-1',
          operation: RewardCommandOperation.spinWheel,
        );

        expect(status, equals(TargetAuthorizationStatus.definitelyDenied));
      });

      test(
        '4. Adult owner/parent membership with active child returns authorized',
        () async {
          // No child device grant
          mockHttp.grantRow = null;
          // Adult owner membership
          mockHttp.membershipRow = {'status': 'active', 'role': 'owner'};
          mockHttp.childProfileRow = {'status': 'active'};

          final adultContext = ValidatedActorContext(
            userId: 'usr-parent-1',
            sessionGeneration: 'gen-parent-1',
            observedAt: DateTime.utc(2026, 11, 7, 12, 0, 0),
            role: 'owner',
          );

          final status = await adapter.verifyTarget(
            context: adultContext,
            familyId: 'fam-1',
            childId: 'child-1',
            operation: RewardCommandOperation.redeemReward,
          );

          expect(status, equals(TargetAuthorizationStatus.authorized));
          expect(
            mockHttp.recordedRequests.any(
              (r) => r.url.path.contains('family_memberships'),
            ),
            isTrue,
          );
        },
      );

      test('5. Adult membership revoked returns definitelyDenied', () async {
        mockHttp.grantRow = null;
        mockHttp.membershipRow = {'status': 'revoked', 'role': 'parent'};

        final status = await adapter.verifyTarget(
          context: context,
          familyId: 'fam-1',
          childId: 'child-1',
          operation: RewardCommandOperation.redeemReward,
        );

        expect(status, equals(TargetAuthorizationStatus.definitelyDenied));
      });

      test(
        '6. Missing row / RLS filtered returns unverified (NEVER fail-open)',
        () async {
          mockHttp.grantRow = null;
          mockHttp.membershipRow = null;

          final status = await adapter.verifyTarget(
            context: context,
            familyId: 'fam-1',
            childId: 'child-1',
            operation: RewardCommandOperation.spinWheel,
          );

          expect(status, equals(TargetAuthorizationStatus.unverified));
        },
      );

      test(
        '7. Network error / HTTP exception returns unverified fail-closed',
        () async {
          mockHttp.simulateNetworkError = true;

          final status = await adapter.verifyTarget(
            context: context,
            familyId: 'fam-1',
            childId: 'child-1',
            operation: RewardCommandOperation.spinWheel,
          );

          expect(status, equals(TargetAuthorizationStatus.unverified));
        },
      );
    },
  );

  group(
    'SupabaseAuthSessionAdapter Stream Error Fail-Closed Contract (A21, M04)',
    () {
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
    },
  );
}
