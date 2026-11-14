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
  _SpyAssessmentRepository({super.activeActorIdProvider});

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
  Future<DraftCasResult?> Function(String localDraftId)?
  onAcquireDraftClaimOverride;
  Future<DraftCasResult?> Function()? onPersistServerAssessmentIdOverride;
  Future<DraftCasResult?> Function()? onCompleteDraftSubmissionOverride;

  int markDraftStageCallCount = 0;
  int releaseDraftClaimCallCount = 0;
  String? lastReleasedLeaseToken;

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
    bool ignoreRetryBackoff = false,
  }) async {
    final override = await onAcquireDraftClaimOverride?.call(localDraftId);
    if (override != null) return override;
    return inner.acquireDraftClaim(
      localDraftId: localDraftId,
      actorUserId: actorUserId,
      familyId: familyId,
      childId: childId,
      leaseDuration: leaseDuration,
      now: now,
      overrideLeaseToken: overrideLeaseToken,
      ignoreRetryBackoff: ignoreRetryBackoff,
    );
  }

  @override
  Future<DraftCasResult> resumeDraftClaimAfterExpiry({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    required DateTime now,
    String? overrideLeaseToken,
    bool ignoreRetryBackoff = false,
  }) => inner.resumeDraftClaimAfterExpiry(
    localDraftId: localDraftId,
    actorUserId: actorUserId,
    familyId: familyId,
    childId: childId,
    leaseDuration: leaseDuration,
    now: now,
    overrideLeaseToken: overrideLeaseToken,
    ignoreRetryBackoff: ignoreRetryBackoff,
  );

  @override
  Future<DraftCasResult> markDraftStageAndDispatch({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DraftSubmissionStatus targetStage,
    required DateTime now,
  }) {
    markDraftStageCallCount++;
    return inner.markDraftStageAndDispatch(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      targetStage: targetStage,
      now: now,
    );
  }

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
  }) {
    releaseDraftClaimCallCount++;
    lastReleasedLeaseToken = leaseToken;
    return inner.releaseDraftClaim(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      now: now,
    );
  }

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

final class _QueueEvidencePickerService implements EvidencePickerService {
  _QueueEvidencePickerService(List<SelectedEvidenceFile?> selections)
    : _queue = List<SelectedEvidenceFile?>.from(selections);

  final List<SelectedEvidenceFile?> _queue;

  @override
  Future<SelectedEvidenceFile?> pickEvidencePhoto() async {
    if (_queue.isEmpty) return null;
    return _queue.removeAt(0);
  }
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
      authPort = FakeAuthSessionPort(
        activeUserId: 'parent-actor-1',
        sessionGeneration: 'gen-matrix-1',
      );
      repo = _SpyAssessmentRepository(
        activeActorIdProvider: () => authPort.currentContext?.userId,
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

    group('R33-07: Claimed SQLite Journal Payload Binding & Fencing', () {
      test('two-connection SQLite race: conn2 update between initial read and conn1 claim fails closed before markDraftStageAndDispatch and releases only own lease token', () async {
        const draftId = 'draft-r33-07-sqlite-1';
        final snap = await fileStore.saveCanonicalEvidenceSnapshot(
          localDraftId: draftId,
          bytes: validJpegBytes,
        );
        final initial = LocalAssessmentDraft(
          localDraftId: draftId,
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          actorUserId: 'parent-actor-1',
          createCommandId: 'cmd-r3307-create-1',
          submitCommandId: 'cmd-r3307-submit-1',
          evidenceId: 'evi-r3307-1',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Worker1 Original Title',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 9,
          maxScore: 10,
          localCompressedPhotoPath: snap.filePath,
          sha256Checksum: snap.sha256Checksum,
          occurredAt: baseTime,
          updatedAt: baseTime,
          entryContext: EntryContext.sharedChild,
        );
        final seedRes = await appDatabase.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: initial,
          now: baseTime,
        );
        expect(seedRes.isSuccess, isTrue);

        final conn2 = AppDatabase(NativeDatabase(dbFile));
        addTearDown(conn2.close);

        final spyConn1 = _InterceptableSqliteDraftStore(appDatabase);
        String? capturedOwnLeaseToken;
        var injected = false;
        spyConn1.onAcquireDraftClaimOverride = (id) async {
          if (!injected && id == draftId) {
            injected = true;
            final mutated = initial.copyWith(
              subjectKey: SubjectKey.science,
              subject: 'Science',
              title: 'Conn2 Updated Title',
              assessmentType: AssessmentType.homework.name,
              difficulty: AssessmentDifficulty.hard.name,
              rawScore: 7,
              maxScore: 10,
              occurredAt: baseTime.add(const Duration(minutes: 5)),
              updatedAt: baseTime.add(const Duration(minutes: 5)),
              entryContext: EntryContext.adult,
            );
            final conn2Update = await conn2.registerOrUpdateDraftIfUnchanged(
              expected: initial,
              desired: mutated,
              now: baseTime.add(const Duration(minutes: 5)),
            );
            expect(conn2Update.isSuccess, isTrue);

            spyConn1.onAcquireDraftClaimOverride = null;
            final claimRes = await appDatabase.acquireDraftClaim(
              localDraftId: id,
              actorUserId: 'parent-actor-1',
              familyId: testFamily.id.value,
              childId: testChild.id.value,
              leaseDuration: const Duration(minutes: 2),
              now: baseTime.add(const Duration(minutes: 6)),
            );
            capturedOwnLeaseToken = claimRes.draft?.leaseToken;
            return claimRes;
          }
          return null;
        };

        final useCase = SubmitAssessmentDraft(
          repository: repo,
          storage: storage,
          authSessionPort: authPort,
          recoveryAuthorizationPort: FakeRecoveryAuthorizationPort(),
          localDraftStore: spyConn1,
          canonicalSnapshotStore: fileStore,
        );

        await expectLater(
          () => useCase(
            createCommandId: 'cmd-r3307-create-1',
            submitCommandId: 'cmd-r3307-submit-1',
            familyId: testFamily.id,
            childId: testChild.id,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Worker1 Original Title',
            type: AssessmentType.quiz,
            difficulty: AssessmentDifficulty.normal,
            score: AssessmentScore(rawScore: 9, maxScore: 10),
            occurredAt: baseTime,
            entryContext: EntryContext.sharedChild,
            evidenceId: EvidenceId('evi-r3307-1'),
            localDraftId: draftId,
          ),
          throwsA(
            isA<DraftSubmissionCasException>()
                .having(
                  (e) => e.stage,
                  'stage',
                  DraftCasFailureStage.acquireLease,
                )
                .having(
                  (e) => e.casStatus,
                  'casStatus',
                  DraftCasStatus.casConflict,
                ),
          ),
        );

        expect(capturedOwnLeaseToken, isNotNull);
        expect(spyConn1.markDraftStageCallCount, equals(0));
        expect(spyConn1.releaseDraftClaimCallCount, equals(1));
        expect(spyConn1.lastReleasedLeaseToken, equals(capturedOwnLeaseToken));
        expect(repo.createDraftCalls, equals(0));
        expect(storage.uploadCallCount, equals(0));
        expect(repo.registerEvidenceCalls, equals(0));
        expect(repo.submitAssessmentCalls, equals(0));

        final persisted = await conn2.getLocalDraft(draftId);
        expect(persisted, isNotNull);
        expect(persisted!.title, equals('Conn2 Updated Title'));
        expect(persisted.subject, equals('Science'));
        expect(persisted.subjectKey, equals(SubjectKey.science));
        expect(persisted.rawScore, equals(7));
        expect(
          persisted.occurredAt,
          equals(baseTime.add(const Duration(minutes: 5))),
        );
        expect(persisted.entryContext, equals(EntryContext.adult));
        expect(persisted.createCommandId, equals('cmd-r3307-create-1'));
        expect(persisted.submitCommandId, equals('cmd-r3307-submit-1'));
        expect(persisted.evidenceId, equals('evi-r3307-1'));
        expect(persisted.dispatchState, CommandDispatchState.neverDispatched);
        expect(persisted.leaseToken, isNull);
        expect(File(snap.filePath).existsSync(), isTrue);

        // Verify SQLite token-fenced lease release cannot clobber another
        // connection's active lease token.
        final conn2Claim = await conn2.acquireDraftClaim(
          localDraftId: draftId,
          actorUserId: 'parent-actor-1',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          leaseDuration: const Duration(minutes: 2),
          overrideLeaseToken: 'conn2-active-token',
        );
        expect(conn2Claim.isSuccess, isTrue);

        final wrongRelease = await appDatabase.releaseDraftClaim(
          localDraftId: draftId,
          leaseToken: capturedOwnLeaseToken!,
          authenticatedActorId: 'parent-actor-1',
        );
        expect(wrongRelease.status, DraftCasStatus.leaseConflict);
        final stillOwnedByConn2 = await conn2.getLocalDraft(draftId);
        expect(stillOwnedByConn2!.leaseToken, equals('conn2-active-token'));
      });

      test('two-connection SQLite race: conn2 attaches canonical snapshot after photo-less getLocalDraft fails closed before markDraftStageAndDispatch', () async {
        const draftId = 'draft-r33-07-sqlite-snap-race';
        final photoLessInitial = LocalAssessmentDraft(
          localDraftId: draftId,
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          actorUserId: 'parent-actor-1',
          createCommandId: 'cmd-r3307-snap-create',
          submitCommandId: 'cmd-r3307-snap-submit',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Photo-less When Started',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8,
          maxScore: 10,
          occurredAt: baseTime,
          updatedAt: baseTime,
          entryContext: EntryContext.sharedChild,
        );
        expect(
          (await appDatabase.registerOrUpdateDraftIfUnchanged(
            expected: null,
            desired: photoLessInitial,
            now: baseTime,
          )).isSuccess,
          isTrue,
        );

        final conn2 = AppDatabase(NativeDatabase(dbFile));
        addTearDown(conn2.close);

        final snap = await fileStore.saveCanonicalEvidenceSnapshot(
          localDraftId: draftId,
          bytes: validPngBytes,
        );

        final spyConn1 = _InterceptableSqliteDraftStore(appDatabase);
        var injected = false;
        spyConn1.onAcquireDraftClaimOverride = (id) async {
          if (!injected && id == draftId) {
            injected = true;
            final withSnapshot = photoLessInitial.copyWith(
              evidenceId: 'evi-added-by-conn2',
              localCompressedPhotoPath: snap.filePath,
              sha256Checksum: snap.sha256Checksum,
              updatedAt: baseTime.add(const Duration(seconds: 30)),
            );
            final updateRes = await conn2.registerOrUpdateDraftIfUnchanged(
              expected: photoLessInitial,
              desired: withSnapshot,
              now: baseTime.add(const Duration(seconds: 30)),
            );
            expect(updateRes.isSuccess, isTrue);
            spyConn1.onAcquireDraftClaimOverride = null;
            return appDatabase.acquireDraftClaim(
              localDraftId: id,
              actorUserId: 'parent-actor-1',
              familyId: testFamily.id.value,
              childId: testChild.id.value,
              leaseDuration: const Duration(minutes: 2),
              now: baseTime.add(const Duration(minutes: 1)),
            );
          }
          return null;
        };

        final useCase = SubmitAssessmentDraft(
          repository: repo,
          storage: storage,
          authSessionPort: authPort,
          recoveryAuthorizationPort: FakeRecoveryAuthorizationPort(),
          localDraftStore: spyConn1,
          canonicalSnapshotStore: fileStore,
        );

        await expectLater(
          () => useCase(
            createCommandId: 'cmd-r3307-snap-create',
            submitCommandId: 'cmd-r3307-snap-submit',
            familyId: testFamily.id,
            childId: testChild.id,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Photo-less When Started',
            type: AssessmentType.quiz,
            difficulty: AssessmentDifficulty.normal,
            score: AssessmentScore(rawScore: 8, maxScore: 10),
            occurredAt: baseTime,
            entryContext: EntryContext.sharedChild,
            localDraftId: draftId,
          ),
          throwsA(
            isA<DraftSubmissionCasException>().having(
              (e) => e.casStatus,
              'casStatus',
              DraftCasStatus.casConflict,
            ),
          ),
        );

        expect(spyConn1.markDraftStageCallCount, equals(0));
        expect(repo.createDraftCalls, equals(0));
        expect(storage.uploadCallCount, equals(0));

        final persisted = await conn2.getLocalDraft(draftId);
        expect(persisted!.evidenceId, equals('evi-added-by-conn2'));
        expect(persisted.sha256Checksum, equals(snap.sha256Checksum));
        expect(persisted.leaseToken, isNull);
        expect(File(snap.filePath).existsSync(), isTrue);
      });
    });

    group(
      'R33-08: Frozen Evidence Immutability UI & End-to-End Regression',
      () {
        testWidgets(
          'frozen JPEG draft rejects different JPEG selection via change_evidence_button, keeps UI/IDs/files intact with zero upload',
          (tester) async {
            const draftId = 'draft-frozen-jpeg-replace';
            final snap = await fileStore.saveCanonicalEvidenceSnapshot(
              localDraftId: draftId,
              bytes: validJpegBytes,
            );
            final originalCanonicalName = snap.filePath
                .split(RegExp(r'[/\\]'))
                .last;
            final rawOriginalPath = await fileStore.saveEvidence(
              fileName: 'raw_original.jpg',
              bytes: validJpegBytes,
            );
            final seeded = LocalAssessmentDraft(
              localDraftId: draftId,
              familyId: testFamily.id.value,
              childId: testChild.id.value,
              actorUserId: 'parent-actor-1',
              createCommandId: 'cmd-frozen-jpg-create',
              submitCommandId: 'cmd-frozen-jpg-submit',
              evidenceId: 'evi-frozen-jpg-1',
              subjectKey: SubjectKey.math,
              subject: 'Math',
              title: 'Locked JPEG Draft',
              assessmentType: 'quiz',
              difficulty: 'normal',
              rawScore: 9,
              maxScore: 10,
              localPhotoPath: rawOriginalPath,
              localCompressedPhotoPath: snap.filePath,
              sha256Checksum: snap.sha256Checksum,
              occurredAt: baseTime,
              updatedAt: baseTime,
              entryContext: EntryContext.sharedChild,
            );
            await appDatabase.registerOrUpdateDraftIfUnchanged(
              expected: null,
              desired: seeded,
              now: baseTime,
            );

            final pickedReplacementFile = File(
              '${tempDir.path}/picked_other_photo.jpg',
            )..writeAsBytesSync(<int>[...validJpegBytes, 0xAA, 0xBB]);
            final picker = _QueueEvidencePickerService([
              SelectedEvidenceFile(
                fileName: 'picked_other_photo.jpg',
                bytes: pickedReplacementFile.readAsBytesSync(),
                mediaType: 'image/jpeg',
                localPath: pickedReplacementFile.path,
              ),
            ]);

            await tester.pumpWidget(
              buildRoutedApp(initialDraft: seeded, customPicker: picker),
            );
            await tester.pumpAndSettle();

            expect(
              find.byKey(const Key('frozen_evidence_locked_hint')),
              findsOneWidget,
            );
            expect(find.textContaining(originalCanonicalName), findsOneWidget);

            // Attempt to replace the frozen JPEG with a different JPEG.
            await tapButton(tester, 'change_evidence_button');

            expect(
              find.textContaining(
                'Evidence photo is already locked for this draft',
              ),
              findsOneWidget,
            );
            expect(find.textContaining(originalCanonicalName), findsOneWidget);
            expect(find.textContaining('picked_other_photo.jpg'), findsNothing);

            expect(storage.uploadCallCount, equals(0));
            expect(repo.createDraftCalls, equals(0));
            expect(repo.registerEvidenceCalls, equals(0));
            expect(repo.submitAssessmentCalls, equals(0));

            final afterAttempt = await appDatabase.getLocalDraft(draftId);
            expect(afterAttempt!.evidenceId, equals('evi-frozen-jpg-1'));
            expect(
              afterAttempt.createCommandId,
              equals('cmd-frozen-jpg-create'),
            );
            expect(
              afterAttempt.submitCommandId,
              equals('cmd-frozen-jpg-submit'),
            );
            expect(afterAttempt.sha256Checksum, equals(snap.sha256Checksum));
            expect(File(snap.filePath).existsSync(), isTrue);
            expect(File(rawOriginalPath).existsSync(), isTrue);
            expect(pickedReplacementFile.existsSync(), isTrue);
            final verifiedSnap = await fileStore.readVerifiedCanonicalSnapshot(
              draft: afterAttempt,
            );
            expect(verifiedSnap.bytes, equals(validJpegBytes));
          },
        );

        testWidgets(
          'in-screen freeze after interrupted submit locks evidence and rejects different photo selection with zero extra RPC',
          (tester) async {
            final pickedOther = File('${tempDir.path}/after_freeze_other.jpg')
              ..writeAsBytesSync(<int>[...validJpegBytes, 0xCC, 0xDD]);
            final picker = _QueueEvidencePickerService([
              SelectedEvidenceFile(
                fileName: 'in_screen_frozen.jpg',
                bytes: validJpegBytes,
                mediaType: 'image/jpeg',
              ),
              SelectedEvidenceFile(
                fileName: 'after_freeze_other.jpg',
                bytes: pickedOther.readAsBytesSync(),
                mediaType: 'image/jpeg',
                localPath: pickedOther.path,
              ),
            ]);
            repo.nextRegisterError = StateError('Simulated offline failure');

            await tester.pumpWidget(buildRoutedApp(customPicker: picker));
            await tester.pumpAndSettle();

            await fillRequiredForm(tester, title: 'In-Screen Freeze Draft');
            await tapButton(tester, 'attach_evidence_button');
            await tapButton(tester, 'submit_assessment_button');

            final uploadsAtFailure = storage.uploadCallCount;
            final createsAtFailure = repo.createDraftCalls;
            final registersAtFailure = repo.registerEvidenceCalls;
            final submitsAtFailure = repo.submitAssessmentCalls;

            final frozen = (await appDatabase.listLocalDrafts(testChild.id))
                .single;
            expect(frozen.hasVerifiedEvidenceSnapshot, isTrue);
            expect(
              find.byKey(const Key('frozen_evidence_locked_hint')),
              findsOneWidget,
            );
            expect(find.textContaining('in_screen_frozen.jpg'), findsOneWidget);

            // R33-09: Interrupted submit transitions the in-screen draft to possibly_dispatched,
            // locking evidence editing buttons as well as payload controls immediately.
            final changeButton = tester.widget<IconButton>(
              find.byKey(const Key('change_evidence_button')),
            );
            final removeButton = tester.widget<IconButton>(
              find.byKey(const Key('remove_evidence_button')),
            );
            expect(changeButton.onPressed, isNull);
            expect(removeButton.onPressed, isNull);

            await tapButton(tester, 'change_evidence_button');

            expect(find.textContaining('in_screen_frozen.jpg'), findsOneWidget);
            expect(find.textContaining('after_freeze_other.jpg'), findsNothing);

            expect(storage.uploadCallCount, equals(uploadsAtFailure));
            expect(repo.createDraftCalls, equals(createsAtFailure));
            expect(repo.registerEvidenceCalls, equals(registersAtFailure));
            expect(repo.submitAssessmentCalls, equals(submitsAtFailure));
            expect(File(frozen.localCompressedPhotoPath!).existsSync(), isTrue);
            expect(pickedOther.existsSync(), isTrue);
          },
        );

        testWidgets(
          'frozen PNG draft rejects different image selection via change_evidence_button, preserves original PNG & newly picked file with zero upload',
          (tester) async {
            const draftId = 'draft-frozen-png-replace';
            final snap = await fileStore.saveCanonicalEvidenceSnapshot(
              localDraftId: draftId,
              bytes: validPngBytes,
            );
            final originalCanonicalName = snap.filePath
                .split(RegExp(r'[/\\]'))
                .last;
            final seeded = LocalAssessmentDraft(
              localDraftId: draftId,
              familyId: testFamily.id.value,
              childId: testChild.id.value,
              actorUserId: 'parent-actor-1',
              createCommandId: 'cmd-frozen-png-create',
              submitCommandId: 'cmd-frozen-png-submit',
              evidenceId: 'evi-frozen-png-1',
              subjectKey: SubjectKey.math,
              subject: 'Math',
              title: 'Locked PNG Draft',
              assessmentType: 'quiz',
              difficulty: 'normal',
              rawScore: 9,
              maxScore: 10,
              localCompressedPhotoPath: snap.filePath,
              sha256Checksum: snap.sha256Checksum,
              occurredAt: baseTime,
              updatedAt: baseTime,
              entryContext: EntryContext.sharedChild,
            );
            await appDatabase.registerOrUpdateDraftIfUnchanged(
              expected: null,
              desired: seeded,
              now: baseTime,
            );

            final pickedOtherPng = File('${tempDir.path}/other_image.png')
              ..writeAsBytesSync(<int>[...validPngBytes, 0x09, 0x0A]);
            final picker = _QueueEvidencePickerService([
              SelectedEvidenceFile(
                fileName: 'other_image.png',
                bytes: pickedOtherPng.readAsBytesSync(),
                mediaType: 'image/png',
                localPath: pickedOtherPng.path,
              ),
            ]);

            await tester.pumpWidget(
              buildRoutedApp(initialDraft: seeded, customPicker: picker),
            );
            await tester.pumpAndSettle();

            expect(find.textContaining(originalCanonicalName), findsOneWidget);

            await tapButton(tester, 'change_evidence_button');

            expect(
              find.textContaining(
                'Evidence photo is already locked for this draft',
              ),
              findsOneWidget,
            );
            expect(find.textContaining(originalCanonicalName), findsOneWidget);
            expect(find.textContaining('other_image.png'), findsNothing);
            expect(storage.uploadCallCount, equals(0));
            expect(repo.createDraftCalls, equals(0));
            expect(repo.registerEvidenceCalls, equals(0));
            expect(repo.submitAssessmentCalls, equals(0));

            final afterAttempt = await appDatabase.getLocalDraft(draftId);
            expect(afterAttempt!.evidenceId, equals('evi-frozen-png-1'));
            expect(afterAttempt.sha256Checksum, equals(snap.sha256Checksum));
            expect(File(snap.filePath).existsSync(), isTrue);
            expect(pickedOtherPng.existsSync(), isTrue);
            final verifiedSnap = await fileStore.readVerifiedCanonicalSnapshot(
              draft: afterAttempt,
            );
            expect(verifiedSnap.bytes, equals(validPngBytes));
          },
        );

        testWidgets(
          'explicit removal of frozen evidence shows clear error, retains displayed attachment/IDs/files with zero remote RPC',
          (tester) async {
            const draftId = 'draft-frozen-remove';
            final snap = await fileStore.saveCanonicalEvidenceSnapshot(
              localDraftId: draftId,
              bytes: validJpegBytes,
            );
            final originalCanonicalName = snap.filePath
                .split(RegExp(r'[/\\]'))
                .last;
            final seeded = LocalAssessmentDraft(
              localDraftId: draftId,
              familyId: testFamily.id.value,
              childId: testChild.id.value,
              actorUserId: 'parent-actor-1',
              createCommandId: 'cmd-frozen-rem-create',
              submitCommandId: 'cmd-frozen-rem-submit',
              evidenceId: 'evi-frozen-rem-1',
              subjectKey: SubjectKey.math,
              subject: 'Math',
              title: 'Locked Remove Check',
              assessmentType: 'quiz',
              difficulty: 'normal',
              rawScore: 9,
              maxScore: 10,
              localCompressedPhotoPath: snap.filePath,
              sha256Checksum: snap.sha256Checksum,
              occurredAt: baseTime,
              updatedAt: baseTime,
              entryContext: EntryContext.sharedChild,
            );
            await appDatabase.registerOrUpdateDraftIfUnchanged(
              expected: null,
              desired: seeded,
              now: baseTime,
            );

            await tester.pumpWidget(buildRoutedApp(initialDraft: seeded));
            await tester.pumpAndSettle();

            expect(find.textContaining(originalCanonicalName), findsOneWidget);

            await tapButton(tester, 'remove_evidence_button');

            expect(
              find.textContaining(
                'Evidence photo is already locked for this draft',
              ),
              findsOneWidget,
            );
            expect(find.textContaining(originalCanonicalName), findsOneWidget);
            expect(
              find.byKey(const Key('frozen_evidence_locked_hint')),
              findsOneWidget,
            );

            expect(storage.uploadCallCount, equals(0));
            expect(repo.createDraftCalls, equals(0));
            expect(repo.registerEvidenceCalls, equals(0));
            expect(repo.submitAssessmentCalls, equals(0));

            final afterAttempt = await appDatabase.getLocalDraft(draftId);
            expect(afterAttempt!.evidenceId, equals('evi-frozen-rem-1'));
            expect(
              afterAttempt.createCommandId,
              equals('cmd-frozen-rem-create'),
            );
            expect(
              afterAttempt.submitCommandId,
              equals('cmd-frozen-rem-submit'),
            );
            expect(afterAttempt.sha256Checksum, equals(snap.sha256Checksum));
            expect(File(snap.filePath).existsSync(), isTrue);
          },
        );

        testWidgets(
          'reopening saved draft with unchanged canonical snapshot preserves IDs and submits exact frozen bytes cleanly',
          (tester) async {
            const draftId = 'draft-reopen-unchanged-snap';
            final snap = await fileStore.saveCanonicalEvidenceSnapshot(
              localDraftId: draftId,
              bytes: validPngBytes,
            );
            final seeded = LocalAssessmentDraft(
              localDraftId: draftId,
              familyId: testFamily.id.value,
              childId: testChild.id.value,
              actorUserId: 'parent-actor-1',
              createCommandId: 'cmd-reopen-create-1',
              submitCommandId: 'cmd-reopen-submit-1',
              evidenceId: 'evi-reopen-1',
              subjectKey: SubjectKey.math,
              subject: 'Math',
              title: 'Reopened Snapshot Quiz',
              assessmentType: 'quiz',
              difficulty: 'normal',
              rawScore: 9,
              maxScore: 10,
              localCompressedPhotoPath: snap.filePath,
              sha256Checksum: snap.sha256Checksum,
              occurredAt: baseTime,
              updatedAt: baseTime,
              entryContext: EntryContext.sharedChild,
            );
            await appDatabase.registerOrUpdateDraftIfUnchanged(
              expected: null,
              desired: seeded,
              now: baseTime,
            );

            await tester.pumpWidget(buildRoutedApp(initialDraft: seeded));
            await tester.pumpAndSettle();

            expect(
              find.byKey(const Key('frozen_evidence_locked_hint')),
              findsOneWidget,
            );
            await tapButton(tester, 'submit_assessment_button');

            expect(find.text('HOME_ROUTE'), findsOneWidget);
            expect(repo.createDraftCalls, equals(1));
            expect(storage.uploadCallCount, equals(1));
            expect(repo.registerEvidenceCalls, equals(1));
            expect(repo.submitAssessmentCalls, equals(1));
            expect(storage.storage.values.single, equals(validPngBytes));

            final committed = await appDatabase.getLocalDraft(draftId);
            expect(
              committed!.dispatchState,
              CommandDispatchState.confirmedCommitted,
            );
            expect(committed.createCommandId, equals('cmd-reopen-create-1'));
            expect(committed.submitCommandId, equals('cmd-reopen-submit-1'));
            expect(committed.evidenceId, equals('evi-reopen-1'));
            expect(committed.sha256Checksum, equals(snap.sha256Checksum));
            expect(committed.serverAssessmentId, isNotNull);
            expect(committed.serverEvidenceId, isNotNull);
          },
        );
      },
    );

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
        recoveryAuthorizationPort: FakeRecoveryAuthorizationPort(),
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
          occurredAt: baseTime,
          evidenceId: EvidenceId('evi-conc-1'),
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
        occurredAt: baseTime,
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

    group('R33-09: Payload Immutability on Dispatched & Locked Drafts', () {
      void expectAllEditingControlsLocked(
        WidgetTester tester, {
        required bool hasAttachedEvidence,
        bool expectSubmitEnabled = false,
      }) {
        expect(
          tester
              .widget<DropdownButtonFormField<SubjectKey>>(
                find.byKey(const Key('assessment_subject_key_dropdown')),
              )
              .onChanged,
          isNull,
        );
        expect(
          tester
              .widget<DropdownButtonFormField<AssessmentType>>(
                find.byKey(const Key('assessment_type_dropdown')),
              )
              .onChanged,
          isNull,
        );
        expect(
          tester
              .widget<DropdownButtonFormField<AssessmentDifficulty>>(
                find.byKey(const Key('assessment_difficulty_dropdown')),
              )
              .onChanged,
          isNull,
        );
        for (final keyName in const [
          'assessment_subject_field',
          'assessment_title_field',
          'assessment_raw_score_field',
          'assessment_max_score_field',
        ]) {
          final field = tester.widget<TextField>(
            find.descendant(
              of: find.byKey(Key(keyName)),
              matching: find.byType(TextField),
            ),
          );
          expect(field.enabled, isFalse, reason: '$keyName must be disabled');
          expect(field.readOnly, isTrue, reason: '$keyName must be readOnly');
        }
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('save_draft_button')),
              )
              .enabled,
          isFalse,
        );
        if (hasAttachedEvidence) {
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const Key('change_evidence_button')),
                )
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<IconButton>(
                  find.byKey(const Key('remove_evidence_button')),
                )
                .onPressed,
            isNull,
          );
        } else {
          expect(
            tester
                .widget<ButtonStyleButton>(
                  find.byKey(const Key('attach_evidence_button')),
                )
                .onPressed,
            isNull,
          );
        }
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('submit_assessment_button')),
              )
              .enabled,
          equals(expectSubmitEnabled),
        );
      }

      Future<LocalAssessmentDraft> insertCleanDraft({
        required String localDraftId,
        required SubjectKey subjectKey,
        required String subject,
        required String title,
        String assessmentType = 'quiz',
        String difficulty = 'normal',
        double rawScore = 8.0,
        double maxScore = 10.0,
        String? createCommandId,
        String? submitCommandId,
        String? evidenceId,
        CanonicalEvidenceSnapshot? snapshot,
      }) async {
        final draft = LocalAssessmentDraft(
          localDraftId: localDraftId,
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          actorUserId: 'parent-actor-1',
          createCommandId: createCommandId ?? 'cmd-$localDraftId-c',
          submitCommandId: submitCommandId ?? 'cmd-$localDraftId-s',
          evidenceId: evidenceId,
          subjectKey: subjectKey,
          subject: subject,
          title: title,
          assessmentType: assessmentType,
          difficulty: difficulty,
          rawScore: rawScore,
          maxScore: maxScore,
          localCompressedPhotoPath: snapshot?.filePath,
          sha256Checksum: snapshot?.sha256Checksum,
          occurredAt: baseTime,
          updatedAt: baseTime,
          dispatchState: CommandDispatchState.neverDispatched,
          entryContext: EntryContext.sharedChild,
        );
        final res = await appDatabase.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: draft,
          now: baseTime,
        );
        expect(res.isSuccess, isTrue, reason: 'Seed failed: ${res.reason}');
        return res.draft!;
      }

      Future<LocalAssessmentDraft> transitionToDispatchedRetryable(
        LocalAssessmentDraft draft,
      ) async {
        final claim = await appDatabase.acquireDraftClaim(
          localDraftId: draft.localDraftId,
          actorUserId: 'parent-actor-1',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          leaseDuration: const Duration(minutes: 5),
          now: baseTime,
        );
        expect(claim.isSuccess, isTrue);
        final dispatched = await appDatabase.markDraftStageAndDispatch(
          localDraftId: draft.localDraftId,
          leaseToken: claim.draft!.leaseToken!,
          authenticatedActorId: 'parent-actor-1',
          targetStage: DraftSubmissionStatus.submittingAssessment,
          now: baseTime,
        );
        expect(dispatched.isSuccess, isTrue);
        final released = await appDatabase.releaseDraftClaim(
          localDraftId: draft.localDraftId,
          leaseToken: claim.draft!.leaseToken!,
          authenticatedActorId: 'parent-actor-1',
          now: baseTime,
        );
        expect(released.isSuccess, isTrue);
        return released.draft!;
      }

      testWidgets(
        'reopened retryable possiblyDispatched draft locks all controls, explains preserved payload, resists edits, and retries exact original payload cleanly',
        (tester) async {
          const draftId = 'draft-r3309-dispatched-retry';
          final snap = await fileStore.saveCanonicalEvidenceSnapshot(
            localDraftId: draftId,
            bytes: validJpegBytes,
          );
          final clean = await insertCleanDraft(
            localDraftId: draftId,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Dispatched Fractions Quiz',
            rawScore: 8.0,
            maxScore: 10.0,
            createCommandId: 'cmd-r3309-create-1',
            submitCommandId: 'cmd-r3309-submit-1',
            evidenceId: 'evi-r3309-1',
            snapshot: snap,
          );
          final seeded = await transitionToDispatchedRetryable(clean);

          await tester.pumpWidget(buildRoutedApp(initialDraft: seeded));
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('payload_locked_banner')),
            findsOneWidget,
          );
          expect(
            find.textContaining('original submitted payload'),
            findsOneWidget,
          );
          expectAllEditingControlsLocked(
            tester,
            hasAttachedEvidence: true,
            expectSubmitEnabled: true,
          );

          await tester.enterText(
            find.byKey(const Key('assessment_title_field')),
            'Attempted Edited Title',
          );
          await tester.enterText(
            find.byKey(const Key('assessment_subject_field')),
            'History',
          );
          await tester.enterText(
            find.byKey(const Key('assessment_raw_score_field')),
            '10',
          );
          await tester.pumpAndSettle();

          expect(find.text('Dispatched Fractions Quiz'), findsOneWidget);
          expect(find.text('Attempted Edited Title'), findsNothing);

          await tapButton(tester, 'submit_assessment_button');

          expect(find.text('HOME_ROUTE'), findsOneWidget);
          expect(repo.assessments.length, equals(1));
          final submitted = repo.assessments.values.single;
          expect(submitted.subjectKey, SubjectKey.math);
          expect(submitted.subject, equals('Math'));
          expect(submitted.title, equals('Dispatched Fractions Quiz'));
          expect(submitted.type, AssessmentType.quiz);
          expect(submitted.difficulty, AssessmentDifficulty.normal);
          expect(submitted.score.rawScore, equals(8.0));
          expect(submitted.score.maxScore, equals(10.0));
          expect(storage.storage.values.single, equals(validJpegBytes));
        },
      );

      testWidgets(
        'confirmedCommitted, leased, quarantined, waitingOriginalActor, terminalError, and retryScheduled drafts lock all editing controls',
        (tester) async {
          final nowUtc = DateTime.now().toUtc();

          // 1. confirmedCommitted
          final c1 = await insertCleanDraft(
            localDraftId: 'draft-r3309-committed',
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Committed Draft',
          );
          final claim1 = await appDatabase.acquireDraftClaim(
            localDraftId: c1.localDraftId,
            actorUserId: 'parent-actor-1',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            leaseDuration: const Duration(minutes: 5),
            now: nowUtc,
          );
          await appDatabase.markDraftStageAndDispatch(
            localDraftId: c1.localDraftId,
            leaseToken: claim1.draft!.leaseToken!,
            authenticatedActorId: 'parent-actor-1',
            targetStage: DraftSubmissionStatus.submittingAssessment,
            now: nowUtc,
          );
          final committed = (await appDatabase.completeDraftSubmission(
            localDraftId: c1.localDraftId,
            leaseToken: claim1.draft!.leaseToken!,
            authenticatedActorId: 'parent-actor-1',
            serverAssessmentId: 'srv-comm-1',
            now: nowUtc,
          )).draft!;

          // 2. active lease
          final c2 = await insertCleanDraft(
            localDraftId: 'draft-r3309-leased',
            subjectKey: SubjectKey.science,
            subject: 'Science',
            title: 'Leased Draft',
            assessmentType: 'homework',
            difficulty: 'hard',
            rawScore: 7,
          );
          final leased = (await appDatabase.acquireDraftClaim(
            localDraftId: c2.localDraftId,
            actorUserId: 'parent-actor-1',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            leaseDuration: const Duration(minutes: 10),
            now: nowUtc,
          )).draft!;

          // 3. malformed lease (quarantined)
          final c3 = await insertCleanDraft(
            localDraftId: 'draft-r3309-quarantined-lease',
            subjectKey: SubjectKey.english,
            subject: 'English',
            title: 'Malformed Lease Draft',
            assessmentType: 'exam',
            difficulty: 'challenge',
          );
          await appDatabase.customStatement(
            "UPDATE local_assessment_drafts "
            "SET lease_token = 'orphan-token', lease_expires_at = NULL "
            "WHERE local_draft_id = 'draft-r3309-quarantined-lease';",
          );
          final malformedLease = (await appDatabase.getLocalDraft(
            c3.localDraftId,
          ))!;

          // 4. waitingOriginalActor
          final c4 = await insertCleanDraft(
            localDraftId: 'draft-r3309-wait-actor',
            subjectKey: SubjectKey.literature,
            subject: 'Literature',
            title: 'Waiting Actor Draft',
            assessmentType: 'practice',
            difficulty: 'normal',
            rawScore: 8.5,
          );
          await transitionToDispatchedRetryable(c4);
          final waitingActor = (await appDatabase.pauseMismatchedActorDraft(
            localDraftId: c4.localDraftId,
            familyId: testFamily.id.value,
            authenticatedActorId: 'parent-actor-2',
            now: nowUtc,
          )).draft!;

          // 5. terminalError
          final c5 = await insertCleanDraft(
            localDraftId: 'draft-r3309-terminal',
            subjectKey: SubjectKey.other,
            subject: 'Other',
            title: 'Terminal Error Draft',
            rawScore: 6,
          );
          final claim5 = await appDatabase.acquireDraftClaim(
            localDraftId: c5.localDraftId,
            actorUserId: 'parent-actor-1',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            leaseDuration: const Duration(minutes: 5),
            now: nowUtc,
          );
          await appDatabase.markDraftStageAndDispatch(
            localDraftId: c5.localDraftId,
            leaseToken: claim5.draft!.leaseToken!,
            authenticatedActorId: 'parent-actor-1',
            targetStage: DraftSubmissionStatus.submittingAssessment,
            now: nowUtc,
          );
          final terminalError = (await appDatabase.quarantineDraftOutcome(
            localDraftId: c5.localDraftId,
            leaseToken: claim5.draft!.leaseToken!,
            authenticatedActorId: 'parent-actor-1',
            recoveryCode: DraftRecoveryCode.unknownWireStatus,
            errorMessage: 'Terminal error',
            now: nowUtc,
          )).draft!;

          // 6. retryScheduled (editing locked, safe retry allowed)
          final c6 = await insertCleanDraft(
            localDraftId: 'draft-r3309-retry-sched',
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Retry Scheduled Draft',
            rawScore: 9,
          );
          final claim6 = await appDatabase.acquireDraftClaim(
            localDraftId: c6.localDraftId,
            actorUserId: 'parent-actor-1',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            leaseDuration: const Duration(minutes: 5),
            now: nowUtc,
          );
          await appDatabase.markDraftStageAndDispatch(
            localDraftId: c6.localDraftId,
            leaseToken: claim6.draft!.leaseToken!,
            authenticatedActorId: 'parent-actor-1',
            targetStage: DraftSubmissionStatus.submittingAssessment,
            now: nowUtc,
          );
          final retryScheduled = (await appDatabase.scheduleDraftRetry(
            localDraftId: c6.localDraftId,
            leaseToken: claim6.draft!.leaseToken!,
            authenticatedActorId: 'parent-actor-1',
            nextAttemptAt: nowUtc.add(const Duration(minutes: 1)),
            recoveryCode: DraftRecoveryCode.retryScheduled,
            errorMessage: 'Retry later',
            now: nowUtc,
          )).draft!;

          final cases =
              <({String name, LocalAssessmentDraft draft, bool allowSubmit})>[
                (
                  name: 'confirmedCommitted',
                  draft: committed,
                  allowSubmit: false,
                ),
                (name: 'leased', draft: leased, allowSubmit: false),
                (
                  name: 'malformedLeaseQuarantined',
                  draft: malformedLease,
                  allowSubmit: false,
                ),
                (
                  name: 'waitingOriginalActor',
                  draft: waitingActor,
                  allowSubmit: false,
                ),
                (
                  name: 'terminalError',
                  draft: terminalError,
                  allowSubmit: false,
                ),
                (
                  name: 'retryScheduled',
                  draft: retryScheduled,
                  allowSubmit: true,
                ),
              ];

          for (final testCase in cases) {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            await tester.pumpWidget(
              buildRoutedApp(initialDraft: testCase.draft),
            );
            await tester.pumpAndSettle();

            expect(
              find.byKey(const Key('payload_locked_banner')),
              findsOneWidget,
              reason: '${testCase.name} must display locked payload banner',
            );
            expect(
              find.textContaining('original submitted payload'),
              findsOneWidget,
              reason: '${testCase.name} must explain payload is preserved',
            );
            expectAllEditingControlsLocked(
              tester,
              hasAttachedEvidence: false,
              expectSubmitEnabled: testCase.allowSubmit,
            );
          }
        },
      );

      testWidgets(
        'stale-screen text/score edits after background transition to possiblyDispatched recheck store, lock controls, reject submit, and leave SQLite/RPC untouched',
        (tester) async {
          const draftId = 'draft-r3309-stale-text-race';
          final snap = await fileStore.saveCanonicalEvidenceSnapshot(
            localDraftId: draftId,
            bytes: validJpegBytes,
          );
          final staleInitial = await insertCleanDraft(
            localDraftId: draftId,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Stale Original Title',
            rawScore: 8.0,
            maxScore: 10.0,
            createCommandId: 'cmd-r3309-stale-c',
            submitCommandId: 'cmd-r3309-stale-s',
            evidenceId: 'evi-r3309-stale',
            snapshot: snap,
          );

          await tester.pumpWidget(buildRoutedApp(initialDraft: staleInitial));
          await tester.pumpAndSettle();

          // While this stale screen remains open, SQLite transitions to possiblyDispatched.
          await transitionToDispatchedRetryable(staleInitial);

          // User edits title, subject, and raw score on the stale screen.
          await tester.enterText(
            find.byKey(const Key('assessment_title_field')),
            'Diverged Title',
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('assessment_subject_field')),
            'Physics',
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('assessment_raw_score_field')),
            '10',
          );
          await tester.pumpAndSettle();

          // Recheck must lock controls and surface explicit rejection.
          expect(
            find.byKey(const Key('payload_locked_banner')),
            findsOneWidget,
          );
          expect(
            find.textContaining(
              'Edits made on this screen cannot be submitted',
            ),
            findsOneWidget,
          );
          expectAllEditingControlsLocked(
            tester,
            hasAttachedEvidence: true,
            expectSubmitEnabled: true,
          );

          // Attempting Submit for Review must fail closed with ZERO remote RPCs.
          await tapButton(tester, 'submit_assessment_button');

          expect(find.byType(AddAssessmentScreen), findsOneWidget);
          expect(find.text('HOME_ROUTE'), findsNothing);
          expect(
            find.textContaining(
              'Edits made on this screen cannot be submitted',
            ),
            findsOneWidget,
          );
          expect(repo.createDraftCalls, equals(0));
          expect(storage.uploadCallCount, equals(0));
          expect(repo.registerEvidenceCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));

          final persisted = await appDatabase.getLocalDraft(draftId);
          expect(persisted!.title, equals('Stale Original Title'));
          expect(persisted.subject, equals('Math'));
          expect(persisted.rawScore, equals(8.0));
          expect(persisted.maxScore, equals(10.0));
          expect(persisted.createCommandId, equals('cmd-r3309-stale-c'));
          expect(persisted.submitCommandId, equals('cmd-r3309-stale-s'));
          expect(persisted.evidenceId, equals('evi-r3309-stale'));
          expect(persisted.sha256Checksum, equals(snap.sha256Checksum));
        },
      );

      testWidgets(
        'stale-screen dropdown changes (subjectKey, type, difficulty) after background transition reject edit, lock controls, and reject subsequent submit',
        (tester) async {
          Future<void> runDropdownAttempt({
            required String draftId,
            required Key dropdownKey,
            required String optionLabel,
          }) async {
            final staleInitial = await insertCleanDraft(
              localDraftId: draftId,
              subjectKey: SubjectKey.math,
              subject: 'Math',
              title: 'Stale Dropdown Draft',
              rawScore: 7.0,
              maxScore: 10.0,
            );
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            await tester.pumpWidget(buildRoutedApp(initialDraft: staleInitial));
            await tester.pumpAndSettle();

            await transitionToDispatchedRetryable(staleInitial);

            await tester.ensureVisible(find.byKey(dropdownKey));
            await tester.tap(find.byKey(dropdownKey));
            await tester.pumpAndSettle();
            await tester.tap(find.text(optionLabel).last);
            await tester.pumpAndSettle();

            expect(
              find.byKey(const Key('payload_locked_banner')),
              findsOneWidget,
            );
            expect(
              find.textContaining(
                'Edits made on this screen cannot be submitted',
              ),
              findsOneWidget,
            );
            expectAllEditingControlsLocked(
              tester,
              hasAttachedEvidence: false,
              expectSubmitEnabled: true,
            );

            await tapButton(tester, 'submit_assessment_button');

            expect(find.byType(AddAssessmentScreen), findsOneWidget);
            expect(repo.createDraftCalls, equals(0));
            expect(repo.submitAssessmentCalls, equals(0));
            final persisted = await appDatabase.getLocalDraft(draftId);
            expect(persisted!.subjectKey, equals(SubjectKey.math));
            expect(persisted.assessmentType, equals('quiz'));
            expect(persisted.difficulty, equals('normal'));
          }

          await runDropdownAttempt(
            draftId: 'draft-r3309-stale-dd-type',
            dropdownKey: const Key('assessment_type_dropdown'),
            optionLabel: 'EXAM',
          );
          await runDropdownAttempt(
            draftId: 'draft-r3309-stale-dd-diff',
            dropdownKey: const Key('assessment_difficulty_dropdown'),
            optionLabel: 'hard',
          );
          await runDropdownAttempt(
            draftId: 'draft-r3309-stale-dd-subj',
            dropdownKey: const Key('assessment_subject_key_dropdown'),
            optionLabel: SubjectKey.science.displayLabel,
          );
        },
      );

      testWidgets(
        'stale-screen direct retry fails closed when SQLite payload differs from displayed form even without user edits',
        (tester) async {
          const draftId = 'draft-r3309-stale-direct-submit';
          final staleInitial = await insertCleanDraft(
            localDraftId: draftId,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Screen Original Title',
            rawScore: 8.0,
            maxScore: 10.0,
          );

          await tester.pumpWidget(buildRoutedApp(initialDraft: staleInitial));
          await tester.pumpAndSettle();

          // Update payload concurrently while still neverDispatched, then transition to possiblyDispatched.
          final bgUpdated = staleInitial.copyWith(
            title: 'Authoritative Updated Title',
            rawScore: 9.0,
            updatedAt: baseTime.add(const Duration(seconds: 2)),
          );
          final updateRes = await appDatabase.registerOrUpdateDraftIfUnchanged(
            expected: staleInitial,
            desired: bgUpdated,
            now: baseTime.add(const Duration(seconds: 2)),
          );
          expect(updateRes.isSuccess, isTrue);
          await transitionToDispatchedRetryable(updateRes.draft!);

          await tapButton(tester, 'submit_assessment_button');

          expect(find.byType(AddAssessmentScreen), findsOneWidget);
          expect(find.text('HOME_ROUTE'), findsNothing);
          expect(
            find.textContaining(
              'Edits made on this screen cannot be submitted',
            ),
            findsOneWidget,
          );
          expect(repo.createDraftCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));
          expectAllEditingControlsLocked(
            tester,
            hasAttachedEvidence: false,
            expectSubmitEnabled: true,
          );
        },
      );

      testWidgets(
        'in-screen transition: failed submit moves fresh draft to possiblyDispatched, locks all controls immediately, and allows unmodified retry',
        (tester) async {
          repo.nextSubmitError = StateError('SocketException: dropped');

          await tester.pumpWidget(buildRoutedApp());
          await tester.pumpAndSettle();

          await fillRequiredForm(
            tester,
            title: 'In-Screen Transition Quiz',
            rawScore: '9',
          );
          await tapButton(tester, 'submit_assessment_button');

          // Still on AddAssessmentScreen after failure; controls are immediately locked.
          expect(find.byType(AddAssessmentScreen), findsOneWidget);
          expect(
            find.byKey(const Key('payload_locked_banner')),
            findsOneWidget,
          );
          expect(
            find.textContaining('original submitted payload'),
            findsOneWidget,
          );
          expectAllEditingControlsLocked(
            tester,
            hasAttachedEvidence: false,
            expectSubmitEnabled: true,
          );

          // Safe retry without edits succeeds and dispatches exact original payload.
          await tapButton(tester, 'submit_assessment_button');

          expect(find.text('HOME_ROUTE'), findsOneWidget);
          expect(repo.assessments.length, equals(1));
          expect(
            repo.assessments.values.single.title,
            equals('In-Screen Transition Quiz'),
          );
          expect(repo.assessments.values.single.score.rawScore, equals(9.0));
        },
      );

      testWidgets(
        'clean neverDispatched draft remains editable across all payload fields and submits edited values',
        (tester) async {
          const draftId = 'draft-r3309-editable-clean';
          final cleanDraft = await insertCleanDraft(
            localDraftId: draftId,
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Initial Clean Title',
            rawScore: 6.0,
            maxScore: 10.0,
          );

          await tester.pumpWidget(buildRoutedApp(initialDraft: cleanDraft));
          await tester.pumpAndSettle();

          expect(find.byKey(const Key('payload_locked_banner')), findsNothing);
          expect(
            find.byKey(const Key('legacy_draft_quarantine_banner')),
            findsNothing,
          );

          await tester.tap(
            find.byKey(const Key('assessment_subject_key_dropdown')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(SubjectKey.science.displayLabel).last);
          await tester.pumpAndSettle();

          await tester.enterText(
            find.byKey(const Key('assessment_subject_field')),
            'Chemistry',
          );
          await tester.enterText(
            find.byKey(const Key('assessment_title_field')),
            'Edited Clean Assessment',
          );
          await tester.ensureVisible(
            find.byKey(const Key('assessment_type_dropdown')),
          );
          await tester.tap(find.byKey(const Key('assessment_type_dropdown')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('HOMEWORK').last);
          await tester.pumpAndSettle();

          await tester.tap(
            find.byKey(const Key('assessment_difficulty_dropdown')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('hard').last);
          await tester.pumpAndSettle();

          await tester.enterText(
            find.byKey(const Key('assessment_raw_score_field')),
            '9.5',
          );
          await tester.enterText(
            find.byKey(const Key('assessment_max_score_field')),
            '10',
          );
          await tester.pumpAndSettle();

          await tapButton(tester, 'save_draft_button');
          expect(find.text('Draft saved locally.'), findsOneWidget);
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();

          final saved = await appDatabase.getLocalDraft(draftId);
          expect(saved!.subjectKey, SubjectKey.science);
          expect(saved.subject, equals('Chemistry'));
          expect(saved.title, equals('Edited Clean Assessment'));
          expect(saved.assessmentType, equals('homework'));
          expect(saved.difficulty, equals('hard'));
          expect(saved.rawScore, equals(9.5));

          await tapButton(tester, 'submit_assessment_button');

          expect(find.text('HOME_ROUTE'), findsOneWidget);
          expect(repo.assessments.length, equals(1));
          final submitted = repo.assessments.values.single;
          expect(submitted.subjectKey, SubjectKey.science);
          expect(submitted.subject, equals('Chemistry'));
          expect(submitted.title, equals('Edited Clean Assessment'));
          expect(submitted.type, AssessmentType.homework);
          expect(submitted.difficulty, AssessmentDifficulty.hard);
          expect(submitted.score.rawScore, equals(9.5));
          expect(submitted.score.maxScore, equals(10.0));
        },
      );
    });
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
