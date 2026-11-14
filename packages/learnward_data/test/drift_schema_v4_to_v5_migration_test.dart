import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Test database subclass simulating a crash or network interruption midway through migration
class CrashingAppDatabase extends AppDatabase {
  CrashingAppDatabase(super.executor);

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      await customStatement('PRAGMA foreign_keys = OFF');
      try {
        await transaction(() async {
          // Add one column, then throw to simulate crash/power loss mid-upgrade
          await migrator.addColumn(
            localAssessmentDrafts,
            localAssessmentDrafts.serverEvidenceId,
          );
          throw StateError(
            'Simulated process crash / power failure midway through migration',
          );
        });
      } finally {
        await customStatement('PRAGMA foreign_keys = ON');
      }
    },
  );
}

void main() {
  group('Drift Schema v4 -> v5 Migration & Backward Compatibility', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'learnward_v4_v5_migration_',
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

    /// Helper creating a real SQLite v1 database (only metadata table)
    void createAndPopulateV1Database(File file) {
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
          VALUES ('v1_probe', 'v1_initial_data', 1729000000000);
        ''');
      } finally {
        db.close();
      }
    }

    /// Helper creating a real SQLite v2 database (metadata + local_assessment_drafts without v3/v5 columns)
    void createAndPopulateV2Database(File file) {
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
            "updated_at" INTEGER NOT NULL,
            "server_assessment_id" TEXT
          );
        ''');
        db.execute('''
          INSERT INTO "local_metadata_entries" ("key", "value", "updated_at")
          VALUES ('v2_probe', 'v2_initial_data', 1729500000000);
        ''');
        db.execute('''
          INSERT INTO "local_assessment_drafts" (
            "local_draft_id", "family_id", "child_id",
            "subject_key", "subject", "title", "assessment_type", "difficulty",
            "raw_score", "max_score", "occurred_at", "updated_at"
          ) VALUES (
            'draft-v2-1', 'fam-v2-1', 'child-v2-1',
            'math', 'Mathematics', 'V2 Historical Quiz', 'quiz', 'normal',
            9.0, 10.0, 1729500000000, 1729500000000
          );
        ''');
      } finally {
        db.close();
      }
    }

    /// Helper creating a real SQLite v3 database (with v3 draft columns, but no pending_reward_commands)
    void createAndPopulateV3Database(File file) {
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
          VALUES ('v3_probe', 'v3_initial_data', 1729800000000);
        ''');
        db.execute('''
          INSERT INTO "local_assessment_drafts" (
            "local_draft_id", "family_id", "child_id",
            "create_command_id", "submit_command_id", "evidence_id", "server_assessment_id",
            "subject_key", "subject", "title", "assessment_type", "difficulty",
            "raw_score", "max_score", "occurred_at", "updated_at"
          ) VALUES (
            'draft-v3-1', 'fam-v3-1', 'child-v3-1',
            'cmd-create-v3', 'cmd-submit-v3', 'ev-v3-1', 'srv-ass-v3',
            'science', 'Science', 'V3 Inflight Draft', 'quiz', 'normal',
            8.0, 10.0, 1729800000000, 1729800000000
          );
        ''');
      } finally {
        db.close();
      }
    }

    /// Helper creating a real SQLite v4 database populated with exact Drift v4 tables and rows
    void createAndPopulateV4Database(File file) {
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
          VALUES ('schema_probe', 'v4_initial', 1730000000000);
        ''');
        db.execute('''
          INSERT INTO "local_assessment_drafts" (
            "local_draft_id", "family_id", "child_id",
            "create_command_id", "submit_command_id", "evidence_id", "server_assessment_id",
            "subject_key", "subject", "title", "assessment_type", "difficulty",
            "raw_score", "max_score", "local_photo_path", "entry_context",
            "occurred_at", "updated_at"
          ) VALUES (
            'draft-v4-offline', 'fam-v4-1', 'child-v4-1',
            NULL, NULL, NULL, NULL,
            'math', 'Mathematics', 'Weekly Quiz 1', 'quiz', 'normal',
            8.5, 10.0, '/data/user/0/com.learnward/cache/photo_offline.jpg', 'shared_child',
            1730000000000, 1730000000000
          );
        ''');
        db.execute('''
          INSERT INTO "local_assessment_drafts" (
            "local_draft_id", "family_id", "child_id",
            "create_command_id", "submit_command_id", "evidence_id", "server_assessment_id",
            "subject_key", "subject", "title", "assessment_type", "difficulty",
            "raw_score", "max_score", "local_photo_path", "entry_context",
            "occurred_at", "updated_at"
          ) VALUES (
            'draft-v4-inflight', 'fam-v4-1', 'child-v4-1',
            'cmd-create-v4', 'cmd-submit-v4', 'ev-client-uuid-v4', 'srv-ass-0099',
            'math', 'Mathematics', 'Weekly Quiz 2 Inflight', 'quiz', 'normal',
            9.0, 10.0, '/data/user/0/com.learnward/cache/photo_inflight.jpg', 'shared_child',
            1730100000000, 1730100000000
          );
        ''');
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id",
            "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'redeem_reward', 'cmd-redeem-v4', 'fam-v4-1', 'child-v4-1', 'rew-v4-book',
            NULL, NULL, 1730200000000
          );
        ''');
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id",
            "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'spin_wheel', 'cmd-spin-v4', 'fam-v4-1', 'child-v4-1', NULL,
            NULL, NULL, 1730210000000
          );
        ''');
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id",
            "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'fulfill_reward', 'cmd-fulfill-v4', 'fam-v4-1', 'child-v4-1', NULL,
            'red-v4-101', NULL, 1730220000000
          );
        ''');
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id",
            "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'cancel_reward', 'cmd-cancel-v4', 'fam-v4-1', 'child-v4-1', NULL,
            'red-v4-102', 'Out of stock at bookstore', 1730230000000
          );
        ''');
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id",
            "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'spin_wheel', 'cmd-nullable-v4', 'fam-v4-1', NULL, NULL,
            NULL, NULL, 1730304000000
          );
        ''');
      } finally {
        db.close();
      }
    }

    test(
      'populates real SQLite v4 database and successfully upgrades to v5',
      () async {
        createAndPopulateV4Database(dbFile);

        final rawDbBefore = sqlite3.open(dbFile.path);
        expect(rawDbBefore.userVersion, 4);
        rawDbBefore.close();

        final database = AppDatabase(NativeDatabase(dbFile));
        try {
          expect(database.schemaVersion, 6);

          // Metadata survived
          final probe = await database.readMetadata('schema_probe');
          expect(probe, 'v4_initial');

          // PRAGMA user_version is 6
          final rawCheck = await database
              .customSelect('PRAGMA user_version')
              .getSingle();
          expect(rawCheck.data['user_version'], 6);

          // Draft migration: offline draft preserves NULL command and evidence IDs
          final offlineDraft = await database.getLocalDraft('draft-v4-offline');
          expect(offlineDraft, isNotNull);
          expect(offlineDraft!.localDraftId, 'draft-v4-offline');
          expect(offlineDraft.familyId, 'fam-v4-1');
          expect(offlineDraft.childId, 'child-v4-1');
          expect(offlineDraft.createCommandId, isNull);
          expect(offlineDraft.submitCommandId, isNull);
          expect(offlineDraft.evidenceId, isNull);
          expect(offlineDraft.serverAssessmentId, isNull);
          expect(
            offlineDraft.dispatchState,
            CommandDispatchState.unknownLegacy,
          );
          expect(offlineDraft.isLegacyUnknown, isTrue);
          expect(offlineDraft.canAutoSubmit, isFalse);

          // Inflight draft preserved
          final inflightDraft = await database.getLocalDraft(
            'draft-v4-inflight',
          );
          expect(inflightDraft, isNotNull);
          expect(inflightDraft!.createCommandId, 'cmd-create-v4');
          expect(inflightDraft.submitCommandId, 'cmd-submit-v4');
          expect(inflightDraft.evidenceId, 'ev-client-uuid-v4');
          expect(inflightDraft.serverAssessmentId, 'srv-ass-0099');
          expect(
            inflightDraft.dispatchState,
            CommandDispatchState.unknownLegacy,
          );
          expect(inflightDraft.canAutoSubmit, isFalse);

          // Commands migration: all 5 legacy commands are quarantined
          final quarantinedCommands = await database.listPendingCommands(
            recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
          );
          expect(quarantinedCommands.length, 5);
          for (final cmd in quarantinedCommands) {
            expect(
              cmd.recoveryState,
              CommandRecoveryState.quarantinedUnknownOutcome,
            );
            expect(cmd.dispatchState, CommandDispatchState.unknownLegacy);
            expect(cmd.canAutoReplay, isFalse);
          }

          // Active commands list is empty
          final activeCommands = await database.listPendingCommands(
            recoveryState: CommandRecoveryState.active,
          );
          expect(activeCommands, isEmpty);

          // Legacy spin, redeem, and redemption lookups return null
          expect(
            await database.findPendingSpinCommand(
              familyId: 'fam-v4-1',
              childId: 'child-v4-1',
            ),
            isNull,
          );
          expect(
            await database.findPendingRedeemCommand(
              familyId: 'fam-v4-1',
              childId: 'child-v4-1',
              rewardId: 'rew-v4-book',
            ),
            isNull,
          );

          // Fresh v5 command creation and lookup
          final freshCmd = PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-spin-v5-fresh',
            familyId: 'fam-v4-1',
            childId: 'child-v4-1',
            actorUserId: 'usr-child-dev-1',
            actorRole: 'paired_child',
            createdAt: DateTime.utc(2026, 11, 6, 12, 10),
          );
          await database.savePendingCommand(freshCmd);

          final activeSpin = await database.findPendingSpinCommand(
            familyId: 'fam-v4-1',
            childId: 'child-v4-1',
          );
          expect(activeSpin, isNotNull);
          expect(activeSpin!.commandId, 'cmd-spin-v5-fresh');
          expect(activeSpin.canAutoReplay, isTrue);

          // Filter by matching actor returns command; mismatched actor returns null
          expect(
            await database.findPendingSpinCommand(
              familyId: 'fam-v4-1',
              childId: 'child-v4-1',
              actorUserId: 'usr-child-dev-1',
            ),
            isNotNull,
          );
          expect(
            await database.findPendingSpinCommand(
              familyId: 'fam-v4-1',
              childId: 'child-v4-1',
              actorUserId: 'usr-different-actor',
            ),
            isNull,
          );
        } finally {
          await database.close();
        }

        // Reopen integrity
        final databaseSecondOpen = AppDatabase(NativeDatabase(dbFile));
        try {
          expect(databaseSecondOpen.schemaVersion, 6);
          expect((await databaseSecondOpen.listPendingCommands()).length, 6);
        } finally {
          await databaseSecondOpen.close();
        }
      },
    );

    test('upgrades directly from v1 to v5, preserving metadata and creating tables cleanly', () async {
      createAndPopulateV1Database(dbFile);

      final rawDbBefore = sqlite3.open(dbFile.path);
      expect(rawDbBefore.userVersion, 1);
      rawDbBefore.close();

      final database = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(database.schemaVersion, 6);
        final probe = await database.readMetadata('v1_probe');
        expect(probe, 'v1_initial_data');

        // Can insert and query drafts
        final draft = LocalAssessmentDraft(
          localDraftId: 'draft-from-v1',
          familyId: 'fam-1',
          childId: 'child-1',
          subjectKey: SubjectKey.science,
          subject: 'Science',
          title: 'V1 Upgrade Test',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 10,
          maxScore: 10,
          actorUserId: 'usr-1',
          occurredAt: DateTime.utc(2026, 11, 6),
          updatedAt: DateTime.utc(2026, 11, 6),
        );
        await database.saveLocalDraft(draft);
        final loadedDraft = await database.getLocalDraft('draft-from-v1');
        expect(loadedDraft, isNotNull);
        expect(loadedDraft!.canAutoSubmit, isTrue);

        // Can insert and query commands
        final cmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-from-v1',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'usr-1',
          createdAt: DateTime.utc(2026, 11, 6),
        );
        await database.savePendingCommand(cmd);
        final loadedCmd = await database.getPendingCommand('cmd-from-v1');
        expect(loadedCmd, isNotNull);
        expect(loadedCmd!.canAutoReplay, isTrue);
      } finally {
        await database.close();
      }
    });

    test('upgrades directly from v2 to v5, adding v3 and v5 columns and quarantining drafts', () async {
      createAndPopulateV2Database(dbFile);

      final rawDbBefore = sqlite3.open(dbFile.path);
      expect(rawDbBefore.userVersion, 2);
      rawDbBefore.close();

      final database = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(database.schemaVersion, 6);
        final probe = await database.readMetadata('v2_probe');
        expect(probe, 'v2_initial_data');

        final draft = await database.getLocalDraft('draft-v2-1');
        expect(draft, isNotNull);
        expect(draft!.title, 'V2 Historical Quiz');
        expect(draft.createCommandId, isNull);
        expect(draft.submitCommandId, isNull);
        expect(draft.evidenceId, isNull);
        expect(draft.dispatchState, CommandDispatchState.unknownLegacy);
        expect(draft.canAutoSubmit, isFalse);

        // Pending reward commands table created cleanly without duplicate column crashes
        final commands = await database.listPendingCommands();
        expect(commands, isEmpty);
      } finally {
        await database.close();
      }
    });

    test(
      'upgrades directly from v3 to v5 without duplicate column errors',
      () async {
        createAndPopulateV3Database(dbFile);

        final rawDbBefore = sqlite3.open(dbFile.path);
        expect(rawDbBefore.userVersion, 3);
        rawDbBefore.close();

        final database = AppDatabase(NativeDatabase(dbFile));
        try {
          expect(database.schemaVersion, 6);
          final probe = await database.readMetadata('v3_probe');
          expect(probe, 'v3_initial_data');

          final draft = await database.getLocalDraft('draft-v3-1');
          expect(draft, isNotNull);
          expect(draft!.createCommandId, 'cmd-create-v3');
          expect(draft.submitCommandId, 'cmd-submit-v3');
          expect(draft.evidenceId, 'ev-v3-1');
          expect(draft.dispatchState, CommandDispatchState.unknownLegacy);
          expect(draft.canAutoSubmit, isFalse);

          // Pending reward commands table created cleanly and accepts fresh commands
          final cmd = PendingRewardCommand(
            operation: RewardCommandOperation.redeemReward,
            commandId: 'cmd-v3-fresh',
            familyId: 'fam-v3-1',
            childId: 'child-v3-1',
            rewardId: 'rew-v3-1',
            actorUserId: 'usr-v3-child',
            createdAt: DateTime.utc(2026, 11, 6),
          );
          await database.savePendingCommand(cmd);
          final loadedCmd = await database.getPendingCommand('cmd-v3-fresh');
          expect(loadedCmd, isNotNull);
          expect(loadedCmd!.canAutoReplay, isTrue);
        } finally {
          await database.close();
        }
      },
    );

    test('atomic rollback on interrupted migration and successful recovery on reopen', () async {
      createAndPopulateV4Database(dbFile);

      // Attempt upgrade with CrashingAppDatabase which throws inside transaction
      final crashingDb = CrashingAppDatabase(NativeDatabase(dbFile));
      try {
        await expectLater(
          () => crashingDb.getLocalDraft('draft-v4-offline'),
          throwsA(isA<StateError>()),
        );
      } finally {
        await crashingDb.close();
      }

      // Verify transaction rolled back: PRAGMA user_version remains 4
      final rawDbAfterCrash = sqlite3.open(dbFile.path);
      expect(rawDbAfterCrash.userVersion, 4);

      // Verify partially added column does NOT exist in table
      final cols = rawDbAfterCrash.select(
        "PRAGMA table_info('local_assessment_drafts');",
      );
      final colNames = cols.map((row) => row['name'] as String).toList();
      expect(colNames.contains('server_evidence_id'), isFalse);
      rawDbAfterCrash.close();

      // Normal application restart / reopen succeeds without duplicate column error
      final standardDb = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(standardDb.schemaVersion, 6);

        // Verify successful full migration to v6
        final rawCheck = await standardDb
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(rawCheck.data['user_version'], 6);

        final draft = await standardDb.getLocalDraft('draft-v4-offline');
        expect(draft, isNotNull);
        expect(draft!.dispatchState, CommandDispatchState.unknownLegacy);
      } finally {
        await standardDb.close();
      }
    });

    test('preserves NULL command identity and unbound actor provenance by failing closed on saveLocalDraft across reopen (R33-01 / R33-03)', () async {
      createAndPopulateV4Database(dbFile);

      final database = AppDatabase(NativeDatabase(dbFile));
      try {
        // Read draft with NULL create/submit command IDs and NULL actor
        final offlineDraft = await database.getLocalDraft('draft-v4-offline');
        expect(offlineDraft, isNotNull);
        expect(offlineDraft!.createCommandId, isNull);
        expect(offlineDraft.submitCommandId, isNull);
        expect(offlineDraft.actorUserId, isNull);

        // Attempting legacy saveLocalDraft overwrite or actor backfill must fail closed
        final updatedDraft = offlineDraft.copyWith(
          title: 'Updated Offline Quiz Title',
          serverAssessmentId: 'srv-partial-draft-101',
          actorUserId: 'adopted-user-1',
        );
        await expectLater(
          () => database.saveLocalDraft(updatedDraft),
          throwsA(isA<DraftWriteConflictException>()),
        );

        // Reload within same connection: original metadata and NULLs preserved untouched
        final reloaded = await database.getLocalDraft('draft-v4-offline');
        expect(reloaded, isNotNull);
        expect(reloaded!.title, 'Weekly Quiz 1');
        expect(reloaded.serverAssessmentId, isNull);
        expect(reloaded.createCommandId, isNull);
        expect(reloaded.submitCommandId, isNull);
        expect(reloaded.actorUserId, isNull);
      } finally {
        await database.close();
      }

      // Reopen database and verify SQLite persisted real NULL values untouched
      final reopenedDb = AppDatabase(NativeDatabase(dbFile));
      try {
        final reloadedAfterReopen = await reopenedDb.getLocalDraft(
          'draft-v4-offline',
        );
        expect(reloadedAfterReopen, isNotNull);
        expect(reloadedAfterReopen!.title, 'Weekly Quiz 1');
        expect(reloadedAfterReopen.createCommandId, isNull);
        expect(reloadedAfterReopen.submitCommandId, isNull);
        expect(reloadedAfterReopen.actorUserId, isNull);
        expect(reloadedAfterReopen.serverAssessmentId, isNull);
      } finally {
        await reopenedDb.close();
      }
    });

    test('fail-closed replay eligibility across actor, quarantine, and committed states', () async {
      final database = AppDatabase(NativeDatabase.memory());
      try {
        // 1. Quarantined legacy command fails closed
        final legacyCmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-legacy-q',
          familyId: 'fam-1',
          childId: 'child-1',
          createdAt: DateTime.utc(2026, 11, 6),
          recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
          dispatchState: CommandDispatchState.unknownLegacy,
        );
        expect(legacyCmd.canAutoReplay, isFalse);

        // 2. Command without actor fails closed
        final cmdWithoutActor = PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-no-actor',
          familyId: 'fam-1',
          childId: 'child-1',
          rewardId: 'rew-1',
          createdAt: DateTime.utc(2026, 11, 6),
        );
        expect(cmdWithoutActor.actorUserId, isNull);
        expect(cmdWithoutActor.canAutoReplay, isFalse);

        // 3. Confirmed committed command fails closed against replay
        final committedCmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-committed',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'usr-1',
          actorRole: 'paired_child',
          createdAt: DateTime.utc(2026, 11, 6),
          dispatchState: CommandDispatchState.confirmedCommitted,
        );
        expect(committedCmd.canAutoReplay, isFalse);

        // 4. Active command with actor is eligible
        final activeCmd = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-active',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'usr-1',
          actorRole: 'paired_child',
          createdAt: DateTime.utc(2026, 11, 6),
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        expect(activeCmd.canAutoReplay, isTrue);

        await database.savePendingCommand(activeCmd);

        // 5. SpinRewardWheel use-case preserves actor binding and prevents replay of mismatched actor
        final fakeServer = FakeWheelRepository(randomSeed: 42);
        fakeServer.addReward(
          Reward(
            id: RewardId('rw-1'),
            familyId: FamilyId('fam-1'),
            title: 'Reward 1',
            category: RewardCategory.item,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            createdAt: DateTime.utc(2026, 11, 6),
            updatedAt: DateTime.utc(2026, 11, 6),
          ),
        );
        fakeServer.addReward(
          Reward(
            id: RewardId('rw-2'),
            familyId: FamilyId('fam-1'),
            title: 'Reward 2',
            category: RewardCategory.item,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            createdAt: DateTime.utc(2026, 11, 6),
            updatedAt: DateTime.utc(2026, 11, 6),
          ),
        );
        fakeServer.addReward(
          Reward(
            id: RewardId('rw-3'),
            familyId: FamilyId('fam-1'),
            title: 'Reward 3',
            category: RewardCategory.item,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            createdAt: DateTime.utc(2026, 11, 6),
            updatedAt: DateTime.utc(2026, 11, 6),
          ),
        );

        final testClock = TestClock(DateTime.utc(2026, 11, 7, 12, 0));
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'usr-different-actor',
          role: 'child',
        );
        final fakeAuthz = FakeRecoveryAuthorizationPort(
          defaultStatus: TargetAuthorizationStatus.authorized,
        );
        final spinUseCase = SpinRewardWheel(
          fakeServer,
          database,
          authSessionPort: fakeAuth,
          authorizationPort: fakeAuthz,
          clock: testClock,
        );

        // 5. Fail closed on actor mismatch: different actor CANNOT replay usr-1's command
        // Must throw StateError, must NOT generate replacement command, must NOT call server
        await expectLater(
          () => spinUseCase(
            familyId: FamilyId('fam-1'),
            childId: ChildId('child-1'),
            actorUserId: 'usr-different-actor',
          ),
          throwsA(isA<StateError>()),
        );

        // usr-1's command is still intact and preserved for reconciliation
        final preservedCmd = await database.findPendingSpinCommand(
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'usr-1',
        );
        expect(preservedCmd, isNotNull);
        expect(preservedCmd!.commandId, equals('cmd-active'));

        // No new command was created for usr-different-actor
        final differentActorCmd = await database.findPendingSpinCommand(
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'usr-different-actor',
        );
        expect(differentActorCmd, isNull);

        // 6. Fail closed on missing caller actor
        fakeAuth.invalidateSession();
        await expectLater(
          () => spinUseCase(
            familyId: FamilyId('fam-1'),
            childId: ChildId('child-1'),
            actorUserId: null,
          ),
          throwsA(isA<StateError>()),
        );

        // 7. Successful replay with matching actor sets possiblyDispatched BEFORE remote RPC
        fakeAuth.setSession(userId: 'usr-1', role: 'child');
        fakeServer.failNextWithNetwork = true;
        await expectLater(
          () => spinUseCase(
            familyId: FamilyId('fam-1'),
            childId: ChildId('child-1'),
            commandId: 'cmd-active',
            actorUserId: 'usr-1',
          ),
          throwsA(isA<Exception>()),
        );

        // Pre-dispatch durability: row is marked possibly_dispatched on disk
        final replayedCmd = await database.findPendingSpinCommand(
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'usr-1',
        );
        expect(replayedCmd, isNotNull);
        expect(replayedCmd!.commandId, equals('cmd-active'));
        expect(
          replayedCmd.dispatchState,
          equals(CommandDispatchState.possiblyDispatched),
        );

        // 8. 42501 permission error does NOT delete the pending command
        testClock.advance(const Duration(minutes: 5));
        fakeServer.failNextWithPermissionError = true;
        await expectLater(
          () => spinUseCase(
            familyId: FamilyId('fam-1'),
            childId: ChildId('child-1'),
            commandId: 'cmd-active',
            actorUserId: 'usr-1',
          ),
          throwsA(anything),
        );
        final stillPendingAfter42501 = await database.findPendingSpinCommand(
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'usr-1',
          recoveryState: null,
        );
        expect(
          stillPendingAfter42501,
          isNotNull,
          reason: '42501 must preserve pending journal row for provenance',
        );
      } finally {
        await database.close();
      }
    });
  });
}
