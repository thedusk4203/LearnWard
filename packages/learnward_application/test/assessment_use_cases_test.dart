import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  late FakeAssessmentRepository repository;
  late FakeAssessmentEvidenceStorage storage;

  final familyId = FamilyId('fam-1');
  final childId = ChildId('child-1');

  setUp(() {
    repository = FakeAssessmentRepository();
    storage = FakeAssessmentEvidenceStorage();
  });

  test('CreateAssessmentDraft creates a valid draft', () async {
    final useCase = CreateAssessmentDraft(repository);
    final assessment = await useCase(
      familyId: familyId,
      childId: childId,
      subject: 'Math',
      title: 'Fractions Test',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 8, maxScore: 10),
    );

    expect(assessment.status, equals(AssessmentStatus.draft));
    expect(assessment.version, equals(1));
    expect(assessment.score.rawScore, equals(8));
  });

  test('UpdateAssessmentDraft updates fields and increments version', () async {
    final createUseCase = CreateAssessmentDraft(repository);
    final draft = await createUseCase(
      familyId: familyId,
      childId: childId,
      subject: 'Math',
      title: 'Draft 1',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 7, maxScore: 10),
    );

    final updateUseCase = UpdateAssessmentDraft(repository);
    final updated = await updateUseCase(
      assessmentId: draft.id,
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
      familyId: familyId,
      childId: childId,
      subject: 'History',
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

  test(
    'UploadAssessmentEvidence stores bytes and registers evidence',
    () async {
      final draft = await CreateAssessmentDraft(repository)(
        familyId: familyId,
        childId: childId,
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
        fileName: 'page1.jpg',
        bytes: [1, 2, 3, 4],
        mediaType: 'image/jpeg',
      );

      expect(evidence.mediaType, equals('image/jpeg'));
      expect(evidence.fileSizeBytes, equals(4));
      expect(storage.storage[evidence.storagePath], equals([1, 2, 3, 4]));
    },
  );

  test(
    'VerifyAssessment creates immutable learning event and is idempotent',
    () async {
      final draft = await CreateAssessmentDraft(repository)(
        familyId: familyId,
        childId: childId,
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

  test('RejectAssessment transitions status to rejected', () async {
    final draft = await CreateAssessmentDraft(repository)(
      familyId: familyId,
      childId: childId,
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
    final rejected = await rejectUseCase(
      assessmentId: submitted.id,
      expectedVersion: 2,
      commandId: 'cmd-reject-art',
      reason: 'Missing submission requirements',
    );

    expect(rejected.status, equals(AssessmentStatus.rejected));
    expect(repository.verifiedEvents.isEmpty, isTrue);
  });

  test(
    'ListPendingAssessments and ListVerifiedLearningEvents query correctly',
    () async {
      final draft1 = await CreateAssessmentDraft(repository)(
        familyId: familyId,
        childId: childId,
        subject: 'Math',
        title: 'Test 1',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 8, maxScore: 10),
      );
      await SubmitAssessment(repository)(
        assessmentId: draft1.id,
        expectedVersion: 1,
        commandId: 'cmd-sub-1',
      );

      final pendingList = await ListPendingAssessments(repository)
          .forFamily(familyId);
      expect(pendingList.length, equals(1));
      expect(pendingList.first.id, equals(draft1.id));

      await VerifyAssessment(repository)(
        assessmentId: draft1.id,
        expectedVersion: 2,
        commandId: 'cmd-ver-1',
      );

      final events = await ListVerifiedLearningEvents(repository)(childId);
      expect(events.length, equals(1));
      expect(events.first.subject, equals('Math'));
    },
  );
}
