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

final class _DiskCanonicalSnapshotStore
    implements CanonicalEvidenceSnapshotStore {
  _DiskCanonicalSnapshotStore(this.dir);

  final Directory dir;

  @override
  Future<CanonicalEvidenceSnapshot> saveCanonicalEvidenceSnapshot({
    required String localDraftId,
    required List<int> bytes,
  }) async {
    final inspected = inspectAndValidateEvidenceBytes(bytes);
    final file = File(
      '${dir.path}/${localDraftId}_canonical.${inspected.fileExtension}',
    );
    await file.writeAsBytes(inspected.bytes, flush: true);
    return CanonicalEvidenceSnapshot(
      localDraftId: localDraftId,
      filePath: file.path,
      mediaType: inspected.mediaType,
      fileExtension: inspected.fileExtension,
      byteLength: inspected.byteLength,
      sha256Checksum: inspected.sha256Checksum,
      frozenAt: DateTime.utc(2026, 11, 14, 12, 0),
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

final class _ConcurrentlyBarrieredRepository extends FakeAssessmentRepository {
  _ConcurrentlyBarrieredRepository({super.activeActorIdProvider});

  int createDraftCalls = 0;
  int registerEvidenceCalls = 0;
  int submitAssessmentCalls = 0;
  Completer<void>? submitBarrierEntered;
  Completer<void>? submitBarrierRelease;
  bool pauseNextSubmit = false;
  bool syncDriftOnCreateMismatch = false;

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
    final created = await super.createDraft(
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
    if (syncDriftOnCreateMismatch) {
      return created.copyWith(title: 'Divergent Remote Title');
    }
    return created;
  }

  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) {
    registerEvidenceCalls++;
    return super.registerEvidence(
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: fileSizeBytes,
    );
  }

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
    submitAssessmentCalls++;
    if (pauseNextSubmit) {
      pauseNextSubmit = false;
      submitBarrierEntered?.complete();
      if (submitBarrierRelease != null) {
        await submitBarrierRelease!.future;
      }
    }
    return super.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
    );
  }
}

void main() {
  group('WP3 SupabaseAssessmentRepository & Storage Error Mapping (B1-29 / R32-07)', () {
    test('maps PostgrestException codes (LW101, LW107, LW109, 42501, LW001, P0001 embedded) and strips secrets', () async {
      const jwtSecret =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.SecretSigPart99';
      const bearerSecret = 'Bearer super_secret_token_abc123';
      const signedUrl =
          'https://example.supabase.co/storage/v1/object/sign/assessment-evidence/fam-1/ch-1/a-1/ev-1.jpg?token=signedQuerySecret88';

      String nextCode = 'LW101';
      String nextMessage = 'LW101 conflict $bearerSecret $jwtSecret $signedUrl';
      int nextStatus = 400;

      final mockClient = MockClient((request) async {
        final body = utf8.encode(
          jsonEncode({
            'code': nextCode,
            'message': nextMessage,
            'details': null,
            'hint': null,
          }),
        );
        return http.Response.bytes(
          body,
          nextStatus,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-anon-key',
        httpClient: mockClient,
      );
      final repo = SupabaseAssessmentRepository(client);
      final familyId = FamilyId('fam-rpc-1');
      final childId = ChildId('ch-rpc-1');

      for (final tc in <(String, String, int, String)>[
        ('LW101', 'LW101 version conflict', 400, 'LW101'),
        ('LW107', 'LW107 ambiguous command', 400, 'LW107'),
        ('LW109', 'LW109 not in draft', 400, 'LW109'),
        ('42501', 'permission denied for rpc', 403, '42501'),
        ('LW001', 'LW001 family access revoked', 403, 'LW001'),
        ('P0001', 'LW109 embedded inside raise exception', 400, 'LW109'),
      ]) {
        nextCode = tc.$1;
        nextMessage = '${tc.$2} $bearerSecret $jwtSecret $signedUrl';
        nextStatus = tc.$3;

        await expectLater(
          () => repo.createDraft(
            commandId: 'cmd-1',
            familyId: familyId,
            childId: childId,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Algebra',
            type: AssessmentType.quiz,
            difficulty: AssessmentDifficulty.normal,
            score: AssessmentScore(rawScore: 8, maxScore: 10),
          ),
          throwsA(
            isA<BackendRpcException>()
                .having((e) => e.code, 'code', equals(tc.$4))
                .having(
                  (e) => e.message,
                  'redacts jwt',
                  isNot(contains('SecretSigPart99')),
                )
                .having(
                  (e) => e.message,
                  'redacts bearer',
                  isNot(contains('super_secret_token_abc123')),
                )
                .having(
                  (e) => e.message,
                  'redacts signed query token',
                  isNot(contains('signedQuerySecret88')),
                )
                .having(
                  (e) => e.message,
                  'redacts storage path',
                  isNot(contains('assessment-evidence/fam-1')),
                ),
          ),
        );
      }
    });

    test('SupabaseAssessmentEvidenceStorage treats HTTP 401 as auth failure and never deletes remote objects', () async {
      var deleteCalls = 0;
      final mockClient = MockClient((request) async {
        if (request.method.toUpperCase() == 'DELETE') {
          deleteCalls++;
        }
        return http.Response(
          jsonEncode({
            'statusCode': '401',
            'error': 'Unauthorized',
            'message': 'Invalid JWT Bearer tok_abc',
          }),
          401,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-anon-key',
        httpClient: mockClient,
      );
      final authPort = FakeAuthSessionPort(
        activeUserId: 'actor-auth-1',
        sessionGeneration: 'gen-1',
      );
      final storage = SupabaseAssessmentEvidenceStorage(
        client,
        authSessionPort: authPort,
      );

      await expectLater(
        () => storage.uploadEvidence(
          familyId: FamilyId('fam-1'),
          childId: ChildId('ch-1'),
          assessmentId: AssessmentId('a-1'),
          evidenceId: EvidenceId('ev-1'),
          bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2]),
          mediaType: 'image/jpeg',
          expectedSessionGeneration: 'gen-1',
        ),
        throwsA(
          isA<EvidenceStorageAuthException>().having(
            (e) => e.message,
            'redacted token',
            isNot(contains('tok_abc')),
          ),
        ),
      );
      expect(deleteCalls, equals(0));
    });
  });

  group('WP3 File-Backed SQLite Two-Connection Concurrency & Crash Resume (B1-21, B1-22)', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase conn1;
    late _DiskCanonicalSnapshotStore snapshotStore;

    final validJpegBytes = Uint8List.fromList([
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      4,
      5,
      6,
    ]);
    final baseTime = DateTime.utc(2026, 11, 14, 12, 0, 0);
    final familyId = FamilyId('fam-sqlite-1');
    final childId = ChildId('ch-sqlite-1');

    setUpAll(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('learnward_wp3_sqlite_');
      dbFile = File('${tempDir.path}/wp3_concurrent.sqlite');
      conn1 = AppDatabase(NativeDatabase(dbFile));
      snapshotStore = _DiskCanonicalSnapshotStore(tempDir);
    });

    tearDown(() async {
      await conn1.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<LocalAssessmentDraft> seedDraftOnConn(
      AppDatabase db, {
      required String localDraftId,
      bool withEvidence = true,
    }) async {
      CanonicalEvidenceSnapshot? snap;
      if (withEvidence) {
        snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
          localDraftId: localDraftId,
          bytes: validJpegBytes,
        );
      }
      final draft = LocalAssessmentDraft(
        localDraftId: localDraftId,
        familyId: familyId.value,
        childId: childId.value,
        actorUserId: 'parent-1',
        createCommandId: 'cmd-c-$localDraftId',
        submitCommandId: 'cmd-s-$localDraftId',
        evidenceId: withEvidence ? 'ev-$localDraftId' : null,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Concurrent Quiz',
        assessmentType: 'quiz',
        difficulty: 'normal',
        rawScore: 9.0,
        maxScore: 10.0,
        localCompressedPhotoPath: snap?.filePath,
        sha256Checksum: snap?.sha256Checksum,
        occurredAt: baseTime,
        updatedAt: baseTime,
        dispatchState: CommandDispatchState.neverDispatched,
        entryContext: EntryContext.sharedChild,
      );
      final res = await db.registerOrUpdateDraftIfUnchanged(
        expected: null,
        desired: draft,
        now: baseTime,
      );
      expect(res.isSuccess, isTrue);
      return res.draft!;
    }

    test('Worker 2 reclaims expired SQLite lease, skips already-persisted stage A/B, commits, and fences stalled Worker 1 retry/error', () async {
      const draftId = 'sqlite-wp3-takeover';
      await seedDraftOnConn(conn1, localDraftId: draftId, withEvidence: true);

      final conn2 = AppDatabase(NativeDatabase(dbFile));
      addTearDown(() async => conn2.close());

      final authPort = FakeAuthSessionPort(
        activeUserId: 'parent-1',
        sessionGeneration: 'gen-1',
        role: 'parent',
      );
      final repo = _ConcurrentlyBarrieredRepository(
        activeActorIdProvider: () => 'parent-1',
      );
      final storage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
      final authzPort = FakeRecoveryAuthorizationPort();

      final clock1 = TestClock(baseTime);
      final clock2 = TestClock(baseTime.add(const Duration(minutes: 5)));

      final entered = Completer<void>();
      final release = Completer<void>();
      repo.pauseNextSubmit = true;
      repo.submitBarrierEntered = entered;
      repo.submitBarrierRelease = release;

      final worker1 = AssessmentSubmissionOrchestrator(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: conn1,
        recoveryAuthorizationPort: authzPort,
        canonicalSnapshotStore: snapshotStore,
        clock: clock1,
      );
      final worker2 = AssessmentSubmissionOrchestrator(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: conn2,
        recoveryAuthorizationPort: authzPort,
        canonicalSnapshotStore: snapshotStore,
        clock: clock2,
      );

      Future<AssessmentSubmissionOutcome> callWorker(
        AssessmentSubmissionOrchestrator orch,
      ) {
        return orch.execute(
          familyId: familyId,
          childId: childId,
          createCommandId: 'cmd-c-$draftId',
          submitCommandId: 'cmd-s-$draftId',
          evidenceId: EvidenceId('ev-$draftId'),
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Concurrent Quiz',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          occurredAt: baseTime,
          entryContext: EntryContext.sharedChild,
          localDraftId: draftId,
        );
      }

      // Worker 1 persists serverAssessmentId + serverEvidenceId, then stalls on submitAssessment.
      final w1Future = callWorker(worker1);
      await entered.future;

      final midRow = await conn2.getLocalDraft(draftId);
      expect(midRow?.serverAssessmentId, isNotNull);
      expect(midRow?.serverEvidenceId, isNotNull);

      // Reset counters before Worker 2 reclaims expired lease & completes!
      repo.createDraftCalls = 0;
      repo.registerEvidenceCalls = 0;
      storage.uploadCallCount = 0;

      final w2Outcome = await callWorker(worker2);
      expect(w2Outcome, isA<AssessmentSubmissionConfirmed>());
      expect(repo.createDraftCalls, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));

      final committedRow = await conn2.getLocalDraft(draftId);
      expect(
        committedRow?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      final committedAssessmentId = committedRow!.serverAssessmentId!;
      final committedEvidenceId = committedRow.serverEvidenceId!;

      // Release Worker 1 -> converges cleanly without mutating or deleting committed evidence.
      release.complete();
      final w1Outcome = await w1Future;
      expect(w1Outcome, isA<AssessmentSubmissionConfirmed>());

      final afterRow = await conn2.getLocalDraft(draftId);
      expect(
        afterRow?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expect(afterRow?.serverAssessmentId, equals(committedAssessmentId));
      expect(afterRow?.serverEvidenceId, equals(committedEvidenceId));
      expect(storage.deleteCallCount, equals(0));
    });

    test('Stale worker hitting quarantine error after Worker 2 takeover is fenced by SQLite CAS (_quarantineWithLease)', () async {
      const draftId = 'sqlite-wp3-quarantine-fence';
      await seedDraftOnConn(conn1, localDraftId: draftId, withEvidence: false);

      final conn2 = AppDatabase(NativeDatabase(dbFile));
      addTearDown(() async => conn2.close());

      final authPort = FakeAuthSessionPort(
        activeUserId: 'parent-1',
        sessionGeneration: 'gen-1',
        role: 'parent',
      );
      final storage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
      final authzPort = FakeRecoveryAuthorizationPort();

      // Worker 1 acquires lease and pauses inside createDraft before persisting serverAssessmentId;
      // when released, returns mismatched remote title (would trigger _quarantineWithLease).
      final repo1 = _ConcurrentlyBarrieredRepository(
        activeActorIdProvider: () => 'parent-1',
      );
      final repo2 = _ConcurrentlyBarrieredRepository(
        activeActorIdProvider: () => 'parent-1',
      );

      final lease1 = (await conn1.acquireDraftClaim(
        localDraftId: draftId,
        actorUserId: 'parent-1',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseTime,
      )).draft!.leaseToken!;
      await conn1.markDraftStageAndDispatch(
        localDraftId: draftId,
        leaseToken: lease1,
        authenticatedActorId: 'parent-1',
        targetStage: DraftSubmissionStatus.submittingAssessment,
        now: baseTime,
      );
      await conn1.releaseDraftClaim(
        localDraftId: draftId,
        leaseToken: lease1,
        authenticatedActorId: 'parent-1',
        now: baseTime,
      );

      // Now create orchestrator on conn1 that stalls during createDraft while conn2 steals expired lease and commits.
      final enteredCreate = Completer<void>();
      final releaseCreate = Completer<void>();
      final pausedCreateRepo = _CreatePauseRepo(
        entered: enteredCreate,
        release: releaseCreate,
        activeActorIdProvider: () => 'parent-1',
      );

      final worker1 = AssessmentSubmissionOrchestrator(
        repository: pausedCreateRepo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: conn1,
        recoveryAuthorizationPort: authzPort,
        canonicalSnapshotStore: snapshotStore,
        clock: TestClock(baseTime),
      );
      final worker2 = AssessmentSubmissionOrchestrator(
        repository: repo2,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: conn2,
        recoveryAuthorizationPort: authzPort,
        canonicalSnapshotStore: snapshotStore,
        clock: TestClock(baseTime.add(const Duration(minutes: 5))),
      );

      Future<AssessmentSubmissionOutcome> runOn(
        AssessmentSubmissionOrchestrator orch,
      ) {
        return orch.execute(
          familyId: familyId,
          childId: childId,
          createCommandId: 'cmd-c-$draftId',
          submitCommandId: 'cmd-s-$draftId',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Concurrent Quiz',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          occurredAt: baseTime,
          entryContext: EntryContext.sharedChild,
          localDraftId: draftId,
        );
      }

      final w1Future = expectLater(
        () => runOn(worker1),
        throwsA(
          isA<DraftSubmissionCasException>().having(
            (e) => e.casStatus,
            'casStatus',
            anyOf(
              DraftCasStatus.alreadyCommitted,
              DraftCasStatus.leaseConflict,
            ),
          ),
        ),
      );

      await enteredCreate.future;

      final w2Outcome = await runOn(worker2);
      expect(w2Outcome, isA<AssessmentSubmissionConfirmed>());

      releaseCreate.complete();
      await w1Future;

      final committed = await conn2.getLocalDraft(draftId);
      expect(committed?.dispatchState, CommandDispatchState.confirmedCommitted);
      expect(committed?.isReadOnlyQuarantined, isFalse);
      expect(repo1.submitAssessmentCalls, equals(0));
    });

    test('AppDatabase restart after persisted serverAssessmentId + serverEvidenceId resumes without re-creating or re-uploading', () async {
      const draftId = 'sqlite-wp3-restart';
      await seedDraftOnConn(conn1, localDraftId: draftId, withEvidence: true);

      final authPort = FakeAuthSessionPort(
        activeUserId: 'parent-1',
        sessionGeneration: 'gen-1',
        role: 'parent',
      );
      final repo = _ConcurrentlyBarrieredRepository(
        activeActorIdProvider: () => 'parent-1',
      );
      final storage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
      final authzPort = FakeRecoveryAuthorizationPort();

      // Crash right at submitAssessment after Stage A + Stage B durable checkpoints
      final crashRepo = _FailingAfterStageBRepo(
        delegate: repo,
        activeActorIdProvider: () => 'parent-1',
      );

      final preCrash = AssessmentSubmissionOrchestrator(
        repository: crashRepo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: conn1,
        recoveryAuthorizationPort: authzPort,
        canonicalSnapshotStore: snapshotStore,
        clock: TestClock(baseTime),
      );

      await expectLater(
        () => preCrash.execute(
          familyId: familyId,
          childId: childId,
          createCommandId: 'cmd-c-$draftId',
          submitCommandId: 'cmd-s-$draftId',
          evidenceId: EvidenceId('ev-$draftId'),
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Concurrent Quiz',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          occurredAt: baseTime,
          entryContext: EntryContext.sharedChild,
          localDraftId: draftId,
        ),
        throwsStateError,
      );

      // Close & reopen SQLite database (simulate full app process restart)
      await conn1.close();
      final reopened = AppDatabase(NativeDatabase(dbFile));
      addTearDown(() async => reopened.close());

      final persistedBeforeResume = await reopened.getLocalDraft(draftId);
      expect(persistedBeforeResume?.serverAssessmentId, isNotNull);
      expect(persistedBeforeResume?.serverEvidenceId, isNotNull);

      repo.createDraftCalls = 0;
      repo.registerEvidenceCalls = 0;
      storage.uploadCallCount = 0;

      final postRestart = AssessmentSubmissionOrchestrator(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: reopened,
        recoveryAuthorizationPort: authzPort,
        canonicalSnapshotStore: snapshotStore,
        clock: TestClock(baseTime.add(const Duration(seconds: 30))),
      );

      final outcome = await postRestart.execute(
        familyId: familyId,
        childId: childId,
        createCommandId: 'cmd-c-$draftId',
        submitCommandId: 'cmd-s-$draftId',
        evidenceId: EvidenceId('ev-$draftId'),
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Concurrent Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseTime,
        entryContext: EntryContext.sharedChild,
        localDraftId: draftId,
      );

      expect(outcome, isA<AssessmentSubmissionConfirmed>());
      expect(repo.createDraftCalls, equals(0));
      expect(repo.registerEvidenceCalls, equals(0));
      expect(storage.uploadCallCount, equals(0));
    });
  });
}

final class _CreatePauseRepo extends FakeAssessmentRepository {
  _CreatePauseRepo({
    required this.entered,
    required this.release,
    super.activeActorIdProvider,
  });

  final Completer<void> entered;
  final Completer<void> release;

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
    entered.complete();
    await release.future;
    final created = await super.createDraft(
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
    return created.copyWith(title: 'Divergent Title');
  }
}

final class _FailingAfterStageBRepo extends FakeAssessmentRepository {
  _FailingAfterStageBRepo({
    required this.delegate,
    super.activeActorIdProvider,
  });

  final FakeAssessmentRepository delegate;

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
  }) => delegate.createDraft(
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

  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) => delegate.registerEvidence(
    assessmentId: assessmentId,
    storagePath: storagePath,
    mediaType: mediaType,
    fileSizeBytes: fileSizeBytes,
  );

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
    throw StateError('Simulated abrupt crash before submitAssessment');
  }
}
