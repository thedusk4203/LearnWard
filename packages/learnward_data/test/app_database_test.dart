import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  group('AppDatabase Metadata', () {
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

  group('AppDatabase LocalDraftStore', () {
    test(
      'saves, gets, lists and deletes local assessment drafts with subjectKey',
      () async {
        final draft1 = LocalAssessmentDraft(
          localDraftId: 'draft-1',
          familyId: 'fam-1',
          childId: 'child-1',
          createCommandId: 'cmd-create-1',
          submitCommandId: 'cmd-submit-1',
          evidenceId: 'ev-uuid-1',
          subjectKey: SubjectKey.science,
          subject: 'Science',
          title: 'Quiz 1',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 9,
          maxScore: 10,
          localPhotoPath: '/path/to/photo.jpg',
          entryContext: EntryContext.sharedChild,
          occurredAt: DateTime.utc(2026, 11, 1),
          updatedAt: DateTime.utc(2026, 11, 1, 10, 0),
          actorUserId: 'usr-test-1',
        );

        await database.saveLocalDraft(draft1);

        final retrieved = await database.getLocalDraft('draft-1');
        expect(retrieved, isNotNull);
        expect(retrieved!.createCommandId, equals('cmd-create-1'));
        expect(retrieved.submitCommandId, equals('cmd-submit-1'));
        expect(retrieved.evidenceId, equals('ev-uuid-1'));
        expect(retrieved.subjectKey, equals(SubjectKey.science));
        expect(retrieved.entryContext, equals(EntryContext.sharedChild));
        expect(retrieved.title, equals('Quiz 1'));

        final list = await database.listLocalDrafts(ChildId('child-1'));
        expect(list.length, equals(1));
        expect(list.first.subject, equals('Science'));
        expect(list.first.rawScore, equals(9));
        expect(list.first.localPhotoPath, equals('/path/to/photo.jpg'));

        await database.deleteLocalDraft('draft-1');
        final emptyList = await database.listLocalDrafts(ChildId('child-1'));
        expect(emptyList.isEmpty, isTrue);
        expect(await database.getLocalDraft('draft-1'), isNull);
      },
    );
  });
}
