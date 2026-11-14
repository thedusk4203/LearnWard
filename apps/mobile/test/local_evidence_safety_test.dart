import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
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

  @override
  Future<DraftCasResult> registerOrUpdateDraftIfUnchanged({
    required LocalAssessmentDraft? expected,
    required LocalAssessmentDraft desired,
    DateTime? now,
  }) => inner.registerOrUpdateDraftIfUnchanged(
    expected: expected,
    desired: desired,
    now: now,
  );

  @override
  Future<DraftCasResult> acquireDraftClaim({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    DateTime? now,
    String? overrideLeaseToken,
  }) => inner.acquireDraftClaim(
    localDraftId: localDraftId,
    actorUserId: actorUserId,
    familyId: familyId,
    childId: childId,
    leaseDuration: leaseDuration,
    now: now,
    overrideLeaseToken: overrideLeaseToken,
  );

  @override
  Future<DraftCasResult> resumeDraftClaimAfterExpiry({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    required DateTime now,
    String? overrideLeaseToken,
  }) => inner.resumeDraftClaimAfterExpiry(
    localDraftId: localDraftId,
    actorUserId: actorUserId,
    familyId: familyId,
    childId: childId,
    leaseDuration: leaseDuration,
    now: now,
    overrideLeaseToken: overrideLeaseToken,
  );

  @override
  Future<DraftCasResult> markDraftStageAndDispatch({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DraftSubmissionStatus targetStage,
    required DateTime now,
  }) => inner.markDraftStageAndDispatch(
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    targetStage: targetStage,
    now: now,
  );

  @override
  Future<DraftCasResult> persistServerAssessmentId({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
  }) => inner.persistServerAssessmentId(
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    serverAssessmentId: serverAssessmentId,
    now: now,
  );

  @override
  Future<DraftCasResult> persistServerEvidenceId({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverEvidenceId,
    required String expectedEvidenceId,
    required String expectedSha256Checksum,
    required DateTime now,
  }) => inner.persistServerEvidenceId(
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    serverEvidenceId: serverEvidenceId,
    expectedEvidenceId: expectedEvidenceId,
    expectedSha256Checksum: expectedSha256Checksum,
    now: now,
  );

  @override
  Future<DraftCasResult> scheduleDraftRetry({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DateTime nextAttemptAt,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  }) => inner.scheduleDraftRetry(
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    nextAttemptAt: nextAttemptAt,
    recoveryCode: recoveryCode,
    errorMessage: errorMessage,
    now: now,
  );

  @override
  Future<DraftCasResult> quarantineDraftOutcome({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  }) => inner.quarantineDraftOutcome(
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    recoveryCode: recoveryCode,
    errorMessage: errorMessage,
    now: now,
  );

  @override
  Future<DraftCasResult> completeDraftSubmission({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
    String? serverEvidenceId,
  }) => inner.completeDraftSubmission(
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    serverAssessmentId: serverAssessmentId,
    now: now,
    serverEvidenceId: serverEvidenceId,
  );

  @override
  Future<DraftCasResult> releaseDraftClaim({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    DateTime? now,
  }) => inner.releaseDraftClaim(
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    now: now,
  );

  @override
  Future<DraftCasResult> pauseMismatchedActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  }) => inner.pauseMismatchedActorDraft(
    localDraftId: localDraftId,
    familyId: familyId,
    authenticatedActorId: authenticatedActorId,
    mismatchReason: mismatchReason,
    now: now,
  );

  @override
  Future<DraftCasResult> resumeOriginalActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  }) => inner.resumeOriginalActorDraft(
    localDraftId: localDraftId,
    familyId: familyId,
    authenticatedActorId: authenticatedActorId,
    now: now,
  );
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

final class FailingEvidenceFileStore implements LocalEvidenceFileStore {
  FailingEvidenceFileStore({
    this.delegate,
    this.shouldFailSave = true,
    this.shouldFailLoad = false,
    this.shouldReturnNullLoad = false,
    this.pendingLoadCompleter,
  });

  final LocalEvidenceFileStore? delegate;
  bool shouldFailSave;
  bool shouldFailLoad;
  bool shouldReturnNullLoad;
  Completer<List<int>?>? pendingLoadCompleter;
  final Set<String> _savedCanonicalPaths = {};

  @override
  Future<String> saveEvidence({
    required String fileName,
    required List<int> bytes,
  }) async {
    if (shouldFailSave) {
      throw const EvidenceStorageException(
        'Simulated storage write failure (disk full / I/O error)',
      );
    }
    return delegate!.saveEvidence(fileName: fileName, bytes: bytes);
  }

  @override
  Future<String> saveDurableEvidence({
    required String localDraftId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    if (shouldFailSave) {
      throw const EvidenceStorageException(
        'Simulated durable storage failure (disk full / I/O error)',
      );
    }
    return delegate!.saveDurableEvidence(
      localDraftId: localDraftId,
      bytes: bytes,
      mediaType: mediaType,
    );
  }

  @override
  Future<List<int>?> loadEvidence(String filePath) async {
    if (pendingLoadCompleter != null) {
      return pendingLoadCompleter!.future;
    }
    if (shouldFailLoad) {
      throw const FileSystemException(
        'Simulated I/O disk error loading evidence file',
      );
    }
    if (shouldReturnNullLoad) {
      return null;
    }
    return delegate?.loadEvidence(filePath);
  }

  @override
  Future<List<int>?> readEvidenceBytes(String filePath) async =>
      delegate?.readEvidenceBytes(filePath);

  @override
  Future<void> deleteDurableEvidence(String filePath) async =>
      delegate?.deleteDurableEvidence(filePath);

  @override
  Future<void> deleteEvidence(String filePath) async =>
      delegate?.deleteEvidence(filePath);

  @override
  Future<EvidenceFileDeletionResult> deleteEvidenceIfUnreferenced({
    required String filePath,
    required LocalDraftStore draftStore,
  }) async =>
      delegate?.deleteEvidenceIfUnreferenced(
        filePath: filePath,
        draftStore: draftStore,
      ) ??
      EvidenceFileDeletionResult(
        status: EvidenceFileDeletionStatus.preservedConservative,
        filePath: filePath,
      );

  @override
  Future<CanonicalEvidenceSnapshot> saveCanonicalEvidenceSnapshot({
    required String localDraftId,
    required List<int> bytes,
  }) async {
    if (shouldFailSave) {
      throw const EvidenceStorageException(
        'Simulated canonical snapshot write failure (disk full / I/O error)',
      );
    }
    final snap = await delegate!.saveCanonicalEvidenceSnapshot(
      localDraftId: localDraftId,
      bytes: bytes,
    );
    _savedCanonicalPaths.add(snap.filePath);
    return snap;
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
    if (shouldFailLoad) {
      throw const EvidenceStorageException(
        'Simulated I/O disk error verifying canonical snapshot',
      );
    }
    if (shouldReturnNullLoad &&
        !_savedCanonicalPaths.contains(canonicalFilePath)) {
      throw const EvidenceStorageException(
        'Simulated missing canonical snapshot',
        kind: EvidenceStorageFailureKind.missingSnapshot,
      );
    }
    return delegate!.verifyCanonicalEvidenceSnapshot(
      localDraftId: localDraftId,
      canonicalFilePath: canonicalFilePath,
      expectedSha256: expectedSha256,
      expectedByteLength: expectedByteLength,
      expectedMediaType: expectedMediaType,
      frozenAt: frozenAt,
    );
  }

  @override
  Future<VerifiedCanonicalEvidence> readVerifiedCanonicalSnapshot({
    required LocalAssessmentDraft draft,
  }) async {
    if (shouldFailLoad) {
      throw const EvidenceStorageException(
        'Simulated I/O disk error reading canonical snapshot',
      );
    }
    if (shouldReturnNullLoad &&
        !_savedCanonicalPaths.contains(draft.localCompressedPhotoPath)) {
      throw const EvidenceStorageException(
        'Simulated missing canonical snapshot',
        kind: EvidenceStorageFailureKind.missingSnapshot,
      );
    }
    return delegate!.readVerifiedCanonicalSnapshot(draft: draft);
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
    late FakeAuthSessionPort fakeAuth;
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
      fakeAuth = FakeAuthSessionPort(
        activeUserId: 'local-parent-user',
        sessionGeneration: 'demo-generation-1',
      );
      fakeStorage = FakeAssessmentEvidenceStorage(authSessionPort: fakeAuth);
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
        actorUserId: 'local-parent-user',
      );
    }

    Widget createTestHarness({
      required Widget child,
      LocalDraftStore? customDraftStore,
      EvidencePickerService? customPicker,
      LocalEvidenceFileStore? customFileStore,
    }) {
      return ProviderScope(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
          growthRepositoryProvider.overrideWithValue(fakeGrowthRepo),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
          assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
          localEvidenceFileStoreProvider.overrideWithValue(
            customFileStore ?? fileStore,
          ),
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
    // B01 / B05 / R26-3-02: Successful save with photo replacement
    // -------------------------------------------------------------------------
    testWidgets(
      'B01/B05/R26-3-02: Successful save with photo replacement conservatively preserves prior evidence on disk',
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

        // Under Slice 4B-0 R26-3-02 conservative retention, old file is preserved on disk
        expect(File(oldPath).existsSync(), isTrue);
        expect(File(oldPath).readAsBytesSync(), equals(oldBytes));
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

      // In Phase 6 Slice 4B-0, deleteEvidenceIfUnreferenced conservatively preserves file
      final conservativeAfterAll = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: sharedPath,
        draftStore: appDatabase,
      );
      expect(
        conservativeAfterAll.status,
        equals(EvidenceFileDeletionStatus.preservedConservative),
      );
      expect(conservativeAfterAll.isPreserved, isTrue);
      expect(File(sharedPath).existsSync(), isTrue);
      expect(File(sharedPath).readAsBytesSync(), equals(sharedBytes));
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
        final photoBytes = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5];
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
        final photoBytes = [0xFF, 0xD8, 0xFF, 0xE0, 11, 22, 33];
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
    // Concurrent delete taps, conservative retention and idempotency
    // -------------------------------------------------------------------------
    test(
      'Concurrent cleanup attempts default to conservative retention',
      () async {
        final photoBytes = [42, 43, 44];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'concurrent_pic.jpg',
          bytes: photoBytes,
        );

        // Execute 10 parallel cleanup attempts without allowPhysicalUnlink
        final results = await Future.wait(
          List.generate(
            10,
            (_) => fileStore.deleteEvidenceIfUnreferenced(
              filePath: photoPath,
              draftStore: appDatabase,
            ),
          ),
        );

        // File should remain preserved on disk
        expect(File(photoPath).existsSync(), isTrue);
        expect(File(photoPath).readAsBytesSync(), equals(photoBytes));
        expect(
          results.every((r) => r.isPreserved),
          isTrue,
          reason: 'Concurrent cleanups must all return preserved under Slice 4B-0 policy',
        );
      },
    );

    test('R26-4-01: Public cleanup API cannot physically delete evidence (even unreferenced)', () async {
      final photoBytes = [42, 43, 44];
      final photoPath = await fileStore.saveEvidence(
        fileName: 'unreferenced_evidence.jpg',
        bytes: photoBytes,
      );
      final durableBytes = [52, 53, 54];
      final durablePath = await fileStore.saveDurableEvidence(
        localDraftId: 'unref-draft',
        bytes: durableBytes,
        mediaType: 'image/jpeg',
      );

      // Verify zero draft references in database
      expect(
        await appDatabase.countDraftReferencesToFile(photoPath),
        equals(0),
      );
      expect(
        await appDatabase.countDraftReferencesToFile(durablePath),
        equals(0),
      );

      // 1. deleteEvidence is a no-op under conservative retention policy
      await fileStore.deleteEvidence(photoPath);
      expect(File(photoPath).existsSync(), isTrue);
      expect(File(photoPath).readAsBytesSync(), equals(photoBytes));

      // 2. deleteDurableEvidence is a no-op under conservative retention policy
      await fileStore.deleteDurableEvidence(durablePath);
      expect(File(durablePath).existsSync(), isTrue);
      expect(File(durablePath).readAsBytesSync(), equals(durableBytes));

      // 3. deleteEvidenceIfUnreferenced returns preservedConservative and retains file
      final photoResult = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: photoPath,
        draftStore: appDatabase,
      );
      expect(
        photoResult.status,
        equals(EvidenceFileDeletionStatus.preservedConservative),
      );
      expect(photoResult.isPreserved, isTrue);
      expect(File(photoPath).existsSync(), isTrue);
      expect(File(photoPath).readAsBytesSync(), equals(photoBytes));

      final durableResult = await fileStore.deleteEvidenceIfUnreferenced(
        filePath: durablePath,
        draftStore: appDatabase,
      );
      expect(
        durableResult.status,
        equals(EvidenceFileDeletionStatus.preservedConservative),
      );
      expect(durableResult.isPreserved, isTrue);
      expect(File(durablePath).existsSync(), isTrue);
      expect(File(durablePath).readAsBytesSync(), equals(durableBytes));
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

        // Photo file preserved on disk under Slice 4B-0 conservative retention policy
        expect(File(photoPath).existsSync(), isTrue);
        expect(File(photoPath).readAsBytesSync(), equals(photoBytes));
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

        // While dialog is open, mutate draft directly in SQLite to possiblyDispatched
        await (appDatabase.update(
          appDatabase.localAssessmentDrafts,
        )..where((t) => t.localDraftId.equals('d-stale-disp'))).write(
          LocalAssessmentDraftsCompanion(
            dispatchState: Value(
              CommandDispatchState.possiblyDispatched.wireValue,
            ),
            updatedAt: Value(now.add(const Duration(seconds: 5))),
          ),
        );

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
      'R26-3-01 UI: Draft actorUserId or command ID changed without changing updatedAt shows conflict dialog',
      (tester) async {
        final photoBytes = [88, 99];
        final photoPath = await fileStore.saveEvidence(
          fileName: 'stale_dialog_id_conflict.jpg',
          bytes: photoBytes,
        );
        final draft = buildDraft(
          draftId: 'd-stale-id-conflict',
          photoPath: photoPath,
          title: 'Unchanged Title',
        );
        await appDatabase.saveLocalDraft(draft);

        final persistedInitial = await appDatabase.getLocalDraft(
          'd-stale-id-conflict',
        );
        expect(persistedInitial, isNotNull);

        await tester.pumpWidget(
          createTestHarness(child: const Scaffold(body: ChildModeScreen())),
        );
        await tester.pumpAndSettle();

        expect(find.text('Unchanged Title'), findsOneWidget);

        // Open confirm delete dialog
        await tester.tap(
          find.byKey(const Key('delete_draft_button_d-stale-id-conflict')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('confirm_delete_draft_dialog')),
          findsOneWidget,
        );

        // Concurrently modify actorUserId and submitCommandId directly in SQLite WITHOUT changing updatedAt
        await (appDatabase.update(
          appDatabase.localAssessmentDrafts,
        )..where((t) => t.localDraftId.equals('d-stale-id-conflict'))).write(
          const LocalAssessmentDraftsCompanion(
            actorUserId: Value('new-worker-id'),
            submitCommandId: Value('new-submit-cmd'),
          ),
        );

        // Tap Delete in dialog
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

        await tester.tap(
          find.byKey(const Key('draft_delete_conflict_ok_button')),
        );
        await tester.pumpAndSettle();

        final persisted = await appDatabase.getLocalDraft(
          'd-stale-id-conflict',
        );
        expect(persisted, isNotNull);
        expect(persisted!.actorUserId, equals('new-worker-id'));
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

        // While dialog open, background worker claims lease via CAS
        final claim = await appDatabase.acquireDraftClaim(
          localDraftId: 'd-stale-lease',
          actorUserId: 'local-parent-user',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          leaseDuration: const Duration(minutes: 5),
          overrideLeaseToken: 'worker-lease-token-abc',
        );
        expect(claim.isSuccess, isTrue);

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

    // -------------------------------------------------------------------------
    // Additional Verification: Collision resistance & non-overwriting creation
    // -------------------------------------------------------------------------
    test('saveDurableEvidence creates unique collision-resistant files without overwriting', () async {
      final bytesA = [1, 2, 3];
      final bytesB = [4, 5, 6];

      final pathA = await fileStore.saveDurableEvidence(
        localDraftId: 'draft-collision-test',
        bytes: bytesA,
        mediaType: 'image/jpeg',
      );
      final pathB = await fileStore.saveDurableEvidence(
        localDraftId: 'draft-collision-test',
        bytes: bytesB,
        mediaType: 'image/jpeg',
      );

      expect(pathA, isNot(equals(pathB)));
      expect(File(pathA).existsSync(), isTrue);
      expect(File(pathB).existsSync(), isTrue);
      expect(File(pathA).readAsBytesSync(), equals(bytesA));
      expect(File(pathB).readAsBytesSync(), equals(bytesB));
    });

    test('saveEvidence sanitizes traversal filenames and prevents accidental overwriting', () async {
      final bytes1 = [10, 20];
      final bytes2 = [30, 40];

      // Filename with path traversal characters
      final path1 = await fileStore.saveEvidence(
        fileName: '../../sensitive_escaped.jpg',
        bytes: bytes1,
      );
      final path2 = await fileStore.saveEvidence(
        fileName: '../../sensitive_escaped.jpg',
        bytes: bytes2,
      );

      // Verify files are inside draft_evidence and not escaped
      expect(path1, contains('draft_evidence'));
      expect(path1, isNot(contains('..')));
      expect(path2, contains('draft_evidence'));
      expect(path1, isNot(equals(path2)));

      expect(File(path1).readAsBytesSync(), equals(bytes1));
      expect(File(path2).readAsBytesSync(), equals(bytes2));
    });

    test('R26-4-02: Deterministic collision in saveDurableEvidence throws EvidenceStorageException and preserves original file bytes', () async {
      final fixedClock = DateTime(2026, 11, 9, 12, 0, 0);
      final collidingStore = DefaultLocalEvidenceFileStore(
        baseDirectory: tempDir,
        clock: () => fixedClock,
        suffixGenerator: () => 'fixed-collision',
      );

      final evidenceDir = Directory('${tempDir.path}/draft_evidence');
      if (!evidenceDir.existsSync()) {
        evidenceDir.createSync(recursive: true);
      }

      // Pre-create the colliding file
      final collidingFile = File(
        '${evidenceDir.path}/test-draft_${fixedClock.millisecondsSinceEpoch}_fixed-collision.jpg',
      );
      final originalBytes = [1, 2, 3, 4, 5];
      collidingFile.writeAsBytesSync(originalBytes, flush: true);

      // Attempt to save durable evidence that collides on every attempt
      expect(
        () => collidingStore.saveDurableEvidence(
          localDraftId: 'test-draft',
          bytes: [9, 9, 9, 9],
          mediaType: 'image/jpeg',
        ),
        throwsA(
          isA<EvidenceStorageException>().having(
            (e) => e.message,
            'message',
            contains(
              'Failed to exclusively create durable evidence file after 5 collision attempts',
            ),
          ),
        ),
      );

      // Verify original file was NEVER overwritten
      expect(collidingFile.existsSync(), isTrue);
      expect(collidingFile.readAsBytesSync(), equals(originalBytes));
    });

    test('R26-4-02: Deterministic collision in saveEvidence throws EvidenceStorageException and preserves original file bytes', () async {
      final fixedClock = DateTime(2026, 11, 9, 12, 0, 0);
      final collidingStore = DefaultLocalEvidenceFileStore(
        baseDirectory: tempDir,
        clock: () => fixedClock,
        suffixGenerator: () => 'fixed-collision',
      );

      final evidenceDir = Directory('${tempDir.path}/draft_evidence');
      if (!evidenceDir.existsSync()) {
        evidenceDir.createSync(recursive: true);
      }

      // Pre-create the colliding file
      final collidingFile = File(
        '${evidenceDir.path}/${fixedClock.millisecondsSinceEpoch}_fixed-collision_pic.jpg',
      );
      final originalBytes = [10, 20, 30, 40];
      collidingFile.writeAsBytesSync(originalBytes, flush: true);

      // Attempt to save evidence that collides on every attempt
      expect(
        () => collidingStore.saveEvidence(fileName: 'pic.jpg', bytes: [99, 99]),
        throwsA(
          isA<EvidenceStorageException>().having(
            (e) => e.message,
            'message',
            contains(
              'Failed to exclusively create evidence file after 5 collision attempts',
            ),
          ),
        ),
      );

      // Verify original file was NEVER overwritten
      expect(collidingFile.existsSync(), isTrue);
      expect(collidingFile.readAsBytesSync(), equals(originalBytes));
    });

    test('R26-4-02: saveDurableEvidence recovers on subsequent attempt without overwriting pre-existing colliding file', () async {
      final fixedClock = DateTime(2026, 11, 9, 12, 0, 0);
      int callCount = 0;
      final recoveringStore = DefaultLocalEvidenceFileStore(
        baseDirectory: tempDir,
        clock: () => fixedClock,
        suffixGenerator: () {
          final res = callCount == 0
              ? 'collision-candidate'
              : 'recovered-unique';
          callCount++;
          return res;
        },
      );

      final evidenceDir = Directory('${tempDir.path}/draft_evidence');
      if (!evidenceDir.existsSync()) {
        evidenceDir.createSync(recursive: true);
      }

      // Pre-create the colliding file for attempt 0
      final collidingFile = File(
        '${evidenceDir.path}/recover-draft_${fixedClock.millisecondsSinceEpoch}_collision-candidate.png',
      );
      final originalBytes = [100, 101, 102];
      collidingFile.writeAsBytesSync(originalBytes, flush: true);

      final newBytes = [200, 201];
      final savedPath = await recoveringStore.saveDurableEvidence(
        localDraftId: 'recover-draft',
        bytes: newBytes,
        mediaType: 'image/png',
      );

      expect(savedPath, contains('recovered-unique.png'));
      expect(File(savedPath).existsSync(), isTrue);
      expect(File(savedPath).readAsBytesSync(), equals(newBytes));

      // Original colliding file remains untouched
      expect(collidingFile.existsSync(), isTrue);
      expect(collidingFile.readAsBytesSync(), equals(originalBytes));
    });

    test('R26-4-02: saveEvidence recovers on subsequent attempt without overwriting pre-existing colliding file', () async {
      final fixedClock = DateTime(2026, 11, 9, 12, 0, 0);
      int callCount = 0;
      final recoveringStore = DefaultLocalEvidenceFileStore(
        baseDirectory: tempDir,
        clock: () => fixedClock,
        suffixGenerator: () {
          final res = callCount == 0
              ? 'collision-candidate'
              : 'recovered-unique';
          callCount++;
          return res;
        },
      );

      final evidenceDir = Directory('${tempDir.path}/draft_evidence');
      if (!evidenceDir.existsSync()) {
        evidenceDir.createSync(recursive: true);
      }

      // Pre-create the colliding file for attempt 0
      final collidingFile = File(
        '${evidenceDir.path}/${fixedClock.millisecondsSinceEpoch}_collision-candidate_doc.pdf',
      );
      final originalBytes = [70, 71, 72];
      collidingFile.writeAsBytesSync(originalBytes, flush: true);

      final newBytes = [80, 81];
      final savedPath = await recoveringStore.saveEvidence(
        fileName: 'doc.pdf',
        bytes: newBytes,
      );

      expect(savedPath, contains('recovered-unique_doc.pdf'));
      expect(File(savedPath).existsSync(), isTrue);
      expect(File(savedPath).readAsBytesSync(), equals(newBytes));

      // Original colliding file remains untouched
      expect(collidingFile.existsSync(), isTrue);
      expect(collidingFile.readAsBytesSync(), equals(originalBytes));
    });

    test('R26-4-02: saveDurableEvidence rejects path traversal, separators, and invalid characters in localDraftId', () async {
      final testCases = [
        '../../traversal',
        'sub/folder',
        r'sub\folder',
        '..',
        '',
        'draft with spaces',
        'draft!@#\$%',
        'draft\x00null',
      ];

      for (final invalidId in testCases) {
        expect(
          () => fileStore.saveDurableEvidence(
            localDraftId: invalidId,
            bytes: [1, 2, 3],
            mediaType: 'image/jpeg',
          ),
          throwsA(
            isA<EvidenceStorageException>().having(
              (e) => e.message,
              'message',
              contains('Invalid localDraftId'),
            ),
          ),
          reason: 'localDraftId "$invalidId" must be rejected',
        );
      }

      // Valid IDs containing alphanumeric, dashes, and underscores succeed
      final validPath = await fileStore.saveDurableEvidence(
        localDraftId: 'valid-draft_123',
        bytes: [1, 2, 3],
        mediaType: 'image/jpeg',
      );
      expect(File(validPath).existsSync(), isTrue);
    });

    test(
      'R26-4-02: saveEvidence rejects invalid and empty file names',
      () async {
        final invalidNames = ['', '.', '..', '../../', '__', '#@!\$%^&*()'];

        for (final invalidName in invalidNames) {
          expect(
            () =>
                fileStore.saveEvidence(fileName: invalidName, bytes: [1, 2, 3]),
            throwsA(
              isA<EvidenceStorageException>().having(
                (e) => e.message,
                'message',
                contains('Invalid fileName'),
              ),
            ),
            reason: 'fileName "$invalidName" must be rejected',
          );
        }
      },
    );

    // -------------------------------------------------------------------------
    // R26-5-01: Evidence persistence failure must not be treated as success
    // -------------------------------------------------------------------------
    testWidgets(
      'R26-5-01: New photo selected; saveEvidence throws; user receives actionable error and attach button remains',
      (tester) async {
        final failingFileStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: true,
        );
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'temp_picker.jpg',
            bytes: [1, 2, 3],
            mediaType: 'image/jpeg',
            localPath: '/tmp/cache/temp_picker.jpg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingFileStore,
            customPicker: picker,
            child: const Scaffold(body: AddAssessmentScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Tap attach photo button
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        // Actionable error message is displayed
        expect(
          find.textContaining('Could not save evidence photo locally'),
          findsOneWidget,
        );
        // Photo was not accepted as attached evidence
        expect(find.byKey(const Key('attach_evidence_button')), findsOneWidget);
        expect(find.byKey(const Key('remove_evidence_button')), findsNothing);
      },
    );

    testWidgets(
      'R26-5-01: User attempts to save draft after failure; no misleading success reported and temporary path not persisted',
      (tester) async {
        final failingFileStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: true,
        );
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'temp_picker.jpg',
            bytes: [1, 2, 3],
            mediaType: 'image/jpeg',
            localPath: '/tmp/cache/temp_picker.jpg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingFileStore,
            customPicker: picker,
            child: const Scaffold(body: AddAssessmentScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Trigger picker which fails
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Could not save evidence photo locally'),
          findsOneWidget,
        );

        // Attempt to tap Save Draft
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        // No misleading "Draft saved locally." snackbar is displayed
        expect(find.text('Draft saved locally.'), findsNothing);
        expect(
          find.textContaining(
            'Cannot save draft: the selected photo could not be saved locally',
          ),
          findsOneWidget,
        );

        // Verify SQLite store does NOT contain any draft referencing the temporary path
        final drafts = await appDatabase.listLocalDrafts(testChild.id);
        expect(
          drafts.where((d) => d.localPhotoPath == '/tmp/cache/temp_picker.jpg'),
          isEmpty,
        );
      },
    );

    testWidgets(
      'R26-5-01: User attempts to submit assessment after failure; submission is blocked',
      (tester) async {
        final failingFileStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: true,
        );
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'temp_picker.jpg',
            bytes: [1, 2, 3],
            mediaType: 'image/jpeg',
            localPath: '/tmp/cache/temp_picker.jpg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingFileStore,
            customPicker: picker,
            child: const Scaffold(body: AddAssessmentScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Fill out required form fields
        await tester.enterText(
          find.byKey(const Key('assessment_raw_score_field')),
          '9',
        );
        await tester.enterText(
          find.byKey(const Key('assessment_title_field')),
          'Math Test',
        );
        await tester.pumpAndSettle();

        // Trigger picker failure
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        // Attempt to Submit
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        // Submission is blocked
        expect(find.text('Assessment submitted for review!'), findsNothing);
        expect(
          find.textContaining(
            'Cannot submit assessment: the selected photo could not be saved locally',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'R26-5-01: Existing draft photo is replaced, but new file persistence fails; original draft row, evidence ID, photo path and bytes remain unchanged',
      (tester) async {
        final origBytes = [40, 50, 60];
        final origPath = await fileStore.saveEvidence(
          fileName: 'original_durable.jpg',
          bytes: origBytes,
        );
        const origEvidenceId = 'ev-durable-orig-789';
        final initialDraft = buildDraft(
          draftId: 'd-orig-replace-fail',
          photoPath: origPath,
          title: 'Existing Homework',
        ).copyWith(evidenceId: origEvidenceId);
        await appDatabase.saveLocalDraft(initialDraft);

        final failingFileStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: true,
        );
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'new_temp_fail.jpg',
            bytes: [99, 98],
            mediaType: 'image/jpeg',
            localPath: '/tmp/cache/new_temp_fail.jpg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingFileStore,
            customPicker: picker,
            child: Scaffold(
              body: AddAssessmentScreen(initialDraft: initialDraft),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Existing photo is displayed
        expect(find.textContaining('original_durable.jpg'), findsOneWidget);

        // Tap Change Photo
        await tester.ensureVisible(
          find.byKey(const Key('change_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('change_evidence_button')));
        await tester.pumpAndSettle();

        // Actionable error is displayed
        expect(
          find.textContaining('Could not save evidence photo locally'),
          findsOneWidget,
        );
        // Previous attachment remains visible in UI
        expect(find.textContaining('original_durable.jpg'), findsOneWidget);

        // User attempts to save draft
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.text('Draft saved locally.'), findsNothing);

        // Query real SQLite database: draft row, evidence ID, photo path, and bytes remain 100% UNCHANGED
        final persisted = await appDatabase.getLocalDraft(
          'd-orig-replace-fail',
        );
        expect(persisted, isNotNull);
        expect(persisted!.evidenceId, equals(origEvidenceId));
        expect(persisted.localPhotoPath, equals(origPath));
        expect(persisted.title, equals('Existing Homework'));
        expect(File(origPath).existsSync(), isTrue);
        expect(File(origPath).readAsBytesSync(), equals(origBytes));
      },
    );

    testWidgets(
      'R26-5-01: Restart after failed selection; original evidence remains recoverable',
      (tester) async {
        final origBytes = [70, 80, 90];
        final origPath = await fileStore.saveEvidence(
          fileName: 'original_survivor.jpg',
          bytes: origBytes,
        );
        const origEvidenceId = 'ev-survivor-111';
        final initialDraft = buildDraft(
          draftId: 'd-survivor',
          photoPath: origPath,
          title: 'Survivor Draft',
        ).copyWith(evidenceId: origEvidenceId);
        await appDatabase.saveLocalDraft(initialDraft);

        final failingFileStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: true,
        );
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'unpersisted_crash.jpg',
            bytes: [1, 1, 1],
            mediaType: 'image/jpeg',
            localPath: '/tmp/cache/unpersisted_crash.jpg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingFileStore,
            customPicker: picker,
            child: Scaffold(
              body: AddAssessmentScreen(initialDraft: initialDraft),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Trigger failed photo replacement
        await tester.ensureVisible(
          find.byKey(const Key('change_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('change_evidence_button')));
        await tester.pumpAndSettle();

        // Simulate app restart: close database and re-open from the same file
        await appDatabase.close();
        final reopenedDb = AppDatabase(NativeDatabase(dbFile));

        try {
          final recoveredDraft = await reopenedDb.getLocalDraft('d-survivor');
          expect(recoveredDraft, isNotNull);
          expect(recoveredDraft!.evidenceId, equals(origEvidenceId));
          expect(recoveredDraft.localPhotoPath, equals(origPath));

          // Load original bytes from durable storage
          final recoveredBytes = await fileStore.loadEvidence(
            recoveredDraft.localPhotoPath!,
          );
          expect(recoveredBytes, equals(origBytes));
        } finally {
          await reopenedDb.close();
          // Restore appDatabase for tearDown
          appDatabase = AppDatabase(NativeDatabase(dbFile));
        }
      },
    );

    testWidgets(
      'R26-5-01: Successful durable copy supports normal save and submission',
      (tester) async {
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'good_photo.jpg',
            bytes: [11, 22, 33],
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customPicker: picker,
            child: const Scaffold(body: AddAssessmentScreen()),
          ),
        );
        await tester.pumpAndSettle();

        // Attach photo (succeeds with real fileStore)
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        // Shows attached photo
        expect(find.textContaining('good_photo.jpg'), findsOneWidget);
        expect(find.byKey(const Key('remove_evidence_button')), findsOneWidget);

        // Save draft locally
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.text('Draft saved locally.'), findsOneWidget);

        // Verify draft was saved with durable path inside draft_evidence/
        final drafts = await appDatabase.listLocalDrafts(testChild.id);
        expect(drafts, isNotEmpty);
        final saved = drafts.first;
        expect(saved.localPhotoPath, isNotNull);
        expect(saved.localPhotoPath, contains('draft_evidence'));
        expect(File(saved.localPhotoPath!).existsSync(), isTrue);
        expect(
          File(saved.localPhotoPath!).readAsBytesSync(),
          equals([11, 22, 33]),
        );
      },
    );

    testWidgets(
      'R26-5-01: Explicitly submitting with no attachment remains supported',
      (tester) async {
        await tester.pumpWidget(
          createTestHarness(child: const Scaffold(body: AddAssessmentScreen())),
        );
        await tester.pumpAndSettle();

        // Fill out required form fields without attaching photo
        await tester.enterText(
          find.byKey(const Key('assessment_raw_score_field')),
          '8.5',
        );
        await tester.enterText(
          find.byKey(const Key('assessment_title_field')),
          'Reading Comprehension',
        );
        await tester.pumpAndSettle();

        // Tap Submit
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        // Submission succeeds without photo
        expect(find.text('Assessment submitted for review!'), findsOneWidget);
      },
    );

    testWidgets(
      'R26-5-01: Photo save fails, user dismisses error, and submits with no attachment successfully',
      (tester) async {
        final failingFileStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: true,
        );
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'fail.jpg',
            bytes: [1, 2],
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingFileStore,
            customPicker: picker,
            child: const Scaffold(body: AddAssessmentScreen()),
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('assessment_raw_score_field')),
          '10',
        );
        await tester.enterText(
          find.byKey(const Key('assessment_title_field')),
          'Spelling Test',
        );
        await tester.pumpAndSettle();

        // Trigger picker which fails
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Could not save evidence photo locally'),
          findsOneWidget,
        );

        // User taps Dismiss button
        await tester.ensureVisible(
          find.byKey(const Key('dismiss_evidence_error_button')),
        );
        await tester.tap(
          find.byKey(const Key('dismiss_evidence_error_button')),
        );
        await tester.pumpAndSettle();

        // Error is dismissed
        expect(
          find.textContaining('Could not save evidence photo locally'),
          findsNothing,
        );

        // Now user submits with no attachment
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        expect(find.text('Assessment submitted for review!'), findsOneWidget);
      },
    );

    testWidgets(
      'R26-6-01 (1): Existing draft references a missing physical file (returns null from fileStore)',
      (tester) async {
        final draft = buildDraft(
          draftId: 'r26-6-missing-file',
          photoPath: '${tempDir.path}/evidence/non_existent_photo.jpg',
        );
        await appDatabase.saveLocalDraft(draft);

        await tester.pumpWidget(
          createTestHarness(
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Existing evidence file is missing or unreadable',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('attach_evidence_button')), findsOneWidget);
        expect(find.byKey(const Key('remove_evidence_button')), findsOneWidget);
      },
    );

    testWidgets(
      'R26-6-01 (2): Existing evidence read returns null explicitly',
      (tester) async {
        final draft = buildDraft(
          draftId: 'r26-6-null-read',
          photoPath: '${tempDir.path}/evidence/photo.jpg',
        );
        await appDatabase.saveLocalDraft(draft);

        final failingStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          shouldReturnNullLoad: true,
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingStore,
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'R26-6-01 (3): Existing evidence read throws an I/O exception (FileSystemException)',
      (tester) async {
        final draft = buildDraft(
          draftId: 'r26-6-io-exception',
          photoPath: '${tempDir.path}/evidence/corrupt.jpg',
        );
        await appDatabase.saveLocalDraft(draft);

        final failingStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          shouldFailLoad: true,
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingStore,
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Failed to read existing evidence file'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'R26-6-01 (4): Save after failed restoration: no false evidence-durability success',
      (tester) async {
        final draft = buildDraft(
          draftId: 'r26-6-save-fail-closed',
          photoPath: '${tempDir.path}/evidence/unreadable.jpg',
          title: 'Original Title',
        );
        await appDatabase.saveLocalDraft(draft);

        final failingStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          shouldReturnNullLoad: true,
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingStore,
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        await tester.pumpAndSettle();

        // Attempt to edit title and save
        await tester.enterText(
          find.byKey(const Key('assessment_title_field')),
          'Mutated Title Without Evidence',
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        // Must NOT report draft saved locally
        expect(find.text('Draft saved locally.'), findsNothing);
        expect(
          find.textContaining(
            'Cannot save draft: existing evidence is missing or unreadable',
          ),
          findsOneWidget,
        );

        // Database row must remain intact with original title
        final persisted = await appDatabase.getLocalDraft(
          'r26-6-save-fail-closed',
        );
        expect(persisted, isNotNull);
        expect(persisted!.title, 'Original Title');
        expect(
          persisted.localPhotoPath,
          '${tempDir.path}/evidence/unreadable.jpg',
        );
      },
    );

    testWidgets(
      'R26-6-01 (5): Submit after failed restoration: zero remote mutations and draft remains intact',
      (tester) async {
        final draft = buildDraft(
          draftId: 'r26-6-submit-fail-closed',
          photoPath: '${tempDir.path}/evidence/unreadable.jpg',
          title: 'Science Project',
        );
        await appDatabase.saveLocalDraft(draft);

        final failingStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          shouldReturnNullLoad: true,
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingStore,
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        // Must NOT report submitted
        expect(find.text('Assessment submitted for review!'), findsNothing);
        expect(
          find.textContaining(
            'Cannot submit assessment: existing evidence is missing or unreadable',
          ),
          findsOneWidget,
        );

        // Zero remote mutations
        expect(fakeAssessmentRepo.assessments.isEmpty, isTrue);
        expect(fakeStorage.storage.isEmpty, isTrue);

        // Database row must remain intact
        final persisted = await appDatabase.getLocalDraft(
          'r26-6-submit-fail-closed',
        );
        expect(persisted, isNotNull);
        expect(
          persisted!.localPhotoPath,
          '${tempDir.path}/evidence/unreadable.jpg',
        );
        expect(persisted.submissionStatus, DraftSubmissionStatus.draft);
      },
    );

    testWidgets(
      'R26-6-01 (6): Restoration still pending when Save/Submit is attempted fails closed',
      (tester) async {
        final pendingLoadCompleter = Completer<List<int>?>();
        final draft = buildDraft(
          draftId: 'r26-6-pending-load',
          photoPath: '${tempDir.path}/evidence/slow.jpg',
        );
        await appDatabase.saveLocalDraft(draft);

        final slowStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          pendingLoadCompleter: pendingLoadCompleter,
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: slowStore,
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        // Pump frame without settling so load is still pending
        await tester.pump();

        expect(
          find.text('Verifying existing evidence photo...'),
          findsOneWidget,
        );

        // Save attempt while loading fails closed
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pump();

        expect(
          find.text(
            'Evidence restoration is in progress. Please wait a moment before saving.',
          ),
          findsOneWidget,
        );

        // Submit attempt while loading fails closed
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pump();

        expect(
          find.text(
            'Evidence restoration is in progress. Please wait a moment before submitting.',
          ),
          findsOneWidget,
        );

        // Now complete the restoration
        pendingLoadCompleter.complete([1, 2, 3, 4, 5]);
        await tester.pumpAndSettle();

        expect(find.textContaining('slow.jpg'), findsOneWidget);
        expect(find.text('Verifying existing evidence photo...'), findsNothing);
      },
    );

    testWidgets(
      'R26-6-01 (7): New replacement succeeds after a restoration failure',
      (tester) async {
        final draft = buildDraft(
          draftId: 'r26-6-replace-success',
          photoPath: '${tempDir.path}/evidence/unreadable.jpg',
        );
        await appDatabase.saveLocalDraft(draft);

        final customStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          shouldReturnNullLoad: true,
        );
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'fresh_replacement.jpg',
            bytes: [0xFF, 0xD8, 0xFF, 0xE0, 10, 20, 30, 40],
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: customStore,
            customPicker: picker,
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsOneWidget,
        );

        // User attaches replacement
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pumpAndSettle();

        // Broken warning should be gone, replacement displayed
        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsNothing,
        );
        expect(find.textContaining('fresh_replacement.jpg'), findsOneWidget);

        // Save succeeds
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.text('Draft saved locally.'), findsOneWidget);
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
            .clearSnackBars();
        await tester.pumpAndSettle();

        // Submit succeeds
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        expect(find.text('Assessment submitted for review!'), findsOneWidget);
        expect(fakeAssessmentRepo.assessments.length, 1);
        expect(fakeStorage.storage.length, 1);
      },
    );

    testWidgets(
      'R26-6-01 (8): Late restoration response cannot overwrite a newer user selection',
      (tester) async {
        final pendingLoadCompleter = Completer<List<int>?>();
        final draft = buildDraft(
          draftId: 'r26-6-epoch-token',
          photoPath: '${tempDir.path}/evidence/slow_photo.jpg',
        );
        await appDatabase.saveLocalDraft(draft);

        final slowStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          pendingLoadCompleter: pendingLoadCompleter,
        );
        final picker = SimulatedEvidencePickerService(
          stubFile: const SelectedEvidenceFile(
            fileName: 'newer_photo.jpg',
            bytes: [9, 9, 9],
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: slowStore,
            customPicker: picker,
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        // Pump frame, restoration in flight
        await tester.pump();

        // While pending, user picks a replacement photo
        await tester.ensureVisible(
          find.byKey(const Key('attach_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('attach_evidence_button')));
        await tester.pump();

        // Newer photo is now attached
        expect(find.textContaining('newer_photo.jpg'), findsOneWidget);

        // Now the slow load finally completes with the old photo bytes
        pendingLoadCompleter.complete([1, 1, 1]);
        await tester.pumpAndSettle();

        // Newer selection MUST NOT be overwritten by the late restoration result
        expect(find.textContaining('newer_photo.jpg'), findsOneWidget);
        expect(find.textContaining('slow_photo.jpg'), findsNothing);
      },
    );

    testWidgets(
      'R26-6-01 (9): Restart preserves original IDs and recovery metadata in SQLite',
      (tester) async {
        final originalDraft = LocalAssessmentDraft(
          localDraftId: 'r26-6-metadata-preserve',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          createCommandId: 'cmd-create-original-999',
          submitCommandId: 'cmd-submit-original-888',
          evidenceId: 'ev-original-777',
          serverAssessmentId: 'srv-original-666',
          subjectKey: SubjectKey.english,
          subject: 'English',
          title: 'Spelling Essay',
          assessmentType: 'exam',
          difficulty: 'hard',
          rawScore: 95.0,
          maxScore: 100.0,
          localPhotoPath: '${tempDir.path}/evidence/missing_essay.jpg',
          occurredAt: now,
          updatedAt: now,
          entryContext: EntryContext.sharedChild,
          actorUserId: 'actor-original-555',
          actorRole: 'learner',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.draft,
        );
        await appDatabase.saveLocalDraft(originalDraft);

        final failingStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          shouldReturnNullLoad: true,
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: failingStore,
            child: Scaffold(
              body: AddAssessmentScreen(initialDraft: originalDraft),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Screen is open, restoration failed
        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsOneWidget,
        );

        // Attempt save (fails closed)
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        // Reload draft directly from SQLite to simulate app restart
        final reloaded = await appDatabase.getLocalDraft(
          'r26-6-metadata-preserve',
        );
        expect(reloaded, isNotNull);
        expect(reloaded!.createCommandId, 'cmd-create-original-999');
        expect(reloaded.submitCommandId, 'cmd-submit-original-888');
        expect(reloaded.evidenceId, 'ev-original-777');
        expect(reloaded.serverAssessmentId, 'srv-original-666');
        expect(reloaded.actorUserId, 'actor-original-555');
        expect(reloaded.actorRole, 'learner');
        expect(
          reloaded.localPhotoPath,
          '${tempDir.path}/evidence/missing_essay.jpg',
        );
        expect(reloaded.dispatchState, CommandDispatchState.neverDispatched);
        expect(reloaded.submissionStatus, DraftSubmissionStatus.draft);
      },
    );

    testWidgets(
      'R26-6-01 (10): Genuinely attachment-free draft saves and submits normally',
      (tester) async {
        final draft = buildDraft(
          draftId: 'r26-6-no-attachment',
          photoPath: null,
          title: 'Math Mental Quiz',
        );
        await appDatabase.saveLocalDraft(draft);

        await tester.pumpWidget(
          createTestHarness(
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        await tester.pumpAndSettle();

        // No broken image warning
        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsNothing,
        );
        expect(find.text('Attach Photo'), findsOneWidget);

        // Save succeeds
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.text('Draft saved locally.'), findsOneWidget);
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
            .clearSnackBars();
        await tester.pumpAndSettle();

        // Submit succeeds
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        expect(find.text('Assessment submitted for review!'), findsOneWidget);
        expect(fakeAssessmentRepo.assessments.length, 1);
        expect(fakeStorage.storage.isEmpty, isTrue);
      },
    );

    testWidgets(
      'R26-6-01 (11): Explicitly removing unreadable attachment authorizes attachment-free save and submit',
      (tester) async {
        final draft = buildDraft(
          draftId: 'r26-6-remove-unreadable',
          photoPath: '${tempDir.path}/evidence/corrupt_unreadable.jpg',
        );
        await appDatabase.saveLocalDraft(draft);

        final customStore = FailingEvidenceFileStore(
          delegate: fileStore,
          shouldFailSave: false,
          shouldReturnNullLoad: true,
        );

        await tester.pumpWidget(
          createTestHarness(
            customFileStore: customStore,
            child: Scaffold(body: AddAssessmentScreen(initialDraft: draft)),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsOneWidget,
        );

        // User explicitly taps "Remove Attachment"
        await tester.ensureVisible(
          find.byKey(const Key('remove_evidence_button')),
        );
        await tester.tap(find.byKey(const Key('remove_evidence_button')));
        await tester.pumpAndSettle();

        // Broken warning should be replaced with "Attach Photo"
        expect(
          find.text('Attached photo is missing or unreadable on disk'),
          findsNothing,
        );
        expect(find.text('Attach Photo'), findsOneWidget);

        // Save succeeds with attachment removed
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.text('Draft saved locally.'), findsOneWidget);
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
            .clearSnackBars();
        await tester.pumpAndSettle();

        final persisted = await appDatabase.getLocalDraft(
          'r26-6-remove-unreadable',
        );
        expect(persisted!.localPhotoPath, isNull);
        expect(persisted.evidenceId, isNull);

        // Submit succeeds with zero evidence uploaded
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        expect(find.text('Assessment submitted for review!'), findsOneWidget);
        expect(fakeAssessmentRepo.assessments.length, 1);
        expect(fakeStorage.storage.isEmpty, isTrue);
      },
    );
  });
}
