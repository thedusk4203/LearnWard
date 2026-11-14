import 'dart:typed_data';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

LocalAssessmentDraft _buildDraft({
  String localDraftId = 'draft-wp2-1',
  String familyId = 'fam-1',
  String childId = 'child-1',
  String? actorUserId = 'actor-1',
  String? createCommandId = 'cmd-create-1',
  String? submitCommandId = 'cmd-submit-1',
  String? evidenceId = 'evi-1',
  String? serverAssessmentId,
  String? serverEvidenceId,
  String? localPhotoPath,
  String? localCompressedPhotoPath,
  String? sha256Checksum,
  DraftSubmissionStatus submissionStatus = DraftSubmissionStatus.draft,
  CommandDispatchState dispatchState = CommandDispatchState.neverDispatched,
  int retryCount = 0,
  String? lastErrorMessage,
  DateTime? nextAttemptAt,
  String? leaseToken,
  DateTime? leaseExpiresAt,
}) {
  return LocalAssessmentDraft(
    localDraftId: localDraftId,
    familyId: familyId,
    childId: childId,
    actorUserId: actorUserId,
    actorRole: actorUserId == null ? null : 'child',
    createCommandId: createCommandId,
    submitCommandId: submitCommandId,
    evidenceId: evidenceId,
    serverAssessmentId: serverAssessmentId,
    serverEvidenceId: serverEvidenceId,
    subjectKey: SubjectKey.math,
    subject: 'Math',
    title: 'Fractions Quiz',
    assessmentType: 'quiz',
    difficulty: 'medium',
    rawScore: 8,
    maxScore: 10,
    localPhotoPath: localPhotoPath,
    localCompressedPhotoPath: localCompressedPhotoPath,
    sha256Checksum: sha256Checksum,
    occurredAt: DateTime.utc(2026, 11, 14, 8, 0),
    updatedAt: DateTime.utc(2026, 11, 14, 8, 5),
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
  final validSha = 'a' * 64;

  group('WP2 DraftSubmissionStatus & Recovery Code Parsing', () {
    test('tryFromString parses known values and returns null for unknown', () {
      for (final status in DraftSubmissionStatus.values) {
        expect(DraftSubmissionStatus.tryFromString(status.wireValue), status);
        expect(DraftSubmissionStatus.fromString(status.wireValue), status);
      }
      expect(DraftSubmissionStatus.tryFromString('future_status_v9'), isNull);
      expect(DraftSubmissionStatus.tryFromString(''), isNull);
    });

    test('fromString fails closed to terminalError on unknown wire status', () {
      expect(
        DraftSubmissionStatus.fromString('corrupted_v9_wire'),
        DraftSubmissionStatus.terminalError,
      );
      expect(
        DraftSubmissionStatus.fromString(''),
        DraftSubmissionStatus.terminalError,
      );
    });

    test('DraftRecoveryCode format and parse normalize LW4B1 markers', () {
      final unknownFormatted = DraftRecoveryCode.format(
        DraftRecoveryCode.unknownWireStatus,
        'future_v9',
      );
      expect(unknownFormatted, 'LW4B1:UNKNOWN_WIRE_STATUS:future_v9');
      expect(
        DraftRecoveryCode.parseCode(unknownFormatted),
        DraftRecoveryCode.unknownWireStatus,
      );

      final retryFormatted = DraftRecoveryCode.format(
        DraftRecoveryCode.retryScheduled,
        'Temporary timeout',
      );
      expect(retryFormatted, 'LW4B1:RETRY_SCHEDULED: Temporary timeout');
      expect(
        DraftRecoveryCode.parseCode(retryFormatted),
        DraftRecoveryCode.retryScheduled,
      );
      expect(DraftRecoveryCode.parseCode('Plain non-prefixed error'), isNull);
    });
  });

  group('WP2 DraftRecoveryDisposition, Quarantine & Safety Matrix', () {
    final now = DateTime.utc(2026, 11, 14, 10, 0);

    test('editable bound draft allows auto-submit and safe deletion', () {
      final draft = _buildDraft();
      expect(
        draft.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.editableDraft,
      );
      expect(draft.isReadOnlyQuarantined, isFalse);
      expect(draft.canAutoSubmit, isTrue);
      expect(draft.isUnsafeToDelete(now: now), isFalse);
    });

    test('active lease vs expired lease in-flight dispositions', () {
      final activeLeased = _buildDraft(
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.uploadingEvidence,
        localCompressedPhotoPath: '/app/draft_evidence/c.jpg',
        sha256Checksum: validSha,
        leaseToken: 'lease-1',
        leaseExpiresAt: now.add(const Duration(minutes: 2)),
      );
      expect(
        activeLeased.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.inProgressSameSession,
      );
      expect(activeLeased.isUnsafeToDelete(now: now), isTrue);
      expect(activeLeased.canAutoSubmit, isTrue);

      final expiredInFlight = activeLeased.copyWith(
        leaseExpiresAt: now.subtract(const Duration(seconds: 1)),
      );
      expect(
        expiredInFlight.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.verificationPending,
      );
      expect(expiredInFlight.isUnsafeToDelete(now: now), isTrue);
      expect(expiredInFlight.canAutoSubmit, isTrue);
    });

    test(
      'retryScheduled disposition preserves auto-submit and blocks deletion',
      () {
        final retryDraft = _buildDraft(
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          dispatchState: CommandDispatchState.possiblyDispatched,
          localCompressedPhotoPath: '/app/draft_evidence/c.jpg',
          sha256Checksum: validSha,
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.retryScheduled,
            'Socket closed',
          ),
          nextAttemptAt: now.add(const Duration(seconds: 30)),
        );
        expect(
          retryDraft.recoveryDispositionAt(now: now),
          DraftRecoveryDisposition.retryScheduled,
        );
        expect(retryDraft.isReadOnlyQuarantined, isFalse);
        expect(retryDraft.canAutoSubmit, isTrue);
        expect(retryDraft.isUnsafeToDelete(now: now), isTrue);
      },
    );

    test('waitingOriginalActor blocks auto-submit and deletion while remaining non-quarantined', () {
      final paused = _buildDraft(
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.submittingAssessment,
        localCompressedPhotoPath: '/app/draft_evidence/c.jpg',
        sha256Checksum: validSha,
        lastErrorMessage: DraftRecoveryCode.format(
          DraftRecoveryCode.waitingOriginalActor,
          'Session switched to adult',
        ),
      );
      expect(
        paused.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.waitingOriginalActor,
      );
      expect(paused.isReadOnlyQuarantined, isFalse);
      expect(paused.canAutoSubmit, isFalse);
      expect(paused.isUnsafeToDelete(now: now), isTrue);
    });

    test('fail-closed read-only quarantine matrix covers all unverified/corrupt states', () {
      final unbound = _buildDraft(actorUserId: null);
      expect(
        unbound.derivedQuarantineCode,
        DraftRecoveryCode.unboundActorProvenance,
      );
      expect(
        unbound.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.quarantinedUnknownOutcome,
      );
      expect(unbound.isReadOnlyQuarantined, isTrue);
      expect(unbound.canAutoSubmit, isFalse);

      final legacy = _buildDraft(
        dispatchState: CommandDispatchState.unknownLegacy,
        createCommandId: null,
        submitCommandId: null,
      );
      expect(legacy.derivedQuarantineCode, DraftRecoveryCode.legacyUnknown);
      expect(
        legacy.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.quarantinedLegacyUnknown,
      );
      expect(legacy.canAutoSubmit, isFalse);
      expect(legacy.isUnsafeToDelete(now: now), isTrue);

      final unverifiedInFlight = _buildDraft(
        dispatchState: CommandDispatchState.possiblyDispatched,
        submissionStatus: DraftSubmissionStatus.uploadingEvidence,
        evidenceId: 'evi-unverified',
        localPhotoPath: '/mutable/cam.jpg',
      );
      expect(
        unverifiedInFlight.derivedQuarantineCode,
        DraftRecoveryCode.legacyInFlightUnverifiedBytes,
      );
      expect(
        unverifiedInFlight.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.quarantinedLegacyUnknown,
      );
      expect(unverifiedInFlight.isReadOnlyQuarantined, isTrue);
      expect(unverifiedInFlight.canAutoSubmit, isFalse);
      expect(unverifiedInFlight.isUnsafeToDelete(now: now), isTrue);

      final halfLeased = _buildDraft(
        leaseToken: 'orphan-token',
        leaseExpiresAt: null,
      );
      expect(
        halfLeased.derivedQuarantineCode,
        DraftRecoveryCode.malformedLeaseMetadata,
      );
      expect(halfLeased.hasMalformedLease, isTrue);
      expect(halfLeased.canAutoSubmit, isFalse);
      expect(halfLeased.isUnsafeToDelete(now: now), isTrue);

      final missingSnapshot = _buildDraft(
        submissionStatus: DraftSubmissionStatus.terminalError,
        lastErrorMessage: DraftRecoveryCode.format(
          DraftRecoveryCode.localSnapshotMissing,
        ),
      );
      expect(
        missingSnapshot.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.quarantinedMissingSnapshot,
      );

      final corruptedSnapshot = _buildDraft(
        submissionStatus: DraftSubmissionStatus.terminalError,
        lastErrorMessage: DraftRecoveryCode.format(
          DraftRecoveryCode.localSnapshotCorrupted,
        ),
      );
      expect(
        corruptedSnapshot.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.quarantinedCorruptedSnapshot,
      );

      final contentConflict = _buildDraft(
        dispatchState: CommandDispatchState.confirmedCommitted,
        submissionStatus: DraftSubmissionStatus.terminalError,
        lastErrorMessage: DraftRecoveryCode.format(
          DraftRecoveryCode.storageContentConflict,
        ),
      );
      // Fail-closed conflict takes precedence over confirmedCommitted
      expect(
        contentConflict.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.quarantinedConflict,
      );
      expect(contentConflict.canAutoSubmit, isFalse);

      final policyDenial = _buildDraft(
        submissionStatus: DraftSubmissionStatus.terminalError,
        lastErrorMessage: DraftRecoveryCode.format(
          DraftRecoveryCode.terminalPolicyDenial,
          'Child archived on server',
        ),
      );
      expect(
        policyDenial.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.terminalPolicyDenial,
      );
      expect(policyDenial.isReadOnlyQuarantined, isFalse);
      expect(policyDenial.canAutoSubmit, isFalse);
      expect(policyDenial.isUnsafeToDelete(now: now), isTrue);

      final committed = _buildDraft(
        dispatchState: CommandDispatchState.confirmedCommitted,
        submissionStatus: DraftSubmissionStatus.submittingAssessment,
        serverAssessmentId: 'srv-1',
      );
      expect(
        committed.recoveryDispositionAt(now: now),
        DraftRecoveryDisposition.confirmedSubmitted,
      );
      expect(committed.canAutoSubmit, isFalse);
      expect(committed.isUnsafeToDelete(now: now), isTrue);
    });
  });

  group('WP2 Canonical Evidence Byte Inspection & Verification', () {
    test('detects JPEG and PNG purely by magic bytes and computes lowercase SHA-256', () {
      final jpegBytes = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
      final inspectedJpg = inspectAndValidateEvidenceBytes(jpegBytes);
      expect(inspectedJpg.mediaType, 'image/jpeg');
      expect(inspectedJpg.fileExtension, 'jpg');
      expect(inspectedJpg.byteLength, jpegBytes.length);
      expect(isValidSha256Hex(inspectedJpg.sha256Checksum), isTrue);

      final pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01];
      final inspectedPng = inspectAndValidateEvidenceBytes(pngBytes);
      expect(inspectedPng.mediaType, 'image/png');
      expect(inspectedPng.fileExtension, 'png');
      expect(inspectedPng.byteLength, pngBytes.length);
      expect(isValidSha256Hex(inspectedPng.sha256Checksum), isTrue);
    });

    test(
      'creates defensive immutable copies preventing caller buffer mutation',
      () {
        final mutableSource = Uint8List.fromList([
          0xFF,
          0xD8,
          0xFF,
          0xAA,
          0xBB,
        ]);
        final verified = VerifiedCanonicalEvidence(
          snapshot: CanonicalEvidenceSnapshot(
            localDraftId: 'd1',
            filePath: '/app/draft_evidence/d1.jpg',
            mediaType: 'image/jpeg',
            fileExtension: 'jpg',
            byteLength: mutableSource.length,
            sha256Checksum: computeSha256Hex(mutableSource),
            frozenAt: DateTime.utc(2026, 11, 14),
          ),
          bytes: mutableSource,
        );

        mutableSource[3] = 0x00;
        expect(verified.bytes[3], 0xAA);
        expect(computeSha256Hex(verified.bytes), verified.sha256Checksum);
      },
    );

    test('rejects empty, oversized, and non-JPEG/PNG disguised payloads', () {
      expect(
        () => inspectAndValidateEvidenceBytes(const []),
        throwsA(
          isA<CanonicalEvidenceValidationException>().having(
            (e) => e.code,
            'code',
            CanonicalEvidenceValidationCode.emptyBytes,
          ),
        ),
      );

      final oversized =
          Uint8List(AssessmentEvidenceStorage.maxFileSizeBytes + 1)
            ..[0] = 0xFF
            ..[1] = 0xD8
            ..[2] = 0xFF;
      expect(
        () => inspectAndValidateEvidenceBytes(oversized),
        throwsA(
          isA<CanonicalEvidenceValidationException>().having(
            (e) => e.code,
            'code',
            CanonicalEvidenceValidationCode.oversizedBytes,
          ),
        ),
      );

      // Disguised PDF / WEBP / random bytes
      for (final bad in [
        '%PDF-1.7'.codeUnits,
        [0x47, 0x49, 0x46, 0x38, 0x39, 0x61],
        [0xFF, 0xD8],
        [1, 2, 3, 4],
      ]) {
        expect(
          () => inspectAndValidateEvidenceBytes(bad),
          throwsA(
            isA<CanonicalEvidenceValidationException>().having(
              (e) => e.code,
              'code',
              CanonicalEvidenceValidationCode.unsupportedMagicBytes,
            ),
          ),
        );
      }
    });

    test('verifyCanonicalEvidenceBytes rejects digest, length, and mediaType mismatches', () {
      final bytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x22];
      final inspected = inspectAndValidateEvidenceBytes(bytes);

      expect(
        () => verifyCanonicalEvidenceBytes(
          bytes: bytes,
          expectedSha256: 'b' * 64,
        ),
        throwsA(
          isA<CanonicalEvidenceValidationException>().having(
            (e) => e.code,
            'code',
            CanonicalEvidenceValidationCode.sha256Mismatch,
          ),
        ),
      );
      expect(
        () => verifyCanonicalEvidenceBytes(
          bytes: bytes,
          expectedSha256: inspected.sha256Checksum,
          expectedByteLength: inspected.byteLength + 1,
        ),
        throwsA(
          isA<CanonicalEvidenceValidationException>().having(
            (e) => e.code,
            'code',
            CanonicalEvidenceValidationCode.lengthMismatch,
          ),
        ),
      );
      expect(
        () => verifyCanonicalEvidenceBytes(
          bytes: bytes,
          expectedSha256: inspected.sha256Checksum,
          expectedMediaType: 'image/jpeg',
        ),
        throwsA(
          isA<CanonicalEvidenceValidationException>().having(
            (e) => e.code,
            'code',
            CanonicalEvidenceValidationCode.mediaTypeMismatch,
          ),
        ),
      );
    });
  });
}
