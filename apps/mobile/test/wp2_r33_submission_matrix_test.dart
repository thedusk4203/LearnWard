import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/assessments/presentation/add_assessment_screen.dart';
import 'package:learnward/features/assessments/presentation/evidence_picker_service.dart';
import 'package:learnward/features/assessments/services/local_evidence_file_store.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void _ensureSqliteInitialized() {
  if (Platform.isWindows) {
    try {
      DynamicLibrary.open('sqlite3.dll');
    } catch (_) {}
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

final class _SpyAssessmentRepository extends FakeAssessmentRepository {
  int createDraftCalls = 0;
  int registerEvidenceCalls = 0;
  int submitAssessmentCalls = 0;

  Object? nextRegisterError;
  Object? nextSubmitError;

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
    registerEvidenceCalls++;
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
    submitAssessmentCalls++;
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

final class _InterceptableSqliteDraftStore implements LocalDraftStore {
  _InterceptableSqliteDraftStore(this.inner);

  final LocalDraftStore inner;

  Future<DraftCasResult?> Function()? onRegisterOrUpdateOverride;
  Future<DraftCasResult?> Function()? onPersistServerAssessmentIdOverride;
  Future<DraftCasResult?> Function()? onCompleteDraftSubmissionOverride;

  @override
  Future<void> saveLocalDraft(LocalAssessmentDraft draft) =>
      inner.saveLocalDraft(draft);

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
  }) async {
    final override = await onRegisterOrUpdateOverride?.call();
    if (override != null) return override;
    return inner.registerOrUpdateDraftIfUnchanged(
      expected: expected,
      desired: desired,
      now: now,
    );
  }

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
  }) async {
    final override = await onPersistServerAssessmentIdOverride?.call();
    if (override != null) return override;
    return inner.persistServerAssessmentId(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      serverAssessmentId: serverAssessmentId,
      now: now,
    );
  }

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
  }) async {
    final override = await onCompleteDraftSubmissionOverride?.call();
    if (override != null) return override;
    return inner.completeDraftSubmission(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      serverAssessmentId: serverAssessmentId,
      now: now,
      serverEvidenceId: serverEvidenceId,
    );
  }

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

final class _ManualClock implements Clock {
  _ManualClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;
}

void main() {
  setUpAll(() {
    _ensureSqliteInitialized();
  });

  group('WP2 Required Regression Matrix (R33-04..R33-06)', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase appDatabase;
    late DefaultLocalEvidenceFileStore fileStore;
    late _SpyAssessmentRepository repo;
    late FakeAuthSessionPort authPort;
    late FakeAssessmentEvidenceStorage storage;
    late FakeFamilyRepository fakeFamilyRepo;
    late FakeChildProfileRepository fakeChildRepo;
    late InMemoryGrowthRepository fakeGrowthRepo;
    late InMemoryLocalMetadataStore fakeMetadataStore;

    final baseTime = DateTime.utc(2026, 11, 14, 10, 0);
    final testFamily = Family(
      id: FamilyId('10000000-0000-0000-0000-000000000010'),
      name: 'Matrix Family',
      timezone: 'UTC',
      locale: 'en_US',
      createdByUserId: 'parent-actor-1',
      createdAt: baseTime,
    );
    final testChild = ChildProfile(
      id: ChildId('20000000-0000-0000-0000-000000000020'),
      familyId: testFamily.id,
      displayName: 'Liam',
      schoolGrade: 4,
      birthYear: 2016,
      createdAt: baseTime,
    );

    final validJpegBytes = <int>[
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0x4A,
      0x46,
      0x49,
      0x46,
      11,
      22,
      33,
      44,
    ];
    final validPngBytes = <int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      55,
      66,
      77,
      88,
    ];

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_wp2_matrix_');
      dbFile = File('${tempDir.path}/wp2_matrix.sqlite');
      appDatabase = AppDatabase(NativeDatabase(dbFile));
      fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
      repo = _SpyAssessmentRepository();
      authPort = FakeAuthSessionPort(
        activeUserId: 'parent-actor-1',
        sessionGeneration: 'gen-matrix-1',
      );
      storage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
      fakeFamilyRepo = FakeFamilyRepository();
      fakeChildRepo = FakeChildProfileRepository();
      fakeGrowthRepo = InMemoryGrowthRepository();
      fakeMetadataStore = InMemoryLocalMetadataStore();
    });

    tearDown(() async {
      await appDatabase.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Widget buildRoutedApp({
      LocalAssessmentDraft? initialDraft,
      LocalDraftStore? customDraftStore,
      EvidencePickerService? customPicker,
      LocalEvidenceFileStore? customFileStore,
      FakeAuthSessionPort? customAuth,
    }) {
      final router = GoRouter(
        initialLocation: '/add',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) =>
                const Scaffold(body: Center(child: Text('HOME_ROUTE'))),
            routes: [
              GoRoute(
                path: 'add',
                builder: (context, state) =>
                    AddAssessmentScreen(initialDraft: initialDraft),
              ),
            ],
          ),
        ],
      );

      return ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWithValue(
            (customAuth ?? authPort).currentContext?.userId,
          ),
          authSessionPortProvider.overrideWithValue(customAuth ?? authPort),
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
          growthRepositoryProvider.overrideWithValue(fakeGrowthRepo),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          assessmentRepositoryProvider.overrideWithValue(repo),
          assessmentEvidenceStorageProvider.overrideWithValue(storage),
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
          evidencePickerServiceProvider.overrideWithValue(
            customPicker ?? SimulatedEvidencePickerService(),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    Future<void> fillRequiredForm(
      WidgetTester tester, {
      String title = 'Matrix Quiz',
      String rawScore = '9',
    }) async {
      await tester.enterText(
        find.byKey(const Key('assessment_title_field')),
        title,
      );
      await tester.enterText(
        find.byKey(const Key('assessment_raw_score_field')),
        rawScore,
      );
      await tester.pumpAndSettle();
    }

    Future<void> tapButton(WidgetTester tester, String key) async {
      final finder = find.byKey(Key(key));
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'Matrix 1: New assessment without photo commits remotely and writes confirmedCommitted SQLite tombstone',
      (tester) async {
        await tester.pumpWidget(buildRoutedApp());
        await tester.pumpAndSettle();

        await fillRequiredForm(tester, title: 'No Photo Quiz');
        await tapButton(tester, 'submit_assessment_button');

        expect(find.text('HOME_ROUTE'), findsOneWidget);
        expect(repo.assessments.length, equals(1));
        expect(repo.submitAssessmentCalls, equals(1));

        final drafts = await appDatabase.listLocalDrafts(testChild.id);
        expect(drafts.length, equals(1));
        final saved = drafts.single;
        expect(saved.dispatchState, CommandDispatchState.confirmedCommitted);
        expect(saved.serverAssessmentId, equals(repo.assessments.keys.single));
        expect(saved.serverEvidenceId, isNull);
        expect(saved.actorUserId, equals('parent-actor-1'));
        expect(saved.leaseToken, isNull);
      },
    );

    testWidgets(
      'Matrix 2 (JPEG & PNG): Freezes canonical snapshot before dispatch, uploads/registers, submits, and stores verified tombstone',
      (tester) async {
        for (final entry in [
          ('jpeg_quiz.jpg', 'image/jpeg', validJpegBytes),
          ('png_quiz.png', 'image/png', validPngBytes),
        ]) {
          final currentCount = repo.assessments.length;
          final picker = SimulatedEvidencePickerService(
            stubFile: SelectedEvidenceFile(
              fileName: entry.$1,
              bytes: entry.$3,
              mediaType: entry.$2,
            ),
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.pumpWidget(buildRoutedApp(customPicker: picker));
          await tester.pumpAndSettle();

          await fillRequiredForm(tester, title: 'Photo ${entry.$1}');
          await tapButton(tester, 'attach_evidence_button');
          await tapButton(tester, 'submit_assessment_button');

          expect(find.text('HOME_ROUTE'), findsOneWidget);
          expect(repo.assessments.length, equals(currentCount + 1));

          final drafts = await appDatabase.listLocalDrafts(testChild.id);
          final matching = drafts.firstWhere(
            (d) => d.title == 'Photo ${entry.$1}',
          );
          expect(
            matching.dispatchState,
            CommandDispatchState.confirmedCommitted,
          );
          expect(matching.isReadOnlyQuarantined, isFalse);
          expect(matching.hasVerifiedEvidenceSnapshot, isTrue);
          expect(matching.localCompressedPhotoPath, contains('_canonical_'));
          expect(matching.sha256Checksum, equals(computeSha256Hex(entry.$3)));
          expect(matching.serverAssessmentId, isNotNull);
          expect(matching.serverEvidenceId, isNotNull);
          expect(matching.leaseToken, isNull);

          final verifiedSnap = await fileStore.readVerifiedCanonicalSnapshot(
            draft: matching,
          );
          expect(verifiedSnap.bytes, equals(entry.$3));
          expect(verifiedSnap.mediaType, equals(entry.$2));
        }
      },
    );

    testWidgets(
      'Matrix 3: Existing saved draft with photo preserves original IDs and resumes cleanly without quarantine',
      (tester) async {
        final picker = SimulatedEvidencePickerService(
          stubFile: SelectedEvidenceFile(
            fileName: 'saved_work.png',
            bytes: validPngBytes,
            mediaType: 'image/png',
          ),
        );

        await tester.pumpWidget(buildRoutedApp(customPicker: picker));
        await tester.pumpAndSettle();

        await fillRequiredForm(tester, title: 'Saved Draft PNG');
        await tapButton(tester, 'attach_evidence_button');
        await tapButton(tester, 'save_draft_button');

        final savedBeforeSubmit = (await appDatabase.listLocalDrafts(
          testChild.id,
        )).single;
        expect(
          savedBeforeSubmit.dispatchState,
          CommandDispatchState.neverDispatched,
        );
        expect(savedBeforeSubmit.localPhotoPath, isNotNull);
        expect(savedBeforeSubmit.localCompressedPhotoPath, isNull);
        expect(savedBeforeSubmit.createCommandId, isNotNull);
        expect(savedBeforeSubmit.submitCommandId, isNotNull);
        expect(savedBeforeSubmit.evidenceId, isNotNull);
        expect(savedBeforeSubmit.actorUserId, equals('parent-actor-1'));

        // Close screen & reopen existing saved draft to submit
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          buildRoutedApp(initialDraft: savedBeforeSubmit, customPicker: picker),
        );
        await tester.pumpAndSettle();
        await tapButton(tester, 'submit_assessment_button');

        expect(find.text('HOME_ROUTE'), findsOneWidget);
        expect(repo.assessments.length, equals(1));

        final after = await appDatabase.getLocalDraft(
          savedBeforeSubmit.localDraftId,
        );
        expect(after, isNotNull);
        expect(after!.dispatchState, CommandDispatchState.confirmedCommitted);
        expect(
          after.createCommandId,
          equals(savedBeforeSubmit.createCommandId),
        );
        expect(
          after.submitCommandId,
          equals(savedBeforeSubmit.submitCommandId),
        );
        expect(after.evidenceId, equals(savedBeforeSubmit.evidenceId));
        expect(after.actorUserId, equals(savedBeforeSubmit.actorUserId));
        expect(after.serverEvidenceId, isNotNull);
        expect(after.isReadOnlyQuarantined, isFalse);
      },
    );

    testWidgets(
      'Matrix 4: Lost registration/submit response retains canonical snapshot and pending journal and converges on retry',
      (tester) async {
        final picker = SimulatedEvidencePickerService(
          stubFile: SelectedEvidenceFile(
            fileName: 'retry_work.jpg',
            bytes: validJpegBytes,
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(buildRoutedApp(customPicker: picker));
        await tester.pumpAndSettle();

        await fillRequiredForm(tester, title: 'Lost Response Draft');
        await tapButton(tester, 'attach_evidence_button');

        // Inject lost registration response on first submit
        repo.nextRegisterError = StateError('Lost registration ACK');
        await tapButton(tester, 'submit_assessment_button');

        expect(find.byType(AddAssessmentScreen), findsOneWidget);
        expect(find.text('HOME_ROUTE'), findsNothing);

        final midDraft = (await appDatabase.listLocalDrafts(testChild.id))
            .single;
        expect(midDraft.dispatchState, CommandDispatchState.possiblyDispatched);
        expect(
          midDraft.submissionStatus,
          DraftSubmissionStatus.uploadingEvidence,
        );
        expect(midDraft.serverAssessmentId, isNotNull);
        expect(midDraft.localCompressedPhotoPath, isNotNull);
        expect(
          midDraft.sha256Checksum,
          equals(computeSha256Hex(validJpegBytes)),
        );
        expect(midDraft.leaseToken, isNull);
        expect(File(midDraft.localCompressedPhotoPath!).existsSync(), isTrue);

        // Retry resumed draft -> converges without creating duplicate server draft
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(buildRoutedApp(initialDraft: midDraft));
        await tester.pumpAndSettle();
        await tapButton(tester, 'submit_assessment_button');

        expect(find.text('HOME_ROUTE'), findsOneWidget);
        expect(repo.assessments.length, equals(1));
        final done = await appDatabase.getLocalDraft(midDraft.localDraftId);
        expect(done!.dispatchState, CommandDispatchState.confirmedCommitted);
        expect(done.serverAssessmentId, equals(midDraft.serverAssessmentId));
        expect(done.createCommandId, equals(midDraft.createCommandId));
        expect(done.submitCommandId, equals(midDraft.submitCommandId));
        expect(done.evidenceId, equals(midDraft.evidenceId));
      },
    );

    testWidgets(
      'Matrix 5: CAS persistence failures prevent speculative downstream RPCs in UI',
      (tester) async {
        final spyStore = _InterceptableSqliteDraftStore(appDatabase);
        spyStore.onPersistServerAssessmentIdOverride = () async =>
            const DraftCasResult(
              status: DraftCasStatus.casConflict,
              reason: 'Simulated CAS failure on persistServerAssessmentId',
            );

        final picker = SimulatedEvidencePickerService(
          stubFile: SelectedEvidenceFile(
            fileName: 'cas_abort.jpg',
            bytes: validJpegBytes,
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(
          buildRoutedApp(customDraftStore: spyStore, customPicker: picker),
        );
        await tester.pumpAndSettle();

        await fillRequiredForm(tester, title: 'CAS Persist Failure');
        await tapButton(tester, 'attach_evidence_button');
        await tapButton(tester, 'submit_assessment_button');

        expect(find.byType(AddAssessmentScreen), findsOneWidget);
        expect(find.text('HOME_ROUTE'), findsNothing);
        expect(
          find.textContaining('Could not safely update your local draft state'),
          findsOneWidget,
        );

        // No speculative upload, registration, or submit RPCs executed
        expect(repo.createDraftCalls, equals(1));
        expect(storage.uploadCallCount, equals(0));
        expect(repo.registerEvidenceCalls, equals(0));
        expect(repo.submitAssessmentCalls, equals(0));
      },
    );

    testWidgets(
      'Matrix 6: CAS completion failure after server submit surfaces reconciliation-pending state without false completion',
      (tester) async {
        final spyStore = _InterceptableSqliteDraftStore(appDatabase);
        spyStore.onCompleteDraftSubmissionOverride = () async =>
            const DraftCasResult(
              status: DraftCasStatus.leaseConflict,
              reason: 'Simulated completion failure after remote submit',
            );

        final picker = SimulatedEvidencePickerService(
          stubFile: SelectedEvidenceFile(
            fileName: 'reconcile_pending.jpg',
            bytes: validJpegBytes,
            mediaType: 'image/jpeg',
          ),
        );

        await tester.pumpWidget(
          buildRoutedApp(customDraftStore: spyStore, customPicker: picker),
        );
        await tester.pumpAndSettle();

        await fillRequiredForm(tester, title: 'Completion CAS Failure');
        await tapButton(tester, 'attach_evidence_button');
        await tapButton(tester, 'submit_assessment_button');

        // Screen remains open, no false success message, safe reconciliation-pending notice shown
        expect(find.byType(AddAssessmentScreen), findsOneWidget);
        expect(find.text('HOME_ROUTE'), findsNothing);
        expect(find.text('Assessment submitted for review!'), findsNothing);
        expect(
          find.textContaining('pending local sync confirmation'),
          findsOneWidget,
        );

        final persisted = (await appDatabase.listLocalDrafts(testChild.id))
            .single;
        expect(
          persisted.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );
        expect(
          persisted.submissionStatus,
          DraftSubmissionStatus.submittingAssessment,
        );
        expect(persisted.serverAssessmentId, isNotNull);
        expect(persisted.serverEvidenceId, isNotNull);
        expect(persisted.leaseToken, isNull);
        expect(
          persisted.recoveryDispositionAt(
            now: DateTime.utc(2026, 11, 14, 10, 0),
          ),
          DraftRecoveryDisposition.verificationPending,
        );
        expect(
          await fileStore.readVerifiedCanonicalSnapshot(draft: persisted),
          isNotNull,
        );
      },
    );

    testWidgets(
      'Matrix 7: Missing local journal fails closed with zero remote RPCs',
      (tester) async {
        final unpersistedDraft = LocalAssessmentDraft(
          localDraftId: 'missing-journal-id-7',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          actorUserId: 'parent-actor-1',
          createCommandId: 'cmd-c-missing',
          submitCommandId: 'cmd-s-missing',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Missing SQLite Journal',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8.0,
          maxScore: 10.0,
          occurredAt: baseTime,
          updatedAt: baseTime,
          dispatchState: CommandDispatchState.neverDispatched,
        );

        // Notice unpersistedDraft is NEVER inserted into appDatabase
        await tester.pumpWidget(buildRoutedApp(initialDraft: unpersistedDraft));
        await tester.pumpAndSettle();

        await tapButton(tester, 'submit_assessment_button');

        expect(find.byType(AddAssessmentScreen), findsOneWidget);
        expect(
          find.textContaining('Local draft record is missing from storage'),
          findsOneWidget,
        );
        expect(repo.createDraftCalls, equals(0));
        expect(storage.uploadCallCount, equals(0));
        expect(repo.registerEvidenceCalls, equals(0));
        expect(repo.submitAssessmentCalls, equals(0));
      },
    );

    test('Matrix 8: Concurrent SQLite connections enforce single-winner lease and fence stale worker across submission/completion', () async {
      final conn1 = appDatabase;
      final conn2 = AppDatabase(NativeDatabase(dbFile));
      addTearDown(() async => conn2.close());

      const draftId = 'sqlite-concurrent-submit-1';
      final snap = await fileStore.saveCanonicalEvidenceSnapshot(
        localDraftId: draftId,
        bytes: validJpegBytes,
      );
      final initial = LocalAssessmentDraft(
        localDraftId: draftId,
        familyId: testFamily.id.value,
        childId: testChild.id.value,
        actorUserId: 'parent-actor-1',
        createCommandId: 'cmd-conc-create-1',
        submitCommandId: 'cmd-conc-submit-1',
        evidenceId: 'evi-conc-1',
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Concurrent SQLite Draft',
        assessmentType: 'quiz',
        difficulty: 'normal',
        rawScore: 9.0,
        maxScore: 10.0,
        localCompressedPhotoPath: snap.filePath,
        sha256Checksum: snap.sha256Checksum,
        occurredAt: baseTime,
        updatedAt: baseTime,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      expect(
        (await conn1.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: initial,
          now: baseTime,
        )).isSuccess,
        isTrue,
      );

      // Single-winner lease across two connections
      final claimResults = await Future.wait([
        conn1.acquireDraftClaim(
          localDraftId: draftId,
          actorUserId: 'parent-actor-1',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          leaseDuration: const Duration(minutes: 2),
          now: baseTime,
          overrideLeaseToken: 'lease-worker-1',
        ),
        conn2.acquireDraftClaim(
          localDraftId: draftId,
          actorUserId: 'parent-actor-1',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          leaseDuration: const Duration(minutes: 2),
          now: baseTime,
          overrideLeaseToken: 'lease-worker-2',
        ),
      ]);
      expect(
        claimResults.where((r) => r.status == DraftCasStatus.succeeded).length,
        equals(1),
      );
      expect(
        claimResults
            .where((r) => r.status == DraftCasStatus.leaseConflict)
            .length,
        equals(1),
      );

      // Release and simulate Worker A paused mid-flight inside SubmitAssessmentDraft
      final activeLease = claimResults
          .firstWhere((r) => r.isSuccess)
          .draft!
          .leaseToken!;
      await conn1.releaseDraftClaim(
        localDraftId: draftId,
        leaseToken: activeLease,
        authenticatedActorId: 'parent-actor-1',
        now: baseTime,
      );

      final workerAClock = _ManualClock(
        baseTime.add(const Duration(seconds: 5)),
      );
      final workerBClock = _ManualClock(
        baseTime.add(const Duration(minutes: 5)),
      );

      final enteredDispatchBarrier = Completer<void>();
      final releaseDispatchBarrier = Completer<void>();
      final workerAStore = _FencedBarrierStore(
        conn1,
        onAfterMarkDispatch: () async {
          enteredDispatchBarrier.complete();
          await releaseDispatchBarrier.future;
        },
      );

      final workerA = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        authSessionPort: authPort,
        localDraftStore: workerAStore,
        canonicalSnapshotStore: fileStore,
        clock: workerAClock,
      );

      final workerAFuture = expectLater(
        () => workerA(
          createCommandId: 'cmd-conc-create-1',
          submitCommandId: 'cmd-conc-submit-1',
          familyId: testFamily.id,
          childId: testChild.id,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Concurrent SQLite Draft',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          localDraftId: draftId,
        ),
        throwsA(
          isA<DraftSubmissionCasException>().having(
            (e) => e.casStatus,
            'casStatus',
            anyOf(
              DraftCasStatus.leaseConflict,
              DraftCasStatus.alreadyCommitted,
            ),
          ),
        ),
      );

      await enteredDispatchBarrier.future;

      // Worker A's lease expired -> Worker B takes over on conn2 and completes submission!
      final takeover = await conn2.resumeDraftClaimAfterExpiry(
        localDraftId: draftId,
        actorUserId: 'parent-actor-1',
        familyId: testFamily.id.value,
        childId: testChild.id.value,
        leaseDuration: const Duration(minutes: 2),
        now: workerBClock.now(),
        overrideLeaseToken: 'lease-worker-b-takeover',
      );
      expect(takeover.isSuccess, isTrue);

      // Complete via Worker B using same conn2 lease
      final draftB = await repo.createDraft(
        commandId: 'cmd-conc-create-1',
        familyId: testFamily.id,
        childId: testChild.id,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Concurrent SQLite Draft',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9, maxScore: 10),
      );
      await conn2.persistServerAssessmentId(
        localDraftId: draftId,
        leaseToken: 'lease-worker-b-takeover',
        authenticatedActorId: 'parent-actor-1',
        serverAssessmentId: draftB.id.value,
        now: workerBClock.now(),
      );
      final completeB = await conn2.completeDraftSubmission(
        localDraftId: draftId,
        leaseToken: 'lease-worker-b-takeover',
        authenticatedActorId: 'parent-actor-1',
        serverAssessmentId: draftB.id.value,
        now: workerBClock.now(),
      );
      expect(completeB.isSuccess, isTrue);

      // Resume stale Worker A -> must fail fenced on persistServerAssessmentId & never clobber Worker B
      releaseDispatchBarrier.complete();
      await workerAFuture;

      final finalRow = await conn2.getLocalDraft(draftId);
      expect(finalRow!.dispatchState, CommandDispatchState.confirmedCommitted);
      expect(finalRow.serverAssessmentId, equals(draftB.id.value));
      expect(repo.assessments.length, equals(1));
    });

    testWidgets(
      'Matrix 9: App restart preserves canonical snapshot & pending state without duplicate commands or actor adoption',
      (tester) async {
        const draftId = 'restart-draft-1';
        final snap = await fileStore.saveCanonicalEvidenceSnapshot(
          localDraftId: draftId,
          bytes: validPngBytes,
        );
        final seeded = LocalAssessmentDraft(
          localDraftId: draftId,
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          actorUserId: 'parent-actor-1',
          createCommandId: 'cmd-restart-create-1',
          submitCommandId: 'cmd-restart-submit-1',
          evidenceId: '550e8400-e29b-41d4-a716-446655440999',
          subjectKey: SubjectKey.science,
          subject: 'Science',
          title: 'Restart Resilience',
          assessmentType: 'homework',
          difficulty: 'normal',
          rawScore: 8.0,
          maxScore: 10.0,
          localCompressedPhotoPath: snap.filePath,
          sha256Checksum: snap.sha256Checksum,
          occurredAt: baseTime,
          updatedAt: baseTime,
        );
        expect(
          (await appDatabase.registerOrUpdateDraftIfUnchanged(
            expected: null,
            desired: seeded,
            now: baseTime,
          )).isSuccess,
          isTrue,
        );

        // Seed an unbound-actor legacy row to confirm no adoption across restart
        await appDatabase.saveLocalDraft(
          LocalAssessmentDraft(
            localDraftId: 'restart-unbound-legacy',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Unbound Row',
            assessmentType: 'quiz',
            difficulty: 'normal',
            rawScore: 5.0,
            maxScore: 10.0,
            occurredAt: baseTime,
            updatedAt: baseTime,
            actorUserId: null,
          ),
        );

        // First launch hits lost register response mid-flight
        repo.nextRegisterError = StateError('App terminated mid-registration');
        await tester.pumpWidget(buildRoutedApp(initialDraft: seeded));
        await tester.pumpAndSettle();
        await tapButton(tester, 'submit_assessment_button');

        expect(find.byType(AddAssessmentScreen), findsOneWidget);
        expect(repo.assessments.length, equals(1));
        final preRestartServerId = repo.assessments.keys.single;

        // Simulate full app restart (close DB, reopen fresh AppDatabase + fresh DefaultLocalEvidenceFileStore)
        await appDatabase.close();
        appDatabase = AppDatabase(NativeDatabase(dbFile));
        final restartedFileStore = DefaultLocalEvidenceFileStore(
          baseDirectory: tempDir,
        );

        final reopenedDraft = await appDatabase.getLocalDraft(draftId);
        expect(reopenedDraft, isNotNull);
        expect(
          reopenedDraft!.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );
        expect(reopenedDraft.createCommandId, equals('cmd-restart-create-1'));
        expect(reopenedDraft.submitCommandId, equals('cmd-restart-submit-1'));
        expect(reopenedDraft.serverAssessmentId, equals(preRestartServerId));
        expect(reopenedDraft.actorUserId, equals('parent-actor-1'));
        expect(reopenedDraft.leaseToken, isNull);

        // Unbound-actor row stayed quarantined across restart
        final unboundAfterRestart = await appDatabase.getLocalDraft(
          'restart-unbound-legacy',
        );
        expect(unboundAfterRestart!.hasUnboundActor, isTrue);
        expect(unboundAfterRestart.isReadOnlyQuarantined, isTrue);

        // Different authenticated actor cannot adopt or submit reopened draft
        final wrongActorAuth = FakeAuthSessionPort(
          activeUserId: 'parent-actor-2',
          sessionGeneration: 'gen-other-1',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          buildRoutedApp(
            initialDraft: reopenedDraft,
            customFileStore: restartedFileStore,
            customAuth: wrongActorAuth,
          ),
        );
        await tester.pumpAndSettle();
        await tapButton(tester, 'submit_assessment_button');
        expect(find.byType(AddAssessmentScreen), findsOneWidget);
        expect(
          find.textContaining('session is no longer valid'),
          findsOneWidget,
        );
        expect(repo.submitAssessmentCalls, equals(0));

        // Original actor resumes after restart -> single server assessment, confirmedCommitted
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          buildRoutedApp(
            initialDraft: reopenedDraft,
            customFileStore: restartedFileStore,
          ),
        );
        await tester.pumpAndSettle();
        await tapButton(tester, 'submit_assessment_button');

        expect(find.text('HOME_ROUTE'), findsOneWidget);
        expect(repo.assessments.length, equals(1));
        final committed = await appDatabase.getLocalDraft(draftId);
        expect(
          committed!.dispatchState,
          CommandDispatchState.confirmedCommitted,
        );
        expect(committed.serverAssessmentId, equals(preRestartServerId));
        expect(committed.serverEvidenceId, isNotNull);
      },
    );

    testWidgets(
      'R31-08 UI guard: ignores spoofed cached currentUserIdProvider when live authSessionPort is signed out or mismatched',
      (tester) async {
        final signedOutAuth = FakeAuthSessionPort(activeUserId: null);

        final mismatchedRouter = GoRouter(
          initialLocation: '/add',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) =>
                  const Scaffold(body: Center(child: Text('HOME_ROUTE'))),
              routes: [
                GoRoute(
                  path: 'add',
                  builder: (_, _) => const AddAssessmentScreen(),
                ),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              // Cached UI provider still holds an old userId even though live port is signed out
              currentUserIdProvider.overrideWithValue('parent-actor-1'),
              authSessionPortProvider.overrideWithValue(signedOutAuth),
              localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
              growthRepositoryProvider.overrideWithValue(fakeGrowthRepo),
              familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
              childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
              assessmentRepositoryProvider.overrideWithValue(repo),
              assessmentEvidenceStorageProvider.overrideWithValue(storage),
              localEvidenceFileStoreProvider.overrideWithValue(fileStore),
              localDraftStoreProvider.overrideWithValue(appDatabase),
              activeFamilyProvider.overrideWith(
                () => _PresetFamilyNotifier(testFamily),
              ),
              activeChildModeProvider.overrideWith(
                () => _PresetActiveChildNotifier(testChild),
              ),
              evidencePickerServiceProvider.overrideWithValue(
                SimulatedEvidencePickerService(),
              ),
            ],
            child: MaterialApp.router(routerConfig: mismatchedRouter),
          ),
        );
        await tester.pumpAndSettle();

        await fillRequiredForm(tester, title: 'Spoofed Provider Draft');
        await tapButton(tester, 'submit_assessment_button');

        expect(find.byType(AddAssessmentScreen), findsOneWidget);
        expect(find.text('HOME_ROUTE'), findsNothing);
        expect(
          find.textContaining('session is no longer valid'),
          findsOneWidget,
        );
        expect(repo.createDraftCalls, equals(0));
        expect(await appDatabase.listLocalDrafts(testChild.id), isEmpty);
      },
    );
  });
}

final class _FencedBarrierStore extends _InterceptableSqliteDraftStore {
  _FencedBarrierStore(super.inner, {required this.onAfterMarkDispatch});

  final Future<void> Function() onAfterMarkDispatch;
  var _fired = false;

  @override
  Future<DraftCasResult> markDraftStageAndDispatch({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DraftSubmissionStatus targetStage,
    required DateTime now,
  }) async {
    final res = await super.markDraftStageAndDispatch(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      targetStage: targetStage,
      now: now,
    );
    if (!_fired && res.isSuccess) {
      _fired = true;
      await onAfterMarkDispatch();
    }
    return res;
  }
}
