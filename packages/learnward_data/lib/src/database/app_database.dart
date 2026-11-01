import 'package:drift/drift.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

import 'local_assessment_drafts.dart';
import 'local_metadata_entries.dart';

part 'app_database.g.dart';

/// LearnWard's local SQLite database.
///
/// The server remains authoritative. This database is reserved for cached read
/// models, drafts and the future offline command outbox.
@DriftDatabase(tables: [LocalMetadataEntries, LocalAssessmentDrafts])
class AppDatabase extends _$AppDatabase
    implements LocalMetadataStore, LocalDraftStore {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
    onUpgrade: (migrator, from, to) async {
      if (from < 2) {
        await migrator.createTable(localAssessmentDrafts);
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
      occurredAt: row.occurredAt,
      updatedAt: row.updatedAt,
    );
  }
}
