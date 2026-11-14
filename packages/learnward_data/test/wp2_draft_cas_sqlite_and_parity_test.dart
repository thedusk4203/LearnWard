import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

final String _validShaA = 'a' * 64;
final String _validShaB = 'b' * 64;

LocalAssessmentDraft _buildDraft({
  String localDraftId = 'draft-cas-1',
  String familyId = 'fam-1',
  String childId = 'child-1',
  String? actorUserId = 'actor-1',
  String? actorRole = 'child',
  String? createCommandId = 'cmd-create-1',
  String? submitCommandId = 'cmd-submit-1',
  String? evidenceId = 'evi-client-1',
  String? serverAssessmentId,
  String? serverEvidenceId,
  String? localPhotoPath = '/tmp/source.jpg',
  String? localCompressedPhotoPath,
  String? sha256Checksum,
  String title = 'Geometry Quiz',
  double rawScore = 9.0,
  DraftSubmissionStatus submissionStatus = DraftSubmissionStatus.draft,
  CommandDispatchState dispatchState = CommandDispatchState.neverDispatched,
  int retryCount = 0,
  String? lastErrorMessage,
  DateTime? nextAttemptAt,
  String? leaseToken,
  DateTime? leaseExpiresAt,
  DateTime? updatedAt,
}) {
  final ts = (updatedAt ?? DateTime.utc(2026, 11, 14, 9, 0, 0));
  return LocalAssessmentDraft(
    localDraftId: localDraftId,
    familyId: familyId,
    childId: childId,
    actorUserId: actorUserId,
    actorRole: actorRole,
    createCommandId: createCommandId,
    submitCommandId: submitCommandId,
    evidenceId: evidenceId,
    serverAssessmentId: serverAssessmentId,
    serverEvidenceId: serverEvidenceId,
    subjectKey: SubjectKey.math,
    subject: 'Math',
    title: title,
    assessmentType: 'quiz',
    difficulty: 'medium',
    rawScore: rawScore,
    maxScore: 10.0,
    localPhotoPath: localPhotoPath,
    localCompressedPhotoPath: localCompressedPhotoPath,
    sha256Checksum: sha256Checksum,
    occurredAt: DateTime.utc(2026, 11, 14, 8, 30, 0),
    updatedAt: ts,
    submissionStatus: submissionStatus,
    retryCount: retryCount,
    dispatchState: dispatchState,
    lastErrorMessage: lastErrorMessage,
    nextAttemptAt: nextAttemptAt,
    leaseToken: leaseToken,
    leaseExpiresAt: leaseExpiresAt,
  );
}

void main() {
  group('WP2 SQLite Multi-Connection Concurrency, Lease Fencing & Restart Persistence', () {
    late Directory tempDir;
    late File dbFile;
    late AppDatabase conn1;
    late AppDatabase conn2;

    final now = DateTime.utc(2026, 11, 14, 10, 0, 0);

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_wp2_cas_');
      dbFile = File('${tempDir.path}/wp2_cas.sqlite');
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

    test('concurrent fresh direct-submit registration elects single winner without overwrite', () async {
      final draftConn1 = _buildDraft(
        localDraftId: 'draft-race-reg',
        title: 'Winner A',
        localCompressedPhotoPath: '/app/draft_evidence/a.jpg',
        sha256Checksum: _validShaA,
      );
      final draftConn2 = _buildDraft(
        localDraftId: 'draft-race-reg',
        title: 'Winner B',
        localCompressedPhotoPath: '/app/draft_evidence/b.jpg',
        sha256Checksum: _validShaB,
      );

      final results = await Future.wait([
        conn1.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: draftConn1,
          now: now,
        ),
        conn2.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: draftConn2,
          now: now,
        ),
      ]);

      final successes = results.where((r) => r.isSuccess).toList();
      final conflicts = results
          .where((r) => r.status == DraftCasStatus.casConflict)
          .toList();
      expect(successes.length, 1);
      expect(conflicts.length, 1);

      final persisted = await conn1.getLocalDraft('draft-race-reg');
      expect(persisted, isNotNull);
      expect(persisted!.title, successes.first.draft!.title);
      expect(persisted.sha256Checksum, successes.first.draft!.sha256Checksum);
    });

    test(
      'single-winner claim acquisition across 2 independent SQLite connections',
      () async {
        final draft = _buildDraft(
          localCompressedPhotoPath: '/app/draft_evidence/snap.jpg',
          sha256Checksum: _validShaA,
        );
        final reg = await conn1.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: draft,
          now: now,
        );
        expect(reg.isSuccess, isTrue);

        final claimResults = await Future.wait([
          conn1.acquireDraftClaim(
            localDraftId: draft.localDraftId,
            actorUserId: 'actor-1',
            familyId: 'fam-1',
            childId: 'child-1',
            leaseDuration: const Duration(minutes: 2),
            now: now,
            overrideLeaseToken: 'lease-conn-1',
          ),
          conn2.acquireDraftClaim(
            localDraftId: draft.localDraftId,
            actorUserId: 'actor-1',
            familyId: 'fam-1',
            childId: 'child-1',
            leaseDuration: const Duration(minutes: 2),
            now: now,
            overrideLeaseToken: 'lease-conn-2',
          ),
        ]);

        final winners = claimResults.where((r) => r.isSuccess).toList();
        final losers = claimResults
            .where((r) => r.status == DraftCasStatus.leaseConflict)
            .toList();
        expect(winners.length, 1);
        expect(losers.length, 1);

        final persisted = await conn2.getLocalDraft(draft.localDraftId);
        expect(persisted!.leaseToken, winners.first.draft!.leaseToken);
      },
    );

    test('expired lease reclamation rotates token and fences stale worker across every CAS op', () async {
      final draft = _buildDraft(
        localCompressedPhotoPath: '/app/draft_evidence/snap.jpg',
        sha256Checksum: _validShaA,
      );
      await conn1.registerOrUpdateDraftIfUnchanged(
        expected: null,
        desired: draft,
        now: now,
      );

      final claim1 = await conn1.acquireDraftClaim(
        localDraftId: draft.localDraftId,
        actorUserId: 'actor-1',
        familyId: 'fam-1',
        childId: 'child-1',
        leaseDuration: const Duration(seconds: 30),
        now: now,
        overrideLeaseToken: 'lease-stale',
      );
      expect(claim1.isSuccess, isTrue);

      // Cannot resume while unexpired
      final prematureResume = await conn2.resumeDraftClaimAfterExpiry(
        localDraftId: draft.localDraftId,
        actorUserId: 'actor-1',
        familyId: 'fam-1',
        childId: 'child-1',
        leaseDuration: const Duration(minutes: 1),
        now: now.add(const Duration(seconds: 15)),
        overrideLeaseToken: 'lease-fresh',
      );
      expect(prematureResume.status, DraftCasStatus.leaseConflict);

      // After expiry, resume must rotate token (same token is rejected)
      final afterExpiry = now.add(const Duration(seconds: 31));
      final sameTokenResume = await conn2.resumeDraftClaimAfterExpiry(
        localDraftId: draft.localDraftId,
        actorUserId: 'actor-1',
        familyId: 'fam-1',
        childId: 'child-1',
        leaseDuration: const Duration(minutes: 1),
        now: afterExpiry,
        overrideLeaseToken: 'lease-stale',
      );
      expect(sameTokenResume.status, DraftCasStatus.invalidInput);

      final resumed = await conn2.resumeDraftClaimAfterExpiry(
        localDraftId: draft.localDraftId,
        actorUserId: 'actor-1',
        familyId: 'fam-1',
        childId: 'child-1',
        leaseDuration: const Duration(minutes: 1),
        now: afterExpiry,
        overrideLeaseToken: 'lease-fresh',
      );
      expect(resumed.isSuccess, isTrue);
      expect(resumed.draft!.leaseToken, 'lease-fresh');

      // Advance stage under fresh lease
      final staged = await conn2.markDraftStageAndDispatch(
        localDraftId: draft.localDraftId,
        leaseToken: 'lease-fresh',
        authenticatedActorId: 'actor-1',
        targetStage: DraftSubmissionStatus.uploadingEvidence,
        now: afterExpiry.add(const Duration(seconds: 1)),
      );
      expect(staged.isSuccess, isTrue);

      // Stale worker tries every lease-fenced operation with old token -> all fenced
      final staleNow = afterExpiry.add(const Duration(seconds: 2));
      for (final staleResult in [
        await conn1.markDraftStageAndDispatch(
          localDraftId: draft.localDraftId,
          leaseToken: 'lease-stale',
          authenticatedActorId: 'actor-1',
          targetStage: DraftSubmissionStatus.submittingAssessment,
          now: staleNow,
        ),
        await conn1.persistServerAssessmentId(
          localDraftId: draft.localDraftId,
          leaseToken: 'lease-stale',
          authenticatedActorId: 'actor-1',
          serverAssessmentId: 'srv-rogue',
          now: staleNow,
        ),
        await conn1.persistServerEvidenceId(
          localDraftId: draft.localDraftId,
          leaseToken: 'lease-stale',
          authenticatedActorId: 'actor-1',
          serverEvidenceId: 'srv-evi-rogue',
          expectedEvidenceId: 'evi-client-1',
          expectedSha256Checksum: _validShaA,
          now: staleNow,
        ),
        await conn1.scheduleDraftRetry(
          localDraftId: draft.localDraftId,
          leaseToken: 'lease-stale',
          authenticatedActorId: 'actor-1',
          nextAttemptAt: staleNow.add(const Duration(minutes: 1)),
          recoveryCode: DraftRecoveryCode.retryScheduled,
          errorMessage: 'Transient error',
          now: staleNow,
        ),
        await conn1.quarantineDraftOutcome(
          localDraftId: draft.localDraftId,
          leaseToken: 'lease-stale',
          authenticatedActorId: 'actor-1',
          recoveryCode: DraftRecoveryCode.storageContentConflict,
          errorMessage: 'Rogue quarantine',
          now: staleNow,
        ),
        await conn1.completeDraftSubmission(
          localDraftId: draft.localDraftId,
          leaseToken: 'lease-stale',
          authenticatedActorId: 'actor-1',
          serverAssessmentId: 'srv-rogue',
          now: staleNow,
        ),
        await conn1.releaseDraftClaim(
          localDraftId: draft.localDraftId,
          leaseToken: 'lease-stale',
          authenticatedActorId: 'actor-1',
          now: staleNow,
        ),
      ]) {
        expect(staleResult.status, DraftCasStatus.leaseConflict);
      }

      // Fresh leaseholder's state remains untouched
      final afterFencing = await conn2.getLocalDraft(draft.localDraftId);
      expect(afterFencing!.leaseToken, 'lease-fresh');
      expect(afterFencing.serverAssessmentId, isNull);
      expect(
        afterFencing.submissionStatus,
        DraftSubmissionStatus.uploadingEvidence,
      );
      expect(
        afterFencing.dispatchState,
        CommandDispatchState.possiblyDispatched,
      );
    });

    test('saveLocalDraft and deleteLocalDraft reject active leases, frozen snapshots, and quarantine', () async {
      final draft = _buildDraft(
        localCompressedPhotoPath: '/app/draft_evidence/frozen.jpg',
        sha256Checksum: _validShaA,
      );
      await conn1.registerOrUpdateDraftIfUnchanged(
        expected: null,
        desired: draft,
        now: now,
      );

      // Frozen canonical snapshot blocks legacy saveLocalDraft overwrite
      await expectLater(
        () => conn2.saveLocalDraft(draft.copyWith(title: 'Autosave overwrite')),
        throwsA(isA<DraftWriteConflictException>()),
      );

      // Claim lease & verify deleteLocalDraft and saveLocalDraft fail closed
      final unphotoed = _buildDraft(
        localDraftId: 'draft-leased-guard',
        localPhotoPath: null,
        evidenceId: null,
      );
      await conn1.registerOrUpdateDraftIfUnchanged(
        expected: null,
        desired: unphotoed,
        now: now,
      );
      final claimed = await conn1.acquireDraftClaim(
        localDraftId: 'draft-leased-guard',
        actorUserId: 'actor-1',
        familyId: 'fam-1',
        childId: 'child-1',
        leaseDuration: const Duration(minutes: 5),
        now: now,
      );
      expect(claimed.isSuccess, isTrue);

      await expectLater(
        () => conn2.saveLocalDraft(unphotoed.copyWith(title: 'Stale autosave')),
        throwsA(isA<DraftWriteConflictException>()),
      );
      await expectLater(
        () => conn2.deleteLocalDraft('draft-leased-guard'),
        throwsA(isA<DraftWriteConflictException>()),
      );
    });

    test('unknown wire status fails closed across reopen WITHOUT rewriting SQLite column', () async {
      final draft = _buildDraft(
        localDraftId: 'draft-unknown-wire',
        localCompressedPhotoPath: '/app/draft_evidence/snap.jpg',
        sha256Checksum: _validShaA,
      );
      await conn1.registerOrUpdateDraftIfUnchanged(
        expected: null,
        desired: draft,
        now: now,
      );

      // Corrupt wire status directly in SQLite (simulating future version or DB corruption)
      await conn1.customStatement(
        "UPDATE local_assessment_drafts "
        "SET submission_status = 'future_unknown_stage_v9', last_error_message = NULL "
        "WHERE local_draft_id = 'draft-unknown-wire';",
      );

      await conn1.close();
      await conn2.close();
      final reopened = AppDatabase(NativeDatabase(dbFile));
      try {
        final decoded = await reopened.getLocalDraft('draft-unknown-wire');
        expect(decoded, isNotNull);
        expect(decoded!.submissionStatus, DraftSubmissionStatus.terminalError);
        expect(
          decoded.lastErrorMessage,
          'LW4B1:UNKNOWN_WIRE_STATUS:future_unknown_stage_v9',
        );
        expect(decoded.recoveryCode, DraftRecoveryCode.unknownWireStatus);
        expect(decoded.isReadOnlyQuarantined, isTrue);
        expect(decoded.canAutoSubmit, isFalse);
        expect(decoded.isUnsafeToDelete(now: now), isTrue);

        // Verify raw SQLite value was NOT mutated during read decoding
        final rawRows = await reopened
            .customSelect(
              'SELECT submission_status, last_error_message '
              'FROM local_assessment_drafts '
              "WHERE local_draft_id = 'draft-unknown-wire';",
            )
            .get();
        expect(rawRows.length, 1);
        expect(
          rawRows.single.read<String>('submission_status'),
          'future_unknown_stage_v9',
        );
        expect(rawRows.single.read<String?>('last_error_message'), isNull);

        // Mutations, claims, pause, and deletion all fail closed
        final claimAttempt = await reopened.acquireDraftClaim(
          localDraftId: 'draft-unknown-wire',
          actorUserId: 'actor-1',
          familyId: 'fam-1',
          childId: 'child-1',
          leaseDuration: const Duration(minutes: 1),
          now: now,
        );
        expect(claimAttempt.status, DraftCasStatus.blockedQuarantined);

        final delOutcome = await reopened.deleteDraftSafely(
          localDraftId: 'draft-unknown-wire',
          expectedDraft: decoded,
          now: now,
        );
        expect(delOutcome.status, DraftDeletionStatus.blockedUnsafeState);

        await expectLater(
          () => reopened.saveLocalDraft(decoded.copyWith(title: 'Overwrite')),
          throwsA(isA<DraftWriteConflictException>()),
        );
        await expectLater(
          () => reopened.deleteLocalDraft('draft-unknown-wire'),
          throwsA(isA<DraftWriteConflictException>()),
        );
      } finally {
        await reopened.close();
        conn1 = AppDatabase(NativeDatabase(dbFile));
        conn2 = AppDatabase(NativeDatabase(dbFile));
      }
    });

    test('unbound actor, unknownLegacy, and unverified possiblyDispatched fail closed across reopen preserving NULLs', () async {
      final unbound = _buildDraft(
        localDraftId: 'draft-unbound-actor',
        actorUserId: null,
        actorRole: null,
      );
      final legacy = _buildDraft(
        localDraftId: 'draft-legacy-row',
        actorUserId: null,
        actorRole: null,
        createCommandId: null,
        submitCommandId: null,
        dispatchState: CommandDispatchState.unknownLegacy,
        submissionStatus: DraftSubmissionStatus.draft,
      );
      final unverifiedInFlight = _buildDraft(
        localDraftId: 'draft-unverified-bytes',
        actorUserId: 'actor-1',
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.uploadingEvidence,
        localPhotoPath: '/mutable/raw_camera.jpg',
        localCompressedPhotoPath: null,
        sha256Checksum: null,
      );

      await conn1.saveLocalDraft(unbound);
      await conn1.saveLocalDraft(legacy);
      await conn1.saveLocalDraft(unverifiedInFlight);

      await conn1.close();
      await conn2.close();
      final reopened = AppDatabase(NativeDatabase(dbFile));
      try {
        final loadedUnbound = await reopened.getLocalDraft(
          'draft-unbound-actor',
        );
        expect(loadedUnbound!.actorUserId, isNull);
        expect(loadedUnbound.isReadOnlyQuarantined, isTrue);
        expect(loadedUnbound.canAutoSubmit, isFalse);

        final loadedLegacy = await reopened.getLocalDraft('draft-legacy-row');
        expect(loadedLegacy!.actorUserId, isNull);
        expect(loadedLegacy.createCommandId, isNull);
        expect(loadedLegacy.submitCommandId, isNull);
        expect(loadedLegacy.isReadOnlyQuarantined, isTrue);
        expect(loadedLegacy.canAutoSubmit, isFalse);

        final loadedUnverified = await reopened.getLocalDraft(
          'draft-unverified-bytes',
        );
        expect(
          loadedUnverified!.derivedQuarantineCode,
          DraftRecoveryCode.legacyInFlightUnverifiedBytes,
        );
        expect(loadedUnverified.isReadOnlyQuarantined, isTrue);
        expect(loadedUnverified.canAutoSubmit, isFalse);

        for (final id in [
          'draft-unbound-actor',
          'draft-legacy-row',
          'draft-unverified-bytes',
        ]) {
          final claim = await reopened.acquireDraftClaim(
            localDraftId: id,
            actorUserId: 'actor-1',
            familyId: 'fam-1',
            childId: 'child-1',
            leaseDuration: const Duration(minutes: 1),
            now: now,
          );
          expect(claim.status, isNot(DraftCasStatus.succeeded));
        }
      } finally {
        await reopened.close();
        conn1 = AppDatabase(NativeDatabase(dbFile));
        conn2 = AppDatabase(NativeDatabase(dbFile));
      }
    });
  });

  group(
    'WP2 Parity Suite: AppDatabase (SQLite) vs TestLocalDraftStore (InMemory)',
    () {
      late Directory tempDir;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('learnward_wp2_parity_');
      });

      tearDown(() {
        if (tempDir.existsSync()) {
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      });

      Future<void> runParityScenario(
        LocalDraftStore store,
        Future<LocalDraftStore> Function()? restartHook,
      ) async {
        final t0 = DateTime.utc(2026, 11, 14, 12, 0, 0);

        // 1. Strict registration preconditions
        final unboundAttempt = await store.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: _buildDraft(actorUserId: null, updatedAt: t0),
          now: t0,
        );
        expect(unboundAttempt.status, DraftCasStatus.actorMismatch);

        // 2. Successful registration & full-column CAS update without updatedAt change
        final initial = _buildDraft(
          localDraftId: 'parity-1',
          localCompressedPhotoPath: '/app/draft_evidence/p1.jpg',
          sha256Checksum: _validShaA,
          updatedAt: t0,
        );
        final created = await store.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: initial,
          now: t0,
        );
        expect(created.isSuccess, isTrue);

        final editedSameTs = created.draft!.copyWith(title: 'Edited Title');
        final updated = await store.registerOrUpdateDraftIfUnchanged(
          expected: created.draft!,
          desired: editedSameTs,
          now: t0,
        );
        expect(updated.isSuccess, isTrue);

        // Stale snapshot (still with identical updatedAt!) conflicts
        final staleAttempt = await store.registerOrUpdateDraftIfUnchanged(
          expected: created.draft!,
          desired: created.draft!.copyWith(title: 'Stale Overwrite'),
          now: t0,
        );
        expect(staleAttempt.status, DraftCasStatus.casConflict);

        // Rotating canonical snapshot or commandId during pre-dispatch CAS is forbidden
        final rotateCmdAttempt = await store.registerOrUpdateDraftIfUnchanged(
          expected: updated.draft!,
          desired: updated.draft!.copyWith(createCommandId: 'cmd-rotated'),
          now: t0,
        );
        expect(rotateCmdAttempt.status, DraftCasStatus.casConflict);

        // 3. Acquire claim -> wrong actor rejected -> mark stage -> persist serverAssessmentId & serverEvidenceId
        final wrongActorClaim = await store.acquireDraftClaim(
          localDraftId: 'parity-1',
          actorUserId: 'actor-other',
          familyId: 'fam-1',
          childId: 'child-1',
          leaseDuration: const Duration(minutes: 2),
          now: t0,
        );
        expect(wrongActorClaim.status, DraftCasStatus.actorMismatch);

        final claim = await store.acquireDraftClaim(
          localDraftId: 'parity-1',
          actorUserId: 'actor-1',
          familyId: 'fam-1',
          childId: 'child-1',
          leaseDuration: const Duration(minutes: 2),
          now: t0,
          overrideLeaseToken: 'tok-p1',
        );
        expect(claim.isSuccess, isTrue);

        final staged = await store.markDraftStageAndDispatch(
          localDraftId: 'parity-1',
          leaseToken: 'tok-p1',
          authenticatedActorId: 'actor-1',
          targetStage: DraftSubmissionStatus.uploadingEvidence,
          now: t0.add(const Duration(seconds: 1)),
        );
        expect(staged.isSuccess, isTrue);
        expect(
          staged.draft!.dispatchState,
          CommandDispatchState.possiblyDispatched,
        );

        final persistedSrvAssess = await store.persistServerAssessmentId(
          localDraftId: 'parity-1',
          leaseToken: 'tok-p1',
          authenticatedActorId: 'actor-1',
          serverAssessmentId: 'srv-assess-uuid-1',
          now: t0.add(const Duration(seconds: 2)),
        );
        expect(persistedSrvAssess.isSuccess, isTrue);

        // Trying to change serverAssessmentId later conflicts
        final conflictingSrvAssess = await store.persistServerAssessmentId(
          localDraftId: 'parity-1',
          leaseToken: 'tok-p1',
          authenticatedActorId: 'actor-1',
          serverAssessmentId: 'srv-assess-uuid-2',
          now: t0.add(const Duration(seconds: 3)),
        );
        expect(conflictingSrvAssess.status, DraftCasStatus.casConflict);

        // Persist distinct serverEvidenceId != evidenceId fenced on SHA-256 (R31-01)
        final mismatchedShaPersist = await store.persistServerEvidenceId(
          localDraftId: 'parity-1',
          leaseToken: 'tok-p1',
          authenticatedActorId: 'actor-1',
          serverEvidenceId: 'srv-evi-uuid-99',
          expectedEvidenceId: 'evi-client-1',
          expectedSha256Checksum: _validShaB,
          now: t0.add(const Duration(seconds: 4)),
        );
        expect(mismatchedShaPersist.status, DraftCasStatus.casConflict);

        final persistedSrvEvidence = await store.persistServerEvidenceId(
          localDraftId: 'parity-1',
          leaseToken: 'tok-p1',
          authenticatedActorId: 'actor-1',
          serverEvidenceId: 'srv-evi-uuid-99',
          expectedEvidenceId: 'evi-client-1',
          expectedSha256Checksum: _validShaA,
          now: t0.add(const Duration(seconds: 4)),
        );
        expect(persistedSrvEvidence.isSuccess, isTrue);
        expect(persistedSrvEvidence.draft!.serverEvidenceId, 'srv-evi-uuid-99');

        // 4. Schedule retry with secret leakage test (secrets redacted) & lease released
        final retryAt = t0.add(const Duration(seconds: 30));
        final retryScheduled = await store.scheduleDraftRetry(
          localDraftId: 'parity-1',
          leaseToken: 'tok-p1',
          authenticatedActorId: 'actor-1',
          nextAttemptAt: retryAt,
          recoveryCode: DraftRecoveryCode.retryScheduled,
          errorMessage: 'Bearer supersecret_tok https://proj.supabase.co/storage/v1/object/sign?token=abc',
          now: t0.add(const Duration(seconds: 5)),
        );
        expect(retryScheduled.isSuccess, isTrue);
        expect(retryScheduled.draft!.retryCount, 1);
        expect(retryScheduled.draft!.leaseToken, isNull);
        expect(
          retryScheduled.draft!.submissionStatus,
          DraftSubmissionStatus.failedRetryable,
        );
        expect(
          retryScheduled.draft!.lastErrorMessage,
          isNot(contains('supersecret_tok')),
        );
        expect(
          retryScheduled.draft!.lastErrorMessage,
          isNot(contains('proj.supabase.co')),
        );
        expect(
          retryScheduled.draft!.recoveryCode,
          DraftRecoveryCode.retryScheduled,
        );

        // Cannot claim before backoff elapses
        final earlyClaim = await store.acquireDraftClaim(
          localDraftId: 'parity-1',
          actorUserId: 'actor-1',
          familyId: 'fam-1',
          childId: 'child-1',
          leaseDuration: const Duration(minutes: 2),
          now: t0.add(const Duration(seconds: 10)),
        );
        expect(earlyClaim.status, DraftCasStatus.casConflict);

        // 5. Account switch pauses draft while preserving retryCount, nextAttemptAt, IDs, & snapshot
        final paused = await store.pauseMismatchedActorDraft(
          localDraftId: 'parity-1',
          familyId: 'fam-1',
          authenticatedActorId: 'parent-user-2',
          mismatchReason: 'Parent signed in',
          now: t0.add(const Duration(seconds: 15)),
        );
        expect(paused.isSuccess, isTrue);
        expect(paused.draft!.hasWaitingOriginalActorMarker, isTrue);
        expect(paused.draft!.actorUserId, 'actor-1');
        expect(paused.draft!.retryCount, 1);
        expect(paused.draft!.serverAssessmentId, 'srv-assess-uuid-1');
        expect(paused.draft!.serverEvidenceId, 'srv-evi-uuid-99');

        // Other user cannot resume
        final wrongResume = await store.resumeOriginalActorDraft(
          localDraftId: 'parity-1',
          familyId: 'fam-1',
          authenticatedActorId: 'parent-user-2',
          now: t0.add(const Duration(seconds: 20)),
        );
        expect(wrongResume.status, DraftCasStatus.actorMismatch);

        if (restartHook != null) {
          store = await restartHook();
        }

        // Original actor resumes & claims after backoff elapsed -> completes submission
        final resumed = await store.resumeOriginalActorDraft(
          localDraftId: 'parity-1',
          familyId: 'fam-1',
          authenticatedActorId: 'actor-1',
          now: retryAt,
        );
        expect(resumed.isSuccess, isTrue);
        expect(resumed.draft!.hasWaitingOriginalActorMarker, isFalse);
        expect(resumed.draft!.retryCount, 1);

        final reclaimed = await store.acquireDraftClaim(
          localDraftId: 'parity-1',
          actorUserId: 'actor-1',
          familyId: 'fam-1',
          childId: 'child-1',
          leaseDuration: const Duration(minutes: 2),
          now: retryAt,
          overrideLeaseToken: 'tok-p2',
        );
        expect(reclaimed.isSuccess, isTrue);

        final completed = await store.completeDraftSubmission(
          localDraftId: 'parity-1',
          leaseToken: 'tok-p2',
          authenticatedActorId: 'actor-1',
          serverAssessmentId: 'srv-assess-uuid-1',
          serverEvidenceId: 'srv-evi-uuid-99',
          now: retryAt.add(const Duration(seconds: 2)),
        );
        expect(completed.isSuccess, isTrue);
        expect(
          completed.draft!.dispatchState,
          CommandDispatchState.confirmedCommitted,
        );
        expect(completed.draft!.leaseToken, isNull);
        expect(completed.draft!.lastErrorMessage, isNull);
        expect(completed.draft!.serverAssessmentId, 'srv-assess-uuid-1');
        expect(completed.draft!.serverEvidenceId, 'srv-evi-uuid-99');
        expect(completed.draft!.sha256Checksum, _validShaA);
        expect(completed.draft!.canAutoSubmit, isFalse);

        // Quarantine test on separate draft preserves IDs & evidence bytes
        final qDraft = _buildDraft(
          localDraftId: 'parity-quarantine',
          localCompressedPhotoPath: '/app/draft_evidence/q.png',
          sha256Checksum: _validShaB,
          updatedAt: t0,
        );
        await store.registerOrUpdateDraftIfUnchanged(
          expected: null,
          desired: qDraft,
          now: t0,
        );
        final qClaim = await store.acquireDraftClaim(
          localDraftId: 'parity-quarantine',
          actorUserId: 'actor-1',
          familyId: 'fam-1',
          childId: 'child-1',
          leaseDuration: const Duration(minutes: 2),
          now: t0,
          overrideLeaseToken: 'tok-q1',
        );
        expect(qClaim.isSuccess, isTrue);

        final quarantined = await store.quarantineDraftOutcome(
          localDraftId: 'parity-quarantine',
          leaseToken: 'tok-q1',
          authenticatedActorId: 'actor-1',
          recoveryCode: DraftRecoveryCode.storageContentConflict,
          errorMessage:
              'Storage 409 SHA-256 mismatch at fam-1/child-1/srv-1/evi-1.jpg',
          now: t0.add(const Duration(seconds: 5)),
        );
        expect(quarantined.isSuccess, isTrue);
        expect(
          quarantined.draft!.submissionStatus,
          DraftSubmissionStatus.terminalError,
        );
        expect(quarantined.draft!.leaseToken, isNull);
        expect(
          quarantined.draft!.recoveryDispositionAt(now: t0),
          DraftRecoveryDisposition.quarantinedConflict,
        );
        expect(
          quarantined.draft!.localCompressedPhotoPath,
          '/app/draft_evidence/q.png',
        );
        expect(quarantined.draft!.createCommandId, 'cmd-create-1');
      }

      test('identical CAS workflow and security invariants across AppDatabase and TestLocalDraftStore', () async {
        final dbFile = File('${tempDir.path}/parity.sqlite');
        var db = AppDatabase(NativeDatabase(dbFile));
        try {
          await runParityScenario(db, () async {
            await db.close();
            db = AppDatabase(NativeDatabase(dbFile));
            return db;
          });
        } finally {
          await db.close();
        }

        final memStore = TestLocalDraftStore();
        await runParityScenario(memStore, null);
      });
    },
  );

  group('R33-01 / R33-02 / R33-03: Legacy Save, Raw Delete, and Unbound Actor Hardening', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_r33_hardening_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Future<void> verifyR33Suite(
      LocalDraftStore initialStore, {
      required Future<void> Function(
        LocalDraftStore store,
        LocalAssessmentDraft malformedDraft,
      )
      seedCorruptDraft,
      Future<LocalDraftStore> Function(LocalDraftStore current)? reopenStore,
    }) async {
      var store = initialStore;
      final now = DateTime.utc(2026, 11, 14, 12, 0, 0);

      // =====================================================================
      // R33-01: Unbound actor quarantine against legacy saveLocalDraft
      // =====================================================================
      final unboundNever = _buildDraft(
        localDraftId: 'r33-unbound-never',
        actorUserId: null,
        actorRole: null,
        title: 'Unbound Never Original',
        rawScore: 6.5,
        localPhotoPath: '${tempDir.path}/u1.jpg',
        dispatchState: CommandDispatchState.neverDispatched,
        submissionStatus: DraftSubmissionStatus.draft,
      );
      final unboundDispatched = _buildDraft(
        localDraftId: 'r33-unbound-disp',
        actorUserId: null,
        actorRole: null,
        title: 'Unbound Dispatched Original',
        rawScore: 7.5,
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.submittingAssessment,
      );
      final unboundLegacy = _buildDraft(
        localDraftId: 'r33-unbound-legacy',
        actorUserId: '',
        actorRole: null,
        createCommandId: null,
        submitCommandId: null,
        title: 'Unbound Legacy Original',
        rawScore: 5.5,
        dispatchState: CommandDispatchState.unknownLegacy,
        submissionStatus: DraftSubmissionStatus.draft,
      );

      await store.saveLocalDraft(unboundNever);
      await store.saveLocalDraft(unboundDispatched);
      await store.saveLocalDraft(unboundLegacy);

      for (final row in [unboundNever, unboundDispatched, unboundLegacy]) {
        // 1. Actor adoption / backfill must fail closed
        await expectLater(
          () => store.saveLocalDraft(
            row.copyWith(actorUserId: 'adopted-user-999'),
          ),
          throwsA(isA<DraftWriteConflictException>()),
        );
        // 2. Content / score / file edits without actor backfill must fail closed
        await expectLater(
          () => store.saveLocalDraft(
            row.copyWith(
              title: 'Tampered Title',
              rawScore: 10.0,
              localPhotoPath: '${tempDir.path}/tampered.jpg',
            ),
          ),
          throwsA(isA<DraftWriteConflictException>()),
        );
      }

      if (reopenStore != null) {
        store = await reopenStore(store);
      }

      final persistedUnboundNever = await store.getLocalDraft(
        'r33-unbound-never',
      );
      expect(persistedUnboundNever!.actorUserId, isNull);
      expect(persistedUnboundNever.title, 'Unbound Never Original');
      expect(persistedUnboundNever.rawScore, 6.5);
      expect(persistedUnboundNever.localPhotoPath, '${tempDir.path}/u1.jpg');
      expect(persistedUnboundNever.isReadOnlyQuarantined, isTrue);

      final persistedUnboundLegacy = await store.getLocalDraft(
        'r33-unbound-legacy',
      );
      expect(persistedUnboundLegacy!.hasUnboundActor, isTrue);
      expect(persistedUnboundLegacy.createCommandId, isNull);
      expect(persistedUnboundLegacy.submitCommandId, isNull);
      expect(persistedUnboundLegacy.title, 'Unbound Legacy Original');

      // =====================================================================
      // R33-02: Raw deleteLocalDraft blocks ALL unsafe states (including unleased/expired)
      // =====================================================================
      final unsafeFiles = <String, File>{};
      File makeEvidenceFile(String tag) {
        final f = File('${tempDir.path}/ev_$tag.jpg')
          ..writeAsBytesSync(<int>[1, 2, 3, tag.length]);
        unsafeFiles[tag] = f;
        return f;
      }

      final unsafeDeleteCases = <String, LocalAssessmentDraft>{
        'possibly_dispatched_unleased': _buildDraft(
          localDraftId: 'r33-del-possibly',
          dispatchState: CommandDispatchState.possiblyDispatched,
          submissionStatus: DraftSubmissionStatus.draft,
          localPhotoPath: makeEvidenceFile('possibly').path,
        ),
        'confirmed_committed_unleased': _buildDraft(
          localDraftId: 'r33-del-committed',
          dispatchState: CommandDispatchState.confirmedCommitted,
          submissionStatus: DraftSubmissionStatus.submittingAssessment,
          serverAssessmentId: 'srv-1',
          localPhotoPath: makeEvidenceFile('committed').path,
        ),
        'uploading_evidence_unleased': _buildDraft(
          localDraftId: 'r33-del-uploading',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.uploadingEvidence,
          localPhotoPath: makeEvidenceFile('uploading').path,
        ),
        'submitting_assessment_unleased': _buildDraft(
          localDraftId: 'r33-del-submitting',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.submittingAssessment,
        ),
        'failed_retryable_unleased': _buildDraft(
          localDraftId: 'r33-del-retryable',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.failedRetryable,
        ),
        'terminal_error_unleased': _buildDraft(
          localDraftId: 'r33-del-terminal',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.terminalError,
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.terminalPolicyDenial,
          ),
        ),
        'server_assessment_id_unleased': _buildDraft(
          localDraftId: 'r33-del-srv-assess',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.draft,
          serverAssessmentId: 'srv-assess-persisted',
        ),
        'server_evidence_id_unleased': _buildDraft(
          localDraftId: 'r33-del-srv-ev',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.draft,
          serverEvidenceId: 'srv-ev-persisted',
        ),
        'frozen_snapshot_unleased': _buildDraft(
          localDraftId: 'r33-del-frozen-snap',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.draft,
          localCompressedPhotoPath: makeEvidenceFile('frozen').path,
          sha256Checksum: _validShaA,
        ),
        'unbound_actor_unleased': unboundNever,
        'unknown_legacy_unleased': _buildDraft(
          localDraftId: 'r33-del-legacy',
          dispatchState: CommandDispatchState.unknownLegacy,
          submissionStatus: DraftSubmissionStatus.draft,
        ),
        'recovery_marker_unleased': _buildDraft(
          localDraftId: 'r33-del-marker',
          dispatchState: CommandDispatchState.neverDispatched,
          submissionStatus: DraftSubmissionStatus.draft,
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.waitingOriginalActor,
            'User switched',
          ),
        ),
        'active_lease': _buildDraft(
          localDraftId: 'r33-del-active-lease',
          leaseToken: 'tok-active-1',
          leaseExpiresAt: now.add(const Duration(minutes: 5)),
        ),
        'expired_lease': _buildDraft(
          localDraftId: 'r33-del-expired-lease',
          leaseToken: 'tok-expired-1',
          leaseExpiresAt: now.subtract(const Duration(minutes: 5)),
        ),
        'malformed_lease_token_only': _buildDraft(
          localDraftId: 'r33-del-half-token',
          leaseToken: 'tok-half-1',
          leaseExpiresAt: null,
        ),
        'malformed_lease_expiry_only': _buildDraft(
          localDraftId: 'r33-del-half-exp',
          leaseToken: null,
          leaseExpiresAt: now.add(const Duration(minutes: 5)),
        ),
      };

      for (final entry in unsafeDeleteCases.entries) {
        final draft = entry.value;
        if (draft.localDraftId != unboundNever.localDraftId) {
          if (draft.hasMalformedLease) {
            await seedCorruptDraft(store, draft);
          } else {
            await store.saveLocalDraft(draft);
          }
        }
        await expectLater(
          () => store.deleteLocalDraft(draft.localDraftId),
          throwsA(isA<DraftWriteConflictException>()),
          reason: 'deleteLocalDraft must block ${entry.key}',
        );
        final stillPresent = await store.getLocalDraft(draft.localDraftId);
        expect(
          stillPresent,
          isNotNull,
          reason: 'Row for ${entry.key} must remain preserved',
        );
      }

      // Physical evidence files for blocked drafts must remain on disk
      for (final f in unsafeFiles.values) {
        expect(f.existsSync(), isTrue);
      }

      // Unbound actor row also blocks deleteDraftSafely
      final unboundSafeDel = await store.deleteDraftSafely(
        localDraftId: unboundNever.localDraftId,
        expectedDraft: persistedUnboundNever,
        now: now,
      );
      expect(unboundSafeDel.status, DraftDeletionStatus.blockedUnsafeState);

      // Positive control: clean bound-actor neverDispatched unleased draft deletes cleanly
      // while preserving its physical file on disk
      final cleanFile = makeEvidenceFile('clean');
      final cleanDraft = _buildDraft(
        localDraftId: 'r33-del-clean-ok',
        localPhotoPath: cleanFile.path,
        actorUserId: 'actor-1',
      );
      await store.saveLocalDraft(cleanDraft);
      await store.deleteLocalDraft('r33-del-clean-ok');
      expect(await store.getLocalDraft('r33-del-clean-ok'), isNull);
      expect(cleanFile.existsSync(), isTrue);

      // =====================================================================
      // R33-03: saveLocalDraft blocks content/command/evidence/actor edits once dispatched or non-draft
      // =====================================================================
      final inFlightNoSnap = _buildDraft(
        localDraftId: 'r33-inflight-nosnap',
        actorUserId: 'actor-1',
        createCommandId: 'cmd-orig-create',
        submitCommandId: 'cmd-orig-submit',
        evidenceId: 'ev-orig-1',
        title: 'Original In-Flight Title',
        rawScore: 8.5,
        localPhotoPath: '${tempDir.path}/inflight_raw.jpg',
        localCompressedPhotoPath: null,
        sha256Checksum: null,
        serverEvidenceId: null,
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.submittingAssessment,
      );
      await store.saveLocalDraft(inFlightNoSnap);

      final forbiddenEdits = <String, LocalAssessmentDraft>{
        'title': inFlightNoSnap.copyWith(title: 'Autosave Mutated Title'),
        'rawScore': inFlightNoSnap.copyWith(rawScore: 10.0),
        'subject': inFlightNoSnap.copyWith(
          subject: 'Science',
          subjectKey: SubjectKey.science,
        ),
        'commandIds': inFlightNoSnap.copyWith(
          createCommandId: 'cmd-rot-create',
          submitCommandId: 'cmd-rot-submit',
        ),
        'evidenceRef': inFlightNoSnap.copyWith(
          evidenceId: 'ev-mutated',
          localPhotoPath: '${tempDir.path}/other.jpg',
        ),
        'actorSwap': inFlightNoSnap.copyWith(actorUserId: 'actor-2'),
        'actorClear': inFlightNoSnap.copyWith(actorUserId: null),
        'recoveryMarker': inFlightNoSnap.copyWith(
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.retryScheduled,
          ),
        ),
      };
      for (final editEntry in forbiddenEdits.entries) {
        await expectLater(
          () => store.saveLocalDraft(editEntry.value),
          throwsA(isA<DraftWriteConflictException>()),
          reason:
              'saveLocalDraft must reject ${editEntry.key} on possiblyDispatched row',
        );
      }

      // Legacy saveLocalDraft also cannot forge dispatch/lease/server IDs on a clean draft
      final editable = _buildDraft(
        localDraftId: 'r33-editable-guard',
        actorUserId: 'actor-1',
        title: 'Initial Editable',
      );
      await store.saveLocalDraft(editable);
      for (final forged in <LocalAssessmentDraft>[
        editable.copyWith(
          dispatchState: CommandDispatchState.possiblyDispatched,
        ),
        editable.copyWith(
          submissionStatus: DraftSubmissionStatus.submittingAssessment,
        ),
        editable.copyWith(serverAssessmentId: 'forged-srv-1'),
        editable.copyWith(actorUserId: null),
        editable.copyWith(actorUserId: 'actor-2'),
      ]) {
        await expectLater(
          () => store.saveLocalDraft(forged),
          throwsA(isA<DraftWriteConflictException>()),
        );
      }

      if (reopenStore != null) {
        store = await reopenStore(store);
      }

      final persistedInFlight = await store.getLocalDraft(
        'r33-inflight-nosnap',
      );
      expect(persistedInFlight, isNotNull);
      expect(persistedInFlight!.title, 'Original In-Flight Title');
      expect(persistedInFlight.rawScore, 8.5);
      expect(persistedInFlight.subject, 'Math');
      expect(persistedInFlight.subjectKey, SubjectKey.math);
      expect(persistedInFlight.createCommandId, 'cmd-orig-create');
      expect(persistedInFlight.submitCommandId, 'cmd-orig-submit');
      expect(persistedInFlight.evidenceId, 'ev-orig-1');
      expect(persistedInFlight.actorUserId, 'actor-1');
      expect(
        persistedInFlight.dispatchState,
        CommandDispatchState.possiblyDispatched,
      );
    }

    test(
      'SQLite AppDatabase enforces R33-01, R33-02, R33-03 across restart',
      () async {
        final dbFile = File('${tempDir.path}/r33_sqlite.sqlite');
        var db = AppDatabase(NativeDatabase(dbFile));
        try {
          await verifyR33Suite(
            db,
            seedCorruptDraft: (store, malformed) async {
              final targetDb = store as AppDatabase;
              await targetDb.saveLocalDraft(
                malformed.copyWith(leaseToken: null, leaseExpiresAt: null),
              );
              await (targetDb.update(targetDb.localAssessmentDrafts)..where(
                    (t) => t.localDraftId.equals(malformed.localDraftId),
                  ))
                  .write(
                    LocalAssessmentDraftsCompanion(
                      leaseToken: Value(malformed.leaseToken),
                      leaseExpiresAt: Value(malformed.leaseExpiresAt),
                    ),
                  );
            },
            reopenStore: (current) async {
              await (current as AppDatabase).close();
              db = AppDatabase(NativeDatabase(dbFile));
              return db;
            },
          );
        } finally {
          await db.close();
        }
      },
    );

    test('TestLocalDraftStore mirrors R33-01, R33-02, R33-03 invariants identically', () async {
      await verifyR33Suite(
        TestLocalDraftStore(),
        seedCorruptDraft: (store, malformed) async {
          (store as TestLocalDraftStore).seedRawDraft(malformed);
        },
      );
    });
  });
}
