import 'package:drift/drift.dart';

/// Local offline storage for assessment drafts.
@DataClassName('LocalAssessmentDraftEntry')
class LocalAssessmentDrafts extends Table {
  TextColumn get localDraftId => text()();

  TextColumn get familyId => text()();

  TextColumn get childId => text()();

  TextColumn get createCommandId => text().nullable()();

  TextColumn get submitCommandId => text().nullable()();

  TextColumn get evidenceId => text().nullable()();

  TextColumn get serverAssessmentId => text().nullable()();

  TextColumn get subjectKey => text().withDefault(const Constant('math'))();

  TextColumn get subject => text()();

  TextColumn get title => text()();

  TextColumn get assessmentType => text()();

  TextColumn get difficulty => text()();

  RealColumn get rawScore => real()();

  RealColumn get maxScore => real()();

  TextColumn get localPhotoPath => text().nullable()();

  TextColumn get entryContext =>
      text().withDefault(const Constant('shared_child'))();

  DateTimeColumn get occurredAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  // Phase 6.1 Additions (v5):
  TextColumn get serverEvidenceId => text().nullable()();

  TextColumn get sha256Checksum => text().nullable()();

  TextColumn get localCompressedPhotoPath => text().nullable()();

  TextColumn get submissionStatus =>
      text().withDefault(const Constant('draft'))();

  IntColumn get retryCount => integer().withDefault(const Constant(0))();

  TextColumn get dispatchState =>
      text().withDefault(const Constant('unknown_legacy'))();

  TextColumn get lastErrorMessage => text().nullable()();

  TextColumn get actorUserId => text().nullable()();

  TextColumn get actorRole => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localDraftId};
}
