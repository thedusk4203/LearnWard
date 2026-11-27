import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/cold_start_containment_bootstrap.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/app/bootstrap/supabase_auth_session_adapter.dart';
import 'package:learnward/app/bootstrap/supabase_containment_authorization_verifier.dart';
import 'package:learnward/features/auth/presentation/auth_screen.dart';
import 'package:learnward/features/family/presentation/create_family_screen.dart';
import 'package:learnward/features/shared_device/domain/parent_gate_service.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

class _PresetFamilyNotifier extends ActiveFamilyNotifier {
  _PresetFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

class _PostgrestTableReply {
  const _PostgrestTableReply.rows(this.rows)
    : statusCode = 200,
      errorBody = null;

  const _PostgrestTableReply.error({
    required this.statusCode,
    required this.errorBody,
  }) : rows = const [];

  final List<Map<String, dynamic>> rows;
  final int statusCode;
  final Map<String, dynamic>? errorBody;
}

class _ConfigurablePostgrestHttpClient extends http.BaseClient {
  final Map<String, _PostgrestTableReply> repliesByTable = {};
  final Set<String> timeoutTables = {};
  final Set<String> networkErrorTables = {};
  final List<http.BaseRequest> recordedRequests = [];

  void setRows(String table, List<Map<String, dynamic>> rows) {
    repliesByTable[table] = _PostgrestTableReply.rows(rows);
  }

  void set42501(String table) {
    repliesByTable[table] = const _PostgrestTableReply.error(
      statusCode: 403,
      errorBody: {
        'code': '42501',
        'message': 'permission denied for relation',
        'details': null,
        'hint': null,
      },
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    recordedRequests.add(request);
    final path = request.url.path;

    String? table;
    for (final candidate in const [
      'child_device_grants',
      'family_memberships',
      'families',
      'child_profiles',
    ]) {
      if (path.contains(candidate)) {
        table = candidate;
        break;
      }
    }

    if (table != null && timeoutTables.contains(table)) {
      await Future<void>.delayed(const Duration(seconds: 10));
    }
    if (table != null && networkErrorTables.contains(table)) {
      throw http.ClientException('Simulated socket disconnect on $table');
    }

    final reply = table != null
        ? repliesByTable[table]
        : const _PostgrestTableReply.rows([]);
    final effectiveReply = reply ?? const _PostgrestTableReply.rows([]);

    if (effectiveReply.errorBody != null) {
      final body = utf8.encode(jsonEncode(effectiveReply.errorBody));
      return http.StreamedResponse(
        Stream.value(body),
        effectiveReply.statusCode,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }

    final isSingleObject =
        request.headers['Accept'] == 'application/vnd.pgrst.object+json';
    final dynamic payload = isSingleObject
        ? (effectiveReply.rows.isNotEmpty ? effectiveReply.rows.first : null)
        : effectiveReply.rows;
    final body = utf8.encode(jsonEncode(payload));
    return http.StreamedResponse(
      Stream.value(body),
      200,
      request: request,
      headers: {
        'content-type': 'application/json',
        'content-range': effectiveReply.rows.isEmpty
            ? '*/0'
            : '0-${effectiveReply.rows.length - 1}/${effectiveReply.rows.length}',
      },
    );
  }
}

void _ensureSqliteInitialized() {
  if (Platform.isWindows) {
    try {
      DynamicLibrary.open('sqlite3.dll');
    } catch (_) {
      for (final candidate in [
        File('.dart_tool/lib/sqlite3.dll'),
        File('../../.dart_tool/lib/sqlite3.dll'),
        File('../.dart_tool/lib/sqlite3.dll'),
      ]) {
        if (candidate.existsSync()) {
          try {
            DynamicLibrary.open(candidate.absolute.path);
            break;
          } catch (_) {}
        }
      }
    }
  } else if (Platform.isLinux) {
    try {
      DynamicLibrary.open('libsqlite3.so');
    } catch (_) {
      try {
        DynamicLibrary.open('libsqlite3.so.0');
      } catch (_) {}
    }
  }
}

String _encodeJwtWithPayload(Map<String, dynamic> payload) {
  final headerB64 = base64Url
      .encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})))
      .replaceAll('=', '');
  final payloadB64 = base64Url
      .encode(utf8.encode(jsonEncode(payload)))
      .replaceAll('=', '');
  return '$headerB64.$payloadB64.sig';
}

void main() {
  setUpAll(_ensureSqliteInitialized);

  final nowUtc = DateTime.utc(2026, 11, 25, 14, 0);
  final testFamily = Family(
    id: FamilyId('fam-secret-a'),
    name: 'Secret Miller Family',
    timezone: 'UTC',
    locale: 'en_US',
    createdByUserId: 'adult-a',
    createdAt: DateTime.utc(2026, 10, 31),
  );
  final testFamilyB = Family(
    id: FamilyId('fam-b'),
    name: 'Family B',
    timezone: 'UTC',
    locale: 'en_US',
    createdByUserId: 'adult-b',
    createdAt: DateTime.utc(2026, 10, 31),
  );
  final testChild = ChildProfile(
    id: ChildId('child-secret-a'),
    familyId: testFamily.id,
    displayName: 'Maya Secret',
    schoolGrade: 5,
    birthYear: 2015,
    avatarKey: 'avatar-fox',
    createdAt: DateTime.utc(2026, 10, 31),
  );

  Map<String, dynamic> familyRow(Family f) => {
    'id': f.id.value,
    'name': f.name,
    'timezone': f.timezone,
    'locale': f.locale,
    'created_by_user_id': f.createdByUserId,
    'created_at': f.createdAt.toUtc().toIso8601String(),
    'archived_at': f.archivedAt?.toUtc().toIso8601String(),
  };

  Map<String, dynamic> childRow(ChildProfile c, {String? statusOverride}) => {
    'id': c.id.value,
    'family_id': c.familyId.value,
    'display_name': c.displayName,
    'school_grade': c.schoolGrade,
    'birth_year': c.birthYear,
    'avatar_key': c.avatarKey,
    'status': statusOverride ?? c.status.wireName,
    'created_at': c.createdAt.toUtc().toIso8601String(),
    'archived_at': c.archivedAt?.toUtc().toIso8601String(),
  };

  group('WP2 Part A: Trusted isAnonymous Propagation', () {
    test('SupabaseAuthSessionAdapter propagates user.isAnonymous and JWT is_anonymous claim', () async {
      final client = SupabaseClient('https://test.supabase.co', 'anon-key');
      final streamController = StreamController<AuthState>.broadcast();
      addTearDown(streamController.close);

      final anonUser = User(
        id: 'anon-child-1',
        appMetadata: const {'role': 'owner'},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: nowUtc.toIso8601String(),
        isAnonymous: true,
      );
      Session? currentSession = Session(
        accessToken: 'synthetic-non-jwt-token',
        tokenType: 'bearer',
        user: anonUser,
        expiresIn: 3600,
      );

      final adapter = SupabaseAuthSessionAdapter(
        client,
        clock: FixedClock(nowUtc),
        authStateStream: streamController.stream,
        currentSessionProvider: () => currentSession,
      );
      addTearDown(adapter.dispose);

      final ctxFromFlag = await adapter.validateForMutation();
      expect(ctxFromFlag, isNotNull);
      expect(ctxFromFlag!.isAnonymous, isTrue);

      // User.isAnonymous=false, but JWT carries is_anonymous: true
      final jwtAnonUser = User(
        id: 'jwt-anon-child-2',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: nowUtc.toIso8601String(),
        isAnonymous: false,
      );
      final jwtAnonSession = Session(
        accessToken: _encodeJwtWithPayload({
          'sub': 'jwt-anon-child-2',
          'is_anonymous': true,
        }),
        tokenType: 'bearer',
        user: jwtAnonUser,
        expiresIn: 3600,
      );
      currentSession = jwtAnonSession;
      streamController.add(AuthState(AuthChangeEvent.signedIn, jwtAnonSession));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final ctxFromJwt = await adapter.validateForMutation();
      expect(ctxFromJwt, isNotNull);
      expect(ctxFromJwt!.isAnonymous, isTrue);

      // Regular non-anonymous JWT returns isAnonymous=false
      final nonAnonSession = Session(
        accessToken: _encodeJwtWithPayload({
          'sub': 'adult-1',
          'is_anonymous': false,
        }),
        tokenType: 'bearer',
        user: User(
          id: 'adult-1',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: nowUtc.toIso8601String(),
          isAnonymous: false,
        ),
        expiresIn: 3600,
      );
      currentSession = nonAnonSession;
      streamController.add(AuthState(AuthChangeEvent.signedIn, nonAnonSession));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final ctxNonAnon = await adapter.validateForMutation();
      expect(ctxNonAnon, isNotNull);
      expect(ctxNonAnon!.isAnonymous, isFalse);
    });

    test('FakeAuthSessionPort & InMemoryAuthSessionPort preserve isAnonymous across updates', () async {
      final fake = FakeAuthSessionPort(
        activeUserId: 'child-1',
        isAnonymous: true,
      );
      expect((await fake.validateForMutation())!.isAnonymous, isTrue);
      fake.setSessionGeneration('gen-child-2');
      expect((await fake.validateForMutation())!.isAnonymous, isTrue);
      fake.switchActor('adult-2', role: 'owner', isAnonymous: false);
      expect((await fake.validateForMutation())!.isAnonymous, isFalse);

      final inMemAnon = InMemoryAuthSessionPort(
        activeUserId: 'anon-local',
        role: 'child',
        isAnonymous: true,
      );
      final inMemCtx = await inMemAnon.validateForMutation();
      expect(inMemCtx, isNotNull);
      expect(inMemCtx!.isAnonymous, isTrue);
      expect(inMemCtx.role, 'child');
    });
  });

  group('WP2 Part B: SupabaseContainmentAuthorizationVerifier Contract', () {
    late _ConfigurablePostgrestHttpClient mockHttp;
    late SupabaseContainmentAuthorizationVerifier verifier;

    setUp(() {
      mockHttp = _ConfigurablePostgrestHttpClient();
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-anon-key',
        httpClient: mockHttp,
      );
      verifier = SupabaseContainmentAuthorizationVerifier(
        client,
        clock: FixedClock(nowUtc),
        timeout: const Duration(milliseconds: 150),
      );
    });

    void expectReadOnlyQueriesOnly() {
      for (final req in mockHttp.recordedRequests) {
        expect(req.method, 'GET', reason: 'Verifier must stay strictly GET');
        expect(req.url.path, isNot(contains('/rpc/')));
      }
    }

    test('stale/expired/blank ValidatedActorContext fails closed with zero remote requests', () async {
      final expiredCtx = ValidatedActorContext(
        userId: 'adult-a',
        sessionGeneration: 'gen-1',
        observedAt: nowUtc.subtract(const Duration(minutes: 10)),
      );
      final outcome = await verifier.verifySession(context: expiredCtx);
      expect(outcome, isA<SessionAuthorizationUnverified>());
      expect(mockHttp.recordedRequests, isEmpty);
    });

    test('anonymous session fails closed to PairedChildUnverified without touching family_memberships', () async {
      mockHttp.setRows('child_device_grants', const []);
      mockHttp.setRows('family_memberships', [
        {
          'family_id': testFamily.id.value,
          'auth_user_id': 'anon-1',
          'role': 'owner',
          'status': 'active',
          'joined_at': nowUtc.toIso8601String(),
        },
      ]);

      final outcome = await verifier.verifySession(
        context: ValidatedActorContext(
          userId: 'anon-1',
          sessionGeneration: 'gen-anon-1',
          observedAt: nowUtc,
          role: 'owner',
          isAnonymous: true,
        ),
      );

      expect(outcome, isA<PairedChildUnverified>());
      expect(
        (outcome as PairedChildUnverified).reason,
        PairedChildUnverifiedReason.grantMissingForPairedIdentity,
      );
      expect(
        mockHttp.recordedRequests.any(
          (r) => r.url.path.contains('family_memberships'),
        ),
        isFalse,
      );
      expectReadOnlyQueriesOnly();
    });

    test('C0-34: active adult membership succeeds with null, authenticated, or inconsistent appMetadata.role', () async {
      for (final metaRole in <String?>[null, 'authenticated', 'parent']) {
        mockHttp.recordedRequests.clear();
        mockHttp.setRows('child_device_grants', const []);
        mockHttp.setRows('family_memberships', [
          {
            'family_id': testFamily.id.value,
            'auth_user_id': 'adult-a',
            'role': 'owner',
            'status': 'active',
            'joined_at': nowUtc.toIso8601String(),
          },
        ]);
        mockHttp.setRows('families', [familyRow(testFamily)]);

        final outcome = await verifier.verifySession(
          context: ValidatedActorContext(
            userId: 'adult-a',
            sessionGeneration: 'gen-adult-a',
            observedAt: nowUtc,
            role: metaRole,
          ),
        );

        expect(outcome, isA<AuthorizedActiveAdult>());
        final adult = outcome as AuthorizedActiveAdult;
        expect(adult.verifiedRole, VerifiedAdultRole.owner);
        expect(adult.verifiedFamily.id, testFamily.id);
        // child_device_grants MUST be queried before family_memberships
        final paths = mockHttp.recordedRequests.map((r) => r.url.path).toList();
        expect(paths.first, contains('child_device_grants'));
        expect(paths[1], contains('family_memberships'));
        expectReadOnlyQueriesOnly();
      }
    });

    test('C0-35: child_device_grants takes precedence over null or adult-like appMetadata.role', () async {
      mockHttp.setRows('child_device_grants', [
        {
          'id': 'grant-1',
          'family_id': testFamily.id.value,
          'child_id': testChild.id.value,
          'auth_user_id': 'paired-1',
          'status': 'active',
          'revoked_at': null,
        },
      ]);
      mockHttp.setRows('child_profiles', [childRow(testChild)]);
      mockHttp.setRows('families', [familyRow(testFamily)]);
      mockHttp.setRows('family_memberships', [
        {
          'family_id': testFamily.id.value,
          'auth_user_id': 'paired-1',
          'role': 'owner',
          'status': 'active',
          'joined_at': nowUtc.toIso8601String(),
        },
      ]);

      final activeGrantOutcome = await verifier.verifySession(
        context: ValidatedActorContext(
          userId: 'paired-1',
          sessionGeneration: 'gen-p1',
          observedAt: nowUtc,
          role: 'owner', // Stale or spoofed hint must never grant Parent Mode
        ),
      );
      expect(activeGrantOutcome, isA<AuthorizedPairedChild>());
      expect((activeGrantOutcome as AuthorizedPairedChild).grantId, 'grant-1');

      // Positively revoked grant with revoked_at != null -> ConfirmedPairedChildGrantRevoked
      mockHttp.setRows('child_device_grants', [
        {
          'id': 'grant-1',
          'family_id': testFamily.id.value,
          'child_id': testChild.id.value,
          'auth_user_id': 'paired-1',
          'status': 'revoked',
          'revoked_at': '2026-11-25T13:00:00Z',
        },
      ]);
      final revokedOutcome = await verifier.verifySession(
        context: ValidatedActorContext(
          userId: 'paired-1',
          sessionGeneration: 'gen-p1',
          observedAt: nowUtc,
          role: null,
        ),
      );
      expect(revokedOutcome, isA<ConfirmedPairedChildGrantRevoked>());

      // Revoked grant WITHOUT revoked_at -> PairedChildUnverified (never confirmed revocation)
      mockHttp.setRows('child_device_grants', [
        {
          'id': 'grant-1',
          'family_id': testFamily.id.value,
          'child_id': testChild.id.value,
          'auth_user_id': 'paired-1',
          'status': 'revoked',
          'revoked_at': null,
        },
      ]);
      final ambiguousGrant = await verifier.verifySession(
        context: ValidatedActorContext(
          userId: 'paired-1',
          sessionGeneration: 'gen-p1',
          observedAt: nowUtc,
        ),
      );
      expect(ambiguousGrant, isA<PairedChildUnverified>());
      expect(
        (ambiguousGrant as PairedChildUnverified).reason,
        PairedChildUnverifiedReason.grantStatusMalformedOrAmbiguous,
      );
      expectReadOnlyQueriesOnly();
    });

    test('distinguishes RLS 0-row neutrality, positive adult revocation, 42501, and network failures', () async {
      final adultCtx = ValidatedActorContext(
        userId: 'adult-x',
        sessionGeneration: 'gen-x',
        observedAt: nowUtc,
      );

      // 1. Clean 0 rows -> NoActiveFamilyMembershipObserved
      mockHttp.setRows('child_device_grants', const []);
      mockHttp.setRows('family_memberships', const []);
      expect(
        await verifier.verifySession(context: adultCtx),
        isA<NoActiveFamilyMembershipObserved>(),
      );

      // 2. Positive revoked membership -> ConfirmedAdultMembershipRevoked
      mockHttp.setRows('family_memberships', [
        {
          'family_id': testFamily.id.value,
          'auth_user_id': 'adult-x',
          'role': 'parent',
          'status': 'revoked',
          'joined_at': nowUtc.toIso8601String(),
        },
      ]);
      expect(
        await verifier.verifySession(context: adultCtx),
        isA<ConfirmedAdultMembershipRevoked>(),
      );

      // 3. 42501 on memberships -> SessionAuthorizationUnverified
      mockHttp.set42501('family_memberships');
      final err42501 = await verifier.verifySession(context: adultCtx);
      expect(err42501, isA<SessionAuthorizationUnverified>());
      expect(
        (err42501 as SessionAuthorizationUnverified).diagnosticCode,
        '42501',
      );

      // 4. 42501 on grants for paired child -> PairedChildUnverified(grantUncertain42501)
      mockHttp.set42501('child_device_grants');
      final paired42501 = await verifier.verifySession(
        context: ValidatedActorContext(
          userId: 'child-x',
          sessionGeneration: 'gen-c',
          observedAt: nowUtc,
          role: 'child',
        ),
      );
      expect(paired42501, isA<PairedChildUnverified>());
      expect(
        (paired42501 as PairedChildUnverified).reason,
        PairedChildUnverifiedReason.grantUncertain42501,
      );

      // 5. Socket/network disconnect on grants
      mockHttp.repliesByTable.clear();
      mockHttp.networkErrorTables.add('child_device_grants');
      expect(
        await verifier.verifySession(context: adultCtx),
        isA<SessionAuthorizationUnverified>(),
      );
      expect(
        await verifier.verifySession(
          context: ValidatedActorContext(
            userId: 'child-x',
            sessionGeneration: 'gen-c',
            observedAt: nowUtc,
            isAnonymous: true,
          ),
        ),
        isA<PairedChildUnverified>(),
      );

      // 6. Active paired grant + archived child -> PairedChildUnverified
      mockHttp.networkErrorTables.clear();
      mockHttp.setRows('child_device_grants', [
        {
          'id': 'g-1',
          'family_id': testFamily.id.value,
          'child_id': testChild.id.value,
          'auth_user_id': 'child-x',
          'status': 'active',
          'revoked_at': null,
        },
      ]);
      mockHttp.setRows('child_profiles', [
        childRow(testChild, statusOverride: 'archived'),
      ]);
      final pairedArchived = await verifier.verifySession(
        context: ValidatedActorContext(
          userId: 'child-x',
          sessionGeneration: 'gen-c',
          observedAt: nowUtc,
        ),
      );
      expect(pairedArchived, isA<PairedChildUnverified>());
      expect(
        (pairedArchived as PairedChildUnverified).reason,
        PairedChildUnverifiedReason.childProfileUnavailableOrArchived,
      );
      expectReadOnlyQueriesOnly();
    });

    test('shared-device adult detects archived child, RLS 0-row child, and cross-family mismatch', () async {
      mockHttp.setRows('child_device_grants', const []);
      mockHttp.setRows('family_memberships', [
        {
          'family_id': testFamily.id.value,
          'auth_user_id': 'adult-a',
          'role': 'owner',
          'status': 'active',
          'joined_at': nowUtc.toIso8601String(),
        },
      ]);
      mockHttp.setRows('families', [familyRow(testFamily)]);

      final adultCtx = ValidatedActorContext(
        userId: 'adult-a',
        sessionGeneration: 'gen-a',
        observedAt: nowUtc,
      );
      final persisted = PersistedChildModeSession(
        modeKind: PersistedChildModeKind.sharedDeviceAdult,
        actorUserId: 'adult-a',
        familyId: testFamily.id,
        childId: testChild.id,
        childProfileSnapshot: testChild,
        persistedAtUtc: nowUtc,
      );

      // Archived row
      mockHttp.setRows('child_profiles', [
        childRow(testChild, statusOverride: 'archived'),
      ]);
      final archived = await verifier.verifySession(
        context: adultCtx,
        persistedChildSession: persisted,
      );
      expect(archived, isA<AuthorizedAdultChildUnavailable>());
      expect(
        (archived as AuthorizedAdultChildUnavailable).reason,
        TargetChildUnavailabilityReason.confirmedArchived,
      );

      // RLS 0-row response
      mockHttp.setRows('child_profiles', const []);
      final hidden = await verifier.verifySession(
        context: adultCtx,
        persistedChildSession: persisted,
      );
      expect(hidden, isA<AuthorizedAdultChildUnavailable>());
      expect(
        (hidden as AuthorizedAdultChildUnavailable).reason,
        TargetChildUnavailabilityReason.notActiveOrRlsHidden,
      );

      // Cross-family target mismatch
      final crossFamily = await verifier.verifySession(
        context: adultCtx,
        targetFamilyId: testFamilyB.id,
        targetChildId: ChildId('child-b'),
      );
      expect(crossFamily, isA<AuthorizedAdultChildUnavailable>());
      expect(
        (crossFamily as AuthorizedAdultChildUnavailable).reason,
        TargetChildUnavailabilityReason.familyMismatch,
      );

      // Timeout on child_profiles -> SessionAuthorizationUnverified (offline contained path)
      mockHttp.timeoutTables.add('child_profiles');
      final timedOut = await verifier.verifySession(
        context: adultCtx,
        persistedChildSession: persisted,
      );
      expect(timedOut, isA<SessionAuthorizationUnverified>());
      expectReadOnlyQueriesOnly();
    });

    test('AppConfig staging & production fail closed on containmentAuthorizationVerifierProvider', () {
      for (final env in [AppEnvironment.staging, AppEnvironment.production]) {
        final container = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(
              AppConfig(
                environment: env,
                supabaseUrl: '',
                supabasePublishableKey: '',
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(
          () => container.read(containmentAuthorizationVerifierProvider),
          throwsA(
            isA<Object>().having(
              (e) => e.toString(),
              'message',
              contains('MissingSupabaseConfigurationException'),
            ),
          ),
        );
      }
    });

    test('InMemoryContainmentAuthorizationVerifier enforces 8-way semantics across anonymous, paired grants, revoked/0-row memberships & archived child', () async {
      final archivedChild = ChildProfile(
        id: ChildId('child-arch'),
        familyId: testFamily.id,
        displayName: 'Archived Child',
        status: ChildProfileStatus.archived,
        createdAt: DateTime.utc(2026, 10, 31),
        archivedAt: nowUtc,
      );
      final famRepo = FakeFamilyRepository(
        currentUserId: 'adult-a',
        families: [testFamily],
        memberships: [
          FamilyMembership(
            familyId: testFamily.id,
            authUserId: 'adult-a',
            role: FamilyRole.owner,
            status: MembershipStatus.active,
            joinedAt: DateTime.utc(2026, 10, 31),
          ),
        ],
      );
      final childRepo = FakeChildProfileRepository(
        children: [testChild, archivedChild],
      );
      final inMemVerifier = InMemoryContainmentAuthorizationVerifier(
        familyRepository: famRepo,
        childProfileRepository: childRepo,
        clock: FixedClock(nowUtc),
        grantsByAuthUserId: {
          'paired-active': InMemoryChildDeviceGrantRecord(
            grantId: 'g-act',
            familyId: testFamily.id,
            childId: testChild.id,
            authUserId: 'paired-active',
            status: 'active',
          ),
          'paired-revoked': InMemoryChildDeviceGrantRecord(
            grantId: 'g-rev',
            familyId: testFamily.id,
            childId: testChild.id,
            authUserId: 'paired-revoked',
            status: 'revoked',
            revokedAt: nowUtc,
          ),
          'paired-malformed': InMemoryChildDeviceGrantRecord(
            grantId: 'g-mal',
            familyId: testFamily.id,
            childId: testChild.id,
            authUserId: 'paired-malformed',
            status: 'revoked',
          ),
        },
        revokedAdultUserIds: const {'adult-revoked'},
      );

      // Anonymous without grant -> PairedChildUnverified
      expect(
        await inMemVerifier.verifySession(
          context: ValidatedActorContext(
            userId: 'anon-1',
            sessionGeneration: 'gen-1',
            observedAt: nowUtc,
            isAnonymous: true,
          ),
        ),
        isA<PairedChildUnverified>(),
      );

      // Active, revoked, and malformed grants
      expect(
        await inMemVerifier.verifySession(
          context: ValidatedActorContext(
            userId: 'paired-active',
            sessionGeneration: 'gen-1',
            observedAt: nowUtc,
          ),
        ),
        isA<AuthorizedPairedChild>(),
      );
      expect(
        await inMemVerifier.verifySession(
          context: ValidatedActorContext(
            userId: 'paired-revoked',
            sessionGeneration: 'gen-1',
            observedAt: nowUtc,
          ),
        ),
        isA<ConfirmedPairedChildGrantRevoked>(),
      );
      expect(
        await inMemVerifier.verifySession(
          context: ValidatedActorContext(
            userId: 'paired-malformed',
            sessionGeneration: 'gen-1',
            observedAt: nowUtc,
          ),
        ),
        isA<PairedChildUnverified>(),
      );

      // Revoked adult -> ConfirmedAdultMembershipRevoked
      expect(
        await inMemVerifier.verifySession(
          context: ValidatedActorContext(
            userId: 'adult-revoked',
            sessionGeneration: 'gen-1',
            observedAt: nowUtc,
          ),
        ),
        isA<ConfirmedAdultMembershipRevoked>(),
      );

      // Active adult + active child vs missing/archived child
      final adultCtx = ValidatedActorContext(
        userId: 'adult-a',
        sessionGeneration: 'gen-1',
        observedAt: nowUtc,
      );
      expect(
        await inMemVerifier.verifySession(
          context: adultCtx,
          targetFamilyId: testFamily.id,
          targetChildId: testChild.id,
        ),
        isA<AuthorizedActiveAdult>(),
      );
      expect(
        await inMemVerifier.verifySession(
          context: adultCtx,
          targetFamilyId: testFamily.id,
          targetChildId: archivedChild.id,
        ),
        isA<AuthorizedAdultChildUnavailable>(),
      );

      // 0-row membership (clean empty repo) -> NoActiveFamilyMembershipObserved
      final emptyVerifier = InMemoryContainmentAuthorizationVerifier(
        familyRepository: FakeFamilyRepository(currentUserId: 'adult-new'),
        childProfileRepository: FakeChildProfileRepository(),
        clock: FixedClock(nowUtc),
      );
      expect(
        await emptyVerifier.verifySession(
          context: ValidatedActorContext(
            userId: 'adult-new',
            sessionGeneration: 'gen-1',
            observedAt: nowUtc,
          ),
        ),
        isA<NoActiveFamilyMembershipObserved>(),
      );
    });
  });

  group(
    'WP2 Part C: Fail-Closed Cold Start & Cross-User Zero-PII Widget Matrix',
    () {
      late InMemoryLocalMetadataStore db;

      const setupFence = ParentGateOperationFence(
        actorUserId: 'adult-a',
        sessionGeneration: 1,
        containmentEpoch: 1,
        expectedContainmentStatus: 'parent_mode',
        verifiedFamilyId: 'fam-secret-a',
      );

      setUp(() async {
        db = InMemoryLocalMetadataStore();
        await ParentGateService(
          db,
          clock: FixedClock(nowUtc),
          minIterations: 1000,
          configuredIterations: 1000,
          runInIsolate: false,
        ).setPin(
          '8392',
          ownerFamilyId: testFamily.id.value,
          configuredByActorUserId: 'adult-a',
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: [testFamily.id.value],
          fence: setupFence,
        );
      });

      Future<void> verifyAllSqlDataAndPhotoIntact() async {
        expect(
          await db.readMetadata(ParentGateService.credentialV2Key),
          isNotNull,
        );
      }

      testWidgets(
        'boots through Hydrating barrier before exposing Parent or Child UI, clears cached PII, and preserves SQLite/photo bytes',
        (tester) async {
          final barrier = Completer<void>();
          final verifier = FakeContainmentAuthorizationVerifier(
            barrier: barrier,
            defaultOutcome: const NoActiveFamilyMembershipObserved(),
          );
          final fakeAuth = FakeAuthSessionPort(activeUserId: 'adult-clean');

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                localMetadataStoreProvider.overrideWithValue(db),
                authSessionPortProvider.overrideWithValue(fakeAuth),
                containmentAuthorizationVerifierProvider.overrideWithValue(
                  verifier,
                ),
                // Simulate stale cached activeFamilyProvider from a previous actor
                activeFamilyProvider.overrideWith(
                  () => _PresetFamilyNotifier(testFamily),
                ),
              ],
              child: const LearnWardApp(),
            ),
          );

          await tester.pump();
          expect(
            find.byKey(const Key('containment_hydrating_screen')),
            findsOneWidget,
          );
          expect(find.text('Secret Miller Family'), findsNothing);
          expect(find.text('Parent Mode'), findsNothing);
          expect(find.text('Maya Secret'), findsNothing);

          // Complete verifier as NoActiveFamilyMembershipObserved
          barrier.complete();
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('cold_start_no_active_family_shell')),
            findsOneWidget,
          );
          expect(find.text('No Family Found'), findsOneWidget);
          expect(find.text('Secret Miller Family'), findsNothing);
          expect(find.text('Parent Mode'), findsNothing);
          expect(verifier.calls, hasLength(1));
          await verifyAllSqlDataAndPhotoIntact();
        },
      );

      testWidgets(
        'signed-out cold start with persisted v2 session opens AuthScreen without calling verifier or deleting SQLite rows',
        (tester) async {
          final persistedRaw = PersistedChildModeSession(
            modeKind: PersistedChildModeKind.sharedDeviceAdult,
            actorUserId: 'adult-a',
            familyId: testFamily.id,
            childId: testChild.id,
            childProfileSnapshot: testChild,
            persistedAtUtc: nowUtc,
          ).toJsonString();
          await db.writeMetadata(
            key: ActiveChildModeNotifier.activeSessionKey,
            value: persistedRaw,
            updatedAt: nowUtc,
          );

          final verifier = FakeContainmentAuthorizationVerifier();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                localMetadataStoreProvider.overrideWithValue(db),
                authSessionPortProvider.overrideWithValue(
                  FakeAuthSessionPort(activeUserId: null),
                ),
                containmentAuthorizationVerifierProvider.overrideWithValue(
                  verifier,
                ),
              ],
              child: const LearnWardApp(),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byType(AuthScreen), findsOneWidget);
          expect(find.text('Maya Secret'), findsNothing);
          expect(verifier.calls, isEmpty);
          expect(
            await db.readMetadata(ActiveChildModeNotifier.activeSessionKey),
            equals(persistedRaw),
          );
          await verifyAllSqlDataAndPhotoIntact();
        },
      );

      testWidgets(
        'legacy v1 and malformed child sessions stay in containmentLocked without adopting v1, upgrading to v2, or exposing PII',
        (tester) async {
          final legacyRaw = jsonEncode({
            'id': testChild.id.value,
            'family_id': testFamily.id.value,
            'display_name': testChild.displayName,
            'status': 'active',
            'created_at': testChild.createdAt.toIso8601String(),
          });

          for (final seedRaw in [legacyRaw, '{corrupt-envelope']) {
            await db.writeMetadata(
              key: ActiveChildModeNotifier.activeSessionKey,
              value: seedRaw,
              updatedAt: nowUtc,
            );

            await tester.pumpWidget(
              ProviderScope(
                key: UniqueKey(),
                overrides: [
                  localMetadataStoreProvider.overrideWithValue(db),
                  authSessionPortProvider.overrideWithValue(
                    FakeAuthSessionPort(activeUserId: 'adult-a'),
                  ),
                  containmentAuthorizationVerifierProvider.overrideWithValue(
                    FakeContainmentAuthorizationVerifier(
                      defaultOutcome: AuthorizedActiveAdult(
                        verifiedRole: VerifiedAdultRole.owner,
                        verifiedFamily: testFamily,
                        verifiedFamilies: [testFamily],
                        verifiedRolesByFamilyId: {
                          testFamily.id.value: VerifiedAdultRole.owner,
                        },
                      ),
                    ),
                  ),
                ],
                child: const LearnWardApp(),
              ),
            );
            await tester.pumpAndSettle();

            expect(
              find.byKey(const Key('cold_start_containment_locked_shell')),
              findsOneWidget,
            );
            expect(find.text('Maya Secret'), findsNothing);
            expect(find.text('Secret Miller Family'), findsNothing);
            expect(find.text('Parent Mode'), findsNothing);
            // Raw legacy/malformed envelope preserved intact, never rewritten to v2
            expect(
              await db.readMetadata(ActiveChildModeNotifier.activeSessionKey),
              equals(seedRaw),
            );
            await verifyAllSqlDataAndPhotoIntact();
          }
        },
      );

      testWidgets(
        'actor mismatch, archived/RLS-0-row child, and recovery lock stay locked with zero cross-user PII',
        (tester) async {
          final v2ActorA = PersistedChildModeSession(
            modeKind: PersistedChildModeKind.sharedDeviceAdult,
            actorUserId: 'adult-a',
            familyId: testFamily.id,
            childId: testChild.id,
            childProfileSnapshot: testChild,
            persistedAtUtc: nowUtc,
          ).toJsonString();
          await db.writeMetadata(
            key: ActiveChildModeNotifier.activeSessionKey,
            value: v2ActorA,
            updatedAt: nowUtc,
          );

          // Actor B signs in on same device -> containmentLocked, zero Family_A / child PII
          await tester.pumpWidget(
            ProviderScope(
              key: UniqueKey(),
              overrides: [
                localMetadataStoreProvider.overrideWithValue(db),
                authSessionPortProvider.overrideWithValue(
                  FakeAuthSessionPort(activeUserId: 'adult-b'),
                ),
                containmentAuthorizationVerifierProvider.overrideWithValue(
                  FakeContainmentAuthorizationVerifier(
                    defaultOutcome: AuthorizedActiveAdult(
                      verifiedRole: VerifiedAdultRole.owner,
                      verifiedFamily: testFamilyB,
                      verifiedFamilies: [testFamilyB],
                      verifiedRolesByFamilyId: {
                        testFamilyB.id.value: VerifiedAdultRole.owner,
                      },
                    ),
                  ),
                ),
              ],
              child: const LearnWardApp(),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('cold_start_containment_locked_shell')),
            findsOneWidget,
          );
          expect(find.text('Maya Secret'), findsNothing);
          expect(find.text('Secret Miller Family'), findsNothing);
          expect(find.text('Parent Mode'), findsNothing);

          // Same Actor A, but target child archived / RLS-0-row -> containmentLocked
          await tester.pumpWidget(
            ProviderScope(
              key: UniqueKey(),
              overrides: [
                localMetadataStoreProvider.overrideWithValue(db),
                authSessionPortProvider.overrideWithValue(
                  FakeAuthSessionPort(activeUserId: 'adult-a'),
                ),
                containmentAuthorizationVerifierProvider.overrideWithValue(
                  FakeContainmentAuthorizationVerifier(
                    defaultOutcome: AuthorizedAdultChildUnavailable(
                      verifiedRole: VerifiedAdultRole.owner,
                      verifiedFamily: testFamily,
                      verifiedFamilies: [testFamily],
                      verifiedRolesByFamilyId: {
                        testFamily.id.value: VerifiedAdultRole.owner,
                      },
                      reason:
                          TargetChildUnavailabilityReason.notActiveOrRlsHidden,
                      targetChildId: testChild.id,
                      targetFamilyId: testFamily.id,
                    ),
                  ),
                ),
              ],
              child: const LearnWardApp(),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('cold_start_containment_locked_shell')),
            findsOneWidget,
          );
          expect(find.text('Parent Mode'), findsNothing);
          expect(find.text('Maya Secret'), findsNothing);

          // Even without active_child_session, valid containment_recovery_lock_v1 stays locked in WP2
          await db.applyMetadataBatch([
            MetadataMutation.upsert(
              key: ParentGateService.containmentRecoveryLockV1Key,
              value: ContainmentRecoveryLockV1(
                reason: ContainmentRecoveryReason.childArchived,
                ownershipLevel: ContainmentRecoveryOwnershipLevel.boundV2,
                requiredOwnerFamilyId: testFamily.id.value,
                originActorUserId: 'adult-a',
                initiatedFromSessionGeneration: 'gen-1',
                initiatedAtUtc: nowUtc,
              ).toJsonString(),
              updatedAt: nowUtc,
            ),
            const MetadataMutation.delete(
              key: ActiveChildModeNotifier.activeSessionKey,
            ),
          ]);
          await tester.pumpWidget(
            ProviderScope(
              key: UniqueKey(),
              overrides: [
                localMetadataStoreProvider.overrideWithValue(db),
                authSessionPortProvider.overrideWithValue(
                  FakeAuthSessionPort(
                    activeUserId: 'adult-a',
                    sessionGeneration: 'gen-2',
                  ),
                ),
                containmentAuthorizationVerifierProvider.overrideWithValue(
                  FakeContainmentAuthorizationVerifier(
                    defaultOutcome: AuthorizedActiveAdult(
                      verifiedRole: VerifiedAdultRole.owner,
                      verifiedFamily: testFamily,
                      verifiedFamilies: [testFamily],
                      verifiedRolesByFamilyId: {
                        testFamily.id.value: VerifiedAdultRole.owner,
                      },
                    ),
                  ),
                ),
              ],
              child: const LearnWardApp(),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('cold_start_containment_locked_shell')),
            findsOneWidget,
          );
          await verifyAllSqlDataAndPhotoIntact();
        },
      );

      test('offline same-actor v2 child session enters offlineContainedChildMode only when non-corrupt PIN exists', () {
        final actorA = ValidatedActorContext(
          userId: 'adult-a',
          sessionGeneration: 'gen-a',
          observedAt: nowUtc,
        );
        final validV2 = PersistedChildModeSession(
          modeKind: PersistedChildModeKind.sharedDeviceAdult,
          actorUserId: 'adult-a',
          familyId: testFamily.id,
          childId: testChild.id,
          childProfileSnapshot: testChild,
          persistedAtUtc: nowUtc,
        );

        final offlineContained = resolveColdStartContainmentState(
          actorContext: actorA,
          persistedSessionResult: ValidPersistedChildModeSessionV2(
            session: validV2,
            rawJson: validV2.toJsonString(),
          ),
          recoveryLockResult: const AbsentContainmentRecoveryLock(),
          verificationOutcome: const SessionAuthorizationUnverified(
            reason: 'offline_socket_error',
          ),
          parentGateCredentialStatus: ParentGateCredentialStatus.validV2,
        );
        expect(
          offlineContained.status,
          ColdStartContainmentStatus.offlineContainedChildMode,
        );
        expect(offlineContained.verifiedChild?.id, testChild.id);
        expect(offlineContained.verifiedFamily, isNull);

        final corruptPinLock = resolveColdStartContainmentState(
          actorContext: actorA,
          persistedSessionResult: ValidPersistedChildModeSessionV2(
            session: validV2,
            rawJson: validV2.toJsonString(),
          ),
          recoveryLockResult: const AbsentContainmentRecoveryLock(),
          verificationOutcome: const SessionAuthorizationUnverified(
            reason: 'offline_socket_error',
          ),
          parentGateCredentialStatus: ParentGateCredentialStatus.corrupt,
        );
        expect(
          corruptPinLock.status,
          ColdStartContainmentStatus.containmentLocked,
        );
      });
    },
  );

  group('WP2 Part D: File-Backed SQLite Cold-Start Preservation Matrix', () {
    test('preserves 100% drafts, reward commands, photo SHA-256 bytes, PIN & legacy metadata across all cold-start transitions and reopen', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'learnward_wp2_sqlite_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbFile = File(p.join(tempDir.path, 'containment.sqlite'));
      final db = AppDatabase(NativeDatabase(dbFile));
      var closed = false;
      Future<void> closeDb() async {
        if (!closed) {
          closed = true;
          await db.close();
        }
      }

      addTearDown(closeDb);

      final evidenceFile = File(p.join(tempDir.path, 'evidence_photo.jpg'));
      final photoBytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 10, 20, 30, 40, 0xD9];
      await evidenceFile.writeAsBytes(photoBytes, flush: true);
      final expectedDigest = sha256.convert(photoBytes).toString();

      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'draft-wp2-sql-1',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          createCommandId: 'cmd-wp2-create',
          submitCommandId: 'cmd-wp2-submit',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Quarantined Math Worksheet',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 9,
          maxScore: 10,
          localCompressedPhotoPath: evidenceFile.path,
          sha256Checksum: expectedDigest,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-wp2-spin',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          createdAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await ParentGateService(
        db,
        clock: FixedClock(nowUtc),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      ).setPin(
        '8392',
        ownerFamilyId: testFamily.id.value,
        configuredByActorUserId: 'adult-a',
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: [testFamily.id.value],
        fence: const ParentGateOperationFence(
          actorUserId: 'adult-a',
          sessionGeneration: 1,
          containmentEpoch: 1,
          expectedContainmentStatus: 'parent_mode',
          verifiedFamilyId: 'fam-secret-a',
        ),
      );

      final legacyRaw = jsonEncode({
        'id': testChild.id.value,
        'family_id': testFamily.id.value,
        'display_name': testChild.displayName,
        'status': 'active',
        'created_at': testChild.createdAt.toIso8601String(),
      });
      await db.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: legacyRaw,
        updatedAt: nowUtc,
      );

      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: const NoActiveFamilyMembershipObserved(),
      );
      final fakeAuth = FakeAuthSessionPort(activeUserId: null);
      final container = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(db),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              db,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(container.dispose);

      // 1. Unauthenticated -> unauthenticated (keeps legacy lock & SQLite data)
      await container.read(coldStartContainmentProvider.notifier).rehydrate();
      expect(
        container.read(coldStartContainmentProvider).status,
        ColdStartContainmentStatus.unauthenticated,
      );

      // 2. Signed-in with legacy v1 -> containmentLocked (legacy raw intact)
      fakeAuth.setSession(userId: 'adult-a', sessionGeneration: 'gen-2');
      await container.read(coldStartContainmentProvider.notifier).rehydrate();
      expect(
        container.read(coldStartContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );
      expect(
        await db.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        equals(legacyRaw),
      );

      // 3. Revoked paired grant -> pairedChildRevoked without deleting SQLite data
      await db.applyMetadataBatch([
        const MetadataMutation.delete(
          key: ActiveChildModeNotifier.activeSessionKey,
        ),
      ]);
      verifier.defaultOutcome = ConfirmedPairedChildGrantRevoked(
        revokedAt: nowUtc,
        grantId: 'g-revoked',
      );
      await container.read(coldStartContainmentProvider.notifier).rehydrate();
      expect(
        container.read(coldStartContainmentProvider).status,
        ColdStartContainmentStatus.pairedChildRevoked,
      );

      // 4. Close and reopen file-backed SQLite and prove zero deletion
      await closeDb();
      final reopened = AppDatabase(NativeDatabase(dbFile));
      addTearDown(reopened.close);

      final draftAfter = await reopened.getLocalDraft('draft-wp2-sql-1');
      expect(draftAfter, isNotNull);
      expect(draftAfter!.sha256Checksum, expectedDigest);
      final cmdAfter = await reopened.getPendingCommand('cmd-wp2-spin');
      expect(cmdAfter, isNotNull);
      expect(
        await reopened.readMetadata(ParentGateService.credentialV2Key),
        isNotNull,
      );
      expect(
        sha256.convert(await evidenceFile.readAsBytes()).toString(),
        expectedDigest,
      );
    });
  });

  group('R40-01: Create Family from Restricted Onboarding Shell', () {
    testWidgets(
      'creates family from noActiveFamilyMembership without GoRouter, waits for positive adult verification, then enters ParentMode',
      (tester) async {
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-onboard-1',
          sessionGeneration: 'gen-onboard-1',
        );
        final createdFamily = Family(
          id: FamilyId('fam-created-1'),
          name: 'The Miller Family',
          timezone: 'UTC',
          locale: 'en_US',
          createdByUserId: 'adult-onboard-1',
          createdAt: nowUtc,
        );
        final recordingRepo = _RecordingCreateFamilyRepository(
          familyToCreate: createdFamily,
        );
        final verifier = FakeContainmentAuthorizationVerifier(
          onVerify: (call) async {
            if (recordingRepo.createFamilyCalls == 0) {
              return const NoActiveFamilyMembershipObserved();
            }
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: createdFamily,
              verifiedFamilies: [createdFamily],
              verifiedRolesByFamilyId: {
                createdFamily.id.value: VerifiedAdultRole.owner,
              },
            );
          },
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
              ),
              familyRepositoryProvider.overrideWithValue(recordingRepo),
              childProfileRepositoryProvider.overrideWithValue(
                FakeChildProfileRepository(),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('cold_start_no_active_family_shell')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('create_family_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('family_name_field')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('family_name_field')),
          'The Miller Family',
        );

        await tester.tap(find.byKey(const Key('save_family_button')));
        await tester.pumpAndSettle();

        expect(recordingRepo.createFamilyCalls, equals(1));
        expect(verifier.calls.length, greaterThanOrEqualTo(2));
        expect(find.byType(CreateFamilyScreen), findsNothing);
        expect(
          find.byKey(const Key('cold_start_no_active_family_shell')),
          findsNothing,
        );
        expect(find.text('The Miller Family'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'keeps CreateFamilyScreen non-destructive and avoids duplicate RPC if verification lags behind create_family',
      (tester) async {
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-onboard-2',
          sessionGeneration: 'gen-onboard-2',
        );
        final createdFamily = Family(
          id: FamilyId('fam-created-2'),
          name: 'Delayed Verification Family',
          timezone: 'UTC',
          locale: 'en_US',
          createdByUserId: 'adult-onboard-2',
          createdAt: nowUtc,
        );
        final recordingRepo = _RecordingCreateFamilyRepository(
          familyToCreate: createdFamily,
        );
        var allowPositiveVerification = false;
        final verifier = FakeContainmentAuthorizationVerifier(
          onVerify: (call) async {
            if (!allowPositiveVerification) {
              return const NoActiveFamilyMembershipObserved();
            }
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: createdFamily,
              verifiedFamilies: [createdFamily],
              verifiedRolesByFamilyId: {
                createdFamily.id.value: VerifiedAdultRole.owner,
              },
            );
          },
        );

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
              ),
              familyRepositoryProvider.overrideWithValue(recordingRepo),
              childProfileRepositoryProvider.overrideWithValue(
                FakeChildProfileRepository(),
              ),
            ],
            child: Consumer(
              builder: (context, ref, child) {
                container = ProviderScope.containerOf(context);
                return const LearnWardApp();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('create_family_button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('family_name_field')),
          'Delayed Verification Family',
        );

        await tester.tap(find.byKey(const Key('save_family_button')));
        await tester.pumpAndSettle();

        expect(recordingRepo.createFamilyCalls, equals(1));
        expect(container.read(activeFamilyProvider), isNull);
        expect(
          container.read(coldStartContainmentProvider).status,
          ColdStartContainmentStatus.noActiveFamilyMembership,
        );
        expect(find.textContaining('Failed to create family'), findsNothing);
        expect(
          find.byKey(const Key('create_family_verification_pending_notice')),
          findsOneWidget,
        );
        expect(find.text('Retry Verification'), findsOneWidget);

        // Navigating Back and reopening CreateFamilyScreen also preserves
        // pendingCreatedFamily and avoids duplicate create_family RPC.
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('create_family_button')));
        await tester.pumpAndSettle();
        expect(find.text('Retry Verification'), findsOneWidget);

        // Retry verification without calling create_family again
        allowPositiveVerification = true;
        await tester.tap(find.byKey(const Key('save_family_button')));
        await tester.pumpAndSettle();

        expect(recordingRepo.createFamilyCalls, equals(1));
        expect(
          container.read(coldStartContainmentProvider).status,
          ColdStartContainmentStatus.verifiedParentMode,
        );
        expect(
          container.read(activeFamilyProvider)?.id,
          equals(createdFamily.id),
        );
        expect(find.text('Delayed Verification Family'), findsOneWidget);
      },
    );

    testWidgets(
      'transitions fail-closed to authorizationUnverified if post-create verification errors without misreporting creation failure or duplicating RPC',
      (tester) async {
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-onboard-3',
          sessionGeneration: 'gen-onboard-3',
        );
        final createdFamily = Family(
          id: FamilyId('fam-created-3'),
          name: 'Network Flake Family',
          timezone: 'UTC',
          locale: 'en_US',
          createdByUserId: 'adult-onboard-3',
          createdAt: nowUtc,
        );
        final recordingRepo = _RecordingCreateFamilyRepository(
          familyToCreate: createdFamily,
        );
        var returnUnverified = false;
        final verifier = FakeContainmentAuthorizationVerifier(
          onVerify: (call) async {
            if (recordingRepo.createFamilyCalls == 0) {
              return const NoActiveFamilyMembershipObserved();
            }
            if (returnUnverified) {
              return const SessionAuthorizationUnverified(
                reason: 'post_create_network_timeout',
              );
            }
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: createdFamily,
              verifiedFamilies: [createdFamily],
              verifiedRolesByFamilyId: {
                createdFamily.id.value: VerifiedAdultRole.owner,
              },
            );
          },
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
              ),
              familyRepositoryProvider.overrideWithValue(recordingRepo),
              childProfileRepositoryProvider.overrideWithValue(
                FakeChildProfileRepository(),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('create_family_button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('family_name_field')),
          'Network Flake Family',
        );

        returnUnverified = true;
        await tester.tap(find.byKey(const Key('save_family_button')));
        await tester.pumpAndSettle();

        expect(recordingRepo.createFamilyCalls, equals(1));
        expect(find.textContaining('Failed to create family'), findsNothing);
        expect(
          find.byKey(const Key('cold_start_authorization_unverified_shell')),
          findsOneWidget,
        );

        // Retry from authorizationUnverified enters ParentMode without re-creating
        returnUnverified = false;
        await tester.tap(find.byKey(const Key('cold_start_retry_button')));
        await tester.pumpAndSettle();

        expect(recordingRepo.createFamilyCalls, equals(1));
        expect(find.text('Network Flake Family'), findsOneWidget);
      },
    );

    testWidgets(
      'prevents duplicate create_family RPC when button is tapped repeatedly while request is in flight',
      (tester) async {
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-onboard-4',
          sessionGeneration: 'gen-onboard-4',
        );
        final createdFamily = Family(
          id: FamilyId('fam-created-4'),
          name: 'Debounce Family',
          timezone: 'UTC',
          locale: 'en_US',
          createdByUserId: 'adult-onboard-4',
          createdAt: nowUtc,
        );
        final createCompleter = Completer<void>();
        final recordingRepo = _RecordingCreateFamilyRepository(
          familyToCreate: createdFamily,
          createBarrier: createCompleter,
        );
        final verifier = FakeContainmentAuthorizationVerifier(
          onVerify: (call) async {
            if (!createCompleter.isCompleted) {
              return const NoActiveFamilyMembershipObserved();
            }
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: createdFamily,
              verifiedFamilies: [createdFamily],
              verifiedRolesByFamilyId: {
                createdFamily.id.value: VerifiedAdultRole.owner,
              },
            );
          },
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(
                InMemoryLocalMetadataStore(),
              ),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
              ),
              familyRepositoryProvider.overrideWithValue(recordingRepo),
              childProfileRepositoryProvider.overrideWithValue(
                FakeChildProfileRepository(),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('create_family_button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('family_name_field')),
          'Debounce Family',
        );

        await tester.tap(find.byKey(const Key('save_family_button')));
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('save_family_button')),
          warnIfMissed: false,
        );
        await tester.pump();

        expect(recordingRepo.createFamilyCalls, equals(1));
        createCompleter.complete();
        await tester.pumpAndSettle();

        expect(recordingRepo.createFamilyCalls, equals(1));
        expect(find.text('Debounce Family'), findsOneWidget);
      },
    );

    testWidgets(
      'reports error cleanly and preserves local store when create_family RPC itself throws',
      (tester) async {
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-onboard-5',
          sessionGeneration: 'gen-onboard-5',
        );
        final store = InMemoryLocalMetadataStore();
        await store.writeMetadata(
          key: 'preserved_local_work_marker',
          value: 'keep-me',
          updatedAt: nowUtc,
        );
        final recordingRepo = _RecordingCreateFamilyRepository(
          createError: StateError('rpc_unavailable'),
        );
        final verifier = FakeContainmentAuthorizationVerifier(
          defaultOutcome: const NoActiveFamilyMembershipObserved(),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
              ),
              familyRepositoryProvider.overrideWithValue(recordingRepo),
              childProfileRepositoryProvider.overrideWithValue(
                FakeChildProfileRepository(),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('create_family_button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('family_name_field')),
          'Fail Family',
        );
        await tester.tap(find.byKey(const Key('save_family_button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('Failed to create family:'), findsOneWidget);
        expect(
          await store.readMetadata('preserved_local_work_marker'),
          equals('keep-me'),
        );
      },
    );
  });

  group('R40-02: Hardened ActiveChildModeNotifier.selectChild', () {
    test('rejects actor mismatch even when actorUserId is provided, plus unauthenticated, expired, anonymous, and paired-child actors', () async {
      final store = InMemoryLocalMetadataStore();
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: testFamily,
          verifiedFamilies: [testFamily],
          verifiedRolesByFamilyId: {
            testFamily.id.value: VerifiedAdultRole.owner,
          },
          verifiedChild: testChild,
        ),
      );

      // 1. actorUserId mismatch against validated actor
      final validAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        sessionGeneration: 'gen-a-1',
      );
      final c1 = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(store),
          authSessionPortProvider.overrideWithValue(validAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(c1.dispose);
      await expectLater(
        () => c1
            .read(activeChildModeProvider.notifier)
            .selectChild(testChild, actorUserId: 'adult-spoofed'),
        throwsStateError,
      );
      expect(c1.read(activeChildModeProvider), isNull);
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );

      // 2. Unauthenticated actor
      final unauth = FakeAuthSessionPort(activeUserId: null);
      final c2 = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(store),
          authSessionPortProvider.overrideWithValue(unauth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(c2.dispose);
      await expectLater(
        () => c2
            .read(activeChildModeProvider.notifier)
            .selectChild(testChild, actorUserId: 'adult-a'),
        throwsStateError,
      );
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );

      // 3. Expired actor context
      final expiredAuth = _ExpirableAuthSessionPort(
        context: ValidatedActorContext(
          userId: 'adult-a',
          sessionGeneration: 'gen-expired',
          observedAt: nowUtc.subtract(const Duration(minutes: 6)),
          role: 'owner',
        ),
      );
      final c3 = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          localMetadataStoreProvider.overrideWithValue(store),
          authSessionPortProvider.overrideWithValue(expiredAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(c3.dispose);
      await expectLater(
        () => c3.read(activeChildModeProvider.notifier).selectChild(testChild),
        throwsStateError,
      );

      // 4. Anonymous or child-role actor
      final anonAuth = FakeAuthSessionPort(
        activeUserId: 'anon-1',
        sessionGeneration: 'gen-anon',
        isAnonymous: true,
      );
      final c4 = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(store),
          authSessionPortProvider.overrideWithValue(anonAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(c4.dispose);
      await expectLater(
        () => c4.read(activeChildModeProvider.notifier).selectChild(testChild),
        throwsStateError,
      );

      final childRoleAuth = FakeAuthSessionPort(
        activeUserId: 'child-actor-1',
        sessionGeneration: 'gen-child',
        role: 'child',
      );
      final c5 = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(store),
          authSessionPortProvider.overrideWithValue(childRoleAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(c5.dispose);
      await expectLater(
        () => c5.read(activeChildModeProvider.notifier).selectChild(testChild),
        throwsStateError,
      );
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );
    });

    test('rejects non-adult, revoked, unverified, or child-unavailable outcomes and preserves existing lock/session records', () async {
      final store = InMemoryLocalMetadataStore();
      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        sessionGeneration: 'gen-a-1',
      );
      final verifier = FakeContainmentAuthorizationVerifier();

      final container = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(store),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(container.dispose);

      for (final rejectedOutcome in <ContainmentVerificationOutcome>[
        const NoActiveFamilyMembershipObserved(),
        const ConfirmedAdultMembershipRevoked(reason: 'revoked'),
        const SessionAuthorizationUnverified(reason: 'network_error'),
        AuthorizedAdultChildUnavailable(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: testFamily,
          verifiedFamilies: [testFamily],
          verifiedRolesByFamilyId: {
            testFamily.id.value: VerifiedAdultRole.owner,
          },
          reason: TargetChildUnavailabilityReason.confirmedArchived,
          targetChildId: testChild.id,
          targetFamilyId: testFamily.id,
        ),
        AuthorizedPairedChild(
          verifiedChild: testChild,
          verifiedFamily: testFamily,
          grantId: 'grant-1',
        ),
      ]) {
        verifier.defaultOutcome = rejectedOutcome;
        await expectLater(
          () => container
              .read(activeChildModeProvider.notifier)
              .selectChild(testChild),
          throwsStateError,
        );
        expect(container.read(activeChildModeProvider), isNull);
        expect(
          await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
          isNull,
        );
      }

      // Unresolved containment_recovery_lock_v1 blocks selection and stays intact
      verifier.defaultOutcome = AuthorizedActiveAdult(
        verifiedRole: VerifiedAdultRole.owner,
        verifiedFamily: testFamily,
        verifiedFamilies: [testFamily],
        verifiedRolesByFamilyId: {testFamily.id.value: VerifiedAdultRole.owner},
        verifiedChild: testChild,
      );
      const lockValue = '{"version":1,"state":"recovery_locked"}';
      await store.writeMetadata(
        key: ColdStartContainmentNotifier.containmentRecoveryLockV1Key,
        value: lockValue,
        updatedAt: nowUtc,
      );
      await expectLater(
        () => container
            .read(activeChildModeProvider.notifier)
            .selectChild(testChild),
        throwsStateError,
      );
      expect(
        await store.readMetadata(
          ColdStartContainmentNotifier.containmentRecoveryLockV1Key,
        ),
        equals(lockValue),
      );
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );
    });

    test('fences mid-flight session rotation during verification and commits v2 session when valid adult authorization holds', () async {
      final store = InMemoryLocalMetadataStore();
      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        sessionGeneration: 'gen-a-1',
      );
      final barrier = Completer<void>();
      final verifier = FakeContainmentAuthorizationVerifier(
        barrier: barrier,
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: testFamily,
          verifiedFamilies: [testFamily],
          verifiedRolesByFamilyId: {
            testFamily.id.value: VerifiedAdultRole.owner,
          },
          verifiedChild: testChild,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(store),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(container.dispose);

      final future = container
          .read(activeChildModeProvider.notifier)
          .selectChild(testChild, actorUserId: 'adult-a');
      await Future<void>.delayed(Duration.zero);

      // Rotate auth generation while verifySession is awaiting response
      fakeAuth.setSession(userId: 'adult-b', sessionGeneration: 'gen-b-1');
      barrier.complete();

      await expectLater(future, throwsStateError);
      expect(container.read(activeChildModeProvider), isNull);
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );

      // Valid unrotated adult succeeds
      verifier.barrier = null;
      fakeAuth.setSession(userId: 'adult-a', sessionGeneration: 'gen-a-2');
      await container
          .read(activeChildModeProvider.notifier)
          .selectChild(testChild, actorUserId: 'adult-a');
      expect(container.read(activeChildModeProvider), equals(testChild));
      final saved = await store.readMetadata(
        ActiveChildModeNotifier.activeSessionKey,
      );
      expect(saved, isNotNull);
      final parsed = PersistedChildModeSession.tryParse(saved);
      expect(parsed, isA<ValidPersistedChildModeSessionV2>());
      expect(
        (parsed as ValidPersistedChildModeSessionV2).session.actorUserId,
        equals('adult-a'),
      );
    });

    test('aborts atomic CAS commit when preCommitGuard observes session rotation inside transaction barrier', () async {
      final backingStore = InMemoryLocalMetadataStore();
      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        sessionGeneration: 'gen-a-1',
      );
      final interceptingStore = _PreGuardMutatingMetadataStore(
        backingStore,
        onBeforeGuard: () {
          fakeAuth.setSession(userId: 'adult-a', sessionGeneration: 'gen-a-2');
        },
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: testFamily,
          verifiedFamilies: [testFamily],
          verifiedRolesByFamilyId: {
            testFamily.id.value: VerifiedAdultRole.owner,
          },
          verifiedChild: testChild,
        ),
      );

      final container = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(interceptingStore),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        () => container
            .read(activeChildModeProvider.notifier)
            .selectChild(testChild, actorUserId: 'adult-a'),
        throwsStateError,
      );
      expect(container.read(activeChildModeProvider), isNull);
      expect(
        await backingStore.readMetadata(
          ActiveChildModeNotifier.activeSessionKey,
        ),
        isNull,
      );
    });
  });

  group('R40-03: Restricted Shell Sign Out & Preservation', () {
    testWidgets(
      'displays Sign Out across all 6 restricted shells, invokes restricted sign-out, clears PII, routes to AuthScreen, and preserves local containment records',
      (tester) async {
        final restrictedCases =
            <
              ({
                String name,
                Key shellKey,
                String userId,
                bool pairedHint,
                ContainmentVerificationOutcome outcome,
              })
            >[
              (
                name: 'pairedChildRevoked',
                shellKey: const Key('cold_start_paired_child_revoked_shell'),
                userId: 'child-device-user',
                pairedHint: true,
                outcome: ConfirmedPairedChildGrantRevoked(
                  revokedAt: nowUtc,
                  grantId: 'grant-revoked-1',
                ),
              ),
              (
                name: 'pairedChildUnverified',
                shellKey: const Key('cold_start_paired_child_unverified_shell'),
                userId: 'child-device-user',
                pairedHint: true,
                outcome: const PairedChildUnverified(
                  reason: PairedChildUnverifiedReason
                      .grantVerificationTimeoutOrError,
                ),
              ),
              (
                name: 'authorizationUnverified',
                shellKey: const Key(
                  'cold_start_authorization_unverified_shell',
                ),
                userId: 'adult-a',
                pairedHint: false,
                outcome: const SessionAuthorizationUnverified(
                  reason: 'offline',
                ),
              ),
              (
                name: 'adultAccessRestricted',
                shellKey: const Key('cold_start_adult_access_restricted_shell'),
                userId: 'adult-a',
                pairedHint: false,
                outcome: const ConfirmedAdultMembershipRevoked(
                  reason: 'revoked',
                ),
              ),
              (
                name: 'noActiveFamilyMembership',
                shellKey: const Key('cold_start_no_active_family_shell'),
                userId: 'adult-a',
                pairedHint: false,
                outcome: const NoActiveFamilyMembershipObserved(),
              ),
              (
                name: 'containmentLocked',
                shellKey: const Key('cold_start_containment_locked_shell'),
                userId: 'adult-a',
                pairedHint: false,
                outcome: const NoActiveFamilyMembershipObserved(),
              ),
            ];

        for (final tc in restrictedCases) {
          final store = InMemoryLocalMetadataStore();
          const lockJson = '{"version":1,"state":"recovery_locked"}';
          const pinJson = '{"version":2,"salt":"abc","hash":"def"}';
          await store.writeMetadata(
            key: ParentGateService.credentialV2Key,
            value: pinJson,
            updatedAt: nowUtc,
          );
          if (tc.name == 'containmentLocked') {
            await store.writeMetadata(
              key: ColdStartContainmentNotifier.containmentRecoveryLockV1Key,
              value: lockJson,
              updatedAt: nowUtc,
            );
          }
          final sessionJson = tc.name == 'containmentLocked'
              ? jsonEncode({
                  'id': testChild.id.value,
                  'family_id': testFamily.id.value,
                })
              : null;
          if (sessionJson != null) {
            await store.writeMetadata(
              key: ActiveChildModeNotifier.activeSessionKey,
              value: sessionJson,
              updatedAt: nowUtc,
            );
          }

          final authPort = InMemoryAuthSessionPort(
            activeUserId: tc.userId,
            sessionGeneration: 'gen-${tc.name}',
            isAnonymous: tc.pairedHint,
            role: tc.pairedHint ? 'child' : 'owner',
          );
          final verifier = FakeContainmentAuthorizationVerifier(
            defaultOutcome: tc.outcome,
          );
          var signOutCalls = 0;

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authSessionPortProvider.overrideWithValue(authPort),
                localMetadataStoreProvider.overrideWithValue(store),
                containmentAuthorizationVerifierProvider.overrideWithValue(
                  verifier,
                ),
                parentGateServiceProvider.overrideWithValue(
                  ParentGateService(store, runInIsolate: false),
                ),
                restrictedShellSignOutProvider.overrideWith((ref) {
                  return () async {
                    signOutCalls++;
                    authPort.signOut();
                  };
                }),
              ],
              child: const LearnWardApp(),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.byKey(tc.shellKey), findsOneWidget, reason: tc.name);
          expect(
            find.byKey(const Key('cold_start_sign_out_button')),
            findsOneWidget,
            reason: tc.name,
          );

          await tester.tap(find.byKey(const Key('cold_start_sign_out_button')));
          await tester.pumpAndSettle();

          expect(signOutCalls, equals(1), reason: tc.name);
          expect(await authPort.validateForMutation(), isNull, reason: tc.name);
          expect(find.byType(AuthScreen), findsOneWidget, reason: tc.name);
          expect(
            await store.readMetadata(ParentGateService.credentialV2Key),
            equals(pinJson),
            reason: tc.name,
          );
          if (tc.name == 'containmentLocked') {
            expect(
              await store.readMetadata(
                ColdStartContainmentNotifier.containmentRecoveryLockV1Key,
              ),
              equals(lockJson),
              reason: tc.name,
            );
          }
          if (sessionJson != null) {
            expect(
              await store.readMetadata(
                ActiveChildModeNotifier.activeSessionKey,
              ),
              equals(sessionJson),
              reason: tc.name,
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );

    test('restrictedShellSignOutProvider dispatches real SupabaseClient.auth.signOut() and transitions containment to unauthenticated', () async {
      final logoutRequests = <http.BaseRequest>[];
      final spyHttp = _SpyAuthHttpClient(
        userId: 'adult-signout-1',
        email: 'adult-signout-1@example.test',
        isAnonymous: false,
        onLogout: logoutRequests.add,
      );
      final client = SupabaseClient(
        'https://test.supabase.co',
        'anon-key',
        httpClient: spyHttp,
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: EmptyLocalStorage(),
        ),
      );
      addTearDown(client.dispose);

      await client.auth.signInWithPassword(
        email: 'adult-signout-1@example.test',
        password: 'secret-password',
      );
      expect(client.auth.currentSession, isNotNull);

      final store = InMemoryLocalMetadataStore();
      final container = ProviderContainer(
        overrides: [
          supabaseClientProvider.overrideWithValue(client),
          localMetadataStoreProvider.overrideWithValue(store),
          containmentAuthorizationVerifierProvider.overrideWithValue(
            FakeContainmentAuthorizationVerifier(
              defaultOutcome: const ConfirmedAdultMembershipRevoked(
                reason: 'revoked',
              ),
            ),
          ),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(store, runInIsolate: false),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(coldStartContainmentProvider.notifier).rehydrate();
      expect(
        container.read(coldStartContainmentProvider).status,
        ColdStartContainmentStatus.adultAccessRestricted,
      );

      await container
          .read(coldStartContainmentProvider.notifier)
          .signOutFromRestrictedShell();
      expect(
        logoutRequests.any((r) => r.url.path.contains('/auth/v1/logout')),
        isTrue,
      );
      expect(client.auth.currentSession, isNull);
      expect(
        container.read(coldStartContainmentProvider).status,
        ColdStartContainmentStatus.unauthenticated,
      );
    });

    test('SQLite signOutFromRestrictedShell preserves drafts, reward commands, PIN, active_child_session, lock, and evidence file across reopen', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'learnward_r40_03_sql_',
      );
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });
      final dbFile = File(p.join(tempDir.path, 'r40_03_signout.sqlite'));
      final db = AppDatabase(NativeDatabase(dbFile));
      var isClosed = false;
      Future<void> closeDb() async {
        if (!isClosed) {
          isClosed = true;
          await db.close();
        }
      }

      addTearDown(closeDb);

      final evidenceFile = File(p.join(tempDir.path, 'evidence_r40_03.jpg'));
      final photoBytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xD9];
      await evidenceFile.writeAsBytes(photoBytes, flush: true);
      final expectedDigest = sha256.convert(photoBytes).toString();

      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'draft-r40-03',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          createCommandId: 'cmd-r40-create',
          submitCommandId: 'cmd-r40-submit',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Preserved Draft Across Sign Out',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8,
          maxScore: 10,
          localCompressedPhotoPath: evidenceFile.path,
          sha256Checksum: expectedDigest,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-r40-spin',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          createdAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await ParentGateService(
        db,
        clock: FixedClock(nowUtc),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      ).setPin(
        '4829',
        ownerFamilyId: testFamily.id.value,
        configuredByActorUserId: 'adult-a',
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: [testFamily.id.value],
        fence: const ParentGateOperationFence(
          actorUserId: 'adult-a',
          sessionGeneration: 1,
          containmentEpoch: 1,
          expectedContainmentStatus: 'parent_mode',
          verifiedFamilyId: 'fam-secret-a',
        ),
      );

      final legacyRaw = jsonEncode({
        'id': testChild.id.value,
        'family_id': testFamily.id.value,
        'display_name': testChild.displayName,
        'status': 'active',
        'created_at': testChild.createdAt.toIso8601String(),
      });
      await db.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: legacyRaw,
        updatedAt: nowUtc,
      );
      const lockJson = '{"version":1,"state":"recovery_locked"}';
      await db.writeMetadata(
        key: ColdStartContainmentNotifier.containmentRecoveryLockV1Key,
        value: lockJson,
        updatedAt: nowUtc,
      );

      final port = InMemoryAuthSessionPort(activeUserId: 'adult-a');
      final container = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(db),
          authSessionPortProvider.overrideWithValue(port),
          containmentAuthorizationVerifierProvider.overrideWithValue(
            FakeContainmentAuthorizationVerifier(
              defaultOutcome: const NoActiveFamilyMembershipObserved(),
            ),
          ),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              db,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(coldStartContainmentProvider.notifier).rehydrate();
      expect(
        container.read(coldStartContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      await container
          .read(coldStartContainmentProvider.notifier)
          .signOutFromRestrictedShell();
      expect(
        container.read(coldStartContainmentProvider).status,
        ColdStartContainmentStatus.unauthenticated,
      );

      await closeDb();
      final reopened = AppDatabase(NativeDatabase(dbFile));
      addTearDown(reopened.close);

      expect(await reopened.getLocalDraft('draft-r40-03'), isNotNull);
      expect(await reopened.getPendingCommand('cmd-r40-spin'), isNotNull);
      expect(
        await reopened.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        equals(legacyRaw),
      );
      expect(
        await reopened.readMetadata(
          ColdStartContainmentNotifier.containmentRecoveryLockV1Key,
        ),
        equals(lockJson),
      );
      expect(
        await reopened.readMetadata(ParentGateService.credentialV2Key),
        isNotNull,
      );
      expect(
        sha256.convert(await evidenceFile.readAsBytes()).toString(),
        equals(expectedDigest),
      );
    });
  });

  group('R40-04: Auth Session Adapter Disposal Lifecycle', () {
    test('authSessionPortProvider disposes adapter on container disposal, rejects post-dispose events/calls, and recreates cleanly without duplicate listeners', () async {
      final session = Session(
        accessToken: _encodeJwtWithPayload({'sub': 'adult-lifecycle'}),
        tokenType: 'bearer',
        user: User(
          id: 'adult-lifecycle',
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: nowUtc.toIso8601String(),
        ),
        expiresIn: 3600,
      );

      final client = SupabaseClient(
        'https://test.supabase.co',
        'anon-key',
        authOptions: const FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: EmptyLocalStorage(),
        ),
      );
      addTearDown(client.dispose);

      final container1 = ProviderContainer(
        overrides: [supabaseClientProvider.overrideWithValue(client)],
      );
      final port1 = container1.read(
        authSessionPortProvider,
      ) as SupabaseAuthSessionAdapter;
      expect(await port1.validateForMutation(), isNull);
      container1.dispose();

      // Idempotent second dispose & post-dispose fail-closed check
      port1.dispose();
      expect(port1.currentSessionGeneration, isNull);
      expect(await port1.validateForMutation(), isNull);

      // Verify direct stream subscription cancellation & recreation count
      var activeListeners = 0;
      var cancelCalls = 0;
      late StreamController<AuthState> authStreamController;
      authStreamController = StreamController<AuthState>.broadcast(
        onListen: () => activeListeners++,
        onCancel: () {
          activeListeners--;
          cancelCalls++;
        },
      );
      addTearDown(authStreamController.close);

      var generationEvents = 0;
      final adapterA = SupabaseAuthSessionAdapter(
        client,
        clock: FixedClock(nowUtc),
        authStateStream: authStreamController.stream,
        currentSessionProvider: () => session,
      );
      final genSubA = adapterA.sessionGenerationStream.listen((_) {
        generationEvents++;
      });

      expect(activeListeners, equals(1));
      expect(
        adapterA.currentSessionGeneration,
        equals('gen-adult-lifecycle-1'),
      );

      authStreamController.add(
        AuthState(AuthChangeEvent.tokenRefreshed, session),
      );
      await Future<void>.delayed(Duration.zero);
      expect(generationEvents, equals(1));
      expect(
        adapterA.currentSessionGeneration,
        equals('gen-adult-lifecycle-2'),
      );

      await genSubA.cancel();
      adapterA.dispose();
      adapterA.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(activeListeners, equals(0));
      expect(cancelCalls, equals(1));
      expect(await adapterA.validateForMutation(), isNull);

      // Post-dispose stream emission does not throw or increment old listener
      authStreamController.add(AuthState(AuthChangeEvent.signedIn, session));
      await Future<void>.delayed(Duration.zero);
      expect(generationEvents, equals(1));

      // Recreated adapter receives exactly 1 subscription without duplicate handling
      final adapterB = SupabaseAuthSessionAdapter(
        client,
        clock: FixedClock(nowUtc),
        authStateStream: authStreamController.stream,
        currentSessionProvider: () => session,
      );
      var bEvents = 0;
      final genSubB = adapterB.sessionGenerationStream.listen((_) {
        bEvents++;
      });
      addTearDown(() async {
        await genSubB.cancel();
        adapterB.dispose();
      });

      expect(activeListeners, equals(1));
      authStreamController.add(
        AuthState(AuthChangeEvent.tokenRefreshed, session),
      );
      await Future<void>.delayed(Duration.zero);
      expect(bEvents, equals(1));
      expect(generationEvents, equals(1));
    });
  });
}

class _ExpirableAuthSessionPort implements AuthSessionPort {
  _ExpirableAuthSessionPort({required this.context});

  final ValidatedActorContext context;

  @override
  String? get currentSessionGeneration => context.sessionGeneration;

  @override
  Stream<String?> get sessionGenerationStream =>
      Stream.value(context.sessionGeneration);

  @override
  Future<ValidatedActorContext?> validateForMutation() async => context;
}

class _PreGuardMutatingMetadataStore implements LocalMetadataStore {
  _PreGuardMutatingMetadataStore(this._inner, {required this.onBeforeGuard});

  final InMemoryLocalMetadataStore _inner;
  final void Function() onBeforeGuard;

  @override
  Future<void> applyMetadataBatch(List<MetadataMutation> mutations) =>
      _inner.applyMetadataBatch(mutations);

  @override
  Future<bool> compareAndSwapMetadataBatch({
    required Map<String, String?> expectedValues,
    required List<MetadataMutation> mutations,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) {
    return _inner.compareAndSwapMetadataBatch(
      expectedValues: expectedValues,
      mutations: mutations,
      preCommitGuard: preCommitGuard,
      onBeforePreCommitGuard: () async {
        await onBeforePreCommitGuard?.call();
        onBeforeGuard();
      },
      onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
    );
  }

  @override
  Future<String?> readMetadata(String key) => _inner.readMetadata(key);

  @override
  Future<void> writeMetadata({
    required String key,
    required String value,
    required DateTime updatedAt,
  }) => _inner.writeMetadata(key: key, value: value, updatedAt: updatedAt);
}

class _RecordingCreateFamilyRepository implements FamilyRepository {
  _RecordingCreateFamilyRepository({
    this.familyToCreate,
    this.createBarrier,
    this.createError,
  });

  final Family? familyToCreate;
  final Completer<void>? createBarrier;
  final Object? createError;
  final List<Family> _createdFamilies = [];
  int createFamilyCalls = 0;

  @override
  Future<Family> createFamily({
    required String name,
    required String timezone,
    required String locale,
  }) async {
    createFamilyCalls++;
    if (createBarrier != null) {
      await createBarrier!.future;
    }
    if (createError != null) {
      throw createError!;
    }
    final family = familyToCreate!;
    _createdFamilies.add(family);
    return family;
  }

  @override
  Future<FamilyMembership?> getMyMembership(FamilyId familyId) async {
    final fam = _createdFamilies.where((f) => f.id == familyId).firstOrNull;
    if (fam == null) return null;
    return FamilyMembership(
      familyId: fam.id,
      authUserId: fam.createdByUserId,
      role: FamilyRole.owner,
      status: MembershipStatus.active,
      joinedAt: fam.createdAt,
    );
  }

  @override
  Future<List<Family>> listMyFamilies() async =>
      List.unmodifiable(_createdFamilies);
}

class _SpyAuthHttpClient extends http.BaseClient {
  _SpyAuthHttpClient({
    required this.userId,
    required this.email,
    required this.isAnonymous,
    this.onLogout,
  });

  final String userId;
  final String email;
  final bool isAnonymous;
  final void Function(http.BaseRequest request)? onLogout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.contains('/auth/v1/logout')) {
      onLogout?.call(request);
      return http.StreamedResponse(
        Stream.value(utf8.encode('{}')),
        204,
        request: request,
      );
    }

    if (request.url.path.contains('/auth/v1/token') ||
        request.url.path.contains('/auth/v1/signup')) {
      final token = _encodeJwtWithPayload({
        'sub': userId,
        'email': email,
        'role': 'authenticated',
        'is_anonymous': isAnonymous,
        'exp':
            DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000,
      });
      final body = utf8.encode(
        jsonEncode({
          'access_token': token,
          'token_type': 'bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-$userId',
          'user': {
            'id': userId,
            'aud': 'authenticated',
            'role': 'authenticated',
            'email': isAnonymous ? null : email,
            'is_anonymous': isAnonymous,
            'app_metadata': {if (isAnonymous) 'role': 'child'},
            'user_metadata': const <String, dynamic>{},
            'created_at': '2026-11-25T14:00:00Z',
          },
        }),
      );
      return http.StreamedResponse(
        Stream.value(body),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }

    return http.StreamedResponse(
      Stream.value(utf8.encode('[]')),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}
