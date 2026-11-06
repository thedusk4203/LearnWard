import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/assessments/presentation/add_assessment_screen.dart';
import 'package:learnward/features/assessments/presentation/evidence_picker_service.dart';
import 'package:learnward/features/assessments/services/local_evidence_file_store.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

class FakeLocalEvidenceFileStore implements LocalEvidenceFileStore {
  final Map<String, List<int>> files = {};

  @override
  Future<String> saveDurableEvidence({
    required String localDraftId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final path = '/mock/evidence/${localDraftId}_test.jpg';
    files[path] = bytes;
    return path;
  }

  @override
  Future<String> saveEvidence({
    required String fileName,
    required List<int> bytes,
  }) async {
    final path = '/mock/evidence/$fileName';
    files[path] = bytes;
    return path;
  }

  @override
  Future<List<int>?> readEvidenceBytes(String filePath) async =>
      files[filePath];

  @override
  Future<List<int>?> loadEvidence(String filePath) =>
      readEvidenceBytes(filePath);

  @override
  Future<void> deleteDurableEvidence(String filePath) async {
    files.remove(filePath);
  }

  @override
  Future<void> deleteEvidence(String filePath) =>
      deleteDurableEvidence(filePath);
}

class _PresetActiveChildNotifier extends ActiveChildModeNotifier {
  _PresetActiveChildNotifier(this._preset);
  final ChildProfile? _preset;

  @override
  ChildProfile? build() => _preset;
}

class _PresetFamilyNotifier extends ActiveFamilyNotifier {
  _PresetFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

void main() {
  late FakeFamilyRepository fakeFamilyRepo;
  late FakeChildProfileRepository fakeChildRepo;
  late FakeAssessmentRepository fakeAssessmentRepo;
  late FakeAssessmentEvidenceStorage fakeStorage;
  late InMemoryLocalMetadataStore fakeMetadataStore;
  late FakeLocalEvidenceFileStore fakeEvidenceFileStore;
  late InMemoryLocalDraftStore fakeDraftStore;

  final now = DateTime.utc(2026, 11, 1);
  final testFamily = Family(
    id: FamilyId('fam-test-1'),
    name: 'Test Family',
    timezone: 'UTC',
    locale: 'en_US',
    createdByUserId: 'parent-1',
    createdAt: now,
  );

  final testChild = ChildProfile(
    id: ChildId('child-test-1'),
    familyId: testFamily.id,
    displayName: 'Lucas',
    schoolGrade: 5,
    birthYear: 2015,
    createdAt: now,
  );

  setUp(() {
    fakeFamilyRepo = FakeFamilyRepository();
    fakeChildRepo = FakeChildProfileRepository();
    fakeAssessmentRepo = FakeAssessmentRepository();
    fakeStorage = FakeAssessmentEvidenceStorage();
    fakeMetadataStore = InMemoryLocalMetadataStore();
    fakeEvidenceFileStore = FakeLocalEvidenceFileStore();
    fakeDraftStore = InMemoryLocalDraftStore();

    fakeFamilyRepo.createFamily(
      name: testFamily.name,
      timezone: testFamily.timezone,
      locale: testFamily.locale,
    );
  });

  testWidgets(
    'Child Mode: captures assessment, calculates normalized score, attaches evidence and submits',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            localEvidenceFileStoreProvider.overrideWithValue(
              fakeEvidenceFileStore,
            ),
            localDraftStoreProvider.overrideWithValue(fakeDraftStore),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetActiveChildNotifier(testChild),
            ),
            evidencePickerServiceProvider.overrideWithValue(
              SimulatedEvidencePickerService(
                stubFile: const SelectedEvidenceFile(
                  fileName: 'math_quiz.jpg',
                  bytes: [1, 2, 3],
                  mediaType: 'image/jpeg',
                  localPath: '/tmp/math_quiz.jpg',
                ),
              ),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      await tester.pumpAndSettle();

      // In Child Mode
      expect(find.text('Hi, Lucas!'), findsOneWidget);
      expect(
        find.byKey(const Key('child_add_assessment_button')),
        findsOneWidget,
      );

      // Tap Add Academic Result
      await tester.tap(find.byKey(const Key('child_add_assessment_button')));
      await tester.pumpAndSettle();

      expect(find.text('Add Assessment Result'), findsOneWidget);

      // Enter Title
      await tester.enterText(
        find.byKey(const Key('assessment_title_field')),
        'Fractions Mastery Quiz',
      );

      // Enter Raw Score 8.5 and Max Score 10
      await tester.enterText(
        find.byKey(const Key('assessment_raw_score_field')),
        '8.5',
      );
      await tester.pumpAndSettle();

      // Check live normalized score preview
      expect(find.text('Normalized Score: 8.50 / 10.0'), findsOneWidget);

      // Attach evidence photo
      await tester.ensureVisible(
        find.byKey(const Key('attach_evidence_button')),
      );
      await tester.tap(find.byKey(const Key('attach_evidence_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('math_quiz.jpg'), findsOneWidget);

      // Submit for review
      await tester.ensureVisible(
        find.byKey(const Key('submit_assessment_button')),
      );
      await tester.tap(find.byKey(const Key('submit_assessment_button')));
      await tester.pumpAndSettle();

      // Should return to Child Mode
      expect(find.text('Hi, Lucas!'), findsOneWidget);

      // Repository state assertion: exactly 1 pending assessment exists
      expect(fakeAssessmentRepo.assessments.length, equals(1));
      final submitted = fakeAssessmentRepo.assessments.values.first;
      expect(submitted.status, equals(AssessmentStatus.pendingReview));
      expect(submitted.title, equals('Fractions Mastery Quiz'));
      expect(submitted.score.rawScore, equals(8.5));
      expect(submitted.score.maxScore, equals(10.0));
      expect(submitted.score.serverNormalizedScore, equals(8.50));
    },
  );

  testWidgets(
    'Parent Mode: reviews pending assessment and verifies it into immutable learning event',
    (tester) async {
      // Pre-seed a submitted pending assessment
      final draft = await fakeAssessmentRepo.createDraft(
        commandId: 'cmd-create-draft-1',
        familyId: testFamily.id,
        childId: testChild.id,
        subjectKey: SubjectKey.math,
        subject: 'Mathematics',
        title: 'Weekly Test 1',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
      );
      final submitted = await fakeAssessmentRepo.submitAssessment(
        assessmentId: draft.id,
        expectedVersion: 1,
        commandId: 'cmd-sub-test',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            localEvidenceFileStoreProvider.overrideWithValue(
              fakeEvidenceFileStore,
            ),
            localDraftStoreProvider.overrideWithValue(fakeDraftStore),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      await tester.pumpAndSettle();

      // On Family Home Screen
      expect(find.text('Pending Reviews'), findsOneWidget);
      expect(
        find.byKey(Key('pending_card_${submitted.id.value}')),
        findsOneWidget,
      );

      // Tap Review
      await tester.tap(find.byKey(Key('review_button_${submitted.id.value}')));
      await tester.pumpAndSettle();

      expect(find.text('Review Assessment'), findsOneWidget);
      expect(find.text('9.0 / 10.0'), findsOneWidget);
      expect(find.text('9.0 / 10'), findsOneWidget);

      // Tap Verify Result
      await tester.tap(find.byKey(const Key('verify_assessment_button')));
      await tester.pumpAndSettle();

      // Confirmation dialog
      expect(find.text('Confirm Verify'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('verification_notes_field')),
        'Verified correctly solved steps',
      );
      await tester.tap(find.byKey(const Key('confirm_verify_button')));
      await tester.pumpAndSettle();

      // Back on Family Home Screen: pending section now empty
      expect(
        find.text('All caught up! No pending submissions.'),
        findsOneWidget,
      );

      // Assert verified learning event was generated
      expect(fakeAssessmentRepo.verifiedEvents.length, equals(1));
      final event = fakeAssessmentRepo.verifiedEvents.first;
      expect(event.title, equals('Weekly Test 1'));
      expect(event.score.rawScore, equals(9.0));
      expect(event.score.serverNormalizedScore, equals(9.0));
    },
  );

  testWidgets('Parent Mode: rejects a submitted assessment with reason note', (
    tester,
  ) async {
    final draft = await fakeAssessmentRepo.createDraft(
      commandId: 'cmd-create-draft-2',
      familyId: testFamily.id,
      childId: testChild.id,
      subjectKey: SubjectKey.english,
      subject: 'English',
      title: 'Vocabulary Quiz',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 5.0, maxScore: 10.0),
    );
    final submitted = await fakeAssessmentRepo.submitAssessment(
      assessmentId: draft.id,
      expectedVersion: 1,
      commandId: 'cmd-sub-vocab',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
          assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
          activeFamilyProvider.overrideWith(
            () => _PresetFamilyNotifier(testFamily),
          ),
        ],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Review
    await tester.tap(find.byKey(Key('review_button_${submitted.id.value}')));
    await tester.pumpAndSettle();

    // Tap Reject
    await tester.tap(find.byKey(const Key('reject_assessment_button')));
    await tester.pumpAndSettle();

    // Enter rejection reason
    await tester.enterText(
      find.byKey(const Key('rejection_reason_field')),
      'Incomplete page 2',
    );
    await tester.tap(find.byKey(const Key('confirm_reject_button')));
    await tester.pumpAndSettle();

    // Verified events should still be 0
    expect(fakeAssessmentRepo.verifiedEvents.isEmpty, isTrue);
    // Status in repo must be rejected
    expect(
      fakeAssessmentRepo.assessments[submitted.id.value]?.status,
      equals(AssessmentStatus.rejected),
    );
  });

  testWidgets('Child Mode: reopens and edits an unsubmitted local draft', (
    tester,
  ) async {
    final preDraft = LocalAssessmentDraft(
      localDraftId: 'draft-offline-123',
      familyId: testFamily.id.value,
      childId: testChild.id.value,
      createCommandId: 'cmd-create-123',
      submitCommandId: 'cmd-submit-123',
      evidenceId: null,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Solar System Quiz',
      assessmentType: 'quiz',
      difficulty: 'normal',
      rawScore: 9.0,
      maxScore: 10.0,
      occurredAt: now,
      updatedAt: now,
    );
    await fakeDraftStore.saveLocalDraft(preDraft);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
          assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
          localEvidenceFileStoreProvider.overrideWithValue(
            fakeEvidenceFileStore,
          ),
          localDraftStoreProvider.overrideWithValue(fakeDraftStore),
          activeFamilyProvider.overrideWith(
            () => _PresetFamilyNotifier(testFamily),
          ),
          activeChildModeProvider.overrideWith(
            () => _PresetActiveChildNotifier(testChild),
          ),
        ],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Verify unsubmitted local draft is displayed on Child Mode screen
    expect(find.text('Unsubmitted Local Drafts (1)'), findsOneWidget);
    expect(find.text('Solar System Quiz'), findsOneWidget);

    // Tap draft card to reopen
    await tester.tap(find.byKey(Key('local_draft_${preDraft.localDraftId}')));
    await tester.pumpAndSettle();

    // Verify Edit screen opened and prefilled
    expect(find.text('Edit Assessment Draft'), findsOneWidget);
    expect(find.text('Solar System Quiz'), findsOneWidget);
    expect(find.text('9.0'), findsOneWidget);

    // Submit the draft
    await tester.ensureVisible(
      find.byKey(const Key('submit_assessment_button')),
    );
    await tester.tap(find.byKey(const Key('submit_assessment_button')));
    await tester.pumpAndSettle();

    // Returns to Child Mode screen, local draft should be removed
    expect(find.text('Hi, Lucas!'), findsOneWidget);
    expect(find.text('Unsubmitted Local Drafts (1)'), findsNothing);
    expect(fakeAssessmentRepo.assessments.length, equals(1));
    expect(
      fakeAssessmentRepo.assessments.values.first.title,
      equals('Solar System Quiz'),
    );
  });

  test(
    'ActiveChildModeNotifier persists and restores canonical avatar_key',
    () async {
      final container = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
        ],
      );
      addTearDown(container.dispose);

      final childWithAvatar = ChildProfile(
        id: ChildId('child-lion-1'),
        familyId: testFamily.id,
        displayName: 'Leo',
        avatarKey: 'avatar-lion',
        createdAt: now,
      );

      final notifier = container.read(activeChildModeProvider.notifier);
      await notifier.selectChild(childWithAvatar);

      // Verify written JSON in metadata store contains avatar_key
      final savedJson = await fakeMetadataStore.readMetadata(
        ActiveChildModeNotifier.activeSessionKey,
      );
      expect(savedJson, isNotNull);
      expect(savedJson, contains('"avatar_key":"avatar-lion"'));
      expect(savedJson, contains('"avatarKey":"avatar-lion"'));

      // Create a new container simulating app restart
      final restartContainer = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
        ],
      );
      addTearDown(restartContainer.dispose);

      // Read to trigger build and wait for async restore
      restartContainer.read(activeChildModeProvider);
      await pumpEventQueue();

      final restoredChild = restartContainer.read(activeChildModeProvider);
      expect(restoredChild, isNotNull);
      expect(restoredChild!.avatarKey, equals('avatar-lion'));
      expect(restoredChild.displayName, equals('Leo'));
    },
  );

  testWidgets(
    'Child Mode: submission failure displays friendly error message',
    (tester) async {
      final failingRepo = _FailingSubmitAssessmentRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(failingRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            localEvidenceFileStoreProvider.overrideWithValue(
              fakeEvidenceFileStore,
            ),
            localDraftStoreProvider.overrideWithValue(fakeDraftStore),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetActiveChildNotifier(testChild),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Add Academic Result
      await tester.tap(find.byKey(const Key('child_add_assessment_button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('assessment_title_field')),
        'Difficult Test',
      );
      await tester.enterText(
        find.byKey(const Key('assessment_raw_score_field')),
        '7.0',
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('submit_assessment_button')),
      );
      await tester.tap(find.byKey(const Key('submit_assessment_button')));
      await tester.pumpAndSettle();

      // Friendly error message should be displayed without raw SQL details
      expect(
        find.textContaining('Could not connect to the server'),
        findsOneWidget,
      );
      expect(
        find.textContaining('FATAL: 28P01: password authentication failed'),
        findsNothing,
      );
    },
  );

  testWidgets('Parent Mode: review screen displays attached evidence preview', (
    tester,
  ) async {
    final draft = await fakeAssessmentRepo.createDraft(
      commandId: 'cmd-create-ev-1',
      familyId: testFamily.id,
      childId: testChild.id,
      subjectKey: SubjectKey.science,
      subject: 'Science',
      title: 'Lab Report',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 10.0, maxScore: 10.0),
    );

    // Upload evidence
    await fakeAssessmentRepo.registerEvidence(
      assessmentId: draft.id,
      storagePath:
          '${testFamily.id.value}/${testChild.id.value}/${draft.id.value}/ev-lab-1.jpg',
      mediaType: 'image/jpeg',
      fileSizeBytes: 2048,
    );

    final submitted = await fakeAssessmentRepo.submitAssessment(
      assessmentId: draft.id,
      expectedVersion: 1,
      commandId: 'cmd-sub-lab',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
          assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
          localEvidenceFileStoreProvider.overrideWithValue(
            fakeEvidenceFileStore,
          ),
          localDraftStoreProvider.overrideWithValue(fakeDraftStore),
          activeFamilyProvider.overrideWith(
            () => _PresetFamilyNotifier(testFamily),
          ),
        ],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Review
    await tester.tap(find.byKey(Key('review_button_${submitted.id.value}')));
    await tester.pumpAndSettle();

    // Check evidence preview item is rendered
    expect(find.text('ev-lab-1.jpg'), findsAtLeast(1));
    expect(find.text('2.0 KB'), findsOneWidget);
  });

  testWidgets(
    'AddAssessment: generates distinct create/submit command IDs and reuses them on retry',
    (tester) async {
      final trackingRepo = _TrackingAssessmentRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(trackingRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            localEvidenceFileStoreProvider.overrideWithValue(
              fakeEvidenceFileStore,
            ),
            localDraftStoreProvider.overrideWithValue(fakeDraftStore),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetActiveChildNotifier(testChild),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Add Academic Result
      await tester.tap(find.byKey(const Key('child_add_assessment_button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('assessment_title_field')),
        'Idempotency Test',
      );
      await tester.enterText(
        find.byKey(const Key('assessment_raw_score_field')),
        '8.0',
      );
      await tester.pumpAndSettle();

      // Make first submit attempt fail at submitAssessment
      trackingRepo.failSubmit = true;

      await tester.ensureVisible(
        find.byKey(const Key('submit_assessment_button')),
      );
      await tester.tap(find.byKey(const Key('submit_assessment_button')));
      await tester.pumpAndSettle();

      expect(trackingRepo.recordedCreateCommandIds.length, equals(1));
      final firstCreateCmd = trackingRepo.recordedCreateCommandIds.first;
      expect(trackingRepo.recordedSubmitCommandIds.length, equals(1));
      final firstSubmitCmd = trackingRepo.recordedSubmitCommandIds.first;

      // INVARIANT: createCommandId must NOT equal submitCommandId
      expect(firstCreateCmd, isNot(equals(firstSubmitCmd)));

      // Draft was persisted locally with stable IDs
      final savedDrafts = await fakeDraftStore.listLocalDrafts(testChild.id);
      expect(savedDrafts.length, equals(1));
      expect(savedDrafts.first.createCommandId, equals(firstCreateCmd));
      expect(savedDrafts.first.submitCommandId, equals(firstSubmitCmd));

      // Now clear failure and retry submitting
      trackingRepo.failSubmit = false;
      await tester.ensureVisible(
        find.byKey(const Key('submit_assessment_button')),
      );
      await tester.tap(find.byKey(const Key('submit_assessment_button')));
      await tester.pumpAndSettle();

      // INVARIANT: retry reuses the exact same create and submit command IDs
      expect(trackingRepo.recordedCreateCommandIds.length, equals(2));
      expect(trackingRepo.recordedCreateCommandIds[1], equals(firstCreateCmd));
      expect(trackingRepo.recordedSubmitCommandIds.length, equals(2));
      expect(trackingRepo.recordedSubmitCommandIds[1], equals(firstSubmitCmd));

      // Submission succeeded and draft was deleted
      final remainingDrafts = await fakeDraftStore.listLocalDrafts(
        testChild.id,
      );
      expect(remainingDrafts.isEmpty, isTrue);
    },
  );

  testWidgets(
    'Parent Mode: verify failure displays friendly mapped error without leaking raw exceptions',
    (tester) async {
      final failingVerifyRepo = _FailingVerifyAssessmentRepository();
      final draft = await failingVerifyRepo.createDraft(
        commandId: 'cmd-ver-fail-1',
        familyId: testFamily.id,
        childId: testChild.id,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Review Fail Test',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
      );
      final submitted = await failingVerifyRepo.submitAssessment(
        assessmentId: draft.id,
        expectedVersion: 1,
        commandId: 'cmd-sub-fail-1',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(failingVerifyRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            localEvidenceFileStoreProvider.overrideWithValue(
              fakeEvidenceFileStore,
            ),
            localDraftStoreProvider.overrideWithValue(fakeDraftStore),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Review
      await tester.tap(find.byKey(Key('review_button_${submitted.id.value}')));
      await tester.pumpAndSettle();

      // Tap Verify button to open confirmation dialog
      await tester.tap(find.byKey(const Key('verify_assessment_button')));
      await tester.pumpAndSettle();

      // Tap Confirm Verify in dialog
      await tester.tap(find.byKey(const Key('confirm_verify_button')));
      await tester.pumpAndSettle();

      // Friendly error should be mapped without raw SQL details
      expect(find.textContaining('Network connection issue'), findsOneWidget);
      expect(find.textContaining('PG_ERR_5432'), findsNothing);
    },
  );

  testWidgets(
    'AddAssessmentScreen displays quarantine banner, disables submit, and preserves metadata for unknown_legacy draft',
    (tester) async {
      final legacyDraft = LocalAssessmentDraft(
        localDraftId: 'legacy-draft-quarantine-test',
        familyId: testFamily.id.value,
        childId: testChild.id.value,
        subjectKey: SubjectKey.science,
        subject: 'Physics',
        title: 'Legacy Physics Lab',
        assessmentType: 'quiz',
        difficulty: 'hard',
        rawScore: 9.0,
        maxScore: 10.0,
        occurredAt: now,
        updatedAt: now,
        dispatchState: CommandDispatchState.unknownLegacy,
        submissionStatus: DraftSubmissionStatus.draft,
        retryCount: 2,
        actorUserId: 'usr-legacy-actor',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            localEvidenceFileStoreProvider.overrideWithValue(
              fakeEvidenceFileStore,
            ),
            localDraftStoreProvider.overrideWithValue(fakeDraftStore),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetActiveChildNotifier(testChild),
            ),
          ],
          child: MaterialApp(
            home: AddAssessmentScreen(initialDraft: legacyDraft),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Verify quarantine banner is displayed
      expect(
        find.byKey(const Key('legacy_draft_quarantine_banner')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'This draft was preserved from an earlier app version',
        ),
        findsOneWidget,
      );

      // 2. Verify Submit for Review button is disabled
      final submitButtonFinder = find.byKey(
        const Key('submit_assessment_button'),
      );
      expect(submitButtonFinder, findsOneWidget);
      final submitButton = tester.widget<FilledButton>(submitButtonFinder);
      expect(
        submitButton.enabled,
        isFalse,
        reason: 'Submit button must be disabled for quarantined legacy drafts',
      );

      // 3. Tap Save Local Draft and verify metadata is preserved
      final saveButtonFinder = find.byKey(const Key('save_draft_button'));
      expect(saveButtonFinder, findsOneWidget);
      await tester.ensureVisible(saveButtonFinder);
      await tester.tap(saveButtonFinder);
      await tester.pumpAndSettle();

      final savedDraft = await fakeDraftStore.getLocalDraft(
        'legacy-draft-quarantine-test',
      );
      expect(savedDraft, isNotNull);
      expect(
        savedDraft!.dispatchState,
        equals(CommandDispatchState.unknownLegacy),
        reason: 'Saving local draft must preserve unknown_legacy dispatchState',
      );
      expect(savedDraft.retryCount, equals(2));
      expect(savedDraft.actorUserId, equals('usr-legacy-actor'));
    },
  );
}

final class _TrackingAssessmentRepository extends FakeAssessmentRepository {
  final List<String> recordedCreateCommandIds = [];
  final List<String> recordedSubmitCommandIds = [];
  bool failSubmit = false;

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
    recordedCreateCommandIds.add(commandId);
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
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
    recordedSubmitCommandIds.add(commandId);
    if (failSubmit) {
      throw Exception('Simulated network failure on submit');
    }
    return super.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
    );
  }
}

final class _FailingVerifyAssessmentRepository
    extends FakeAssessmentRepository {
  @override
  Future<Assessment> verifyAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    String? notes,
  }) async {
    throw Exception('PG_ERR_5432: internal connection dropped');
  }
}

final class _FailingSubmitAssessmentRepository
    extends FakeAssessmentRepository {
  _FailingSubmitAssessmentRepository();

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
    throw Exception(
      'SocketException: Connection refused (FATAL: 28P01: password authentication failed)',
    );
  }
}
