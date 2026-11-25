import 'package:learnward_application/learnward_application.dart';

/// In-memory [LegacyOutboxProvenanceSource] for deterministic ownership tests.
final class InMemoryLegacyOutboxProvenanceSource
    implements LegacyOutboxProvenanceSource {
  InMemoryLegacyOutboxProvenanceSource([
    List<ActorBoundOutboxRecord>? initialRecords,
  ]) : _records = List<ActorBoundOutboxRecord>.of(initialRecords ?? const []);

  final List<ActorBoundOutboxRecord> _records;

  /// Replaces the fixture records held by this source.
  void setRecords(List<ActorBoundOutboxRecord> records) {
    _records
      ..clear()
      ..addAll(records);
  }

  /// Appends an actor-bound record fixture.
  void addRecord(ActorBoundOutboxRecord record) {
    _records.add(record);
  }

  @override
  Future<List<ActorBoundOutboxRecord>> listActorBoundRecords() async {
    return List<ActorBoundOutboxRecord>.unmodifiable(_records);
  }
}
