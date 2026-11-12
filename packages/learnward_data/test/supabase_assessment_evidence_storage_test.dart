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
  bool simulateDownload403 = false;
  bool simulateDownload404 = false;
  bool simulateDownloadTimeout = false;
  bool simulateNetworkError = false;

  int uploadCallCount = 0;
  int downloadCallCount = 0;
  int deleteCallCount = 0;
  List<String> deletedPaths = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    recordedRequests.add(request);

    if (simulateNetworkError) {
      throw http.ClientException('Simulated network error');
    }
    if (simulateDownloadTimeout) {
      throw http.ClientException('Connection timed out');
    }

    final path = Uri.decodeComponent(request.url.path);
    final method = request.method.toUpperCase();

    // 1. DELETE /storage/v1/object/assessment-evidence
    if (method == 'DELETE' &&
        path.contains('/storage/v1/object/assessment-evidence')) {
      deleteCallCount++;
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
                'message': 'Access denied by Storage RLS',
              }),
            ),
          ),
          403,
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
  });
}
