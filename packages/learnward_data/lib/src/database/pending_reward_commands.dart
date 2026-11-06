import 'package:drift/drift.dart';

/// Local offline storage for pending reward commands to guarantee restart-safe idempotency.
@DataClassName('PendingRewardCommandEntry')
class PendingRewardCommands extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get operation => text()();

  TextColumn get commandId => text().unique()();

  TextColumn get familyId => text()();

  TextColumn get childId => text().nullable()();

  TextColumn get rewardId => text().nullable()();

  TextColumn get redemptionId => text().nullable()();

  TextColumn get cancellationReason => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  // Phase 6.1 Additions (v5):
  TextColumn get actorUserId => text().nullable()();

  TextColumn get actorRole => text().nullable()();

  IntColumn get schemaVersion => integer().withDefault(const Constant(1))();

  TextColumn get recoveryState =>
      text().withDefault(const Constant('active'))();

  TextColumn get dispatchState =>
      text().withDefault(const Constant('unknown_legacy'))();
}
