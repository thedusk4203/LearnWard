import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Test database subclass simulating an interrupted migration midway through v5 -> v6
class CrashingV6AppDatabase extends AppDatabase {
  CrashingV6AppDatabase(super.executor);

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      await customStatement('PRAGMA foreign_keys = OFF');
      try {
        await transaction(() async {
          if (from < 6) {
            // Add one column, then throw to simulate crash/interruption mid-upgrade
            await migrator.addColumn(
              pendingRewardCommands,
              pendingRewardCommands.retryCount,
            );
            throw StateError(
              'Simulated crash / process termination midway through v5 -> v6 migration',
            );
          }
        });
      } finally {
        await customStatement('PRAGMA foreign_keys = ON');
      }
    },
  );
}

void main() {
  group('Drift Schema Migration Matrix (v1-v5 -> v6)', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'learnward_v6_migration_test_',
      );
      dbFile = File('${tempDir.path}/migration_test.sqlite');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    void createV1Database(File file) {
      final db = sqlite3.open(file.path);
      try {
        db.execute('PRAGMA user_version = 1;');
        db.execute('''
          CREATE TABLE "local_metadata_entries" (
            "key" TEXT NOT NULL PRIMARY KEY,
            "value" TEXT NOT NULL,
            "updated_at" INTEGER NOT NULL
          );
        ''');
        db.execute('''
          INSERT INTO "local_metadata_entries" ("key", "value", "updated_at")
          VALUES ('v1_probe', 'v1_data', 1729000000000);
        ''');
      } finally {
        db.close();
      }
    }

    void createV2Database(File file) {
      final db = sqlite3.open(file.path);
      try {
        db.execute('PRAGMA user_version = 2;');
        db.execute('''
          CREATE TABLE "local_metadata_entries" (
            "key" TEXT NOT NULL PRIMARY KEY,
            "value" TEXT NOT NULL,
            "updated_at" INTEGER NOT NULL
          );
        ''');
        db.execute('''
          CREATE TABLE "local_assessment_drafts" (
            "local_draft_id" TEXT NOT NULL PRIMARY KEY,
            "family_id" TEXT NOT NULL,
            "child_id" TEXT NOT NULL,
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
        db.execute('''
          INSERT INTO "local_metadata_entries" ("key", "value", "updated_at")
          VALUES ('v2_probe', 'v2_data', 1729500000000);
        ''');
      } finally {
        db.close();
      }
    }

    void createV3Database(File file) {
      final db = sqlite3.open(file.path);
      try {
        db.execute('PRAGMA user_version = 3;');
        db.execute('''
          CREATE TABLE "local_metadata_entries" (
            "key" TEXT NOT NULL PRIMARY KEY,
            "value" TEXT NOT NULL,
            "updated_at" INTEGER NOT NULL
          );
        ''');
        db.execute('''
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
        db.execute('''
          INSERT INTO "local_metadata_entries" ("key", "value", "updated_at")
          VALUES ('v3_probe', 'v3_data', 1729800000000);
        ''');
      } finally {
        db.close();
      }
    }

    void createV4Database(File file) {
      final db = sqlite3.open(file.path);
      try {
        db.execute('PRAGMA user_version = 4;');
        db.execute('''
          CREATE TABLE "local_metadata_entries" (
            "key" TEXT NOT NULL PRIMARY KEY,
            "value" TEXT NOT NULL,
            "updated_at" INTEGER NOT NULL
          );
        ''');
        db.execute('''
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
        db.execute('''
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
        db.execute('''
          INSERT INTO "local_metadata_entries" ("key", "value", "updated_at")
          VALUES ('v4_probe', 'v4_data', 1730000000000);
        ''');
        db.execute('''
          INSERT INTO "local_assessment_drafts" (
            "local_draft_id", "family_id", "child_id",
            "subject_key", "subject", "title", "assessment_type", "difficulty",
            "raw_score", "max_score", "occurred_at", "updated_at"
          ) VALUES (
            'draft-v4', 'fam-v4', 'child-v4',
            'math', 'Mathematics', 'V4 Quiz', 'quiz', 'normal',
            9.0, 10.0, 1730000000000, 1730000000000
          );
        ''');
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "created_at"
          ) VALUES (
            'spin_wheel', 'cmd-v4', 'fam-v4', 'child-v4', 1730000000000
          );
        ''');
      } finally {
        db.close();
      }
    }

    void createV5Database(File file) {
      final db = sqlite3.open(file.path);
      try {
        db.execute('PRAGMA user_version = 5;');
        db.execute('''
          CREATE TABLE "local_metadata_entries" (
            "key" TEXT NOT NULL PRIMARY KEY,
            "value" TEXT NOT NULL,
            "updated_at" INTEGER NOT NULL
          );
        ''');
        db.execute('''
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
            "updated_at" INTEGER NOT NULL,
            "server_evidence_id" TEXT,
            "sha256_checksum" TEXT,
            "local_compressed_photo_path" TEXT,
            "submission_status" TEXT NOT NULL DEFAULT 'draft',
            "retry_count" INTEGER NOT NULL DEFAULT 0,
            "dispatch_state" TEXT NOT NULL DEFAULT 'unknown_legacy',
            "last_error_message" TEXT,
            "actor_user_id" TEXT,
            "actor_role" TEXT
          );
        ''');
        db.execute('''
          CREATE TABLE "pending_reward_commands" (
            "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            "operation" TEXT NOT NULL,
            "command_id" TEXT NOT NULL UNIQUE,
            "family_id" TEXT NOT NULL,
            "child_id" TEXT,
            "reward_id" TEXT,
            "redemption_id" TEXT,
            "cancellation_reason" TEXT,
            "created_at" INTEGER NOT NULL,
            "actor_user_id" TEXT,
            "actor_role" TEXT,
            "schema_version" INTEGER NOT NULL DEFAULT 1,
            "recovery_state" TEXT NOT NULL DEFAULT 'active',
            "dispatch_state" TEXT NOT NULL DEFAULT 'unknown_legacy'
          );
        ''');
        db.execute('''
          INSERT INTO "local_metadata_entries" ("key", "value", "updated_at")
          VALUES ('v5_probe', 'v5_data', 1731000000000);
        ''');
        db.execute('''
          INSERT INTO "local_assessment_drafts" (
            "local_draft_id", "family_id", "child_id",
            "subject_key", "subject", "title", "assessment_type", "difficulty",
            "raw_score", "max_score", "occurred_at", "updated_at",
            "submission_status", "retry_count", "dispatch_state", "actor_user_id"
          ) VALUES (
            'draft-v5-active', 'fam-v5', 'child-v5',
            'science', 'Science', 'V5 Active Quiz', 'quiz', 'normal',
            10.0, 10.0, 1731000000000, 1731000000000,
            'draft', 1, 'possibly_dispatched', 'actor-user-v5'
          );
        ''');
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id",
            "created_at", "actor_user_id", "actor_role", "recovery_state", "dispatch_state"
          ) VALUES (
            'redeem_reward', 'cmd-v5-active', 'fam-v5', 'child-v5', 'rew-1',
            1731000000000, 'actor-user-v5', 'child', 'active', 'possibly_dispatched'
          );
        ''');
      } finally {
        db.close();
      }
    }

    test('upgrades directly from v1 to v6', () async {
      createV1Database(dbFile);

      final db = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(db.schemaVersion, 6);
        expect(await db.readMetadata('v1_probe'), 'v1_data');

        final userVersion =
            (await db.customSelect('PRAGMA user_version').getSingle())
                .data['user_version'];
        expect(userVersion, 6);
      } finally {
        await db.close();
      }
    });

    test('upgrades directly from v2 to v6', () async {
      createV2Database(dbFile);

      final db = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(db.schemaVersion, 6);
        expect(await db.readMetadata('v2_probe'), 'v2_data');

        final userVersion =
            (await db.customSelect('PRAGMA user_version').getSingle())
                .data['user_version'];
        expect(userVersion, 6);
      } finally {
        await db.close();
      }
    });

    test('upgrades directly from v3 to v6', () async {
      createV3Database(dbFile);

      final db = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(db.schemaVersion, 6);
        expect(await db.readMetadata('v3_probe'), 'v3_data');

        final userVersion =
            (await db.customSelect('PRAGMA user_version').getSingle())
                .data['user_version'];
        expect(userVersion, 6);
      } finally {
        await db.close();
      }
    });

    test(
      'upgrades directly from v4 to v6 and enforces legacy quarantine',
      () async {
        createV4Database(dbFile);

        final db = AppDatabase(NativeDatabase(dbFile));
        try {
          expect(db.schemaVersion, 6);
          expect(await db.readMetadata('v4_probe'), 'v4_data');

          final userVersion =
              (await db.customSelect('PRAGMA user_version').getSingle())
                  .data['user_version'];
          expect(userVersion, 6);

          // Verify draft was quarantined as unknown_legacy with null actor
          final draft = await db.getLocalDraft('draft-v4');
          expect(draft, isNotNull);
          expect(draft!.dispatchState, CommandDispatchState.unknownLegacy);
          expect(draft.actorUserId, isNull);
          expect(draft.canAutoSubmit, isFalse);
          expect(draft.nextAttemptAt, isNull);
          expect(draft.leaseToken, isNull);

          // Verify command was quarantined as unknown_legacy with null actor
          final cmd = await db.getPendingCommand('cmd-v4');
          expect(cmd, isNotNull);
          expect(
            cmd!.recoveryState,
            CommandRecoveryState.quarantinedUnknownOutcome,
          );
          expect(cmd.dispatchState, CommandDispatchState.unknownLegacy);
          expect(cmd.actorUserId, isNull);
          expect(cmd.canAutoReplay, isFalse);
          expect(cmd.retryCount, 0);
          expect(cmd.leaseToken, isNull);
        } finally {
          await db.close();
        }
      },
    );

    test('upgrades directly from v5 to v6 preserving v5 data and adding v6 columns', () async {
      createV5Database(dbFile);

      final db = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(db.schemaVersion, 6);
        expect(await db.readMetadata('v5_probe'), 'v5_data');

        final userVersion =
            (await db.customSelect('PRAGMA user_version').getSingle())
                .data['user_version'];
        expect(userVersion, 6);

        // Verify v5 draft preserved data and received v6 columns
        final draft = await db.getLocalDraft('draft-v5-active');
        expect(draft, isNotNull);
        expect(draft!.familyId, 'fam-v5');
        expect(draft.actorUserId, 'actor-user-v5');
        expect(draft.dispatchState, CommandDispatchState.possiblyDispatched);
        expect(draft.nextAttemptAt, isNull);
        expect(draft.leaseToken, isNull);
        expect(draft.leaseExpiresAt, isNull);

        // Verify v5 command preserved data and received v6 columns with defaults
        final cmd = await db.getPendingCommand('cmd-v5-active');
        expect(cmd, isNotNull);
        expect(cmd!.familyId, 'fam-v5');
        expect(cmd.actorUserId, 'actor-user-v5');
        expect(cmd.recoveryState, CommandRecoveryState.active);
        expect(cmd.dispatchState, CommandDispatchState.possiblyDispatched);
        expect(cmd.retryCount, 0);
        expect(cmd.nextAttemptAt, isNull);
        expect(cmd.lastErrorMessage, isNull);
        expect(cmd.leaseToken, isNull);
        expect(cmd.leaseExpiresAt, isNull);
      } finally {
        await db.close();
      }
    });

    test('atomic rollback on interrupted v5 -> v6 migration and successful clean reopen', () async {
      createV5Database(dbFile);

      final rawDbBefore = sqlite3.open(dbFile.path);
      expect(rawDbBefore.userVersion, 5);
      rawDbBefore.close();

      // Attempt migration with CrashingV6AppDatabase
      final crashingDb = CrashingV6AppDatabase(NativeDatabase(dbFile));
      try {
        await crashingDb.customSelect('SELECT 1;').get();
        fail('Should have thrown StateError');
      } on StateError catch (e) {
        expect(e.message, contains('Simulated crash'));
      } finally {
        await crashingDb.close();
      }

      // Verify transaction rolled back: PRAGMA user_version remains 5
      final rawDbAfterCrash = sqlite3.open(dbFile.path);
      expect(rawDbAfterCrash.userVersion, 5);

      // Verify partially added column was rolled back
      final cols = rawDbAfterCrash.select(
        "PRAGMA table_info('pending_reward_commands');",
      );
      final colNames = cols.map((row) => row['name'] as String).toList();
      expect(colNames.contains('retry_count'), isFalse);
      expect(colNames.contains('lease_token'), isFalse);
      rawDbAfterCrash.close();

      // Normal application reopen succeeds cleanly without error
      final standardDb = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(standardDb.schemaVersion, 6);
        final userVersion =
            (await standardDb.customSelect('PRAGMA user_version').getSingle())
                .data['user_version'];
        expect(userVersion, 6);

        final cmd = await standardDb.getPendingCommand('cmd-v5-active');
        expect(cmd, isNotNull);
        expect(cmd!.actorUserId, 'actor-user-v5');
        expect(cmd.retryCount, 0);
      } finally {
        await standardDb.close();
      }
    });
  });
}
