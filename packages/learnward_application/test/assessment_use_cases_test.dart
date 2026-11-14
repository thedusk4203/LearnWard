import 'dart:async';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

typedef InMemoryLocalDraftStore = TestLocalDraftStore;

final class FailingRegisterAssessmentRepository
    extends FakeAssessmentRepository {
  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) async {
    throw StateError('Simulated DB registration failure');
  }
}

final class FailingDeleteStorage implements AssessmentEvidenceStorage {
  FailingDeleteStorage(this.inner);
  final AssessmentEvidenceStorage inner;

  @override
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) => inner.uploadEvidence(
    familyId: familyId,
    childId: childId,
    assessmentId: assessmentId,
    evidenceId: evidenceId,
    bytes: bytes,
    mediaType: mediaType,
    context: context,
    expectedSessionGeneration: expectedSessionGeneration,
  );

  @override
  Future<List<int>> downloadEvidence({
    required String storagePath,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) => inner.downloadEvidence(
    storagePath: storagePath,
    context: context,
    expectedSessionGeneration: expectedSessionGeneration,
  );

  @override
  Future<EvidenceStorageReconciliationResult> reconcileEvidence({
    required String storagePath,
    required List<int> localBytes,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) => inner.reconcileEvidence(
    storagePath: storagePath,
    localBytes: localBytes,
    context: context,
    expectedSessionGeneration: expectedSessionGeneration,
  );

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) => inner.getEvidenceSignedUrl(
    storagePath: storagePath,
    expiresIn: expiresIn,
    context: context,
    expectedSessionGeneration: expectedSessionGeneration,
  );

  @override
  Future<void> deleteEvidence(
    String storagePath, {
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    throw StateError('Simulated storage delete failure');
  }
}

void main() {
  late FakeAssessmentRepository repository;
  late FakeAuthSessionPort fakeAuth;
  late FakeAssessmentEvidenceStorage storage;

  final familyId = FamilyId('fam-1');
  final childId = ChildId('child-1');

  setUp(() {
    repository = FakeAssessmentRepository();
    fakeAuth = FakeAuthSessionPort(
      activeUserId: 'user-parent-1',
      sessionGeneration: 'gen-1',
    );
    storage = FakeAssessmentEvidenceStorage(authSessionPort: fakeAuth);
  });

  test(
    'CreateAssessmentDraft creates a valid draft with commandId and subjectKey',
    () async {
      final useCase = CreateAssessmentDraft(repository);
      final assessment = await useCase(
        commandId: 'cmd-create-1',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Fractions Test',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 8, maxScore: 10),
        entryContext: EntryContext.adult,
      );

      expect(assessment.status, equals(AssessmentStatus.draft));
      expect(assessment.version, equals(1));
      expect(assessment.subjectKey, equals(SubjectKey.math));
      expect(assessment.score.rawScore, equals(8));

      // Idempotent retry returns same assessment
      final retry = await useCase(
        commandId: 'cmd-create-1',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Fractions Test',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 8, maxScore: 10),
      );
      expect(retry.id, equals(assessment.id));
      expect(repository.assessments.length, equals(1));
    },
  );

  test('UpdateAssessmentDraft updates fields and increments version', () async {
    final createUseCase = CreateAssessmentDraft(repository);
    final draft = await createUseCase(
      commandId: 'cmd-create-2',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'Draft 1',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 7, maxScore: 10),
    );

    final updateUseCase = UpdateAssessmentDraft(repository);
    final updated = await updateUseCase(
      assessmentId: draft.id,
      subjectKey: SubjectKey.math,
      subject: 'Mathematics',
      title: 'Updated Quiz',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.hard,
      score: AssessmentScore(rawScore: 9, maxScore: 10),
      expectedVersion: 1,
    );

    expect(updated.title, equals('Updated Quiz'));
    expect(updated.score.rawScore, equals(9));
    expect(updated.version, equals(2));
  });

  test('SubmitAssessment transitions assessment to pendingReview', () async {
    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-3',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.literature,
      subject: 'Literature',
      title: 'Essay',
      type: AssessmentType.homework,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 9, maxScore: 10),
    );

    final submitUseCase = SubmitAssessment(repository);
    final submitted = await submitUseCase(
      assessmentId: draft.id,
      expectedVersion: 1,
      commandId: 'cmd-submit-1',
    );

    expect(submitted.status, equals(AssessmentStatus.pendingReview));
    expect(submitted.version, equals(2));
  });

  test('UploadAssessmentEvidence stores bytes and registers evidence with opaque UUID', () async {
    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-4',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Lab Report',
      type: AssessmentType.practice,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 10, maxScore: 10),
    );

    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    final evidence = await uploadUseCase(
      familyId: familyId,
      childId: childId,
      assessmentId: draft.id,
      evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440000'),
      bytes: [1, 2, 3, 4],
      mediaType: 'image/jpeg',
    );

    expect(evidence.mediaType, equals('image/jpeg'));
    expect(evidence.fileSizeBytes, equals(4));
    expect(storage.storage[evidence.storagePath], equals([1, 2, 3, 4]));
    expect(
      evidence.storagePath.contains('550e8400-e29b-41d4-a716-446655440000.jpg'),
      isTrue,
    );
  });

  test('UploadAssessmentEvidence validates size and MIME type', () async {
    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-5',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'Exam',
      type: AssessmentType.exam,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 10, maxScore: 10),
    );

    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    // Oversize
    final oversize = List<int>.filled(10 * 1024 * 1024 + 1, 0);
    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440001'),
        bytes: oversize,
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<InvalidAssessmentException>()),
    );

    // Disallowed MIME
    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440002'),
        bytes: [1, 2, 3],
        mediaType: 'application/pdf',
      ),
      throwsA(isA<InvalidAssessmentException>()),
    );
  });

  test('UploadAssessmentEvidence preserves storage object and never performs compensation delete when DB registration fails (I04)', () async {
    final failingRepo = FailingRegisterAssessmentRepository();
    final draft = await CreateAssessmentDraft(failingRepo)(
      commandId: 'cmd-create-6',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'Fail Test',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 10, maxScore: 10),
    );

    final uploadUseCase = UploadAssessmentEvidence(
      repository: failingRepo,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    final evidenceId = EvidenceId('550e8400-e29b-41d4-a716-446655440003');
    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: evidenceId,
        bytes: [1, 2, 3, 4],
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<StateError>()),
    );

    // Verify Invariant I04: Storage object is retained, NOT deleted
    final expectedPath =
        '${familyId.value}/${childId.value}/${draft.id.value}/${evidenceId.value}.jpg';
    expect(storage.storage.containsKey(expectedPath), isTrue);
    expect(storage.storage[expectedPath], equals([1, 2, 3, 4]));
    expect(storage.deleteCallCount, equals(0));
    expect(storage.deleteCalls, isEmpty);
  });

  test('UploadAssessmentEvidence with AuthSessionPort fails closed when session is null, expired, or sessionGeneration changes (R31-08)', () async {
    final fakeAuth = FakeAuthSessionPort(
      activeUserId: 'user-parent-1',
      sessionGeneration: 'gen-1',
    );
    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-auth-1',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'Auth Test',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 10, maxScore: 10),
    );

    final evidenceId = EvidenceId('550e8400-e29b-41d4-a716-446655440004');

    // 1. Session generation mismatch
    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: evidenceId,
        bytes: [1, 2, 3, 4],
        mediaType: 'image/jpeg',
        expectedSessionGeneration: 'gen-old-stale',
      ),
      throwsA(isA<EvidenceStorageAuthException>()),
    );

    // 2. Unauthenticated / signed out
    fakeAuth.signOut();
    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: evidenceId,
        bytes: [1, 2, 3, 4],
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<EvidenceStorageAuthException>()),
    );

    // Zero storage uploads occurred during auth failures
    expect(storage.storage.isEmpty, isTrue);
  });

  test('R32-02: session change between upload completion and registration aborts with EvidenceStorageAuthException and preserves remote bytes', () async {
    final fakeAuth = FakeAuthSessionPort(
      activeUserId: 'user-parent-1',
      sessionGeneration: 'gen-1',
    );
    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-r32-02',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Asynchronous Session Invalidation Test',
      type: AssessmentType.homework,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 9, maxScore: 10),
    );

    final evidenceId = EvidenceId('550e8400-e29b-41d4-a716-446655440099');
    final expectedPath =
        '${familyId.value}/${childId.value}/${draft.id.value}/${evidenceId.value}.jpg';

    // Simulate session generation invalidation immediately after Storage upload completes
    storage.onAfterUpload = () {
      fakeAuth.setSessionGeneration('gen-invalidated-after-upload');
    };

    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: evidenceId,
        bytes: [1, 2, 3, 4, 5],
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<EvidenceStorageAuthException>()),
    );

    // Verify remote bytes were preserved and NO remote deletion was invoked (Invariant I04)
    expect(storage.storage.containsKey(expectedPath), isTrue);
    expect(storage.storage[expectedPath], equals([1, 2, 3, 4, 5]));
    expect(storage.deleteCallCount, equals(0));
  });

  test('UploadAssessmentEvidence with AuthSessionPort fails closed on actor switch (R31-08)', () async {
    final fakeAuth = FakeAuthSessionPort(
      activeUserId: 'user-attacker',
      sessionGeneration: 'gen-attacker',
    );
    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-auth-2',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'Actor Switch Test',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 10, maxScore: 10),
    );

    final originalContext = ValidatedActorContext(
      userId: 'user-original-owner',
      sessionGeneration: 'gen-orig',
      observedAt: DateTime.now().toUtc(),
    );

    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440005'),
        bytes: [1, 2, 3, 4],
        mediaType: 'image/jpeg',
        context: originalContext,
      ),
      throwsA(isA<EvidenceStorageAuthException>()),
    );

    expect(storage.storage.isEmpty, isTrue);
  });

  test('UploadAssessmentEvidence 409 reconciliation succeeds on identical bytes (B1-06)', () async {
    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-409-match',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Lab 409 Match',
      type: AssessmentType.homework,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 8, maxScore: 10),
    );

    final evidenceId = EvidenceId('550e8400-e29b-41d4-a716-446655440006');
    final path =
        '${familyId.value}/${childId.value}/${draft.id.value}/${evidenceId.value}.jpg';
    final bytes = [10, 20, 30, 40, 50];

    // Pre-seed storage with identical bytes (simulating prior acknowledged upload)
    storage.storage[path] = List<int>.from(bytes);

    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    final result = await uploadUseCase(
      familyId: familyId,
      childId: childId,
      assessmentId: draft.id,
      evidenceId: evidenceId,
      bytes: bytes,
      mediaType: 'image/jpeg',
    );

    expect(result.storagePath, equals(path));
    expect(storage.reconcileCallCount, equals(1));
  });

  test('UploadAssessmentEvidence 409 reconciliation fails with conflict on differing digest (B1-07)', () async {
    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-409-conflict',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Lab 409 Conflict',
      type: AssessmentType.homework,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 8, maxScore: 10),
    );

    final evidenceId = EvidenceId('550e8400-e29b-41d4-a716-446655440007');
    final path =
        '${familyId.value}/${childId.value}/${draft.id.value}/${evidenceId.value}.jpg';

    // Pre-seed storage with same length but differing content bytes
    storage.storage[path] = [1, 2, 3, 4, 5];
    final localBytes = [1, 2, 3, 4, 99]; // Same length, different SHA-256

    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: evidenceId,
        bytes: localBytes,
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<EvidenceStorageConflictException>()),
    );

    // Verify remote bytes untouched and no deletion occurred
    expect(storage.storage[path], equals([1, 2, 3, 4, 5]));
    expect(storage.deleteCallCount, equals(0));
  });

  test('UploadAssessmentEvidence 409 reconciliation fails with conflict on differing length (B1-08)', () async {
    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-409-diff-len',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Lab 409 Diff Len',
      type: AssessmentType.homework,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 8, maxScore: 10),
    );

    final evidenceId = EvidenceId('550e8400-e29b-41d4-a716-446655440008');
    final path =
        '${familyId.value}/${childId.value}/${draft.id.value}/${evidenceId.value}.jpg';

    // Pre-seed storage with 3 bytes
    storage.storage[path] = [1, 2, 3];
    final localBytes = [1, 2, 3, 4, 5]; // 5 bytes

    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: evidenceId,
        bytes: localBytes,
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<EvidenceStorageConflictException>()),
    );

    expect(storage.storage[path], equals([1, 2, 3]));
    expect(storage.deleteCallCount, equals(0));
  });

  test('UploadAssessmentEvidence 409 reconciliation fails closed as unknown on download error without deleting local or remote bytes (B1-09)', () async {
    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-409-unknown',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Lab 409 Unknown',
      type: AssessmentType.homework,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 8, maxScore: 10),
    );

    final evidenceId = EvidenceId('550e8400-e29b-41d4-a716-446655440009');
    final path =
        '${familyId.value}/${childId.value}/${draft.id.value}/${evidenceId.value}.jpg';
    storage.storage[path] = [1, 2, 3];
    storage.throwOnDownload = StateError('Simulated 403 RLS hidden error');

    final uploadUseCase = UploadAssessmentEvidence(
      repository: repository,
      storage: storage,
      authSessionPort: fakeAuth,
    );

    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: evidenceId,
        bytes: [1, 2, 3],
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<EvidenceStorageUnknownOutcomeException>()),
    );

    // Verify remote bytes still intact and never deleted
    expect(storage.storage[path], equals([1, 2, 3]));
    expect(storage.deleteCallCount, equals(0));
  });

  test(
    'VerifyAssessment creates immutable learning event and is idempotent',
    () async {
      final draft = await CreateAssessmentDraft(repository)(
        commandId: 'cmd-create-7',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Final Exam',
        type: AssessmentType.exam,
        difficulty: AssessmentDifficulty.challenge,
        score: AssessmentScore(rawScore: 19, maxScore: 20),
      );

      final submitted = await SubmitAssessment(repository)(
        assessmentId: draft.id,
        expectedVersion: 1,
        commandId: 'cmd-submit-exam',
      );

      final verifyUseCase = VerifyAssessment(repository);
      final verified = await verifyUseCase(
        assessmentId: submitted.id,
        expectedVersion: 2,
        commandId: 'cmd-verify-exam',
        notes: 'Superb work!',
      );

      expect(verified.status, equals(AssessmentStatus.verified));
      expect(verified.version, equals(3));
      expect(repository.verifiedEvents.length, equals(1));
      expect(
        repository.verifiedEvents.first.subjectKey,
        equals(SubjectKey.math),
      );
      expect(repository.verifiedEvents.first.score.rawScore, equals(19));

      // Idempotent call with same commandId
      final retried = await verifyUseCase(
        assessmentId: submitted.id,
        expectedVersion: 2,
        commandId: 'cmd-verify-exam',
      );

      expect(retried.status, equals(AssessmentStatus.verified));
      expect(repository.verifiedEvents.length, equals(1));
    },
  );

  test(
    'RejectAssessment requires non-empty reason and caps at 500 chars',
    () async {
      final draft = await CreateAssessmentDraft(repository)(
        commandId: 'cmd-create-8',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.other,
        subject: 'Art',
        title: 'Project',
        type: AssessmentType.other,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 3, maxScore: 10),
      );

      final submitted = await SubmitAssessment(repository)(
        assessmentId: draft.id,
        expectedVersion: 1,
        commandId: 'cmd-submit-art',
      );

      final rejectUseCase = RejectAssessment(repository);

      // Empty reason throws
      expect(
        () => rejectUseCase(
          assessmentId: submitted.id,
          expectedVersion: 2,
          commandId: 'cmd-reject-art-empty',
          reason: '   ',
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );

      // Reason > 500 chars throws
      expect(
        () => rejectUseCase(
          assessmentId: submitted.id,
          expectedVersion: 2,
          commandId: 'cmd-reject-art-huge',
          reason: 'x' * 501,
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );

      final rejected = await rejectUseCase(
        assessmentId: submitted.id,
        expectedVersion: 2,
        commandId: 'cmd-reject-art',
        reason: 'Missing submission requirements',
      );

      expect(rejected.status, equals(AssessmentStatus.rejected));
      expect(repository.verifiedEvents.isEmpty, isTrue);
    },
  );

  test('SubmitAssessmentDraft coordinates distinct create/submit commands, evidence upload, and draft deletion', () async {
    final draftStore = InMemoryLocalDraftStore();
    const localId = 'local-draft-42';
    await draftStore.saveLocalDraft(
      LocalAssessmentDraft(
        localDraftId: localId,
        familyId: familyId.value,
        childId: childId.value,
        createCommandId: 'cmd-create-wf-1',
        submitCommandId: 'cmd-submit-wf-1',
        evidenceId: '550e8400-e29b-41d4-a716-446655440099',
        subjectKey: SubjectKey.english,
        subject: 'English',
        title: 'Spelling Quiz',
        assessmentType: 'quiz',
        difficulty: 'normal',
        rawScore: 9.0,
        maxScore: 10.0,
        occurredAt: DateTime.utc(2026, 11, 1),
        updatedAt: DateTime.utc(2026, 11, 1),
      ),
    );

    expect(await draftStore.getLocalDraft(localId), isNotNull);

    final submitWorkflow = SubmitAssessmentDraft(
      repository: repository,
      storage: storage,
      localDraftStore: draftStore,
      authSessionPort: fakeAuth,
    );

    final result = await submitWorkflow(
      createCommandId: 'cmd-create-wf-1',
      submitCommandId: 'cmd-submit-wf-1',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.english,
      subject: 'English',
      title: 'Spelling Quiz',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 9, maxScore: 10),
      evidenceBytes: [9, 8, 7],
      evidenceMediaType: 'image/jpeg',
      evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440099'),
      localDraftId: localId,
    );

    expect(result.status, equals(AssessmentStatus.pendingReview));
    expect(result.subjectKey, equals(SubjectKey.english));
    // Verify local draft was deleted after successful submission
    expect(await draftStore.getLocalDraft(localId), isNull);
    // Verify storage has evidence
    expect(storage.storage.values.first, equals([9, 8, 7]));
  });

  test('SubmitAssessmentDraft blocks quarantined legacy draft with StateError before network call', () async {
    final draftStore = InMemoryLocalDraftStore();
    const legacyDraftId = 'legacy-draft-quarantined-1';
    await draftStore.saveLocalDraft(
      LocalAssessmentDraft(
        localDraftId: legacyDraftId,
        familyId: familyId.value,
        childId: childId.value,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Legacy Draft',
        assessmentType: 'quiz',
        difficulty: 'normal',
        rawScore: 8.0,
        maxScore: 10.0,
        occurredAt: DateTime.utc(2026, 11, 1),
        updatedAt: DateTime.utc(2026, 11, 1),
        dispatchState: CommandDispatchState.unknownLegacy,
      ),
    );

    final submitWorkflow = SubmitAssessmentDraft(
      repository: repository,
      storage: storage,
      localDraftStore: draftStore,
      authSessionPort: fakeAuth,
    );

    await expectLater(
      () => submitWorkflow(
        createCommandId: 'cmd-create-legacy',
        submitCommandId: 'cmd-submit-legacy',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Legacy Draft',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 8, maxScore: 10),
        localDraftId: legacyDraftId,
      ),
      throwsA(isA<StateError>()),
    );

    // Verify draft remains quarantined in store
    final draftAfter = await draftStore.getLocalDraft(legacyDraftId);
    expect(draftAfter, isNotNull);
    expect(draftAfter!.dispatchState, CommandDispatchState.unknownLegacy);
  });

  test('SubmitAssessmentDraft persists possiblyDispatched before remote calls; failure retains state', () async {
    final draftStore = InMemoryLocalDraftStore();
    const testDraftId = 'draft-provenance-test-1';
    await draftStore.saveLocalDraft(
      LocalAssessmentDraft(
        localDraftId: testDraftId,
        familyId: familyId.value,
        childId: childId.value,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Failing Network Draft',
        assessmentType: 'quiz',
        difficulty: 'normal',
        rawScore: 8.0,
        maxScore: 10.0,
        occurredAt: DateTime.utc(2026, 11, 1),
        updatedAt: DateTime.utc(2026, 11, 1),
        dispatchState: CommandDispatchState.neverDispatched,
      ),
    );

    final failingRepo = _FailingCreateAssessmentRepository();

    final submitWorkflow = SubmitAssessmentDraft(
      repository: failingRepo,
      storage: storage,
      localDraftStore: draftStore,
      authSessionPort: fakeAuth,
    );

    await expectLater(
      () => submitWorkflow(
        createCommandId: 'cmd-create-fail',
        submitCommandId: 'cmd-submit-fail',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Failing Network Draft',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 8, maxScore: 10),
        localDraftId: testDraftId,
      ),
      throwsA(isA<Exception>()),
    );

    // Draft in store MUST have been updated to possiblyDispatched before remote call
    final draftAfter = await draftStore.getLocalDraft(testDraftId);
    expect(draftAfter, isNotNull);
    expect(draftAfter!.dispatchState, CommandDispatchState.possiblyDispatched);
    expect(
      draftAfter.submissionStatus,
      DraftSubmissionStatus.submittingAssessment,
    );
  });

  group('R32-06 / R32-07 / R32-08: Hardened Auth, Size Bounds, and Safe Fake/Demo Modes', () {
    test('R32-06: SubmitAssessmentDraft fails closed when unauthenticated without marking possiblyDispatched or calling RPCs', () async {
      final draftStore = InMemoryLocalDraftStore();
      const localId = 'draft-unauth-test-1';
      await draftStore.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: localId,
          familyId: familyId.value,
          childId: childId.value,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Unauthenticated Draft',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8.0,
          maxScore: 10.0,
          occurredAt: DateTime.utc(2026, 11, 1),
          updatedAt: DateTime.utc(2026, 11, 1),
          dispatchState: CommandDispatchState.neverDispatched,
        ),
      );

      fakeAuth.signOut();
      final submitWorkflow = SubmitAssessmentDraft(
        repository: repository,
        storage: storage,
        localDraftStore: draftStore,
        authSessionPort: fakeAuth,
      );

      await expectLater(
        () => submitWorkflow(
          createCommandId: 'cmd-unauth-create',
          submitCommandId: 'cmd-unauth-submit',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Unauthenticated Draft',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 8, maxScore: 10),
          localDraftId: localId,
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      final draftAfter = await draftStore.getLocalDraft(localId);
      expect(draftAfter!.dispatchState, CommandDispatchState.neverDispatched);
      expect(repository.assessments, isEmpty);
    });

    test('R32-06: SubmitAssessmentDraft revalidates auth before final submitAssessment even without evidence', () async {
      var calls = 0;
      fakeAuth.onValidateForMutation = (callCount) {
        calls = callCount;
        // First check passes preflight before createDraft; second check (before submitAssessment) fails
        if (callCount >= 2) {
          fakeAuth.setSessionGeneration('gen-rotated-before-submit');
        }
      };

      final submitWorkflow = SubmitAssessmentDraft(
        repository: repository,
        storage: storage,
        authSessionPort: fakeAuth,
      );

      await expectLater(
        () => submitWorkflow(
          createCommandId: 'cmd-submit-revalidate-create',
          submitCommandId: 'cmd-submit-revalidate-submit',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.english,
          subject: 'English',
          title: 'Reading Log',
          type: AssessmentType.homework,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 10, maxScore: 10),
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      expect(calls, equals(2));
      expect(
        repository.assessments.values.single.status,
        equals(AssessmentStatus.draft),
      );
    });

    test('R32-06: FakeAssessmentEvidenceStorage fails closed without authSessionPort unless explicitly configured', () async {
      final unconfiguredStorage = FakeAssessmentEvidenceStorage();
      final evId = EvidenceId('550e8400-e29b-41d4-a716-446655440200');
      const path =
          'fam-1/child-1/asmt-1/550e8400-e29b-41d4-a716-446655440200.jpg';

      await expectLater(
        () => unconfiguredStorage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: AssessmentId('asmt-1'),
          evidenceId: evId,
          bytes: [1, 2, 3],
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      await expectLater(
        () => unconfiguredStorage.downloadEvidence(storagePath: path),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      final reconcile = await unconfiguredStorage.reconcileEvidence(
        storagePath: path,
        localBytes: [1, 2, 3],
      );
      expect(reconcile, isA<AuthFailureOutcome>());
      await expectLater(
        () => unconfiguredStorage.getEvidenceSignedUrl(storagePath: path),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      await expectLater(
        () => unconfiguredStorage.deleteEvidence(path),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      // Explicitly configured unauthenticated fake preserves opt-in behavior
      final explicitUnauth = FakeAssessmentEvidenceStorage.unauthenticated();
      final uploadedPath = await explicitUnauth.uploadEvidence(
        familyId: familyId,
        childId: childId,
        assessmentId: AssessmentId('asmt-1'),
        evidenceId: evId,
        bytes: [1, 2, 3],
        mediaType: 'image/jpeg',
      );
      expect(uploadedPath, isNotEmpty);
    });

    test('R32-08: UploadAssessmentEvidence and SubmitAssessmentDraft reject zero-length and >10 MiB evidence cleanly', () async {
      final draft = await CreateAssessmentDraft(repository)(
        commandId: 'cmd-create-zero-size',
        familyId: familyId,
        childId: childId,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Zero Byte Test',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 5, maxScore: 10),
      );

      final uploadUseCase = UploadAssessmentEvidence(
        repository: repository,
        storage: storage,
        authSessionPort: fakeAuth,
      );

      await expectLater(
        () => uploadUseCase(
          familyId: familyId,
          childId: childId,
          assessmentId: draft.id,
          evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440301'),
          bytes: const [],
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );

      // Exact 10 MiB boundary succeeds
      final exactMax = List<int>.filled(10 * 1024 * 1024, 9);
      final registered = await uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440302'),
        bytes: exactMax,
        mediaType: 'image/png',
      );
      expect(registered.fileSizeBytes, equals(10 * 1024 * 1024));

      // SubmitAssessmentDraft rejects zero-length attached evidence BEFORE createDraft
      final submitWorkflow = SubmitAssessmentDraft(
        repository: repository,
        storage: storage,
        authSessionPort: fakeAuth,
      );
      await expectLater(
        () => submitWorkflow(
          createCommandId: 'cmd-submit-zero-evidence',
          submitCommandId: 'cmd-submit-zero-evidence-2',
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.science,
          subject: 'Science',
          title: 'Empty Evidence Draft',
          type: AssessmentType.homework,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 8, maxScore: 10),
          evidenceBytes: const [],
          evidenceMediaType: 'image/jpeg',
          evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440303'),
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );

      // Zero new drafts created for rejected empty evidence
      expect(repository.assessments.length, equals(1));
    });
  });

  group('R32-09: Session Revalidation Across Async saveLocalDraft Before createDraft', () {
    Future<void> verifyRejectedAcrossSaveBarrier({
      required String scenarioLabel,
      required void Function(FakeAuthSessionPort auth) mutateSession,
    }) async {
      final draftStore = InMemoryLocalDraftStore();
      final recordingRepo = _RecordingAssessmentRepository();
      const localId = 'draft-r32-09-barrier';
      const createCommandId = 'cmd-r32-09-create';
      const submitCommandId = 'cmd-r32-09-submit';
      const evidenceUuid = '550e8400-e29b-41d4-a716-446655440901';
      const localPhotoPath = '/tmp/r32-09-evidence.jpg';
      const actorUserId = 'user-parent-1';

      await draftStore.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: localId,
          familyId: familyId.value,
          childId: childId.value,
          createCommandId: createCommandId,
          submitCommandId: submitCommandId,
          evidenceId: evidenceUuid,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Barrier Scenario: $scenarioLabel',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 9.0,
          maxScore: 10.0,
          localPhotoPath: localPhotoPath,
          actorUserId: actorUserId,
          occurredAt: DateTime.utc(2026, 11, 1),
          updatedAt: DateTime.utc(2026, 11, 1),
          dispatchState: CommandDispatchState.neverDispatched,
        ),
      );

      final enteredSave = Completer<void>();
      final releaseSave = Completer<void>();
      var armBarrier = true;
      draftStore.onSaveLocalDraft = (_) async {
        if (armBarrier) {
          armBarrier = false;
          enteredSave.complete();
          await releaseSave.future;
        }
      };

      final evidenceBytes = <int>[10, 20, 30, 40];
      final expectedEvidenceBytes = List<int>.from(evidenceBytes);

      final submitWorkflow = SubmitAssessmentDraft(
        repository: recordingRepo,
        storage: storage,
        localDraftStore: draftStore,
        authSessionPort: fakeAuth,
      );

      final submissionExpectation = expectLater(
        submitWorkflow(
          createCommandId: createCommandId,
          submitCommandId: submitCommandId,
          familyId: familyId,
          childId: childId,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Barrier Scenario: $scenarioLabel',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          evidenceBytes: evidenceBytes,
          evidenceMediaType: 'image/jpeg',
          evidenceId: EvidenceId(evidenceUuid),
          localDraftId: localId,
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      await enteredSave.future;
      mutateSession(fakeAuth);
      releaseSave.complete();
      await submissionExpectation;

      // Preflight check + post-save/pre-createDraft revalidation ran; never proceeded further
      expect(fakeAuth.validateCallCount, equals(2));

      // Zero network mutations or destructive deletes executed
      expect(recordingRepo.createDraftCallCount, equals(0));
      expect(recordingRepo.registerEvidenceCallCount, equals(0));
      expect(recordingRepo.submitAssessmentCallCount, equals(0));
      expect(recordingRepo.assessments, isEmpty);
      expect(storage.uploadCallCount, equals(0));
      expect(storage.downloadCallCount, equals(0));
      expect(storage.reconcileCallCount, equals(0));
      expect(storage.deleteCallCount, equals(0));
      expect(draftStore.deleteLocalDraftCallCount, equals(0));

      // Local journal, original IDs, and evidence bytes remain preserved
      final draftAfter = await draftStore.getLocalDraft(localId);
      expect(draftAfter, isNotNull);
      expect(draftAfter!.localDraftId, equals(localId));
      expect(draftAfter.createCommandId, equals(createCommandId));
      expect(draftAfter.submitCommandId, equals(submitCommandId));
      expect(draftAfter.evidenceId, equals(evidenceUuid));
      expect(draftAfter.localPhotoPath, equals(localPhotoPath));
      expect(draftAfter.actorUserId, equals(actorUserId));
      expect(evidenceBytes, equals(expectedEvidenceBytes));
    }

    test('rejects actor switch occurring while localDraftStore.saveLocalDraft is pending before createDraft', () async {
      await verifyRejectedAcrossSaveBarrier(
        scenarioLabel: 'actor-switch',
        mutateSession: (auth) => auth.switchActor('user-parent-2'),
      );
    });

    test('rejects actor switch with unchanged sessionGeneration while localDraftStore.saveLocalDraft is pending', () async {
      await verifyRejectedAcrossSaveBarrier(
        scenarioLabel: 'actor-switch-same-generation',
        mutateSession: (auth) => auth.setContext(
          ValidatedActorContext(
            userId: 'user-parent-2',
            sessionGeneration: 'gen-1',
            observedAt: DateTime.now().toUtc(),
          ),
        ),
      );
    });

    test('rejects sign-out occurring while localDraftStore.saveLocalDraft is pending before createDraft', () async {
      await verifyRejectedAcrossSaveBarrier(
        scenarioLabel: 'sign-out',
        mutateSession: (auth) => auth.signOut(),
      );
    });

    test('rejects session generation rotation occurring while localDraftStore.saveLocalDraft is pending', () async {
      await verifyRejectedAcrossSaveBarrier(
        scenarioLabel: 'session-generation-rotation',
        mutateSession: (auth) => auth.setSessionGeneration('gen-rotated'),
      );
    });

    test('rejects expired session observed across pending localDraftStore.saveLocalDraft write', () async {
      await verifyRejectedAcrossSaveBarrier(
        scenarioLabel: 'expired-session',
        mutateSession: (auth) => auth.setContext(
          ValidatedActorContext(
            userId: 'user-parent-1',
            sessionGeneration: 'gen-1',
            observedAt: DateTime.now().toUtc().subtract(
              const Duration(minutes: 6),
            ),
          ),
        ),
      );
    });
  });
}

final class _RecordingAssessmentRepository extends FakeAssessmentRepository {
  int createDraftCallCount = 0;
  int registerEvidenceCallCount = 0;
  int submitAssessmentCallCount = 0;

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
    return super.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
    );
  }
}

final class _FailingCreateAssessmentRepository
    extends FakeAssessmentRepository {
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
    throw Exception('Simulated network timeout during createDraft');
  }
}
