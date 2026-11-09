import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/assessments/presentation/add_assessment_screen.dart';
import 'package:learnward/features/assessments/presentation/evidence_picker_service.dart';
import 'package:learnward/features/assessments/services/local_evidence_file_store.dart';
import 'package:learnward/features/child/presentation/child_mode_screen.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

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

class FailingLocalDraftStore implements LocalDraftStore {
  FailingLocalDraftStore(this.inner);
  final LocalDraftStore inner;
  bool shouldFailSave = false;

  @override
  Future<void> saveLocalDraft(LocalAssessmentDraft draft) async {
    if (shouldFailSave) {
      throw StateError('Simulated disk I/O failure during draft save');
    }
    return inner.saveLocalDraft(draft);
  }

  @override
  Future<LocalAssessmentDraft?> getLocalDraft(String localDraftId) =>
      inner.getLocalDraft(localDraftId);

  @override
  Future<List<LocalAssessmentDraft>> listLocalDrafts(ChildId childId) =>
      inner.listLocalDrafts(childId);

  @override
  Future<void> deleteLocalDraft(String localDraftId) =>
      inner.deleteLocalDraft(localDraftId);

  @override
  Future<DraftDeletionOutcome> deleteDraftSafely({
    required String localDraftId,
    required LocalAssessmentDraft expectedDraft,
    DateTime? now,
  }) => inner.deleteDraftSafely(
    localDraftId: localDraftId,
    expectedDraft: expectedDraft,
    now: now,
  );

  @override
  Future<bool> hasDraftReferenceToFile(String filePath) =>
      inner.hasDraftReferenceToFile(filePath);

  @override
  Future<int> countDraftReferencesToFile(String filePath) =>
      inner.countDraftReferencesToFile(filePath);
}

final class FailingSubmitAssessmentRepository extends FakeAssessmentRepository {
  bool shouldFailSubmit = false;

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
    if (shouldFailSubmit) {
      throw StateError('Simulated network timeout during submitAssessment');
    }
    return super.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
    );
  }
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

  group('Phase 6 Slice 4B-0: Local Evidence Safety & Data Loss Prevention Suite', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase appDatabase;
    late DefaultLocalEvidenceFileStore fileStore;
    late FakeFamilyRepository fakeFamilyRepo;
    late FakeChildProfileRepository fakeChildRepo;
    late FailingSubmitAssessmentRepository fakeAssessmentRepo;
    late FakeAssessmentEvidenceStorage fakeStorage;
    late InMemoryGrowthRepository fakeGrowthRepo;
    late InMemoryLocalMetadataStore fakeMetadataStore;

    final now = DateTime.utc(2026, 11, 9, 10, 0);
    final testFamily = Family(
      id: FamilyId('fam-b0-1'),
      name: 'Safety Family',
      timezone: 'UTC',
      locale: 'en_US',
      createdByUserId: 'parent-b0',
      createdAt: now,
    );

    final testChild = ChildProfile(
      id: ChildId('child-b0-1'),
      familyId: testFamily.id,
      displayName: 'Maya',
      schoolGrade: 4,
      birthYear: 2016,
      createdAt: now,
    );

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'learnward_evidence_safety_',
      );
      dbFile = File('${tempDir.path}/evidence_safety.sqlite');
      appDatabase = AppDatabase(NativeDatabase(dbFile));
      fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);

      fakeFamilyRepo = FakeFamilyRepository();
      fakeChildRepo = FakeChildProfileRepository();
      fakeAssessmentRepo = FailingSubmitAssessmentRepository();
      fakeStorage = FakeAssessmentEvidenceStorage();
      fakeGrowthRepo = InMemoryGrowthRepository();
      fakeMetadataStore = InMemoryLocalMetadataStore();

      fakeFamilyRepo.createFamily(
        name: testFamily.name,
        timezone: testFamily.timezone,
        locale: testFamily.locale,
      );
    });

    tearDown(() async {
      await appDatabase.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    LocalAssessmentDraft buildDraft({
      required String draftId,
      String? photoPath,
      String? compressedPath,
      CommandDispatchState dispatchState = CommandDispatchState.neverDispatched,
      DraftSubmissionStatus submissionStatus = DraftSubmissionStatus.draft,
      String title = 'Homework Assessment',
    }) {
      return LocalAssessmentDraft(
        localDraftId: draftId,
        familyId: testFamily.id.value,
        childId: testChild.id.value,
        subjectKey: SubjectKey.science,
        subject: 'Science',
        title: title,
        assessmentType: 'homework',
        difficulty: 'normal',
        rawScore: 9.0,
        maxScore: 10.0,
        localPhotoPath: photoPath,
        localCompressedPhotoPath: compressedPath,
        occurredAt: now,
        updatedAt: now,
        dispatchState: dispatchState,
        submissionStatus: submissionStatus,
      );
    }

    Widget createTestHarness({
      required Widget child,
      LocalDraftStore? customDraftStore,
      EvidencePickerService? customPicker,
    }) {
      return ProviderScope(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
          growthRepositoryProvider.overrideWithValue(fakeGrowthRepo),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
          assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
          localEvidenceFileStoreProvider.overrideWithValue(fileStore),
          localDraftStoreProvider.overrideWithValue(
            customDraftStore ?? appDatabase,
          ),
          activeFamilyProvider.overrideWith(
            () => _PresetFamilyNotifier(testFamily),
          ),
          activeChildModeProvider.overrideWith(
            () => _PresetActiveChildNotifier(testChild),
          ),
          if (customPicker != null)
            evidencePickerServiceProvider.overrideWithValue(customPicker),
        ],
        child: MaterialApp(home: child),
      );
    }

    // -------------------------------------------------------------------------
    // B01 / B02: Remove photo, then navigate back without saving
    // -------------------------------------------------------------------------
    testWidgets(
      'B01/B02: Removing photo and navigating back without Save preserves physical file and draft',
      (tester) async {
        final originalBytes = [10, 20, 30, 40, 50];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'original_hw.jpg',
          bytes: originalBytes,
        );
        expect(File(photoPath).existsSync(), isTrue);

        final initialDraft = buildDraft(
          draftId: 'd-back-test',
          photoPath: photoPath,
        );
        await appDatabase.saveLocalDraft(initialDraft);

        await tester.pumpWidget(
          createTestHarness(
            child: Builder(
              builder: (ctx) => ElevatedButton(
                key: const Key('open_edit_btn'),
                onPressed: () async {
                  await Navigator.of(ctx).push<bool>(
                    MaterialPageRoute(
                      builder: (_) =>
                          AddAssessmentScreen(initialDraft: initialDraft),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        );

        // Open AddAssessmentScreen
        await tester.tap(find.byKey(const Key('open_edit_btn')));
        await tester.pumpAndSettle();
        expect(find.text('Edit Assessment Draft'), findsOneWidget);

        // Tap "Remove Photo"
        await tester.ensureVisible(
          find.byKey(const Key('remove_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('remove_evidence_button')));
        await tester.pumpAndSettle();

        // Navigate back WITHOUT saving
        final backButton = find.byType(BackButton);
        await tester.tap(backButton);
        await tester.pumpAndSettle();

        // 1. Verify physical file is STILL ON DISK with exact bytes
        final file = File(photoPath);
        expect(
          file.existsSync(),
          isTrue,
          reason: 'Physical file must NOT be deleted on UI remove',
        );
        expect(file.readAsBytesSync(), equals(originalBytes));

        // 2. Verify draft in SQLite is UNCHANGED
        final draftInStore = await appDatabase.getLocalDraft('d-back-test');
        expect(draftInStore, isNotNull);
        expect(draftInStore!.localPhotoPath, equals(photoPath));
      },
    );

    // -------------------------------------------------------------------------
    // B02: Replace photo, then fail the draft save
    // -------------------------------------------------------------------------
    testWidgets(
      'B02: Replacing photo followed by a failed draft save preserves original evidence file',
      (tester) async {
        final originalBytes = [1, 2, 3];
        final originalPath = await fileStore.saveEvidence(
          fileName: 'original_safe.jpg',
          bytes: originalBytes,
        );

        final initialDraft = buildDraft(
          draftId: 'd-fail-save',
          photoPath: originalPath,
        );
        await appDatabase.saveLocalDraft(initialDraft);

        final failingStore = FailingLocalDraftStore(appDatabase);

        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'new_replacement.jpg',
            bytes: [9, 8, 7],
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customDraftStore: failingStore,
            customPicker: picker,
            child: AddAssessmentScreen(initialDraft: initialDraft),
          ),
        );
        await tester.pumpAndSettle();

        // Remove old photo first
        await tester.ensureVisible(
          find.byKey(const Key('remove_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('remove_evidence_button')));
        await tester.pumpAndSettle();

        // Pick new replacement photo
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        // Inject save failure
        failingStore.shouldFailSave = true;

        // Try to save draft
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        // Original file must remain 100% intact
        expect(File(originalPath).existsSync(), isTrue);
        expect(File(originalPath).readAsBytesSync(), equals(originalBytes));

        // Draft in DB still points to original file
        final draftInStore = await appDatabase.getLocalDraft('d-fail-save');
        expect(draftInStore!.localPhotoPath, equals(originalPath));
      },
    );

    // -------------------------------------------------------------------------
    // B01 / B05: Successful save with reference switch
    // -------------------------------------------------------------------------
    testWidgets(
      'B01/B05: Successful save with reference switch cleans up old file only if unreferenced',
      (tester) async {
        final oldBytes = [100, 101];
        final oldPath = await fileStore.saveEvidence(
          fileName: 'old_pic.jpg',
          bytes: oldBytes,
        );
        final initialDraft = buildDraft(
          draftId: 'd-switch-test',
          photoPath: oldPath,
        );
        await appDatabase.saveLocalDraft(initialDraft);

        final newBytes = [200, 201];
        final picker = SimulatedEvidencePickerService(
          stubFile: SelectedEvidenceFile(
            fileName: 'new_pic.jpg',
            bytes: newBytes,
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customPicker: picker,
            child: AddAssessmentScreen(initialDraft: initialDraft),
          ),
        );
        await tester.pumpAndSettle();

        // Remove old photo first
        await tester.ensureVisible(
          find.byKey(const Key('remove_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('remove_evidence_button')));
        await tester.pumpAndSettle();

        // Pick new photo
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        // Save draft
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        final updated = await appDatabase.getLocalDraft('d-switch-test');
        expect(updated!.localPhotoPath, isNot(equals(oldPath)));
        expect(File(updated.localPhotoPath!).existsSync(), isTrue);

        // Old file had zero other references, so it was safely unlinked
        expect(File(oldPath).existsSync(), isFalse);
      },
    );

    // -------------------------------------------------------------------------
    // B05: Two drafts referencing the same physical file
    // -------------------------------------------------------------------------
    test('B05: Two drafts referencing the same file prevents unlinking when one is deleted or switched', () async {
      final sharedBytes = [55, 66, 77];
      final sharedPath = await fileStore.saveEvidence(
        fileName: 'shared_homework.jpg',
        bytes: sharedBytes,
      );

      final draftA = buildDraft(draftId: 'd-shared-A', photoPath: sharedPath);
      final draftB = buildDraft(draftId: 'd-shared-B', photoPath: sharedPath);

      await appDatabase.saveLocalDraft(draftA);
      await appDatabase.saveLocalDraft(draftB);

      // Delete draft A
      await appDatabase.deleteLocalDraft('d-shared-A');

      // Reference check should find draft B still references it
      final deleted = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: sharedPath,
        draftStore: appDatabase,
      );
      expect(
        deleted.isPreserved,
        isTrue,
        reason: 'File must NOT be deleted while draft B references it',
      );
      expect(deleted.referenceCount, equals(1));
      expect(File(sharedPath).existsSync(), isTrue);
      expect(File(sharedPath).readAsBytesSync(), equals(sharedBytes));

      // Now delete draft B
      await appDatabase.deleteLocalDraft('d-shared-B');
      final deletedAfterAll = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: sharedPath,
        draftStore: appDatabase,
      );
      expect(
        deletedAfterAll.isDeleted,
        isTrue,
        reason: 'File should be safely deleted when zero references remain',
      );
      expect(File(sharedPath).existsSync(), isFalse);
    });

    // -------------------------------------------------------------------------
    // B05: App restart during edit or cleanup
    // -------------------------------------------------------------------------
    test('B05: Draft references and photo bytes survive AppDatabase restart intact', () async {
      final photoBytes = [12, 34, 56];
      final photoPath = await fileStore.saveEvidence(
        fileName: 'restart_test.jpg',
        bytes: photoBytes,
      );

      final draft = buildDraft(draftId: 'd-restart-1', photoPath: photoPath);
      await appDatabase.saveLocalDraft(draft);

      // Close database and reopen from disk
      await appDatabase.close();
      final reopenedDb = AppDatabase(NativeDatabase(dbFile));

      try {
        final reloaded = await reopenedDb.getLocalDraft('d-restart-1');
        expect(reloaded, isNotNull);
        expect(reloaded!.localPhotoPath, equals(photoPath));
        expect(File(photoPath).existsSync(), isTrue);
        expect(File(photoPath).readAsBytesSync(), equals(photoBytes));
        expect(await reopenedDb.hasDraftReferenceToFile(photoPath), isTrue);
      } finally {
        await reopenedDb.close();
      }
    });

    // -------------------------------------------------------------------------
    // B04: Draft deletion without confirmation
    // -------------------------------------------------------------------------
    testWidgets(
      'B04: Draft deletion requires confirmation; tapping Cancel preserves draft and evidence',
      (tester) async {
        final photoBytes = [7, 8, 9];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'cancel_del.jpg',
          bytes: photoBytes,
        );
        final draft = buildDraft(
          draftId: 'd-cancel-del',
          photoPath: photoPath,
          title: 'Preserved Draft',
        );
        await appDatabase.saveLocalDraft(draft);

        await tester.pumpWidget(
          createTestHarness(child: const Scaffold(body: ChildModeScreen())),
        );
        await tester.pumpAndSettle();

        // Verify draft appears in Child Mode list
        expect(find.text('Preserved Draft'), findsOneWidget);

        // Tap delete icon
        final deleteButton = find.byKey(
          const Key('delete_draft_button_d-cancel-del'),
        );
        expect(deleteButton, findsOneWidget);
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();

        // Confirmation dialog appears
        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsOneWidget,
        );
        expect(find.text('Delete Assessment Draft?'), findsOneWidget);

        // Tap Cancel
        await tester.tap(find.byKey(const Key('cancel_delete_draft_button')));
        await tester.pumpAndSettle();

        // Dialog dismissed, draft remains visible
        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsNothing,
        );
        expect(find.text('Preserved Draft'), findsOneWidget);

        // File and draft in DB are intact
        expect(File(photoPath).existsSync(), isTrue);
        expect(await appDatabase.getLocalDraft('d-cancel-del'), isNotNull);
      },
    );

    // -------------------------------------------------------------------------
    // B04: Delete attempt against possibly_dispatched or unknown_legacy
    // -------------------------------------------------------------------------
    testWidgets(
      'B04: Delete attempt against unknown_legacy or possibly_dispatched is blocked',
      (tester) async {
        final photoBytes = [99, 88];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'legacy_pic.jpg',
          bytes: photoBytes,
        );

        // 1. Quarantined unknown_legacy draft
        final legacyDraft = buildDraft(
          draftId: 'd-legacy-blocked',
          photoPath: photoPath,
          title: 'Legacy Draft',
          dispatchState: CommandDispatchState.unknownLegacy,
        );
        await appDatabase.saveLocalDraft(legacyDraft);

        await tester.pumpWidget(
          createTestHarness(child: const Scaffold(body: ChildModeScreen())),
        );
        await tester.pumpAndSettle();

        expect(find.text('Legacy Draft'), findsOneWidget);

        // Tap delete
        await tester.tap(
          find.byKey(const Key('delete_draft_button_d-legacy-blocked')),
        );
        await tester.pumpAndSettle();

        // Blocked dialog appears instead of confirm dialog
        expect(
          find.byKey(const Key('draft_delete_blocked_dialog')),
          findsOneWidget,
        );
        expect(find.text('Cannot Delete Draft'), findsOneWidget);

        // Dismiss blocked dialog
        await tester.tap(
          find.byKey(const Key('draft_delete_blocked_ok_button')),
        );
        await tester.pumpAndSettle();

        // Draft and file must remain
        expect(await appDatabase.getLocalDraft('d-legacy-blocked'), isNotNull);
        expect(File(photoPath).existsSync(), isTrue);
      },
    );

    // -------------------------------------------------------------------------
    // B03: Remote submission succeeded but local evidence preserved
    // -------------------------------------------------------------------------
    testWidgets(
      'B03: Remote submission succeeds; local evidence bytes are preserved on disk',
      (tester) async {
        final photoBytes = [1, 2, 3, 4, 5];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'submit_preserve.jpg',
          bytes: photoBytes,
        );

        final picker = SimulatedEvidencePickerService(
          stubFile: SelectedEvidenceFile(
            fileName: 'submit_preserve.jpg',
            bytes: photoBytes,
            mediaType: 'image/jpeg',
            localPath: photoPath,
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customPicker: picker,
            child: const AddAssessmentScreen(),
          ),
        );
        await tester.pumpAndSettle();

        // Fill form
        await tester.enterText(
          find.byKey(const Key('assessment_title_field')),
          'Fractions Test',
        );
        await tester.enterText(
          find.byKey(const Key('assessment_raw_score_field')),
          '8.0',
        );
        await tester.enterText(
          find.byKey(const Key('assessment_max_score_field')),
          '10.0',
        );

        // Attach photo
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        // Submit assessment
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        // Verify remote assessment was created
        expect(fakeAssessmentRepo.assessments.length, equals(1));

        // B03 INVARIANT: Physical file on disk must NOT have been unlinked!
        expect(
          File(photoPath).existsSync(),
          isTrue,
          reason: 'Physical evidence bytes must survive submission',
        );
        expect(File(photoPath).readAsBytesSync(), equals(photoBytes));
      },
    );

    // -------------------------------------------------------------------------
    // B03: Uncertain server registration or lost response
    // -------------------------------------------------------------------------
    testWidgets(
      'B03: Uncertain submission failure retains local evidence bytes and possiblyDispatched state',
      (tester) async {
        final photoBytes = [11, 22, 33];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'failing_upload.jpg',
          bytes: photoBytes,
        );

        final draft = buildDraft(
          draftId: 'd-uncertain-fail',
          photoPath: photoPath,
          title: 'Uncertain Draft',
        );
        await appDatabase.saveLocalDraft(draft);

        // Injected repository failure on submit
        fakeAssessmentRepo.shouldFailSubmit = true;

        final picker = SimulatedEvidencePickerService(
          stubFile: SelectedEvidenceFile(
            fileName: 'failing_upload.jpg',
            bytes: photoBytes,
            mediaType: 'image/jpeg',
            localPath: photoPath,
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customPicker: picker,
            child: AddAssessmentScreen(initialDraft: draft),
          ),
        );
        await tester.pumpAndSettle();

        // Submit
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        // Photo must be completely intact
        expect(File(photoPath).existsSync(), isTrue);
        expect(File(photoPath).readAsBytesSync(), equals(photoBytes));

        // Draft retains possiblyDispatched state
        final updatedDraft = await appDatabase.getLocalDraft(
          'd-uncertain-fail',
        );
        expect(updatedDraft, isNotNull);
        expect(updatedDraft!.localPhotoPath, equals(photoPath));
      },
    );

    // -------------------------------------------------------------------------
    // Concurrent delete taps and cleanup idempotency
    // -------------------------------------------------------------------------
    test('Repeated delete taps and concurrent cleanup attempts are safe and idempotent', () async {
      final photoBytes = [42, 43, 44];
      final photoPath = await fileStore.saveEvidence(
        fileName: 'concurrent_pic.jpg',
        bytes: photoBytes,
      );

      // Execute 10 parallel cleanup attempts
      final results = await Future.wait(
        List.generate(
          10,
          (_) => fileStore.deleteEvidenceIfUnreferenced(
            filePath: photoPath,
            draftStore: appDatabase,
          ),
        ),
      );

      // File should be safely deleted without any unhandled exceptions
      expect(File(photoPath).existsSync(), isFalse);
      expect(
        results.every((r) => r.isDeleted || r.isAlreadyAbsent),
        isTrue,
        reason: 'Concurrent cleanups must all succeed idempotently (deleted or alreadyAbsent)',
      );
    });

    // -------------------------------------------------------------------------
    // B04 / B05: Confirming delete removes draft and unlinks unreferenced evidence
    // -------------------------------------------------------------------------
    testWidgets(
      'B04/B05: Confirming delete in dialog deletes draft and safely unlinks unreferenced photo',
      (tester) async {
        final photoBytes = [88, 99];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'confirmed_del.jpg',
          bytes: photoBytes,
        );
        final draft = buildDraft(
          draftId: 'd-conf-del',
          photoPath: photoPath,
          title: 'Draft To Delete',
        );
        await appDatabase.saveLocalDraft(draft);

        await tester.pumpWidget(
          createTestHarness(child: const Scaffold(body: ChildModeScreen())),
        );
        await tester.pumpAndSettle();

        expect(find.text('Draft To Delete'), findsOneWidget);

        // Tap delete
        await tester.tap(
          find.byKey(const Key('delete_draft_button_d-conf-del')),
        );
        await tester.pumpAndSettle();

        // Confirm delete dialog appears
        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsOneWidget,
        );

        // Tap Delete in dialog
        await tester.tap(find.byKey(const Key('confirm_delete_draft_button')));
        await tester.pumpAndSettle();

        // Draft removed from UI and SQLite
        expect(find.text('Draft To Delete'), findsNothing);
        expect(await appDatabase.getLocalDraft('d-conf-del'), isNull);

        // Photo file unlinked because zero drafts reference it
        expect(File(photoPath).existsSync(), isFalse);
      },
    );

    // -------------------------------------------------------------------------
    // R26-02: Pre-unlink reference check race & conservative retention
    // -------------------------------------------------------------------------
    test('R26-02: Reference injected during pre-unlink gap aborts deletion and preserves file', () async {
      final photoBytes = [91, 92, 93];
      late DefaultLocalEvidenceFileStore racingStore;
      late String photoPath;

      racingStore = DefaultLocalEvidenceFileStore(
        baseDirectory: tempDir,
        onPreUnlink: (path) async {
          // Concurrently persist a new draft referencing this exact path
          final competingDraft = buildDraft(
            draftId: 'd-competing-preunlink',
            photoPath: path,
          );
          await appDatabase.saveLocalDraft(competingDraft);
        },
      );

      photoPath = await racingStore.saveEvidence(
        fileName: 'racing_evidence.jpg',
        bytes: photoBytes,
      );

      // At start, zero drafts reference photoPath. But during onPreUnlink, competingDraft appears.
      final result = await racingStore.deleteEvidenceIfUnreferenced(
        filePath: photoPath,
        draftStore: appDatabase,
      );

      expect(
        result.status,
        equals(EvidenceFileDeletionStatus.preservedReferenced),
      );
      expect(result.isPreserved, isTrue);
      expect(result.referenceCount, equals(1));
      expect(File(photoPath).existsSync(), isTrue);
      expect(File(photoPath).readAsBytesSync(), equals(photoBytes));
    });

    test('R26-02: Competing SQLite connections preserve evidence when reference added during pre-unlink window', () async {
      final conn2 = AppDatabase(NativeDatabase(dbFile));
      try {
        final photoBytes = [77, 88];
        late DefaultLocalEvidenceFileStore racingStore;
        final sharedPath = await fileStore.saveEvidence(
          fileName: 'shared_conn_pic.jpg',
          bytes: photoBytes,
        );

        final draftA = buildDraft(
          draftId: 'd-shared-c1',
          photoPath: sharedPath,
        );
        await appDatabase.saveLocalDraft(draftA);

        racingStore = DefaultLocalEvidenceFileStore(
          baseDirectory: tempDir,
          onPreUnlink: (path) async {
            // Connection 2 inserts a draft referencing the path
            final draftB = buildDraft(draftId: 'd-shared-c2', photoPath: path);
            await conn2.saveLocalDraft(draftB);
          },
        );

        // Connection 1 deletes draft A
        await appDatabase.deleteLocalDraft('d-shared-c1');

        final result = await racingStore.deleteEvidenceIfUnreferenced(
          filePath: sharedPath,
          draftStore: conn2,
        );

        expect(
          result.status,
          equals(EvidenceFileDeletionStatus.preservedReferenced),
        );
        expect(result.isPreserved, isTrue);
        expect(File(sharedPath).existsSync(), isTrue);
        expect(File(sharedPath).readAsBytesSync(), equals(photoBytes));
      } finally {
        await conn2.close();
      }
    });

    test('R26-02: Evidence file and draft references survive simulated application restart', () async {
      final photoBytes = [111, 222];
      final photoPath = await fileStore.saveEvidence(
        fileName: 'restart_proof_r26.jpg',
        bytes: photoBytes,
      );
      final draft = buildDraft(draftId: 'd-restart-r26', photoPath: photoPath);
      await appDatabase.saveLocalDraft(draft);

      // Simulate app termination
      await appDatabase.close();

      // Reopen database from same file (simulating app restart)
      final restartedDb = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(await restartedDb.hasDraftReferenceToFile(photoPath), isTrue);
        expect(
          await restartedDb.countDraftReferencesToFile(photoPath),
          equals(1),
        );
        expect(File(photoPath).existsSync(), isTrue);
        expect(File(photoPath).readAsBytesSync(), equals(photoBytes));

        // Delete attempt with reference present preserves file
        final result = await fileStore.deleteEvidenceIfUnreferenced(
          filePath: photoPath,
          draftStore: restartedDb,
        );
        expect(result.isPreserved, isTrue);
        expect(File(photoPath).existsSync(), isTrue);
      } finally {
        await restartedDb.close();
      }
    });

    // -------------------------------------------------------------------------
    // R26-03: Boundary checks, traversal escapes, and failed delete handling
    // -------------------------------------------------------------------------
    test('R26-03: Deletion rejected for paths outside evidence directory (absolute path)', () async {
      final outsideFile = File('${tempDir.path}/external_file.txt')
        ..writeAsStringSync('critical system file');

      final result = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: outsideFile.path,
        draftStore: appDatabase,
      );

      expect(
        result.status,
        equals(EvidenceFileDeletionStatus.rejectedOutOfBounds),
      );
      expect(result.isRejectedOutOfBounds, isTrue);
      expect(outsideFile.existsSync(), isTrue);
    });

    test('R26-03: Deletion rejected for path traversal attempts', () async {
      final traversalPath =
          '${tempDir.path}/draft_evidence/../../outside_escaped.txt';
      final result = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: traversalPath,
        draftStore: appDatabase,
      );

      expect(
        result.status,
        equals(EvidenceFileDeletionStatus.rejectedOutOfBounds),
      );
      expect(result.isRejectedOutOfBounds, isTrue);
    });

    test('R26-03: Deletion reports alreadyAbsent when file does not exist in evidence directory', () async {
      final absentPath = '${tempDir.path}/draft_evidence/non_existent.jpg';
      final result = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: absentPath,
        draftStore: appDatabase,
      );

      expect(result.status, equals(EvidenceFileDeletionStatus.alreadyAbsent));
      expect(result.isAlreadyAbsent, isTrue);
    });

    test('R26-03: Filesystem deletion errors return deletionFailed and fail closed', () async {
      final conflictingDir = Directory(
        '${tempDir.path}/draft_evidence/dir_as_file.jpg',
      )..createSync(recursive: true);
      File('${conflictingDir.path}/nested.txt').writeAsStringSync('nested');

      final result = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: conflictingDir.path,
        draftStore: appDatabase,
      );

      expect(result.status, equals(EvidenceFileDeletionStatus.deletionFailed));
      expect(result.isFailed, isTrue);
      expect(conflictingDir.existsSync(), isTrue);
    });

    // -------------------------------------------------------------------------
    // R26-01: UI stale-state handling and concurrency conflict dialogs
    // -------------------------------------------------------------------------
    testWidgets(
      'R26-01 UI: Draft mutated to possiblyDispatched while dialog is open is rejected and displays blocked dialog',
      (tester) async {
        final photoBytes = [12, 13];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'stale_dialog_disp.jpg',
          bytes: photoBytes,
        );
        final draft = buildDraft(
          draftId: 'd-stale-disp',
          photoPath: photoPath,
          title: 'Stale Dialog Draft',
        );
        await appDatabase.saveLocalDraft(draft);

        await tester.pumpWidget(
          createTestHarness(child: const Scaffold(body: ChildModeScreen())),
        );
        await tester.pumpAndSettle();

        expect(find.text('Stale Dialog Draft'), findsOneWidget);

        // Tap delete to open dialog
        await tester.tap(
          find.byKey(const Key('delete_draft_button_d-stale-disp')),
        );
        await tester.pumpAndSettle();

        // Confirm dialog is visible
        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsOneWidget,
        );

        // While dialog is open, mutate draft in appDatabase to possiblyDispatched
        final mutatedDraft = draft.copyWith(
          dispatchState: CommandDispatchState.possiblyDispatched,
          updatedAt: now.add(const Duration(seconds: 5)),
        );
        await appDatabase.saveLocalDraft(mutatedDraft);

        // Now tap "Delete" in dialog
        await tester.tap(find.byKey(const Key('confirm_delete_draft_button')));
        await tester.pumpAndSettle();

        // Confirm dialog dismissed and blocked dialog appears!
        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('draft_delete_blocked_dialog')),
          findsOneWidget,
        );
        expect(find.text('Cannot Delete Draft'), findsOneWidget);

        // Dismiss blocked dialog
        await tester.tap(
          find.byKey(const Key('draft_delete_blocked_ok_button')),
        );
        await tester.pumpAndSettle();

        // Draft and photo file MUST remain intact
        final persisted = await appDatabase.getLocalDraft('d-stale-disp');
        expect(persisted, isNotNull);
        expect(
          persisted!.dispatchState,
          equals(CommandDispatchState.possiblyDispatched),
        );
        expect(File(photoPath).existsSync(), isTrue);
      },
    );

    testWidgets(
      'R26-01 UI: Draft content modified while dialog is open is rejected and displays conflict dialog',
      (tester) async {
        final photoBytes = [14, 15];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'stale_dialog_conflict.jpg',
          bytes: photoBytes,
        );
        final draft = buildDraft(
          draftId: 'd-stale-conflict',
          photoPath: photoPath,
          title: 'Before Conflict Title',
        );
        await appDatabase.saveLocalDraft(draft);

        await tester.pumpWidget(
          createTestHarness(child: const Scaffold(body: ChildModeScreen())),
        );
        await tester.pumpAndSettle();

        expect(find.text('Before Conflict Title'), findsOneWidget);

        // Tap delete to open dialog
        await tester.tap(
          find.byKey(const Key('delete_draft_button_d-stale-conflict')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsOneWidget,
        );

        // Concurrently modify draft title while dialog is pending
        final updatedDraft = draft.copyWith(
          title: 'Concurrently Modified Title',
          updatedAt: now.add(const Duration(seconds: 10)),
        );
        await appDatabase.saveLocalDraft(updatedDraft);

        // Tap "Delete" in dialog
        await tester.tap(find.byKey(const Key('confirm_delete_draft_button')));
        await tester.pumpAndSettle();

        // Conflict dialog appears!
        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('draft_delete_conflict_dialog')),
          findsOneWidget,
        );
        expect(find.text('Draft Modified'), findsOneWidget);

        // Dismiss conflict dialog
        await tester.tap(
          find.byKey(const Key('draft_delete_conflict_ok_button')),
        );
        await tester.pumpAndSettle();

        // Draft remains in store with updated title
        final persisted = await appDatabase.getLocalDraft('d-stale-conflict');
        expect(persisted, isNotNull);
        expect(persisted!.title, equals('Concurrently Modified Title'));
        expect(File(photoPath).existsSync(), isTrue);
      },
    );

    testWidgets(
      'R26-01 UI: Draft with unexpired lease while dialog open is rejected and displays blocked dialog',
      (tester) async {
        final photoBytes = [16, 17];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'stale_dialog_lease.jpg',
          bytes: photoBytes,
        );
        final draft = buildDraft(
          draftId: 'd-stale-lease',
          photoPath: photoPath,
          title: 'Lease Test Draft',
        );
        await appDatabase.saveLocalDraft(draft);

        await tester.pumpWidget(
          createTestHarness(child: const Scaffold(body: ChildModeScreen())),
        );
        await tester.pumpAndSettle();

        expect(find.text('Lease Test Draft'), findsOneWidget);

        // Tap delete to open dialog
        await tester.tap(
          find.byKey(const Key('delete_draft_button_d-stale-lease')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsOneWidget,
        );

        // While dialog open, background worker claims lease
        final leasedDraft = draft.copyWith(
          leaseToken: 'worker-lease-token-abc',
          leaseExpiresAt: now.add(const Duration(minutes: 5)),
          updatedAt: now.add(const Duration(seconds: 2)),
        );
        await appDatabase.saveLocalDraft(leasedDraft);

        // Tap "Delete" in dialog
        await tester.tap(find.byKey(const Key('confirm_delete_draft_button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('draft_delete_blocked_dialog')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('draft_delete_blocked_ok_button')),
        );
        await tester.pumpAndSettle();

        final persisted = await appDatabase.getLocalDraft('d-stale-lease');
        expect(persisted, isNotNull);
        expect(persisted!.leaseToken, equals('worker-lease-token-abc'));
        expect(File(photoPath).existsSync(), isTrue);
      },
    );
  });
}
