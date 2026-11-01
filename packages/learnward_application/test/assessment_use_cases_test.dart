import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

final class InMemoryLocalDraftStore implements LocalDraftStore {
  final Map<String, LocalAssessmentDraft> drafts = {};

  @override
  Future<void> saveLocalDraft(LocalAssessmentDraft draft) async {
    drafts[draft.localDraftId] = draft;
  }

  @override
  Future<LocalAssessmentDraft?> getLocalDraft(String localDraftId) async {
    return drafts[localDraftId];
  }

  @override
  Future<List<LocalAssessmentDraft>> listLocalDrafts(ChildId childId) async {
    return drafts.values.where((d) => d.childId == childId.value).toList();
  }

  @override
  Future<void> deleteLocalDraft(String localDraftId) async {
    drafts.remove(localDraftId);
  }
}

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
  }) => inner.uploadEvidence(
    familyId: familyId,
    childId: childId,
    assessmentId: assessmentId,
    evidenceId: evidenceId,
    bytes: bytes,
    mediaType: mediaType,
  );

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
  }) => inner.getEvidenceSignedUrl(
    storagePath: storagePath,
    expiresIn: expiresIn,
  );

  @override
  Future<void> deleteEvidence(String storagePath) async {
    throw StateError('Simulated storage delete failure');
  }
}

void main() {
  late FakeAssessmentRepository repository;
  late FakeAssessmentEvidenceStorage storage;

  final familyId = FamilyId('fam-1');
  final childId = ChildId('child-1');

  setUp(() {
    repository = FakeAssessmentRepository();
    storage = FakeAssessmentEvidenceStorage();
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

  test('UploadAssessmentEvidence performs compensation cleanup when DB registration fails', () async {
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
    );

    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440003'),
        bytes: [1, 2, 3, 4],
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<StateError>()),
    );

    // Verify storage object was compensated/deleted
    expect(storage.storage.isEmpty, isTrue);
  });

  test('UploadAssessmentEvidence invokes onCleanupError safely when storage deletion fails', () async {
    final failingRepo = FailingRegisterAssessmentRepository();
    final failingStorage = FailingDeleteStorage(storage);
    String? reportedMessage;
    Object? reportedError;

    final uploadUseCase = UploadAssessmentEvidence(
      repository: failingRepo,
      storage: failingStorage,
      onCleanupError: (msg, err) {
        reportedMessage = msg;
        reportedError = err;
      },
    );

    final draft = await CreateAssessmentDraft(repository)(
      commandId: 'cmd-create-fail-del',
      familyId: familyId,
      childId: childId,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Lab 2',
      type: AssessmentType.homework,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 8, maxScore: 10),
    );

    await expectLater(
      () => uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: EvidenceId('550e8400-e29b-41d4-a716-446655440004'),
        bytes: [5, 6, 7],
        mediaType: 'image/jpeg',
      ),
      throwsA(isA<StateError>()),
    );

    expect(reportedMessage, contains('Failed to clean up'));
    expect(reportedError, isNotNull);
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
}
