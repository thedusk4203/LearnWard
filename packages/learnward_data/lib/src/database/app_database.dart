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
        await customStatement('PRAGMA busy_timeout = 5000');
        await customStatement('PRAGMA journal_mode = WAL');
      }
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA busy_timeout = 5000');
      await customStatement('PRAGMA journal_mode = WAL');
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

  LocalAssessmentDraftsCompanion _draftToCompanion(LocalAssessmentDraft draft) {
    return LocalAssessmentDraftsCompanion.insert(
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
      occurredAt: draft.occurredAt.toUtc(),
      updatedAt: draft.updatedAt.toUtc(),
      serverEvidenceId: Value(draft.serverEvidenceId),
      sha256Checksum: Value(draft.sha256Checksum),
      localCompressedPhotoPath: Value(draft.localCompressedPhotoPath),
      submissionStatus: Value(draft.submissionStatus.wireValue),
      retryCount: Value(draft.retryCount),
      dispatchState: Value(draft.dispatchState.wireValue),
      lastErrorMessage: Value(draft.lastErrorMessage),
      actorUserId: Value(draft.actorUserId),
      actorRole: Value(draft.actorRole),
      nextAttemptAt: Value(draft.nextAttemptAt?.toUtc()),
      leaseToken: Value(draft.leaseToken),
      leaseExpiresAt: Value(draft.leaseExpiresAt?.toUtc()),
    );
  }

  Future<T> _withSqliteBusyRetry<T>(Future<T> Function() action) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        return await action();
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final isBusy =
            msg.contains('database is locked') ||
            msg.contains('database table is locked') ||
            msg.contains('sqlite_busy');
        if (isBusy && attempt < 7) {
          await Future<void>.delayed(
            Duration(milliseconds: 25 * (attempt + 1)),
          );
          continue;
        }
        rethrow;
      }
    }
    throw StateError('Exceeded SQLite busy retry attempts.');
  }

  @override
  Future<void> saveLocalDraft(LocalAssessmentDraft draft) {
    return _withSqliteBusyRetry(() {
      return transaction(() async {
        final existingRow =
            await (select(localAssessmentDrafts)..where(
                  (entry) => entry.localDraftId.equals(draft.localDraftId),
                ))
                .getSingleOrNull();
        final existing = existingRow == null
            ? null
            : _mapRowToDraft(existingRow);

        validateLegacySaveLocalDraft(existing: existing, desired: draft);

        await into(localAssessmentDrafts)
            .insertOnConflictUpdate(_draftToCompanion(draft));
      });
    });
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
  Future<void> deleteLocalDraft(String localDraftId) {
    return _withSqliteBusyRetry(() {
      return transaction(() async {
        final existingRow =
            await (select(localAssessmentDrafts)
                  ..where((entry) => entry.localDraftId.equals(localDraftId)))
                .getSingleOrNull();
        if (existingRow == null) return;

        final existing = _mapRowToDraft(existingRow);
        validateRawLocalDraftDelete(existing);

        final query = delete(localAssessmentDrafts)
          ..where(
            (entry) =>
                entry.localDraftId.equals(localDraftId) &
                entry.leaseToken.isNull() &
                entry.leaseExpiresAt.isNull(),
          );
        final deleted = await query.go();
        if (deleted != 1) {
          throw DraftWriteConflictException(
            localDraftId: localDraftId,
            code: 'concurrent_delete_fenced',
            message:
                'Failed to delete draft $localDraftId: row changed concurrently or became leased.',
          );
        }
      });
    });
  }

  @override
  Future<DraftDeletionOutcome> deleteDraftSafely({
    required String localDraftId,
    required LocalAssessmentDraft expectedDraft,
    DateTime? now,
  }) {
    return transaction(() async {
      final query = select(localAssessmentDrafts)
        ..where((tbl) => tbl.localDraftId.equals(localDraftId));
      final row = await query.getSingleOrNull();

      if (row == null) {
        return evaluateDeleteDraftSafelyPreconditions(
          localDraftId: localDraftId,
          current: null,
          expectedDraft: expectedDraft,
          now: now,
        )!;
      }
      final current = _mapRowToDraft(row);

      final blockedOutcome = evaluateDeleteDraftSafelyPreconditions(
        localDraftId: localDraftId,
        current: current,
        expectedDraft: expectedDraft,
        now: now,
      );
      if (blockedOutcome != null) {
        return blockedOutcome;
      }

      // 3. Complete persisted-state CAS delete predicate:
      // Does not rely solely on updatedAt as a revision counter; guards all durable
      // identity, ownership, recovery, command, and evidence fields.
      final deleteQuery = delete(localAssessmentDrafts)
        ..where((tbl) {
          Expression<bool> predicate = tbl.localDraftId.equals(localDraftId);

          // Revision & lifecycle state predicates
          predicate = predicate & tbl.updatedAt.equals(row.updatedAt);
          predicate =
              predicate &
              tbl.dispatchState.equals(expectedDraft.dispatchState.wireValue);
          predicate =
              predicate &
              tbl.submissionStatus.equals(
                expectedDraft.submissionStatus.wireValue,
              );

          // Identity & ownership predicates
          predicate = predicate & tbl.familyId.equals(expectedDraft.familyId);
          predicate = predicate & tbl.childId.equals(expectedDraft.childId);
          if (expectedDraft.actorUserId == null) {
            predicate = predicate & tbl.actorUserId.isNull();
          } else {
            predicate =
                predicate & tbl.actorUserId.equals(expectedDraft.actorUserId!);
          }
          if (expectedDraft.actorRole == null) {
            predicate = predicate & tbl.actorRole.isNull();
          } else {
            predicate =
                predicate & tbl.actorRole.equals(expectedDraft.actorRole!);
          }

          // Command and server recovery IDs
          if (expectedDraft.createCommandId == null) {
            predicate = predicate & tbl.createCommandId.isNull();
          } else {
            predicate =
                predicate &
                tbl.createCommandId.equals(expectedDraft.createCommandId!);
          }
          if (expectedDraft.submitCommandId == null) {
            predicate = predicate & tbl.submitCommandId.isNull();
          } else {
            predicate =
                predicate &
                tbl.submitCommandId.equals(expectedDraft.submitCommandId!);
          }
          if (expectedDraft.evidenceId == null) {
            predicate = predicate & tbl.evidenceId.isNull();
          } else {
            predicate =
                predicate & tbl.evidenceId.equals(expectedDraft.evidenceId!);
          }
          if (expectedDraft.serverAssessmentId == null) {
            predicate = predicate & tbl.serverAssessmentId.isNull();
          } else {
            predicate =
                predicate &
                tbl.serverAssessmentId.equals(
                  expectedDraft.serverAssessmentId!,
                );
          }

          // Evidence paths & checksums
          if (expectedDraft.localPhotoPath == null) {
            predicate = predicate & tbl.localPhotoPath.isNull();
          } else {
            predicate =
                predicate &
                tbl.localPhotoPath.equals(expectedDraft.localPhotoPath!);
          }
          if (expectedDraft.localCompressedPhotoPath == null) {
            predicate = predicate & tbl.localCompressedPhotoPath.isNull();
          } else {
            predicate =
                predicate &
                tbl.localCompressedPhotoPath.equals(
                  expectedDraft.localCompressedPhotoPath!,
                );
          }
          if (expectedDraft.sha256Checksum == null) {
            predicate = predicate & tbl.sha256Checksum.isNull();
          } else {
            predicate =
                predicate &
                tbl.sha256Checksum.equals(expectedDraft.sha256Checksum!);
          }

          // Lease token
          if (expectedDraft.leaseToken == null) {
            predicate = predicate & tbl.leaseToken.isNull();
          } else {
            predicate =
                predicate & tbl.leaseToken.equals(expectedDraft.leaseToken!);
          }

          return predicate;
        });
      final affectedRows = await deleteQuery.go();

      if (affectedRows == 1) {
        return DraftDeletionOutcome(
          status: DraftDeletionStatus.deleted,
          localDraftId: localDraftId,
        );
      } else {
        return DraftDeletionOutcome(
          status: DraftDeletionStatus.concurrencyConflict,
          localDraftId: localDraftId,
          reason: 'Draft was modified concurrently during deletion execution.',
          currentDraft: current,
        );
      }
    });
  }

  @override
  Future<bool> hasDraftReferenceToFile(String filePath) async {
    final count = await countDraftReferencesToFile(filePath);
    return count > 0;
  }

  @override
  Future<int> countDraftReferencesToFile(String filePath) async {
    final query = select(localAssessmentDrafts)
      ..where(
        (t) =>
            t.localPhotoPath.equals(filePath) |
            t.localCompressedPhotoPath.equals(filePath),
      );
    final rows = await query.get();
    return rows.length;
  }

  static const String _draftValidWireStatusSql =
      "submission_status IN ('draft', 'uploading_evidence', 'submitting_assessment', 'failed_retryable')";
  static const String _draftLeaseShapeConsistentSql =
      '((lease_token IS NULL AND lease_expires_at IS NULL) OR (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL))';
  static const String _draftVerifiedEvidenceOrUnphotoedInFlightSql =
      "(dispatch_state != 'possibly_dispatched' OR ((local_compressed_photo_path IS NOT NULL AND length(local_compressed_photo_path) > 0 AND sha256_checksum IS NOT NULL AND length(sha256_checksum) = 64 AND sha256_checksum NOT GLOB '*[^0-9a-f]*') OR ((local_photo_path IS NULL OR local_photo_path = '') AND (local_compressed_photo_path IS NULL OR local_compressed_photo_path = '') AND (sha256_checksum IS NULL OR sha256_checksum = '') AND (evidence_id IS NULL OR evidence_id = ''))))";
  static const String _draftNotQuarantinedMarkerSql =
      "(last_error_message IS NULL OR last_error_message NOT LIKE 'LW4B1:%' OR last_error_message LIKE 'LW4B1:RETRY_SCHEDULED%')";
  static const String _draftActiveLeaseWhereSql =
      "local_draft_id = ? AND lease_token = ? AND lease_expires_at IS NOT NULL AND lease_expires_at > ? AND actor_user_id IS NOT NULL AND actor_user_id = ? AND dispatch_state IN ('never_dispatched', 'possibly_dispatched') AND $_draftValidWireStatusSql AND $_draftLeaseShapeConsistentSql AND $_draftVerifiedEvidenceOrUnphotoedInFlightSql AND $_draftNotQuarantinedMarkerSql";

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

    final parsedStatus = DraftSubmissionStatus.tryFromString(
      row.submissionStatus,
    );
    final effectiveStatus = parsedStatus ?? DraftSubmissionStatus.terminalError;
    final effectiveLastError = parsedStatus == null
        ? DraftRecoveryCode.format(
            DraftRecoveryCode.unknownWireStatus,
            row.submissionStatus.isEmpty ? '<empty>' : row.submissionStatus,
          )
        : row.lastErrorMessage;

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
      submissionStatus: effectiveStatus,
      retryCount: row.retryCount,
      dispatchState: CommandDispatchState.fromString(row.dispatchState),
      lastErrorMessage: effectiveLastError,
      actorUserId: row.actorUserId,
      actorRole: row.actorRole,
      nextAttemptAt: row.nextAttemptAt?.toUtc(),
      leaseToken: row.leaseToken,
      leaseExpiresAt: row.leaseExpiresAt?.toUtc(),
    );
  }

  Future<DraftCasResult> _execFencedDraftUpdate({
    required String localDraftId,
    required String sql,
    required List<Variable<Object>> variables,
    required DraftCasResult Function(LocalAssessmentDraft? current)
    diagnoseZeroRows,
  }) async {
    final rowsAffected = await _withSqliteBusyRetry(
      () => customUpdate(
        sql,
        variables: variables,
        updates: {localAssessmentDrafts},
      ),
    );
    final latest = await _withSqliteBusyRetry(
      () => getLocalDraft(localDraftId),
    );
    if (rowsAffected == 1) {
      return DraftCasResult(status: DraftCasStatus.succeeded, draft: latest);
    }
    return diagnoseZeroRows(latest);
  }

  @override
  Future<DraftCasResult> registerOrUpdateDraftIfUnchanged({
    required LocalAssessmentDraft? expected,
    required LocalAssessmentDraft desired,
    DateTime? now,
  }) {
    final effectiveNow = normalizeDraftUtcNow(now);
    return _withSqliteBusyRetry(() async {
      try {
        return await transaction(() async {
          final existingRow =
              await (select(localAssessmentDrafts)..where(
                    (entry) => entry.localDraftId.equals(desired.localDraftId),
                  ))
                  .getSingleOrNull();
          final existing = existingRow == null
              ? null
              : _mapRowToDraft(existingRow);

          final eval = evaluateDraftRegistrationCas(
            existing: existing,
            expected: expected,
            desired: desired,
            secondPrecisionTimestamps: true,
            now: effectiveNow,
          );
          if (!eval.isSuccess) {
            return eval;
          }

          final persistedTarget = eval.draft!;
          if (expected == null) {
            await into(localAssessmentDrafts).insert(
              _draftToCompanion(persistedTarget),
              mode: InsertMode.insert,
            );
          } else {
            await update(localAssessmentDrafts)
                .replace(_draftToCompanion(persistedTarget));
          }

          final reloaded = await getLocalDraft(desired.localDraftId);
          return DraftCasResult(
            status: DraftCasStatus.succeeded,
            draft: reloaded,
          );
        });
      } catch (e) {
        final msg = e.toString().toLowerCase();
        if (expected == null &&
            (msg.contains('unique constraint') ||
                msg.contains('primarykey') ||
                msg.contains('sqlite_constraint'))) {
          final current = await getLocalDraft(desired.localDraftId);
          return DraftCasResult(
            status: DraftCasStatus.casConflict,
            draft: current,
            reason:
                'Draft ${desired.localDraftId} was registered concurrently.',
          );
        }
        rethrow;
      }
    });
  }

  Future<DraftCasResult> _claimOrResumeDraftLease({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    required bool expectingExpiredLease,
    DateTime? now,
    String? overrideLeaseToken,
  }) async {
    if (actorUserId.isEmpty ||
        familyId.isEmpty ||
        childId.isEmpty ||
        leaseDuration <= Duration.zero) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'Claim requires non-empty actorUserId, familyId, childId, and positive leaseDuration.',
      );
    }
    if (overrideLeaseToken != null && overrideLeaseToken.isEmpty) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'overrideLeaseToken cannot be empty.',
      );
    }

    final effectiveNow = normalizeDraftUtcNow(now);
    final newToken = overrideLeaseToken ?? generateDraftLeaseToken();
    final newExpiresAt = effectiveNow.add(leaseDuration);

    final leaseClause = expectingExpiredLease
        ? 'lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND lease_expires_at <= ? AND lease_token != ?'
        : 'lease_token IS NULL AND lease_expires_at IS NULL';

    final variables = <Variable<Object>>[
      Variable<String>(newToken),
      Variable<DateTime>(newExpiresAt),
      Variable<DateTime>(effectiveNow),
      Variable<String>(localDraftId),
      Variable<String>(actorUserId),
      Variable<String>(familyId),
      Variable<String>(childId),
      if (expectingExpiredLease) ...[
        Variable<DateTime>(effectiveNow),
        Variable<String>(newToken),
      ],
      Variable<DateTime>(effectiveNow),
    ];

    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET lease_token = ?,
          lease_expires_at = ?,
          next_attempt_at = NULL,
          updated_at = ?
      WHERE local_draft_id = ?
        AND actor_user_id IS NOT NULL
        AND actor_user_id = ?
        AND family_id = ?
        AND child_id = ?
        AND $leaseClause
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND $_draftValidWireStatusSql
        AND $_draftLeaseShapeConsistentSql
        AND $_draftVerifiedEvidenceOrUnphotoedInFlightSql
        AND $_draftNotQuarantinedMarkerSql
        AND (
          (submission_status != 'failed_retryable' AND (last_error_message IS NULL OR last_error_message NOT LIKE 'LW4B1:RETRY_SCHEDULED%'))
          OR next_attempt_at IS NULL
          OR next_attempt_at <= ?
        );
      ''',
      variables: variables,
      diagnoseZeroRows: (current) => diagnoseDraftClaimFailure(
        existing: current,
        localDraftId: localDraftId,
        actorUserId: actorUserId,
        familyId: familyId,
        childId: childId,
        effectiveNow: effectiveNow,
        expectingExpiredLease: expectingExpiredLease,
        existingLeaseToken: overrideLeaseToken,
      ),
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
  }) => _claimOrResumeDraftLease(
    localDraftId: localDraftId,
    actorUserId: actorUserId,
    familyId: familyId,
    childId: childId,
    leaseDuration: leaseDuration,
    expectingExpiredLease: false,
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
  }) => _claimOrResumeDraftLease(
    localDraftId: localDraftId,
    actorUserId: actorUserId,
    familyId: familyId,
    childId: childId,
    leaseDuration: leaseDuration,
    expectingExpiredLease: true,
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
  }) async {
    final effectiveNow = now.toUtc();
    if (leaseToken.isEmpty ||
        authenticatedActorId.isEmpty ||
        (targetStage != DraftSubmissionStatus.uploadingEvidence &&
            targetStage != DraftSubmissionStatus.submittingAssessment)) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'markDraftStageAndDispatch requires non-empty lease/actor and uploadingEvidence or submittingAssessment targetStage.',
      );
    }
    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET submission_status = ?,
          dispatch_state = 'possibly_dispatched',
          next_attempt_at = NULL,
          last_error_message = CASE
            WHEN last_error_message LIKE 'LW4B1:RETRY_SCHEDULED%' THEN NULL
            ELSE last_error_message
          END,
          updated_at = ?
      WHERE $_draftActiveLeaseWhereSql;
      ''',
      variables: [
        Variable<String>(targetStage.wireValue),
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(leaseToken),
        Variable<DateTime>(effectiveNow),
        Variable<String>(authenticatedActorId),
      ],
      diagnoseZeroRows: (current) => diagnoseLeasedMutationFailure(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        effectiveNow: effectiveNow,
      ),
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
    final effectiveNow = now.toUtc();
    if (leaseToken.isEmpty ||
        authenticatedActorId.isEmpty ||
        serverAssessmentId.isEmpty) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'persistServerAssessmentId requires non-empty leaseToken, actorId, and serverAssessmentId.',
      );
    }
    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET server_assessment_id = ?,
          updated_at = ?
      WHERE $_draftActiveLeaseWhereSql
        AND (server_assessment_id IS NULL OR server_assessment_id = '' OR server_assessment_id = ?);
      ''',
      variables: [
        Variable<String>(serverAssessmentId),
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(leaseToken),
        Variable<DateTime>(effectiveNow),
        Variable<String>(authenticatedActorId),
        Variable<String>(serverAssessmentId),
      ],
      diagnoseZeroRows: (current) {
        final eval = evaluatePersistServerAssessmentId(
          existing: current,
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          authenticatedActorId: authenticatedActorId,
          serverAssessmentId: serverAssessmentId,
          now: effectiveNow,
        );
        return eval.isSuccess
            ? DraftCasResult(
                status: DraftCasStatus.casConflict,
                draft: current,
                reason: 'Concurrent modification during serverAssessmentId CAS update.',
              )
            : eval;
      },
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
  }) async {
    final effectiveNow = now.toUtc();
    if (leaseToken.isEmpty ||
        authenticatedActorId.isEmpty ||
        serverEvidenceId.isEmpty ||
        expectedEvidenceId.isEmpty ||
        !isValidSha256Hex(expectedSha256Checksum)) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'persistServerEvidenceId requires non-empty IDs and valid 64-char lowercase sha256Checksum.',
      );
    }
    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET server_evidence_id = ?,
          updated_at = ?
      WHERE $_draftActiveLeaseWhereSql
        AND evidence_id = ?
        AND sha256_checksum = ?
        AND (server_evidence_id IS NULL OR server_evidence_id = '' OR server_evidence_id = ?);
      ''',
      variables: [
        Variable<String>(serverEvidenceId),
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(leaseToken),
        Variable<DateTime>(effectiveNow),
        Variable<String>(authenticatedActorId),
        Variable<String>(expectedEvidenceId),
        Variable<String>(expectedSha256Checksum),
        Variable<String>(serverEvidenceId),
      ],
      diagnoseZeroRows: (current) {
        final eval = evaluatePersistServerEvidenceId(
          existing: current,
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          authenticatedActorId: authenticatedActorId,
          serverEvidenceId: serverEvidenceId,
          expectedEvidenceId: expectedEvidenceId,
          expectedSha256Checksum: expectedSha256Checksum,
          now: effectiveNow,
        );
        return eval.isSuccess
            ? DraftCasResult(
                status: DraftCasStatus.casConflict,
                draft: current,
                reason: 'Concurrent modification during serverEvidenceId CAS update.',
              )
            : eval;
      },
    );
  }

  @override
  Future<DraftCasResult> scheduleDraftRetry({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DateTime nextAttemptAt,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  }) async {
    final effectiveNow = normalizeDraftUtcNow(now);
    final parsedCode = DraftRecoveryCode.parseCode(recoveryCode);
    if (leaseToken.isEmpty ||
        authenticatedActorId.isEmpty ||
        parsedCode != DraftRecoveryCode.retryScheduled) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason:
            'scheduleDraftRetry requires valid lease/actor and ${DraftRecoveryCode.retryScheduled} recoveryCode.',
      );
    }
    final envelope = formatSanitizedRecoveryEnvelope(
      recoveryCode: DraftRecoveryCode.retryScheduled,
      errorMessage: errorMessage,
    );
    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET submission_status = 'failed_retryable',
          retry_count = retry_count + 1,
          next_attempt_at = ?,
          last_error_message = ?,
          lease_token = NULL,
          lease_expires_at = NULL,
          updated_at = ?
      WHERE $_draftActiveLeaseWhereSql;
      ''',
      variables: [
        Variable<DateTime>(nextAttemptAt.toUtc()),
        Variable<String>(envelope),
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(leaseToken),
        Variable<DateTime>(effectiveNow),
        Variable<String>(authenticatedActorId),
      ],
      diagnoseZeroRows: (current) => diagnoseLeasedMutationFailure(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        effectiveNow: effectiveNow,
      ),
    );
  }

  @override
  Future<DraftCasResult> quarantineDraftOutcome({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  }) async {
    final effectiveNow = normalizeDraftUtcNow(now);
    final parsedCode = DraftRecoveryCode.parseCode(recoveryCode);
    final isAllowed =
        parsedCode != null &&
        (DraftRecoveryCode.quarantineCodes.contains(parsedCode) ||
            parsedCode == DraftRecoveryCode.terminalPolicyDenial ||
            parsedCode == DraftRecoveryCode.authContextExpiredOrMismatched);
    if (leaseToken.isEmpty || authenticatedActorId.isEmpty || !isAllowed) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'quarantineDraftOutcome requires valid lease/actor and allowed quarantine/terminal recoveryCode.',
      );
    }
    final envelope = parsedCode == DraftRecoveryCode.unknownWireStatus
        ? DraftRecoveryCode.format(
            DraftRecoveryCode.unknownWireStatus,
            sanitizeStorageError(errorMessage),
          )
        : formatSanitizedRecoveryEnvelope(
            recoveryCode: parsedCode,
            errorMessage: errorMessage,
          );

    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET submission_status = 'terminal_error',
          next_attempt_at = NULL,
          last_error_message = ?,
          lease_token = NULL,
          lease_expires_at = NULL,
          updated_at = ?
      WHERE $_draftActiveLeaseWhereSql;
      ''',
      variables: [
        Variable<String>(envelope),
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(leaseToken),
        Variable<DateTime>(effectiveNow),
        Variable<String>(authenticatedActorId),
      ],
      diagnoseZeroRows: (current) => diagnoseLeasedMutationFailure(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        effectiveNow: effectiveNow,
      ),
    );
  }

  @override
  Future<DraftCasResult> completeDraftSubmission({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
    String? serverEvidenceId,
  }) async {
    final effectiveNow = now.toUtc();
    if (leaseToken.isEmpty ||
        authenticatedActorId.isEmpty ||
        serverAssessmentId.isEmpty ||
        (serverEvidenceId != null && serverEvidenceId.isEmpty)) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'completeDraftSubmission requires non-empty leaseToken, actorId, serverAssessmentId, and non-empty serverEvidenceId when supplied.',
      );
    }
    final hasServerEvidenceId = serverEvidenceId != null;
    final setEvidenceSql = hasServerEvidenceId ? 'server_evidence_id = ?,' : '';
    final evidenceGuardSql = hasServerEvidenceId
        ? "AND (server_evidence_id IS NULL OR server_evidence_id = '' OR server_evidence_id = ?)"
        : '';
    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET server_assessment_id = ?,
          $setEvidenceSql
          submission_status = 'submitting_assessment',
          dispatch_state = 'confirmed_committed',
          next_attempt_at = NULL,
          last_error_message = NULL,
          lease_token = NULL,
          lease_expires_at = NULL,
          updated_at = ?
      WHERE $_draftActiveLeaseWhereSql
        AND (server_assessment_id IS NULL OR server_assessment_id = '' OR server_assessment_id = ?)
        $evidenceGuardSql;
      ''',
      variables: [
        Variable<String>(serverAssessmentId),
        if (hasServerEvidenceId) Variable<String>(serverEvidenceId),
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(leaseToken),
        Variable<DateTime>(effectiveNow),
        Variable<String>(authenticatedActorId),
        Variable<String>(serverAssessmentId),
        if (hasServerEvidenceId) Variable<String>(serverEvidenceId),
      ],
      diagnoseZeroRows: (current) {
        final eval = evaluateCompleteDraftSubmission(
          existing: current,
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          authenticatedActorId: authenticatedActorId,
          serverAssessmentId: serverAssessmentId,
          now: effectiveNow,
          serverEvidenceId: serverEvidenceId,
        );
        return eval.isSuccess
            ? DraftCasResult(
                status: DraftCasStatus.casConflict,
                draft: current,
                reason: 'Concurrent modification during completeDraftSubmission CAS update.',
              )
            : eval;
      },
    );
  }

  @override
  Future<DraftCasResult> releaseDraftClaim({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    DateTime? now,
  }) async {
    final effectiveNow = normalizeDraftUtcNow(now);
    if (leaseToken.isEmpty || authenticatedActorId.isEmpty) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'releaseDraftClaim requires non-empty leaseToken and actorId.',
      );
    }
    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET lease_token = NULL,
          lease_expires_at = NULL,
          updated_at = ?
      WHERE $_draftActiveLeaseWhereSql;
      ''',
      variables: [
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(leaseToken),
        Variable<DateTime>(effectiveNow),
        Variable<String>(authenticatedActorId),
      ],
      diagnoseZeroRows: (current) => diagnoseLeasedMutationFailure(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        effectiveNow: effectiveNow,
      ),
    );
  }

  @override
  Future<DraftCasResult> pauseMismatchedActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  }) async {
    final effectiveNow = normalizeDraftUtcNow(now);
    if (familyId.isEmpty || authenticatedActorId.isEmpty) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'familyId and authenticatedActorId must be non-empty.',
      );
    }
    final envelope = formatSanitizedRecoveryEnvelope(
      recoveryCode: DraftRecoveryCode.waitingOriginalActor,
      errorMessage: mismatchReason ?? 'Paused because active session switched away from original draft author.',
    );
    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET last_error_message = ?,
          lease_token = NULL,
          lease_expires_at = NULL,
          updated_at = ?
      WHERE local_draft_id = ?
        AND family_id = ?
        AND actor_user_id IS NOT NULL
        AND length(actor_user_id) > 0
        AND actor_user_id != ?
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND $_draftValidWireStatusSql
        AND $_draftLeaseShapeConsistentSql
        AND $_draftVerifiedEvidenceOrUnphotoedInFlightSql
        AND $_draftNotQuarantinedMarkerSql
        AND (lease_token IS NULL OR lease_expires_at <= ?);
      ''',
      variables: [
        Variable<String>(envelope),
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(familyId),
        Variable<String>(authenticatedActorId),
        Variable<DateTime>(effectiveNow),
      ],
      diagnoseZeroRows: (current) => diagnoseActorPauseOrResumeFailure(
        existing: current,
        localDraftId: localDraftId,
        familyId: familyId,
        authenticatedActorId: authenticatedActorId,
        effectiveNow: effectiveNow,
        expectingResume: false,
      ),
    );
  }

  @override
  Future<DraftCasResult> resumeOriginalActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  }) async {
    final effectiveNow = normalizeDraftUtcNow(now);
    if (familyId.isEmpty || authenticatedActorId.isEmpty) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: await _withSqliteBusyRetry(() => getLocalDraft(localDraftId)),
        reason: 'familyId and authenticatedActorId must be non-empty.',
      );
    }
    return _execFencedDraftUpdate(
      localDraftId: localDraftId,
      sql:
          '''
      UPDATE local_assessment_drafts
      SET last_error_message = NULL,
          lease_token = NULL,
          lease_expires_at = NULL,
          updated_at = ?
      WHERE local_draft_id = ?
        AND family_id = ?
        AND actor_user_id = ?
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
        AND $_draftValidWireStatusSql
        AND $_draftLeaseShapeConsistentSql
        AND $_draftVerifiedEvidenceOrUnphotoedInFlightSql
        AND last_error_message LIKE 'LW4B1:WAITING_ORIGINAL_ACTOR%'
        AND (lease_token IS NULL OR lease_expires_at <= ?);
      ''',
      variables: [
        Variable<DateTime>(effectiveNow),
        Variable<String>(localDraftId),
        Variable<String>(familyId),
        Variable<String>(authenticatedActorId),
        Variable<DateTime>(effectiveNow),
      ],
      diagnoseZeroRows: (current) => diagnoseActorPauseOrResumeFailure(
        existing: current,
        localDraftId: localDraftId,
        familyId: familyId,
        authenticatedActorId: authenticatedActorId,
        effectiveNow: effectiveNow,
        expectingResume: true,
      ),
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
  Future<RegisterFreshCommandResult> registerFreshCommand({
    required PendingRewardCommand command,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        return await transaction(() async {
          final query = select(pendingRewardCommands)
            ..where((t) => t.familyId.equals(command.familyId));

          if (command.operation == RewardCommandOperation.fulfillReward ||
              command.operation == RewardCommandOperation.cancelReward) {
            query
              ..where((t) => t.redemptionId.equals(command.redemptionId!))
              ..where(
                (t) => t.operation.isIn([
                  RewardCommandOperation.fulfillReward.wireValue,
                  RewardCommandOperation.cancelReward.wireValue,
                ]),
              );
          } else {
            query.where((t) => t.operation.equals(command.operation.wireValue));
            if (command.childId != null) {
              query.where((t) => t.childId.equals(command.childId!));
            }
            if (command.operation == RewardCommandOperation.redeemReward &&
                command.rewardId != null) {
              query.where((t) => t.rewardId.equals(command.rewardId!));
            }
          }

          final candidates = await query.get();
          for (final candidate in candidates) {
            final recState = CommandRecoveryState.fromString(
              candidate.recoveryState,
            );
            final dispState = CommandDispatchState.fromString(
              candidate.dispatchState,
            );
            if (isCommandUnresolved(
              recoveryState: recState,
              dispatchState: dispState,
            )) {
              return PreexistingCommandFound(
                _mapRowToPendingCommand(candidate),
              );
            }
          }

          await into(pendingRewardCommands).insert(
            PendingRewardCommandsCompanion.insert(
              operation: command.operation.wireValue,
              commandId: command.commandId,
              familyId: command.familyId,
              childId: Value(command.childId),
              rewardId: Value(command.rewardId),
              redemptionId: Value(command.redemptionId),
              cancellationReason: Value(command.cancellationReason),
              createdAt: effectiveNow,
              actorUserId: Value(command.actorUserId),
              actorRole: Value(command.actorRole),
              schemaVersion: Value(command.schemaVersion),
              recoveryState: Value(command.recoveryState.wireValue),
              dispatchState: Value(command.dispatchState.wireValue),
              retryCount: Value(command.retryCount),
              nextAttemptAt: Value(command.nextAttemptAt?.toUtc()),
              lastErrorMessage: Value(command.lastErrorMessage),
              leaseToken: const Value(null),
              leaseExpiresAt: const Value(null),
            ),
            mode: InsertMode.insert,
          );

          return FreshCommandRegistered(command);
        });
      } catch (e) {
        if (e.toString().contains('database is locked') && attempt < 4) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }
        rethrow;
      }
    }
    throw StateError('Failed to register fresh command after retries');
  }

  @override
  Future<void> savePendingCommand(
    PendingRewardCommand command, {
    DateTime? now,
  }) async {
    final hasPartialLease =
        (command.leaseToken != null && command.leaseExpiresAt == null) ||
        (command.leaseToken == null && command.leaseExpiresAt != null);
    if (hasPartialLease) {
      throw ArgumentError(
        'Cannot save pending command ${command.commandId}: partial lease metadata '
        '(leaseToken=${command.leaseToken}, leaseExpiresAt=${command.leaseExpiresAt})',
      );
    }

    final effectiveNow = (now ?? DateTime.now()).toUtc();

    await transaction(() async {
      final existing =
          await (select(pendingRewardCommands)
                ..where((entry) => entry.commandId.equals(command.commandId)))
              .getSingleOrNull();

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
            createdAt: command.createdAt.toUtc(),
            actorUserId: Value(command.actorUserId),
            actorRole: Value(command.actorRole),
            schemaVersion: Value(command.schemaVersion),
            recoveryState: Value(command.recoveryState.wireValue),
            dispatchState: Value(command.dispatchState.wireValue),
            retryCount: Value(command.retryCount),
            nextAttemptAt: Value(command.nextAttemptAt?.toUtc()),
            lastErrorMessage: Value(command.lastErrorMessage),
            leaseToken: const Value(null),
            leaseExpiresAt: const Value(null),
          ),
          mode: InsertMode.insert,
        );
        return;
      }

      // HIGH 1: Existing command identity must be immutable.
      final isSameIdentity =
          existing.operation == command.operation.wireValue &&
          existing.familyId == command.familyId &&
          existing.childId == command.childId &&
          existing.rewardId == command.rewardId &&
          existing.redemptionId == command.redemptionId &&
          existing.cancellationReason == command.cancellationReason &&
          existing.actorUserId == command.actorUserId &&
          existing.actorRole == command.actorRole;

      if (!isSameIdentity) {
        throw StateError(
          'Cannot mutate immutable identity fields of existing pending command ${command.commandId}',
        );
      }

      // Active lease protection
      final hasActiveLease =
          existing.leaseToken != null &&
          existing.leaseExpiresAt != null &&
          existing.leaseExpiresAt!.isAfter(effectiveNow);
      if (hasActiveLease) {
        throw StateError(
          'Cannot overwrite pending command ${command.commandId}: held by an active lease',
        );
      }

      // MEDIUM: Malformed lease fail-close
      final isMalformedLease =
          (existing.leaseToken != null && existing.leaseExpiresAt == null) ||
          (existing.leaseToken == null && existing.leaseExpiresAt != null);
      if (isMalformedLease) {
        throw StateError(
          'Cannot overwrite pending command ${command.commandId}: existing lease is malformed',
        );
      }

      // HIGH 2: Irreversible dispatch provenance & legacy quarantine checks
      if (existing.dispatchState ==
          CommandDispatchState.unknownLegacy.wireValue) {
        throw StateError(
          'Cannot overwrite pending command ${command.commandId}: record is quarantined as unknown_legacy',
        );
      }
      if (existing.dispatchState ==
          CommandDispatchState.confirmedCommitted.wireValue) {
        throw StateError(
          'Cannot overwrite pending command ${command.commandId}: record is already confirmed_committed',
        );
      }
      if (existing.recoveryState ==
          CommandRecoveryState.quarantinedUnknownOutcome.wireValue) {
        throw StateError(
          'Cannot overwrite pending command ${command.commandId}: record is quarantined',
        );
      }
      if (existing.recoveryState ==
          CommandRecoveryState.pendingOriginalActor.wireValue) {
        throw StateError(
          'Cannot overwrite pending command ${command.commandId}: record is paused for original actor',
        );
      }
      if (existing.recoveryState ==
          CommandRecoveryState.terminalError.wireValue) {
        throw StateError(
          'Cannot overwrite pending command ${command.commandId}: record is in terminal_error',
        );
      }

      final rowsAffected = await customUpdate(
        '''
        UPDATE pending_reward_commands
        SET dispatch_state = CASE
              WHEN dispatch_state = 'possibly_dispatched' THEN 'possibly_dispatched'
              ELSE ?
            END,
            next_attempt_at = COALESCE(?, next_attempt_at),
            last_error_message = COALESCE(?, last_error_message),
            lease_token = NULL,
            lease_expires_at = NULL
        WHERE command_id = ?
          AND operation = ?
          AND family_id = ?
          AND (child_id IS ?)
          AND (reward_id IS ?)
          AND (redemption_id IS ?)
          AND (cancellation_reason IS ?)
          AND (actor_user_id IS ?)
          AND (actor_role IS ?)
          AND dispatch_state NOT IN ('unknown_legacy', 'confirmed_committed')
          AND recovery_state NOT IN ('quarantined_unknown_outcome', 'pending_original_actor', 'terminal_error')
          AND (
            (lease_token IS NULL AND lease_expires_at IS NULL)
            OR
            (lease_token IS NOT NULL AND lease_expires_at <= ?)
          );
        ''',
        variables: [
          Variable<String>(command.dispatchState.wireValue),
          Variable<DateTime>(command.nextAttemptAt?.toUtc()),
          Variable<String>(command.lastErrorMessage),
          Variable<String>(command.commandId),
          Variable<String>(command.operation.wireValue),
          Variable<String>(command.familyId),
          Variable<String>(command.childId),
          Variable<String>(command.rewardId),
          Variable<String>(command.redemptionId),
          Variable<String>(command.cancellationReason),
          Variable<String>(command.actorUserId),
          Variable<String>(command.actorRole),
          Variable<DateTime>(effectiveNow),
        ],
        updates: {pendingRewardCommands},
      );

      if (rowsAffected == 0) {
        throw StateError(
          'Cannot update pending command ${command.commandId}: conflicting identity or conditional predicates not met',
        );
      }
    });
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
    await customUpdate(
      '''
      DELETE FROM pending_reward_commands
      WHERE command_id = ?
        AND lease_token IS NULL
        AND lease_expires_at IS NULL;
      ''',
      variables: [Variable<String>(commandId)],
      updates: {pendingRewardCommands},
    );
  }

  // ---------------------------------------------------------------------------
  // PHASE 6 SLICE 4A-0: ATOMIC CAS STORE OPERATIONS & FENCING
  // ---------------------------------------------------------------------------

  static const String _operationEligibilityPredicate = '''
    (
      operation IN ('spin_wheel', 'redeem_reward')
      OR (
        operation = 'fulfill_reward'
        AND child_id IS NOT NULL AND trim(child_id) <> ''
        AND redemption_id IS NOT NULL AND trim(redemption_id) <> ''
        AND cancellation_reason IS NULL
        AND actor_role IN ('owner', 'parent')
      )
      OR (
        operation = 'cancel_reward'
        AND child_id IS NOT NULL AND trim(child_id) <> ''
        AND redemption_id IS NOT NULL AND trim(redemption_id) <> ''
        AND cancellation_reason IS NOT NULL AND length(trim(cancellation_reason)) >= 2
        AND actor_role IN ('owner', 'parent')
      )
    )
  ''';

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
        AND $_operationEligibilityPredicate
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched', 'confirmed_committed')
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
  Future<bool> markPossiblyDispatched({
    required String commandId,
    required String leaseToken,
    required String authenticatedActorId,
    required DateTime now,
  }) async {
    final effectiveNow = now.toUtc();
    final rowsAffected = await customUpdate(
      '''
      UPDATE pending_reward_commands
      SET dispatch_state = 'possibly_dispatched',
          last_error_message = CASE WHEN last_error_message LIKE '[UNVERIFIED_TARGET_MISS:%' THEN NULL ELSE last_error_message END
      WHERE command_id = ?
        AND lease_token = ?
        AND lease_expires_at > ?
        AND actor_user_id = ?
        AND recovery_state = 'active'
        AND $_operationEligibilityPredicate
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched');
      ''',
      variables: [
        Variable<String>(commandId),
        Variable<String>(leaseToken),
        Variable<DateTime>(effectiveNow),
        Variable<String>(authenticatedActorId),
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
        AND $_operationEligibilityPredicate
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched', 'confirmed_committed')
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
        AND $_operationEligibilityPredicate
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched', 'confirmed_committed')
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
    String? familyId,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    final query = customSelect(
      '''
      SELECT * FROM pending_reward_commands
      WHERE actor_user_id = ?
        ${familyId != null ? 'AND family_id = ?' : ''}
        AND recovery_state = 'active'
        AND $_operationEligibilityPredicate
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched', 'confirmed_committed')
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
        if (familyId != null) Variable<String>(familyId),
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
        AND $_operationEligibilityPredicate
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched', 'confirmed_committed')
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
        AND $_operationEligibilityPredicate
        AND dispatch_state IN ('never_dispatched', 'possibly_dispatched', 'confirmed_committed')
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
