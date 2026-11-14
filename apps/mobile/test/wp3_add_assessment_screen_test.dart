import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/features/assessments/presentation/add_assessment_screen.dart';
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

final class _HookableLocalDraftStore implements LocalDraftStore {
  _HookableLocalDraftStore(this.inner);
  final LocalDraftStore inner;
  Future<void> Function(String localDraftId)? onBeforeRegisterOrUpdate;

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
    if (onBeforeRegisterOrUpdate != null) {
      await onBeforeRegisterOrUpdate!(desired.localDraftId);
    }
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
  }) => inner.acquireDraftClaim(
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

final class _ThrowingSubmitRepo extends FakeAssessmentRepository {
  _ThrowingSubmitRepo({super.activeActorIdProvider});
  Object? nextSubmitError;

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
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

void main() {
  setUpAll(_ensureSqliteInitialized);

  final validJpegBytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
  final testFamily = Family(
    id: FamilyId('fam-ui-wp3'),
    name: 'WP3 UI Family',
    timezone: 'UTC',
    locale: 'en_US',
    createdByUserId: 'parent-ui-1',
    createdAt: DateTime.utc(2026, 1, 1),
  );
  final testChild = ChildProfile(
    id: ChildId('ch-ui-wp3'),
    familyId: testFamily.id,
    displayName: 'Kid One',
    birthYear: 2018,
    schoolGrade: 2,
    createdAt: DateTime.utc(2026, 1, 1),
  );

  late Directory tempDir;
  late AppDatabase db;
  late DefaultLocalEvidenceFileStore fileStore;
  late FakeAuthSessionPort authPort;
  late FakeRecoveryAuthorizationPort authzPort;
  late _ThrowingSubmitRepo assessmentRepo;
  late FakeAssessmentEvidenceStorage evidenceStorage;
  late InMemoryLocalMetadataStore metadataStore;
  late FakeFamilyRepository familyRepo;
  late FakeChildProfileRepository childRepo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('learnward_wp3_ui_');
    db = AppDatabase(NativeDatabase(File('${tempDir.path}/ui_wp3.sqlite')));
    fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
    authPort = FakeAuthSessionPort(
      activeUserId: 'parent-ui-1',
      sessionGeneration: 'gen-ui-1',
      role: 'parent',
    );
    authzPort = FakeRecoveryAuthorizationPort();
    assessmentRepo = _ThrowingSubmitRepo(
      activeActorIdProvider: () => authPort.currentContext?.userId,
    );
    evidenceStorage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
    metadataStore = InMemoryLocalMetadataStore();
    familyRepo = FakeFamilyRepository();
    childRepo = FakeChildProfileRepository();
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Widget buildHarness({
    LocalAssessmentDraft? initialDraft,
    LocalDraftStore? customDraftStore,
  }) {
    final router = GoRouter(
      initialLocation: '/child/add',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('Home Placeholder')),
          routes: [
            GoRoute(
              path: 'child/add',
              builder: (_, _) =>
                  AddAssessmentScreen(initialDraft: initialDraft),
            ),
          ],
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        localMetadataStoreProvider.overrideWithValue(metadataStore),
        familyRepositoryProvider.overrideWithValue(familyRepo),
        childProfileRepositoryProvider.overrideWithValue(childRepo),
        assessmentRepositoryProvider.overrideWithValue(assessmentRepo),
        assessmentEvidenceStorageProvider.overrideWithValue(evidenceStorage),
        localEvidenceFileStoreProvider.overrideWithValue(fileStore),
        localDraftStoreProvider.overrideWithValue(customDraftStore ?? db),
        authSessionPortProvider.overrideWithValue(authPort),
        recoveryAuthorizationPortProvider.overrideWithValue(authzPort),
        activeFamilyProvider.overrideWith(
          () => _PresetFamilyNotifier(testFamily),
        ),
        activeChildModeProvider.overrideWith(
          () => _PresetActiveChildNotifier(testChild),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  Future<void> fillValidFields(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('assessment_title_field')),
      'WP3 Fraction Test',
    );
    await tester.enterText(
      find.byKey(const Key('assessment_raw_score_field')),
      '8.5',
    );
    await tester.pumpAndSettle();
  }

  group('WP3 AddAssessmentScreen UI & Local Save/Retry Integration', () {
    testWidgets(
      '_saveLocalDraft fails closed when session is invalid and persists zero drafts',
      (tester) async {
        authPort.invalidateSession();
        await tester.pumpWidget(buildHarness());
        await tester.pumpAndSettle();
        await fillValidFields(tester);

        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('session'), findsAtLeastNWidgets(1));
        final drafts = await db.listLocalDrafts(testChild.id);
        expect(drafts, isEmpty);
      },
    );

    testWidgets(
      '_saveLocalDraft blocks definitelyDenied target and permits offline save under transientVerificationFailure',
      (tester) async {
        // 1. Confirmed revocation blocks save cleanly
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.confirmedRevoked(),
        );
        await tester.pumpWidget(buildHarness());
        await tester.pumpAndSettle();
        await fillValidFields(tester);

        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('permission'), findsAtLeastNWidgets(1));
        expect(await db.listLocalDrafts(testChild.id), isEmpty);

        // 2. Transient network failure still permits offline local draft save
        authzPort.setDefaultAdultResult(
          const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.transientVerificationFailure,
          ),
        );
        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.text('Draft saved locally.'), findsOneWidget);
        final drafts = await db.listLocalDrafts(testChild.id);
        expect(drafts.length, equals(1));
      },
    );

    testWidgets(
      '_saveLocalDraft registers/updates via CAS and rejects concurrent overwrite cleanly',
      (tester) async {
        final hookedStore = _HookableLocalDraftStore(db);
        const draftId = 'ui-cas-conc-1';
        final now = DateTime.now().toUtc();
        final seeded = LocalAssessmentDraft(
          localDraftId: draftId,
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          actorUserId: 'parent-ui-1',
          createCommandId: 'cmd-c-ui-1',
          submitCommandId: 'cmd-s-ui-1',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Original Title',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 7.0,
          maxScore: 10.0,
          occurredAt: now,
          updatedAt: now,
          dispatchState: CommandDispatchState.neverDispatched,
          entryContext: EntryContext.sharedChild,
        );
        await db.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: seeded,
          now: now,
        );

        await tester.pumpWidget(
          buildHarness(initialDraft: seeded, customDraftStore: hookedStore),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('assessment_title_field')),
          'Edited Stale UI Title',
        );
        await tester.pumpAndSettle();

        // Inject concurrent mutation right before CAS write
        hookedStore.onBeforeRegisterOrUpdate = (id) async {
          await db.registerOrUpdateDraftIfUnchanged(
            expected: seeded,
            desired: seeded.copyWith(title: 'Concurrent Newer Title'),
            now: now.add(const Duration(seconds: 5)),
          );
        };

        await tester.ensureVisible(find.byKey(const Key('save_draft_button')));
        await tester.tap(find.byKey(const Key('save_draft_button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('preserved'), findsAtLeastNWidgets(1));
        final row = await db.getLocalDraft(draftId);
        expect(row?.title, equals('Concurrent Newer Title'));
      },
    );

    testWidgets(
      'retrying a retryScheduled draft with future nextAttemptAt via UI uses foregroundRetry and commits cleanly',
      (tester) async {
        const draftId = 'ui-retry-scheduled-1';
        final now = DateTime.now().toUtc();
        final snap = await fileStore.saveCanonicalEvidenceSnapshot(
          localDraftId: draftId,
          bytes: validJpegBytes,
        );
        final remoteDraft = await assessmentRepo.createDraft(
          commandId: 'cmd-c-retry-1',
          familyId: testFamily.id,
          childId: testChild.id,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Scheduled Retry Quiz',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          occurredAt: now,
          entryContext: EntryContext.sharedChild,
        );
        final baseDraft = LocalAssessmentDraft(
          localDraftId: draftId,
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          actorUserId: 'parent-ui-1',
          createCommandId: 'cmd-c-retry-1',
          submitCommandId: 'cmd-s-retry-1',
          evidenceId: 'ev-ui-retry-1',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Scheduled Retry Quiz',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 9.0,
          maxScore: 10.0,
          localPhotoPath: snap.filePath,
          localCompressedPhotoPath: snap.filePath,
          sha256Checksum: snap.sha256Checksum,
          occurredAt: now,
          updatedAt: now,
          dispatchState: CommandDispatchState.neverDispatched,
          entryContext: EntryContext.sharedChild,
        );
        final regRes = await db.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: baseDraft,
          now: now,
        );
        expect(regRes.isSuccess, isTrue);
        final lease = (await db.acquireDraftClaim(
          localDraftId: draftId,
          actorUserId: 'parent-ui-1',
          familyId: testFamily.id.value,
          childId: testChild.id.value,
          leaseDuration: const Duration(minutes: 2),
          now: now,
        )).draft!.leaseToken!;
        await db.markDraftStageAndDispatch(
          localDraftId: draftId,
          leaseToken: lease,
          authenticatedActorId: 'parent-ui-1',
          targetStage: DraftSubmissionStatus.submittingAssessment,
          now: now,
        );
        await db.persistServerAssessmentId(
          localDraftId: draftId,
          leaseToken: lease,
          authenticatedActorId: 'parent-ui-1',
          serverAssessmentId: remoteDraft.id.value,
          now: now,
        );
        final schedRes = await db.scheduleDraftRetry(
          localDraftId: draftId,
          leaseToken: lease,
          authenticatedActorId: 'parent-ui-1',
          nextAttemptAt: now.add(const Duration(minutes: 10)),
          recoveryCode: DraftRecoveryCode.retryScheduled,
          errorMessage: 'LW4B1:RETRY_SCHEDULED: Temporary server outage.',
          now: now,
        );
        expect(schedRes.isSuccess, isTrue);
        final seeded = schedRes.draft!;

        await tester.pumpWidget(buildHarness(initialDraft: seeded));
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        final afterRow = await db.getLocalDraft(draftId);
        expect(
          afterRow?.dispatchState,
          CommandDispatchState.confirmedCommitted,
        );
        expect(afterRow?.serverEvidenceId, isNotNull);
        expect(find.text('Home Placeholder'), findsOneWidget);
      },
    );

    testWidgets(
      'quarantined LW107 UI feedback never leaks JWT, Bearer token, or Storage path secrets (R32-07)',
      (tester) async {
        const secretJwt =
            'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.SecretUiSig77';
        const secretBearer = 'Bearer secret_ui_bearer_555';
        const secretUrl =
            'https://proj.supabase.co/storage/v1/object/sign/assessment-evidence/fam-ui-wp3/ch-ui-wp3/a-1/ev-1.jpg?token=secretUiTok88';

        assessmentRepo.nextSubmitError = const BackendRpcException(
          message: 'Failed: $secretBearer $secretJwt $secretUrl',
          code: 'LW107',
        );

        await tester.pumpWidget(buildHarness());
        await tester.pumpAndSettle();
        await fillValidFields(tester);

        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pumpAndSettle();

        final textWidgets = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .join('\n');
        for (final secret in const [
          'SecretUiSig77',
          'secret_ui_bearer_555',
          'secretUiTok88',
          'assessment-evidence/fam-ui-wp3',
        ]) {
          expect(textWidgets, isNot(contains(secret)));
        }
        expect(
          textWidgets,
          contains('Submission status requires manual verification'),
        );
      },
    );
  });
}
