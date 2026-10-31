import 'package:drift/native.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  group('AppDatabase', () {
    test('opens, migrates and persists technical metadata', () async {
      await database.writeMetadata(
        key: 'schema_probe',
        value: 'ready',
        updatedAt: DateTime.utc(2026, 10, 31),
      );

      expect(await database.readMetadata('schema_probe'), 'ready');
    });

    test('replaces a metadata value without creating a duplicate', () async {
      final timestamp = DateTime.utc(2026, 10, 31);

      await database.writeMetadata(
        key: 'schema_probe',
        value: 'first',
        updatedAt: timestamp,
      );
      await database.writeMetadata(
        key: 'schema_probe',
        value: 'second',
        updatedAt: timestamp,
      );

      expect(await database.readMetadata('schema_probe'), 'second');
      expect(await database.readMetadata('missing'), isNull);
    });
  });
}
