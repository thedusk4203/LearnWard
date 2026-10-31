import 'package:drift/drift.dart';

/// Technical key/value metadata used to verify that the local database opens,
/// migrates and persists data.
///
/// This is deliberately not a product entity. Real cached entities, drafts and
/// the offline outbox arrive in later phases.
@DataClassName('LocalMetadataEntry')
class LocalMetadataEntries extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}
