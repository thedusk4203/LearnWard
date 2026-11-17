// Phase 6 Slice 4B-1 — WP5 Acceptance & Invariant Verification Suite
//
// Governing contract: docs/24-phase-6-slice-4b-1-evidence-resumability-design-contract.md
//
// Traceability Matrix (B1-01 through B1-30 & I01 through I16):
// | ID    | Invariants      | Scope & Verification Focus                                                     |
// |-------|-----------------|--------------------------------------------------------------------------------|
// | B1-01 | I01, I08, I14   | JPEG picker bytes frozen once, SHA-256 & length survive SQLite restart         |
// | B1-02 | I01, I02, I14   | PNG evidence preserved as image/png (.png path, no fake JPEG transcoding)      |
// | B1-03 | I01, I04, I08   | Missing, truncated, or byte-mutated canonical file fails closed (no fallback)  |
// | B1-04 | I02, I03        | Canonical Storage path uses stable IDs; never rotates UUIDs across retries     |
// | B1-05 | I02, I11        | Registration stores DB-generated serverEvidenceId != client evidenceId          |
// | B1-06 | I01, I03, I05   | Storage 409 with matching bytes reconciles via authorized download & commits   |
// | B1-07 | I01, I03..I05   | Storage 409 same-length differing-digest quarantines; zero delete/overwrite    |
// | B1-08 | I01, I03..I05   | Storage 409 different-length quarantines; preserves remote & local objects     |
// | B1-09 | I04, I06, I07   | Storage 409 + download 401/403/RLS denial remains unknown & retains evidence   |
// | B1-10 | I02, I04, I06   | Storage 409 + download 404 never deletes or rotates identity                   |
// | B1-11 | I03, I05        | Lost upload timeout reconciles via exact byte match without duplicate upload   |
// | B1-12 | I02, I05, I11   | Lost registration ACK learns serverEvidenceId (= row.id) or quarantines mismatch|
// | B1-13 | I04, I12, I13   | Registration committed + non-draft LW109 reconciles read-only & confirms       |
// | B1-14 | I04, I06, I12   | Non-draft assessment with no proven evidence row quarantines unresolved        |
// | B1-15 | I02, I04, I06   | RLS-null assessment/evidence read never infers absence or mints new UUIDs      |
// | B1-16 | I02, I07, I10   | Authoritative auth, actor switch A<->B, unbound actor quarantine, session gen  |
// | B1-17 | I04, I06, I07   | Child archived before dispatch vs after lost submit (Step 4 42501 ambiguous)   |
// | B1-18 | I07, I08, I14   | Crash & auth boundary resilience across direct submit and every stage boundary |
// | B1-19 | I02, I05, I11   | Crash after registration before serverEvidenceId persistence reconciles & wins |
// | B1-20 | I11, I13, I14   | Lost submit ACK preserves submitCommandId; idempotent vs 42501 ambiguity       |
// | B1-21 | I08, I09        | Two-connection SQLite contention + Completer barriers -> single lease & 1 RPC  |
// | B1-22 | I09             | Expired lease takeover fences stale worker across every CAS operation          |
// | B1-23 | I10, I15        | saveLocalDraft & CAS block concurrent editor overwrites and quarantine edits   |
// | B1-24 | I01, I02, I07   | Cross-family, cross-child, and cross-assessment mismatch rejects fail-closed   |
// | B1-25 | I11, I13        | Version enforcement: expectedVersion 1 only, draft v>1 quarantine, LW101/LW107 |
// | B1-26 | I07, I10, I15   | unknownLegacy, unbound actor, unverified in-flight & unknown wire status       |
// | B1-27 | I02, I09        | Bounded persisted retry backoff with TestClock & DeterministicJitterSource     |
// | B1-28 | I04, I14        | Confirmed submission retains local photos & SQLite receipt across restart      |
// | B1-29 | I03..I07, I16   | Supabase Storage & PostgREST wire contract, x-upsert:false, LW109, I16 redact  |
// | B1-30 | I15             | Drift schema v6 intact (30+19 cols) and isolated reward/assessment CAS co-exist|

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

final class _DurableDiskCanonicalSnapshotStore
    implements CanonicalEvidenceSnapshotStore {
  _DurableDiskCanonicalSnapshotStore(this.dir);

  final Directory dir;
  int _counter = 0;

  @override
  Future<CanonicalEvidenceSnapshot> saveCanonicalEvidenceSnapshot({
    required String localDraftId,
    required List<int> bytes,
  }) async {
    final inspected = inspectAndValidateEvidenceBytes(bytes);
    final evidenceDir = Directory('${dir.path}/draft_evidence');
    if (!evidenceDir.existsSync()) {
      evidenceDir.createSync(recursive: true);
    }
    _counter++;
    final file = File(
      '${evidenceDir.path}/${localDraftId}_canonical_$_counter.${inspected.fileExtension}',
    );
    // Match D4 contract: exclusive file creation + RandomAccessFile flush + re-read check.
    file.createSync(exclusive: true);
    final raf = file.openSync(mode: FileMode.writeOnly);
    try {
      raf.writeFromSync(inspected.bytes);
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    final reRead = file.readAsBytesSync();
    final reVerified = verifyCanonicalEvidenceBytes(
      bytes: reRead,
      expectedSha256: inspected.sha256Checksum,
      expectedByteLength: inspected.byteLength,
      expectedMediaType: inspected.mediaType,
    );
    return CanonicalEvidenceSnapshot(
      localDraftId: localDraftId,
      filePath: file.path,
      mediaType: reVerified.mediaType,
      fileExtension: reVerified.fileExtension,
      byteLength: reVerified.byteLength,
      sha256Checksum: reVerified.sha256Checksum,
      frozenAt: DateTime.utc(2026, 11, 16, 8, 0),
    );
  }

  @override
  Future<VerifiedCanonicalEvidence> readVerifiedCanonicalSnapshot({
    required LocalAssessmentDraft draft,
  }) async {
    if (!draft.hasVerifiedEvidenceSnapshot) {
      throw const CanonicalEvidenceValidationException(
        CanonicalEvidenceValidationCode.invalidSha256Format,
        'Missing canonical snapshot metadata on draft.',
      );
    }
    final file = File(draft.localCompressedPhotoPath!);
    if (!await file.exists()) {
      throw MissingCanonicalEvidenceSnapshotException(
        localDraftId: draft.localDraftId,
        message: 'Canonical snapshot file missing on disk.',
      );
    }
    final bytes = await file.readAsBytes();
    final verified = verifyCanonicalEvidenceBytes(
      bytes: bytes,
      expectedSha256: draft.sha256Checksum!,
    );
    return VerifiedCanonicalEvidence(
      snapshot: CanonicalEvidenceSnapshot(
        localDraftId: draft.localDraftId,
        filePath: file.path,
        mediaType: verified.mediaType,
        fileExtension: verified.fileExtension,
        byteLength: verified.byteLength,
        sha256Checksum: verified.sha256Checksum,
        frozenAt: draft.updatedAt,
      ),
      bytes: verified.bytes,
    );
  }
}

final class _SimulatedProcessCrashException implements Exception {
  const _SimulatedProcessCrashException(this.stage);

  final String stage;

  @override
  String toString() => '_SimulatedProcessCrashException($stage)';
}

final class _CrashableLocalDraftStore implements LocalDraftStore {
  _CrashableLocalDraftStore(this.inner);

  final LocalDraftStore inner;
  bool _hardCrashed = false;
  bool get hardCrashed => _hardCrashed;
  Future<void> Function()? onBeforeMarkStageAndDispatch;

  void tripHardCrash() {
    _hardCrashed = true;
  }

  void _checkAlive(String operation) {
    if (_hardCrashed) {
      throw _SimulatedProcessCrashException('hard_crash_blocked_$operation');
    }
  }

  @override
  Future<DraftCasResult> acquireDraftClaim({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    DateTime? now,
    String? overrideLeaseToken,
    bool ignoreRetryBackoff = false,
  }) {
    _checkAlive('acquireDraftClaim');
    return inner.acquireDraftClaim(
      localDraftId: localDraftId,
      actorUserId: actorUserId,
      familyId: familyId,
      childId: childId,
      leaseDuration: leaseDuration,
      now: now,
      overrideLeaseToken: overrideLeaseToken,
      ignoreRetryBackoff: ignoreRetryBackoff,
    );
  }

  @override
  Future<DraftCasResult> resumeDraftClaimAfterExpiry({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    required DateTime now,
    String? overrideLeaseToken,
    bool ignoreRetryBackoff = false,
  }) {
    _checkAlive('resumeDraftClaimAfterExpiry');
    return inner.resumeDraftClaimAfterExpiry(
      localDraftId: localDraftId,
      actorUserId: actorUserId,
      familyId: familyId,
      childId: childId,
      leaseDuration: leaseDuration,
      now: now,
      overrideLeaseToken: overrideLeaseToken,
      ignoreRetryBackoff: ignoreRetryBackoff,
    );
  }

  @override
  Future<DraftCasResult> markDraftStageAndDispatch({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DraftSubmissionStatus targetStage,
    required DateTime now,
  }) async {
    _checkAlive('markDraftStageAndDispatch');
    if (onBeforeMarkStageAndDispatch != null) {
      await onBeforeMarkStageAndDispatch!();
    }
    _checkAlive('markDraftStageAndDispatch');
    return inner.markDraftStageAndDispatch(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      targetStage: targetStage,
      now: now,
    );
  }

  @override
  Future<DraftCasResult> persistServerAssessmentId({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
  }) {
    _checkAlive('persistServerAssessmentId');
    return inner.persistServerAssessmentId(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      serverAssessmentId: serverAssessmentId,
      now: now,
    );
  }

  @override
  Future<DraftCasResult> persistServerEvidenceId({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverEvidenceId,
    required String expectedEvidenceId,
    required String expectedSha256Checksum,
    required DateTime now,
  }) {
    _checkAlive('persistServerEvidenceId');
    return inner.persistServerEvidenceId(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      serverEvidenceId: serverEvidenceId,
      expectedEvidenceId: expectedEvidenceId,
      expectedSha256Checksum: expectedSha256Checksum,
      now: now,
    );
  }

  @override
  Future<DraftCasResult> scheduleDraftRetry({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DateTime nextAttemptAt,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  }) {
    _checkAlive('scheduleDraftRetry');
    return inner.scheduleDraftRetry(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      nextAttemptAt: nextAttemptAt,
      recoveryCode: recoveryCode,
      errorMessage: errorMessage,
      now: now,
    );
  }

  @override
  Future<DraftCasResult> quarantineDraftOutcome({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  }) {
    _checkAlive('quarantineDraftOutcome');
    return inner.quarantineDraftOutcome(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      recoveryCode: recoveryCode,
      errorMessage: errorMessage,
      now: now,
    );
  }

  @override
  Future<DraftCasResult> completeDraftSubmission({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
    String? serverEvidenceId,
  }) {
    _checkAlive('completeDraftSubmission');
    return inner.completeDraftSubmission(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      serverAssessmentId: serverAssessmentId,
      now: now,
      serverEvidenceId: serverEvidenceId,
    );
  }

  @override
  Future<DraftCasResult> releaseDraftClaim({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    DateTime? now,
  }) {
    _checkAlive('releaseDraftClaim');
    return inner.releaseDraftClaim(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      now: now,
    );
  }

  @override
  Future<DraftCasResult> pauseMismatchedActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  }) {
    _checkAlive('pauseMismatchedActorDraft');
    return inner.pauseMismatchedActorDraft(
      localDraftId: localDraftId,
      familyId: familyId,
      authenticatedActorId: authenticatedActorId,
      mismatchReason: mismatchReason,
      now: now,
    );
  }

  @override
  Future<DraftCasResult> resumeOriginalActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  }) {
    _checkAlive('resumeOriginalActorDraft');
    return inner.resumeOriginalActorDraft(
      localDraftId: localDraftId,
      familyId: familyId,
      authenticatedActorId: authenticatedActorId,
      now: now,
    );
  }

  @override
  Future<void> saveLocalDraft(LocalAssessmentDraft draft) {
    _checkAlive('saveLocalDraft');
    return inner.saveLocalDraft(draft);
  }

  @override
  Future<void> deleteLocalDraft(String localDraftId) {
    _checkAlive('deleteLocalDraft');
    return inner.deleteLocalDraft(localDraftId);
  }

  @override
  Future<DraftDeletionOutcome> deleteDraftSafely({
    required String localDraftId,
    required LocalAssessmentDraft expectedDraft,
    DateTime? now,
  }) {
    _checkAlive('deleteDraftSafely');
    return inner.deleteDraftSafely(
      localDraftId: localDraftId,
      expectedDraft: expectedDraft,
      now: now,
    );
  }

  @override
  Future<DraftCasResult> registerOrUpdateDraftIfUnchanged({
    required LocalAssessmentDraft? expected,
    required LocalAssessmentDraft desired,
    DateTime? now,
  }) {
    _checkAlive('registerOrUpdateDraftIfUnchanged');
    return inner.registerOrUpdateDraftIfUnchanged(
      expected: expected,
      desired: desired,
      now: now,
    );
  }

  @override
  Future<LocalAssessmentDraft?> getLocalDraft(String localDraftId) =>
      inner.getLocalDraft(localDraftId);

  @override
  Future<List<LocalAssessmentDraft>> listLocalDrafts(ChildId childId) =>
      inner.listLocalDrafts(childId);

  @override
  Future<bool> hasDraftReferenceToFile(String filePath) =>
      inner.hasDraftReferenceToFile(filePath);

  @override
  Future<int> countDraftReferencesToFile(String filePath) =>
      inner.countDraftReferencesToFile(filePath);
}

final class _InstrumentedAssessmentRepository extends FakeAssessmentRepository {
  _InstrumentedAssessmentRepository({super.activeActorIdProvider});

  int createDraftCalls = 0;
  int getAssessmentCalls = 0;
  int listEvidenceCalls = 0;
  int registerEvidenceCalls = 0;
  int submitAssessmentCalls = 0;

  final List<String> recordedCreateCommandIds = [];
  final List<String> recordedSubmitCommandIds = [];
  final List<int> recordedSubmitExpectedVersions = [];
  final List<AssessmentEvidence> recordedRegistrations = [];

  Object? nextCreateError;
  Object? nextRegisterError;
  Object? nextSubmitError;

  bool forceNullGetAssessment = false;
  bool forceEmptyEvidenceList = false;

  Future<void> Function()? onBeforeCreate;
  Future<void> Function()? onAfterCreate;
  Future<void> Function()? onBeforeRegister;
  Future<void> Function()? onAfterRegister;
  Future<void> Function()? onBeforeSubmit;
  Future<void> Function()? onAfterSubmit;
  Future<void> Function()? onAfterListEvidence;

  void resetCounts() {
    createDraftCalls = 0;
    getAssessmentCalls = 0;
    listEvidenceCalls = 0;
    registerEvidenceCalls = 0;
    submitAssessmentCalls = 0;
  }

  /// Simulates another worker/request committing evidence registration +
  /// assessment submission directly on the server without incrementing
  /// orchestrator call counters.
  Future<AssessmentEvidence> seedConcurrentEvidenceAndSubmit({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
    required String submitCommandId,
  }) async {
    final registered = await super.registerEvidence(
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: fileSizeBytes,
    );
    await super.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: 1,
      commandId: submitCommandId,
    );
    return registered;
  }

  @override
  Future<Assessment> createDraft({
    required String commandId,
    required FamilyId familyId,
    required ChildId childId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    EntryContext entryContext = EntryContext.adult,
  }) async {
    createDraftCalls++;
    recordedCreateCommandIds.add(commandId);
    if (onBeforeCreate != null) {
      await onBeforeCreate!();
    }
    final err = nextCreateError;
    if (err != null) {
      nextCreateError = null;
      throw err;
    }
    final res = await super.createDraft(
      commandId: commandId,
      familyId: familyId,
      childId: childId,
      subjectKey: subjectKey,
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      occurredAt: occurredAt,
      entryContext: entryContext,
    );
    if (onAfterCreate != null) {
      await onAfterCreate!();
    }
    return res;
  }

  @override
  Future<Assessment?> getAssessment(AssessmentId id) async {
    getAssessmentCalls++;
    if (forceNullGetAssessment) {
      return null;
    }
    return super.getAssessment(id);
  }

  @override
  Future<List<AssessmentEvidence>> listEvidenceForAssessment(
    AssessmentId assessmentId,
  ) async {
    listEvidenceCalls++;
    final res = forceEmptyEvidenceList
        ? const <AssessmentEvidence>[]
        : await super.listEvidenceForAssessment(assessmentId);
    if (onAfterListEvidence != null) {
      await onAfterListEvidence!();
    }
    return res;
  }

  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) async {
    registerEvidenceCalls++;
    if (onBeforeRegister != null) {
      await onBeforeRegister!();
    }
    final err = nextRegisterError;
    if (err != null) {
      nextRegisterError = null;
      throw err;
    }
    final ev = await super.registerEvidence(
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: fileSizeBytes,
    );
    recordedRegistrations.add(ev);
    if (onAfterRegister != null) {
      await onAfterRegister!();
    }
    return ev;
  }

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
    submitAssessmentCalls++;
    recordedSubmitCommandIds.add(commandId);
    recordedSubmitExpectedVersions.add(expectedVersion);
    if (onBeforeSubmit != null) {
      await onBeforeSubmit!();
    }
    final err = nextSubmitError;
    if (err != null) {
      nextSubmitError = null;
      throw err;
    }
    final submitted = await super.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
    );
    if (onAfterSubmit != null) {
      await onAfterSubmit!();
    }
    return submitted;
  }
}

final class _MockStorageHttpClient extends http.BaseClient {
  final Map<String, List<int>> remoteStorage = {};
  final Map<String, String> remoteContentTypes = {};
  final List<http.BaseRequest> requests = [];

  bool simulateUpload409 = false;
  bool commitUploadThenLoseResponseOnce = false;
  int? downloadStatusOverride;
  bool simulateDownloadTimeout = false;

  Future<void> Function()? onBeforeUpload;
  Future<void> Function()? onAfterRemoteWriteBeforeResponse;

  int uploadCallCount = 0;
  int successfulUploadWrites = 0;
  int rejectedNoUpsertUploadAttempts = 0;
  int overwriteCount = 0;
  int downloadCallCount = 0;
  int deleteCallCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final path = Uri.decodeComponent(request.url.path);
    final method = request.method.toUpperCase();

    if (method == 'DELETE' &&
        path.contains('/storage/v1/object/assessment-evidence')) {
      deleteCallCount++;
      return http.StreamedResponse(
        Stream.value(utf8.encode('[{"message":"deleted"}]')),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }

    if (method == 'GET' && path.contains('/storage/v1/object/')) {
      downloadCallCount++;
      if (simulateDownloadTimeout) {
        throw http.ClientException('Connection timed out', request.url);
      }
      final override = downloadStatusOverride;
      if (override != null) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'statusCode': '$override',
                'error': 'DownloadError',
                'message': 'Simulated download status $override',
              }),
            ),
          ),
          override,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }
      const marker = '/assessment-evidence/';
      final idx = path.indexOf(marker);
      final key = idx != -1 ? path.substring(idx + marker.length) : '';
      final bytes = remoteStorage[key];
      if (bytes == null) {
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
      return http.StreamedResponse(
        Stream.value(Uint8List.fromList(bytes)),
        200,
        request: request,
        headers: {
          'content-type': remoteContentTypes[key] ?? 'image/jpeg',
          'content-length': '${bytes.length}',
        },
      );
    }

    if (method == 'POST' &&
        path.contains('/storage/v1/object/assessment-evidence/')) {
      uploadCallCount++;
      if (onBeforeUpload != null) {
        await onBeforeUpload!();
      }
      const marker = '/assessment-evidence/';
      final idx = path.indexOf(marker);
      final key = idx != -1 ? path.substring(idx + marker.length) : '';
      final upsertHeader = request.headers['x-upsert']?.toLowerCase();
      final isNoUpsertRejection =
          simulateUpload409 ||
          (remoteStorage.containsKey(key) && upsertHeader != 'true');
      if (isNoUpsertRejection) {
        rejectedNoUpsertUploadAttempts++;
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
      final existedBefore = remoteStorage.containsKey(key);
      final List<int> writtenBytes;
      final String contentType;
      if (request is http.MultipartRequest && request.files.isNotEmpty) {
        writtenBytes = await request.files.first.finalize().toBytes();
        contentType = request.files.first.contentType.mimeType;
      } else {
        writtenBytes = await request.finalize().toBytes();
        contentType =
            request.headers['content-type'] ?? 'application/octet-stream';
      }
      remoteStorage[key] = writtenBytes;
      remoteContentTypes[key] = contentType;
      if (existedBefore) {
        overwriteCount++;
      } else {
        successfulUploadWrites++;
      }
      if (onAfterRemoteWriteBeforeResponse != null) {
        await onAfterRemoteWriteBeforeResponse!();
      }
      if (commitUploadThenLoseResponseOnce) {
        commitUploadThenLoseResponseOnce = false;
        throw http.ClientException(
          'Simulated lost upload response after remote storage commit',
          request.url,
        );
      }
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(jsonEncode({'Key': 'assessment-evidence/$key'})),
        ),
        200,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    }

    return http.StreamedResponse(
      Stream.value(utf8.encode('{"error":"unhandled"}')),
      400,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final baseNow = DateTime.utc(2026, 11, 16, 8, 0, 0);
  final familyId = FamilyId('11111111-1111-4111-8111-111111111111');
  final childId = ChildId('22222222-2222-4222-8222-222222222222');
  final otherFamilyId = FamilyId('99999999-9999-4999-8999-999999999999');
  final otherChildId = ChildId('88888888-8888-4888-8888-888888888888');

  final jpegHeaderBytes = <int>[
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    0x4A,
    0x46,
    0x49,
    0x46,
    0x00,
    0x01,
    0x02,
    0x03,
  ];
  final pngHeaderBytes = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x42,
  ];

  late Directory tempDir;
  late File dbFile;
  late AppDatabase db;
  late _DurableDiskCanonicalSnapshotStore snapshotStore;
  late FakeAuthSessionPort authPort;
  late FakeRecoveryAuthorizationPort authzPort;
  late _InstrumentedAssessmentRepository repo;
  late FakeAssessmentEvidenceStorage storage;
  late TestClock clock;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lw_wp5_b1_');
    dbFile = File('${tempDir.path}/wp5_acceptance.sqlite');
    db = AppDatabase(NativeDatabase(dbFile));
    snapshotStore = _DurableDiskCanonicalSnapshotStore(tempDir);
    clock = TestClock(baseNow);
    authPort = FakeAuthSessionPort(
      activeUserId: 'actor-parent-1',
      sessionGeneration: 'gen-1',
      role: 'parent',
    );
    authzPort = FakeRecoveryAuthorizationPort();
    repo = _InstrumentedAssessmentRepository(
      activeActorIdProvider: () => authPort.currentContext?.userId,
    );
    storage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
  });

  tearDown(() async {
    try {
      await db.close();
    } catch (_) {}
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  AssessmentSubmissionOrchestrator buildOrchestrator({
    LocalDraftStore? storeOverride,
    AssessmentEvidenceStorage? storageOverride,
    AssessmentRepository? repoOverride,
    RecoveryAuthorizationPort? authzOverride,
    Clock? clockOverride,
    JitterSource jitterSource = const DeterministicJitterSource(0.0),
    int maxRetryCount = 3,
  }) {
    return AssessmentSubmissionOrchestrator(
      repository: repoOverride ?? repo,
      storage: storageOverride ?? storage,
      authSessionPort: authPort,
      localDraftStore: storeOverride ?? db,
      recoveryAuthorizationPort: authzOverride ?? authzPort,
      canonicalSnapshotStore: snapshotStore,
      clock: clockOverride ?? clock,
      jitterSource: jitterSource,
      maxRetryCount: maxRetryCount,
    );
  }

  Future<LocalAssessmentDraft> seedDraft({
    AppDatabase? targetDb,
    required String localDraftId,
    String? actorUserId = 'actor-parent-1',
    String? actorRole = 'parent',
    String createCommandId = 'cmd-create-wp5-1',
    String submitCommandId = 'cmd-submit-wp5-1',
    String? evidenceId = '33333333-3333-4333-8333-333333333333',
    List<int>? evidenceBytes,
    String? rawPhotoName,
    String title = 'WP5 Fraction Quiz',
    bool persistViaCas = true,
  }) async {
    final effectiveDb = targetDb ?? db;
    String? rawPhotoPath;
    if (rawPhotoName != null) {
      final rawFile = File('${tempDir.path}/$rawPhotoName')
        ..writeAsBytesSync(evidenceBytes ?? jpegHeaderBytes);
      rawPhotoPath = rawFile.path;
    }

    CanonicalEvidenceSnapshot? snap;
    if (evidenceBytes != null) {
      snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
        localDraftId: localDraftId,
        bytes: evidenceBytes,
      );
    }

    final draft = LocalAssessmentDraft(
      localDraftId: localDraftId,
      familyId: familyId.value,
      childId: childId.value,
      actorUserId: actorUserId,
      actorRole: actorRole,
      createCommandId: createCommandId,
      submitCommandId: submitCommandId,
      evidenceId: evidenceBytes != null ? evidenceId : null,
      subjectKey: SubjectKey.math,
      subject: 'Mathematics',
      title: title,
      assessmentType: 'quiz',
      difficulty: 'normal',
      rawScore: 9.0,
      maxScore: 10.0,
      localPhotoPath: rawPhotoPath,
      localCompressedPhotoPath: snap?.filePath,
      sha256Checksum: snap?.sha256Checksum,
      occurredAt: baseNow,
      updatedAt: baseNow,
      dispatchState: CommandDispatchState.neverDispatched,
      entryContext: EntryContext.sharedChild,
    );

    if (persistViaCas) {
      final reg = await effectiveDb.registerOrUpdateDraftIfUnchanged(
        expected: null,
        desired: draft,
        now: clock.now().toUtc(),
      );
      expect(reg.isSuccess, isTrue);
      return reg.draft!;
    }
    return draft;
  }

  Future<AssessmentSubmissionOutcome> executeDraft(
    AssessmentSubmissionOrchestrator orchestrator, {
    required String localDraftId,
    String createCommandId = 'cmd-create-wp5-1',
    String submitCommandId = 'cmd-submit-wp5-1',
    String? evidenceId = '33333333-3333-4333-8333-333333333333',
    bool hasEvidence = true,
    String title = 'WP5 Fraction Quiz',
    CommandExecutionTrigger trigger = CommandExecutionTrigger.foreground,
    FamilyId? overrideFamilyId,
    ChildId? overrideChildId,
  }) {
    return orchestrator.execute(
      familyId: overrideFamilyId ?? familyId,
      childId: overrideChildId ?? childId,
      createCommandId: createCommandId,
      submitCommandId: submitCommandId,
      subjectKey: SubjectKey.math,
      subject: 'Mathematics',
      title: title,
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
      occurredAt: baseNow,
      entryContext: EntryContext.sharedChild,
      evidenceId: hasEvidence && evidenceId != null
          ? EvidenceId(evidenceId)
          : null,
      localDraftId: localDraftId,
      trigger: trigger,
    );
  }

  void expectCanonicalFileIntact(String? path, List<int> expectedBytes) {
    expect(path, isNotNull);
    final f = File(path!);
    expect(f.existsSync(), isTrue);
    final actual = f.readAsBytesSync();
    expect(actual.length, equals(expectedBytes.length));
    expect(actual, equals(expectedBytes));
    expect(computeSha256Hex(actual), equals(computeSha256Hex(expectedBytes)));
  }

  Future<AppDatabase> reopenDb() async {
    await db.close();
    db = AppDatabase(NativeDatabase(dbFile));
    return db;
  }

  group('Phase 6 Slice 4B-1 Acceptance Matrix B1-01..B1-30', () {
    test('B1-01: New JPEG picker bytes frozen once, caller buffer mutated, exact hash and length survive SQLite restart (I01, I08, I14)', () async {
      const draftId = 'b1-01-jpeg';
      final mutableCallerBytes = List<int>.from(jpegHeaderBytes);
      final expectedDigest = computeSha256Hex(jpegHeaderBytes);
      final seeded = await seedDraft(
        localDraftId: draftId,
        evidenceBytes: mutableCallerBytes,
        rawPhotoName: 'raw_camera.jpg',
      );

      // Mutate caller's input buffer after freeze: canonical snapshot must remain immutable.
      mutableCallerBytes[mutableCallerBytes.length - 1] ^= 0xFF;

      // Restart SQLite database from disk before executing submission.
      await reopenDb();
      final reloaded = await db.getLocalDraft(draftId);
      expect(reloaded, isNotNull);
      expect(reloaded!.sha256Checksum, equals(expectedDigest));
      expect(reloaded.localCompressedPhotoPath, endsWith('.jpg'));
      expectCanonicalFileIntact(
        reloaded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );

      final orchestrator = buildOrchestrator();
      final outcome = await executeDraft(orchestrator, localDraftId: draftId);

      expect(outcome, isA<AssessmentSubmissionConfirmed>());
      final confirmed = outcome as AssessmentSubmissionConfirmed;
      expect(
        confirmed.assessment.status,
        equals(AssessmentStatus.pendingReview),
      );
      expect(repo.createDraftCalls, equals(1));
      expect(storage.uploadCallCount, equals(1));
      expect(repo.registerEvidenceCalls, equals(1));
      expect(repo.submitAssessmentCalls, equals(1));
      expect(storage.deleteCallCount, equals(0));
      expect(
        repo.recordedRegistrations.single.fileSizeBytes,
        equals(jpegHeaderBytes.length),
      );
      expect(repo.recordedRegistrations.single.mediaType, equals('image/jpeg'));

      final finalRow = await db.getLocalDraft(draftId);
      expect(
        finalRow?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expect(finalRow?.sha256Checksum, equals(expectedDigest));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
      expectCanonicalFileIntact(seeded.localPhotoPath, jpegHeaderBytes);
    });

    test('B1-02: PNG evidence preserved with image/png MIME, .png Storage path extension, and byte binding without fake JPEG conversion (I01, I02, I14)', () async {
      const draftId = 'b1-02-png';
      const evId = '33333333-3333-4333-8333-000000000002';
      final seeded = await seedDraft(
        localDraftId: draftId,
        evidenceId: evId,
        evidenceBytes: pngHeaderBytes,
      );

      expect(seeded.localCompressedPhotoPath, endsWith('.png'));
      expect(seeded.sha256Checksum, equals(computeSha256Hex(pngHeaderBytes)));

      await reopenDb();
      final orchestrator = buildOrchestrator();
      final outcome = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        evidenceId: evId,
      );

      expect(outcome, isA<AssessmentSubmissionConfirmed>());
      final confirmed = outcome as AssessmentSubmissionConfirmed;
      expect(confirmed.serverEvidence?.mediaType, equals('image/png'));
      expect(
        confirmed.serverEvidence?.storagePath,
        equals(
          '${familyId.value}/${childId.value}/${confirmed.assessment.id.value}/$evId.png',
        ),
      );
      expect(
        confirmed.serverEvidence?.fileSizeBytes,
        equals(pngHeaderBytes.length),
      );
      expect(
        storage.storage[confirmed.serverEvidence!.storagePath],
        equals(pngHeaderBytes),
      );
      expect(repo.createDraftCalls, equals(1));
      expect(storage.uploadCallCount, equals(1));
      expect(repo.registerEvidenceCalls, equals(1));
      expect(repo.submitAssessmentCalls, equals(1));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        pngHeaderBytes,
      );
    });

    test('B1-03: Canonical snapshot missing, truncated, or mutated since freeze fails closed with zero upload or fallback (I01, I04, I08)', () async {
      // Case 1: neverDispatched missing file on disk despite intact rawPhotoPath -> throws MissingCanonicalEvidenceSnapshotException
      const missingDraftId = 'b1-03-missing';
      final seededMissing = await seedDraft(
        localDraftId: missingDraftId,
        evidenceBytes: jpegHeaderBytes,
        rawPhotoName: 'raw_fallback_should_not_be_used.jpg',
      );
      File(seededMissing.localCompressedPhotoPath!).deleteSync();

      final orchestrator = buildOrchestrator();
      await expectLater(
        () => executeDraft(orchestrator, localDraftId: missingDraftId),
        throwsA(isA<MissingCanonicalEvidenceSnapshotException>()),
      );
      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(seededMissing.localPhotoPath, jpegHeaderBytes);

      // Case 2: possiblyDispatched truncated canonical snapshot -> quarantines LW4B1:LOCAL_SNAPSHOT_CORRUPTED
      const truncDraftId = 'b1-03-truncated';
      final seededTrunc = await seedDraft(
        localDraftId: truncDraftId,
        createCommandId: 'cmd-c-b103-t',
        submitCommandId: 'cmd-s-b103-t',
        evidenceId: '33333333-3333-4333-8333-000000000103',
        evidenceBytes: jpegHeaderBytes,
      );
      final claimTrunc = await db.acquireDraftClaim(
        localDraftId: truncDraftId,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      await db.markDraftStageAndDispatch(
        localDraftId: truncDraftId,
        leaseToken: claimTrunc.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        targetStage: DraftSubmissionStatus.uploadingEvidence,
        now: baseNow,
      );
      await db.releaseDraftClaim(
        localDraftId: truncDraftId,
        leaseToken: claimTrunc.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        now: baseNow,
      );
      File(seededTrunc.localCompressedPhotoPath!)
          .writeAsBytesSync(jpegHeaderBytes.sublist(0, 6), flush: true);

      final truncOutcome = await executeDraft(
        orchestrator,
        localDraftId: truncDraftId,
        createCommandId: 'cmd-c-b103-t',
        submitCommandId: 'cmd-s-b103-t',
        evidenceId: '33333333-3333-4333-8333-000000000103',
      );
      expect(truncOutcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (truncOutcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.localSnapshotCorrupted),
      );
      expect(storage.uploadCallCount, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expect(storage.deleteCallCount, equals(0));

      // Case 3: possiblyDispatched same-length 1-byte tamper -> quarantines LW4B1:LOCAL_SNAPSHOT_CORRUPTED
      const mutatedDraftId = 'b1-03-mutated';
      final seededMut = await seedDraft(
        localDraftId: mutatedDraftId,
        createCommandId: 'cmd-c-b103-m',
        submitCommandId: 'cmd-s-b103-m',
        evidenceId: '33333333-3333-4333-8333-000000000203',
        evidenceBytes: jpegHeaderBytes,
      );
      final claimMut = await db.acquireDraftClaim(
        localDraftId: mutatedDraftId,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      await db.markDraftStageAndDispatch(
        localDraftId: mutatedDraftId,
        leaseToken: claimMut.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        targetStage: DraftSubmissionStatus.uploadingEvidence,
        now: baseNow,
      );
      await db.releaseDraftClaim(
        localDraftId: mutatedDraftId,
        leaseToken: claimMut.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        now: baseNow,
      );
      final tampered = List<int>.from(jpegHeaderBytes);
      tampered[tampered.length - 1] ^= 0x55;
      File(seededMut.localCompressedPhotoPath!)
          .writeAsBytesSync(tampered, flush: true);

      final mutOutcome = await executeDraft(
        orchestrator,
        localDraftId: mutatedDraftId,
        createCommandId: 'cmd-c-b103-m',
        submitCommandId: 'cmd-s-b103-m',
        evidenceId: '33333333-3333-4333-8333-000000000203',
      );
      expect(mutOutcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (mutOutcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.localSnapshotCorrupted),
      );
      expect(storage.uploadCallCount, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expect(storage.deleteCallCount, equals(0));
    });

    test('B1-04: Canonical path uses stable family/child/assessment/evidence IDs and never rotates UUID on multi-stage retry (I02, I03)', () async {
      const draftId = 'b1-04-stable-ids';
      const createCmd = 'cmd-c-b104';
      const submitCmd = 'cmd-s-b104';
      const evId = '33333333-3333-4333-8333-000000000004';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );

      final orchestrator = buildOrchestrator();

      // Fail Stage A (createDraft)
      repo.nextCreateError = TimeoutException('Stage A timeout');
      final r1 = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      expect(r1, isA<AssessmentSubmissionRetryScheduled>());

      // Fail Stage B upload
      clock.advance(const Duration(minutes: 2));
      await reopenDb();
      storage.throwOnUpload = TimeoutException('Upload timeout');
      final r2 = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      expect(r2, isA<AssessmentSubmissionRetryScheduled>());
      final afterStageA = await db.getLocalDraft(draftId);
      final stableServerAssessmentId = afterStageA!.serverAssessmentId!;
      expect(stableServerAssessmentId, isNotEmpty);

      // Fail Stage C submit
      clock.advance(const Duration(minutes: 2));
      await reopenDb();
      storage.throwOnUpload = null;
      repo.nextSubmitError = TimeoutException('Submit timeout');
      final r3 = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      expect(r3, isA<AssessmentSubmissionRetryScheduled>());
      final afterStageB = await db.getLocalDraft(draftId);
      final stableServerEvidenceId = afterStageB!.serverEvidenceId!;
      expect(stableServerEvidenceId, isNot(equals(evId)));

      // Final retry completes with identical IDs and path.
      clock.advance(const Duration(minutes: 5));
      await reopenDb();
      final r4 = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      expect(r4, isA<AssessmentSubmissionConfirmed>());
      final confirmed = r4 as AssessmentSubmissionConfirmed;
      final expectedPath =
          '${familyId.value}/${childId.value}/$stableServerAssessmentId/$evId.jpg';
      expect(confirmed.assessment.id.value, equals(stableServerAssessmentId));
      expect(
        confirmed.serverEvidence?.id.value,
        equals(stableServerEvidenceId),
      );
      expect(confirmed.serverEvidence?.storagePath, equals(expectedPath));
      expect(repo.recordedCreateCommandIds, everyElement(equals(createCmd)));
      expect(repo.recordedSubmitCommandIds, everyElement(equals(submitCmd)));
      expect(storage.storage.keys, equals([expectedPath]));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-05: Successful upload + registration stores DB-generated serverEvidenceId != client evidenceId while preserving distinct evidenceId (I02, I11)', () async {
      const draftId = 'b1-05-id-namespaces';
      const clientEvidenceId = '33333333-3333-4333-8333-000000000005';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b105',
        submitCommandId: 'cmd-s-b105',
        evidenceId: clientEvidenceId,
        evidenceBytes: jpegHeaderBytes,
      );

      final orchestrator = buildOrchestrator();
      final outcome = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: 'cmd-c-b105',
        submitCommandId: 'cmd-s-b105',
        evidenceId: clientEvidenceId,
      );

      expect(outcome, isA<AssessmentSubmissionConfirmed>());
      final confirmed = outcome as AssessmentSubmissionConfirmed;
      final persisted = await (await reopenDb()).getLocalDraft(draftId);
      expect(persisted?.evidenceId, equals(clientEvidenceId));
      expect(persisted?.serverEvidenceId, isNotNull);
      expect(
        persisted?.serverEvidenceId,
        equals(confirmed.serverEvidence?.id.value),
      );
      expect(persisted?.serverEvidenceId, isNot(equals(clientEvidenceId)));
      expect(
        confirmed.serverEvidence?.storagePath,
        contains('/$clientEvidenceId.jpg'),
      );
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-06: HTTP 409 with identical remote bytes and size reconciles via SupabaseAssessmentEvidenceStorage download & completes (I01, I03, I05)', () async {
      const draftId = 'b1-06-409-match';
      const evId = '33333333-3333-4333-8333-000000000006';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b106',
        submitCommandId: 'cmd-s-b106',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );

      final mockHttp = _MockStorageHttpClient()..simulateUpload409 = true;
      final sbClient = SupabaseClient(
        'https://mock.supabase.co',
        'anon-key',
        httpClient: mockHttp,
      );
      final realAdapter = SupabaseAssessmentEvidenceStorage(
        sbClient,
        authSessionPort: authPort,
      );

      // Pre-seed remote assessment & identical object bytes so 409 triggers download reconciliation.
      final preCreated = await repo.createDraft(
        commandId: 'cmd-c-b106',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final storagePath =
          '${familyId.value}/${childId.value}/${preCreated.id.value}/$evId.jpg';
      mockHttp.remoteStorage[storagePath] = List<int>.from(jpegHeaderBytes);
      repo.resetCounts();

      final orchestrator = buildOrchestrator(storageOverride: realAdapter);
      final outcome = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: 'cmd-c-b106',
        submitCommandId: 'cmd-s-b106',
        evidenceId: evId,
      );

      expect(outcome, isA<AssessmentSubmissionConfirmed>());
      expect(mockHttp.uploadCallCount, equals(1));
      expect(mockHttp.downloadCallCount, equals(1));
      expect(mockHttp.deleteCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(1));
      expect(repo.submitAssessmentCalls, equals(1));

      final persisted = await (await reopenDb()).getLocalDraft(draftId);
      expect(
        persisted?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-07: HTTP 409 with same byte length and differing SHA-256 quarantines without overwrite, delete, or UUID rotation (I01, I03, I04, I05)', () async {
      const draftId = 'b1-07-409-same-len-conflict';
      const evId = '33333333-3333-4333-8333-000000000007';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b107',
        submitCommandId: 'cmd-s-b107',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );

      final differingSameLength = List<int>.from(jpegHeaderBytes);
      differingSameLength[differingSameLength.length - 1] ^= 0xFF;
      expect(differingSameLength.length, equals(jpegHeaderBytes.length));

      final mockHttp = _MockStorageHttpClient()..simulateUpload409 = true;
      final sbClient = SupabaseClient(
        'https://mock.supabase.co',
        'anon-key',
        httpClient: mockHttp,
      );
      final realAdapter = SupabaseAssessmentEvidenceStorage(
        sbClient,
        authSessionPort: authPort,
      );

      final preCreated = await repo.createDraft(
        commandId: 'cmd-c-b107',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final storagePath =
          '${familyId.value}/${childId.value}/${preCreated.id.value}/$evId.jpg';
      mockHttp.remoteStorage[storagePath] = List<int>.from(differingSameLength);
      repo.resetCounts();

      final orchestrator = buildOrchestrator(storageOverride: realAdapter);
      final outcome = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: 'cmd-c-b107',
        submitCommandId: 'cmd-s-b107',
        evidenceId: evId,
      );

      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      final q = outcome as AssessmentSubmissionQuarantined;
      expect(q.recoveryCode, equals(DraftRecoveryCode.storageContentConflict));
      expect(mockHttp.uploadCallCount, equals(1));
      expect(mockHttp.downloadCallCount, equals(1));
      expect(mockHttp.deleteCallCount, equals(0));
      expect(mockHttp.remoteStorage[storagePath], equals(differingSameLength));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));

      final persisted = await (await reopenDb()).getLocalDraft(draftId);
      expect(persisted?.evidenceId, equals(evId));
      expect(
        persisted?.recoveryCode,
        equals(DraftRecoveryCode.storageContentConflict),
      );
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-08: HTTP 409 with differing byte length fails closed and preserves both remote object and local file (I01, I03, I04, I05)', () async {
      const draftId = 'b1-08-409-diff-len';
      const evId = '33333333-3333-4333-8333-000000000008';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b108',
        submitCommandId: 'cmd-s-b108',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );
      final longerRemote = <int>[...jpegHeaderBytes, 0x01, 0x02, 0x03];

      final mockHttp = _MockStorageHttpClient()..simulateUpload409 = true;
      final sbClient = SupabaseClient(
        'https://mock.supabase.co',
        'anon-key',
        httpClient: mockHttp,
      );
      final realAdapter = SupabaseAssessmentEvidenceStorage(
        sbClient,
        authSessionPort: authPort,
      );

      final preCreated = await repo.createDraft(
        commandId: 'cmd-c-b108',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final storagePath =
          '${familyId.value}/${childId.value}/${preCreated.id.value}/$evId.jpg';
      mockHttp.remoteStorage[storagePath] = List<int>.from(longerRemote);
      repo.resetCounts();

      final orchestrator = buildOrchestrator(storageOverride: realAdapter);
      final outcome = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: 'cmd-c-b108',
        submitCommandId: 'cmd-s-b108',
        evidenceId: evId,
      );

      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (outcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.storageContentConflict),
      );
      expect(mockHttp.deleteCallCount, equals(0));
      expect(mockHttp.remoteStorage[storagePath], equals(longerRemote));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-09: HTTP 409 followed by download 401 or 403/RLS denial remains unknown and retains remote and local evidence (I04, I06, I07)', () async {
      for (final statusCode in [401, 403]) {
        final draftId = 'b1-09-dl-$statusCode';
        final evId = '33333333-3333-4333-8333-0000000009$statusCode';
        final seeded = await seedDraft(
          localDraftId: draftId,
          createCommandId: 'cmd-c-$draftId',
          submitCommandId: 'cmd-s-$draftId',
          evidenceId: evId,
          evidenceBytes: jpegHeaderBytes,
        );

        final mockHttp = _MockStorageHttpClient()
          ..simulateUpload409 = true
          ..downloadStatusOverride = statusCode;
        final sbClient = SupabaseClient(
          'https://mock.supabase.co',
          'anon-key',
          httpClient: mockHttp,
        );
        final realAdapter = SupabaseAssessmentEvidenceStorage(
          sbClient,
          authSessionPort: authPort,
        );

        final preCreated = await repo.createDraft(
          commandId: 'cmd-c-$draftId',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Mathematics',
          title: 'WP5 Fraction Quiz',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
          occurredAt: baseNow,
          entryContext: EntryContext.sharedChild,
        );
        final path =
            '${familyId.value}/${childId.value}/${preCreated.id.value}/$evId.jpg';
        mockHttp.remoteStorage[path] = List<int>.from(jpegHeaderBytes);
        repo.resetCounts();

        final orchestrator = buildOrchestrator(storageOverride: realAdapter);
        final outcome = await executeDraft(
          orchestrator,
          localDraftId: draftId,
          createCommandId: 'cmd-c-$draftId',
          submitCommandId: 'cmd-s-$draftId',
          evidenceId: evId,
        );

        expect(outcome, isA<AssessmentSubmissionRetryScheduled>());
        expect(mockHttp.uploadCallCount, equals(1));
        expect(mockHttp.downloadCallCount, equals(1));
        expect(mockHttp.deleteCallCount, equals(0));
        expect(repo.registerEvidenceCalls, equals(0));
        expect(repo.submitAssessmentCalls, equals(0));
        expect(mockHttp.remoteStorage[path], equals(jpegHeaderBytes));

        final persisted = await db.getLocalDraft(draftId);
        expect(
          persisted?.dispatchState,
          equals(CommandDispatchState.possiblyDispatched),
        );
        expect(
          persisted?.submissionStatus,
          equals(DraftSubmissionStatus.failedRetryable),
        );
        expect(
          persisted?.recoveryCode,
          equals(DraftRecoveryCode.retryScheduled),
        );
        expect(
          persisted?.recoveryDispositionAt(now: clock.now().toUtc()),
          equals(DraftRecoveryDisposition.retryScheduled),
        );
        expectCanonicalFileIntact(
          seeded.localCompressedPhotoPath,
          jpegHeaderBytes,
        );
      }
    });

    test('B1-10: HTTP 409 followed by remote 404 never authorizes destructive cleanup or UUID rotation (I02, I04, I06)', () async {
      const draftId = 'b1-10-409-404';
      const evId = '33333333-3333-4333-8333-000000000010';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b110',
        submitCommandId: 'cmd-s-b110',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );

      final mockHttp = _MockStorageHttpClient()
        ..simulateUpload409 = true
        ..downloadStatusOverride = 404;
      final sbClient = SupabaseClient(
        'https://mock.supabase.co',
        'anon-key',
        httpClient: mockHttp,
      );
      final realAdapter = SupabaseAssessmentEvidenceStorage(
        sbClient,
        authSessionPort: authPort,
      );

      final orchestrator = buildOrchestrator(storageOverride: realAdapter);
      final outcome = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: 'cmd-c-b110',
        submitCommandId: 'cmd-s-b110',
        evidenceId: evId,
      );

      expect(outcome, isA<AssessmentSubmissionRetryScheduled>());
      expect(mockHttp.uploadCallCount, equals(1));
      expect(mockHttp.downloadCallCount, equals(1));
      expect(mockHttp.deleteCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));

      final persisted = await (await reopenDb()).getLocalDraft(draftId);
      expect(persisted?.evidenceId, equals(evId));
      expect(persisted?.createCommandId, equals('cmd-c-b110'));
      expect(persisted?.submitCommandId, equals('cmd-s-b110'));
      expect(persisted?.serverAssessmentId, isNotNull);
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-11: Remote upload commits then loses client response; reopened SQLite & file store resume without duplicate upload or overwrite (I03, I05)', () async {
      const draftId = 'b1-11-lost-upload-ack';
      const evId = '33333333-3333-4333-8333-000000000011';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b111',
        submitCommandId: 'cmd-s-b111',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );
      final expectedSha = computeSha256Hex(jpegHeaderBytes);

      final mockHttp = _MockStorageHttpClient()
        ..commitUploadThenLoseResponseOnce = true;
      final sbClient = SupabaseClient(
        'https://mock.supabase.co',
        'anon-key',
        httpClient: mockHttp,
      );
      final realAdapter = SupabaseAssessmentEvidenceStorage(
        sbClient,
        authSessionPort: authPort,
      );

      // Attempt 1 through actual orchestrator: createDraft commits, Storage POST commits bytes,
      // then HTTP response is lost -> retry scheduled before registerEvidence / submitAssessment.
      final outcome1 = await executeDraft(
        buildOrchestrator(storageOverride: realAdapter),
        localDraftId: draftId,
        createCommandId: 'cmd-c-b111',
        submitCommandId: 'cmd-s-b111',
        evidenceId: evId,
      );
      expect(outcome1, isA<AssessmentSubmissionRetryScheduled>());
      expect(repo.createDraftCalls, equals(1));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expect(mockHttp.uploadCallCount, equals(1));
      expect(mockHttp.successfulUploadWrites, equals(1));
      expect(mockHttp.rejectedNoUpsertUploadAttempts, equals(0));
      expect(mockHttp.overwriteCount, equals(0));
      expect(mockHttp.downloadCallCount, equals(0));
      expect(mockHttp.deleteCallCount, equals(0));

      final expectedAssessmentId = repo.commandToAssessmentId['cmd-c-b111']!;
      final expectedPath =
          '${familyId.value}/${childId.value}/$expectedAssessmentId/$evId.jpg';
      expect(mockHttp.remoteStorage[expectedPath], equals(jpegHeaderBytes));

      // Simulate restart: reopen file-backed SQLite and recreate canonical file store.
      await reopenDb();
      snapshotStore = _DurableDiskCanonicalSnapshotStore(tempDir);

      final midPersisted = await db.getLocalDraft(draftId);
      expect(midPersisted?.localDraftId, equals(draftId));
      expect(midPersisted?.createCommandId, equals('cmd-c-b111'));
      expect(midPersisted?.submitCommandId, equals('cmd-s-b111'));
      expect(midPersisted?.evidenceId, equals(evId));
      expect(
        midPersisted?.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );
      expect(
        midPersisted?.submissionStatus,
        equals(DraftSubmissionStatus.failedRetryable),
      );
      expect(
        midPersisted?.recoveryCode,
        equals(DraftRecoveryCode.retryScheduled),
      );
      expect(midPersisted?.serverAssessmentId, equals(expectedAssessmentId));
      expect(midPersisted?.serverEvidenceId, isNull);
      expect(midPersisted?.sha256Checksum, equals(expectedSha));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );

      // Advance past retry backoff and resume through fresh orchestrator.
      clock.advance(const Duration(minutes: 5));
      repo.resetCounts();

      final outcome2 = await executeDraft(
        buildOrchestrator(storageOverride: realAdapter),
        localDraftId: draftId,
        createCommandId: 'cmd-c-b111',
        submitCommandId: 'cmd-s-b111',
        evidenceId: evId,
      );
      expect(outcome2, isA<AssessmentSubmissionConfirmed>());
      final confirmed = outcome2 as AssessmentSubmissionConfirmed;
      expect(confirmed.assessment.id.value, equals(expectedAssessmentId));
      expect(repo.createDraftCalls, equals(0));
      expect(repo.registerEvidenceCalls, equals(1));
      expect(repo.submitAssessmentCalls, equals(1));

      // Attempt 2's x-upsert:false upload is rejected with HTTP 409 and reconciled via download;
      // zero duplicate successful uploads, zero overwrites, zero deletions, single remote object.
      expect(mockHttp.uploadCallCount, equals(2));
      expect(mockHttp.successfulUploadWrites, equals(1));
      expect(mockHttp.rejectedNoUpsertUploadAttempts, equals(1));
      expect(mockHttp.overwriteCount, equals(0));
      expect(mockHttp.downloadCallCount, equals(1));
      expect(mockHttp.deleteCallCount, equals(0));
      expect(mockHttp.remoteStorage.keys.toList(), equals([expectedPath]));
      expect(mockHttp.remoteStorage[expectedPath], equals(jpegHeaderBytes));

      await reopenDb();
      final finalPersisted = await db.getLocalDraft(draftId);
      expect(finalPersisted?.localDraftId, equals(draftId));
      expect(finalPersisted?.createCommandId, equals('cmd-c-b111'));
      expect(finalPersisted?.submitCommandId, equals('cmd-s-b111'));
      expect(finalPersisted?.evidenceId, equals(evId));
      expect(finalPersisted?.serverAssessmentId, equals(expectedAssessmentId));
      expect(finalPersisted?.serverEvidenceId, isNotNull);
      expect(finalPersisted?.serverEvidenceId, isNot(equals(evId)));
      expect(finalPersisted?.sha256Checksum, equals(expectedSha));
      expect(
        finalPersisted?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-12: Lost registration response reconciles by (assessmentId, familyId, storagePath) + SHA-256 and enforces serverEvidenceId match (I02, I05, I11)', () async {
      // Case A: serverEvidenceId is null -> learns row.id via lease-fenced CAS
      const draftIdA = 'b1-12-learn-id';
      const evIdA = '33333333-3333-4333-8333-000000000012';
      final seededA = await seedDraft(
        localDraftId: draftIdA,
        createCommandId: 'cmd-c-b112a',
        submitCommandId: 'cmd-s-b112a',
        evidenceId: evIdA,
        evidenceBytes: jpegHeaderBytes,
      );
      final createdA = await repo.createDraft(
        commandId: 'cmd-c-b112a',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final pathA =
          '${familyId.value}/${childId.value}/${createdA.id.value}/$evIdA.jpg';
      storage.storage[pathA] = List<int>.from(jpegHeaderBytes);
      final regRowA = await repo.registerEvidence(
        assessmentId: createdA.id,
        storagePath: pathA,
        mediaType: 'image/jpeg',
        fileSizeBytes: jpegHeaderBytes.length,
      );
      final claimA = await db.acquireDraftClaim(
        localDraftId: draftIdA,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      await db.markDraftStageAndDispatch(
        localDraftId: draftIdA,
        leaseToken: claimA.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        targetStage: DraftSubmissionStatus.uploadingEvidence,
        now: baseNow,
      );
      await db.persistServerAssessmentId(
        localDraftId: draftIdA,
        leaseToken: claimA.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        serverAssessmentId: createdA.id.value,
        now: baseNow,
      );
      await db.releaseDraftClaim(
        localDraftId: draftIdA,
        leaseToken: claimA.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        now: baseNow,
      );
      repo.resetCounts();
      storage.uploadCallCount = 0;

      await reopenDb();
      final orchestrator = buildOrchestrator();
      final outA = await executeDraft(
        orchestrator,
        localDraftId: draftIdA,
        createCommandId: 'cmd-c-b112a',
        submitCommandId: 'cmd-s-b112a',
        evidenceId: evIdA,
      );
      expect(outA, isA<AssessmentSubmissionConfirmed>());
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(storage.reconcileCallCount, equals(1));
      expect(repo.submitAssessmentCalls, equals(1));
      expect(
        (await db.getLocalDraft(draftIdA))?.serverEvidenceId,
        equals(regRowA.id.value),
      );
      expect(regRowA.id.value, isNot(equals(evIdA)));
      expectCanonicalFileIntact(
        seededA.localCompressedPhotoPath,
        jpegHeaderBytes,
      );

      // Case B: serverEvidenceId already persisted to different ID -> EVIDENCE_ID_MISMATCH quarantine
      const draftIdB = 'b1-12-mismatch-id';
      const evIdB = '33333333-3333-4333-8333-000000000112';
      final seededB = await seedDraft(
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b112b',
        submitCommandId: 'cmd-s-b112b',
        evidenceId: evIdB,
        evidenceBytes: jpegHeaderBytes,
      );
      final claimB = await db.acquireDraftClaim(
        localDraftId: draftIdB,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      await db.markDraftStageAndDispatch(
        localDraftId: draftIdB,
        leaseToken: claimB.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        targetStage: DraftSubmissionStatus.uploadingEvidence,
        now: baseNow,
      );
      await db.persistServerAssessmentId(
        localDraftId: draftIdB,
        leaseToken: claimB.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        serverAssessmentId: createdA.id.value,
        now: baseNow,
      );
      await db.persistServerEvidenceId(
        localDraftId: draftIdB,
        leaseToken: claimB.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        serverEvidenceId: 'other-server-evidence-id',
        expectedEvidenceId: evIdB,
        expectedSha256Checksum: seededB.sha256Checksum!,
        now: baseNow,
      );
      await db.releaseDraftClaim(
        localDraftId: draftIdB,
        leaseToken: claimB.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        now: baseNow,
      );
      repo.resetCounts();

      final outB = await executeDraft(
        orchestrator,
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b112b',
        submitCommandId: 'cmd-s-b112b',
        evidenceId: evIdB,
      );
      expect(outB, isA<AssessmentSubmissionQuarantined>());
      expect(
        (outB as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.evidenceIdMismatch),
      );
      expect(repo.submitAssessmentCalls, equals(0));
      expect(storage.deleteCallCount, equals(0));
    });

    test('B1-13: Active LW109 registration rejection reconciles read-only, separately from pre-committed non-draft reconciliation (I04, I12, I13)', () async {
      // Subcase A: Active LW109 execution path during registerEvidence (isNonDraftRemote == false at Stage B entry).
      const draftIdA = 'b1-13a-lw109-active';
      const evIdA = '33333333-3333-4333-8333-000000000013';
      final seededA = await seedDraft(
        localDraftId: draftIdA,
        createCommandId: 'cmd-c-b113a',
        submitCommandId: 'cmd-s-b113a',
        evidenceId: evIdA,
        evidenceBytes: jpegHeaderBytes,
      );
      final a1 = await repo.createDraft(
        commandId: 'cmd-c-b113a',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final pathA =
          '${familyId.value}/${childId.value}/${a1.id.value}/$evIdA.jpg';
      repo.resetCounts();
      storage.reconcileCallCount = 0;

      late final AssessmentEvidence regRowA;
      // Just as registerEvidence is called, another worker/request finishes registering regRowA
      // and transitions a1 out of draft under cmd-s-b113a, causing registerEvidence to throw LW109.
      repo.onBeforeRegister = () async {
        repo.onBeforeRegister = null;
        regRowA = await repo.seedConcurrentEvidenceAndSubmit(
          assessmentId: a1.id,
          storagePath: pathA,
          mediaType: 'image/jpeg',
          fileSizeBytes: jpegHeaderBytes.length,
          submitCommandId: 'cmd-s-b113a',
        );
        repo.nextRegisterError = const BackendRpcException(
          message: 'Assessment must be draft to register evidence',
          code: 'LW109',
        );
      };

      final outcomeA = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftIdA,
        createCommandId: 'cmd-c-b113a',
        submitCommandId: 'cmd-s-b113a',
        evidenceId: evIdA,
      );

      expect(outcomeA, isA<AssessmentSubmissionConfirmed>());
      expect(repo.registerEvidenceCalls, equals(1));
      expect(repo.nextRegisterError, isNull);
      expect(storage.reconcileCallCount, equals(1));
      expect(storage.deleteCallCount, equals(0));
      final persistedA = await (await reopenDb()).getLocalDraft(draftIdA);
      expect(persistedA?.serverEvidenceId, equals(regRowA.id.value));
      expect(regRowA.id.value, isNot(equals(evIdA)));
      expect(
        persistedA?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expectCanonicalFileIntact(
        seededA.localCompressedPhotoPath,
        jpegHeaderBytes,
      );

      // Subcase B: Pre-committed non-draft assessment reconciles read-only at Stage B entry
      // without invoking uploadEvidence or registerEvidence (no LW109 injection needed).
      const draftIdB = 'b1-13b-nondraft-readonly';
      const evIdB = '33333333-3333-4333-8333-000000000113';
      final seededB = await seedDraft(
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b113b',
        submitCommandId: 'cmd-s-b113b',
        evidenceId: evIdB,
        evidenceBytes: jpegHeaderBytes,
      );
      final a2 = await repo.createDraft(
        commandId: 'cmd-c-b113b',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final pathB =
          '${familyId.value}/${childId.value}/${a2.id.value}/$evIdB.jpg';
      storage.storage[pathB] = List<int>.from(jpegHeaderBytes);
      final regRowB = await repo.seedConcurrentEvidenceAndSubmit(
        assessmentId: a2.id,
        storagePath: pathB,
        mediaType: 'image/jpeg',
        fileSizeBytes: jpegHeaderBytes.length,
        submitCommandId: 'cmd-s-b113b',
      );
      repo.resetCounts();
      storage.uploadCallCount = 0;
      storage.reconcileCallCount = 0;

      final outcomeB = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b113b',
        submitCommandId: 'cmd-s-b113b',
        evidenceId: evIdB,
      );

      expect(outcomeB, isA<AssessmentSubmissionConfirmed>());
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(storage.reconcileCallCount, equals(1));
      expect(storage.deleteCallCount, equals(0));
      final persistedB = await (await reopenDb()).getLocalDraft(draftIdB);
      expect(persistedB?.serverEvidenceId, equals(regRowB.id.value));
      expect(
        persistedB?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expectCanonicalFileIntact(
        seededB.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-14: Non-draft assessment with no proven evidence row remains unresolved & preserves remote bytes (I04, I06, I12)', () async {
      const draftId = 'b1-14-unresolved';
      const evId = '33333333-3333-4333-8333-000000000014';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b114',
        submitCommandId: 'cmd-s-b114',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );
      final a = await repo.createDraft(
        commandId: 'cmd-c-b114',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      await repo.submitAssessment(
        assessmentId: a.id,
        expectedVersion: 1,
        commandId: 'cmd-other-submit-b114',
      );
      final path = '${familyId.value}/${childId.value}/${a.id.value}/$evId.jpg';
      storage.storage[path] = List<int>.from(jpegHeaderBytes);
      repo.resetCounts();

      final orchestrator = buildOrchestrator();
      final outcome = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: 'cmd-c-b114',
        submitCommandId: 'cmd-s-b114',
        evidenceId: evId,
      );

      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (outcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.registrationUnresolvedRemoteRetained),
      );
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expect(storage.deleteCallCount, equals(0));
      expect(storage.storage[path], equals(jpegHeaderBytes));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-15: RLS-null on assessment or evidence read never infers absence, never deletes, and never mints new IDs (I02, I04, I06)', () async {
      const draftId = 'b1-15-rls-null';
      const evId = '33333333-3333-4333-8333-000000000015';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b115',
        submitCommandId: 'cmd-s-b115',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );
      final claim = await db.acquireDraftClaim(
        localDraftId: draftId,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      await db.markDraftStageAndDispatch(
        localDraftId: draftId,
        leaseToken: claim.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        targetStage: DraftSubmissionStatus.submittingAssessment,
        now: baseNow,
      );
      await db.persistServerAssessmentId(
        localDraftId: draftId,
        leaseToken: claim.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        serverAssessmentId: 'srv-assessment-rls-1',
        now: baseNow,
      );
      await db.releaseDraftClaim(
        localDraftId: draftId,
        leaseToken: claim.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        now: baseNow,
      );

      // Simulate PostgREST maybeSingle() == null due to RLS filtering during recovery.
      repo.forceNullGetAssessment = true;
      final orchestrator = buildOrchestrator();
      final outcome = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: 'cmd-c-b115',
        submitCommandId: 'cmd-s-b115',
        evidenceId: evId,
      );

      // Authorized target + null SELECT is treated as ambiguous unknown state (42501 signal), zero new createDraft.
      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      expect(repo.createDraftCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expect(storage.deleteCallCount, equals(0));

      final persisted = await (await reopenDb()).getLocalDraft(draftId);
      expect(persisted?.serverAssessmentId, equals('srv-assessment-rls-1'));
      expect(persisted?.createCommandId, equals('cmd-c-b115'));
      expect(persisted?.submitCommandId, equals('cmd-s-b115'));
      expect(persisted?.evidenceId, equals(evId));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-16: Authoritative auth, actor switch A->B->A, unbound actor quarantine, revocation & session generation fence (I02, I07, I10)', () async {
      // 1. Actor switch A -> B pauses with WAITING_ORIGINAL_ACTOR and zero RPCs; Actor A resumes.
      const switchId = 'b1-16-switch';
      final seededSwitch = await seedDraft(
        localDraftId: switchId,
        actorUserId: 'actor-parent-1',
        createCommandId: 'cmd-c-b116',
        submitCommandId: 'cmd-s-b116',
        evidenceBytes: jpegHeaderBytes,
      );
      final orchestrator = buildOrchestrator();

      authPort.setSession(
        userId: 'actor-parent-2',
        sessionGeneration: 'gen-b2',
        role: 'parent',
      );
      final pausedB = await executeDraft(
        orchestrator,
        localDraftId: switchId,
        createCommandId: 'cmd-c-b116',
        submitCommandId: 'cmd-s-b116',
      );
      expect(pausedB, isA<AssessmentSubmissionPausedActorMismatch>());
      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(
        (await db.getLocalDraft(switchId))?.recoveryCode,
        equals(DraftRecoveryCode.waitingOriginalActor),
      );

      // Return to original actor -> resumes & confirms with original IDs
      authPort.setSession(
        userId: 'actor-parent-1',
        sessionGeneration: 'gen-1',
        role: 'parent',
      );
      final resumedA = await executeDraft(
        orchestrator,
        localDraftId: switchId,
        createCommandId: 'cmd-c-b116',
        submitCommandId: 'cmd-s-b116',
      );
      expect(resumedA, isA<AssessmentSubmissionConfirmed>());
      expectCanonicalFileIntact(
        seededSwitch.localCompressedPhotoPath,
        jpegHeaderBytes,
      );

      // 2. Unbound actor (actor_user_id IS NULL) derives UNBOUND_ACTOR_PROVENANCE without rewriting SQLite
      const unboundId = 'b1-16-unbound';
      await db.customStatement('''
          INSERT INTO local_assessment_drafts (
            local_draft_id, family_id, child_id, subject_key, subject, title,
            assessment_type, difficulty, raw_score, max_score, entry_context,
            occurred_at, updated_at, submission_status, retry_count, dispatch_state,
            actor_user_id
          ) VALUES (
            '$unboundId', '${familyId.value}', '${childId.value}', 'math', 'Mathematics',
            'WP5 Fraction Quiz', 'quiz', 'normal', 9.0, 10.0, 'shared_child',
            ${baseNow.millisecondsSinceEpoch ~/ 1000}, ${baseNow.millisecondsSinceEpoch ~/ 1000},
            'draft', 0, 'never_dispatched', NULL
          );
        ''');
      final unboundRow = await db.getLocalDraft(unboundId);
      expect(unboundRow?.hasUnboundActor, isTrue);
      expect(unboundRow?.isReadOnlyQuarantined, isTrue);

      repo.resetCounts();
      final unboundOut = await executeDraft(
        orchestrator,
        localDraftId: unboundId,
        hasEvidence: false,
      );
      expect(unboundOut, isA<AssessmentSubmissionQuarantined>());
      expect(
        (unboundOut as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.unboundActorProvenance),
      );
      expect(repo.createDraftCalls, equals(0));
      expect((await db.getLocalDraft(unboundId))?.actorUserId, isNull);

      // 3. Session generation change across markDraftStageAndDispatch halts before createDraft with zero RPCs
      const genId = 'b1-16-gen';
      final seededGen = await seedDraft(
        localDraftId: genId,
        createCommandId: 'cmd-c-b116-g',
        submitCommandId: 'cmd-s-b116-g',
        evidenceBytes: jpegHeaderBytes,
      );
      final enteredGenBarrier = Completer<void>();
      final releaseGenBarrier = Completer<void>();
      final customAuthz = FakeRecoveryAuthorizationPort(
        onVerifyAssessmentTarget: (_, _, _) async {
          if (!enteredGenBarrier.isCompleted) {
            return const AdultTargetAuthorizationResult.authorized(
              verifiedRole: VerifiedAdultRole.parent,
            );
          }
          return const AdultTargetAuthorizationResult.authorized(
            verifiedRole: VerifiedAdultRole.parent,
          );
        },
      );
      var verifyCount = 0;
      customAuthz.onVerifyAssessmentTarget = (_, _, _) async {
        verifyCount++;
        if (verifyCount == 2) {
          enteredGenBarrier.complete();
          await releaseGenBarrier.future;
        }
        return const AdultTargetAuthorizationResult.authorized(
          verifiedRole: VerifiedAdultRole.parent,
        );
      };
      final genOrch = buildOrchestrator(authzOverride: customAuthz);
      repo.resetCounts();
      storage.uploadCallCount = 0;

      final genFuture = executeDraft(
        genOrch,
        localDraftId: genId,
        createCommandId: 'cmd-c-b116-g',
        submitCommandId: 'cmd-s-b116-g',
      );
      await enteredGenBarrier.future;
      authPort.setSessionGeneration('gen-rotated-during-verify');
      releaseGenBarrier.complete();

      final genOut = await genFuture;
      expect(genOut, isA<AssessmentSubmissionPausedSessionInvalid>());
      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        seededGen.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-17: Child archived before dispatch vs after lost submit (Step 4 42501 before Step 6 receipt check) fails closed without declaring absence (I04, I06, I07, I13)', () async {
      // Case A: Child archived prior to any dispatch -> definitelyDenied(childConfirmedArchived)
      // Per orchestrator contract (D3/R34), childConfirmedArchived is treated conservatively (AMBIGUOUS_42501_OUTCOME)
      // when child archival might overlap pending/unknown work, executing 0 RPCs!
      const dBefore = 'b1-17-archived-before';
      final seededA = await seedDraft(
        localDraftId: dBefore,
        createCommandId: 'cmd-c-b117a',
        submitCommandId: 'cmd-s-b117a',
        evidenceBytes: jpegHeaderBytes,
      );
      authzPort.setDefaultAdultResult(
        const AdultTargetAuthorizationResult.definitelyDenied(
          reason: AdultTargetVerificationReason.childConfirmedArchived,
        ),
      );
      final orchestrator = buildOrchestrator();
      final outA = await executeDraft(
        orchestrator,
        localDraftId: dBefore,
        createCommandId: 'cmd-c-b117a',
        submitCommandId: 'cmd-s-b117a',
      );
      expect(outA, isA<AssessmentSubmissionQuarantined>());
      expect(
        (outA as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        seededA.localCompressedPhotoPath,
        jpegHeaderBytes,
      );

      // Case B: Child archived AFTER submitAssessment committed server-side whose response was lost ->
      // Step 4 raises 42501 before Step 6 receipt lookup -> must preserve AMBIGUOUS_42501_OUTCOME & IDs!
      const dAfter = 'b1-17-archived-after-submit';
      const evAfter = '33333333-3333-4333-8333-000000000117';
      final seededB = await seedDraft(
        localDraftId: dAfter,
        createCommandId: 'cmd-c-b117b',
        submitCommandId: 'cmd-s-b117b',
        evidenceId: evAfter,
        evidenceBytes: jpegHeaderBytes,
      );
      authzPort.setDefaultAdultResult(null);
      authzPort.setDefaultStatus(TargetAuthorizationStatus.authorized);

      // Seed server as committed via Stage A + B, then lose submit response due to Step 4 42501.
      final srvA = await repo.createDraft(
        commandId: 'cmd-c-b117b',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final pathB =
          '${familyId.value}/${childId.value}/${srvA.id.value}/$evAfter.jpg';
      storage.storage[pathB] = List<int>.from(jpegHeaderBytes);
      final srvEv = await repo.registerEvidence(
        assessmentId: srvA.id,
        storagePath: pathB,
        mediaType: 'image/jpeg',
        fileSizeBytes: jpegHeaderBytes.length,
      );
      await repo.submitAssessment(
        assessmentId: srvA.id,
        expectedVersion: 1,
        commandId: 'cmd-s-b117b',
      );

      // Local draft only learned serverAssessmentId + serverEvidenceId, and still retries submit;
      // on submit RPC, child is now archived and Step 4 returns 42501.
      final claimB = await db.acquireDraftClaim(
        localDraftId: dAfter,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      await db.markDraftStageAndDispatch(
        localDraftId: dAfter,
        leaseToken: claimB.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        targetStage: DraftSubmissionStatus.submittingAssessment,
        now: baseNow,
      );
      await db.persistServerAssessmentId(
        localDraftId: dAfter,
        leaseToken: claimB.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        serverAssessmentId: srvA.id.value,
        now: baseNow,
      );
      await db.persistServerEvidenceId(
        localDraftId: dAfter,
        leaseToken: claimB.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        serverEvidenceId: srvEv.id.value,
        expectedEvidenceId: evAfter,
        expectedSha256Checksum: seededB.sha256Checksum!,
        now: baseNow,
      );
      await db.releaseDraftClaim(
        localDraftId: dAfter,
        leaseToken: claimB.draft!.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        now: baseNow,
      );

      repo.onBeforeSubmit = () async {
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.definitelyDenied(
            reason: AdultTargetVerificationReason.childConfirmedArchived,
          ),
        );
        throw const BackendRpcException(
          message: 'Child profile is archived',
          code: '42501',
        );
      };

      final outB = await executeDraft(
        orchestrator,
        localDraftId: dAfter,
        createCommandId: 'cmd-c-b117b',
        submitCommandId: 'cmd-s-b117b',
        evidenceId: evAfter,
      );
      expect(outB, isA<AssessmentSubmissionQuarantined>());
      expect(
        (outB as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(storage.deleteCallCount, equals(0));
      final persistedB = await (await reopenDb()).getLocalDraft(dAfter);
      expect(persistedB?.submitCommandId, equals('cmd-s-b117b'));
      expect(persistedB?.serverAssessmentId, equals(srvA.id.value));
      expect(persistedB?.serverEvidenceId, equals(srvEv.id.value));
      expectCanonicalFileIntact(
        seededB.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-18: Deterministic crash/restart resilience across all 5 crash boundaries with SQLite CAS/lease fencing & auth abort (I07, I08, I14)', () async {
      // Part 0: Auth revoked between snapshot + SQLite registration and RPC -> 0 RPCs
      const authCrashId = 'b1-18-auth-abort';
      final seededAbort = await seedDraft(
        localDraftId: authCrashId,
        createCommandId: 'cmd-c-b118-0',
        submitCommandId: 'cmd-s-b118-0',
        evidenceId: '33333333-3333-4333-8333-000000001800',
        evidenceBytes: jpegHeaderBytes,
      );
      authPort.signOut();
      final abortOut = await executeDraft(
        buildOrchestrator(),
        localDraftId: authCrashId,
        createCommandId: 'cmd-c-b118-0',
        submitCommandId: 'cmd-s-b118-0',
        evidenceId: '33333333-3333-4333-8333-000000001800',
      );
      expect(abortOut, isA<AssessmentSubmissionPausedSessionInvalid>());
      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expectCanonicalFileIntact(
        seededAbort.localCompressedPhotoPath,
        jpegHeaderBytes,
      );

      // Restore valid auth for all 5 crash/restart boundary cases.
      authPort.setSession(
        userId: 'actor-parent-1',
        sessionGeneration: 'gen-1',
        role: 'parent',
      );

      Future<void> runCrashBoundaryCase({
        required String draftId,
        required String createCommandId,
        required String submitCommandId,
        required String evidenceId,
        required String crashStageLabel,
        required void Function(
          _CrashableLocalDraftStore crashStore,
          _MockStorageHttpClient mockHttp,
        )
        configureCrash,
        required void Function(
          LocalAssessmentDraft crashedRow,
          _MockStorageHttpClient mockHttp,
        )
        verifyPostCrash,
        required Future<void> Function(
          AssessmentSubmissionConfirmed confirmed,
          _MockStorageHttpClient mockHttp,
        )
        verifyPostResume,
      }) async {
        final seeded = await seedDraft(
          localDraftId: draftId,
          createCommandId: createCommandId,
          submitCommandId: submitCommandId,
          evidenceId: evidenceId,
          evidenceBytes: jpegHeaderBytes,
        );
        final expectedSha = computeSha256Hex(jpegHeaderBytes);
        final crashStore = _CrashableLocalDraftStore(db);
        final mockHttp = _MockStorageHttpClient();
        final sbClient = SupabaseClient(
          'https://mock.supabase.co',
          'anon-key',
          httpClient: mockHttp,
        );
        final realStorage = SupabaseAssessmentEvidenceStorage(
          sbClient,
          authSessionPort: authPort,
        );

        configureCrash(crashStore, mockHttp);
        repo.resetCounts();

        await expectLater(
          () => executeDraft(
            buildOrchestrator(
              storeOverride: crashStore,
              storageOverride: realStorage,
            ),
            localDraftId: draftId,
            createCommandId: createCommandId,
            submitCommandId: submitCommandId,
            evidenceId: evidenceId,
          ),
          throwsA(
            anyOf(
              isA<_SimulatedProcessCrashException>(),
              predicate<Object>(
                (e) =>
                    e is DraftSubmissionCasException &&
                    e.cause is _SimulatedProcessCrashException,
              ),
            ),
          ),
          reason: '$crashStageLabel should fail at injected hard crash point',
        );
        expect(crashStore.hardCrashed, isTrue);

        // Simulate restart: reopen file-backed SQLite and recreate canonical file store.
        await reopenDb();
        snapshotStore = _DurableDiskCanonicalSnapshotStore(tempDir);

        final crashedRow = await db.getLocalDraft(draftId);
        expect(crashedRow, isNotNull);
        final staleLeaseToken = crashedRow!.leaseToken!;
        expect(staleLeaseToken, isNotEmpty);
        expect(crashedRow.hasActiveLease(now: clock.now().toUtc()), isTrue);
        expect(crashedRow.localDraftId, equals(draftId));
        expect(crashedRow.createCommandId, equals(createCommandId));
        expect(crashedRow.submitCommandId, equals(submitCommandId));
        expect(crashedRow.evidenceId, equals(evidenceId));
        expect(crashedRow.sha256Checksum, equals(expectedSha));
        expectCanonicalFileIntact(
          seeded.localCompressedPhotoPath,
          jpegHeaderBytes,
        );

        verifyPostCrash(crashedRow, mockHttp);

        // Lease fencing BEFORE expiry: competing worker sees leaseConflict and executes 0 RPCs/uploads/deletes.
        final preConflictCreate = repo.createDraftCalls;
        final preConflictUpload = mockHttp.uploadCallCount;
        final preConflictReg = repo.registerEvidenceCalls;
        final preConflictSub = repo.submitAssessmentCalls;
        final preConflictDel = mockHttp.deleteCallCount;

        final conflictOut = await executeDraft(
          buildOrchestrator(storageOverride: realStorage),
          localDraftId: draftId,
          createCommandId: createCommandId,
          submitCommandId: submitCommandId,
          evidenceId: evidenceId,
        );
        expect(conflictOut, isA<AssessmentSubmissionLeaseConflict>());
        expect(
          (conflictOut as AssessmentSubmissionLeaseConflict).casStatus,
          equals(DraftCasStatus.leaseConflict),
        );
        expect(repo.createDraftCalls, equals(preConflictCreate));
        expect(mockHttp.uploadCallCount, equals(preConflictUpload));
        expect(repo.registerEvidenceCalls, equals(preConflictReg));
        expect(repo.submitAssessmentCalls, equals(preConflictSub));
        expect(mockHttp.deleteCallCount, equals(preConflictDel));

        // Advance clock past 2-minute lease expiry so recovery reclaims lease and rotates token.
        clock.advance(const Duration(minutes: 3));
        final expiredMark = await db.markDraftStageAndDispatch(
          localDraftId: draftId,
          leaseToken: staleLeaseToken,
          authenticatedActorId: 'actor-parent-1',
          targetStage: DraftSubmissionStatus.uploadingEvidence,
          now: clock.now().toUtc(),
        );
        expect(expiredMark.status, equals(DraftCasStatus.leaseConflict));

        repo.resetCounts();
        var staleFenceChecked = false;
        repo.onBeforeSubmit = () async {
          repo.onBeforeSubmit = null;
          staleFenceChecked = true;
          final activeRow = await db.getLocalDraft(draftId);
          expect(activeRow?.leaseToken, isNotNull);
          expect(activeRow?.leaseToken, isNot(equals(staleLeaseToken)));
          final ops = <Future<DraftCasResult>>[
            db.markDraftStageAndDispatch(
              localDraftId: draftId,
              leaseToken: staleLeaseToken,
              authenticatedActorId: 'actor-parent-1',
              targetStage: DraftSubmissionStatus.submittingAssessment,
              now: clock.now().toUtc(),
            ),
            db.persistServerAssessmentId(
              localDraftId: draftId,
              leaseToken: staleLeaseToken,
              authenticatedActorId: 'actor-parent-1',
              serverAssessmentId: 'fenced-assessment-id',
              now: clock.now().toUtc(),
            ),
            db.persistServerEvidenceId(
              localDraftId: draftId,
              leaseToken: staleLeaseToken,
              authenticatedActorId: 'actor-parent-1',
              serverEvidenceId: 'fenced-evidence-id',
              expectedEvidenceId: evidenceId,
              expectedSha256Checksum: expectedSha,
              now: clock.now().toUtc(),
            ),
            db.scheduleDraftRetry(
              localDraftId: draftId,
              leaseToken: staleLeaseToken,
              authenticatedActorId: 'actor-parent-1',
              nextAttemptAt: clock.now().toUtc().add(
                const Duration(seconds: 30),
              ),
              recoveryCode: DraftRecoveryCode.retryScheduled,
              errorMessage: 'stale worker retry',
              now: clock.now().toUtc(),
            ),
            db.completeDraftSubmission(
              localDraftId: draftId,
              leaseToken: staleLeaseToken,
              authenticatedActorId: 'actor-parent-1',
              serverAssessmentId: activeRow!.serverAssessmentId!,
              now: clock.now().toUtc(),
              serverEvidenceId: activeRow.serverEvidenceId,
            ),
            db.releaseDraftClaim(
              localDraftId: draftId,
              leaseToken: staleLeaseToken,
              authenticatedActorId: 'actor-parent-1',
              now: clock.now().toUtc(),
            ),
          ];
          for (final res in await Future.wait(ops)) {
            expect(res.isSuccess, isFalse);
            expect(res.status, equals(DraftCasStatus.leaseConflict));
          }
        };

        final resumed = await executeDraft(
          buildOrchestrator(storageOverride: realStorage),
          localDraftId: draftId,
          createCommandId: createCommandId,
          submitCommandId: submitCommandId,
          evidenceId: evidenceId,
        );
        expect(resumed, isA<AssessmentSubmissionConfirmed>());
        final confirmed = resumed as AssessmentSubmissionConfirmed;
        expect(staleFenceChecked, isTrue);
        expect(repo.submitAssessmentCalls, equals(1));
        expect(mockHttp.overwriteCount, equals(0));
        expect(mockHttp.deleteCallCount, equals(0));

        await verifyPostResume(confirmed, mockHttp);

        await reopenDb();
        final finalRow = await db.getLocalDraft(draftId);
        expect(
          finalRow?.dispatchState,
          equals(CommandDispatchState.confirmedCommitted),
        );
        expect(finalRow?.localDraftId, equals(draftId));
        expect(finalRow?.createCommandId, equals(createCommandId));
        expect(finalRow?.submitCommandId, equals(submitCommandId));
        expect(finalRow?.evidenceId, equals(evidenceId));
        expect(
          finalRow?.serverAssessmentId,
          equals(confirmed.assessment.id.value),
        );
        expect(finalRow?.serverEvidenceId, isNotNull);
        expect(finalRow?.serverEvidenceId, isNot(equals(evidenceId)));
        expect(finalRow?.sha256Checksum, equals(expectedSha));
        expectCanonicalFileIntact(
          seeded.localCompressedPhotoPath,
          jpegHeaderBytes,
        );
      }

      // Case 1: Crash before durable upload marker (after lease acquired, before markDraftStageAndDispatch).
      await runCrashBoundaryCase(
        draftId: 'b1-18-case1-before-marker',
        createCommandId: 'cmd-c-b118-1',
        submitCommandId: 'cmd-s-b118-1',
        evidenceId: '33333333-3333-4333-8333-000000001801',
        crashStageLabel: 'Case 1: before durable upload marker',
        configureCrash: (crashStore, mockHttp) {
          crashStore.onBeforeMarkStageAndDispatch = () async {
            crashStore.onBeforeMarkStageAndDispatch = null;
            crashStore.tripHardCrash();
            throw const _SimulatedProcessCrashException('case1_before_marker');
          };
        },
        verifyPostCrash: (crashedRow, mockHttp) {
          expect(
            crashedRow.dispatchState,
            equals(CommandDispatchState.neverDispatched),
          );
          expect(
            crashedRow.submissionStatus,
            equals(DraftSubmissionStatus.draft),
          );
          expect(crashedRow.serverAssessmentId, isNull);
          expect(crashedRow.serverEvidenceId, isNull);
          expect(repo.createDraftCalls, equals(0));
          expect(mockHttp.uploadCallCount, equals(0));
          expect(mockHttp.successfulUploadWrites, equals(0));
          expect(repo.registerEvidenceCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));
        },
        verifyPostResume: (confirmed, mockHttp) async {
          expect(repo.createDraftCalls, equals(1));
          expect(mockHttp.uploadCallCount, equals(1));
          expect(mockHttp.successfulUploadWrites, equals(1));
          expect(mockHttp.rejectedNoUpsertUploadAttempts, equals(0));
          expect(mockHttp.downloadCallCount, equals(0));
          expect(repo.registerEvidenceCalls, equals(1));
        },
      );

      // Case 2a: Crash after durable upload marker, before createDraft RPC.
      await runCrashBoundaryCase(
        draftId: 'b1-18-case2a-after-marker-before-create',
        createCommandId: 'cmd-c-b118-2a',
        submitCommandId: 'cmd-s-b118-2a',
        evidenceId: '33333333-3333-4333-8333-000000001821',
        crashStageLabel: 'Case 2a: after marker, before createDraft',
        configureCrash: (crashStore, mockHttp) {
          repo.onBeforeCreate = () async {
            repo.onBeforeCreate = null;
            crashStore.tripHardCrash();
            throw const _SimulatedProcessCrashException('case2a_before_create');
          };
        },
        verifyPostCrash: (crashedRow, mockHttp) {
          expect(
            crashedRow.dispatchState,
            equals(CommandDispatchState.possiblyDispatched),
          );
          expect(
            crashedRow.submissionStatus,
            equals(DraftSubmissionStatus.uploadingEvidence),
          );
          expect(crashedRow.serverAssessmentId, isNull);
          expect(crashedRow.serverEvidenceId, isNull);
          expect(repo.commandToAssessmentId['cmd-c-b118-2a'], isNull);
          expect(mockHttp.uploadCallCount, equals(0));
          expect(mockHttp.successfulUploadWrites, equals(0));
          expect(repo.registerEvidenceCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));
        },
        verifyPostResume: (confirmed, mockHttp) async {
          expect(repo.createDraftCalls, equals(1));
          expect(mockHttp.uploadCallCount, equals(1));
          expect(mockHttp.successfulUploadWrites, equals(1));
          expect(mockHttp.rejectedNoUpsertUploadAttempts, equals(0));
          expect(repo.registerEvidenceCalls, equals(1));
        },
      );

      // Case 2b: Crash after durable upload marker and persistServerAssessmentId, before upload RPC writes bytes.
      late String case2bAssessmentId;
      await runCrashBoundaryCase(
        draftId: 'b1-18-case2b-after-marker-before-upload',
        createCommandId: 'cmd-c-b118-2b',
        submitCommandId: 'cmd-s-b118-2b',
        evidenceId: '33333333-3333-4333-8333-000000001822',
        crashStageLabel: 'Case 2b: after marker + createDraft, before upload',
        configureCrash: (crashStore, mockHttp) {
          mockHttp.onBeforeUpload = () async {
            mockHttp.onBeforeUpload = null;
            crashStore.tripHardCrash();
            throw const _SimulatedProcessCrashException('case2b_before_upload');
          };
        },
        verifyPostCrash: (crashedRow, mockHttp) {
          expect(
            crashedRow.dispatchState,
            equals(CommandDispatchState.possiblyDispatched),
          );
          expect(
            crashedRow.submissionStatus,
            equals(DraftSubmissionStatus.uploadingEvidence),
          );
          expect(crashedRow.serverAssessmentId, isNotNull);
          expect(crashedRow.serverEvidenceId, isNull);
          case2bAssessmentId = crashedRow.serverAssessmentId!;
          expect(repo.createDraftCalls, equals(1));
          expect(mockHttp.uploadCallCount, equals(1));
          expect(mockHttp.successfulUploadWrites, equals(0));
          expect(mockHttp.remoteStorage, isEmpty);
          expect(repo.registerEvidenceCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));
        },
        verifyPostResume: (confirmed, mockHttp) async {
          expect(confirmed.assessment.id.value, equals(case2bAssessmentId));
          expect(repo.createDraftCalls, equals(0));
          expect(mockHttp.uploadCallCount, equals(2));
          expect(mockHttp.successfulUploadWrites, equals(1));
          expect(mockHttp.rejectedNoUpsertUploadAttempts, equals(0));
          expect(repo.registerEvidenceCalls, equals(1));
        },
      );

      // Case 3: Crash during uncertain upload (Storage write committed before HTTP response returned).
      late String case3AssessmentId;
      await runCrashBoundaryCase(
        draftId: 'b1-18-case3-uncertain-upload',
        createCommandId: 'cmd-c-b118-3',
        submitCommandId: 'cmd-s-b118-3',
        evidenceId: '33333333-3333-4333-8333-000000001803',
        crashStageLabel: 'Case 3: during uncertain upload',
        configureCrash: (crashStore, mockHttp) {
          mockHttp.onAfterRemoteWriteBeforeResponse = () async {
            mockHttp.onAfterRemoteWriteBeforeResponse = null;
            crashStore.tripHardCrash();
            throw const _SimulatedProcessCrashException(
              'case3_during_uncertain_upload',
            );
          };
        },
        verifyPostCrash: (crashedRow, mockHttp) {
          expect(
            crashedRow.dispatchState,
            equals(CommandDispatchState.possiblyDispatched),
          );
          expect(
            crashedRow.submissionStatus,
            equals(DraftSubmissionStatus.uploadingEvidence),
          );
          expect(crashedRow.serverAssessmentId, isNotNull);
          expect(crashedRow.serverEvidenceId, isNull);
          case3AssessmentId = crashedRow.serverAssessmentId!;
          expect(repo.createDraftCalls, equals(1));
          expect(mockHttp.uploadCallCount, equals(1));
          expect(mockHttp.successfulUploadWrites, equals(1));
          expect(mockHttp.remoteStorage.length, equals(1));
          expect(repo.registerEvidenceCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));
        },
        verifyPostResume: (confirmed, mockHttp) async {
          expect(confirmed.assessment.id.value, equals(case3AssessmentId));
          expect(repo.createDraftCalls, equals(0));
          expect(mockHttp.uploadCallCount, equals(2));
          expect(mockHttp.successfulUploadWrites, equals(1));
          expect(mockHttp.rejectedNoUpsertUploadAttempts, equals(1));
          expect(mockHttp.downloadCallCount, equals(1));
          expect(repo.registerEvidenceCalls, equals(1));
        },
      );

      // Case 4: Crash after successful upload (HTTP 200), before registerEvidence RPC.
      late String case4AssessmentId;
      await runCrashBoundaryCase(
        draftId: 'b1-18-case4-after-upload-before-register',
        createCommandId: 'cmd-c-b118-4',
        submitCommandId: 'cmd-s-b118-4',
        evidenceId: '33333333-3333-4333-8333-000000001804',
        crashStageLabel: 'Case 4: after successful upload, before register',
        configureCrash: (crashStore, mockHttp) {
          repo.onBeforeRegister = () async {
            repo.onBeforeRegister = null;
            crashStore.tripHardCrash();
            throw const _SimulatedProcessCrashException(
              'case4_before_register',
            );
          };
        },
        verifyPostCrash: (crashedRow, mockHttp) {
          expect(
            crashedRow.dispatchState,
            equals(CommandDispatchState.possiblyDispatched),
          );
          expect(
            crashedRow.submissionStatus,
            equals(DraftSubmissionStatus.uploadingEvidence),
          );
          expect(crashedRow.serverAssessmentId, isNotNull);
          expect(crashedRow.serverEvidenceId, isNull);
          case4AssessmentId = crashedRow.serverAssessmentId!;
          expect(repo.createDraftCalls, equals(1));
          expect(mockHttp.uploadCallCount, equals(1));
          expect(mockHttp.successfulUploadWrites, equals(1));
          expect(mockHttp.remoteStorage.length, equals(1));
          expect(repo.registerEvidenceCalls, equals(1));
          expect(repo.submitAssessmentCalls, equals(0));
        },
        verifyPostResume: (confirmed, mockHttp) async {
          expect(confirmed.assessment.id.value, equals(case4AssessmentId));
          expect(repo.createDraftCalls, equals(0));
          expect(mockHttp.uploadCallCount, equals(2));
          expect(mockHttp.successfulUploadWrites, equals(1));
          expect(mockHttp.rejectedNoUpsertUploadAttempts, equals(1));
          expect(mockHttp.downloadCallCount, equals(1));
          expect(repo.registerEvidenceCalls, equals(1));
        },
      );

      // Case 5: Crash after createDraft committed on server, but response lost before persistServerAssessmentId.
      final beforeCase5Count = repo.assessments.length;
      late String case5CommittedId;
      await runCrashBoundaryCase(
        draftId: 'b1-18-case5-after-create-lost-response',
        createCommandId: 'cmd-c-b118-5',
        submitCommandId: 'cmd-s-b118-5',
        evidenceId: '33333333-3333-4333-8333-000000001805',
        crashStageLabel: 'Case 5: after createDraft committed, response lost',
        configureCrash: (crashStore, mockHttp) {
          repo.onAfterCreate = () async {
            repo.onAfterCreate = null;
            crashStore.tripHardCrash();
            throw const _SimulatedProcessCrashException(
              'case5_after_create_lost_response',
            );
          };
        },
        verifyPostCrash: (crashedRow, mockHttp) {
          expect(
            crashedRow.dispatchState,
            equals(CommandDispatchState.possiblyDispatched),
          );
          expect(
            crashedRow.submissionStatus,
            equals(DraftSubmissionStatus.uploadingEvidence),
          );
          expect(crashedRow.serverAssessmentId, isNull);
          expect(crashedRow.serverEvidenceId, isNull);
          expect(repo.createDraftCalls, equals(1));
          expect(repo.commandToAssessmentId['cmd-c-b118-5'], isNotNull);
          case5CommittedId = repo.commandToAssessmentId['cmd-c-b118-5']!;
          expect(repo.assessments.length, equals(beforeCase5Count + 1));
          expect(mockHttp.uploadCallCount, equals(0));
          expect(mockHttp.successfulUploadWrites, equals(0));
          expect(repo.registerEvidenceCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));
        },
        verifyPostResume: (confirmed, mockHttp) async {
          expect(confirmed.assessment.id.value, equals(case5CommittedId));
          expect(repo.createDraftCalls, equals(1));
          expect(repo.assessments.length, equals(beforeCase5Count + 1));
          expect(mockHttp.uploadCallCount, equals(1));
          expect(mockHttp.successfulUploadWrites, equals(1));
          expect(mockHttp.rejectedNoUpsertUploadAttempts, equals(0));
          expect(repo.registerEvidenceCalls, equals(1));
        },
      );
    });

    test('B1-19: Crash after evidence registration (row.id != evidenceId) before local persistence reconciles exact row & bytes (I02, I05, I11)', () async {
      const draftId = 'b1-19-crash-after-reg';
      const clientEvId = '33333333-3333-4333-8333-000000000019';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b119',
        submitCommandId: 'cmd-s-b119',
        evidenceId: clientEvId,
        evidenceBytes: jpegHeaderBytes,
      );

      String? remoteEvId;
      repo.onAfterRegister = () async {
        repo.onAfterRegister = null;
        remoteEvId = repo.recordedRegistrations.last.id.value;
        throw StateError('Simulated crash before persistServerEvidenceId');
      };

      final orchestrator = buildOrchestrator();
      await expectLater(
        () => executeDraft(
          orchestrator,
          localDraftId: draftId,
          createCommandId: 'cmd-c-b119',
          submitCommandId: 'cmd-s-b119',
          evidenceId: clientEvId,
        ),
        throwsStateError,
      );

      await reopenDb();
      final preResume = await db.getLocalDraft(draftId);
      expect(preResume?.serverAssessmentId, isNotNull);
      expect(preResume?.serverEvidenceId, isNull);
      expect(remoteEvId, isNotNull);
      expect(remoteEvId, isNot(equals(clientEvId)));

      repo.resetCounts();
      storage.uploadCallCount = 0;
      storage.reconcileCallCount = 0;

      final recovered = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftId,
        createCommandId: 'cmd-c-b119',
        submitCommandId: 'cmd-s-b119',
        evidenceId: clientEvId,
      );
      expect(recovered, isA<AssessmentSubmissionConfirmed>());
      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(storage.reconcileCallCount, equals(1));
      expect(repo.submitAssessmentCalls, equals(1));
      expect(storage.deleteCallCount, equals(0));

      final afterResume = await (await reopenDb()).getLocalDraft(draftId);
      expect(afterResume?.serverEvidenceId, equals(remoteEvId));
      expect(afterResume?.evidenceId, equals(clientEvId));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-20: Lost submit response preserves submitCommandId: idempotent retry confirms; Step 4 42501 stays ambiguous (I11, I13, I14)', () async {
      // Case A: submitAssessment committed on server before TimeoutException dropped response; replay confirms idempotently
      const draftIdA = 'b1-20-lost-submit-ok';
      const evIdA = '33333333-3333-4333-8333-000000000020';
      final seededA = await seedDraft(
        localDraftId: draftIdA,
        createCommandId: 'cmd-c-b120a',
        submitCommandId: 'cmd-s-b120a',
        evidenceId: evIdA,
        evidenceBytes: jpegHeaderBytes,
      );
      repo.onAfterSubmit = () async {
        repo.onAfterSubmit = null;
        throw TimeoutException('HTTP response dropped after commit');
      };

      final orchestrator = buildOrchestrator();
      final first = await executeDraft(
        orchestrator,
        localDraftId: draftIdA,
        createCommandId: 'cmd-c-b120a',
        submitCommandId: 'cmd-s-b120a',
        evidenceId: evIdA,
      );
      expect(first, isA<AssessmentSubmissionRetryScheduled>());
      expect(
        repo.assessments.values.single.status,
        equals(AssessmentStatus.pendingReview),
      );

      await reopenDb();
      clock.advance(const Duration(minutes: 5));
      repo.resetCounts();
      storage.uploadCallCount = 0;

      final replay = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftIdA,
        createCommandId: 'cmd-c-b120a',
        submitCommandId: 'cmd-s-b120a',
        evidenceId: evIdA,
      );
      expect(replay, isA<AssessmentSubmissionConfirmed>());
      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(1));
      expect(repo.recordedSubmitCommandIds.last, equals('cmd-s-b120a'));
      expect(repo.assessments.length, equals(1));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        seededA.localCompressedPhotoPath,
        jpegHeaderBytes,
      );

      // Case B: Replay returns 42501 when actor membership revoked before Step 6 receipt check -> AMBIGUOUS_42501_OUTCOME
      const draftIdB = 'b1-20-lost-submit-42501';
      const evIdB = '33333333-3333-4333-8333-000000000120';
      final seededB = await seedDraft(
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b120b',
        submitCommandId: 'cmd-s-b120b',
        evidenceId: evIdB,
        evidenceBytes: jpegHeaderBytes,
      );
      repo.onAfterSubmit = () async {
        repo.onAfterSubmit = null;
        throw TimeoutException('Lost submit response');
      };
      final firstB = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b120b',
        submitCommandId: 'cmd-s-b120b',
        evidenceId: evIdB,
      );
      expect(firstB, isA<AssessmentSubmissionRetryScheduled>());

      clock.advance(const Duration(minutes: 5));
      authzPort.setDefaultAdultResult(
        const AdultTargetAuthorizationResult.confirmedRevoked(),
      );
      final outB = await executeDraft(
        buildOrchestrator(),
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b120b',
        submitCommandId: 'cmd-s-b120b',
        evidenceId: evIdB,
      );
      expect(outB, isA<AssessmentSubmissionQuarantined>());
      expect(
        (outB as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(storage.deleteCallCount, equals(0));
      final rowB = await db.getLocalDraft(draftIdB);
      expect(rowB?.submitCommandId, equals('cmd-s-b120b'));
      expectCanonicalFileIntact(
        seededB.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-21: Multi-connection SQLite contention + Completer barriers elect single winner & block duplicate stage RPCs (I08, I09)', () async {
      const draftId = 'b1-21-two-conn';
      const createCmd = 'cmd-c-b121';
      const submitCmd = 'cmd-s-b121';
      const evId = '33333333-3333-4333-8333-000000000021';

      final conn2 = AppDatabase(NativeDatabase(dbFile));
      addTearDown(() async => conn2.close());

      // 1. Concurrent direct-submit registration on two independent connections elects single winner.
      final unregisteredDraft = await seedDraft(
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
        persistViaCas: false,
      );
      final regResults = await Future.wait([
        db.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: unregisteredDraft,
          now: baseNow,
        ),
        conn2.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: unregisteredDraft,
          now: baseNow,
        ),
      ]);
      expect(regResults.where((r) => r.isSuccess).length, equals(1));
      expect(
        regResults.where((r) => r.status == DraftCasStatus.casConflict).length,
        equals(1),
      );

      // 2. Concurrent execution across conn1 & conn2 with barrier while conn1 holds lease.
      final enteredSubmit = Completer<void>();
      final releaseSubmit = Completer<void>();
      repo.onBeforeSubmit = () async {
        if (!enteredSubmit.isCompleted) {
          enteredSubmit.complete();
          await releaseSubmit.future;
        }
      };

      final orch1 = buildOrchestrator(storeOverride: db);
      final orch2 = buildOrchestrator(storeOverride: conn2);

      final f1 = executeDraft(
        orch1,
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      await enteredSubmit.future;

      final f2Outcome = await executeDraft(
        orch2,
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      expect(f2Outcome, isA<AssessmentSubmissionLeaseConflict>());
      expect(repo.createDraftCalls, equals(1));
      expect(storage.uploadCallCount, equals(1));
      expect(repo.registerEvidenceCalls, equals(1));
      expect(repo.submitAssessmentCalls, equals(1));

      releaseSubmit.complete();
      final f1Outcome = await f1;
      expect(f1Outcome, isA<AssessmentSubmissionConfirmed>());
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        unregisteredDraft.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-22: Expired lease takeover across independent SQLite connections fences stale worker across every CAS op (I09)', () async {
      const draftId = 'b1-22-takeover';
      const evId = '33333333-3333-4333-8333-000000000022';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b122',
        submitCommandId: 'cmd-s-b122',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );

      final conn2 = AppDatabase(NativeDatabase(dbFile));
      addTearDown(() async => conn2.close());

      final claim1 = await db.acquireDraftClaim(
        localDraftId: draftId,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      final staleToken = claim1.draft!.leaseToken!;
      await db.markDraftStageAndDispatch(
        localDraftId: draftId,
        leaseToken: staleToken,
        authenticatedActorId: 'actor-parent-1',
        targetStage: DraftSubmissionStatus.uploadingEvidence,
        now: baseNow,
      );

      // Lease expires; Worker 2 on conn2 reclaims and completes submission.
      final reclaimTime = baseNow.add(const Duration(minutes: 3));
      final claim2 = await conn2.resumeDraftClaimAfterExpiry(
        localDraftId: draftId,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: reclaimTime,
      );
      expect(claim2.isSuccess, isTrue);
      final freshToken = claim2.draft!.leaseToken!;
      expect(freshToken, isNot(equals(staleToken)));

      // Every stale CAS call with staleToken fails closed without touching Worker 2's lease.
      final staleOps = await Future.wait([
        db.markDraftStageAndDispatch(
          localDraftId: draftId,
          leaseToken: staleToken,
          authenticatedActorId: 'actor-parent-1',
          targetStage: DraftSubmissionStatus.submittingAssessment,
          now: reclaimTime,
        ),
        db.persistServerAssessmentId(
          localDraftId: draftId,
          leaseToken: staleToken,
          authenticatedActorId: 'actor-parent-1',
          serverAssessmentId: 'stale-a-1',
          now: reclaimTime,
        ),
        db.persistServerEvidenceId(
          localDraftId: draftId,
          leaseToken: staleToken,
          authenticatedActorId: 'actor-parent-1',
          serverEvidenceId: 'stale-ev-1',
          expectedEvidenceId: evId,
          expectedSha256Checksum: seeded.sha256Checksum!,
          now: reclaimTime,
        ),
        db.scheduleDraftRetry(
          localDraftId: draftId,
          leaseToken: staleToken,
          authenticatedActorId: 'actor-parent-1',
          nextAttemptAt: reclaimTime.add(const Duration(minutes: 1)),
          recoveryCode: DraftRecoveryCode.retryScheduled,
          errorMessage: 'stale error',
          now: reclaimTime,
        ),
        db.quarantineDraftOutcome(
          localDraftId: draftId,
          leaseToken: staleToken,
          authenticatedActorId: 'actor-parent-1',
          recoveryCode: DraftRecoveryCode.storageContentConflict,
          errorMessage: 'stale quarantine',
          now: reclaimTime,
        ),
        db.completeDraftSubmission(
          localDraftId: draftId,
          leaseToken: staleToken,
          authenticatedActorId: 'actor-parent-1',
          serverAssessmentId: 'stale-a-1',
          now: reclaimTime,
        ),
        db.releaseDraftClaim(
          localDraftId: draftId,
          leaseToken: staleToken,
          authenticatedActorId: 'actor-parent-1',
          now: reclaimTime,
        ),
      ]);
      expect(staleOps.every((r) => !r.isSuccess), isTrue);

      // Worker 2's lease token still intact and commits cleanly.
      final completed = await conn2.completeDraftSubmission(
        localDraftId: draftId,
        leaseToken: freshToken,
        authenticatedActorId: 'actor-parent-1',
        serverAssessmentId: 'srv-winner-b122',
        serverEvidenceId: 'srv-ev-winner-b122',
        now: reclaimTime,
      );
      expect(completed.isSuccess, isTrue);
      expect(
        completed.draft?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-23: Concurrent editor/autosave cannot overwrite leased/dispatched/quarantined state or immutable IDs/hashes (I10, I15)', () async {
      const draftId = 'b1-23-editor-guard';
      const evId = '33333333-3333-4333-8333-000000000023';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b123',
        submitCommandId: 'cmd-s-b123',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );

      // 1. Acquire active lease and verify saveLocalDraft & CAS update reject mutations
      final claim = await db.acquireDraftClaim(
        localDraftId: draftId,
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      final leased = claim.draft!;
      await expectLater(
        () => db.saveLocalDraft(leased.copyWith(title: 'Autosave Tamper')),
        throwsA(isA<DraftWriteConflictException>()),
      );
      final casLeased = await db.registerOrUpdateDraftIfUnchanged(
        expected: seeded,
        desired: seeded.copyWith(title: 'Autosave Tamper'),
        now: baseNow,
      );
      expect(casLeased.isSuccess, isFalse);

      // 2. Quarantined state rejects saveLocalDraft, deleteLocalDraft, and CAS edit
      await db.quarantineDraftOutcome(
        localDraftId: draftId,
        leaseToken: leased.leaseToken!,
        authenticatedActorId: 'actor-parent-1',
        recoveryCode: DraftRecoveryCode.storageContentConflict,
        errorMessage: 'conflict',
        now: baseNow,
      );
      final quarantined = (await db.getLocalDraft(draftId))!;
      await expectLater(
        () => db.saveLocalDraft(
          quarantined.copyWith(title: 'Post-quarantine edit'),
        ),
        throwsA(isA<DraftWriteConflictException>()),
      );
      await expectLater(
        () => db.deleteLocalDraft(draftId),
        throwsA(isA<DraftWriteConflictException>()),
      );
      final casQuarantinedRaw = await db.registerOrUpdateDraftIfUnchanged(
        expected: quarantined,
        desired: quarantined.copyWith(rawScore: 5.0),
        now: baseNow,
      );
      expect(casQuarantinedRaw.isSuccess, isFalse);
      final casQuarantinedStrip = await db.registerOrUpdateDraftIfUnchanged(
        expected: quarantined,
        desired: quarantined.copyWith(
          rawScore: 5.0,
          submissionStatus: DraftSubmissionStatus.draft,
          dispatchState: CommandDispatchState.neverDispatched,
          lastErrorMessage: null,
        ),
        now: baseNow,
      );
      expect(
        casQuarantinedStrip.status,
        equals(DraftCasStatus.blockedQuarantined),
      );

      // Re-check persisted values unchanged and canonical file intact
      final persisted = (await reopenDb()).getLocalDraft(draftId);
      expect((await persisted)?.title, equals('WP5 Fraction Quiz'));
      expect((await persisted)?.rawScore, equals(9.0));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-24: Cross-family, cross-child, and cross-assessment mismatches reject fail-closed with zero mutations (I01, I02, I07, I09)', () async {
      // 1. Journal belongs to familyId/childId, execute called with wrong family/child -> quarantined block
      const draftIdA = 'b1-24-scope-a';
      final seededA = await seedDraft(
        localDraftId: draftIdA,
        createCommandId: 'cmd-c-b124a',
        submitCommandId: 'cmd-s-b124a',
        evidenceBytes: jpegHeaderBytes,
      );
      final orchestrator = buildOrchestrator();
      final crossFamilyOut = await executeDraft(
        orchestrator,
        localDraftId: draftIdA,
        overrideFamilyId: otherFamilyId,
        createCommandId: 'cmd-c-b124a',
        submitCommandId: 'cmd-s-b124a',
      );
      expect(crossFamilyOut, isA<AssessmentSubmissionQuarantined>());
      expect(
        (crossFamilyOut as AssessmentSubmissionQuarantined).casStatus,
        equals(DraftCasStatus.familyOrChildMismatch),
      );
      final crossChildOut = await executeDraft(
        orchestrator,
        localDraftId: draftIdA,
        overrideChildId: otherChildId,
        createCommandId: 'cmd-c-b124a',
        submitCommandId: 'cmd-s-b124a',
      );
      expect(
        (crossChildOut as AssessmentSubmissionQuarantined).casStatus,
        equals(DraftCasStatus.familyOrChildMismatch),
      );
      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));

      // 2. Remote assessment belongs to different child -> versionConflict quarantine before Stage B/C
      const draftIdB = 'b1-24-remote-scope';
      const evIdB = '33333333-3333-4333-8333-000000000124';
      await seedDraft(
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b124b',
        submitCommandId: 'cmd-s-b124b',
        evidenceId: evIdB,
        evidenceBytes: jpegHeaderBytes,
      );
      await repo.createDraft(
        commandId: 'cmd-c-b124b',
        familyId: familyId,
        childId: otherChildId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      repo.resetCounts();

      final remoteScopeOut = await executeDraft(
        orchestrator,
        localDraftId: draftIdB,
        createCommandId: 'cmd-c-b124b',
        submitCommandId: 'cmd-s-b124b',
        evidenceId: evIdB,
      );
      expect(remoteScopeOut, isA<AssessmentSubmissionQuarantined>());
      expect(
        (remoteScopeOut as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.versionConflict),
      );
      expect(storage.uploadCallCount, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        seededA.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-25: Version enforcement: expectedVersion 1 only; remote draft v>1 quarantines UNRECONSTRUCTABLE_EXPECTED_VERSION; LW101/LW107 quarantine (I11, I13)', () async {
      // 1. Remote draft with version > 1 quarantines without adopting remote version
      const v2DraftId = 'b1-25-v2';
      await seedDraft(
        localDraftId: v2DraftId,
        createCommandId: 'cmd-c-b125-v2',
        submitCommandId: 'cmd-s-b125-v2',
        evidenceBytes: null,
      );
      final a2 = await repo.createDraft(
        commandId: 'cmd-c-b125-v2',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      await repo.updateDraft(
        assessmentId: a2.id,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'WP5 Fraction Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
        occurredAt: baseNow,
        expectedVersion: 1,
      );
      repo.resetCounts();

      final orchestrator = buildOrchestrator();
      final v2Out = await executeDraft(
        orchestrator,
        localDraftId: v2DraftId,
        createCommandId: 'cmd-c-b125-v2',
        submitCommandId: 'cmd-s-b125-v2',
        hasEvidence: false,
      );
      expect(v2Out, isA<AssessmentSubmissionQuarantined>());
      expect(
        (v2Out as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.unreconstructableExpectedVersion),
      );
      expect(repo.submitAssessmentCalls, equals(0));

      // 2. LW101 & LW107 on submitAssessment always use expectedVersion: 1 and quarantine safely
      for (final errCase in [
        ('LW101', DraftRecoveryCode.versionConflict),
        ('LW107', DraftRecoveryCode.ambiguousSubmitOutcome),
      ]) {
        final id = 'b1-25-${errCase.$1}';
        await seedDraft(
          localDraftId: id,
          createCommandId: 'cmd-c-$id',
          submitCommandId: 'cmd-s-$id',
          evidenceBytes: jpegHeaderBytes,
          evidenceId:
              '33333333-3333-4333-8333-00000001${errCase.$1.substring(2)}',
        );
        repo.recordedSubmitExpectedVersions.clear();
        repo.nextSubmitError = BackendRpcException(
          message: 'Simulated ${errCase.$1}',
          code: errCase.$1,
        );
        final out = await executeDraft(
          orchestrator,
          localDraftId: id,
          createCommandId: 'cmd-c-$id',
          submitCommandId: 'cmd-s-$id',
          evidenceId:
              '33333333-3333-4333-8333-00000001${errCase.$1.substring(2)}',
        );
        expect(out, isA<AssessmentSubmissionQuarantined>());
        expect(
          (out as AssessmentSubmissionQuarantined).recoveryCode,
          equals(errCase.$2),
        );
        expect(repo.recordedSubmitExpectedVersions, equals([1]));
        expect(storage.deleteCallCount, equals(0));
      }
    });

    test('B1-26: Legacy/unbound/unverified-in-flight/unknown-wire rows derive read-only quarantine without SQLite rewrite across restart (I07, I10, I15)', () async {
      final ts = baseNow.millisecondsSinceEpoch ~/ 1000;
      final rawFile = File('${tempDir.path}/legacy_mutable.jpg')
        ..writeAsBytesSync(jpegHeaderBytes);

      // Insert 4 SQLite rows directly simulating legacy/corrupt on-disk states:
      await db.customStatement('''
          INSERT INTO local_assessment_drafts (
            local_draft_id, family_id, child_id, subject_key, subject, title,
            assessment_type, difficulty, raw_score, max_score, local_photo_path,
            entry_context, occurred_at, updated_at, submission_status, retry_count,
            dispatch_state, actor_user_id
          ) VALUES
          ('b1-26-unknown-legacy', '${familyId.value}', '${childId.value}', 'math', 'Mathematics',
           'Legacy Draft', 'quiz', 'normal', 8.0, 10.0, '${rawFile.path}', 'shared_child',
           $ts, $ts, 'draft', 0, 'unknown_legacy', 'actor-parent-1'),
          ('b1-26-unbound', '${familyId.value}', '${childId.value}', 'math', 'Mathematics',
           'Unbound Draft', 'quiz', 'normal', 8.0, 10.0, '${rawFile.path}', 'shared_child',
           $ts, $ts, 'draft', 0, 'never_dispatched', NULL),
          ('b1-26-in-flight-no-hash', '${familyId.value}', '${childId.value}', 'math', 'Mathematics',
           'Unverified Bytes', 'quiz', 'normal', 8.0, 10.0, '${rawFile.path}', 'shared_child',
           $ts, $ts, 'uploading_evidence', 0, 'possibly_dispatched', 'actor-parent-1'),
          ('b1-26-unknown-wire', '${familyId.value}', '${childId.value}', 'math', 'Mathematics',
           'Future Wire Status', 'quiz', 'normal', 8.0, 10.0, '${rawFile.path}', 'shared_child',
           $ts, $ts, 'future_status_v7', 0, 'never_dispatched', 'actor-parent-1');
        ''');

      await reopenDb();

      Future<String> rawColumn(String id, String col) async {
        final rows = await db
            .customSelect(
              'SELECT $col AS val FROM local_assessment_drafts WHERE local_draft_id = ?;',
              variables: [Variable<String>(id)],
            )
            .get();
        return rows.single.data['val']?.toString() ?? '<NULL>';
      }

      final orchestrator = buildOrchestrator();

      for (final expectedCase in [
        (
          id: 'b1-26-unknown-legacy',
          code: DraftRecoveryCode.legacyUnknown,
          rawCol: 'dispatch_state',
          expectedRawVal: 'unknown_legacy',
        ),
        (
          id: 'b1-26-unbound',
          code: DraftRecoveryCode.unboundActorProvenance,
          rawCol: 'actor_user_id',
          expectedRawVal: '<NULL>',
        ),
        (
          id: 'b1-26-in-flight-no-hash',
          code: DraftRecoveryCode.legacyInFlightUnverifiedBytes,
          rawCol: 'submission_status',
          expectedRawVal: 'uploading_evidence',
        ),
        (
          id: 'b1-26-unknown-wire',
          code: DraftRecoveryCode.unknownWireStatus,
          rawCol: 'submission_status',
          expectedRawVal: 'future_status_v7',
        ),
      ]) {
        final loaded = await db.getLocalDraft(expectedCase.id);
        expect(loaded, isNotNull);
        expect(loaded!.isReadOnlyQuarantined, isTrue);
        expect(loaded.canAutoSubmit, isFalse);
        expect(loaded.derivedQuarantineCode, equals(expectedCase.code));

        // Verify SQLite underlying column was NOT rewritten by deserialization or attempt
        expect(
          await rawColumn(expectedCase.id, expectedCase.rawCol),
          equals(expectedCase.expectedRawVal),
        );

        // Edits and dispatch must all fail closed with 0 RPCs
        final editRes = await db.registerOrUpdateDraftIfUnchanged(
          expected: loaded,
          desired: loaded.copyWith(
            actorUserId: 'actor-parent-1',
            title: 'Tamper Attempt',
          ),
          now: baseNow,
        );
        expect(editRes.isSuccess, isFalse);

        final out = await executeDraft(
          orchestrator,
          localDraftId: expectedCase.id,
          title: loaded.title,
          hasEvidence: false,
        );
        expect(out, isA<AssessmentSubmissionQuarantined>());
        expect(
          (out as AssessmentSubmissionQuarantined).recoveryCode,
          equals(expectedCase.code),
        );
        expect(
          await rawColumn(expectedCase.id, expectedCase.rawCol),
          equals(expectedCase.expectedRawVal),
        );
      }

      expect(repo.createDraftCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(repo.submitAssessmentCalls, equals(0));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(rawFile.path, jpegHeaderBytes);
    });

    test('B1-27: Transient retry backoff is bounded, persisted across SQLite restart, and preserves IDs/evidence (I02, I09)', () async {
      const draftId = 'b1-27-backoff';
      const createCmd = 'cmd-c-b127';
      const submitCmd = 'cmd-s-b127';
      const evId = '33333333-3333-4333-8333-000000000027';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
      );

      final orchestrator = buildOrchestrator(
        jitterSource: const DeterministicJitterSource(0.5),
        maxRetryCount: 2,
      );

      // Attempt 1 fails with transient 503 -> retryCount=1, delay=1s
      repo.nextSubmitError = const BackendRpcException(
        message: 'Upstream 503',
        code: '503',
      );
      final out1 = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      expect(out1, isA<AssessmentSubmissionRetryScheduled>());
      expect(
        (out1 as AssessmentSubmissionRetryScheduled).retryCount,
        equals(1),
      );
      expect(
        out1.nextAttemptAt,
        equals(baseNow.add(const Duration(seconds: 1))),
      );

      // Reopen DB before nextAttemptAt -> foreground trigger is gated with 0 RPCs
      await reopenDb();
      final restartedOrch = buildOrchestrator(
        jitterSource: const DeterministicJitterSource(0.5),
        maxRetryCount: 2,
      );
      final callsBefore = repo.submitAssessmentCalls;
      final gatedOut = await executeDraft(
        restartedOrch,
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(gatedOut, isA<AssessmentSubmissionRetryScheduled>());
      expect(repo.submitAssessmentCalls, equals(callsBefore));

      // Attempt 2 due -> retryCount=2, delay=2s
      clock.advance(const Duration(seconds: 2));
      repo.nextSubmitError = const BackendRpcException(
        message: 'Upstream 503',
        code: '503',
      );
      final out2 = await executeDraft(
        restartedOrch,
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      expect(
        (out2 as AssessmentSubmissionRetryScheduled).retryCount,
        equals(2),
      );

      // Attempt 3 exceeds maxRetryCount (2) -> bounded quarantine without changing IDs
      clock.advance(const Duration(seconds: 5));
      repo.nextSubmitError = const BackendRpcException(
        message: 'Upstream 503',
        code: '503',
      );
      final out3 = await executeDraft(
        restartedOrch,
        localDraftId: draftId,
        createCommandId: createCmd,
        submitCommandId: submitCmd,
        evidenceId: evId,
      );
      expect(out3, isA<AssessmentSubmissionQuarantined>());

      final finalRow = await (await reopenDb()).getLocalDraft(draftId);
      expect(finalRow?.createCommandId, equals(createCmd));
      expect(finalRow?.submitCommandId, equals(submitCmd));
      expect(finalRow?.evidenceId, equals(evId));
      expect(finalRow?.sha256Checksum, equals(seeded.sha256Checksum));
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-28: Confirmed submission retains local photos and durable SQLite receipt across restart; blocks deletion (I04, I14)', () async {
      const draftId = 'b1-28-retention';
      const evId = '33333333-3333-4333-8333-000000000028';
      final seeded = await seedDraft(
        localDraftId: draftId,
        createCommandId: 'cmd-c-b128',
        submitCommandId: 'cmd-s-b128',
        evidenceId: evId,
        evidenceBytes: jpegHeaderBytes,
        rawPhotoName: 'raw_retained.jpg',
      );

      final orchestrator = buildOrchestrator();
      final out = await executeDraft(
        orchestrator,
        localDraftId: draftId,
        createCommandId: 'cmd-c-b128',
        submitCommandId: 'cmd-s-b128',
        evidenceId: evId,
      );
      expect(out, isA<AssessmentSubmissionConfirmed>());

      await reopenDb();
      final persisted = await db.getLocalDraft(draftId);
      expect(persisted, isNotNull);
      expect(
        persisted!.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expect(persisted.serverAssessmentId, isNotNull);
      expect(persisted.serverEvidenceId, isNotNull);
      expect(persisted.isUnsafeToDelete(), isTrue);

      final safeDel = await db.deleteDraftSafely(
        localDraftId: draftId,
        expectedDraft: persisted,
        now: baseNow,
      );
      expect(safeDel.status, equals(DraftDeletionStatus.blockedUnsafeState));
      await expectLater(
        () => db.deleteLocalDraft(draftId),
        throwsA(isA<DraftWriteConflictException>()),
      );
      expect(storage.deleteCallCount, equals(0));
      expectCanonicalFileIntact(seeded.localPhotoPath, jpegHeaderBytes);
      expectCanonicalFileIntact(
        seeded.localCompressedPhotoPath,
        jpegHeaderBytes,
      );
    });

    test('B1-29: Wire contract enforces x-upsert:false, bounded download, LW109/42501 mapping, and I16 secret redaction (I03..I07, I12, I16)', () async {
      final mockHttp = _MockStorageHttpClient();
      final sbClient = SupabaseClient(
        'https://mock.supabase.co',
        'anon-key',
        httpClient: mockHttp,
      );
      final realStorage = SupabaseAssessmentEvidenceStorage(
        sbClient,
        authSessionPort: authPort,
      );

      const evId = '33333333-3333-4333-8333-000000000029';
      final uploadedPath = await realStorage.uploadEvidence(
        familyId: familyId,
        childId: childId,
        assessmentId: AssessmentId('44444444-4444-4444-8444-444444444444'),
        evidenceId: EvidenceId(evId),
        bytes: jpegHeaderBytes,
        mediaType: 'image/jpeg',
      );
      expect(uploadedPath, endsWith('/$evId.jpg'));
      final postReq = mockHttp.requests.single;
      expect(
        postReq.headers['x-upsert']?.toLowerCase(),
        anyOf(equals('false'), isNull),
      );

      // Verify I16 secret redaction on PostgrestException through SupabaseAssessmentRepository
      const jwtSecret =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.Wp5SecretSig';
      const bearerSecret = 'Bearer wp5_secret_bearer_token_999';
      final signedUrl =
          'https://proj.supabase.co/storage/v1/object/sign/assessment-evidence/${familyId.value}/${childId.value}/a-1/$evId.jpg?token=wp5SignedToken';
      final rpcHttp = MockClient((req) async {
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 'P0001',
              'message':
                  'LW109 draft error $bearerSecret $jwtSecret $signedUrl',
              'details': null,
              'hint': null,
            }),
          ),
          400,
          request: req,
          headers: {'content-type': 'application/json'},
        );
      });
      final rpcClient = SupabaseClient(
        'https://mock.supabase.co',
        'anon-key',
        httpClient: rpcHttp,
      );
      final realRepo = SupabaseAssessmentRepository(rpcClient);

      try {
        await realRepo.registerEvidence(
          assessmentId: AssessmentId('44444444-4444-4444-8444-444444444444'),
          storagePath: uploadedPath,
          mediaType: 'image/jpeg',
          fileSizeBytes: jpegHeaderBytes.length,
        );
        fail('Expected BackendRpcException');
      } on BackendRpcException catch (e) {
        expect(e.code, equals('LW109'));
        expect(e.message, isNot(contains('wp5_secret_bearer_token_999')));
        expect(e.message, isNot(contains('Wp5SecretSig')));
        expect(e.message, isNot(contains('wp5SignedToken')));
        expect(
          e.message,
          isNot(contains('assessment-evidence/${familyId.value}')),
        );
      }
    });

    test('B1-30: Drift schema remains v6 (30 draft cols, 19 reward cols) and reward/assessment CAS stores operate in strict isolation (I15)', () async {
      expect(db.schemaVersion, equals(6));
      final draftCols = await db
          .customSelect("PRAGMA table_info('local_assessment_drafts');")
          .get();
      final rewardCols = await db
          .customSelect("PRAGMA table_info('pending_reward_commands');")
          .get();
      expect(draftCols.length, equals(30));
      expect(rewardCols.length, equals(19));

      // Co-exist an assessment draft and a pending reward wheel command on the same AppDatabase.
      await seedDraft(
        localDraftId: 'b1-30-draft',
        evidenceBytes: jpegHeaderBytes,
      );
      final rewardReg = await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-wheel-b130',
          familyId: familyId.value,
          childId: childId.value,
          actorUserId: 'actor-parent-1',
          actorRole: 'parent',
          createdAt: baseNow,
          dispatchState: CommandDispatchState.neverDispatched,
        ),
        now: baseNow,
      );
      expect(rewardReg, isA<FreshCommandRegistered>());

      final rewardClaim = await db.acquireClaim(
        commandId: 'cmd-wheel-b130',
        actorUserId: 'actor-parent-1',
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      expect(rewardClaim, isNotNull);

      // Assessment draft remains independently claimable and unaffected by reward command CAS.
      final draftClaim = await db.acquireDraftClaim(
        localDraftId: 'b1-30-draft',
        actorUserId: 'actor-parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      );
      expect(draftClaim.isSuccess, isTrue);
      expect(
        (await db.getPendingCommand('cmd-wheel-b130'))?.leaseToken,
        equals(rewardClaim),
      );
      expect(
        (await db.getLocalDraft('b1-30-draft'))?.leaseToken,
        equals(draftClaim.draft!.leaseToken),
      );
    });
  });
}
