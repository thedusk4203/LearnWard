import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

/// Configurable mock HTTP client for Supabase Storage requests.
final class _MockStorageHttpClient extends http.BaseClient {
  _MockStorageHttpClient();

  final Map<String, List<int>> remoteStorage = {};
  final List<http.BaseRequest> recordedRequests = [];

  bool simulateUpload409 = false;
  int? customUploadErrorStatus;
  String? customUploadErrorMessage;
  bool simulateDownload403 = false;
  bool simulateDownload404 = false;
  bool simulateDownload500 = false;
  String? customDownloadErrorMessage;
  bool simulateSign500 = false;
  String? customSignErrorMessage;
  bool simulateDelete500 = false;
  String? customDeleteErrorMessage;
  bool simulateDownloadTimeout = false;
  bool simulateNetworkError = false;
  String? customNetworkErrorUri;
  List<List<int>>? chunkedDownloadChunks;
  int emittedDownloadChunkCount = 0;

  int uploadCallCount = 0;
  int downloadCallCount = 0;
  int deleteCallCount = 0;
  List<String> deletedPaths = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    recordedRequests.add(request);

    if (simulateNetworkError) {
      throw http.ClientException(
        'Simulated network error',
        customNetworkErrorUri != null
            ? Uri.parse(customNetworkErrorUri!)
            : request.url,
      );
    }
    if (simulateDownloadTimeout) {
      throw http.ClientException('Connection timed out', request.url);
    }

    final path = Uri.decodeComponent(request.url.path);
    final method = request.method.toUpperCase();

    // 1. DELETE /storage/v1/object/assessment-evidence
    if (method == 'DELETE' &&
        path.contains('/storage/v1/object/assessment-evidence')) {
      deleteCallCount++;
      if (simulateDelete500) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '500',
                'error': 'InternalError',
                'message':
                    customDeleteErrorMessage ?? 'Delete failure during test',
              }),
            ),
          ),
          500,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode([
              {'message': 'Successfully deleted'},
            ]),
          ),
        ),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }

    // 2. POST /storage/v1/object/sign/assessment-evidence/...
    if (method == 'POST' &&
        path.contains('/storage/v1/object/sign/assessment-evidence/')) {
      if (simulateSign500) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '500',
                'error': 'SigningError',
                'message':
                    customSignErrorMessage ?? 'Signing failure during test',
              }),
            ),
          ),
          500,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      final signedUrl = 'https://mock.supabase.co$path?token=mock-token';
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'signedURL': signedUrl}))),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }

    // 3. GET /storage/v1/object/... (download)
    if (method == 'GET' && path.contains('/storage/v1/object/')) {
      downloadCallCount++;
      if (simulateDownload403) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '403',
                'error': 'Unauthorized',
                'message':
                    customDownloadErrorMessage ??
                    'Access denied by Storage RLS',
              }),
            ),
          ),
          403,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      if (simulateDownload500) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '500',
                'error': 'InternalError',
                'message':
                    customDownloadErrorMessage ??
                    'Download failure during test',
              }),
            ),
          ),
          500,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      if (simulateDownload404) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '404',
                'error': 'Not Found',
                'message': 'Object not found',
              }),
            ),
          ),
          404,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }

      if (chunkedDownloadChunks != null) {
        Stream<List<int>> emitChunks() async* {
          for (final chunk in chunkedDownloadChunks!) {
            emittedDownloadChunkCount++;
            yield Uint8List.fromList(chunk);
            await Future<void>.delayed(Duration.zero);
          }
        }

        return http.StreamedResponse(
          emitChunks(),
          200,
          request: request,
          headers: {'content-type': 'image/jpeg'},
        );
      }

      // Extract storage path after bucket name
      final bucketMarker = '/assessment-evidence/';
      final idx = path.indexOf(bucketMarker);
      final itemKey = idx != -1
          ? path.substring(idx + bucketMarker.length)
          : '';

      final data = remoteStorage[itemKey];
      if (data != null) {
        return http.StreamedResponse(
          Stream.value(Uint8List.fromList(data)),
          200,
          request: request,
          headers: {
            'content-type': 'image/jpeg',
            'content-length': '${data.length}',
          },
        );
      } else {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '404',
                'error': 'Not Found',
                'message': 'Object not found',
              }),
            ),
          ),
          404,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
    }

    // 4. POST /storage/v1/object/assessment-evidence/... (upload)
    if (method == 'POST' &&
        path.contains('/storage/v1/object/assessment-evidence/')) {
      uploadCallCount++;
      if (customUploadErrorStatus != null) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '$customUploadErrorStatus',
                'error': 'StorageFailure',
                'message':
                    customUploadErrorMessage ?? 'Upload error during test',
              }),
            ),
          ),
          customUploadErrorStatus!,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      if (simulateUpload409) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '409',
                'error': 'Duplicate',
                'message': 'The resource already exists',
              }),
            ),
          ),
          409,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }

      final bucketMarker = '/assessment-evidence/';
      final idx = path.indexOf(bucketMarker);
      final itemKey = idx != -1
          ? path.substring(idx + bucketMarker.length)
          : '';

      if (request is http.MultipartRequest && request.files.isNotEmpty) {
        final file = request.files.first;
        final fileBytes = await file.finalize().toBytes();
        remoteStorage[itemKey] = fileBytes;
      } else {
        final bodyBytes = await request.finalize().toBytes();
        remoteStorage[itemKey] = bodyBytes;
      }

      return http.StreamedResponse(
        Stream.value(
          utf8.encode(jsonEncode({'Key': 'assessment-evidence/$itemKey'})),
        ),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }

    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'error': 'Unhandled mock route'}))),
      400,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  final familyId = FamilyId('10000000-0000-0000-0000-000000000001');
  final childId = ChildId('20000000-0000-0000-0000-000000000002');
  final assessmentId = AssessmentId('30000000-0000-0000-0000-000000000003');
  final evidenceId = EvidenceId('40000000-0000-0000-0000-000000000004');
  const expectedPath =
      '10000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000002/30000000-0000-0000-0000-000000000003/40000000-0000-0000-0000-000000000004.jpg';

  late _MockStorageHttpClient mockHttp;
  late SupabaseClient supabaseClient;
  late FakeAuthSessionPort fakeAuth;
  late SupabaseAssessmentEvidenceStorage storage;

  setUp(() {
    mockHttp = _MockStorageHttpClient();
    supabaseClient = SupabaseClient(
      'https://mock.supabase.co',
      'anon-key',
      httpClient: mockHttp,
    );
    fakeAuth = FakeAuthSessionPort(
      activeUserId: 'user-parent-1',
      sessionGeneration: 'gen-1',
    );
    storage = SupabaseAssessmentEvidenceStorage(
      supabaseClient,
      authSessionPort: fakeAuth,
    );
  });

  group('SupabaseAssessmentEvidenceStorage - Client Validation & Auth (R31-08 / I07)', () {
    test('enforces 10 MiB size cap and valid MIME types', () async {
      // Exceeds 10 MiB
      final oversizedBytes = List<int>.filled(10 * 1024 * 1024 + 1, 42);
      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: oversizedBytes,
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );

      // Unsupported media type
      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3],
          mediaType: 'application/pdf',
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );

      expect(mockHttp.uploadCallCount, equals(0));
    });

    test('fails closed with EvidenceStorageAuthException on unauthenticated session', () async {
      fakeAuth.signOut();

      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3, 4],
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      expect(mockHttp.uploadCallCount, equals(0));
    });

    test('fails closed with EvidenceStorageAuthException on session generation mismatch', () async {
      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3, 4],
          mediaType: 'image/jpeg',
          expectedSessionGeneration: 'stale-prior-gen',
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      expect(mockHttp.uploadCallCount, equals(0));
    });

    test(
      'fails closed with EvidenceStorageAuthException on actor switch',
      () async {
        final actorContext = ValidatedActorContext(
          userId: 'original-actor-id',
          sessionGeneration: 'gen-1',
          observedAt: DateTime.now().toUtc(),
        );

        await expectLater(
          () => storage.uploadEvidence(
            familyId: familyId,
            childId: childId,
            assessmentId: assessmentId,
            evidenceId: evidenceId,
            bytes: [1, 2, 3, 4],
            mediaType: 'image/jpeg',
            context: actorContext,
          ),
          throwsA(isA<EvidenceStorageAuthException>()),
        );

        expect(mockHttp.uploadCallCount, equals(0));
      },
    );
  });

  group('SupabaseAssessmentEvidenceStorage - Upload and 409 Byte Reconciliation (WP1)', () {
    test('fresh upload succeeds with upsert=false and records bytes', () async {
      final bytes = [10, 20, 30, 40, 50];
      final path = await storage.uploadEvidence(
        familyId: familyId,
        childId: childId,
        assessmentId: assessmentId,
        evidenceId: evidenceId,
        bytes: bytes,
        mediaType: 'image/jpeg',
      );

      expect(path, equals(expectedPath));
      expect(mockHttp.uploadCallCount, equals(1));
      expect(mockHttp.remoteStorage[expectedPath], equals(bytes));
    });

    test(
      'B1-06: 409 with identical remote bytes and size reconciles and succeeds',
      () async {
        final bytes = [1, 2, 3, 4, 5, 6, 7, 8];
        // Seed remote storage with identical bytes
        mockHttp.remoteStorage[expectedPath] = List<int>.from(bytes);
        mockHttp.simulateUpload409 = true;

        final path = await storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: bytes,
          mediaType: 'image/jpeg',
        );

        expect(path, equals(expectedPath));
        expect(mockHttp.uploadCallCount, equals(1));
        expect(mockHttp.downloadCallCount, equals(1));
        expect(mockHttp.deleteCallCount, equals(0));
      },
    );

    test('B1-07: 409 with same length but different digest throws EvidenceStorageConflictException (quarantine)', () async {
      final remoteBytes = [1, 2, 3, 4, 5, 6, 7, 8];
      final localBytes = [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        99,
      ]; // Same length, different SHA-256

      mockHttp.remoteStorage[expectedPath] = remoteBytes;
      mockHttp.simulateUpload409 = true;

      try {
        await storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: localBytes,
          mediaType: 'image/jpeg',
        );
        fail('Expected EvidenceStorageConflictException');
      } on EvidenceStorageConflictException catch (e) {
        expect(
          e.result.outcome,
          equals(EvidenceStorageReconciliationOutcome.contentConflict),
        );
        expect(e.result.storagePath, equals(expectedPath));
        expect(e.result.localByteCount, equals(remoteBytes.length));
        expect(e.result.remoteByteCount, equals(remoteBytes.length));
        expect(e.result.localSha256, isNot(equals(e.result.remoteSha256)));
      }

      // Assert Invariant I04: No remote deletion was invoked!
      expect(mockHttp.deleteCallCount, equals(0));
      expect(mockHttp.remoteStorage[expectedPath], equals(remoteBytes));
    });

    test('B1-08: 409 with different length throws EvidenceStorageConflictException', () async {
      final remoteBytes = [1, 2, 3];
      final localBytes = [1, 2, 3, 4, 5];

      mockHttp.remoteStorage[expectedPath] = remoteBytes;
      mockHttp.simulateUpload409 = true;

      try {
        await storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: localBytes,
          mediaType: 'image/jpeg',
        );
        fail('Expected EvidenceStorageConflictException');
      } on EvidenceStorageConflictException catch (e) {
        expect(
          e.result.outcome,
          equals(EvidenceStorageReconciliationOutcome.contentConflict),
        );
        expect(e.result.localByteCount, equals(5));
        expect(e.result.remoteByteCount, equals(3));
      }

      expect(mockHttp.deleteCallCount, equals(0));
      expect(mockHttp.remoteStorage[expectedPath], equals(remoteBytes));
    });

    test('B1-09: 409 followed by download 403 / RLS denial fails closed as unknown outcome', () async {
      mockHttp.remoteStorage[expectedPath] = [1, 2, 3, 4];
      mockHttp.simulateUpload409 = true;
      mockHttp.simulateDownload403 = true;

      try {
        await storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3, 4],
          mediaType: 'image/jpeg',
        );
        fail('Expected EvidenceStorageUnknownOutcomeException');
      } on EvidenceStorageUnknownOutcomeException catch (e) {
        expect(
          e.result.outcome,
          equals(EvidenceStorageReconciliationOutcome.unknownOutcome),
        );
        expect(e.result.storagePath, equals(expectedPath));
      }

      // Invariant I04 & I06: Preserves remote object, never deletes
      expect(mockHttp.deleteCallCount, equals(0));
      expect(mockHttp.remoteStorage.containsKey(expectedPath), isTrue);
    });

    test('B1-10: 409 followed by remote 404 does not authorize destructive cleanup or ID rotation', () async {
      mockHttp.simulateUpload409 = true;
      mockHttp.simulateDownload404 = true;

      try {
        await storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3, 4],
          mediaType: 'image/jpeg',
        );
        fail('Expected EvidenceStorageUnknownOutcomeException');
      } on EvidenceStorageUnknownOutcomeException catch (e) {
        expect(
          e.result.outcome,
          equals(EvidenceStorageReconciliationOutcome.unknownOutcome),
        );
      }

      expect(mockHttp.deleteCallCount, equals(0));
    });

    test('B1-11: Direct reconcileEvidence proves exact match when upload response was lost', () async {
      final bytes = [100, 101, 102, 103];
      mockHttp.remoteStorage[expectedPath] = List<int>.from(bytes);

      final result = await storage.reconcileEvidence(
        storagePath: expectedPath,
        localBytes: bytes,
      );

      expect(result, isA<MatchingBytesOutcome>());
      final match = result as MatchingBytesOutcome;
      expect(
        match.outcome,
        equals(EvidenceStorageReconciliationOutcome.matchingBytes),
      );
      expect(match.remoteBytes, equals(bytes));
      expect(match.remoteSha256, equals(computeSha256Hex(bytes)));
      expect(mockHttp.downloadCallCount, equals(1));
    });

    test(
      'downloadEvidence and getEvidenceSignedUrl succeed for authorized caller',
      () async {
        final bytes = [11, 22, 33];
        mockHttp.remoteStorage[expectedPath] = bytes;

        final downloaded = await storage.downloadEvidence(
          storagePath: expectedPath,
        );
        expect(downloaded, equals(bytes));

        final signedUrl = await storage.getEvidenceSignedUrl(
          storagePath: expectedPath,
        );
        expect(signedUrl, contains(expectedPath));
      },
    );

    test('R32-03: session change between first and second auth check in reconcileEvidence preserves AuthFailureOutcome and executes zero downloads', () async {
      final bytes = [1, 2, 3, 4, 5];
      mockHttp.remoteStorage[expectedPath] = bytes;

      // On 1st validate call (reconcile preflight): succeeds.
      // On 2nd validate call (downloadEvidence preflight): session generation changed.
      fakeAuth.onValidateForMutation = (count) {
        if (count == 2) {
          fakeAuth.setSessionGeneration('gen-changed-before-download');
        }
      };

      final result = await storage.reconcileEvidence(
        storagePath: expectedPath,
        localBytes: bytes,
      );

      // Must be AuthFailureOutcome, NOT UnknownOutcome!
      expect(result, isA<AuthFailureOutcome>());
      expect(
        result.outcome,
        equals(EvidenceStorageReconciliationOutcome.authFailure),
      );

      // Assert zero HTTP download requests executed
      expect(mockHttp.downloadCallCount, equals(0));
    });

    test('R32-04: getEvidenceSignedUrl and deleteEvidence fail closed on unauthenticated session', () async {
      fakeAuth.signOut();

      await expectLater(
        () => storage.getEvidenceSignedUrl(storagePath: expectedPath),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      await expectLater(
        () => storage.deleteEvidence(expectedPath),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      expect(mockHttp.deleteCallCount, equals(0));
    });

    test('R32-04: oversized remote download (> 10 MiB) fails closed and rejects false match', () async {
      // Seed remote storage with 10 MiB + 1 byte
      final oversizedRemote = List<int>.filled(10 * 1024 * 1024 + 1, 7);
      mockHttp.remoteStorage[expectedPath] = oversizedRemote;

      final result = await storage.reconcileEvidence(
        storagePath: expectedPath,
        localBytes: oversizedRemote,
      );

      // Reconcile must reject oversized remote object as a conflict
      expect(result, isA<ContentConflictOutcome>());
      expect(
        result.outcome,
        equals(EvidenceStorageReconciliationOutcome.contentConflict),
      );
      expect(
        (result as ContentConflictOutcome).reason,
        contains('exceeds maximum allowed size'),
      );

      // downloadEvidence must also reject oversized object
      await expectLater(
        () => storage.downloadEvidence(storagePath: expectedPath),
        throwsA(isA<EvidenceStorageConflictException>()),
      );
    });

    test('R32-04 / R32-07: privacy & redaction: message, toString(), and outcomes never leak paths, bearer tokens, JWTs, or signed URLs', () {
      const sensitivePath =
          'fa000000-0000-4000-c000-000000000001/ca000000-0000-4000-c000-000000000001/ea000000-0000-4000-c000-000000000001/evidence-123.jpg';
      const secretBearer = 'superSecretBearer987654';
      const secretJwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyLTEifQ.hmacSignatureSecret555';
      const secretSignedToken = 'signedTokenSecret444';
      const secretHost = 'https://secret-project-xyz.supabase.co';

      final matchOutcome = MatchingBytesOutcome(
        storagePath: sensitivePath,
        remoteBytes: [1, 2, 3],
        remoteSha256: 'abc123',
      );
      expect(matchOutcome.toString(), isNot(contains('fa000000')));
      expect(matchOutcome.toString(), isNot(contains('ca000000')));
      expect(matchOutcome.toString(), contains('.../evidence-123.jpg'));

      final conflictOutcome = ContentConflictOutcome(
        storagePath: sensitivePath,
        localSha256: 'hash1',
        remoteSha256: 'hash2',
        localByteCount: 10,
        remoteByteCount: 10,
        reason:
            'Conflict at $secretHost/storage/v1/object/sign/assessment-evidence/$sensitivePath?token=$secretSignedToken',
      );
      expect(conflictOutcome.reason, isNot(contains(secretSignedToken)));
      expect(conflictOutcome.reason, isNot(contains(secretHost)));
      expect(conflictOutcome.reason, isNot(contains('fa000000')));
      expect(conflictOutcome.toString(), isNot(contains(secretSignedToken)));
      expect(conflictOutcome.toString(), isNot(contains('fa000000')));

      final authOutcome = AuthFailureOutcome(
        storagePath: sensitivePath,
        reason: 'Token expired: Bearer $secretBearer and jwt $secretJwt',
      );
      expect(authOutcome.reason, isNot(contains(secretBearer)));
      expect(authOutcome.reason, isNot(contains(secretJwt)));
      expect(authOutcome.reason, isNot(contains('eyJhbGci')));
      expect(authOutcome.toString(), isNot(contains('fa000000')));
      expect(authOutcome.toString(), isNot(contains(secretBearer)));
      expect(authOutcome.toString(), isNot(contains(secretJwt)));

      final exc = EvidenceStorageConflictException(
        conflictOutcome,
        'Failed for $sensitivePath with Bearer $secretBearer at $secretHost/object?secret_jwt=$secretJwt',
      );
      expect(exc.message, isNot(contains('fa000000')));
      expect(exc.message, isNot(contains(secretBearer)));
      expect(exc.message, isNot(contains(secretJwt)));
      expect(exc.message, isNot(contains(secretHost)));
      expect(exc.toString(), isNot(contains('fa000000')));
      expect(exc.toString(), isNot(contains(secretBearer)));
      expect(exc.toString(), isNot(contains(secretJwt)));
      expect(exc.toString(), isNot(contains(secretHost)));
    });

    test('R32-07: Storage SDK and HTTP failures never leak bearer tokens, JWTs, URLs, or private Storage paths', () async {
      const secretBearer = 'topSecretBearerTokenXYZ';
      const secretJwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.verySecretSig999';
      const secretSignedToken = 'signedUrlQuerySecret111';
      const secretHost = 'https://private-tenant-host.supabase.co';
      final leakedDetail =
          'Upstream error: Authorization: Bearer $secretBearer JWT=$secretJwt url=$secretHost/storage/v1/object/sign/assessment-evidence/$expectedPath?token=$secretSignedToken';

      void assertNoSecrets(Object err) {
        final msg = err is AssessmentEvidenceStorageException
            ? err.message
            : '';
        final str = err.toString();
        for (final needle in [
          secretBearer,
          secretJwt,
          'eyJhbGci',
          secretSignedToken,
          secretHost,
          '10000000-0000-0000-0000-000000000001',
          '20000000-0000-0000-0000-000000000002',
          '30000000-0000-0000-0000-000000000003',
        ]) {
          expect(msg, isNot(contains(needle)));
          expect(str, isNot(contains(needle)));
        }
        if (err is EvidenceStorageUnknownOutcomeException) {
          expect(err.cause, isNull);
          expect(err.result.cause, isNull);
          for (final needle in [
            secretBearer,
            secretJwt,
            secretSignedToken,
            secretHost,
            '10000000-0000-0000-0000-000000000001',
          ]) {
            expect(err.result.reason, isNot(contains(needle)));
            expect(err.result.toString(), isNot(contains(needle)));
          }
        }
      }

      // 1. Upload StorageException (500)
      mockHttp.customUploadErrorStatus = 500;
      mockHttp.customUploadErrorMessage = leakedDetail;
      try {
        await storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3],
          mediaType: 'image/jpeg',
        );
        fail('Expected EvidenceStorageUnknownOutcomeException');
      } on EvidenceStorageUnknownOutcomeException catch (e) {
        assertNoSecrets(e);
      }
      mockHttp.customUploadErrorStatus = null;

      // 2. Upload 401 StorageException -> typed EvidenceStorageAuthException without secrets
      mockHttp.customUploadErrorStatus = 401;
      mockHttp.customUploadErrorMessage = leakedDetail;
      try {
        await storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3],
          mediaType: 'image/jpeg',
        );
        fail('Expected EvidenceStorageAuthException');
      } on EvidenceStorageAuthException catch (e) {
        assertNoSecrets(e);
      }
      mockHttp.customUploadErrorStatus = null;

      // 3. Download StorageException (500) and Reconcile failure
      mockHttp.simulateDownload500 = true;
      mockHttp.customDownloadErrorMessage = leakedDetail;
      try {
        await storage.downloadEvidence(storagePath: expectedPath);
        fail('Expected EvidenceStorageUnknownOutcomeException');
      } on EvidenceStorageUnknownOutcomeException catch (e) {
        assertNoSecrets(e);
      }
      final reconcileOn500 = await storage.reconcileEvidence(
        storagePath: expectedPath,
        localBytes: [1, 2, 3],
      );
      expect(reconcileOn500, isA<UnknownOutcome>());
      expect(reconcileOn500.toString(), isNot(contains(secretJwt)));
      expect(
        (reconcileOn500 as UnknownOutcome).reason,
        isNot(contains(secretBearer)),
      );
      expect(reconcileOn500.cause, isNull);
      mockHttp.simulateDownload500 = false;

      // 4. Signed URL & Delete StorageException (500)
      mockHttp.simulateSign500 = true;
      mockHttp.customSignErrorMessage = leakedDetail;
      try {
        await storage.getEvidenceSignedUrl(storagePath: expectedPath);
        fail('Expected EvidenceStorageUnknownOutcomeException');
      } on EvidenceStorageUnknownOutcomeException catch (e) {
        assertNoSecrets(e);
      }
      mockHttp.simulateSign500 = false;

      mockHttp.simulateDelete500 = true;
      mockHttp.customDeleteErrorMessage = leakedDetail;
      try {
        await storage.deleteEvidence(expectedPath);
        fail('Expected EvidenceStorageUnknownOutcomeException');
      } on EvidenceStorageUnknownOutcomeException catch (e) {
        assertNoSecrets(e);
      }
      mockHttp.simulateDelete500 = false;

      // 5. Raw HTTP transport ClientException carrying private URL & query token
      mockHttp.simulateNetworkError = true;
      mockHttp.customNetworkErrorUri =
          '$secretHost/storage/v1/object/assessment-evidence/$expectedPath?token=$secretSignedToken';
      try {
        await storage.downloadEvidence(storagePath: expectedPath);
        fail('Expected EvidenceStorageUnknownOutcomeException');
      } on EvidenceStorageUnknownOutcomeException catch (e) {
        assertNoSecrets(e);
      }
      mockHttp.simulateNetworkError = false;
    });

    test('R32-08: rejects 0-byte uploads, accepts exact 10 MiB, rejects 0-byte downloads, and aborts oversized downloadStream without buffering remaining chunks', () async {
      // 1. Reject 0-byte upload
      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: const [],
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );
      expect(mockHttp.uploadCallCount, equals(0));

      // 2. Reject 0-byte remote download in both downloadEvidence and reconcileEvidence
      mockHttp.remoteStorage[expectedPath] = const [];
      await expectLater(
        () => storage.downloadEvidence(storagePath: expectedPath),
        throwsA(isA<EvidenceStorageConflictException>()),
      );
      final emptyReconcile = await storage.reconcileEvidence(
        storagePath: expectedPath,
        localBytes: [1, 2, 3],
      );
      expect(emptyReconcile, isA<ContentConflictOutcome>());
      expect(
        (emptyReconcile as ContentConflictOutcome).reason,
        contains('empty'),
      );

      // 3. Exact 10 MiB boundary upload and streaming download succeed
      final exactTenMib = Uint8List(10 * 1024 * 1024);
      exactTenMib[0] = 77;
      exactTenMib[exactTenMib.length - 1] = 88;
      final uploadedPath = await storage.uploadEvidence(
        familyId: familyId,
        childId: childId,
        assessmentId: assessmentId,
        evidenceId: evidenceId,
        bytes: exactTenMib,
        mediaType: 'image/png',
      );
      final downloadedTenMib = await storage.downloadEvidence(
        storagePath: uploadedPath,
      );
      expect(downloadedTenMib.length, equals(10 * 1024 * 1024));
      expect(downloadedTenMib.first, equals(77));
      expect(downloadedTenMib.last, equals(88));

      // 4. Chunked oversized download (> 10 MiB across multiple chunks) cancels stream immediately
      final chunk3Mib = List<int>.filled(3 * 1024 * 1024, 5);
      mockHttp.chunkedDownloadChunks = [
        chunk3Mib, // 3 MiB
        chunk3Mib, // 6 MiB
        chunk3Mib, // 9 MiB
        chunk3Mib, // 12 MiB -> crosses 10 MiB limit here (chunk 4)
        chunk3Mib, // chunk 5 (must not be consumed)
        chunk3Mib, // chunk 6 (must not be consumed)
      ];
      mockHttp.emittedDownloadChunkCount = 0;

      await expectLater(
        () => storage.downloadEvidence(storagePath: expectedPath),
        throwsA(isA<EvidenceStorageConflictException>()),
      );
      expect(
        mockHttp.emittedDownloadChunkCount,
        lessThan(6),
        reason: 'downloadStream consumer should cancel subscription mid-stream once 10 MiB is exceeded',
      );
    });

    test('R32-06: all Storage operations fail closed with zero HTTP requests when unauthenticated', () async {
      fakeAuth.signOut();

      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3],
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      await expectLater(
        () => storage.downloadEvidence(storagePath: expectedPath),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      final reconcile = await storage.reconcileEvidence(
        storagePath: expectedPath,
        localBytes: [1, 2, 3],
      );
      expect(reconcile, isA<AuthFailureOutcome>());
      await expectLater(
        () => storage.getEvidenceSignedUrl(storagePath: expectedPath),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      await expectLater(
        () => storage.deleteEvidence(expectedPath),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      expect(mockHttp.uploadCallCount, equals(0));
      expect(mockHttp.downloadCallCount, equals(0));
      expect(mockHttp.deleteCallCount, equals(0));
      expect(mockHttp.recordedRequests, isEmpty);
    });
  });
}
