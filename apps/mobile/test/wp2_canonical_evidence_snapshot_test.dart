import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/assessments/services/local_evidence_file_store.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:path/path.dart' as p;

void _ensureSqliteInitialized() {
  if (Platform.isWindows) {
    try {
      DynamicLibrary.open('sqlite3.dll');
    } catch (_) {
      for (final candidate in [
        File('.dart_tool/lib/sqlite3.dll'),
        File('../../.dart_tool/lib/sqlite3.dll'),
        File('../.dart_tool/lib/sqlite3.dll'),
      ]) {
        if (candidate.existsSync()) {
          try {
            DynamicLibrary.open(candidate.absolute.path);
            break;
          } catch (_) {}
        }
      }
    }
  }
}

void main() {
  setUpAll(_ensureSqliteInitialized);

  final jpegPayload = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x11, 0x22, 0x33, 0x44];
  final pngPayload = <int>[
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x01,
    0x02,
    0x03,
  ];

  group(
    'WP2 DefaultLocalEvidenceFileStore Canonical Snapshot & Restart Integrity',
    () {
      late Directory tempDir;
      late Directory evidenceBaseDir;
      late DefaultLocalEvidenceFileStore fileStore;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('learnward_wp2_snap_');
        evidenceBaseDir = Directory('${tempDir.path}/app_docs')..createSync();
        fileStore = DefaultLocalEvidenceFileStore(
          baseDirectory: evidenceBaseDir,
          clock: () => DateTime.utc(2026, 11, 14, 15, 0, 0),
        );
      });

      tearDown(() {
        if (tempDir.existsSync()) {
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      });

      test('freezes JPEG and PNG canonical snapshots exclusively by magic bytes and verifies on reopen', () async {
        final jpgSnap = await fileStore.saveCanonicalEvidenceSnapshot(
          localDraftId: 'draft_jpg_1',
          bytes: jpegPayload,
        );
        expect(jpgSnap.mediaType, 'image/jpeg');
        expect(jpgSnap.fileExtension, 'jpg');
        expect(jpgSnap.byteLength, jpegPayload.length);
        expect(jpgSnap.sha256Checksum, computeSha256Hex(jpegPayload));
        expect(File(jpgSnap.filePath).existsSync(), isTrue);

        final pngSnap = await fileStore.saveCanonicalEvidenceSnapshot(
          localDraftId: 'draft_png_1',
          bytes: pngPayload,
        );
        expect(pngSnap.mediaType, 'image/png');
        expect(pngSnap.fileExtension, 'png');
        expect(pngSnap.byteLength, pngPayload.length);
        expect(pngSnap.sha256Checksum, computeSha256Hex(pngPayload));
        expect(File(pngSnap.filePath).existsSync(), isTrue);

        // Simulated process restart with fresh DefaultLocalEvidenceFileStore instance
        final freshStore = DefaultLocalEvidenceFileStore(
          baseDirectory: evidenceBaseDir,
        );
        final verifiedJpg = await freshStore.verifyCanonicalEvidenceSnapshot(
          localDraftId: 'draft_jpg_1',
          canonicalFilePath: jpgSnap.filePath,
          expectedSha256: jpgSnap.sha256Checksum,
        );
        expect(verifiedJpg.bytes, equals(jpegPayload));
        expect(verifiedJpg.mediaType, 'image/jpeg');

        final verifiedPng = await freshStore.verifyCanonicalEvidenceSnapshot(
          localDraftId: 'draft_png_1',
          canonicalFilePath: pngSnap.filePath,
          expectedSha256: pngSnap.sha256Checksum,
        );
        expect(verifiedPng.bytes, equals(pngPayload));
        expect(verifiedPng.mediaType, 'image/png');
      });

      test('exclusive creation avoids overwriting prior snapshots and preserves existing files', () async {
        int counter = 0;
        final collidingStore = DefaultLocalEvidenceFileStore(
          baseDirectory: evidenceBaseDir,
          suffixGenerator: () {
            counter++;
            // Return colliding suffix on second call's first try, then unique
            return counter <= 2 ? 'fixed-uuid' : 'unique-$counter';
          },
          clock: () => DateTime.utc(2026, 11, 14, 15, 0, 0),
        );

        final first = await collidingStore.saveCanonicalEvidenceSnapshot(
          localDraftId: 'draft-col',
          bytes: jpegPayload,
        );
        final second = await collidingStore.saveCanonicalEvidenceSnapshot(
          localDraftId: 'draft-col',
          bytes: pngPayload,
        );

        expect(first.filePath, isNot(equals(second.filePath)));
        expect(File(first.filePath).readAsBytesSync(), equals(jpegPayload));
        expect(File(second.filePath).readAsBytesSync(), equals(pngPayload));
      });

      test('mutating caller buffer after freeze call does not alter frozen bytes or SHA-256', () async {
        final callerBuffer = Uint8List.fromList(jpegPayload);
        final expectedSha = computeSha256Hex(callerBuffer);

        final snap = await fileStore.saveCanonicalEvidenceSnapshot(
          localDraftId: 'draft-copy-iso',
          bytes: callerBuffer,
        );
        callerBuffer[4] = 0x99;

        final diskBytes = File(snap.filePath).readAsBytesSync();
        expect(computeSha256Hex(diskBytes), expectedSha);
        expect(snap.sha256Checksum, expectedSha);
      });

      test('detects partial or corrupted post-write disk flush without deleting partial file', () async {
        String? capturedPath;
        final corruptingStore = DefaultLocalEvidenceFileStore(
          baseDirectory: evidenceBaseDir,
          onBeforeCanonicalVerify: (path) {
            capturedPath = path;
            // Simulate silent truncation / disk corruption before post-write verify
            File(path).writeAsBytesSync(jpegPayload.sublist(0, 4), flush: true);
          },
        );

        await expectLater(
          () => corruptingStore.saveCanonicalEvidenceSnapshot(
            localDraftId: 'draft-corrupt-write',
            bytes: jpegPayload,
          ),
          throwsA(
            isA<EvidenceStorageException>().having(
              (e) => e.kind,
              'kind',
              EvidenceStorageFailureKind.corruptedOrTamperedSnapshot,
            ),
          ),
        );
        // Partial file preserved without automatic deletion
        expect(capturedPath, isNotNull);
        expect(File(capturedPath!).existsSync(), isTrue);
      });

      test('readVerifiedCanonicalSnapshot enforces strict fail-closed verification with ZERO mutable fallback across SQLite restart', () async {
        final dbFile = File('${tempDir.path}/mobile_snap.sqlite');
        var db = AppDatabase(NativeDatabase(dbFile));
        try {
          final mutableSourcePath = '${tempDir.path}/mutable_camera_pick.jpg';
          File(mutableSourcePath).writeAsBytesSync(jpegPayload, flush: true);

          final canonicalSnap = await fileStore.saveCanonicalEvidenceSnapshot(
            localDraftId: 'draft-restart-1',
            bytes: pngPayload,
          );

          final draft = LocalAssessmentDraft(
            localDraftId: 'draft-restart-1',
            familyId: 'fam-1',
            childId: 'child-1',
            actorUserId: 'actor-1',
            actorRole: 'child',
            createCommandId: 'cmd-c1',
            submitCommandId: 'cmd-s1',
            evidenceId: 'evi-1',
            subjectKey: SubjectKey.science,
            subject: 'Science',
            title: 'Plant Lab',
            assessmentType: 'lab',
            difficulty: 'medium',
            rawScore: 10,
            maxScore: 10,
            localPhotoPath: mutableSourcePath,
            localCompressedPhotoPath: canonicalSnap.filePath,
            sha256Checksum: canonicalSnap.sha256Checksum,
            occurredAt: DateTime.utc(2026, 11, 14, 9, 0),
            updatedAt: DateTime.utc(2026, 11, 14, 9, 5),
          );
          final reg = await db.registerOrUpdateDraftIfUnchanged(
            expected: null,
            desired: draft,
          );
          expect(reg.isSuccess, isTrue);

          // Simulate restart: close and reopen SQLite + create fresh fileStore
          await db.close();
          db = AppDatabase(NativeDatabase(dbFile));
          final freshFileStore = DefaultLocalEvidenceFileStore(
            baseDirectory: evidenceBaseDir,
          );

          final loaded = await db.getLocalDraft('draft-restart-1');
          expect(loaded, isNotNull);

          // 1. Valid snapshot passes verification
          final okRead = await freshFileStore.readVerifiedCanonicalSnapshot(
            draft: loaded!,
          );
          expect(okRead.bytes, equals(pngPayload));
          expect(okRead.sha256Checksum, canonicalSnap.sha256Checksum);

          // 2. Corrupt canonical file on disk -> fails closed without reading mutableSourcePath or deleting files
          File(canonicalSnap.filePath)
              .writeAsBytesSync(jpegPayload, flush: true);
          await expectLater(
            () => freshFileStore.readVerifiedCanonicalSnapshot(draft: loaded),
            throwsA(
              isA<EvidenceStorageException>().having(
                (e) => e.kind,
                'kind',
                EvidenceStorageFailureKind.corruptedOrTamperedSnapshot,
              ),
            ),
          );
          expect(File(canonicalSnap.filePath).existsSync(), isTrue);
          expect(File(mutableSourcePath).existsSync(), isTrue);

          // 3. Delete canonical file -> fails closed with missingSnapshot even though mutableSourcePath still exists!
          File(canonicalSnap.filePath).deleteSync();
          await expectLater(
            () => freshFileStore.readVerifiedCanonicalSnapshot(draft: loaded),
            throwsA(
              isA<EvidenceStorageException>().having(
                (e) => e.kind,
                'kind',
                EvidenceStorageFailureKind.missingSnapshot,
              ),
            ),
          );
          expect(File(mutableSourcePath).existsSync(), isTrue);

          // 4. Draft without localCompressedPhotoPath cannot fall back to mutable localPhotoPath
          final unverifiedDraft = loaded.copyWith(
            localCompressedPhotoPath: null,
            sha256Checksum: null,
          );
          await expectLater(
            () => freshFileStore.readVerifiedCanonicalSnapshot(
              draft: unverifiedDraft,
            ),
            throwsA(
              isA<EvidenceStorageException>().having(
                (e) => e.kind,
                'kind',
                EvidenceStorageFailureKind.missingSnapshot,
              ),
            ),
          );
        } finally {
          await db.close();
        }
      });

      test(
        'rejects out-of-bounds paths, traversal attempts, and symlink escapes',
        () async {
          final outsideFile = File('${tempDir.path}/outside_secret.jpg')
            ..writeAsBytesSync(jpegPayload, flush: true);

          await expectLater(
            () => fileStore.verifyCanonicalEvidenceSnapshot(
              localDraftId: 'draft-escape',
              canonicalFilePath: outsideFile.path,
              expectedSha256: computeSha256Hex(jpegPayload),
            ),
            throwsA(
              isA<EvidenceStorageException>().having(
                (e) => e.kind,
                'kind',
                EvidenceStorageFailureKind.outOfBoundsOrSymlink,
              ),
            ),
          );

          final traversalPath = p.join(
            evidenceBaseDir.path,
            'draft_evidence',
            '..',
            'outside_secret.jpg',
          );
          await expectLater(
            () => fileStore.verifyCanonicalEvidenceSnapshot(
              localDraftId: 'draft-trav',
              canonicalFilePath: traversalPath,
              expectedSha256: computeSha256Hex(jpegPayload),
            ),
            throwsA(
              isA<EvidenceStorageException>().having(
                (e) => e.kind,
                'kind',
                EvidenceStorageFailureKind.outOfBoundsOrSymlink,
              ),
            ),
          );

          // Symlink escape verification when OS permits symlink creation
          final evidenceDir = Directory(
            '${evidenceBaseDir.path}/draft_evidence',
          )..createSync(recursive: true);
          final linkPath = '${evidenceDir.path}/evil_link.jpg';
          var linkCreated = false;
          try {
            Link(linkPath).createSync(outsideFile.path);
            linkCreated = true;
          } on FileSystemException {
            // Unprivileged Windows environments without Developer Mode forbid Link creation
          }
          if (linkCreated) {
            await expectLater(
              () => fileStore.verifyCanonicalEvidenceSnapshot(
                localDraftId: 'draft-symlink',
                canonicalFilePath: linkPath,
                expectedSha256: computeSha256Hex(jpegPayload),
              ),
              throwsA(
                isA<EvidenceStorageException>().having(
                  (e) => e.kind,
                  'kind',
                  EvidenceStorageFailureKind.outOfBoundsOrSymlink,
                ),
              ),
            );
          }
        },
      );

      test('InMemoryLocalDraftStore enforces WP2 CAS, lease fencing, and pause/resume parity', () async {
        final memStore = InMemoryLocalDraftStore();
        final t0 = DateTime.utc(2026, 11, 14, 16, 0, 0);
        final sha = computeSha256Hex(jpegPayload);
        final draft = LocalAssessmentDraft(
          localDraftId: 'mem-1',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'actor-1',
          actorRole: 'child',
          createCommandId: 'cmd-c1',
          submitCommandId: 'cmd-s1',
          evidenceId: 'evi-1',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Quick Check',
          assessmentType: 'quiz',
          difficulty: 'easy',
          rawScore: 5,
          maxScore: 5,
          localCompressedPhotoPath: '/mock/canonical/mem-1.jpg',
          sha256Checksum: sha,
          occurredAt: t0,
          updatedAt: t0,
        );

        final reg = await memStore.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: draft,
          now: t0,
        );
        expect(reg.isSuccess, isTrue);

        final claim = await memStore.acquireDraftClaim(
          localDraftId: 'mem-1',
          actorUserId: 'actor-1',
          familyId: 'fam-1',
          childId: 'child-1',
          leaseDuration: const Duration(minutes: 1),
          now: t0,
          overrideLeaseToken: 'mem-tok-1',
        );
        expect(claim.isSuccess, isTrue);

        await expectLater(
          () => memStore.saveLocalDraft(draft.copyWith(title: 'Blocked')),
          throwsA(isA<DraftWriteConflictException>()),
        );

        final wrongStage = await memStore.markDraftStageAndDispatch(
          localDraftId: 'mem-1',
          leaseToken: 'wrong-tok',
          authenticatedActorId: 'actor-1',
          targetStage: DraftSubmissionStatus.uploadingEvidence,
          now: t0,
        );
        expect(wrongStage.status, DraftCasStatus.leaseConflict);

        final released = await memStore.releaseDraftClaim(
          localDraftId: 'mem-1',
          leaseToken: 'mem-tok-1',
          authenticatedActorId: 'actor-1',
          now: t0.add(const Duration(seconds: 5)),
        );
        expect(released.isSuccess, isTrue);
        expect(released.draft!.leaseToken, isNull);
      });

      test('InMemoryLocalDraftStore enforces R33-01, R33-02, and R33-03 hardening rules', () async {
        final memStore = InMemoryLocalDraftStore();
        final t0 = DateTime.utc(2026, 11, 14, 12, 0);

        // R33-01: Unbound actor row rejects edits & actor adoption
        final unbound = LocalAssessmentDraft(
          localDraftId: 'mem-unbound-1',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: null,
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Unbound Row',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 6,
          maxScore: 10,
          occurredAt: t0,
          updatedAt: t0,
        );
        await memStore.saveLocalDraft(unbound);
        await expectLater(
          () => memStore.saveLocalDraft(
            unbound.copyWith(actorUserId: 'adopted-user'),
          ),
          throwsA(isA<DraftWriteConflictException>()),
        );
        await expectLater(
          () => memStore.saveLocalDraft(unbound.copyWith(title: 'Mutated')),
          throwsA(isA<DraftWriteConflictException>()),
        );
        final persistedUnbound = await memStore.getLocalDraft('mem-unbound-1');
        expect(persistedUnbound!.actorUserId, isNull);
        expect(persistedUnbound.title, 'Unbound Row');

        // R33-02: deleteLocalDraft rejects unbound, dispatched, non-draft, expired lease, server IDs
        await expectLater(
          () => memStore.deleteLocalDraft('mem-unbound-1'),
          throwsA(isA<DraftWriteConflictException>()),
        );

        final inFlightNoSnap = LocalAssessmentDraft(
          localDraftId: 'mem-inflight-1',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'actor-1',
          createCommandId: 'cmd-c',
          submitCommandId: 'cmd-s',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Original In-Flight',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8,
          maxScore: 10,
          dispatchState: CommandDispatchState.possiblyDispatched,
          submissionStatus: DraftSubmissionStatus.submittingAssessment,
          occurredAt: t0,
          updatedAt: t0,
        );
        await memStore.saveLocalDraft(inFlightNoSnap);
        await expectLater(
          () => memStore.deleteLocalDraft('mem-inflight-1'),
          throwsA(isA<DraftWriteConflictException>()),
        );
        // R33-03: saveLocalDraft rejects content or command mutation once possiblyDispatched
        await expectLater(
          () => memStore.saveLocalDraft(
            inFlightNoSnap.copyWith(title: 'Overwritten Title'),
          ),
          throwsA(isA<DraftWriteConflictException>()),
        );
        await expectLater(
          () => memStore.saveLocalDraft(
            inFlightNoSnap.copyWith(createCommandId: 'cmd-new'),
          ),
          throwsA(isA<DraftWriteConflictException>()),
        );
        final persistedInFlight = await memStore.getLocalDraft(
          'mem-inflight-1',
        );
        expect(persistedInFlight!.title, 'Original In-Flight');
        expect(persistedInFlight.createCommandId, 'cmd-c');
      });
    },
  );
}
