import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
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
        actorUserId: 'usr-ref-actor-1',
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

  group('R26-01: Atomic State-Aware Draft Deletion & Concurrency Regression Tests', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase conn1;
    late AppDatabase conn2;

    final childId = ChildId('child-cas-1');
    final familyId = 'fam-cas-1';
    final now = DateTime.utc(2026, 11, 9, 12, 0);

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_cas_safety_');
      dbFile = File('${tempDir.path}/cas_test.sqlite');
      conn1 = AppDatabase(NativeDatabase(dbFile));
      conn2 = AppDatabase(NativeDatabase(dbFile));
    });

    tearDown(() async {
      await conn1.close();
      await conn2.close();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    LocalAssessmentDraft buildDraft({
      required String draftId,
      String? photoPath,
      CommandDispatchState dispatchState = CommandDispatchState.neverDispatched,
      DraftSubmissionStatus submissionStatus = DraftSubmissionStatus.draft,
      String? leaseToken,
      DateTime? leaseExpiresAt,
      DateTime? updatedAt,
      String title = 'Test Assessment',
      double rawScore = 8.0,
      double maxScore = 10.0,
    }) {
      return LocalAssessmentDraft(
        localDraftId: draftId,
        familyId: familyId,
        childId: childId.value,
        subjectKey: SubjectKey.math,
        subject: 'Math',
        title: title,
        assessmentType: 'quiz',
        difficulty: 'normal',
        rawScore: rawScore,
        maxScore: maxScore,
        localPhotoPath: photoPath,
        occurredAt: now,
        updatedAt: updatedAt ?? now,
        dispatchState: dispatchState,
        submissionStatus: submissionStatus,
        leaseToken: leaseToken,
        leaseExpiresAt: leaseExpiresAt,
        actorUserId: 'usr-ref-actor-1',
      );
    }

    Future<void> applyRawConn2Update(
      String draftId,
      LocalAssessmentDraftsCompanion companion,
    ) async {
      await (conn2.update(
        conn2.localAssessmentDrafts,
      )..where((t) => t.localDraftId.equals(draftId))).write(companion);
    }

    test('Draft mutated to possiblyDispatched on independent connection rejects deletion with blockedUnsafeState', () async {
      final photoFile = File('${tempDir.path}/evidence_disp.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      final initialDraft = buildDraft(
        draftId: 'd-conn-disp',
        photoPath: photoFile.path,
        dispatchState: CommandDispatchState.neverDispatched,
        submissionStatus: DraftSubmissionStatus.draft,
      );
      await conn1.saveLocalDraft(initialDraft);

      // Connection 2 transitions draft to possiblyDispatched directly in SQLite
      await applyRawConn2Update(
        'd-conn-disp',
        LocalAssessmentDraftsCompanion(
          dispatchState: Value(
            CommandDispatchState.possiblyDispatched.wireValue,
          ),
          updatedAt: Value(now.add(const Duration(seconds: 1))),
        ),
      );

      // Connection 1 attempts deleteDraftSafely with snapshot of initialDraft
      final outcome = await conn1.deleteDraftSafely(
        localDraftId: 'd-conn-disp',
        expectedDraft: initialDraft,
        now: now,
      );

      expect(outcome.status, equals(DraftDeletionStatus.blockedUnsafeState));
      expect(outcome.isBlockedUnsafeState, isTrue);
      expect(outcome.reason, contains('in-flight'));

      // Both the draft row and the evidence file remain intact
      final persisted = await conn1.getLocalDraft('d-conn-disp');
      expect(persisted, isNotNull);
      expect(
        persisted!.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );
      expect(photoFile.existsSync(), isTrue);
    });

    test('Unexpired lease acquired by another coordinator rejects deletion with blockedUnsafeState', () async {
      final initialDraft = buildDraft(
        draftId: 'd-conn-lease',
        dispatchState: CommandDispatchState.neverDispatched,
        submissionStatus: DraftSubmissionStatus.draft,
      );
      await conn1.saveLocalDraft(initialDraft);

      // Connection 2 acquires an unexpired lease via CAS
      final claimed = await conn2.acquireDraftClaim(
        localDraftId: 'd-conn-lease',
        actorUserId: 'usr-ref-actor-1',
        familyId: familyId,
        childId: childId.value,
        leaseDuration: const Duration(minutes: 5),
        now: now,
        overrideLeaseToken: 'worker-lease-token-99',
      );
      expect(claimed.isSuccess, isTrue);

      // Connection 1 attempts deleteDraftSafely
      final outcome = await conn1.deleteDraftSafely(
        localDraftId: 'd-conn-lease',
        expectedDraft: initialDraft,
        now: now,
      );

      expect(outcome.status, equals(DraftDeletionStatus.blockedUnsafeState));
      expect(outcome.isBlockedUnsafeState, isTrue);
      expect(outcome.reason, contains('active lease'));

      final persisted = await conn1.getLocalDraft('d-conn-lease');
      expect(persisted, isNotNull);
      expect(persisted!.leaseToken, equals('worker-lease-token-99'));
    });

    test(
      'Draft marked unknownLegacy rejects deletion with blockedUnsafeState',
      () async {
        final initialDraft = buildDraft(
          draftId: 'd-conn-legacy',
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await conn1.saveLocalDraft(initialDraft);

        // Connection 2 marks it unknownLegacy directly in SQLite
        await applyRawConn2Update(
          'd-conn-legacy',
          LocalAssessmentDraftsCompanion(
            dispatchState: Value(CommandDispatchState.unknownLegacy.wireValue),
            updatedAt: Value(now.add(const Duration(seconds: 1))),
          ),
        );

        final outcome = await conn1.deleteDraftSafely(
          localDraftId: 'd-conn-legacy',
          expectedDraft: initialDraft,
          now: now,
        );

        expect(outcome.status, equals(DraftDeletionStatus.blockedUnsafeState));
        expect(outcome.isBlockedUnsafeState, isTrue);
        expect(outcome.reason, contains('migrated from a previous version'));

        expect(await conn1.getLocalDraft('d-conn-legacy'), isNotNull);
      },
    );

    test('Draft transitioning to submittingAssessment rejects deletion with blockedUnsafeState', () async {
      final initialDraft = buildDraft(
        draftId: 'd-conn-submitting',
        submissionStatus: DraftSubmissionStatus.draft,
      );
      await conn1.saveLocalDraft(initialDraft);

      // Connection 2 transitions submissionStatus to submittingAssessment directly in SQLite
      await applyRawConn2Update(
        'd-conn-submitting',
        LocalAssessmentDraftsCompanion(
          submissionStatus: Value(
            DraftSubmissionStatus.submittingAssessment.wireValue,
          ),
          updatedAt: Value(now.add(const Duration(seconds: 1))),
        ),
      );

      final outcome = await conn1.deleteDraftSafely(
        localDraftId: 'd-conn-submitting',
        expectedDraft: initialDraft,
        now: now,
      );

      expect(outcome.status, equals(DraftDeletionStatus.blockedUnsafeState));
      expect(outcome.isBlockedUnsafeState, isTrue);
      expect(outcome.reason, contains('being submitted'));

      expect(await conn1.getLocalDraft('d-conn-submitting'), isNotNull);
    });

    test('Draft transitioning to uploadingEvidence rejects deletion with blockedUnsafeState', () async {
      final initialDraft = buildDraft(
        draftId: 'd-conn-uploading',
        submissionStatus: DraftSubmissionStatus.draft,
      );
      await conn1.saveLocalDraft(initialDraft);

      await applyRawConn2Update(
        'd-conn-uploading',
        LocalAssessmentDraftsCompanion(
          submissionStatus: Value(
            DraftSubmissionStatus.uploadingEvidence.wireValue,
          ),
          updatedAt: Value(now.add(const Duration(seconds: 1))),
        ),
      );

      final outcome = await conn1.deleteDraftSafely(
        localDraftId: 'd-conn-uploading',
        expectedDraft: initialDraft,
        now: now,
      );

      expect(outcome.status, equals(DraftDeletionStatus.blockedUnsafeState));
      expect(outcome.isBlockedUnsafeState, isTrue);
      expect(outcome.reason, contains('being uploaded'));

      expect(await conn1.getLocalDraft('d-conn-uploading'), isNotNull);
    });

    test('Draft transitioning to failedRetryable rejects deletion with blockedUnsafeState', () async {
      final initialDraft = buildDraft(
        draftId: 'd-conn-retryable',
        submissionStatus: DraftSubmissionStatus.draft,
      );
      await conn1.saveLocalDraft(initialDraft);

      await applyRawConn2Update(
        'd-conn-retryable',
        LocalAssessmentDraftsCompanion(
          submissionStatus: Value(
            DraftSubmissionStatus.failedRetryable.wireValue,
          ),
          updatedAt: Value(now.add(const Duration(seconds: 1))),
        ),
      );

      final outcome = await conn1.deleteDraftSafely(
        localDraftId: 'd-conn-retryable',
        expectedDraft: initialDraft,
        now: now,
      );

      expect(outcome.status, equals(DraftDeletionStatus.blockedUnsafeState));
      expect(outcome.isBlockedUnsafeState, isTrue);
      expect(outcome.reason, contains('queued for retry'));

      expect(await conn1.getLocalDraft('d-conn-retryable'), isNotNull);
    });

    test('Draft photo reference changed while confirmation was pending rejects with concurrencyConflict', () async {
      final initialPhoto = File('${tempDir.path}/photo_initial.jpg')
        ..writeAsBytesSync([10]);
      final newPhoto = File('${tempDir.path}/photo_new.jpg')
        ..writeAsBytesSync([20]);

      final initialDraft = buildDraft(
        draftId: 'd-conn-photo-change',
        photoPath: initialPhoto.path,
      );
      await conn1.saveLocalDraft(initialDraft);

      // Connection 2 changes the photo reference
      final photoChanged = initialDraft.copyWith(
        localPhotoPath: newPhoto.path,
        updatedAt: now.add(const Duration(seconds: 2)),
      );
      await conn2.saveLocalDraft(photoChanged);

      // Connection 1 attempts deleteDraftSafely with original snapshot
      final outcome = await conn1.deleteDraftSafely(
        localDraftId: 'd-conn-photo-change',
        expectedDraft: initialDraft,
        now: now,
      );

      expect(outcome.status, equals(DraftDeletionStatus.concurrencyConflict));
      expect(outcome.isConcurrencyConflict, isTrue);

      // The draft and new photo are preserved
      final persisted = await conn1.getLocalDraft('d-conn-photo-change');
      expect(persisted, isNotNull);
      expect(persisted!.localPhotoPath, equals(newPhoto.path));
      expect(newPhoto.existsSync(), isTrue);
    });

    test('Draft title or score modified while confirmation was pending rejects with concurrencyConflict', () async {
      final initialDraft = buildDraft(
        draftId: 'd-conn-edit',
        title: 'Original Title',
        rawScore: 5.0,
      );
      await conn1.saveLocalDraft(initialDraft);

      // Connection 2 modifies draft content
      final edited = initialDraft.copyWith(
        title: 'Modified Title',
        rawScore: 9.5,
        updatedAt: now.add(const Duration(seconds: 3)),
      );
      await conn2.saveLocalDraft(edited);

      final outcome = await conn1.deleteDraftSafely(
        localDraftId: 'd-conn-edit',
        expectedDraft: initialDraft,
        now: now,
      );

      expect(outcome.status, equals(DraftDeletionStatus.concurrencyConflict));
      expect(outcome.isConcurrencyConflict, isTrue);

      final persisted = await conn1.getLocalDraft('d-conn-edit');
      expect(persisted, isNotNull);
      expect(persisted!.title, equals('Modified Title'));
      expect(persisted.rawScore, equals(9.5));
    });

    test('Eligible unmodified draft deletes successfully via atomic CAS transaction', () async {
      final photo = File('${tempDir.path}/delete_ok.jpg')
        ..writeAsBytesSync([100]);
      final initialDraft = buildDraft(
        draftId: 'd-conn-ok',
        photoPath: photo.path,
      );
      await conn1.saveLocalDraft(initialDraft);

      // Fetch exact persisted record so timestamp representation matches
      final persisted = await conn1.getLocalDraft('d-conn-ok');
      expect(persisted, isNotNull);

      final outcome = await conn1.deleteDraftSafely(
        localDraftId: 'd-conn-ok',
        expectedDraft: persisted!,
        now: now,
      );

      expect(outcome.status, equals(DraftDeletionStatus.deleted));
      expect(outcome.isDeleted, isTrue);

      expect(await conn1.getLocalDraft('d-conn-ok'), isNull);
      expect(await conn2.getLocalDraft('d-conn-ok'), isNull);
    });

    // -----------------------------------------------------------------------
    // R26-3-01: Identity, command, evidence & photo mutations without bumped updatedAt
    // -----------------------------------------------------------------------
    for (final fieldMutation in [
      (
        'actorUserId',
        (Directory _) => const LocalAssessmentDraftsCompanion(
          actorUserId: Value('new-actor-999'),
        ),
      ),
      (
        'actorRole',
        (Directory _) =>
            const LocalAssessmentDraftsCompanion(actorRole: Value('parent')),
      ),
      (
        'createCommandId',
        (Directory _) => const LocalAssessmentDraftsCompanion(
          createCommandId: Value('cmd-create-diverged'),
        ),
      ),
      (
        'submitCommandId',
        (Directory _) => const LocalAssessmentDraftsCompanion(
          submitCommandId: Value('cmd-submit-diverged'),
        ),
      ),
      (
        'evidenceId',
        (Directory _) => const LocalAssessmentDraftsCompanion(
          evidenceId: Value('ev-id-diverged'),
        ),
      ),
      (
        'serverAssessmentId',
        (Directory _) => const LocalAssessmentDraftsCompanion(
          serverAssessmentId: Value('srv-assess-diverged'),
        ),
      ),
      (
        'serverEvidenceId',
        (Directory _) => const LocalAssessmentDraftsCompanion(
          serverEvidenceId: Value('srv-ev-diverged'),
        ),
      ),
      (
        'localPhotoPath',
        (Directory dir) => LocalAssessmentDraftsCompanion(
          localPhotoPath: Value('${dir.path}/diverged_photo.jpg'),
        ),
      ),
      (
        'localCompressedPhotoPath',
        (Directory dir) => LocalAssessmentDraftsCompanion(
          localCompressedPhotoPath: Value('${dir.path}/diverged_comp.jpg'),
        ),
      ),
      (
        'sha256Checksum',
        (Directory _) => const LocalAssessmentDraftsCompanion(
          sha256Checksum: Value('abcdef1234567890'),
        ),
      ),
      (
        'familyId',
        (Directory _) =>
            const LocalAssessmentDraftsCompanion(familyId: Value('fam-other')),
      ),
      (
        'childId',
        (Directory _) =>
            const LocalAssessmentDraftsCompanion(childId: Value('c-other')),
      ),
    ]) {
      test(
        'R26-3-01: Mutation to ${fieldMutation.$1} WITHOUT changing updatedAt rejects with concurrencyConflict',
        () async {
          final photo = File('${tempDir.path}/photo_${fieldMutation.$1}.jpg')
            ..writeAsBytesSync([10, 20, 30]);
          final initialDraft = buildDraft(
            draftId: 'd-mutation-${fieldMutation.$1}',
            photoPath: photo.path,
          );
          await conn1.saveLocalDraft(initialDraft);

          final persisted = await conn1.getLocalDraft(
            'd-mutation-${fieldMutation.$1}',
          );
          if (persisted == null) {
            fail('Expected persisted draft d-mutation-${fieldMutation.$1}');
          }

          // Connection 2 modifies the target field directly in SQLite WITHOUT bumping updatedAt
          await applyRawConn2Update(
            'd-mutation-${fieldMutation.$1}',
            fieldMutation.$2(tempDir),
          );

          // Confirm in conn1 that updatedAt did NOT change
          final afterConn2 = await conn1.getLocalDraft(
            'd-mutation-${fieldMutation.$1}',
          );
          expect(
            afterConn2!.updatedAt.isAtSameMomentAs(persisted.updatedAt),
            isTrue,
            reason: 'updatedAt must remain strictly identical to test non-timestamp CAS guard',
          );

          // Connection 1 attempts deleteDraftSafely using the original expected snapshot
          final outcome = await conn1.deleteDraftSafely(
            localDraftId: 'd-mutation-${fieldMutation.$1}',
            expectedDraft: persisted,
            now: now,
          );

          expect(
            outcome.status,
            equals(DraftDeletionStatus.concurrencyConflict),
            reason:
                'Divergence in ${fieldMutation.$1} must trigger concurrency conflict',
          );
          expect(outcome.isConcurrencyConflict, isTrue);

          // Draft and original photo file remain preserved
          final surviving = await conn1.getLocalDraft(
            'd-mutation-${fieldMutation.$1}',
          );
          expect(surviving, isNotNull);
          expect(photo.existsSync(), isTrue);
          expect(photo.readAsBytesSync(), equals([10, 20, 30]));
        },
      );
    }
  });
}
