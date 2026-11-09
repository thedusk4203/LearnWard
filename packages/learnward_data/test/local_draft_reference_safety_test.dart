import 'dart:io';

import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Phase 6 Slice 4B-0: LocalDraftStore Reference-Aware Safety & Restart Tests', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase database;

    final childId = ChildId('child-ref-1');
    final familyId = 'fam-ref-1';

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_ref_safety_');
      dbFile = File('${tempDir.path}/draft_refs.sqlite');
      database = AppDatabase(NativeDatabase(dbFile));
    });

    tearDown(() async {
      await database.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    LocalAssessmentDraft buildSampleDraft({
      required String draftId,
      String? photoPath,
      String? compressedPath,
      CommandDispatchState dispatchState = CommandDispatchState.neverDispatched,
      DraftSubmissionStatus submissionStatus = DraftSubmissionStatus.draft,
    }) {
      return LocalAssessmentDraft(
        localDraftId: draftId,
        familyId: familyId,
        childId: childId.value,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: 'Math Quiz $draftId',
        assessmentType: 'quiz',
        difficulty: 'normal',
        rawScore: 9.0,
        maxScore: 10.0,
        localPhotoPath: photoPath,
        localCompressedPhotoPath: compressedPath,
        occurredAt: DateTime.utc(2026, 11, 9, 10, 0),
        updatedAt: DateTime.utc(2026, 11, 9, 10, 0),
        dispatchState: dispatchState,
        submissionStatus: submissionStatus,
      );
    }

    test('Zero references initially for any file path', () async {
      expect(
        await database.hasDraftReferenceToFile('/mock/photo.jpg'),
        isFalse,
      );
      expect(
        await database.countDraftReferencesToFile('/mock/photo.jpg'),
        equals(0),
      );
    });

    test('Single draft reference detection via localPhotoPath', () async {
      final draft = buildSampleDraft(
        draftId: 'd1',
        photoPath: '/evidence/pic1.jpg',
      );
      await database.saveLocalDraft(draft);

      expect(
        await database.hasDraftReferenceToFile('/evidence/pic1.jpg'),
        isTrue,
      );
      expect(
        await database.countDraftReferencesToFile('/evidence/pic1.jpg'),
        equals(1),
      );

      // Unrelated file
      expect(
        await database.hasDraftReferenceToFile('/evidence/other.jpg'),
        isFalse,
      );
      expect(
        await database.countDraftReferencesToFile('/evidence/other.jpg'),
        equals(0),
      );
    });

    test('Reference detection via localCompressedPhotoPath', () async {
      final draft = buildSampleDraft(
        draftId: 'd-comp',
        compressedPath: '/evidence/pic_compressed.jpg',
      );
      await database.saveLocalDraft(draft);

      expect(
        await database.hasDraftReferenceToFile('/evidence/pic_compressed.jpg'),
        isTrue,
      );
      expect(
        await database.countDraftReferencesToFile(
          '/evidence/pic_compressed.jpg',
        ),
        equals(1),
      );
    });

    test('Two drafts referencing the exact same physical photo path', () async {
      final sharedPath = '/evidence/shared_photo.jpg';
      final draft1 = buildSampleDraft(draftId: 'd1', photoPath: sharedPath);
      final draft2 = buildSampleDraft(draftId: 'd2', photoPath: sharedPath);

      await database.saveLocalDraft(draft1);
      await database.saveLocalDraft(draft2);

      expect(await database.countDraftReferencesToFile(sharedPath), equals(2));
      expect(await database.hasDraftReferenceToFile(sharedPath), isTrue);

      // Deleting draft 1 still leaves draft 2 reference intact
      await database.deleteLocalDraft('d1');
      expect(await database.countDraftReferencesToFile(sharedPath), equals(1));
      expect(await database.hasDraftReferenceToFile(sharedPath), isTrue);

      // Deleting draft 2 drops references to 0
      await database.deleteLocalDraft('d2');
      expect(await database.countDraftReferencesToFile(sharedPath), equals(0));
      expect(await database.hasDraftReferenceToFile(sharedPath), isFalse);
    });

    test('File-backed restart: references and draft data survive AppDatabase process restart', () async {
      final photoPath = '/evidence/restart_proof.jpg';
      final draft = buildSampleDraft(
        draftId: 'd-restart',
        photoPath: photoPath,
        compressedPath: '/evidence/restart_proof_compressed.jpg',
      );
      await database.saveLocalDraft(draft);
      expect(await database.countDraftReferencesToFile(photoPath), equals(1));

      // Close and reopen database on same file
      await database.close();
      final reopenedDb = AppDatabase(NativeDatabase(dbFile));

      try {
        expect(
          await reopenedDb.countDraftReferencesToFile(photoPath),
          equals(1),
        );
        expect(await reopenedDb.hasDraftReferenceToFile(photoPath), isTrue);
        expect(
          await reopenedDb.hasDraftReferenceToFile(
            '/evidence/restart_proof_compressed.jpg',
          ),
          isTrue,
        );

        final loaded = await reopenedDb.getLocalDraft('d-restart');
        expect(loaded, isNotNull);
        expect(loaded!.localPhotoPath, equals(photoPath));
        expect(
          loaded.localCompressedPhotoPath,
          equals('/evidence/restart_proof_compressed.jpg'),
        );
      } finally {
        await reopenedDb.close();
      }
    });

    test(
      'Updating draft to new photo path decrements old reference count',
      () async {
        final oldPath = '/evidence/old_photo.jpg';
        final newPath = '/evidence/new_photo.jpg';

        final draft = buildSampleDraft(draftId: 'd-switch', photoPath: oldPath);
        await database.saveLocalDraft(draft);

        expect(await database.countDraftReferencesToFile(oldPath), equals(1));
        expect(await database.countDraftReferencesToFile(newPath), equals(0));

        // Switch to new path
        final updatedDraft = draft.copyWith(localPhotoPath: newPath);
        await database.saveLocalDraft(updatedDraft);

        expect(await database.countDraftReferencesToFile(oldPath), equals(0));
        expect(await database.countDraftReferencesToFile(newPath), equals(1));
        expect(await database.hasDraftReferenceToFile(oldPath), isFalse);
        expect(await database.hasDraftReferenceToFile(newPath), isTrue);
      },
    );
  });
}
