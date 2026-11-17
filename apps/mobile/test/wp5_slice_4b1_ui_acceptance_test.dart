// Phase 6 Slice 4B-1 — WP5 Production UI + DefaultLocalEvidenceFileStore + SQLite Acceptance Suite
//
// Verifies end-to-end Flutter UI flows with real file-backed SQLite (`NativeDatabase`),
// production `DefaultLocalEvidenceFileStore` (`exclusive: true` + RandomAccessFile flush + re-read SHA-256),
// `AddAssessmentScreen`, and `ChildModeScreen` across key B1-01..B1-28 invariants.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart' hide Column, isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
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

final class _QueueEvidencePicker implements EvidencePickerService {
  _QueueEvidencePicker(List<SelectedEvidenceFile?> selections)
    : _queue = List<SelectedEvidenceFile?>.from(selections);

  final List<SelectedEvidenceFile?> _queue;

  @override
  Future<SelectedEvidenceFile?> pickEvidencePhoto() async {
    if (_queue.isEmpty) return null;
    return _queue.removeAt(0);
  }
}

final class _UiSpyAssessmentRepository extends FakeAssessmentRepository {
  _UiSpyAssessmentRepository({super.activeActorIdProvider});

  int createDraftCalls = 0;
  int registerEvidenceCalls = 0;
  int submitAssessmentCalls = 0;

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
    return super.submitAssessment(
      assessmentId: assessmentId,
      expectedVersion: expectedVersion,
      commandId: commandId,
    );
  }
}

final class _GatedAuthzPort implements RecoveryAuthorizationPort {
  _GatedAuthzPort(this.inner);

  final FakeRecoveryAuthorizationPort inner;
  Future<AdultTargetAuthorizationResult> Function(
    ValidatedActorContext context,
    String familyId,
    String childId,
  )?
  onVerifyAssessmentTarget;

  @override
  Future<AdultTargetAuthorizationResult> verifyAdultRedemptionTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required String redemptionId,
    required RewardCommandOperation operation,
  }) => inner.verifyAdultRedemptionTarget(
    context: context,
    familyId: familyId,
    childId: childId,
    redemptionId: redemptionId,
    operation: operation,
  );

  @override
  Future<AdultTargetAuthorizationResult> verifyAssessmentTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
  }) {
    if (onVerifyAssessmentTarget != null) {
      return onVerifyAssessmentTarget!(context, familyId, childId);
    }
    return inner.verifyAssessmentTarget(
      context: context,
      familyId: familyId,
      childId: childId,
    );
  }

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) => inner.verifyTarget(
    context: context,
    familyId: familyId,
    childId: childId,
    operation: operation,
  );
}

Future<void> _tapButton(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  _ensureSqliteInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final entityCreatedAt = DateTime.utc(2026, 11, 1, 8, 0, 0);
  final validJpeg = <int>[
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
    1,
    2,
    3,
    4,
  ];
  final validPng = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
    0x09,
    0x08,
  ];

  final family = Family(
    id: FamilyId('10000000-0000-4000-8000-000000000001'),
    name: 'UI Acceptance Family',
    timezone: 'UTC',
    locale: 'en-US',
    createdByUserId: 'parent-a',
    createdAt: entityCreatedAt,
  );
  final child = ChildProfile(
    id: ChildId('20000000-0000-4000-8000-000000000002'),
    familyId: family.id,
    displayName: 'Maya',
    schoolGrade: 4,
    birthYear: 2016,
    createdAt: entityCreatedAt,
  );

  group(
    'WP5 Mobile UI + DefaultLocalEvidenceFileStore + SQLite Acceptance',
    () {
      late DateTime baseNow;
      late Directory tempDir;
      late File dbFile;
      late AppDatabase db;
      late DefaultLocalEvidenceFileStore fileStore;
      late FakeAuthSessionPort authPort;
      late FakeRecoveryAuthorizationPort authzInner;
      late _GatedAuthzPort authzPort;
      late _UiSpyAssessmentRepository repo;
      late FakeAssessmentEvidenceStorage storage;

      setUp(() async {
        final rawNow = DateTime.now().toUtc();
        baseNow = DateTime.utc(
          rawNow.year,
          rawNow.month,
          rawNow.day,
          rawNow.hour,
          rawNow.minute,
          rawNow.second,
        );
        tempDir = await Directory.systemTemp.createTemp('lw_wp5_ui_');
        dbFile = File('${tempDir.path}/wp5_ui.sqlite');
        db = AppDatabase(NativeDatabase(dbFile));
        fileStore = DefaultLocalEvidenceFileStore(
          baseDirectory: tempDir,
          clock: () => baseNow,
        );
        authPort = FakeAuthSessionPort(
          activeUserId: 'parent-a',
          role: 'parent',
          sessionGeneration: 'gen-ui-1',
          clock: TestClock(baseNow),
        );
        authzInner = FakeRecoveryAuthorizationPort();
        authzPort = _GatedAuthzPort(authzInner);
        repo = _UiSpyAssessmentRepository(
          activeActorIdProvider: () => authPort.currentContext?.userId,
        );
        storage = FakeAssessmentEvidenceStorage(authSessionPort: authPort);
      });

      tearDown(() async {
        try {
          await db.close();
        } catch (_) {}
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      Future<void> reopenDb() async {
        await db.close();
        db = AppDatabase(NativeDatabase(dbFile));
      }

      Widget buildApp({
        LocalAssessmentDraft? initialDraft,
        EvidencePickerService? picker,
        String cachedUserId = 'parent-a',
      }) {
        final router = GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) => Scaffold(
                body: Column(
                  children: [
                    const Text('HOME_ROUTE'),
                    TextButton(
                      key: const Key('open_add_btn'),
                      onPressed: () => context.push('/add'),
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ),
            ),
            GoRoute(
              path: '/add',
              builder: (_, _) =>
                  AddAssessmentScreen(initialDraft: initialDraft),
            ),
          ],
        );
        return ProviderScope(
          overrides: [
            appConfigProvider.overrideWithValue(
              const AppConfig(
                environment: AppEnvironment.development,
                supabaseUrl: '',
                supabasePublishableKey: '',
                enableLocalDemo: true,
              ),
            ),
            appClockProvider.overrideWithValue(() => baseNow),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(family),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetActiveChildNotifier(child),
            ),
            currentUserIdProvider.overrideWithValue(cachedUserId),
            localDraftStoreProvider.overrideWithValue(db),
            localEvidenceFileStoreProvider.overrideWithValue(fileStore),
            if (picker != null)
              evidencePickerServiceProvider.overrideWithValue(picker),
            authSessionPortProvider.overrideWithValue(authPort),
            recoveryAuthorizationPortProvider.overrideWithValue(authzPort),
            assessmentRepositoryProvider.overrideWithValue(repo),
            assessmentEvidenceStorageProvider.overrideWithValue(storage),
          ],
          child: MaterialApp.router(routerConfig: router),
        );
      }

      testWidgets(
        'B1-01 & B1-02 UI: Direct PNG capture freezes canonical .png snapshot via DefaultLocalEvidenceFileStore and retains receipt + file after restart',
        (tester) async {
          final rawPngFile = File('${tempDir.path}/camera_pick.png')
            ..writeAsBytesSync(validPng);
          final picker = _QueueEvidencePicker([
            SelectedEvidenceFile(
              fileName: 'camera_pick.png',
              bytes: validPng,
              mediaType: 'image/png',
              localPath: rawPngFile.path,
            ),
          ]);

          await tester.pumpWidget(buildApp(picker: picker));
          await tester.pumpAndSettle();
          await _tapButton(tester, 'open_add_btn');

          await tester.enterText(
            find.byKey(const Key('assessment_title_field')),
            'PNG Fractions Test',
          );
          await tester.enterText(
            find.byKey(const Key('assessment_raw_score_field')),
            '9',
          );
          await tester.enterText(
            find.byKey(const Key('assessment_max_score_field')),
            '10',
          );
          await _tapButton(tester, 'attach_evidence_button');
          await _tapButton(tester, 'submit_assessment_button');

          expect(find.text('HOME_ROUTE'), findsOneWidget);
          expect(repo.createDraftCalls, equals(1));
          expect(storage.uploadCallCount, equals(1));
          expect(repo.registerEvidenceCalls, equals(1));
          expect(repo.submitAssessmentCalls, equals(1));
          expect(storage.deleteCallCount, equals(0));
          expect(repo.evidence.values.single.mediaType, equals('image/png'));
          expect(repo.evidence.values.single.storagePath, endsWith('.png'));

          await reopenDb();
          final drafts = await db.listLocalDrafts(child.id);
          expect(drafts.length, equals(1));
          final saved = drafts.single;
          expect(
            saved.dispatchState,
            equals(CommandDispatchState.confirmedCommitted),
          );
          expect(saved.localCompressedPhotoPath, endsWith('.png'));
          expect(saved.sha256Checksum, equals(computeSha256Hex(validPng)));
          expect(File(saved.localCompressedPhotoPath!).existsSync(), isTrue);
          expect(
            File(saved.localCompressedPhotoPath!).readAsBytesSync(),
            equals(validPng),
          );
        },
      );

      testWidgets(
        'B1-03 UI: Corrupted canonical snapshot in reopened SQLite draft fails closed with zero upload and zero raw fallback',
        (tester) async {
          const draftId = 'ui-b103-corrupt';
          final rawJpeg = File('${tempDir.path}/raw_b103.jpg')
            ..writeAsBytesSync(validJpeg);
          final snap = await fileStore.saveCanonicalEvidenceSnapshot(
            localDraftId: draftId,
            bytes: validJpeg,
          );
          // Corrupt the canonical file on disk while keeping rawJpeg intact
          File(snap.filePath).writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, 0x00]);

          final draft = LocalAssessmentDraft(
            localDraftId: draftId,
            familyId: family.id.value,
            childId: child.id.value,
            actorUserId: 'parent-a',
            actorRole: 'parent',
            createCommandId: 'cmd-c-ui-b103',
            submitCommandId: 'cmd-s-ui-b103',
            evidenceId: 'ev-ui-b103',
            subjectKey: SubjectKey.math,
            subject: 'Mathematics',
            title: 'Corrupt Canonical Quiz',
            assessmentType: 'quiz',
            difficulty: 'normal',
            rawScore: 8,
            maxScore: 10,
            localPhotoPath: rawJpeg.path,
            localCompressedPhotoPath: snap.filePath,
            sha256Checksum: snap.sha256Checksum,
            occurredAt: baseNow,
            updatedAt: baseNow,
            entryContext: EntryContext.sharedChild,
          );
          await db.registerOrUpdateDraftIfUnchanged(
            expected: null,
            desired: draft,
            now: baseNow,
          );
          await reopenDb();

          await tester.pumpWidget(buildApp(initialDraft: draft));
          await tester.pumpAndSettle();
          await _tapButton(tester, 'open_add_btn');

          expect(
            find.byKey(const Key('submit_assessment_button')),
            findsOneWidget,
          );
          await _tapButton(tester, 'submit_assessment_button');

          expect(storage.uploadCallCount, equals(0));
          expect(repo.createDraftCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));
          expect(storage.deleteCallCount, equals(0));
          expect(rawJpeg.existsSync(), isTrue);
          expect(File(snap.filePath).existsSync(), isTrue);
        },
      );

      testWidgets(
        'B1-16 & B1-18 UI: Direct submit ignores stale cachedUserId and halts cleanly when session generation rotates mid-verify',
        (tester) async {
          final enteredVerify = Completer<void>();
          final releaseVerify = Completer<void>();
          authzPort.onVerifyAssessmentTarget = (_, _, _) async {
            if (!enteredVerify.isCompleted) {
              enteredVerify.complete();
              await releaseVerify.future;
            }
            return const AdultTargetAuthorizationResult.authorized(
              verifiedRole: VerifiedAdultRole.parent,
            );
          };

          await tester.pumpWidget(
            buildApp(cachedUserId: 'stale-cached-user-should-be-ignored'),
          );
          await tester.pumpAndSettle();
          await _tapButton(tester, 'open_add_btn');

          await tester.enterText(
            find.byKey(const Key('assessment_title_field')),
            'Auth Generation Guard Quiz',
          );
          await tester.enterText(
            find.byKey(const Key('assessment_raw_score_field')),
            '9',
          );
          await tester.enterText(
            find.byKey(const Key('assessment_max_score_field')),
            '10',
          );

          await tester.ensureVisible(
            find.byKey(const Key('submit_assessment_button')),
          );
          await tester.tap(find.byKey(const Key('submit_assessment_button')));
          for (var i = 0; i < 50 && !enteredVerify.isCompleted; i++) {
            await tester.pump(const Duration(milliseconds: 10));
          }
          expect(enteredVerify.isCompleted, isTrue);

          // Rotate session generation before async verification returns.
          authPort.setSessionGeneration('gen-ui-rotated');
          releaseVerify.complete();
          await tester.pumpAndSettle();

          expect(repo.createDraftCalls, equals(0));
          expect(repo.submitAssessmentCalls, equals(0));
          expect(storage.uploadCallCount, equals(0));
        },
      );

      testWidgets(
        'B1-26 & B1-28 UI: Unbound actor & unknownLegacy stay read-only without rewriting SQLite, and ChildModeScreen retains confirmed receipt safely',
        (tester) async {
          final ts = baseNow.millisecondsSinceEpoch ~/ 1000;
          final snapConf = await fileStore.saveCanonicalEvidenceSnapshot(
            localDraftId: 'ui-conf-1',
            bytes: validJpeg,
          );
          await db.customStatement('''
          INSERT INTO local_assessment_drafts (
            local_draft_id, family_id, child_id, subject_key, subject, title,
            assessment_type, difficulty, raw_score, max_score, entry_context,
            occurred_at, updated_at, submission_status, retry_count, dispatch_state,
            actor_user_id
          ) VALUES (
            'ui-unbound-1', '${family.id.value}', '${child.id.value}', 'math', 'Mathematics',
            'Unbound Quarantine', 'quiz', 'normal', 7.0, 10.0, 'shared_child',
            $ts, $ts, 'draft', 0, 'never_dispatched', NULL
          );
        ''');
          await db.saveLocalDraft(
            LocalAssessmentDraft(
              localDraftId: 'ui-conf-1',
              familyId: family.id.value,
              childId: child.id.value,
              actorUserId: 'parent-a',
              actorRole: 'parent',
              createCommandId: 'cmd-c-conf-ui',
              submitCommandId: 'cmd-s-conf-ui',
              evidenceId: 'ev-conf-ui',
              serverAssessmentId: 'srv-conf-ui',
              serverEvidenceId: 'srv-ev-ui',
              subjectKey: SubjectKey.math,
              subject: 'Mathematics',
              title: 'Confirmed Retained Receipt',
              assessmentType: 'quiz',
              difficulty: 'normal',
              rawScore: 10,
              maxScore: 10,
              localPhotoPath: snapConf.filePath,
              localCompressedPhotoPath: snapConf.filePath,
              sha256Checksum: snapConf.sha256Checksum,
              occurredAt: baseNow,
              updatedAt: baseNow,
              dispatchState: CommandDispatchState.confirmedCommitted,
              entryContext: EntryContext.sharedChild,
            ),
          );
          await reopenDb();

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                appConfigProvider.overrideWithValue(
                  const AppConfig(
                    environment: AppEnvironment.development,
                    supabaseUrl: '',
                    supabasePublishableKey: '',
                    enableLocalDemo: true,
                  ),
                ),
                appClockProvider.overrideWithValue(() => baseNow),
                activeFamilyProvider.overrideWith(
                  () => _PresetFamilyNotifier(family),
                ),
                activeChildModeProvider.overrideWith(
                  () => _PresetActiveChildNotifier(child),
                ),
                currentUserIdProvider.overrideWithValue('parent-a'),
                localDraftStoreProvider.overrideWithValue(db),
                localMetadataStoreProvider.overrideWithValue(
                  InMemoryMobileMetadataStore(),
                ),
                localEvidenceFileStoreProvider.overrideWithValue(fileStore),
                authSessionPortProvider.overrideWithValue(authPort),
                recoveryAuthorizationPortProvider.overrideWithValue(authzPort),
              ],
              child: const MaterialApp(home: Scaffold(body: ChildModeScreen())),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text('Unsubmitted Local Drafts (1)'), findsOneWidget);
          expect(
            find.byKey(const Key('delete_draft_ui-unbound-1')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('confirmed_local_drafts_section')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('delete_draft_ui-conf-1')), findsNothing);

          final rawActor = await db
              .customSelect(
                "SELECT actor_user_id FROM local_assessment_drafts WHERE local_draft_id = 'ui-unbound-1';",
              )
              .getSingle();
          expect(rawActor.data['actor_user_id'], isNull);
          expect(File(snapConf.filePath).existsSync(), isTrue);
        },
      );
    },
  );
}
