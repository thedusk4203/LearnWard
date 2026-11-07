import 'dart:math';

import 'package:drift/drift.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

import 'local_assessment_drafts.dart';
import 'local_metadata_entries.dart';
import 'pending_reward_commands.dart';

part 'app_database.g.dart';

/// LearnWard's local SQLite database.
///
/// The server remains authoritative. This database is reserved for cached read
/// models, drafts and the offline command outbox.
@DriftDatabase(
  tables: [LocalMetadataEntries, LocalAssessmentDrafts, PendingRewardCommands],
)
class AppDatabase extends _$AppDatabase
    implements LocalMetadataStore, LocalDraftStore, PendingRewardCommandStore {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 6;

  Future<bool> _tableExists(String tableName) async {
    final result = await customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?;",
      variables: [Variable.withString(tableName)],
    ).get();
    return result.isNotEmpty;
  }

  Future<bool> _columnExists(String tableName, String columnName) async {
    final result = await customSelect("PRAGMA table_info('$tableName');").get();
    return result.any((row) => row.data['name'] == columnName);
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      await customStatement('PRAGMA foreign_keys = OFF');
      try {
        await transaction(() async {
          if (from < 2) {
            if (!await _tableExists('local_assessment_drafts')) {
              await migrator.createTable(localAssessmentDrafts);
            }
          }
          if (from < 3) {
            if (await _tableExists('local_assessment_drafts')) {
              if (!await _columnExists(
                'local_assessment_drafts',
                'create_command_id',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.createCommandId,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'submit_command_id',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.submitCommandId,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'evidence_id',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.evidenceId,
                );
              }
            }
          }
          if (from < 4) {
            if (!await _tableExists('pending_reward_commands')) {
              await migrator.createTable(pendingRewardCommands);
            }
          }
          if (from < 5) {
            // v4 -> v5 migration: Additive schema upgrade for Phase 6 offline resilience
            // 1. PendingRewardCommands additions (only if table already existed prior to v5)
            if (await _tableExists('pending_reward_commands')) {
              if (!await _columnExists(
                'pending_reward_commands',
                'actor_user_id',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.actorUserId,
                );
              }
              if (!await _columnExists(
                'pending_reward_commands',
                'actor_role',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.actorRole,
                );
              }
              if (!await _columnExists(
                'pending_reward_commands',
                'schema_version',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.schemaVersion,
                );
              }
              if (!await _columnExists(
                'pending_reward_commands',
                'recovery_state',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.recoveryState,
                );
              }
              if (!await _columnExists(
                'pending_reward_commands',
                'dispatch_state',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.dispatchState,
                );
              }

              // Quarantine all existing legacy pending commands as unknown_legacy with quarantined_unknown_outcome
              await customStatement(
                "UPDATE pending_reward_commands SET "
                "recovery_state = 'quarantined_unknown_outcome', "
                "dispatch_state = 'unknown_legacy' "
                "WHERE actor_user_id IS NULL;",
              );
            }

            // 2. LocalAssessmentDrafts additions (only if table already existed prior to v5)
            if (await _tableExists('local_assessment_drafts')) {
              if (!await _columnExists(
                'local_assessment_drafts',
                'server_evidence_id',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.serverEvidenceId,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'sha256_checksum',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.sha256Checksum,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'local_compressed_photo_path',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.localCompressedPhotoPath,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'submission_status',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.submissionStatus,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'retry_count',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.retryCount,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'dispatch_state',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.dispatchState,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'last_error_message',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.lastErrorMessage,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'actor_user_id',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.actorUserId,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'actor_role',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.actorRole,
                );
              }

              // All migrated legacy drafts start with dispatch_state = 'unknown_legacy'
              await customStatement(
                "UPDATE local_assessment_drafts SET "
                "dispatch_state = 'unknown_legacy' "
                "WHERE actor_user_id IS NULL OR dispatch_state = 'unknown_legacy';",
              );
            }
          }
          if (from < 6) {
            // v5 -> v6 migration: Additive schema upgrade for Phase 6 Slice 4A-0
            // 1. PendingRewardCommands additions
            if (await _tableExists('pending_reward_commands')) {
              if (!await _columnExists(
                'pending_reward_commands',
                'retry_count',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.retryCount,
                );
              }
              if (!await _columnExists(
                'pending_reward_commands',
                'next_attempt_at',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.nextAttemptAt,
                );
              }
              if (!await _columnExists(
                'pending_reward_commands',
                'last_error_message',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.lastErrorMessage,
                );
              }
              if (!await _columnExists(
                'pending_reward_commands',
                'lease_token',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.leaseToken,
                );
              }
              if (!await _columnExists(
                'pending_reward_commands',
                'lease_expires_at',
              )) {
                await migrator.addColumn(
                  pendingRewardCommands,
                  pendingRewardCommands.leaseExpiresAt,
                );
              }
            }

            // 2. LocalAssessmentDrafts additions
            if (await _tableExists('local_assessment_drafts')) {
              if (!await _columnExists(
                'local_assessment_drafts',
                'next_attempt_at',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.nextAttemptAt,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'lease_token',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.leaseToken,
                );
              }
              if (!await _columnExists(
                'local_assessment_drafts',
                'lease_expires_at',
              )) {
                await migrator.addColumn(
                  localAssessmentDrafts,
                  localAssessmentDrafts.leaseExpiresAt,
                );
              }
            }
          }
        });
      } finally {
        await customStatement('PRAGMA foreign_keys = ON');
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Writes a technical metadata entry, replacing an existing value.
  @override
  Future<void> writeMetadata({
    required String key,
    required String value,
    required DateTime updatedAt,
  }) {
    return into(localMetadataEntries).insertOnConflictUpdate(
      LocalMetadataEntriesCompanion.insert(
        key: key,
        value: value,
        updatedAt: updatedAt,
      ),
    );
  }

  /// Reads a technical metadata value, or `null` when the key is absent.
  @override
  Future<String?> readMetadata(String key) async {
    final query = select(localMetadataEntries)
      ..where((entry) => entry.key.equals(key));
    final entry = await query.getSingleOrNull();
    return entry?.value;
  }

  @override
  Future<void> saveLocalDraft(LocalAssessmentDraft draft) {
    return into(localAssessmentDrafts).insertOnConflictUpdate(
      LocalAssessmentDraftsCompanion.insert(
        localDraftId: draft.localDraftId,
        familyId: draft.familyId,
        childId: draft.childId,
        createCommandId: Value(draft.createCommandId),
        submitCommandId: Value(draft.submitCommandId),
        evidenceId: Value(draft.evidenceId),
        serverAssessmentId: Value(draft.serverAssessmentId),
        subjectKey: Value(draft.subjectKey.value),
        subject: draft.subject,
        title: draft.title,
        assessmentType: draft.assessmentType,
        difficulty: draft.difficulty,
        rawScore: draft.rawScore,
        maxScore: draft.maxScore,
        localPhotoPath: Value(draft.localPhotoPath),
        entryContext: Value(draft.entryContext.value),
        occurredAt: draft.occurredAt,
        updatedAt: draft.updatedAt,
        serverEvidenceId: Value(draft.serverEvidenceId),
        sha256Checksum: Value(draft.sha256Checksum),
        localCompressedPhotoPath: Value(draft.localCompressedPhotoPath),
        submissionStatus: Value(draft.submissionStatus.wireValue),
        retryCount: Value(draft.retryCount),
        dispatchState: Value(draft.dispatchState.wireValue),
        lastErrorMessage: Value(draft.lastErrorMessage),
        actorUserId: Value(draft.actorUserId),
        actorRole: Value(draft.actorRole),
        nextAttemptAt: Value(draft.nextAttemptAt),
        leaseToken: Value(draft.leaseToken),
        leaseExpiresAt: Value(draft.leaseExpiresAt),
      ),
    );
  }

  @override
  Future<LocalAssessmentDraft?> getLocalDraft(String localDraftId) async {
    final query = select(localAssessmentDrafts)
      ..where((entry) => entry.localDraftId.equals(localDraftId));
    final row = await query.getSingleOrNull();
    if (row == null) return null;

    return _mapRowToDraft(row);
  }

  @override
  Future<List<LocalAssessmentDraft>> listLocalDrafts(ChildId childId) async {
    final query = select(localAssessmentDrafts)
      ..where((entry) => entry.childId.equals(childId.value))
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    final rows = await query.get();

    return rows.map(_mapRowToDraft).toList();
  }

  @override
  Future<void> deleteLocalDraft(String localDraftId) async {
    final query = delete(localAssessmentDrafts)
      ..where((entry) => entry.localDraftId.equals(localDraftId));
    await query.go();
  }

  LocalAssessmentDraft _mapRowToDraft(LocalAssessmentDraftEntry row) {
    SubjectKey key;
    try {
      key = SubjectKey.parse(row.subjectKey);
    } catch (_) {
      key = SubjectKey.math;
    }

    EntryContext ctx;
    try {
      ctx = EntryContext.parse(row.entryContext);
    } catch (_) {
      ctx = EntryContext.sharedChild;
    }

    return LocalAssessmentDraft(
      localDraftId: row.localDraftId,
      familyId: row.familyId,
      childId: row.childId,
      createCommandId: row.createCommandId,
      submitCommandId: row.submitCommandId,
      evidenceId: row.evidenceId,
      serverAssessmentId: row.serverAssessmentId,
      subjectKey: key,
      subject: row.subject,
      title: row.title,
      assessmentType: row.assessmentType,
      difficulty: row.difficulty,
      rawScore: row.rawScore,
      maxScore: row.maxScore,
      localPhotoPath: row.localPhotoPath,
      entryContext: ctx,
      occurredAt: row.occurredAt.toUtc(),
      updatedAt: row.updatedAt.toUtc(),
      serverEvidenceId: row.serverEvidenceId,
      sha256Checksum: row.sha256Checksum,
      localCompressedPhotoPath: row.localCompressedPhotoPath,
      submissionStatus: DraftSubmissionStatus.fromString(row.submissionStatus),
      retryCount: row.retryCount,
      dispatchState: CommandDispatchState.fromString(row.dispatchState),
      lastErrorMessage: row.lastErrorMessage,
      actorUserId: row.actorUserId,
      actorRole: row.actorRole,
      nextAttemptAt: row.nextAttemptAt?.toUtc(),
      leaseToken: row.leaseToken,
      leaseExpiresAt: row.leaseExpiresAt?.toUtc(),
    );
  }

  // ---------------------------------------------------------------------------
  // PENDING REWARD COMMAND STORE
  // ---------------------------------------------------------------------------

  static String _generateLeaseToken() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  @override
  Future<void> savePendingCommand(PendingRewardCommand command) async {
    final existing =
        await (select(pendingRewardCommands)
              ..where((entry) => entry.commandId.equals(command.commandId)))
            .getSingleOrNull();

    final now = DateTime.now().toUtc();

    if (existing == null) {
      await into(pendingRewardCommands).insert(
        PendingRewardCommandsCompanion.insert(
          operation: command.operation.wireValue,
          commandId: command.commandId,
          familyId: command.familyId,
          childId: Value(command.childId),
          rewardId: Value(command.rewardId),
          redemptionId: Value(command.redemptionId),
          cancellationReason: Value(command.cancellationReason),
          createdAt: command.createdAt,
          actorUserId: Value(command.actorUserId),
          actorRole: Value(command.actorRole),
          schemaVersion: Value(command.schemaVersion),
          recoveryState: Value(command.recoveryState.wireValue),
          dispatchState: Value(command.dispatchState.wireValue),
          retryCount: Value(command.retryCount),
          nextAttemptAt: Value(command.nextAttemptAt),
          lastErrorMessage: Value(command.lastErrorMessage),
          leaseToken: Value(command.leaseToken),
          leaseExpiresAt: Value(command.leaseExpiresAt),
        ),
        mode: InsertMode.insert,
      );
    } else {
      final hasActiveLease =
          existing.leaseToken != null &&
          existing.leaseExpiresAt != null &&
          existing.leaseExpiresAt!.isAfter(now);

      if (hasActiveLease && existing.leaseToken != command.leaseToken) {
        throw StateError(
          'Cannot overwrite pending command ${command.commandId}: held by an active lease',
        );
      }

      await (update(
        pendingRewardCommands,
      )..where((entry) => entry.commandId.equals(command.commandId))).write(
        PendingRewardCommandsCompanion(
          operation: Value(command.operation.wireValue),
          familyId: Value(command.familyId),
          childId: Value(command.childId),
          rewardId: Value(command.rewardId),
          redemptionId: Value(command.redemptionId),
          cancellationReason: Value(command.cancellationReason),
          actorUserId: Value(command.actorUserId),
          actorRole: Value(command.actorRole),
          schemaVersion: Value(command.schemaVersion),
          recoveryState: Value(command.recoveryState.wireValue),
          dispatchState: Value(command.dispatchState.wireValue),
          retryCount: Value(command.retryCount),
          nextAttemptAt: Value(command.nextAttemptAt),
          lastErrorMessage: Value(command.lastErrorMessage),
          leaseToken: Value(command.leaseToken),
          leaseExpiresAt: Value(command.leaseExpiresAt),
        ),
      );
    }
  }

  @override
  Future<PendingRewardCommand?> getPendingCommand(String commandId) async {
    final query = select(pendingRewardCommands)
      ..where((entry) => entry.commandId.equals(commandId));
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return _mapRowToPendingCommand(row);
  }

  @override
  Future<PendingRewardCommand?> findPendingSpinCommand({
    required String familyId,
    required String childId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    final query = select(pendingRewardCommands)
      ..where(
        (entry) =>
            entry.operation.equals(RewardCommandOperation.spinWheel.wireValue) &
            entry.familyId.equals(familyId) &
            entry.childId.equals(childId),
      );
    if (recoveryState != null) {
      query.where(
        (entry) => entry.recoveryState.equals(recoveryState.wireValue),
      );
    }
    if (actorUserId != null) {
      query.where((entry) => entry.actorUserId.equals(actorUserId));
    }
    query
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return _mapRowToPendingCommand(row);
  }

  @override
  Future<PendingRewardCommand?> findPendingRedeemCommand({
    required String familyId,
    required String childId,
    required String rewardId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    final query = select(pendingRewardCommands)
      ..where(
        (entry) =>
            entry.operation.equals(
              RewardCommandOperation.redeemReward.wireValue,
            ) &
            entry.familyId.equals(familyId) &
            entry.childId.equals(childId) &
            entry.rewardId.equals(rewardId),
      );
    if (recoveryState != null) {
      query.where(
        (entry) => entry.recoveryState.equals(recoveryState.wireValue),
      );
    }
    if (actorUserId != null) {
      query.where((entry) => entry.actorUserId.equals(actorUserId));
    }
    query
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return _mapRowToPendingCommand(row);
  }

  @override
  Future<PendingRewardCommand?> findPendingRedemptionCommand({
    required RewardCommandOperation operation,
    required String redemptionId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    final query = select(pendingRewardCommands)
      ..where(
        (entry) =>
            entry.operation.equals(operation.wireValue) &
            entry.redemptionId.equals(redemptionId),
      );
    if (recoveryState != null) {
      query.where(
        (entry) => entry.recoveryState.equals(recoveryState.wireValue),
      );
    }
    if (actorUserId != null) {
      query.where((entry) => entry.actorUserId.equals(actorUserId));
    }
    query
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(1);
    final row = await query.getSingleOrNull();
    if (row == null) return null;
    return _mapRowToPendingCommand(row);
  }

  @override
  Future<List<PendingRewardCommand>> listPendingCommands({
    String? familyId,
    String? childId,
    CommandRecoveryState? recoveryState,
    CommandDispatchState? dispatchState,
  }) async {
    final query = select(pendingRewardCommands);
    if (familyId != null) {
      query.where((entry) => entry.familyId.equals(familyId));
    }
    if (childId != null) {
      query.where((entry) => entry.childId.equals(childId));
    }
    if (recoveryState != null) {
      query.where(
        (entry) => entry.recoveryState.equals(recoveryState.wireValue),
      );
    }
    if (dispatchState != null) {
      query.where(
        (entry) => entry.dispatchState.equals(dispatchState.wireValue),
      );
    }
    query.orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    final rows = await query.get();
    return rows.map(_mapRowToPendingCommand).toList();
  }

  @override
  Future<void> deletePendingCommand(String commandId) async {
    final query = delete(pendingRewardCommands)
      ..where((entry) => entry.commandId.equals(commandId));
    await query.go();
  }

  // ---------------------------------------------------------------------------
  // PHASE 6 SLICE 4A-0: ATOMIC CAS STORE OPERATIONS & FENCING
  // ---------------------------------------------------------------------------

  @override
  Future<String?> acquireClaim({
    required String commandId,
    required String actorUserId,
    required Duration leaseDuration,
    DateTime? now,
    String? overrideLeaseToken,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final leaseExpiresAt = effectiveNow.add(leaseDuration);
    final newLeaseToken = overrideLeaseToken ?? _generateLeaseToken();

    final rowsAffected = await customUpdate(
      '''
      UPDATE pending_reward_commands
      SET lease_token = ?,
          lease_expires_at = ?
      WHERE command_id = ?
        AND actor_user_id = ?
        AND recovery_state = 'active'
        AND operation IN ('spin_wheel', 'redeem_reward')
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
        AND (
          (lease_token IS NULL AND lease_expires_at IS NULL)
          OR
          (lease_token IS NOT NULL AND lease_expires_at <= ?)
        );
      ''',
      variables: [
        Variable<String>(newLeaseToken),
        Variable<DateTime>(leaseExpiresAt),
        Variable<String>(commandId),
        Variable<String>(actorUserId),
        Variable<DateTime>(effectiveNow),
        Variable<DateTime>(effectiveNow),
      ],
      updates: {pendingRewardCommands},
    );

    return rowsAffected == 1 ? newLeaseToken : null;
  }

  @override
  Future<bool> releaseClaim({
    required String commandId,
    required String leaseToken,
    required DateTime nextAttemptAt,
    String? lastErrorMessage,
  }) async {
    final rowsAffected = await customUpdate(
      '''
      UPDATE pending_reward_commands
      SET retry_count = retry_count + 1,
          next_attempt_at = ?,
          last_error_message = ?,
          lease_token = NULL,
          lease_expires_at = NULL
      WHERE command_id = ? AND lease_token = ?;
      ''',
      variables: [
        Variable<DateTime>(nextAttemptAt.toUtc()),
        Variable<String>(lastErrorMessage),
        Variable<String>(commandId),
        Variable<String>(leaseToken),
      ],
      updates: {pendingRewardCommands},
    );

    return rowsAffected == 1;
  }

  @override
  Future<bool> completeCommand({
    required String commandId,
    required String leaseToken,
  }) async {
    final rowsAffected = await customUpdate(
      '''
      DELETE FROM pending_reward_commands
      WHERE command_id = ? AND lease_token = ?;
      ''',
      variables: [Variable<String>(commandId), Variable<String>(leaseToken)],
      updates: {pendingRewardCommands},
    );

    return rowsAffected == 1;
  }

  @override
  Future<bool> transitionRecoveryState({
    required String commandId,
    required String leaseToken,
    required CommandRecoveryState newState,
    String? lastErrorMessage,
  }) async {
    final rowsAffected = await customUpdate(
      '''
      UPDATE pending_reward_commands
      SET recovery_state = ?,
          last_error_message = ?,
          lease_token = NULL,
          lease_expires_at = NULL
      WHERE command_id = ? AND lease_token = ?;
      ''',
      variables: [
        Variable<String>(newState.wireValue),
        Variable<String>(lastErrorMessage),
        Variable<String>(commandId),
        Variable<String>(leaseToken),
      ],
      updates: {pendingRewardCommands},
    );

    return rowsAffected == 1;
  }

  @override
  Future<bool> pauseMismatchedActorCommand({
    required String commandId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    final rowsAffected = await customUpdate(
      '''
      UPDATE pending_reward_commands
      SET recovery_state = 'pending_original_actor',
          last_error_message = ?,
          lease_token = NULL,
          lease_expires_at = NULL
      WHERE command_id = ?
        AND family_id = ?
        AND actor_user_id IS NOT NULL
        AND actor_user_id <> ?
        AND recovery_state = 'active'
        AND operation IN ('spin_wheel', 'redeem_reward')
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND (
          (lease_token IS NULL AND lease_expires_at IS NULL)
          OR
          (lease_token IS NOT NULL AND lease_expires_at <= ?)
        );
      ''',
      variables: [
        Variable<String>(mismatchReason),
        Variable<String>(commandId),
        Variable<String>(familyId),
        Variable<String>(authenticatedActorId),
        Variable<DateTime>(effectiveNow),
      ],
      updates: {pendingRewardCommands},
    );

    return rowsAffected == 1;
  }

  @override
  Future<bool> resumeOriginalActorCommand({
    required String commandId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    final rowsAffected = await customUpdate(
      '''
      UPDATE pending_reward_commands
      SET recovery_state = 'active',
          last_error_message = NULL,
          lease_token = NULL,
          lease_expires_at = NULL
      WHERE command_id = ?
        AND family_id = ?
        AND actor_user_id = ?
        AND recovery_state = 'pending_original_actor'
        AND operation IN ('spin_wheel', 'redeem_reward')
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND (
          (lease_token IS NULL AND lease_expires_at IS NULL)
          OR
          (lease_token IS NOT NULL AND lease_expires_at <= ?)
        );
      ''',
      variables: [
        Variable<String>(commandId),
        Variable<String>(familyId),
        Variable<String>(authenticatedActorId),
        Variable<DateTime>(effectiveNow),
      ],
      updates: {pendingRewardCommands},
    );

    return rowsAffected == 1;
  }

  @override
  Future<List<PendingRewardCommand>> listClaimableCommands({
    required String actorUserId,
    required int limit,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    final query = customSelect(
      '''
      SELECT * FROM pending_reward_commands
      WHERE actor_user_id = ?
        AND recovery_state = 'active'
        AND operation IN ('spin_wheel', 'redeem_reward')
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
        AND (
          (lease_token IS NULL AND lease_expires_at IS NULL)
          OR
          (lease_token IS NOT NULL AND lease_expires_at <= ?)
        )
      ORDER BY created_at ASC
      LIMIT ?;
      ''',
      variables: [
        Variable<String>(actorUserId),
        Variable<DateTime>(effectiveNow),
        Variable<DateTime>(effectiveNow),
        Variable<int>(limit),
      ],
      readsFrom: {pendingRewardCommands},
    );

    final rows = await query.get();
    return rows
        .map((row) => pendingRewardCommands.map(row.data))
        .map(_mapRowToPendingCommand)
        .toList();
  }

  @override
  Future<List<PendingRewardCommand>> listMismatchedActiveCommands({
    required String familyId,
    required String authenticatedActorId,
    required int limit,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    final query = customSelect(
      '''
      SELECT * FROM pending_reward_commands
      WHERE family_id = ?
        AND actor_user_id IS NOT NULL
        AND actor_user_id <> ?
        AND recovery_state = 'active'
        AND operation IN ('spin_wheel', 'redeem_reward')
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND (
          (lease_token IS NULL AND lease_expires_at IS NULL)
          OR
          (lease_token IS NOT NULL AND lease_expires_at <= ?)
        )
      ORDER BY created_at ASC
      LIMIT ?;
      ''',
      variables: [
        Variable<String>(familyId),
        Variable<String>(authenticatedActorId),
        Variable<DateTime>(effectiveNow),
        Variable<int>(limit),
      ],
      readsFrom: {pendingRewardCommands},
    );

    final rows = await query.get();
    return rows
        .map((row) => pendingRewardCommands.map(row.data))
        .map(_mapRowToPendingCommand)
        .toList();
  }

  @override
  Future<List<PendingRewardCommand>> listPausedOriginalActorCommands({
    required String familyId,
    required String authenticatedActorId,
    required int limit,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    final query = customSelect(
      '''
      SELECT * FROM pending_reward_commands
      WHERE family_id = ?
        AND actor_user_id = ?
        AND recovery_state = 'pending_original_actor'
        AND operation IN ('spin_wheel', 'redeem_reward')
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND (
          (lease_token IS NULL AND lease_expires_at IS NULL)
          OR
          (lease_token IS NOT NULL AND lease_expires_at <= ?)
        )
      ORDER BY created_at ASC
      LIMIT ?;
      ''',
      variables: [
        Variable<String>(familyId),
        Variable<String>(authenticatedActorId),
        Variable<DateTime>(effectiveNow),
        Variable<int>(limit),
      ],
      readsFrom: {pendingRewardCommands},
    );

    final rows = await query.get();
    return rows
        .map((row) => pendingRewardCommands.map(row.data))
        .map(_mapRowToPendingCommand)
        .toList();
  }

  PendingRewardCommand _mapRowToPendingCommand(PendingRewardCommandEntry row) {
    return PendingRewardCommand(
      id: row.id,
      operation: RewardCommandOperation.fromString(row.operation),
      commandId: row.commandId,
      familyId: row.familyId,
      childId: row.childId,
      rewardId: row.rewardId,
      redemptionId: row.redemptionId,
      cancellationReason: row.cancellationReason,
      createdAt: row.createdAt.toUtc(),
      actorUserId: row.actorUserId,
      actorRole: row.actorRole,
      schemaVersion: row.schemaVersion,
      recoveryState: CommandRecoveryState.fromString(row.recoveryState),
      dispatchState: CommandDispatchState.fromString(row.dispatchState),
      retryCount: row.retryCount,
      nextAttemptAt: row.nextAttemptAt?.toUtc(),
      lastErrorMessage: row.lastErrorMessage,
      leaseToken: row.leaseToken,
      leaseExpiresAt: row.leaseExpiresAt?.toUtc(),
    );
  }
}
