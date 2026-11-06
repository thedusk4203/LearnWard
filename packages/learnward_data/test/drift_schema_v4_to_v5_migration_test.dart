import 'dart:io';

import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('Drift Schema v4 -> v5 Migration & Backward Compatibility', () {
    late Directory tempDir;
    late File dbFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'learnward_v4_v5_migration_',
      );
      dbFile = File('${tempDir.path}/migration_v4_to_v5.sqlite');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    /// Helper that creates a real SQLite file populated with exact Drift v4 tables and rows.
    void createAndPopulateV4Database(File file) {
      final db = sqlite3.open(file.path);
      try {
        // Set schema version to 4
        db.execute('PRAGMA user_version = 4;');

        // Create exact Drift v4 tables
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

        // Populate metadata
        db.execute('''
          INSERT INTO "local_metadata_entries" ("key", "value", "updated_at")
          VALUES ('schema_probe', 'v4_initial', 1730000000000);
        ''');

        // Populate diverse v4 assessment drafts:
        // Draft 1: Pure offline draft (nullable command/server IDs are null)
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
            1730100000000, 1730101000000
          );
        ''');

        // Draft 2: In-flight draft with partial server work (server_assessment_id populated, evidence_id populated)
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
            'science', 'Science Experiments', 'Unit 3 Test', 'quiz', 'hard',
            9.0, 10.0, '/data/user/0/com.learnward/cache/photo_inflight.jpg', 'parent_supervised',
            1730200000000, 1730201000000
          );
        ''');

        // Populate diverse v4 pending reward commands:
        // Command 1: Redeem Store Reward
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id", "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'redeem_reward', 'cmd-redeem-v4', 'fam-v4-1', 'child-v4-1', 'rew-v4-book', NULL, NULL, 1730300000000
          );
        ''');

        // Command 2: Spin Wheel
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id", "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'spin_wheel', 'cmd-spin-v4', 'fam-v4-1', 'child-v4-1', NULL, NULL, NULL, 1730301000000
          );
        ''');

        // Command 3: Fulfill Reward
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id", "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'fulfill_reward', 'cmd-fulfill-v4', 'fam-v4-1', NULL, NULL, 'red-v4-101', NULL, 1730302000000
          );
        ''');

        // Command 4: Cancel Reward with cancellation reason
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id", "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'cancel_reward', 'cmd-cancel-v4', 'fam-v4-1', NULL, NULL, 'red-v4-102', 'Out of stock at bookstore', 1730303000000
          );
        ''');

        // Command 5: Command with nullable child_id, reward_id, redemption_id, cancellation_reason
        db.execute('''
          INSERT INTO "pending_reward_commands" (
            "operation", "command_id", "family_id", "child_id", "reward_id", "redemption_id", "cancellation_reason", "created_at"
          ) VALUES (
            'spin_wheel', 'cmd-nullable-v4', 'fam-v4-1', NULL, NULL, NULL, NULL, 1730304000000
          );
        ''');
      } finally {
        db.close();
      }
    }

    test('populates real SQLite v4 database and successfully upgrades to v5', () async {
      createAndPopulateV4Database(dbFile);

      // Verify v4 version before opening with AppDatabase
      final rawDbBefore = sqlite3.open(dbFile.path);
      expect(rawDbBefore.userVersion, 4);
      rawDbBefore.close();

      // Open database with AppDatabase (triggers onUpgrade from 4 to 5)
      final database = AppDatabase(NativeDatabase(dbFile));

      try {
        expect(database.schemaVersion, 5);

        // 1. Verify existing metadata survived
        final probe = await database.readMetadata('schema_probe');
        expect(probe, 'v4_initial');

        // 2. Verify PRAGMA user_version is now 5 in SQLite file
        final rawCheck = await database
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(rawCheck.data['user_version'], 5);

        // ---------------------------------------------------------------------
        // DRAFT MIGRATION VERIFICATION
        // ---------------------------------------------------------------------
        final offlineDraft = await database.getLocalDraft('draft-v4-offline');
        expect(offlineDraft, isNotNull);
        expect(offlineDraft!.localDraftId, 'draft-v4-offline');
        expect(offlineDraft.familyId, 'fam-v4-1');
        expect(offlineDraft.childId, 'child-v4-1');
        expect(offlineDraft.subjectKey, SubjectKey.math);
        expect(offlineDraft.title, 'Weekly Quiz 1');
        expect(offlineDraft.rawScore, 8.5);
        expect(offlineDraft.maxScore, 10.0);
        expect(
          offlineDraft.localPhotoPath,
          '/data/user/0/com.learnward/cache/photo_offline.jpg',
        );
        // Nullable IDs remain nullable
        expect(offlineDraft.serverAssessmentId, isNull);
        expect(offlineDraft.evidenceId, isNull);
        expect(offlineDraft.serverEvidenceId, isNull);
        expect(offlineDraft.sha256Checksum, isNull);
        expect(offlineDraft.localCompressedPhotoPath, isNull);
        expect(offlineDraft.actorUserId, isNull);
        expect(offlineDraft.actorRole, isNull);
        // Dispatch provenance: migrated v4 drafts are quarantined as unknown_legacy
        expect(offlineDraft.dispatchState, CommandDispatchState.unknownLegacy);
        expect(offlineDraft.isLegacyUnknown, isTrue);
        expect(
          offlineDraft.canAutoSubmit,
          isFalse,
          reason: 'Legacy unknown drafts must fail closed',
        );

        final inflightDraft = await database.getLocalDraft('draft-v4-inflight');
        expect(inflightDraft, isNotNull);
        expect(inflightDraft!.localDraftId, 'draft-v4-inflight');
        expect(inflightDraft.createCommandId, 'cmd-create-v4');
        expect(inflightDraft.submitCommandId, 'cmd-submit-v4');
        expect(inflightDraft.evidenceId, 'ev-client-uuid-v4');
        expect(inflightDraft.serverAssessmentId, 'srv-ass-0099');
        expect(
          inflightDraft.localPhotoPath,
          '/data/user/0/com.learnward/cache/photo_inflight.jpg',
        );
        // Existing server assessment ID proves prior partial work, not successful completion
        // All migrated drafts must start with dispatchState = unknown_legacy
        expect(inflightDraft.dispatchState, CommandDispatchState.unknownLegacy);
        expect(inflightDraft.isLegacyUnknown, isTrue);
        expect(inflightDraft.canAutoSubmit, isFalse);

        // List drafts for child
        final childDrafts = await database.listLocalDrafts(
          ChildId('child-v4-1'),
        );
        expect(childDrafts.length, 2);

        // ---------------------------------------------------------------------
        // COMMAND MIGRATION & QUARANTINE VERIFICATION
        // ---------------------------------------------------------------------
        final redeemCmd = await database.getPendingCommand('cmd-redeem-v4');
        expect(redeemCmd, isNotNull);
        expect(redeemCmd!.operation, RewardCommandOperation.redeemReward);
        expect(redeemCmd.familyId, 'fam-v4-1');
        expect(redeemCmd.childId, 'child-v4-1');
        expect(redeemCmd.rewardId, 'rew-v4-book');
        expect(redeemCmd.actorUserId, isNull);
        expect(redeemCmd.actorRole, isNull);
        expect(redeemCmd.schemaVersion, 1);
        expect(
          redeemCmd.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(redeemCmd.dispatchState, CommandDispatchState.unknownLegacy);
        expect(
          redeemCmd.canAutoReplay,
          isFalse,
          reason: 'Quarantined legacy commands must fail closed',
        );

        final spinCmd = await database.getPendingCommand('cmd-spin-v4');
        expect(spinCmd, isNotNull);
        expect(spinCmd!.operation, RewardCommandOperation.spinWheel);
        expect(spinCmd.familyId, 'fam-v4-1');
        expect(spinCmd.childId, 'child-v4-1');
        expect(
          spinCmd.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(spinCmd.dispatchState, CommandDispatchState.unknownLegacy);
        expect(spinCmd.canAutoReplay, isFalse);

        final cancelCmd = await database.getPendingCommand('cmd-cancel-v4');
        expect(cancelCmd, isNotNull);
        expect(cancelCmd!.cancellationReason, 'Out of stock at bookstore');
        expect(cancelCmd.redemptionId, 'red-v4-102');
        expect(
          cancelCmd.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(cancelCmd.dispatchState, CommandDispatchState.unknownLegacy);

        final nullableCmd = await database.getPendingCommand('cmd-nullable-v4');
        expect(nullableCmd, isNotNull);
        expect(nullableCmd!.childId, isNull);
        expect(nullableCmd.rewardId, isNull);
        expect(nullableCmd.redemptionId, isNull);
        expect(nullableCmd.cancellationReason, isNull);
        expect(
          nullableCmd.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(nullableCmd.dispatchState, CommandDispatchState.unknownLegacy);

        // ---------------------------------------------------------------------
        // PROVE NO AUTOMATIC LEGACY REPLAY
        // ---------------------------------------------------------------------
        // Regular use-case lookup for active pending commands MUST return null for quarantined legacy rows
        expect(
          await database.findPendingSpinCommand(
            familyId: 'fam-v4-1',
            childId: 'child-v4-1',
          ),
          isNull,
          reason:
              'Legacy spin command must not be returned for automated replay',
        );

        expect(
          await database.findPendingRedeemCommand(
            familyId: 'fam-v4-1',
            childId: 'child-v4-1',
            rewardId: 'rew-v4-book',
          ),
          isNull,
          reason:
              'Legacy redeem command must not be returned for automated replay',
        );

        expect(
          await database.findPendingRedemptionCommand(
            operation: RewardCommandOperation.fulfillReward,
            redemptionId: 'red-v4-101',
          ),
          isNull,
          reason: 'Legacy fulfill command must not be returned for automated replay',
        );

        // Active commands list is empty
        final activeCommands = await database.listPendingCommands(
          recoveryState: CommandRecoveryState.active,
        );
        expect(activeCommands, isEmpty);

        // Quarantined commands list contains all 5 migrated legacy commands
        final quarantinedCommands = await database.listPendingCommands(
          recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(quarantinedCommands.length, 5);

        final allCommands = await database.listPendingCommands();
        expect(allCommands.length, 5);

        // ---------------------------------------------------------------------
        // FRESH v5 RECORD CREATION & DEFAULTS
        // ---------------------------------------------------------------------
        // Fresh draft
        final freshDraft = LocalAssessmentDraft(
          localDraftId: 'draft-v5-fresh',
          familyId: 'fam-v4-1',
          childId: 'child-v4-1',
          createCommandId: 'cmd-c-fresh',
          submitCommandId: 'cmd-s-fresh',
          subjectKey: SubjectKey.science,
          subject: 'Physics',
          title: 'Forces & Motion',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 10.0,
          maxScore: 10.0,
          actorUserId: 'usr-adult-1',
          actorRole: 'owner',
          occurredAt: DateTime.utc(2026, 11, 6, 12, 0),
          updatedAt: DateTime.utc(2026, 11, 6, 12, 5),
        );
        await database.saveLocalDraft(freshDraft);

        final savedFreshDraft = await database.getLocalDraft('draft-v5-fresh');
        expect(savedFreshDraft, isNotNull);
        expect(
          savedFreshDraft!.dispatchState,
          CommandDispatchState.neverDispatched,
        );
        expect(savedFreshDraft.submissionStatus, DraftSubmissionStatus.draft);
        expect(savedFreshDraft.retryCount, 0);
        expect(savedFreshDraft.actorUserId, 'usr-adult-1');
        expect(savedFreshDraft.canAutoSubmit, isTrue);

        // Fresh command
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

        final savedFreshCmd = await database.getPendingCommand(
          'cmd-spin-v5-fresh',
        );
        expect(savedFreshCmd, isNotNull);
        expect(
          savedFreshCmd!.dispatchState,
          CommandDispatchState.neverDispatched,
        );
        expect(savedFreshCmd.recoveryState, CommandRecoveryState.active);
        expect(savedFreshCmd.canAutoReplay, isTrue);

        // findPendingSpinCommand now returns the fresh active command, NOT the quarantined legacy one
        final activeSpin = await database.findPendingSpinCommand(
          familyId: 'fam-v4-1',
          childId: 'child-v4-1',
        );
        expect(activeSpin, isNotNull);
        expect(activeSpin!.commandId, 'cmd-spin-v5-fresh');
      } finally {
        await database.close();
      }

      // -----------------------------------------------------------------------
      // REPEATED STARTUP / REOPEN INTEGRITY
      // -----------------------------------------------------------------------
      // Reopening the database must not corrupt data or re-run destructive migrations
      final databaseSecondOpen = AppDatabase(NativeDatabase(dbFile));
      try {
        expect(databaseSecondOpen.schemaVersion, 5);

        // Verify migrated legacy records remain quarantined
        final legacySpin = await databaseSecondOpen.getPendingCommand(
          'cmd-spin-v4',
        );
        expect(
          legacySpin!.recoveryState,
          CommandRecoveryState.quarantinedUnknownOutcome,
        );
        expect(legacySpin.dispatchState, CommandDispatchState.unknownLegacy);

        // Verify fresh v5 records remain active
        final freshSpin = await databaseSecondOpen.getPendingCommand(
          'cmd-spin-v5-fresh',
        );
        expect(freshSpin!.recoveryState, CommandRecoveryState.active);
        expect(freshSpin.dispatchState, CommandDispatchState.neverDispatched);

        // Total commands count: 5 legacy + 1 fresh = 6
        final allCommands = await databaseSecondOpen.listPendingCommands();
        expect(allCommands.length, 6);

        // Total drafts count: 2 legacy + 1 fresh = 3
        final drafts = await databaseSecondOpen.listLocalDrafts(
          ChildId('child-v4-1'),
        );
        expect(drafts.length, 3);
      } finally {
        await databaseSecondOpen.close();
      }
    });

    test('retryCount zero default does not imply never-dispatched status on legacy items', () async {
      createAndPopulateV4Database(dbFile);

      final database = AppDatabase(NativeDatabase(dbFile));
      try {
        final offlineDraft = await database.getLocalDraft('draft-v4-offline');
        expect(offlineDraft, isNotNull);
        // Even though retryCount defaults to 0, dispatchState MUST be unknownLegacy
        expect(offlineDraft!.retryCount, 0);
        expect(offlineDraft.dispatchState, CommandDispatchState.unknownLegacy);
        expect(offlineDraft.isLegacyUnknown, isTrue);
      } finally {
        await database.close();
      }
    });

    test('fail-closed security for unknown or missing actor identities', () async {
      final database = AppDatabase(NativeDatabase.memory());
      try {
        // Command without actor fails closed
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

        // Command with actor succeeds eligibility check
        final cmdWithActor = cmdWithoutActor.copyWith(
          actorUserId: 'usr-parent-1',
          actorRole: 'parent',
        );
        expect(cmdWithActor.canAutoReplay, isTrue);

        // Draft without actor fails closed for automatic background submission
        final draftWithoutActor = LocalAssessmentDraft(
          localDraftId: 'draft-no-actor',
          familyId: 'fam-1',
          childId: 'child-1',
          createCommandId: 'cmd-c-1',
          submitCommandId: 'cmd-s-1',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Math Quiz',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 9,
          maxScore: 10,
          occurredAt: DateTime.utc(2026, 11, 6),
          updatedAt: DateTime.utc(2026, 11, 6),
        );
        expect(draftWithoutActor.actorUserId, isNull);
        expect(draftWithoutActor.canAutoSubmit, isFalse);

        // Draft with actor succeeds eligibility check
        final draftWithActor = draftWithoutActor.copyWith(
          actorUserId: 'usr-parent-1',
          actorRole: 'parent',
        );
        expect(draftWithActor.canAutoSubmit, isTrue);
      } finally {
        await database.close();
      }
    });
  });
}
