import 'dart:async';
import 'dart:typed_data';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

final class _RecordingRepo extends FakeAssessmentRepository {
  int createDraftCallCount = 0;
  int registerEvidenceCallCount = 0;
  int submitAssessmentCallCount = 0;

  Object? nextRegisterError;
  Object? nextSubmitError;

  final List<String> eventLog = [];

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
    createDraftCallCount++;
    eventLog.add('createDraft:$commandId');
    return super.createDraft(
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
  }

  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) async {
    registerEvidenceCallCount++;
    eventLog.add('registerEvidence:${assessmentId.value}');
    final err = nextRegisterError;
    if (err != null) {
      nextRegisterError = null;
      throw err;
    }
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
    submitAssessmentCallCount++;
    eventLog.add('submitAssessment:$commandId');
    final err = nextSubmitError;
    if (err != null) {
      nextSubmitError = null;
      throw err;
    }
    return super.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
    );
  }
}

final class _InMemoryCanonicalSnapshotStore
    implements CanonicalEvidenceSnapshotStore {
  final Map<String, CanonicalEvidenceSnapshot> _snapshots = {};
  final Map<String, List<int>> _bytes = {};

  @override
  Future<CanonicalEvidenceSnapshot> saveCanonicalEvidenceSnapshot({
    required String localDraftId,
    required List<int> bytes,
  }) async {
    final inspected = inspectAndValidateEvidenceBytes(bytes);
    final path = '/canonical/${localDraftId}_snap.${inspected.fileExtension}';
    final snap = CanonicalEvidenceSnapshot(
      localDraftId: localDraftId,
      filePath: path,
      mediaType: inspected.mediaType,
      fileExtension: inspected.fileExtension,
      byteLength: inspected.byteLength,
      sha256Checksum: inspected.sha256Checksum,
      frozenAt: DateTime.utc(2026, 11, 14, 12, 0),
    );
    _snapshots[path] = snap;
    _bytes[path] = Uint8List.fromList(inspected.bytes);
    return snap;
  }

  void corruptStoredBytes(String path, List<int> newBytes) {
    _bytes[path] = List<int>.from(newBytes);
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
    final path = draft.localCompressedPhotoPath!;
    final raw = _bytes[path];
    if (raw == null) {
      throw StateError('Missing canonical snapshot bytes at $path');
    }
    final verified = verifyCanonicalEvidenceBytes(
      bytes: raw,
      expectedSha256: draft.sha256Checksum!,
    );
    final snap =
        _snapshots[path] ??
        CanonicalEvidenceSnapshot(
          localDraftId: draft.localDraftId,
          filePath: path,
          mediaType: verified.mediaType,
          fileExtension: verified.fileExtension,
          byteLength: verified.byteLength,
          sha256Checksum: verified.sha256Checksum,
          frozenAt: DateTime.utc(2026, 11, 14, 12, 0),
        );
    return VerifiedCanonicalEvidence(snapshot: snap, bytes: verified.bytes);
  }
}

void main() {
  const actorUserId = 'actor-parent-1';
  final familyId = FamilyId('fam-r33-1');
  final childId = ChildId('child-r33-1');

  final jpegBytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 1, 2];
  final pngBytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 3, 4];

  LocalAssessmentDraft buildDraft({
    required String localDraftId,
    String? createCommandId = 'cmd-create-1',
    String? submitCommandId = 'cmd-submit-1',
    String? evidenceId,
    String? localPhotoPath,
    String? localCompressedPhotoPath,
    String? sha256Checksum,
    CommandDispatchState dispatchState = CommandDispatchState.neverDispatched,
    DraftSubmissionStatus submissionStatus = DraftSubmissionStatus.draft,
  }) {
    return LocalAssessmentDraft(
      localDraftId: localDraftId,
      familyId: familyId.value,
      childId: childId.value,
      actorUserId: actorUserId,
      createCommandId: createCommandId,
      submitCommandId: submitCommandId,
      evidenceId: evidenceId,
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'Fraction Checkpoint',
      assessmentType: 'quiz',
      difficulty: 'normal',
      rawScore: 9.0,
      maxScore: 10.0,
      localPhotoPath: localPhotoPath,
      localCompressedPhotoPath: localCompressedPhotoPath,
      sha256Checksum: sha256Checksum,
      occurredAt: DateTime.utc(2026, 11, 14, 9, 0),
      updatedAt: DateTime.utc(2026, 11, 14, 9, 0),
      dispatchState: dispatchState,
      submissionStatus: submissionStatus,
    );
  }

  late _RecordingRepo repo;
  late FakeAuthSessionPort authPort;
  late FakeAssessmentEvidenceStorage storage;
  late TestLocalDraftStore draftStore;
  late _InMemoryCanonicalSnapshotStore snapshotStore;

  setUp(() {
    repo = _RecordingRepo();
    authPort = FakeAuthSessionPort(activeUserId: actorUserId);
    storage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
    draftStore = TestLocalDraftStore();
    snapshotStore = _InMemoryCanonicalSnapshotStore();
  });

  group('R33-04: Pre-dispatch canonical snapshot invariant', () {
    test('rejects evidence-bearing neverDispatched draft lacking canonical snapshot BEFORE lease/possiblyDispatched or RPC', () async {
      const draftId = 'draft-unsnapshotted';
      await draftStore.saveLocalDraft(
        buildDraft(
          localDraftId: draftId,
          evidenceId: 'evi-unsnapshotted',
          localPhotoPath: '/raw/photo.jpg',
        ),
      );

      var claimCalled = false;
      draftStore.onAcquireDraftClaimOverride = (_) async {
        claimCalled = true;
        return null;
      };

      final useCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: draftStore,
      );

      await expectLater(
        () => useCase(
          createCommandId: 'cmd-create-1',
          submitCommandId: 'cmd-submit-1',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Fraction Checkpoint',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          evidenceBytes: jpegBytes,
          evidenceMediaType: 'image/jpeg',
          evidenceId: EvidenceId('evi-unsnapshotted'),
          localDraftId: draftId,
        ),
        throwsA(isA<MissingCanonicalEvidenceSnapshotException>()),
      );

      expect(claimCalled, isFalse);
      expect(repo.createDraftCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));
      expect(storage.uploadCallCount, equals(0));

      final after = await draftStore.getLocalDraft(draftId);
      expect(after!.dispatchState, CommandDispatchState.neverDispatched);
      expect(after.isReadOnlyQuarantined, isFalse);
    });

    test(
      'rejects tampered canonical snapshot bytes before acquiring lease or RPC',
      () async {
        const draftId = 'draft-corrupt-snap';
        final snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
          localDraftId: draftId,
          bytes: jpegBytes,
        );
        await draftStore.saveLocalDraft(
          buildDraft(
            localDraftId: draftId,
            evidenceId: 'evi-corrupt',
            localCompressedPhotoPath: snap.filePath,
            sha256Checksum: snap.sha256Checksum,
          ),
        );
        snapshotStore.corruptStoredBytes(snap.filePath, [
          ...jpegBytes.sublist(0, jpegBytes.length - 1),
          99,
        ]);

        final useCase = SubmitAssessmentDraft(
          repository: repo,
          storage: storage,
          authSessionPort: authPort,
          localDraftStore: draftStore,
          canonicalSnapshotStore: snapshotStore,
        );

        await expectLater(
          () => useCase(
            createCommandId: 'cmd-create-1',
            submitCommandId: 'cmd-submit-1',
            familyId: familyId,
            childId: childId,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Fraction Checkpoint',
            type: AssessmentType.quiz,
            difficulty: AssessmentDifficulty.normal,
            score: AssessmentScore(rawScore: 9, maxScore: 10),
            localDraftId: draftId,
          ),
          throwsA(isA<CanonicalEvidenceValidationException>()),
        );

        expect(repo.createDraftCallCount, equals(0));
        expect(storage.uploadCallCount, equals(0));
        final after = await draftStore.getLocalDraft(draftId);
        expect(after!.dispatchState, CommandDispatchState.neverDispatched);
      },
    );
  });

  group('R33-05: Fail-closed CAS checks & non-masking release', () {
    test('persistServerAssessmentId CAS conflict halts before upload, register, and submit and releases lease', () async {
      const draftId = 'draft-cas-assess-conflict';
      final snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
        localDraftId: draftId,
        bytes: jpegBytes,
      );
      await draftStore.saveLocalDraft(
        buildDraft(
          localDraftId: draftId,
          evidenceId: 'evi-1',
          localCompressedPhotoPath: snap.filePath,
          sha256Checksum: snap.sha256Checksum,
        ),
      );

      draftStore.onPersistServerAssessmentIdOverride = (id, _) async =>
          const DraftCasResult(
            status: DraftCasStatus.casConflict,
            reason: 'Simulated CAS conflict persisting serverAssessmentId',
          );

      final useCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: draftStore,
        canonicalSnapshotStore: snapshotStore,
      );

      await expectLater(
        () => useCase(
          createCommandId: 'cmd-create-1',
          submitCommandId: 'cmd-submit-1',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Fraction Checkpoint',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        ),
        throwsA(
          isA<DraftSubmissionCasException>().having(
            (e) => e.stage,
            'stage',
            DraftCasFailureStage.persistServerAssessmentId,
          ),
        ),
      );

      expect(repo.createDraftCallCount, equals(1));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));

      final after = await draftStore.getLocalDraft(draftId);
      expect(after!.dispatchState, CommandDispatchState.possiblyDispatched);
      expect(after.leaseToken, isNull);
    });

    test('persistServerEvidenceId failure halts before submitAssessment and retains serverAssessmentId', () async {
      const draftId = 'draft-cas-evidence-fail';
      final snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
        localDraftId: draftId,
        bytes: pngBytes,
      );
      await draftStore.saveLocalDraft(
        buildDraft(
          localDraftId: draftId,
          evidenceId: 'evi-2',
          localCompressedPhotoPath: snap.filePath,
          sha256Checksum: snap.sha256Checksum,
        ),
      );

      draftStore.onPersistServerEvidenceIdOverride = (_, _) async =>
          throw StateError('Simulated SQLite write error');

      final useCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: draftStore,
        canonicalSnapshotStore: snapshotStore,
      );

      await expectLater(
        () => useCase(
          createCommandId: 'cmd-create-1',
          submitCommandId: 'cmd-submit-1',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Fraction Checkpoint',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        ),
        throwsA(
          isA<DraftSubmissionCasException>().having(
            (e) => e.stage,
            'stage',
            DraftCasFailureStage.persistServerEvidenceId,
          ),
        ),
      );

      expect(repo.createDraftCallCount, equals(1));
      expect(storage.uploadCallCount, equals(1));
      expect(repo.registerEvidenceCallCount, equals(1));
      expect(repo.submitAssessmentCallCount, equals(0));

      final after = await draftStore.getLocalDraft(draftId);
      expect(after!.serverAssessmentId, isNotNull);
      expect(after.serverEvidenceId, isNull);
      expect(after.leaseToken, isNull);
    });

    test('markDraftStageAndDispatch(submittingAssessment) failure halts before submitAssessment and retains serverEvidenceId without leaking raw cause in toString()', () async {
      const draftId = 'draft-cas-stage-fail';
      final snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
        localDraftId: draftId,
        bytes: jpegBytes,
      );
      await draftStore.saveLocalDraft(
        buildDraft(
          localDraftId: draftId,
          evidenceId: 'evi-stage',
          localCompressedPhotoPath: snap.filePath,
          sha256Checksum: snap.sha256Checksum,
        ),
      );

      draftStore.onMarkDraftStageOverride = (_, targetStage) async {
        if (targetStage == DraftSubmissionStatus.submittingAssessment) {
          throw StateError(
            'Sensitive sqlite failure Bearer eyJhbGciOi.payload.sig /private/bucket/x.jpg',
          );
        }
        return null;
      };

      final useCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: draftStore,
        canonicalSnapshotStore: snapshotStore,
      );

      Object? caught;
      try {
        await useCase(
          createCommandId: 'cmd-create-stage',
          submitCommandId: 'cmd-submit-stage',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Stage Fail',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        );
      } catch (e) {
        caught = e;
      }

      expect(
        caught,
        isA<DraftSubmissionCasException>().having(
          (e) => e.stage,
          'stage',
          DraftCasFailureStage.markSubmittingStage,
        ),
      );
      expect(caught.toString(), isNot(contains('eyJhbGciOi')));
      expect(caught.toString(), isNot(contains('/private/bucket/x.jpg')));
      expect(repo.submitAssessmentCallCount, equals(0));

      final after = await draftStore.getLocalDraft(draftId);
      expect(after!.serverAssessmentId, isNotNull);
      expect(after.serverEvidenceId, isNotNull);
      expect(after.leaseToken, isNull);
    });

    test('completeDraftSubmission failure after confirmed submitAssessment throws AssessmentReconciliationPendingException and avoids confirmedCommitted', () async {
      const draftId = 'draft-completion-fail';
      final snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
        localDraftId: draftId,
        bytes: jpegBytes,
      );
      await draftStore.saveLocalDraft(
        buildDraft(
          localDraftId: draftId,
          evidenceId: 'evi-3',
          localCompressedPhotoPath: snap.filePath,
          sha256Checksum: snap.sha256Checksum,
        ),
      );

      draftStore.onCompleteDraftSubmissionOverride = (_, _) async =>
          const DraftCasResult(
            status: DraftCasStatus.leaseConflict,
            reason: 'Simulated completion lease conflict',
          );

      final useCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: draftStore,
        canonicalSnapshotStore: snapshotStore,
      );

      await expectLater(
        () => useCase(
          createCommandId: 'cmd-create-1',
          submitCommandId: 'cmd-submit-1',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Fraction Checkpoint',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        ),
        throwsA(
          isA<AssessmentReconciliationPendingException>()
              .having(
                (e) => e.casStatus,
                'casStatus',
                DraftCasStatus.leaseConflict,
              )
              .having((e) => e.serverEvidenceId, 'serverEvidenceId', isNotNull),
        ),
      );

      final after = await draftStore.getLocalDraft(draftId);
      expect(after!.dispatchState, CommandDispatchState.possiblyDispatched);
      expect(
        after.submissionStatus,
        DraftSubmissionStatus.submittingAssessment,
      );
      expect(after.serverAssessmentId, isNotNull);
      expect(after.serverEvidenceId, isNotNull);
      expect(after.leaseToken, isNull);
      expect(
        after.recoveryDispositionAt(now: DateTime.utc(2026, 11, 14, 10, 0)),
        DraftRecoveryDisposition.verificationPending,
      );
    });

    test('releaseDraftClaim failure in finally triggers observer callback without masking primary AssessmentReconciliationPendingException', () async {
      const draftId = 'draft-release-nonmask';
      await draftStore.saveLocalDraft(buildDraft(localDraftId: draftId));

      draftStore.onCompleteDraftSubmissionOverride = (_, _) async =>
          throw StateError('Simulated completion failure');
      draftStore.onReleaseDraftClaimOverride = (_) async =>
          const DraftCasResult(
            status: DraftCasStatus.leaseConflict,
            reason: 'Simulated release failure',
          );

      DraftCasStatus? observedReleaseStatus;
      final useCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: draftStore,
        onLeaseReleaseFailure: ({required localDraftId, status, error}) {
          observedReleaseStatus = status;
        },
      );

      await expectLater(
        () => useCase(
          createCommandId: 'cmd-create-1',
          submitCommandId: 'cmd-submit-1',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Fraction Checkpoint',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        ),
        throwsA(isA<AssessmentReconciliationPendingException>()),
      );

      expect(observedReleaseStatus, equals(DraftCasStatus.leaseConflict));
    });
  });

  group('R33-06: Missing local journal fails closed with zero RPC', () {
    test('throws MissingLocalDraftJournalException with zero RPC when row missing or localDraftId omitted', () async {
      final useCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: draftStore,
      );

      await expectLater(
        () => useCase(
          createCommandId: 'cmd-1',
          submitCommandId: 'cmd-2',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Missing Row',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 8, maxScore: 10),
          localDraftId: 'non-existent-draft-id',
        ),
        throwsA(isA<MissingLocalDraftJournalException>()),
      );

      await expectLater(
        () => useCase(
          createCommandId: 'cmd-1',
          submitCommandId: 'cmd-2',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Null Draft Id',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 8, maxScore: 10),
          localDraftId: null,
        ),
        throwsA(isA<MissingLocalDraftJournalException>()),
      );

      expect(repo.createDraftCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));
      expect(storage.uploadCallCount, equals(0));
    });

    test(
      'unjournaledForTesting fails closed if localDraftId is passed',
      () async {
        final unjournaled = SubmitAssessmentDraft.unjournaledForTesting(
          repository: repo,
          storage: storage,
          authSessionPort: authPort,
        );

        await expectLater(
          () => unjournaled(
            createCommandId: 'cmd-1',
            submitCommandId: 'cmd-2',
            familyId: familyId,
            childId: childId,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Bypass attempt',
            type: AssessmentType.quiz,
            difficulty: AssessmentDifficulty.normal,
            score: AssessmentScore(rawScore: 8, maxScore: 10),
            localDraftId: 'should-not-bypass',
          ),
          throwsA(isA<MissingLocalDraftJournalException>()),
        );

        expect(repo.createDraftCallCount, equals(0));
      },
    );
  });

  group('Matrix Scenarios 1-4: Happy paths & lost response recovery', () {
    test('Matrix 1 & 2 (JPEG & PNG): produces canonical snapshot upload, serverEvidenceId persistence before submit, and confirmedCommitted tombstone', () async {
      for (final entry in [('jpg', jpegBytes), ('png', pngBytes)]) {
        final draftId = 'draft-${entry.$1}';
        final snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
          localDraftId: draftId,
          bytes: entry.$2,
        );
        await draftStore.saveLocalDraft(
          buildDraft(
            localDraftId: draftId,
            createCommandId: 'cmd-create-${entry.$1}',
            submitCommandId: 'cmd-submit-${entry.$1}',
            evidenceId: 'evi-${entry.$1}',
            localCompressedPhotoPath: snap.filePath,
            sha256Checksum: snap.sha256Checksum,
          ),
        );

        final useCase = SubmitAssessmentDraft(
          repository: repo,
          storage: storage,
          authSessionPort: authPort,
          localDraftStore: draftStore,
          canonicalSnapshotStore: snapshotStore,
        );

        final result = await useCase(
          createCommandId: 'cmd-create-${entry.$1}',
          submitCommandId: 'cmd-submit-${entry.$1}',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Checkpoint ${entry.$1}',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        );

        expect(result.status, AssessmentStatus.pendingReview);
        final after = await draftStore.getLocalDraft(draftId);
        expect(after!.dispatchState, CommandDispatchState.confirmedCommitted);
        expect(after.serverAssessmentId, equals(result.id.value));
        expect(after.serverEvidenceId, isNotNull);
        expect(after.leaseToken, isNull);
        expect(draftStore.deleteLocalDraftCallCount, equals(0));
      }
    });

    test('Matrix 4: lost registerEvidence and submitAssessment responses retain canonical snapshot and pending journal then converge cleanly on retry', () async {
      const draftId = 'draft-lost-response';
      final snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
        localDraftId: draftId,
        bytes: jpegBytes,
      );
      await draftStore.saveLocalDraft(
        buildDraft(
          localDraftId: draftId,
          createCommandId: 'cmd-create-lost',
          submitCommandId: 'cmd-submit-lost',
          evidenceId: 'evi-lost',
          localCompressedPhotoPath: snap.filePath,
          sha256Checksum: snap.sha256Checksum,
        ),
      );

      final useCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: draftStore,
        canonicalSnapshotStore: snapshotStore,
      );

      // Attempt 1: lost registerEvidence response
      repo.nextRegisterError = StateError('Lost registration response');
      await expectLater(
        () => useCase(
          createCommandId: 'cmd-create-lost',
          submitCommandId: 'cmd-submit-lost',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Lost Resp',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        ),
        throwsStateError,
      );

      final mid1 = await draftStore.getLocalDraft(draftId);
      expect(mid1!.dispatchState, CommandDispatchState.possiblyDispatched);
      expect(mid1.submissionStatus, DraftSubmissionStatus.uploadingEvidence);
      expect(mid1.serverAssessmentId, isNotNull);
      expect(mid1.localCompressedPhotoPath, equals(snap.filePath));
      expect(mid1.sha256Checksum, equals(snap.sha256Checksum));
      expect(mid1.leaseToken, isNull);

      // Attempt 2: registration succeeds, submitAssessment response lost
      repo.nextSubmitError = StateError('Lost submit response');
      await expectLater(
        () => useCase(
          createCommandId: 'cmd-create-lost',
          submitCommandId: 'cmd-submit-lost',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Lost Resp',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        ),
        throwsStateError,
      );

      final mid2 = await draftStore.getLocalDraft(draftId);
      expect(mid2!.dispatchState, CommandDispatchState.possiblyDispatched);
      expect(mid2.submissionStatus, DraftSubmissionStatus.submittingAssessment);
      expect(mid2.serverAssessmentId, equals(mid1.serverAssessmentId));
      expect(mid2.serverEvidenceId, isNotNull);
      expect(mid2.leaseToken, isNull);

      // Attempt 3: succeeds idempotently without duplicating server draft
      final submitted = await useCase(
        createCommandId: 'cmd-create-lost',
        submitCommandId: 'cmd-submit-lost',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Lost Resp',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        localDraftId: draftId,
      );

      expect(submitted.id.value, equals(mid1.serverAssessmentId));
      expect(repo.assessments.length, equals(1));
      final done = await draftStore.getLocalDraft(draftId);
      expect(done!.dispatchState, CommandDispatchState.confirmedCommitted);
      expect(done.serverEvidenceId, equals(mid2.serverEvidenceId));
    });
  });
}
