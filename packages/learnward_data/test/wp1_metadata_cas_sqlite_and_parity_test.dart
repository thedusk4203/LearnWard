import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  group('LocalMetadataStore atomic batch & CAS parity', () {
    for (final mode in ['sqlite_file', 'in_memory']) {
      test(
        '$mode: applyMetadataBatch commits upserts and deletes atomically',
        () async {
          final harness = await _StoreHarness.create(mode);
          addTearDown(harness.dispose);

          final t0 = DateTime.utc(2026, 11, 25, 10, 0);
          await harness.store.applyMetadataBatch([
            MetadataMutation.upsert(key: 'k1', value: 'v1', updatedAt: t0),
            MetadataMutation.upsert(key: 'k2', value: 'v2', updatedAt: t0),
            MetadataMutation.upsert(key: 'stale', value: 'old', updatedAt: t0),
          ]);

          await harness.store.applyMetadataBatch([
            MetadataMutation.upsert(
              key: 'k1',
              value: 'v1-next',
              updatedAt: t0.add(const Duration(seconds: 5)),
            ),
            const MetadataMutation.delete(key: 'stale'),
          ]);

          expect(await harness.store.readMetadata('k1'), equals('v1-next'));
          expect(await harness.store.readMetadata('k2'), equals('v2'));
          expect(await harness.store.readMetadata('stale'), isNull);

          if (mode == 'sqlite_file') {
            final reopened = harness.reopenSqlite();
            addTearDown(reopened.close);
            expect(await reopened.readMetadata('k1'), equals('v1-next'));
            expect(await reopened.readMetadata('stale'), isNull);
          }
        },
      );

      if (mode == 'sqlite_file') {
        test('sqlite_file: applyMetadataBatch rolls back entire batch when mid-batch statement aborts', () async {
          final harness = await _StoreHarness.create(mode);
          addTearDown(harness.dispose);
          final db = harness.sqliteDb!;
          final t0 = DateTime.utc(2026, 11, 25, 10, 0);

          await db.writeMetadata(key: 'good', value: 'initial', updatedAt: t0);
          await db.customStatement('''
              CREATE TRIGGER abort_poison_metadata
              BEFORE INSERT ON local_metadata_entries
              WHEN NEW."key" = 'poison'
              BEGIN
                SELECT RAISE(ABORT, 'simulated mid-batch failure');
              END;
            ''');

          await expectLater(
            () => db.applyMetadataBatch([
              MetadataMutation.upsert(
                key: 'good',
                value: 'mutated',
                updatedAt: t0,
              ),
              MetadataMutation.upsert(
                key: 'poison',
                value: 'boom',
                updatedAt: t0,
              ),
            ]),
            throwsA(anything),
          );

          // Atomic rollback: neither 'good' mutation nor 'poison' persisted.
          expect(await db.readMetadata('good'), equals('initial'));
          expect(await db.readMetadata('poison'), isNull);
        });
      }

      test(
        '$mode: Barrier 1 (onBeforePreCommitGuard) aborts CAS cleanly via preCommitGuard',
        () async {
          final harness = await _StoreHarness.create(mode);
          addTearDown(harness.dispose);

          final t0 = DateTime.utc(2026, 11, 25, 10, 0);
          await harness.store.writeMetadata(
            key: 'lock',
            value: 'locked',
            updatedAt: t0,
          );

          var guardValid = true;
          final committed = await harness.store.compareAndSwapMetadataBatch(
            expectedValues: {'lock': 'locked'},
            mutations: [
              const MetadataMutation.delete(key: 'lock'),
              MetadataMutation.upsert(
                key: 'fence',
                value: 'unlocked',
                updatedAt: t0.add(const Duration(seconds: 1)),
              ),
            ],
            onBeforePreCommitGuard: () async {
              guardValid = false;
            },
            preCommitGuard: () => guardValid,
          );

          expect(committed, isFalse);
          expect(await harness.store.readMetadata('lock'), equals('locked'));
          expect(await harness.store.readMetadata('fence'), isNull);
        },
      );

      test(
        '$mode: CAS rejects mismatch when expected absent key already exists or value differs',
        () async {
          final harness = await _StoreHarness.create(mode);
          addTearDown(harness.dispose);

          final t0 = DateTime.utc(2026, 11, 25, 10, 0);
          await harness.store.writeMetadata(
            key: 'rev',
            value: '2',
            updatedAt: t0,
          );

          final wrongValue = await harness.store.compareAndSwapMetadataBatch(
            expectedValues: {'rev': '1'},
            mutations: [
              MetadataMutation.upsert(key: 'rev', value: '3', updatedAt: t0),
            ],
          );
          expect(wrongValue, isFalse);

          final expectedAbsent = await harness.store
              .compareAndSwapMetadataBatch(
                expectedValues: {'rev': null},
                mutations: [
                  MetadataMutation.upsert(
                    key: 'rev',
                    value: '9',
                    updatedAt: t0,
                  ),
                ],
              );
          expect(expectedAbsent, isFalse);
          expect(await harness.store.readMetadata('rev'), equals('2'));
        },
      );
    }

    test('R39-01: SQLite preCommitGuard runs inside transaction after preliminary read and before mutation admission', () async {
      final tempDir = Directory.systemTemp.createTempSync('lw_wp1_r39_01_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}r39_01.sqlite',
      );
      final db = AppDatabase(NativeDatabase(dbFile));
      final t0 = DateTime.utc(2026, 11, 25, 10, 0);

      await db.applyMetadataBatch([
        MetadataMutation.upsert(
          key: 'active_child_session',
          value: '{"id":"child-a","family_id":"fam-a"}',
          updatedAt: t0,
        ),
        MetadataMutation.upsert(
          key: 'parent_gate_credential_v2',
          value: '{"version":2,"revision":1}',
          updatedAt: t0,
        ),
      ]);

      // Preliminary expectedValues read succeeds inside txn; then live guard
      // invalidates inside Barrier 1 BEFORE SQLite mutation admission.
      var liveGuardValid = true;
      var barrier1Ran = false;
      final committed = await db.compareAndSwapMetadataBatch(
        expectedValues: {
          'active_child_session': '{"id":"child-a","family_id":"fam-a"}',
          'parent_gate_credential_v2': '{"version":2,"revision":1}',
        },
        mutations: [
          const MetadataMutation.delete(key: 'active_child_session'),
          MetadataMutation.upsert(
            key: 'parent_gate_credential_v2',
            value: '{"version":2,"revision":2}',
            updatedAt: t0,
          ),
        ],
        onBeforePreCommitGuard: () async {
          barrier1Ran = true;
          liveGuardValid = false;
        },
        preCommitGuard: () => liveGuardValid,
      );

      expect(barrier1Ran, isTrue);
      expect(committed, isFalse);
      await db.close();

      final reopened = AppDatabase(NativeDatabase(dbFile));
      addTearDown(reopened.close);
      expect(
        await reopened.readMetadata('active_child_session'),
        equals('{"id":"child-a","family_id":"fam-a"}'),
      );
      expect(
        await reopened.readMetadata('parent_gate_credential_v2'),
        equals('{"version":2,"revision":1}'),
      );
    });

    test('Barrier 2 (onAfterGuardBeforeCommit) preserves in-memory CAS abort and SQLite WAL pre-commit isolation + rollback safety', () async {
      // 1) In-memory parity: overlapping CAS commits cleanly abort stale Barrier 2 writer
      final memStore = InMemoryLocalMetadataStore();
      final t0 = DateTime.utc(2026, 11, 25, 10, 0);
      await memStore.writeMetadata(key: 'slot', value: 'v1', updatedAt: t0);

      final memBarrierEntered = Completer<void>();
      final memReleaseBarrier = Completer<void>();
      final memFirst = memStore.compareAndSwapMetadataBatch(
        expectedValues: {'slot': 'v1'},
        mutations: [
          MetadataMutation.upsert(
            key: 'slot',
            value: 'v2-from-first',
            updatedAt: t0,
          ),
        ],
        preCommitGuard: () => true,
        onAfterGuardBeforeCommit: () async {
          memBarrierEntered.complete();
          await memReleaseBarrier.future;
        },
      );
      await memBarrierEntered.future;
      final memSecond = await memStore.compareAndSwapMetadataBatch(
        expectedValues: {'slot': 'v1'},
        mutations: [
          MetadataMutation.upsert(
            key: 'slot',
            value: 'v2-from-second',
            updatedAt: t0,
          ),
        ],
      );
      memReleaseBarrier.complete();
      expect(memSecond, isTrue);
      expect(await memFirst, isFalse);
      expect(await memStore.readMetadata('slot'), equals('v2-from-second'));

      // 2) File-backed SQLite WAL Barrier 2:
      //    (a) Uncommitted write in Barrier 2 is invisible to WAL readers until COMMIT,
      //        while an in-process UI transition flips fail-closed (t_commit < t_event).
      final tempDir = Directory.systemTemp.createTempSync('lw_wp1_cas_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final dbFile = File('${tempDir.path}${Platform.pathSeparator}cas.sqlite');
      final conn1 = AppDatabase(NativeDatabase.createInBackground(dbFile));
      final conn2 = AppDatabase(NativeDatabase.createInBackground(dbFile));
      addTearDown(() async {
        await conn1.close();
        await conn2.close();
      });

      await conn1.writeMetadata(key: 'slot', value: 'v1', updatedAt: t0);
      expect(await conn2.readMetadata('slot'), equals('v1'));

      var uiLiveFailClosed = false;
      String? readerValueDuringBarrier2;
      final sqlFirst = await conn1.compareAndSwapMetadataBatch(
        expectedValues: {'slot': 'v1'},
        mutations: [
          MetadataMutation.upsert(
            key: 'slot',
            value: 'v2-conn1',
            updatedAt: t0,
          ),
        ],
        preCommitGuard: () => true,
        onAfterGuardBeforeCommit: () async {
          readerValueDuringBarrier2 = await conn2.readMetadata('slot');
          uiLiveFailClosed = true;
        },
      );

      expect(sqlFirst, isTrue);
      expect(readerValueDuringBarrier2, equals('v1'));
      expect(uiLiveFailClosed, isTrue);
      expect(await conn2.readMetadata('slot'), equals('v2-conn1'));

      //    (b) Simulated crash/error inside Barrier 2 before COMMIT rolls back atomically.
      await expectLater(
        () => conn1.compareAndSwapMetadataBatch(
          expectedValues: {'slot': 'v2-conn1'},
          mutations: [
            MetadataMutation.upsert(
              key: 'slot',
              value: 'v3-aborted',
              updatedAt: t0,
            ),
          ],
          preCommitGuard: () => true,
          onAfterGuardBeforeCommit: () async {
            throw StateError('simulated crash before COMMIT');
          },
        ),
        throwsStateError,
      );
      expect(await conn1.readMetadata('slot'), equals('v2-conn1'));
      expect(await conn2.readMetadata('slot'), equals('v2-conn1'));
    });

    test('multi-connection SQLite CAS increments lose zero updates across 10 concurrent writers', () async {
      final tempDir = Directory.systemTemp.createTempSync('lw_wp1_race_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}race.sqlite',
      );
      final conn1 = AppDatabase(NativeDatabase.createInBackground(dbFile));
      final conn2 = AppDatabase(NativeDatabase.createInBackground(dbFile));
      addTearDown(() async {
        await conn1.close();
        await conn2.close();
      });

      final t0 = DateTime.utc(2026, 11, 25, 10, 0);
      await conn1.writeMetadata(key: 'counter', value: '0', updatedAt: t0);

      Future<void> incrementWithRetry(AppDatabase db) async {
        while (true) {
          final current = int.parse((await db.readMetadata('counter'))!);
          final ok = await db.compareAndSwapMetadataBatch(
            expectedValues: {'counter': '$current'},
            mutations: [
              MetadataMutation.upsert(
                key: 'counter',
                value: '${current + 1}',
                updatedAt: t0,
              ),
            ],
          );
          if (ok) return;
        }
      }

      await Future.wait([
        for (var i = 0; i < 10; i++)
          incrementWithRetry(i.isEven ? conn1 : conn2),
      ]);

      expect(await conn1.readMetadata('counter'), equals('10'));
      expect(await conn2.readMetadata('counter'), equals('10'));
    });
  });

  group('LegacyOutboxProvenanceSource (AppDatabase + InMemory parity)', () {
    test('AppDatabase.listActorBoundRecords reads only non-empty actor_user_id drafts and reward commands', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final t0 = DateTime.utc(2026, 11, 25, 10, 0);
      // 1) Legacy draft WITHOUT actor_user_id -> MUST NOT appear
      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'draft-legacy',
          familyId: 'fam-legacy',
          childId: 'child-legacy',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Legacy',
          assessmentType: 'quiz',
          difficulty: 'easy',
          rawScore: 8,
          maxScore: 10,
          occurredAt: t0,
          updatedAt: t0,
          actorUserId: null,
        ),
      );

      // 2) Actor-bound draft -> MUST appear with (familyId, childId)
      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'draft-bound',
          familyId: 'fam-a',
          childId: 'child-a',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Bound',
          assessmentType: 'quiz',
          difficulty: 'easy',
          rawScore: 9,
          maxScore: 10,
          occurredAt: t0,
          updatedAt: t0,
          actorUserId: 'actor-a',
          actorRole: 'owner',
        ),
      );

      // 3) Actor-bound household reward command (childId == null) -> MUST preserve null childId
      await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.cancelReward,
          commandId: 'cmd-null-child',
          familyId: 'fam-a',
          childId: null,
          redemptionId: 'red-1',
          cancellationReason: 'test',
          createdAt: t0,
          actorUserId: 'actor-a',
          actorRole: 'owner',
        ),
      );

      // 4) Legacy reward command with blank actor_user_id -> MUST NOT appear
      await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-blank-actor',
          familyId: 'fam-b',
          childId: 'child-b',
          rewardId: 'rew-1',
          createdAt: t0,
          actorUserId: '   ',
          actorRole: 'parent',
        ),
      );

      final records = await db.listActorBoundRecords();
      expect(records, hasLength(2));

      final draftRec = records.singleWhere(
        (r) => r.source == LegacyOutboxRecordSource.assessmentDraft,
      );
      expect(draftRec.recordId, equals('draft-bound'));
      expect(draftRec.familyId, equals('fam-a'));
      expect(draftRec.childId, equals('child-a'));
      expect(draftRec.actorUserId, equals('actor-a'));

      final cmdRec = records.singleWhere(
        (r) => r.source == LegacyOutboxRecordSource.rewardCommand,
      );
      expect(cmdRec.recordId, equals('cmd-null-child'));
      expect(cmdRec.familyId, equals('fam-a'));
      expect(cmdRec.childId, isNull);
      expect(cmdRec.actorUserId, equals('actor-a'));
    });
  });
}

final class _StoreHarness {
  _StoreHarness._({
    required this.store,
    required this.tempDir,
    required this.dbFile,
    required this.sqliteDb,
  });

  final LocalMetadataStore store;
  final Directory? tempDir;
  final File? dbFile;
  final AppDatabase? sqliteDb;

  static Future<_StoreHarness> create(String mode) async {
    if (mode == 'in_memory') {
      return _StoreHarness._(
        store: InMemoryLocalMetadataStore(),
        tempDir: null,
        dbFile: null,
        sqliteDb: null,
      );
    }
    final dir = Directory.systemTemp.createTempSync('lw_wp1_meta_');
    final file = File('${dir.path}${Platform.pathSeparator}meta.sqlite');
    final db = AppDatabase(NativeDatabase(file));
    return _StoreHarness._(store: db, tempDir: dir, dbFile: file, sqliteDb: db);
  }

  AppDatabase reopenSqlite() => AppDatabase(NativeDatabase(dbFile!));

  Future<void> dispose() async {
    await sqliteDb?.close();
    if (tempDir != null && tempDir!.existsSync()) {
      tempDir!.deleteSync(recursive: true);
    }
  }
}
