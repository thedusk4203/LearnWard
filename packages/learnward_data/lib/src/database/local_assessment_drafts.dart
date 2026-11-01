import 'package:drift/drift.dart';

/// Local offline storage for assessment drafts.
@DataClassName('LocalAssessmentDraftEntry')
class LocalAssessmentDrafts extends Table {
  TextColumn get localDraftId => text()();

  TextColumn get familyId => text()();

  TextColumn get childId => text()();

  TextColumn get serverAssessmentId => text().nullable()();

  TextColumn get subject => text()();

  TextColumn get title => text()();

  TextColumn get assessmentType => text()();

  TextColumn get difficulty => text()();

  RealColumn get rawScore => real()();

  RealColumn get maxScore => real()();

  TextColumn get localPhotoPath => text().nullable()();

  DateTimeColumn get occurredAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {localDraftId};
}
