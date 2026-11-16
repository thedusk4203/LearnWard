import 'dart:async';
import 'dart:typed_data';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

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

final class _ScriptedAssessmentRepository extends FakeAssessmentRepository {
  _ScriptedAssessmentRepository({super.activeActorIdProvider});

  int createDraftCallCount = 0;
  int registerEvidenceCallCount = 0;
  int submitAssessmentCallCount = 0;
  int listEvidenceCallCount = 0;
  final List<String> recordedCreateCommandIds = [];
  final List<String> recordedSubmitCommandIds = [];
  final List<int> recordedExpectedVersions = [];

  Object? nextCreateError;
  Object? nextRegisterError;
  Object? nextSubmitError;

  Future<void> Function()? onBeforeSubmit;
  Future<void> Function()? onBeforeCreate;
  Future<void> Function()? onBeforeRegister;
  Future<void> Function()? onAfterListEvidence;

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
    recordedCreateCommandIds.add(commandId);
    if (onBeforeCreate != null) {
      await onBeforeCreate!();
    }
    final err = nextCreateError;
    if (err != null) {
      nextCreateError = null;
      throw err;
    }
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
    if (onBeforeRegister != null) {
      await onBeforeRegister!();
    }
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
    recordedSubmitCommandIds.add(commandId);
    recordedExpectedVersions.add(expectedVersion);
    if (onBeforeSubmit != null) {
      await onBeforeSubmit!();
    }
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

  @override
  Future<List<AssessmentEvidence>> listEvidenceForAssessment(
    AssessmentId assessmentId,
  ) async {
    listEvidenceCallCount++;
    final res = await super.listEvidenceForAssessment(assessmentId);
    if (onAfterListEvidence != null) {
      await onAfterListEvidence!();
    }
    return res;
  }
}

void main() {
  final validJpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
  final differingJpegBytes = Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    9,
    9,
    9,
    9,
  ]);
  final baseNow = DateTime.utc(2026, 11, 14, 12, 0, 0);
  final familyId = FamilyId('fam-wp3-1');
  final childId = ChildId('ch-wp3-1');

  late FakeAuthSessionPort authPort;
  late _ScriptedAssessmentRepository repo;
  late FakeAssessmentEvidenceStorage storage;
  late FakeRecoveryAuthorizationPort authzPort;
  late TestLocalDraftStore draftStore;
  late _InMemoryCanonicalSnapshotStore snapshotStore;
  late TestClock clock;

  AssessmentSubmissionOrchestrator buildOrchestrator({
    int maxRetryCount = 5,
    JitterSource jitterSource = const DeterministicJitterSource(0.0),
  }) {
    return AssessmentSubmissionOrchestrator(
      repository: repo,
      storage: storage,
      authSessionPort: authPort,
      localDraftStore: draftStore,
      recoveryAuthorizationPort: authzPort,
      canonicalSnapshotStore: snapshotStore,
      clock: clock,
      jitterSource: jitterSource,
      maxRetryCount: maxRetryCount,
    );
  }

  Future<LocalAssessmentDraft> seedCanonicalDraft({
    required String localDraftId,
    String createCommandId = 'cmd-create-1',
    String submitCommandId = 'cmd-submit-1',
    String? evidenceId = 'ev-wp3-1',
    String actorUserId = 'actor-a',
    bool withEvidence = true,
    CommandDispatchState dispatchState = CommandDispatchState.neverDispatched,
    DraftSubmissionStatus submissionStatus = DraftSubmissionStatus.draft,
    String? serverAssessmentId,
    String? serverEvidenceId,
  }) async {
    CanonicalEvidenceSnapshot? snap;
    if (withEvidence) {
      snap = await snapshotStore.saveCanonicalEvidenceSnapshot(
        localDraftId: localDraftId,
        bytes: validJpegBytes,
      );
    }
    final initialDraft = LocalAssessmentDraft(
      localDraftId: localDraftId,
      familyId: familyId.value,
      childId: childId.value,
      actorUserId: actorUserId,
      createCommandId: createCommandId,
      submitCommandId: submitCommandId,
      evidenceId: withEvidence ? evidenceId : null,
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'WP3 Quiz',
      assessmentType: 'quiz',
      difficulty: 'normal',
      rawScore: 9.0,
      maxScore: 10.0,
      localCompressedPhotoPath: snap?.filePath,
      sha256Checksum: snap?.sha256Checksum,
      occurredAt: baseNow,
      updatedAt: baseNow,
      dispatchState: CommandDispatchState.neverDispatched,
      entryContext: EntryContext.sharedChild,
    );
    var res = await draftStore.registerOrUpdateDraftIfUnchanged(
      expected: null,
      desired: initialDraft,
      now: baseNow,
    );
    expect(res.isSuccess, isTrue);
    if (dispatchState == CommandDispatchState.possiblyDispatched) {
      final claim = await draftStore.acquireDraftClaim(
        localDraftId: localDraftId,
        familyId: familyId.value,
        childId: childId.value,
        actorUserId: actorUserId,
        now: baseNow,
        leaseDuration: const Duration(minutes: 2),
      );
      expect(claim.isSuccess, isTrue);
      final leaseToken = claim.draft!.leaseToken!;
      res = await draftStore.markDraftStageAndDispatch(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: actorUserId,
        targetStage: submissionStatus,
        now: baseNow,
      );
      expect(res.isSuccess, isTrue);
      if (serverAssessmentId != null) {
        res = await draftStore.persistServerAssessmentId(
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          authenticatedActorId: actorUserId,
          serverAssessmentId: serverAssessmentId,
          now: baseNow,
        );
        expect(res.isSuccess, isTrue);
      }
      if (serverEvidenceId != null && snap != null && evidenceId != null) {
        res = await draftStore.persistServerEvidenceId(
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          authenticatedActorId: actorUserId,
          serverEvidenceId: serverEvidenceId,
          expectedEvidenceId: evidenceId,
          expectedSha256Checksum: snap.sha256Checksum,
          now: baseNow,
        );
        expect(res.isSuccess, isTrue);
      }
      final rel = await draftStore.releaseDraftClaim(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: actorUserId,
        now: baseNow,
      );
      expect(rel.isSuccess, isTrue);
      return rel.draft!;
    }
    return res.draft!;
  }

  Future<AssessmentSubmissionOutcome> runExecute({
    required AssessmentSubmissionOrchestrator orchestrator,
    required String localDraftId,
    String createCommandId = 'cmd-create-1',
    String submitCommandId = 'cmd-submit-1',
    String? evidenceId = 'ev-wp3-1',
    List<int>? evidenceBytes,
    String? evidenceMediaType,
    bool withEvidence = true,
    CommandExecutionTrigger trigger = CommandExecutionTrigger.foreground,
  }) {
    return orchestrator.execute(
      familyId: familyId,
      childId: childId,
      createCommandId: createCommandId,
      submitCommandId: submitCommandId,
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'WP3 Quiz',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 9, maxScore: 10),
      occurredAt: baseNow,
      entryContext: EntryContext.sharedChild,
      evidenceBytes: evidenceBytes,
      evidenceMediaType: evidenceMediaType,
      evidenceId: withEvidence && evidenceId != null
          ? EvidenceId(evidenceId)
          : null,
      localDraftId: localDraftId,
      trigger: trigger,
    );
  }

  setUp(() {
    clock = TestClock(baseNow);
    authPort = FakeAuthSessionPort(
      activeUserId: 'actor-a',
      sessionGeneration: 'gen-actor-a-1',
      role: 'parent',
    );
    repo = _ScriptedAssessmentRepository(
      activeActorIdProvider: () => authPort.currentContext?.userId,
    );
    storage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
    authzPort = FakeRecoveryAuthorizationPort();
    draftStore = TestLocalDraftStore();
    snapshotStore = _InMemoryCanonicalSnapshotStore();
  });

  group('WP3 AssessmentSubmissionOrchestrator B1-11..B1-25', () {
    test('B1-11: Lost upload ACK encountering 409 with matching remote bytes reconciles and completes once', () async {
      const draftId = 'draft-b1-11-match';
      await seedCanonicalDraft(localDraftId: draftId);
      final orchestrator = buildOrchestrator();

      // Simulate upload ACK drop: remote storage already has matching bytes from prior attempt.
      final path =
          '${familyId.value}/${childId.value}/fake-assessment-1/ev-wp3-1.jpg';
      storage.storage[path] = List<int>.from(validJpegBytes);

      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      expect(outcome, isA<AssessmentSubmissionConfirmed>());
      final confirmed = outcome as AssessmentSubmissionConfirmed;
      expect(confirmed.assessment.status, AssessmentStatus.pendingReview);
      expect(
        confirmed.draft?.dispatchState,
        CommandDispatchState.confirmedCommitted,
      );
      expect(confirmed.draft?.serverEvidenceId, isNotNull);
      expect(storage.reconcileCallCount, greaterThanOrEqualTo(1));
      expect(storage.deleteCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(1));
    });

    test('B1-12: HTTP 409 with differing remote bytes quarantines with LW4B1:STORAGE_CONTENT_CONFLICT and retains remote bytes (I04)', () async {
      const draftId = 'draft-b1-12-conflict';
      await seedCanonicalDraft(localDraftId: draftId);
      final orchestrator = buildOrchestrator();

      final path =
          '${familyId.value}/${childId.value}/fake-assessment-1/ev-wp3-1.jpg';
      storage.storage[path] = List<int>.from(differingJpegBytes);

      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      final q = outcome as AssessmentSubmissionQuarantined;
      expect(q.recoveryCode, equals(DraftRecoveryCode.storageContentConflict));
      expect(storage.deleteCallCount, equals(0));
      expect(storage.storage[path], equals(differingJpegBytes));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(persisted?.recoveryCode, DraftRecoveryCode.storageContentConflict);
      expect(persisted?.leaseToken, isNull);
    });

    test('B1-12b: HTTP 409 followed by download failure schedules bounded retry and never deletes remote bytes (I04)', () async {
      const draftId = 'draft-b1-12-dl-fail';
      await seedCanonicalDraft(localDraftId: draftId);
      final orchestrator = buildOrchestrator();

      final path =
          '${familyId.value}/${childId.value}/fake-assessment-1/ev-wp3-1.jpg';
      storage.storage[path] = List<int>.from(validJpegBytes);
      storage.throwOnDownload = TimeoutException('Storage download stalled');

      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      expect(outcome, isA<AssessmentSubmissionRetryScheduled>());
      final retry = outcome as AssessmentSubmissionRetryScheduled;
      expect(retry.retryCount, equals(1));
      expect(storage.deleteCallCount, equals(0));
      expect(storage.storage[path], equals(validJpegBytes));
      expect(repo.submitAssessmentCallCount, equals(0));

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(persisted?.recoveryCode, DraftRecoveryCode.retryScheduled);
      expect(persisted?.nextAttemptAt, equals(retry.nextAttemptAt));
    });

    test('B1-13: Lost registration ACK + LW109 resolves existing serverEvidenceId (!= evidenceId) and skips duplicate upload on resume', () async {
      const draftId = 'draft-b1-13-lw109-resolved';
      await seedCanonicalDraft(
        localDraftId: draftId,
        evidenceId: 'local-ev-uuid-1',
      );
      final orchestrator = buildOrchestrator();

      // Simulate prior attempt succeeded uploading & registering DB evidence row,
      // assessment stayed draft or transitioned, and next registration attempt hits LW109.
      final path =
          '${familyId.value}/${childId.value}/fake-assessment-1/local-ev-uuid-1.jpg';
      await repo.createDraft(
        commandId: 'cmd-create-1',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final registered = await repo.registerEvidence(
        assessmentId: AssessmentId('fake-assessment-1'),
        storagePath: path,
        mediaType: 'image/jpeg',
        fileSizeBytes: validJpegBytes.length,
      );
      expect(registered.id.value, isNot(equals('local-ev-uuid-1')));
      storage.storage[path] = List<int>.from(validJpegBytes);

      // Reset counters for orchestrator run under lost-ACK simulation
      repo.registerEvidenceCallCount = 0;
      repo.nextRegisterError = const BackendRpcException(
        message: 'Assessment must be draft to register evidence',
        code: 'LW109',
      );

      final firstOutcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        evidenceId: 'local-ev-uuid-1',
      );

      // Wait — if preCheck was false on first dispatch, it uploaded/checked and hit LW109,
      // reconciled registered row via listEvidenceForAssessment, and completed submission!
      expect(firstOutcome, isA<AssessmentSubmissionConfirmed>());
      final confirmed = firstOutcome as AssessmentSubmissionConfirmed;
      expect(confirmed.serverEvidence?.id, equals(registered.id));
      expect(confirmed.draft?.serverEvidenceId, equals(registered.id.value));
      expect(confirmed.draft?.evidenceId, equals('local-ev-uuid-1'));
      expect(
        confirmed.draft?.serverEvidenceId,
        isNot(equals(confirmed.draft?.evidenceId)),
      );
      expect(storage.deleteCallCount, equals(0));

      // Now verify resume scenario when possiblyDispatched with serverAssessmentId already persisted,
      // serverEvidenceId still null, and DB row already exists: preCheck avoids re-upload (uploadCallCount == 0).
      const draftId2 = 'draft-b1-13-precheck';
      await seedCanonicalDraft(
        localDraftId: draftId2,
        createCommandId: 'cmd-create-2',
        submitCommandId: 'cmd-submit-2',
        evidenceId: 'local-ev-uuid-2',
      );
      final a2 = await repo.createDraft(
        commandId: 'cmd-create-2',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final path2 =
          '${familyId.value}/${childId.value}/${a2.id.value}/local-ev-uuid-2.jpg';
      storage.storage[path2] = List<int>.from(validJpegBytes);
      final reg2 = await repo.registerEvidence(
        assessmentId: a2.id,
        storagePath: path2,
        mediaType: 'image/jpeg',
        fileSizeBytes: validJpegBytes.length,
      );

      final lease2 = (await draftStore.acquireDraftClaim(
        localDraftId: draftId2,
        actorUserId: 'actor-a',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      )).draft!.leaseToken!;
      await draftStore.markDraftStageAndDispatch(
        localDraftId: draftId2,
        leaseToken: lease2,
        authenticatedActorId: 'actor-a',
        targetStage: DraftSubmissionStatus.uploadingEvidence,
        now: baseNow,
      );
      await draftStore.persistServerAssessmentId(
        localDraftId: draftId2,
        leaseToken: lease2,
        authenticatedActorId: 'actor-a',
        serverAssessmentId: a2.id.value,
        now: baseNow,
      );
      await draftStore.releaseDraftClaim(
        localDraftId: draftId2,
        leaseToken: lease2,
        authenticatedActorId: 'actor-a',
        now: baseNow,
      );

      storage.uploadCallCount = 0;
      repo.registerEvidenceCallCount = 0;

      final resumeOutcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId2,
        createCommandId: 'cmd-create-2',
        submitCommandId: 'cmd-submit-2',
        evidenceId: 'local-ev-uuid-2',
      );

      expect(resumeOutcome, isA<AssessmentSubmissionConfirmed>());
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(
        (resumeOutcome as AssessmentSubmissionConfirmed)
            .draft
            ?.serverEvidenceId,
        equals(reg2.id.value),
      );
    });

    test('B1-14: Unresolved non-draft assessment reconciles read-only, quarantines with REGISTRATION_UNRESOLVED_REMOTE_RETAINED, and preserves remote bytes (I04, R34-03)', () async {
      const draftId = 'draft-b1-14-unresolved';
      await seedCanonicalDraft(localDraftId: draftId);
      final orchestrator = buildOrchestrator();

      final a = await repo.createDraft(
        commandId: 'cmd-create-1',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      await repo.submitAssessment(
        assessmentId: a.id,
        expectedVersion: 1,
        commandId: 'cmd-other-submit',
      );

      final path =
          '${familyId.value}/${childId.value}/${a.id.value}/ev-wp3-1.jpg';
      // Simulate orphaned pre-existing Storage bytes from an earlier interrupted run;
      // R34-03 forbids calling uploadEvidence or registerEvidence when already non-draft.
      storage.storage[path] = List<int>.from(validJpegBytes);

      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      final q = outcome as AssessmentSubmissionQuarantined;
      expect(
        q.recoveryCode,
        equals(DraftRecoveryCode.registrationUnresolvedRemoteRetained),
      );
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(storage.deleteCallCount, equals(0));
      expect(storage.storage[path], equals(validJpegBytes));
      expect(repo.submitAssessmentCallCount, equals(1)); // Only pre-seeded call

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(
        persisted?.recoveryCode,
        equals(DraftRecoveryCode.registrationUnresolvedRemoteRetained),
      );
    });

    test('Remote draft content/actor mismatch and version > 1 quarantine without calling submitAssessment', () async {
      // Case 1: Content mismatch returned by remote createDraft replay
      const mismatchId = 'draft-remote-mismatch';
      await seedCanonicalDraft(localDraftId: mismatchId, withEvidence: false);
      await repo.createDraft(
        commandId: 'cmd-create-1',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Tampered Server Title',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );

      final orchestrator = buildOrchestrator();
      final mismatchOutcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: mismatchId,
        withEvidence: false,
      );
      expect(mismatchOutcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (mismatchOutcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.versionConflict),
      );
      expect(repo.submitAssessmentCallCount, equals(0));

      // Case 2: Version > 1 in draft status during resume -> UNRECONSTRUCTABLE_EXPECTED_VERSION
      const v2Id = 'draft-remote-v2';
      await seedCanonicalDraft(
        localDraftId: v2Id,
        createCommandId: 'cmd-create-v2',
        submitCommandId: 'cmd-submit-v2',
        withEvidence: false,
      );
      final a2 = await repo.createDraft(
        commandId: 'cmd-create-v2',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      await repo.updateDraft(
        assessmentId: a2.id,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        expectedVersion: 1,
      );
      final lease = (await draftStore.acquireDraftClaim(
        localDraftId: v2Id,
        actorUserId: 'actor-a',
        familyId: familyId.value,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 2),
        now: baseNow,
      )).draft!.leaseToken!;
      await draftStore.markDraftStageAndDispatch(
        localDraftId: v2Id,
        leaseToken: lease,
        authenticatedActorId: 'actor-a',
        targetStage: DraftSubmissionStatus.submittingAssessment,
        now: baseNow,
      );
      await draftStore.persistServerAssessmentId(
        localDraftId: v2Id,
        leaseToken: lease,
        authenticatedActorId: 'actor-a',
        serverAssessmentId: a2.id.value,
        now: baseNow,
      );
      await draftStore.releaseDraftClaim(
        localDraftId: v2Id,
        leaseToken: lease,
        authenticatedActorId: 'actor-a',
        now: baseNow,
      );

      final v2Outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: v2Id,
        createCommandId: 'cmd-create-v2',
        submitCommandId: 'cmd-submit-v2',
        withEvidence: false,
      );
      expect(v2Outcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (v2Outcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.unreconstructableExpectedVersion),
      );
      expect(repo.submitAssessmentCallCount, equals(0));
    });

    test('submitAssessment always passes expectedVersion: 1 and quarantines on LW101 / LW107', () async {
      // LW101
      const d101 = 'draft-lw101';
      await seedCanonicalDraft(localDraftId: d101, withEvidence: false);
      repo.nextSubmitError = const BackendRpcException(
        message: 'Version conflict LW101',
        code: 'LW101',
      );
      final orchestrator = buildOrchestrator();
      final res101 = await runExecute(
        orchestrator: orchestrator,
        localDraftId: d101,
        withEvidence: false,
      );
      expect(res101, isA<AssessmentSubmissionQuarantined>());
      expect(
        (res101 as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.versionConflict),
      );
      expect(repo.recordedExpectedVersions, equals([1]));

      // LW107
      const d107 = 'draft-lw107';
      await seedCanonicalDraft(
        localDraftId: d107,
        createCommandId: 'cmd-c-107',
        submitCommandId: 'cmd-s-107',
        withEvidence: false,
      );
      repo.nextSubmitError = const BackendRpcException(
        message: 'Ambiguous idempotency state LW107',
        code: 'LW107',
      );
      final res107 = await runExecute(
        orchestrator: orchestrator,
        localDraftId: d107,
        createCommandId: 'cmd-c-107',
        submitCommandId: 'cmd-s-107',
        withEvidence: false,
      );
      expect(res107, isA<AssessmentSubmissionQuarantined>());
      expect(
        (res107 as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguousSubmitOutcome),
      );
    });

    test('42501 handling: pre-dispatch revoked -> terminal policy denial; childConfirmedArchived or post-dispatch -> AMBIGUOUS_42501_OUTCOME; unverified -> retry cap then quarantine', () async {
      // 1. Pre-dispatch confirmedRevoked -> terminalPolicyDenial
      const dRevoked = 'draft-42501-revoked';
      await seedCanonicalDraft(localDraftId: dRevoked, withEvidence: false);
      authzPort.setDefaultAdultResult(
        const AdultTargetAuthorizationResult.confirmedRevoked(),
      );
      final orchestrator = buildOrchestrator(maxRetryCount: 2);
      final rRevoked = await runExecute(
        orchestrator: orchestrator,
        localDraftId: dRevoked,
        withEvidence: false,
      );
      expect(rRevoked, isA<AssessmentSubmissionPolicyDenied>());
      expect(
        (rRevoked as AssessmentSubmissionPolicyDenied).recoveryCode,
        equals(DraftRecoveryCode.terminalPolicyDenial),
      );
      expect(repo.createDraftCallCount, equals(0));
      expect(
        (await draftStore.getLocalDraft(dRevoked))?.recoveryCode,
        equals(DraftRecoveryCode.terminalPolicyDenial),
      );

      // 2. Child confirmed archived -> ambiguous42501Outcome
      const dArchived = 'draft-42501-archived';
      await seedCanonicalDraft(
        localDraftId: dArchived,
        createCommandId: 'cmd-c-arch',
        submitCommandId: 'cmd-s-arch',
        withEvidence: false,
      );
      var verifyCountArch = 0;
      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        verifyCountArch++;
        if (verifyCountArch == 1) {
          return const AdultTargetAuthorizationResult.authorized(
            verifiedRole: VerifiedAdultRole.parent,
          );
        }
        return const AdultTargetAuthorizationResult.definitelyDenied(
          reason: AdultTargetVerificationReason.childConfirmedArchived,
        );
      };
      repo.nextCreateError = const BackendRpcException(
        message: 'Permission denied 42501',
        code: '42501',
      );
      final rArchived = await runExecute(
        orchestrator: orchestrator,
        localDraftId: dArchived,
        createCommandId: 'cmd-c-arch',
        submitCommandId: 'cmd-s-arch',
        withEvidence: false,
      );
      expect(rArchived, isA<AssessmentSubmissionQuarantined>());
      expect(
        (rArchived as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );

      // 3. Unverified -> bounded retries until maxRetryCount then AMBIGUOUS_42501_OUTCOME
      authzPort.onVerifyAssessmentTarget = null;
      const dUnverified = 'draft-42501-unverified';
      await seedCanonicalDraft(
        localDraftId: dUnverified,
        createCommandId: 'cmd-c-unv',
        submitCommandId: 'cmd-s-unv',
        withEvidence: false,
      );
      var calls = 0;
      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        calls++;
        if (calls == 1) {
          return const AdultTargetAuthorizationResult.authorized(
            verifiedRole: VerifiedAdultRole.parent,
          );
        }
        return const AdultTargetAuthorizationResult.unverified(
          reason: AdultTargetVerificationReason.transientVerificationFailure,
        );
      };
      repo.nextCreateError = const BackendRpcException(
        message: 'Permission denied',
        code: '42501',
      );
      final retry1 = await runExecute(
        orchestrator: orchestrator,
        localDraftId: dUnverified,
        createCommandId: 'cmd-c-unv',
        submitCommandId: 'cmd-s-unv',
        withEvidence: false,
      );
      expect(retry1, isA<AssessmentSubmissionRetryScheduled>());
      expect((retry1 as AssessmentSubmissionRetryScheduled).retryCount, 1);

      clock.advance(const Duration(minutes: 10));
      calls = 0;
      repo.nextCreateError = const BackendRpcException(
        message: 'Permission denied',
        code: '42501',
      );
      final retry2 = await runExecute(
        orchestrator: orchestrator,
        localDraftId: dUnverified,
        createCommandId: 'cmd-c-unv',
        submitCommandId: 'cmd-s-unv',
        withEvidence: false,
      );
      expect(retry2, isA<AssessmentSubmissionRetryScheduled>());
      expect((retry2 as AssessmentSubmissionRetryScheduled).retryCount, 2);

      // Next failure exceeds maxRetryCount (2) -> quarantines cleanly
      clock.advance(const Duration(minutes: 10));
      calls = 0;
      repo.nextCreateError = const BackendRpcException(
        message: 'Permission denied',
        code: '42501',
      );
      final capQuarantine = await runExecute(
        orchestrator: orchestrator,
        localDraftId: dUnverified,
        createCommandId: 'cmd-c-unv',
        submitCommandId: 'cmd-s-unv',
        withEvidence: false,
      );
      expect(capQuarantine, isA<AssessmentSubmissionQuarantined>());
      expect(
        (capQuarantine as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
    });

    test('Persisted backoff nextAttemptAt respects Clock & DeterministicJitterSource and is bypassed by foregroundRetry', () async {
      const draftId = 'draft-backoff-1';
      await seedCanonicalDraft(localDraftId: draftId, withEvidence: false);
      repo.nextSubmitError = const BackendRpcException(
        message: 'Upstream 503 temporary outage',
        code: '503',
      );
      final orchestrator = buildOrchestrator(
        jitterSource: const DeterministicJitterSource(0.5),
      );

      final first = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
      );
      expect(first, isA<AssessmentSubmissionRetryScheduled>());
      final scheduled = first as AssessmentSubmissionRetryScheduled;
      expect(
        scheduled.nextAttemptAt,
        equals(baseNow.add(const Duration(seconds: 1))),
      );

      // Before nextAttemptAt under normal trigger -> returns retry scheduled with 0 RPC calls.
      final beforeCreateCount = repo.createDraftCallCount;
      final blocked = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
        trigger: CommandExecutionTrigger.foreground,
      );
      expect(blocked, isA<AssessmentSubmissionRetryScheduled>());
      expect(repo.createDraftCallCount, equals(beforeCreateCount));

      // Explicit foregroundRetry before nextAttemptAt bypasses backoff and completes.
      final bypassed = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
        trigger: CommandExecutionTrigger.foregroundRetry,
      );
      expect(bypassed, isA<AssessmentSubmissionConfirmed>());
    });

    test('Actor switch A -> B pauses with WAITING_ORIGINAL_ACTOR; A resumes; session generation invalidation pauses without quarantine', () async {
      const draftId = 'draft-actor-switch';
      await seedCanonicalDraft(
        localDraftId: draftId,
        actorUserId: 'actor-a',
        withEvidence: false,
      );
      final orchestrator = buildOrchestrator();

      // Switch to actor B -> paused cleanly with LW4B1:WAITING_ORIGINAL_ACTOR
      authPort.setSession(
        userId: 'actor-b',
        sessionGeneration: 'gen-actor-b-1',
        role: 'parent',
      );
      final actorBOutcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
      );
      expect(actorBOutcome, isA<AssessmentSubmissionPausedActorMismatch>());
      expect(repo.createDraftCallCount, equals(0));
      expect(
        (await draftStore.getLocalDraft(draftId))?.recoveryCode,
        equals(DraftRecoveryCode.waitingOriginalActor),
      );

      // Switch back to actor A -> simulate session generation rotation mid-upload (pre-register)
      const genDraftId = 'draft-gen-switch';
      await seedCanonicalDraft(
        localDraftId: genDraftId,
        actorUserId: 'actor-a',
        createCommandId: 'cmd-c-gen',
        submitCommandId: 'cmd-s-gen',
        evidenceId: 'ev-gen-1',
        withEvidence: true,
      );
      authPort.setSession(
        userId: 'actor-a',
        sessionGeneration: 'gen-actor-a-10',
        role: 'parent',
      );
      storage.onAfterUpload = () {
        authPort.setSession(
          userId: 'actor-a',
          sessionGeneration: 'gen-actor-a-11',
          role: 'parent',
        );
      };
      final pausedGen = await runExecute(
        orchestrator: orchestrator,
        localDraftId: genDraftId,
        createCommandId: 'cmd-c-gen',
        submitCommandId: 'cmd-s-gen',
        evidenceId: 'ev-gen-1',
      );
      expect(pausedGen, isA<AssessmentSubmissionPausedSessionInvalid>());
      final rowAfterPause = await draftStore.getLocalDraft(genDraftId);
      expect(rowAfterPause?.isReadOnlyQuarantined, isFalse);
      expect(rowAfterPause?.leaseToken, isNull);

      // Actor A resumes original switched draft and completes
      storage.onAfterUpload = null;
      final resumedA = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
      );
      expect(resumedA, isA<AssessmentSubmissionConfirmed>());
    });

    test('R32-07: Secret values (JWT, Bearer token, signed URL token, Storage path) are redacted from outcomes and persisted errors', () async {
      const draftId = 'draft-r32-07-redaction';
      await seedCanonicalDraft(localDraftId: draftId, withEvidence: false);
      const secretJwt =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMifQ.secretSigXYZ';
      const secretBearer = 'Bearer super_secret_bearer_token_999';
      const secretUrl =
          'https://proj.supabase.co/storage/v1/object/sign/assessment-evidence/fam-wp3-1/ch-wp3-1/a-1/ev-1.jpg?token=secretQueryTok42';

      repo.nextSubmitError = const BackendRpcException(
        message: 'RPC failed: $secretBearer $secretJwt $secretUrl',
        code: 'LW107',
      );

      final orchestrator = buildOrchestrator();
      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
      );

      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      final q = outcome as AssessmentSubmissionQuarantined;
      for (final secret in const [
        'secretSigXYZ',
        'super_secret_bearer_token_999',
        'secretQueryTok42',
        'assessment-evidence/fam-wp3-1',
      ]) {
        expect(q.message, isNot(contains(secret)));
        expect(q.draft?.lastErrorMessage ?? '', isNot(contains(secret)));
      }
    });
  });

  group('R34 Review Hardening: Revalidation, Non-Draft Read-Only Evidence & Dispatch Boundary', () {
    test('R34-01: Barrier around markDraftStageAndDispatch revoking target authorization halts before createDraft/upload/register/submit and preserves journal/IDs/evidence', () async {
      const draftId = 'draft-r34-01-barrier';
      final seeded = await seedCanonicalDraft(localDraftId: draftId);
      final orchestrator = buildOrchestrator();

      final entered = Completer<void>();
      final release = Completer<void>();
      draftStore.onMarkDraftStageAndDispatch = (id, res) async {
        if (id == draftId && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };

      final futureOutcome = runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      await entered.future;
      authzPort.setTargetStatus(
        familyId: familyId.value,
        childId: childId.value,
        status: TargetAuthorizationStatus.confirmedRevoked,
      );
      release.complete();

      final outcome = await futureOutcome;
      expect(outcome, isA<AssessmentSubmissionPolicyDenied>());
      expect(repo.createDraftCallCount, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(
        persisted?.recoveryCode,
        equals(DraftRecoveryCode.terminalPolicyDenial),
      );
      expect(persisted?.createCommandId, equals(seeded.createCommandId));
      expect(persisted?.submitCommandId, equals(seeded.submitCommandId));
      expect(persisted?.evidenceId, equals(seeded.evidenceId));
      expect(
        persisted?.localCompressedPhotoPath,
        equals(seeded.localCompressedPhotoPath),
      );
      expect(persisted?.sha256Checksum, equals(seeded.sha256Checksum));
      expect(persisted?.leaseToken, isNull);
    });

    test('R34-01: Mid-flight target revocation across pre-check list, upload, and register halts before next remote stage without deleting bytes', () async {
      // Case A: Revoke after listEvidenceForAssessment pre-check -> zero upload/register/submit
      const preCheckId = 'draft-r34-01-precheck-revoke';
      final createdPreCheck = await repo.createDraft(
        commandId: 'cmd-create-1',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      await seedCanonicalDraft(
        localDraftId: preCheckId,
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.uploadingEvidence,
        serverAssessmentId: createdPreCheck.id.value,
      );

      repo.onAfterListEvidence = () async {
        authzPort.setTargetStatus(
          familyId: familyId.value,
          childId: childId.value,
          status: TargetAuthorizationStatus.confirmedRevoked,
        );
      };

      final orchestrator = buildOrchestrator();
      final preCheckOutcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: preCheckId,
      );
      expect(preCheckOutcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (preCheckOutcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(repo.listEvidenceCallCount, equals(1));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));

      // Case B: Revoke after upload -> zero register/submit, bytes retained (I04)
      repo.onAfterListEvidence = null;
      authzPort.setTargetStatus(
        familyId: familyId.value,
        childId: childId.value,
        status: TargetAuthorizationStatus.authorized,
      );
      const midUploadId = 'draft-r34-01-mid-upload';
      await seedCanonicalDraft(
        localDraftId: midUploadId,
        createCommandId: 'cmd-c-mid-u',
        submitCommandId: 'cmd-s-mid-u',
        evidenceId: 'ev-mid-u',
      );
      storage.onAfterUpload = () {
        authzPort.setTargetStatus(
          familyId: familyId.value,
          childId: childId.value,
          status: TargetAuthorizationStatus.confirmedRevoked,
        );
      };

      final midUploadOutcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: midUploadId,
        createCommandId: 'cmd-c-mid-u',
        submitCommandId: 'cmd-s-mid-u',
        evidenceId: 'ev-mid-u',
      );
      expect(midUploadOutcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (midUploadOutcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(storage.uploadCallCount, equals(1));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));
      expect(storage.deleteCallCount, equals(0));

      // Case C: Revoke after registerEvidence -> zero submitAssessment
      storage.onAfterUpload = null;
      authzPort.setTargetStatus(
        familyId: familyId.value,
        childId: childId.value,
        status: TargetAuthorizationStatus.authorized,
      );
      const midRegId = 'draft-r34-01-mid-reg';
      await seedCanonicalDraft(
        localDraftId: midRegId,
        createCommandId: 'cmd-c-mid-r',
        submitCommandId: 'cmd-s-mid-r',
        evidenceId: 'ev-mid-r',
      );
      repo.onBeforeRegister = () async {
        repo.onBeforeRegister = null;
        authzPort.setTargetStatus(
          familyId: familyId.value,
          childId: childId.value,
          status: TargetAuthorizationStatus.confirmedRevoked,
        );
      };
      final midRegOutcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: midRegId,
        createCommandId: 'cmd-c-mid-r',
        submitCommandId: 'cmd-s-mid-r',
        evidenceId: 'ev-mid-r',
      );
      expect(midRegOutcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (midRegOutcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(repo.registerEvidenceCallCount, equals(1));
      expect(repo.submitAssessmentCallCount, equals(0));
    });

    test('R34-01: Private evidence reconciliation respects target authorization before accessing Storage bytes', () async {
      const draftId = 'draft-r34-01-recon-authz';
      final assessment = await repo.createDraft(
        commandId: 'cmd-create-1',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final path =
          '${familyId.value}/${childId.value}/${assessment.id.value}/ev-wp3-1.jpg';
      storage.storage[path] = List<int>.from(validJpegBytes);
      final regEv = await repo.registerEvidence(
        assessmentId: assessment.id,
        storagePath: path,
        mediaType: 'image/jpeg',
        fileSizeBytes: validJpegBytes.length,
      );
      await seedCanonicalDraft(
        localDraftId: draftId,
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.uploadingEvidence,
        serverAssessmentId: assessment.id.value,
        serverEvidenceId: regEv.id.value,
      );

      repo.onAfterListEvidence = () async {
        authzPort.setTargetStatus(
          familyId: familyId.value,
          childId: childId.value,
          status: TargetAuthorizationStatus.confirmedRevoked,
        );
      };

      final orchestrator = buildOrchestrator();
      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      expect(
        (outcome as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(storage.reconcileCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));
    });

    test('R34-03: Non-draft assessment (pendingReview/verified/rejected) reconciles read-only with zero upload or registerEvidence calls', () async {
      const draftId = 'draft-r34-03-nondraft-verified';
      await seedCanonicalDraft(localDraftId: draftId);
      final assessment = await repo.createDraft(
        commandId: 'cmd-create-1',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final path =
          '${familyId.value}/${childId.value}/${assessment.id.value}/ev-wp3-1.jpg';
      storage.storage[path] = List<int>.from(validJpegBytes);
      final regEv = await repo.registerEvidence(
        assessmentId: assessment.id,
        storagePath: path,
        mediaType: 'image/jpeg',
        fileSizeBytes: validJpegBytes.length,
      );
      await repo.submitAssessment(
        assessmentId: assessment.id,
        expectedVersion: 1,
        commandId: 'cmd-submit-1',
      );
      // Even verify the assessment so remote status is `verified` (non-draft).
      await repo.verifyAssessment(
        assessmentId: assessment.id,
        expectedVersion: 2,
        commandId: 'cmd-verify-1',
      );

      repo.registerEvidenceCallCount = 0;
      repo.submitAssessmentCallCount = 0;

      final orchestrator = buildOrchestrator();
      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      expect(outcome, isA<AssessmentSubmissionConfirmed>());
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(storage.reconcileCallCount, equals(1));
      expect(storage.deleteCallCount, equals(0));
      final persisted = await draftStore.getLocalDraft(draftId);
      expect(persisted?.serverEvidenceId, equals(regEv.id.value));
      expect(
        persisted?.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
    });

    test('R34-04 (1): Denial positively established before first remote call produces terminalPolicyDenial with zero RPCs', () async {
      const draftId = 'draft-r34-04-pre-call-deny';
      await seedCanonicalDraft(localDraftId: draftId, withEvidence: false);
      authzPort.setTargetStatus(
        familyId: familyId.value,
        childId: childId.value,
        status: TargetAuthorizationStatus.definitelyDenied,
      );

      final orchestrator = buildOrchestrator();
      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
      );

      expect(outcome, isA<AssessmentSubmissionPolicyDenied>());
      expect(
        (outcome as AssessmentSubmissionPolicyDenied).recoveryCode,
        equals(DraftRecoveryCode.terminalPolicyDenial),
      );
      expect(repo.createDraftCallCount, equals(0));
    });

    test('R34-04 (2): 42501 returned AFTER createDraft was invoked on first dispatch classifies as ambiguous42501Outcome (never terminalPolicyDenial)', () async {
      const draftId = 'draft-r34-04-first-create-42501';
      final seeded = await seedCanonicalDraft(localDraftId: draftId);

      repo.onBeforeCreate = () async {
        // Authorization revokes / RLS triggers 42501 during/after createDraft RPC.
        authzPort.setTargetStatus(
          familyId: familyId.value,
          childId: childId.value,
          status: TargetAuthorizationStatus.confirmedRevoked,
        );
        throw const BackendRpcException(
          message: 'new row violates row-level security policy',
          code: '42501',
        );
      };

      final orchestrator = buildOrchestrator();
      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      expect(repo.createDraftCallCount, equals(1));
      expect(outcome, isNot(isA<AssessmentSubmissionPolicyDenied>()));
      expect(outcome, isA<AssessmentSubmissionQuarantined>());
      final q = outcome as AssessmentSubmissionQuarantined;
      expect(q.recoveryCode, equals(DraftRecoveryCode.ambiguous42501Outcome));

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(
        persisted?.recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(persisted?.createCommandId, equals(seeded.createCommandId));
      expect(persisted?.submitCommandId, equals(seeded.submitCommandId));
      expect(persisted?.evidenceId, equals(seeded.evidenceId));
    });

    test('R34-04 (3): Lost createDraft response followed by revoked authorization preserves ambiguous42501Outcome', () async {
      const draftId = 'draft-r34-04-lost-create-then-revoked';
      await seedCanonicalDraft(localDraftId: draftId, withEvidence: false);
      repo.nextCreateError = const BackendRpcException(
        message: 'SocketException: connection closed before response',
        code: '503',
      );

      final orchestrator = buildOrchestrator();
      final attempt1 = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
      );
      expect(attempt1, isA<AssessmentSubmissionRetryScheduled>());

      authzPort.setTargetStatus(
        familyId: familyId.value,
        childId: childId.value,
        status: TargetAuthorizationStatus.confirmedRevoked,
      );
      final attempt2 = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
        trigger: CommandExecutionTrigger.foregroundRetry,
      );
      expect(attempt2, isNot(isA<AssessmentSubmissionPolicyDenied>()));
      expect(attempt2, isA<AssessmentSubmissionQuarantined>());
      expect(
        (attempt2 as AssessmentSubmissionQuarantined).recoveryCode,
        equals(DraftRecoveryCode.ambiguous42501Outcome),
      );
      expect(repo.createDraftCallCount, equals(1));
    });

    test('R34-04 (4): Actor or session change between markDraftStageAndDispatch and createDraft pauses safely without corrupting journal', () async {
      const draftId = 'draft-r34-04-actor-switch-after-stage';
      final seeded = await seedCanonicalDraft(localDraftId: draftId);
      final orchestrator = buildOrchestrator();

      final entered = Completer<void>();
      final release = Completer<void>();
      draftStore.onMarkDraftStageAndDispatch = (id, res) async {
        if (id == draftId && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };

      final futureOutcome = runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );
      await entered.future;
      authPort.setSession(
        userId: 'actor-b',
        sessionGeneration: 'gen-actor-b-1',
        role: 'parent',
      );
      release.complete();

      final outcome = await futureOutcome;
      expect(outcome, isA<AssessmentSubmissionPausedActorMismatch>());
      expect(repo.createDraftCallCount, equals(0));

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(
        persisted?.recoveryCode,
        equals(DraftRecoveryCode.waitingOriginalActor),
      );
      expect(persisted?.actorUserId, equals('actor-a'));
      expect(persisted?.createCommandId, equals(seeded.createCommandId));
      expect(persisted?.submitCommandId, equals(seeded.submitCommandId));
      expect(persisted?.evidenceId, equals(seeded.evidenceId));
      expect(persisted?.sha256Checksum, equals(seeded.sha256Checksum));
      expect(persisted?.leaseToken, isNull);
    });

    test('R34-05: Production AssessmentSubmissionOrchestrator rejects direct unjournaled reconcileAndRegisterEvidence calls', () async {
      final orchestrator = buildOrchestrator();
      await expectLater(
        () => orchestrator.reconcileAndRegisterEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: AssessmentId('a-direct-1'),
          evidenceId: EvidenceId('e-direct-1'),
          bytes: validJpegBytes,
          mediaType: 'image/jpeg',
        ),
        throwsStateError,
      );
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
    });

    test('R34-06: Actor A -> B while target verification for createDraft is pending pauses without calling createDraft and preserves journal/IDs/evidence', () async {
      const draftId = 'draft-r34-06-actor-create';
      final seeded = await seedCanonicalDraft(localDraftId: draftId);

      // Pause on the second verifyAssessmentTarget call (immediately before createDraft, after pre-dispatch mark).
      var verifyCalls = 0;
      final entered = Completer<void>();
      final release = Completer<void>();
      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        verifyCalls++;
        if (verifyCalls == 2) {
          entered.complete();
          await release.future;
        }
        return const AdultTargetAuthorizationResult.authorized(
          verifiedRole: VerifiedAdultRole.parent,
        );
      };

      final orchestrator = buildOrchestrator();
      final futureOutcome = runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      await entered.future;
      authPort.setSession(
        userId: 'actor-b',
        sessionGeneration: 'gen-actor-b-1',
        role: 'parent',
      );
      release.complete();

      final outcome = await futureOutcome;
      expect(outcome, isA<AssessmentSubmissionPausedActorMismatch>());
      expect(repo.createDraftCallCount, equals(0));
      expect(storage.uploadCallCount, equals(0));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(persisted?.actorUserId, equals('actor-a'));
      expect(
        persisted?.recoveryCode,
        equals(DraftRecoveryCode.waitingOriginalActor),
      );
      expect(persisted?.createCommandId, equals(seeded.createCommandId));
      expect(persisted?.submitCommandId, equals(seeded.submitCommandId));
      expect(persisted?.evidenceId, equals(seeded.evidenceId));
      expect(
        persisted?.localCompressedPhotoPath,
        equals(seeded.localCompressedPhotoPath),
      );
      expect(persisted?.sha256Checksum, equals(seeded.sha256Checksum));
      expect(persisted?.leaseToken, isNull);
    });

    test('R34-06: Session generation rotation while target verification for submitAssessment is pending halts before submitAssessment and preserves dispatched IDs', () async {
      const draftId = 'draft-r34-06-gen-submit';
      final seeded = await seedCanonicalDraft(localDraftId: draftId);

      // Call order for evidence-bearing draft: 1 preDispatch, 2 createDraft, 3 upload, 4 register, 5 submitAssessment.
      var verifyCalls = 0;
      final entered = Completer<void>();
      final release = Completer<void>();
      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        verifyCalls++;
        if (verifyCalls == 5) {
          entered.complete();
          await release.future;
        }
        return const AdultTargetAuthorizationResult.authorized(
          verifiedRole: VerifiedAdultRole.parent,
        );
      };

      final orchestrator = buildOrchestrator();
      final futureOutcome = runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      await entered.future;
      authPort.setSession(
        userId: 'actor-a',
        sessionGeneration: 'gen-actor-a-rotated',
        role: 'parent',
      );
      release.complete();

      final outcome = await futureOutcome;
      expect(outcome, isA<AssessmentSubmissionPausedSessionInvalid>());
      expect(repo.createDraftCallCount, equals(1));
      expect(storage.uploadCallCount, equals(1));
      expect(repo.registerEvidenceCallCount, equals(1));
      expect(repo.submitAssessmentCallCount, equals(0));

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(persisted?.actorUserId, equals('actor-a'));
      expect(
        persisted?.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );
      expect(persisted?.serverAssessmentId, isNotNull);
      expect(persisted?.serverEvidenceId, isNotNull);
      expect(persisted?.createCommandId, equals(seeded.createCommandId));
      expect(persisted?.submitCommandId, equals(seeded.submitCommandId));
      expect(persisted?.evidenceId, equals(seeded.evidenceId));
      expect(persisted?.leaseToken, isNull);
    });

    test('R34-06: Sign-out while target verification is pending fails closed with zero downstream RPCs', () async {
      const draftId = 'draft-r34-06-signout';
      await seedCanonicalDraft(localDraftId: draftId, withEvidence: false);

      var verifyCalls = 0;
      final entered = Completer<void>();
      final release = Completer<void>();
      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        verifyCalls++;
        if (verifyCalls == 2) {
          entered.complete();
          await release.future;
        }
        return const AdultTargetAuthorizationResult.authorized(
          verifiedRole: VerifiedAdultRole.parent,
        );
      };

      final orchestrator = buildOrchestrator();
      final futureOutcome = runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
      );

      await entered.future;
      authPort.signOut();
      release.complete();

      final outcome = await futureOutcome;
      expect(outcome, isA<AssessmentSubmissionPausedSessionInvalid>());
      expect(repo.createDraftCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));
      final persisted = await draftStore.getLocalDraft(draftId);
      expect(persisted?.actorUserId, equals('actor-a'));
      expect(persisted?.leaseToken, isNull);
    });

    test('R34-06: Two authorized parents in the same family cannot cross from parent A verification to parent B live session before RPC', () async {
      const draftId = 'draft-r34-06-two-parents';
      await seedCanonicalDraft(
        localDraftId: draftId,
        actorUserId: 'parent-a',
        withEvidence: false,
      );
      authPort.setSession(
        userId: 'parent-a',
        sessionGeneration: 'gen-pa-1',
        role: 'parent',
      );

      var verifyCalls = 0;
      final entered = Completer<void>();
      final release = Completer<void>();
      // Both parent-a and parent-b are authorized adults for the same family/child.
      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        verifyCalls++;
        if (verifyCalls == 2) {
          entered.complete();
          await release.future;
        }
        return const AdultTargetAuthorizationResult.authorized(
          verifiedRole: VerifiedAdultRole.parent,
        );
      };

      final orchestrator = buildOrchestrator();
      final futureOutcome = runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
        withEvidence: false,
      );

      await entered.future;
      // Switch live session to equally-authorized co-parent B while A verification is pending.
      authPort.setSession(
        userId: 'parent-b',
        sessionGeneration: 'gen-pb-1',
        role: 'parent',
      );
      release.complete();

      final outcome = await futureOutcome;
      expect(outcome, isA<AssessmentSubmissionPausedActorMismatch>());
      expect(repo.createDraftCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));

      final persisted = await draftStore.getLocalDraft(draftId);
      expect(persisted?.actorUserId, equals('parent-a'));
      expect(
        persisted?.recoveryCode,
        equals(DraftRecoveryCode.waitingOriginalActor),
      );
      expect(persisted?.leaseToken, isNull);
    });

    test('R34-06: Session change during evidence registration and private reconciliation verification halts before registerEvidence and reconcileEvidence', () async {
      // Case A: Session generation rotates during target verification before registerEvidence
      const regDraftId = 'draft-r34-06-reg-verify';
      await seedCanonicalDraft(localDraftId: regDraftId);

      var verifyCalls = 0;
      final enteredReg = Completer<void>();
      final releaseReg = Completer<void>();
      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        verifyCalls++;
        if (verifyCalls == 4) {
          enteredReg.complete();
          await releaseReg.future;
        }
        return const AdultTargetAuthorizationResult.authorized(
          verifiedRole: VerifiedAdultRole.parent,
        );
      };

      final orchestrator = buildOrchestrator();
      final regFuture = runExecute(
        orchestrator: orchestrator,
        localDraftId: regDraftId,
      );
      await enteredReg.future;
      authPort.setSession(
        userId: 'actor-a',
        sessionGeneration: 'gen-actor-a-rotated-reg',
        role: 'parent',
      );
      releaseReg.complete();

      final regOutcome = await regFuture;
      expect(regOutcome, isA<AssessmentSubmissionPausedSessionInvalid>());
      expect(storage.uploadCallCount, equals(1));
      expect(repo.registerEvidenceCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));
      expect(storage.deleteCallCount, equals(0));

      // Case B: Actor switch during target verification before private storage.reconcileEvidence
      authzPort.onVerifyAssessmentTarget = null;
      storage.reconcileCallCount = 0;
      repo.submitAssessmentCallCount = 0;
      authPort.setSession(
        userId: 'actor-a',
        sessionGeneration: 'gen-actor-a-1',
        role: 'parent',
      );
      const reconDraftId = 'draft-r34-06-recon-verify';
      final existingAssessment = await repo.createDraft(
        commandId: 'cmd-c-r3406-recon',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'WP3 Quiz',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
        occurredAt: baseNow,
        entryContext: EntryContext.sharedChild,
      );
      final reconPath =
          '${familyId.value}/${childId.value}/${existingAssessment.id.value}/ev-r3406-recon.jpg';
      storage.storage[reconPath] = List<int>.from(validJpegBytes);
      final regEv = await repo.registerEvidence(
        assessmentId: existingAssessment.id,
        storagePath: reconPath,
        mediaType: 'image/jpeg',
        fileSizeBytes: validJpegBytes.length,
      );
      await seedCanonicalDraft(
        localDraftId: reconDraftId,
        createCommandId: 'cmd-c-r3406-recon',
        submitCommandId: 'cmd-s-r3406-recon',
        evidenceId: 'ev-r3406-recon',
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.uploadingEvidence,
        serverAssessmentId: existingAssessment.id.value,
        serverEvidenceId: regEv.id.value,
      );

      // Call order on resume with persisted IDs: 1 preDispatch, 2 getAssessment, 3 listEvidence, 4 storage.reconcileEvidence.
      var reconVerifyCalls = 0;
      final enteredRecon = Completer<void>();
      final releaseRecon = Completer<void>();
      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        reconVerifyCalls++;
        if (reconVerifyCalls == 4) {
          enteredRecon.complete();
          await releaseRecon.future;
        }
        return const AdultTargetAuthorizationResult.authorized(
          verifiedRole: VerifiedAdultRole.parent,
        );
      };

      final reconFuture = runExecute(
        orchestrator: orchestrator,
        localDraftId: reconDraftId,
        createCommandId: 'cmd-c-r3406-recon',
        submitCommandId: 'cmd-s-r3406-recon',
        evidenceId: 'ev-r3406-recon',
      );
      await enteredRecon.future;
      authPort.setSession(
        userId: 'actor-b',
        sessionGeneration: 'gen-actor-b-recon',
        role: 'parent',
      );
      releaseRecon.complete();

      final reconOutcome = await reconFuture;
      expect(reconOutcome, isA<AssessmentSubmissionPausedActorMismatch>());
      expect(storage.reconcileCallCount, equals(0));
      expect(repo.submitAssessmentCallCount, equals(0));
    });

    test('R34-06: Unchanged live session across async verification barriers proceeds to AssessmentSubmissionConfirmed', () async {
      const draftId = 'draft-r34-06-unchanged-ok';
      await seedCanonicalDraft(localDraftId: draftId);

      authzPort.onVerifyAssessmentTarget = (_, _, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return const AdultTargetAuthorizationResult.authorized(
          verifiedRole: VerifiedAdultRole.parent,
        );
      };

      final orchestrator = buildOrchestrator();
      final outcome = await runExecute(
        orchestrator: orchestrator,
        localDraftId: draftId,
      );

      expect(outcome, isA<AssessmentSubmissionConfirmed>());
      expect(repo.createDraftCallCount, equals(1));
      expect(storage.uploadCallCount, equals(1));
      expect(repo.registerEvidenceCallCount, equals(1));
      expect(repo.submitAssessmentCallCount, equals(1));
    });
  });
}
