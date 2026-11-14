import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
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
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:sqlite3/sqlite3.dart';

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
    // Under Slice 4B-0 conservative evidence retention policy, physical unlinking is disabled.
  }

  @override
  Future<void> deleteEvidence(String filePath) =>
      deleteDurableEvidence(filePath);

  @override
  Future<CanonicalEvidenceSnapshot> saveCanonicalEvidenceSnapshot({
    required String localDraftId,
    required List<int> bytes,
  }) async {
    final inspected = inspectAndValidateEvidenceBytes(bytes);
    final path =
        '/mock/evidence/${localDraftId}_canonical.${inspected.fileExtension}';
    files[path] = inspected.bytes;
    return CanonicalEvidenceSnapshot(
      localDraftId: localDraftId,
      filePath: path,
      mediaType: inspected.mediaType,
      fileExtension: inspected.fileExtension,
      byteLength: inspected.byteLength,
      sha256Checksum: inspected.sha256Checksum,
      frozenAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<VerifiedCanonicalEvidence> verifyCanonicalEvidenceSnapshot({
    required String localDraftId,
    required String canonicalFilePath,
    required String expectedSha256,
    int? expectedByteLength,
    String? expectedMediaType,
    DateTime? frozenAt,
  }) async {
    final raw = files[canonicalFilePath];
    if (raw == null) {
      throw EvidenceStorageException(
        'Canonical evidence snapshot is missing.',
        kind: EvidenceStorageFailureKind.missingSnapshot,
      );
    }
    final verified = verifyCanonicalEvidenceBytes(
      bytes: raw,
      expectedSha256: expectedSha256,
      expectedByteLength: expectedByteLength,
      expectedMediaType: expectedMediaType,
    );
    return VerifiedCanonicalEvidence(
      snapshot: CanonicalEvidenceSnapshot(
        localDraftId: localDraftId,
        filePath: canonicalFilePath,
        mediaType: verified.mediaType,
        fileExtension: verified.fileExtension,
        byteLength: verified.byteLength,
        sha256Checksum: verified.sha256Checksum,
        frozenAt: frozenAt ?? DateTime.now().toUtc(),
      ),
      bytes: verified.bytes,
    );
  }

  @override
  Future<VerifiedCanonicalEvidence> readVerifiedCanonicalSnapshot({
    required LocalAssessmentDraft draft,
  }) async {
    final canonicalPath = draft.localCompressedPhotoPath;
    final expectedSha256 = draft.sha256Checksum;
    if (canonicalPath == null ||
        canonicalPath.isEmpty ||
        expectedSha256 == null) {
      throw const EvidenceStorageException(
        'Draft has no frozen canonical evidence snapshot.',
        kind: EvidenceStorageFailureKind.missingSnapshot,
      );
    }
    return verifyCanonicalEvidenceSnapshot(
      localDraftId: draft.localDraftId,
      canonicalFilePath: canonicalPath,
      expectedSha256: expectedSha256,
      frozenAt: draft.updatedAt,
    );
  }

  @override
  Future<EvidenceFileDeletionResult> deleteEvidenceIfUnreferenced({
    required String filePath,
    required LocalDraftStore draftStore,
  }) async {
    final count = await draftStore.countDraftReferencesToFile(filePath);
    if (count > 0) {
      return EvidenceFileDeletionResult(
        status: EvidenceFileDeletionStatus.preservedReferenced,
        filePath: filePath,
        referenceCount: count,
      );
    }
    return EvidenceFileDeletionResult(
      status: EvidenceFileDeletionStatus.preservedConservative,
      filePath: filePath,
      reason: 'Preserved under Slice 4B-0 conservative retention.',
    );
  }
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

void _ensureSqliteInitialized() {
  if (Platform.isWindows) {
    try {
      DynamicLibrary.open('sqlite3.dll');
    } catch (_) {
      final candidates = [
        File('.dart_tool/lib/sqlite3.dll'),
        File('../../.dart_tool/lib/sqlite3.dll'),
        File('../.dart_tool/lib/sqlite3.dll'),
      ];
      for (final file in candidates) {
        if (file.existsSync()) {
          try {
            DynamicLibrary.open(file.absolute.path);
            break;
          } catch (_) {}
        }
      }
    }
  } else if (Platform.isLinux) {
    try {
      DynamicLibrary.open('libsqlite3.so');
    } catch (_) {
      try {
        DynamicLibrary.open('libsqlite3.so.0');
      } catch (_) {}
    }
  }
}

void main() {
  setUpAll(() {
    _ensureSqliteInitialized();
  });

  late FakeFamilyRepository fakeFamilyRepo;
  late FakeChildProfileRepository fakeChildRepo;
  late FakeAssessmentRepository fakeAssessmentRepo;
  late FakeAuthSessionPort fakeAuth;
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
    fakeAuth = FakeAuthSessionPort(
      activeUserId: 'local-parent-user',
      sessionGeneration: 'demo-generation-1',
    );
    fakeAssessmentRepo = FakeAssessmentRepository(
      activeActorIdProvider: () => fakeAuth.currentContext?.userId,
    );
    fakeStorage = FakeAssessmentEvidenceStorage(authSessionPort: fakeAuth);
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
                  bytes: [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3],
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
      actorUserId: 'local-parent-user',
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

    // Returns to Child Mode screen, local draft is transitioned to confirmedCommitted and excluded from unsubmitted list
    expect(find.text('Hi, Lucas!'), findsOneWidget);
    expect(find.text('Unsubmitted Local Drafts (1)'), findsNothing);
    final persistedAfterSubmit = await fakeDraftStore.getLocalDraft(
      'draft-offline-123',
    );
    expect(persistedAfterSubmit, isNotNull);
    expect(
      persistedAfterSubmit!.dispatchState,
      equals(CommandDispatchState.confirmedCommitted),
    );
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
      final trackingRepo = _TrackingAssessmentRepository(
        activeActorIdProvider: () => fakeAuth.currentContext?.userId,
      );

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

      // INVARIANT: retry skips already-persisted createDraft step and reuses
      // the exact same create/submit command IDs
      expect(trackingRepo.recordedCreateCommandIds, equals([firstCreateCmd]));
      expect(trackingRepo.recordedSubmitCommandIds.length, equals(2));
      expect(trackingRepo.recordedSubmitCommandIds[1], equals(firstSubmitCmd));

      // Submission succeeded: draft transitioned to confirmed_committed tombstone (I14)
      // and is excluded from unsubmitted drafts in Child Mode
      final remainingDrafts = await fakeDraftStore.listLocalDrafts(
        testChild.id,
      );
      expect(remainingDrafts.length, equals(1));
      expect(remainingDrafts.first.createCommandId, equals(firstCreateCmd));
      expect(remainingDrafts.first.submitCommandId, equals(firstSubmitCmd));
      expect(
        remainingDrafts.first.dispatchState,
        equals(CommandDispatchState.confirmedCommitted),
      );
      expect(remainingDrafts.first.serverAssessmentId, isNotNull);
      expect(remainingDrafts.first.leaseToken, isNull);
      expect(find.text('Unsubmitted Local Drafts (1)'), findsNothing);
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
      await fakeDraftStore.saveLocalDraft(legacyDraft);

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

      // 3. Save Local Draft is also locked (R33-09) and metadata remains preserved
      final saveButtonFinder = find.byKey(const Key('save_draft_button'));
      expect(saveButtonFinder, findsOneWidget);
      final saveButton = tester.widget<OutlinedButton>(saveButtonFinder);
      expect(
        saveButton.enabled,
        isFalse,
        reason: 'Save button must be disabled for quarantined legacy drafts',
      );
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

  testWidgets(
    'Fresh draft timeout -> Save Local Draft fails closed (R33-03) and preserves possibly_dispatched, content, and command IDs',
    (tester) async {
      final failingSubmitRepo = _FailingSubmitAssessmentRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(failingSubmitRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            localEvidenceFileStoreProvider.overrideWithValue(
              fakeEvidenceFileStore,
            ),
            localDraftStoreProvider.overrideWithValue(fakeDraftStore),
            currentUserIdProvider.overrideWithValue('usr-child-1'),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetActiveChildNotifier(testChild),
            ),
          ],
          child: const MaterialApp(home: AddAssessmentScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Enter assessment details
      await tester.enterText(
        find.byKey(const Key('assessment_raw_score_field')),
        '9.0',
      );
      await tester.enterText(
        find.byKey(const Key('assessment_title_field')),
        'Fresh Quiz Before Drop',
      );
      await tester.pumpAndSettle();

      // 2. Submit -> fails with network error
      final submitFinder = find.byKey(const Key('submit_assessment_button'));
      await tester.ensureVisible(submitFinder);
      await tester.tap(submitFinder);
      await tester.pumpAndSettle();

      // Verify draft in store is marked possibly_dispatched with stable command IDs
      final draftsAfterDrop = await fakeDraftStore.listLocalDrafts(
        testChild.id,
      );
      expect(draftsAfterDrop.length, equals(1));
      final draftAfterDrop = draftsAfterDrop.first;
      expect(
        draftAfterDrop.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );
      expect(draftAfterDrop.createCommandId, isNotNull);
      expect(draftAfterDrop.submitCommandId, isNotNull);
      final originalCreateCmdId = draftAfterDrop.createCommandId;
      final originalSubmitCmdId = draftAfterDrop.submitCommandId;

      // 3. User is still on screen after network drop; user edits title and taps Save Local Draft
      await tester.enterText(
        find.byKey(const Key('assessment_title_field')),
        'Fresh Quiz After Save',
      );
      final saveFinder = find.byKey(const Key('save_draft_button'));
      await tester.ensureVisible(saveFinder);
      await tester.tap(saveFinder);
      await tester.pumpAndSettle();

      // 4. Verify draft in store NEVER regressed to never_dispatched and original content/command IDs remain immutable
      final draftsAfterSave = await fakeDraftStore.listLocalDrafts(
        testChild.id,
      );
      expect(draftsAfterSave.length, equals(1));
      final draftAfterSave = draftsAfterSave.first;
      expect(
        draftAfterSave.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
        reason: 'possibly_dispatched must NOT roll back to never_dispatched when saving locally',
      );
      expect(
        draftAfterSave.createCommandId,
        equals(originalCreateCmdId),
        reason: 'createCommandId must be preserved',
      );
      expect(
        draftAfterSave.submitCommandId,
        equals(originalSubmitCmdId),
        reason: 'submitCommandId must be preserved',
      );
      expect(draftAfterSave.title, equals('Fresh Quiz Before Drop'));
    },
  );

  testWidgets(
    'Migrated v4 unknown_legacy draft preserves NULL command and actor identities after edit and save in AddAssessmentScreen',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync(
        'learnward_v4_legacy_provenance_',
      );
      final dbFile = File('${tempDir.path}/legacy_draft_test.sqlite');

      // 1. Create a populated SQLite v4 database on disk with NULL command IDs and NULL actor
      final rawDb = sqlite3.open(dbFile.path);
      try {
        rawDb.execute('PRAGMA user_version = 4;');
        rawDb.execute('''
          CREATE TABLE "local_metadata_entries" (
            "key" TEXT NOT NULL PRIMARY KEY,
            "value" TEXT NOT NULL,
            "updated_at" INTEGER NOT NULL
          );
        ''');
        rawDb.execute('''
          CREATE TABLE "local_assessment_drafts" (
            "local_draft_id" TEXT NOT NULL PRIMARY KEY,
            "family_id" TEXT NOT NULL,
            "child_id" TEXT NOT NULL,
            "create_command_id" TEXT,
            "submit_command_id" TEXT,
            "evidence_id" TEXT,
            "server_assessment_id" TEXT,
            "subject_key" TEXT NOT NULL DEFAULT 'math',
            "subject" TEXT NOT NULL,
            "title" TEXT NOT NULL,
            "assessment_type" TEXT NOT NULL,
            "difficulty" TEXT NOT NULL,
            "raw_score" REAL NOT NULL,
            "max_score" REAL NOT NULL,
            "local_photo_path" TEXT,
            "entry_context" TEXT NOT NULL DEFAULT 'shared_child',
            "occurred_at" INTEGER NOT NULL,
            "updated_at" INTEGER NOT NULL
          );
        ''');
        rawDb.execute('''
          CREATE TABLE "pending_reward_commands" (
            "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            "operation" TEXT NOT NULL,
            "command_id" TEXT NOT NULL UNIQUE,
            "family_id" TEXT NOT NULL,
            "child_id" TEXT,
            "reward_id" TEXT,
            "redemption_id" TEXT,
            "cancellation_reason" TEXT,
            "created_at" INTEGER NOT NULL
          );
        ''');
        rawDb.execute('''
          INSERT INTO "local_assessment_drafts" (
            "local_draft_id", "family_id", "child_id",
            "create_command_id", "submit_command_id", "evidence_id", "server_assessment_id",
            "subject_key", "subject", "title", "assessment_type", "difficulty",
            "raw_score", "max_score", "local_photo_path", "entry_context",
            "occurred_at", "updated_at"
          ) VALUES (
            'draft-v4-migrated-fixture-001', 'fam-test-1', 'child-test-1',
            NULL, NULL, 'ev-legacy-fixture-123', 'srv-legacy-fixture-456',
            'science', 'Physics', 'Original V4 Physics Lab Title', 'quiz', 'hard',
            9.0, 10.0, '/data/user/0/com.learnward/cache/photo_offline.jpg', 'shared_child',
            1730000000000, 1730000000000
          );
        ''');
      } finally {
        rawDb.close();
      }

      // 2. Open with Drift AppDatabase, triggering v4 -> v5 migration
      final appDb = AppDatabase(NativeDatabase(dbFile));
      final migratedDraft = await appDb.getLocalDraft(
        'draft-v4-migrated-fixture-001',
      );
      expect(migratedDraft, isNotNull);
      expect(migratedDraft!.createCommandId, isNull);
      expect(migratedDraft.submitCommandId, isNull);
      expect(migratedDraft.actorUserId, isNull);
      expect(
        migratedDraft.dispatchState,
        equals(CommandDispatchState.unknownLegacy),
      );
      expect(migratedDraft.canAutoSubmit, isFalse);

      final trackingRepo = _TrackingAssessmentRepository(
        activeActorIdProvider: () => fakeAuth.currentContext?.userId,
      );
      fakeEvidenceFileStore
          .files['/data/user/0/com.learnward/cache/photo_offline.jpg'] = [
        1,
        2,
        3,
      ];

      // 3. Open in AddAssessmentScreen under a DIFFERENT signed-in adult
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
            localDraftStoreProvider.overrideWithValue(appDb),
            currentUserIdProvider.overrideWithValue(
              'different-signed-in-adult-999',
            ),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetActiveChildNotifier(testChild),
            ),
          ],
          child: MaterialApp(
            home: AddAssessmentScreen(initialDraft: migratedDraft),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 4. Verify quarantine banner is displayed and submit is disabled
      expect(
        find.byKey(const Key('legacy_draft_quarantine_banner')),
        findsOneWidget,
      );
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

      // 5. Edit title and tap Save Local Draft
      await tester.enterText(
        find.byKey(const Key('assessment_title_field')),
        'Edited V4 Physics Lab Title',
      );
      await tester.pumpAndSettle();

      final saveButtonFinder = find.byKey(const Key('save_draft_button'));
      await tester.ensureVisible(saveButtonFinder);
      await tester.tap(saveButtonFinder);
      await tester.pumpAndSettle();

      // 6. Close database and reopen to verify on-disk durability
      await appDb.close();

      final reopenedDb = AppDatabase(NativeDatabase(dbFile));
      try {
        final persisted = await reopenedDb.getLocalDraft(
          'draft-v4-migrated-fixture-001',
        );
        expect(persisted, isNotNull);
        expect(
          persisted!.createCommandId,
          isNull,
          reason: 'Legacy draft must preserve NULL createCommandId on disk',
        );
        expect(
          persisted.submitCommandId,
          isNull,
          reason: 'Legacy draft must preserve NULL submitCommandId on disk',
        );
        expect(
          persisted.actorUserId,
          isNull,
          reason: 'Legacy draft must NOT backfill actorUserId with different current user identity',
        );
        expect(
          persisted.dispatchState,
          equals(CommandDispatchState.unknownLegacy),
          reason: 'Legacy draft must remain in unknown_legacy dispatchState',
        );
        expect(
          persisted.canAutoSubmit,
          isFalse,
          reason: 'Legacy draft must remain non-submittable (quarantined)',
        );
        expect(persisted.title, equals('Original V4 Physics Lab Title'));
        expect(
          persisted.evidenceId,
          equals('ev-legacy-fixture-123'),
          reason: 'Legacy evidenceId must be preserved',
        );
        expect(
          persisted.serverAssessmentId,
          equals('srv-legacy-fixture-456'),
          reason: 'Legacy serverAssessmentId must be preserved',
        );
        expect(
          persisted.localPhotoPath,
          equals('/data/user/0/com.learnward/cache/photo_offline.jpg'),
          reason: 'Legacy localPhotoPath must be preserved',
        );
        expect(
          trackingRepo.recordedCreateCommandIds,
          isEmpty,
          reason: 'No create RPC commands must be dispatched on local save',
        );
        expect(
          trackingRepo.recordedSubmitCommandIds,
          isEmpty,
          reason: 'No submit RPC commands must be dispatched on local save',
        );
      } finally {
        await reopenedDb.close();
        if (tempDir.existsSync()) {
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    },
  );
}

final class _TrackingAssessmentRepository extends FakeAssessmentRepository {
  _TrackingAssessmentRepository({super.activeActorIdProvider});
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
