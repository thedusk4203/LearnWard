import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/auth_session_port.dart';
import '../ports/canonical_evidence_snapshot.dart';
import '../ports/clock.dart';
import '../ports/command_lifecycle_states.dart';
import '../ports/draft_store_rules.dart';
import '../ports/local_draft_store.dart';
import 'upload_assessment_evidence.dart';

/// Stages of durable local draft CAS orchestration within [SubmitAssessmentDraft].
enum DraftCasFailureStage {
  registerPreDispatchDraft,
  acquireLease,
  markDispatchStage,
  persistServerAssessmentId,
  persistServerEvidenceId,
  markSubmittingStage,
  completeSubmission,
  releaseDraftClaim,
}

/// Optional observer invoked when releasing an uncompleted CAS lease fails.
typedef LeaseReleaseFailureCallback = void Function({
  required String localDraftId,
  DraftCasStatus? status,
  Object? error,
});

/// Thrown when durable local draft journaling is missing before submission (R33-06).
final class MissingLocalDraftJournalException implements Exception {
  const MissingLocalDraftJournalException({
    required this.reason,
    this.localDraftId,
  });

  final String? localDraftId;
  final String reason;

  @override
  String toString() => 'MissingLocalDraftJournalException: $reason';
}

/// Thrown when an evidence-bearing draft lacks a verified canonical snapshot (R33-04).
final class MissingCanonicalEvidenceSnapshotException implements Exception {
  const MissingCanonicalEvidenceSnapshotException({
    required this.localDraftId,
    required this.message,
  });

  final String localDraftId;
  final String message;

  @override
  String toString() => 'MissingCanonicalEvidenceSnapshotException: $message';
}

/// Thrown when a leased CAS transition or durable local write fails mid-flight (R33-05).
///
/// Intentionally omits raw underlying causes/paths in [toString] (R32-07).
final class DraftSubmissionCasException implements Exception {
  const DraftSubmissionCasException({
    required this.stage,
    required this.localDraftId,
    required this.message,
    this.casStatus,
    this.serverAssessmentId,
    this.serverEvidenceId,
    this.cause,
  });

  final DraftCasFailureStage stage;
  final String localDraftId;
  final DraftCasStatus? casStatus;
  final String? serverAssessmentId;
  final String? serverEvidenceId;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'DraftSubmissionCasException(${stage.name}, '
      'status=${casStatus?.name ?? 'storageError'}): $message';
}

/// Thrown when remote `submitAssessment` succeeded, but persisting the local
/// `confirmed_committed` tombstone failed (R33-05).
///
/// The server assessment is committed and the local draft stays in
/// `possibly_dispatched` / `verificationPending` for safe reconciliation rather
/// than reporting false local completion or deleting/rotating IDs.
final class AssessmentReconciliationPendingException implements Exception {
  const AssessmentReconciliationPendingException({
    required this.submittedAssessment,
    required this.localDraftId,
    required this.message,
    this.serverEvidenceId,
    this.casStatus,
    this.cause,
  });

  final Assessment submittedAssessment;
  final String localDraftId;
  final String? serverEvidenceId;
  final DraftCasStatus? casStatus;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'AssessmentReconciliationPendingException('
      'status=${casStatus?.name ?? 'storageError'}): $message';
}

/// Application use case coordinating the complete assessment submission workflow:
/// 1. Require and validate a durable local draft journal row (`localDraftStore` / `localDraftId`, R33-06),
///    failing closed on quarantined, unbound-actor, committed, scoped, or mismatched drafts
/// 2. Verify active authenticated session via [AuthSessionPort] (R32-06) and match bound draft actor
/// 3. Verify any attached evidence has a valid, durably bound canonical snapshot BEFORE dispatch (R33-04)
/// 4. Acquire a CAS lease and transition the local draft via CAS (R33-01..03), revalidate session before `createDraft` (R32-09),
///    and create or ensure server draft (idempotent via `createCommandId`)
/// 5. Persist `serverAssessmentId` via leased CAS; abort before upload/submit on CAS or storage failure (R33-05)
/// 6. Upload and register evidence (I04), persist `serverEvidenceId` via CAS, and advance stage to `submittingAssessment`
/// 7. Revalidate session before submitting assessment for review (idempotent via `submitCommandId`)
/// 8. Complete local draft as `confirmedCommitted` tombstone (I14), or throw [AssessmentReconciliationPendingException]
///    if local completion fails after server submit, releasing uncompleted leases in `finally` without masking errors.
final class SubmitAssessmentDraft {
  const SubmitAssessmentDraft({
    required this.repository,
    required this.storage,
    required this.authSessionPort,
    required LocalDraftStore this.localDraftStore,
    this.canonicalSnapshotStore,
    this.clock = const SystemClock(),
    this.onLeaseReleaseFailure,
  });

  /// Explicit isolated constructor for unit tests exercising repository/storage
  /// behavior without a local draft journal store.
  const SubmitAssessmentDraft.unjournaledForTesting({
    required this.repository,
    required this.storage,
    required this.authSessionPort,
    this.canonicalSnapshotStore,
    this.clock = const SystemClock(),
    this.onLeaseReleaseFailure,
  }) : localDraftStore = null;

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;
  final AuthSessionPort authSessionPort;
  final LocalDraftStore? localDraftStore;
  final CanonicalEvidenceSnapshotStore? canonicalSnapshotStore;
  final Clock clock;
  final LeaseReleaseFailureCallback? onLeaseReleaseFailure;

  Future<Assessment> call({
    required String createCommandId,
    required String submitCommandId,
    required FamilyId familyId,
    required ChildId childId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    EntryContext entryContext = EntryContext.sharedChild,
    List<int>? evidenceBytes,
    String? evidenceMediaType,
    EvidenceId? evidenceId,
    String? localDraftId,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    final normalizedSubject = normalizeAssessmentSubject(subject);
    final normalizedTitle = normalizeAssessmentTitle(title);
    final normalizedOccurredAt = occurredAt != null
        ? normalizeAssessmentOccurredAt(occurredAt)
        : null;
    if (normalizedSubject.isEmpty || normalizedTitle.isEmpty) {
      throw const InvalidAssessmentException(
        'Assessment subject and title must not be empty.',
      );
    }

    // 0. Fail closed on missing or unsafe local draft journal BEFORE auth/network RPCs (R33-06).
    LocalAssessmentDraft? existingLocal;
    if (localDraftStore == null) {
      if (localDraftId != null) {
        throw MissingLocalDraftJournalException(
          localDraftId: localDraftId,
          reason:
              'Cannot submit persisted draft "$localDraftId" without a configured LocalDraftStore.',
        );
      }
    } else {
      if (localDraftId == null || localDraftId.trim().isEmpty) {
        throw const MissingLocalDraftJournalException(
          reason: 'Cannot submit assessment without a durable localDraftId journal reference.',
        );
      }
      existingLocal = await localDraftStore!.getLocalDraft(localDraftId);
      if (existingLocal == null) {
        throw MissingLocalDraftJournalException(
          localDraftId: localDraftId,
          reason:
              'Required local draft journal row "$localDraftId" was not found.',
        );
      }
      if (existingLocal.isLegacyUnknown) {
        throw StateError(
          'Cannot submit quarantined legacy assessment draft (id: $localDraftId). '
          'Draft is in unknown_legacy dispatch state and requires reconciliation before submission.',
        );
      }
      if (existingLocal.hasUnboundActor) {
        throw StateError(
          'Cannot submit quarantined assessment draft (id: $localDraftId) without bound original actor provenance.',
        );
      }
      if (existingLocal.hasMalformedLease ||
          existingLocal.isReadOnlyQuarantined ||
          existingLocal.hasWaitingOriginalActorMarker ||
          existingLocal.submissionStatus ==
              DraftSubmissionStatus.terminalError ||
          (existingLocal.hasRecoveryMarker &&
              existingLocal.recoveryCode != DraftRecoveryCode.retryScheduled)) {
        throw StateError(
          'Cannot submit quarantined or paused assessment draft (id: $localDraftId).',
        );
      }
      if (existingLocal.dispatchState ==
          CommandDispatchState.confirmedCommitted) {
        throw StateError(
          'Cannot submit already confirmed_committed assessment draft (id: $localDraftId).',
        );
      }
      if (existingLocal.familyId != familyId.value ||
          existingLocal.childId != childId.value) {
        throw StateError(
          'Cannot submit assessment draft (id: $localDraftId) across mismatched family or child scope.',
        );
      }
      if (existingLocal.dispatchState ==
              CommandDispatchState.possiblyDispatched &&
          ((existingLocal.createCommandId != null &&
                  existingLocal.createCommandId != createCommandId) ||
              (existingLocal.submitCommandId != null &&
                  existingLocal.submitCommandId != submitCommandId))) {
        throw StateError(
          'Cannot submit possibly_dispatched assessment draft (id: $localDraftId) with mismatched command IDs.',
        );
      }
    }

    // 1. Authoritative session check before local dispatch state change or remote RPC
    final initialContext = await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: '',
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      stage: 'assessment submission preflight',
    );
    if (existingLocal != null &&
        existingLocal.actorUserId != initialContext.userId) {
      throw EvidenceStorageAuthException(
        const AuthFailureOutcome(
          storagePath: '',
          reason: 'Authenticated actor does not match the original local draft author.',
        ),
      );
    }

    // 2. Validate evidence and verify durable canonical snapshot BEFORE lease/dispatch (R33-04)
    List<int>? resolvedBytes;
    String? resolvedMediaType;
    EvidenceId? resolvedEvidenceId;
    String? resolvedSha256;
    String? verifiedCanonicalPath;

    if (existingLocal == null) {
      if (evidenceBytes != null) {
        if (evidenceMediaType == null || evidenceId == null) {
          throw const InvalidAssessmentException(
            'Evidence metadata is incomplete for attached evidence bytes.',
          );
        }
        validateEvidenceUploadPayload(
          bytes: evidenceBytes,
          mediaType: evidenceMediaType,
        );
        resolvedBytes = evidenceBytes;
        resolvedMediaType = evidenceMediaType;
        resolvedEvidenceId = evidenceId;
      } else if (evidenceMediaType != null || evidenceId != null) {
        throw const InvalidAssessmentException(
          'Evidence metadata provided without attached evidence bytes.',
        );
      }
    } else {
      final hasLocalEvidenceRef =
          existingLocal.hasVerifiedEvidenceSnapshot ||
          (existingLocal.evidenceId?.isNotEmpty ?? false) ||
          (existingLocal.localPhotoPath?.isNotEmpty ?? false) ||
          (existingLocal.localCompressedPhotoPath?.isNotEmpty ?? false) ||
          (existingLocal.sha256Checksum?.isNotEmpty ?? false);
      final hasInputEvidence =
          evidenceBytes != null ||
          evidenceMediaType != null ||
          evidenceId != null;

      if (hasLocalEvidenceRef || hasInputEvidence) {
        if (evidenceBytes != null) {
          if (evidenceMediaType == null) {
            throw const InvalidAssessmentException(
              'Evidence metadata is incomplete for attached evidence bytes.',
            );
          }
          validateEvidenceUploadPayload(
            bytes: evidenceBytes,
            mediaType: evidenceMediaType,
          );
        }

        if (!existingLocal.hasVerifiedEvidenceSnapshot) {
          throw MissingCanonicalEvidenceSnapshotException(
            localDraftId: existingLocal.localDraftId,
            message: 'Evidence-bearing draft requires a durably frozen canonical snapshot before network dispatch.',
          );
        }

        final boundEvidenceId = existingLocal.evidenceId!;
        if (evidenceId == null || evidenceId.value != boundEvidenceId) {
          throw DraftSubmissionCasException(
            stage: DraftCasFailureStage.acquireLease,
            localDraftId: existingLocal.localDraftId,
            casStatus: DraftCasStatus.casConflict,
            serverAssessmentId: existingLocal.serverAssessmentId,
            serverEvidenceId: existingLocal.serverEvidenceId,
            message: 'Attached evidenceId is required and must match the bound canonical draft evidenceId.',
          );
        }

        if (canonicalSnapshotStore != null) {
          final verifiedSnapshot = await canonicalSnapshotStore!
              .readVerifiedCanonicalSnapshot(draft: existingLocal);
          if (evidenceBytes != null) {
            final callerDigest = computeSha256Hex(evidenceBytes);
            if (evidenceBytes.length != verifiedSnapshot.byteLength ||
                callerDigest != verifiedSnapshot.sha256Checksum) {
              throw const CanonicalEvidenceValidationException(
                CanonicalEvidenceValidationCode.sha256Mismatch,
                'Attached evidence bytes do not match the canonical snapshot digest.',
              );
            }
            if (evidenceMediaType != null &&
                evidenceMediaType != verifiedSnapshot.mediaType) {
              throw const CanonicalEvidenceValidationException(
                CanonicalEvidenceValidationCode.mediaTypeMismatch,
                'Attached evidence media type does not match the canonical snapshot format.',
              );
            }
          }
          resolvedBytes = verifiedSnapshot.bytes;
          resolvedMediaType = verifiedSnapshot.mediaType;
          resolvedSha256 = verifiedSnapshot.sha256Checksum;
          verifiedCanonicalPath = verifiedSnapshot.snapshot.filePath;
        } else {
          if (evidenceBytes == null || evidenceBytes.isEmpty) {
            throw MissingCanonicalEvidenceSnapshotException(
              localDraftId: existingLocal.localDraftId,
              message: 'Canonical snapshot bytes or a CanonicalEvidenceSnapshotStore must be supplied for evidence submission.',
            );
          }
          final inspected = verifyCanonicalEvidenceBytes(
            bytes: evidenceBytes,
            expectedSha256: existingLocal.sha256Checksum!,
            expectedMediaType: evidenceMediaType,
          );
          resolvedBytes = inspected.bytes;
          resolvedMediaType = inspected.mediaType;
          resolvedSha256 = inspected.sha256Checksum;
          verifiedCanonicalPath = existingLocal.localCompressedPhotoPath;
        }

        resolvedEvidenceId = EvidenceId(boundEvidenceId);
      }

      // Bind caller payload to persisted local journal before acquiring a claim (R33-07).
      final preClaimMismatch = _findJournalPayloadMismatch(
        candidate: existingLocal,
        authenticatedActorId: initialContext.userId,
        familyId: familyId,
        childId: childId,
        createCommandId: createCommandId,
        submitCommandId: submitCommandId,
        subjectKey: subjectKey,
        normalizedSubject: normalizedSubject,
        normalizedTitle: normalizedTitle,
        type: type,
        difficulty: difficulty,
        score: score,
        normalizedOccurredAt: normalizedOccurredAt,
        entryContext: entryContext,
        callerEvidenceId: evidenceId,
        resolvedEvidenceId: resolvedEvidenceId,
        resolvedSha256: resolvedSha256,
        expectedCanonicalPath: verifiedCanonicalPath,
        expectedHasEvidence: resolvedBytes != null,
      );
      if (preClaimMismatch != null) {
        throw DraftSubmissionCasException(
          stage: DraftCasFailureStage.acquireLease,
          localDraftId: existingLocal.localDraftId,
          casStatus: DraftCasStatus.casConflict,
          serverAssessmentId: existingLocal.serverAssessmentId,
          serverEvidenceId: existingLocal.serverEvidenceId,
          message:
              'Submission payload does not match persisted local draft journal ($preClaimMismatch).',
        );
      }
    }

    final hasResolvedEvidence = resolvedBytes != null;
    String? activeLeaseToken;
    var completedLocally = false;
    String? knownServerAssessmentId = existingLocal?.serverAssessmentId;
    String? knownServerEvidenceId = existingLocal?.serverEvidenceId;
    Object? primaryError;

    try {
      try {
        // 3. Claim lease and record possibly_dispatched durably via CAS before issuing remote RPC
        if (existingLocal != null && localDraftId != null) {
          final DraftCasResult claimResult;
          try {
            claimResult = await localDraftStore!.acquireDraftClaim(
              localDraftId: localDraftId,
              actorUserId: initialContext.userId,
              familyId: familyId.value,
              childId: childId.value,
              leaseDuration: const Duration(minutes: 2),
              now: clock.now().toUtc(),
            );
          } catch (e) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.acquireLease,
              localDraftId: localDraftId,
              serverAssessmentId: knownServerAssessmentId,
              serverEvidenceId: knownServerEvidenceId,
              message: 'Failed to acquire submission lease due to a local storage error.',
              cause: e,
            );
          }
          if (!claimResult.isSuccess || claimResult.draft?.leaseToken == null) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.acquireLease,
              localDraftId: localDraftId,
              casStatus: claimResult.status,
              serverAssessmentId: knownServerAssessmentId,
              serverEvidenceId: knownServerEvidenceId,
              message:
                  'Failed to acquire submission lease for draft (${claimResult.status.name}).',
            );
          }
          final claimedDraft = claimResult.draft!;
          final leaseToken = claimedDraft.leaseToken!;
          activeLeaseToken = leaseToken;

          // Validate claimed row returned by acquireDraftClaim against intended payload
          // and pre-claim snapshot identity BEFORE markDraftStageAndDispatch or RPC (R33-07).
          final postClaimMismatch = _findJournalPayloadMismatch(
            candidate: claimedDraft,
            baselineRow: existingLocal,
            authenticatedActorId: initialContext.userId,
            familyId: familyId,
            childId: childId,
            createCommandId: createCommandId,
            submitCommandId: submitCommandId,
            subjectKey: subjectKey,
            normalizedSubject: normalizedSubject,
            normalizedTitle: normalizedTitle,
            type: type,
            difficulty: difficulty,
            score: score,
            normalizedOccurredAt: normalizedOccurredAt,
            entryContext: entryContext,
            callerEvidenceId: evidenceId,
            resolvedEvidenceId: resolvedEvidenceId,
            resolvedSha256: resolvedSha256,
            expectedCanonicalPath: verifiedCanonicalPath,
            expectedHasEvidence: hasResolvedEvidence,
          );
          if (postClaimMismatch != null) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.acquireLease,
              localDraftId: localDraftId,
              casStatus: DraftCasStatus.casConflict,
              serverAssessmentId: claimedDraft.serverAssessmentId,
              serverEvidenceId: claimedDraft.serverEvidenceId,
              message:
                  'Claimed local draft journal no longer matches intended submission payload ($postClaimMismatch).',
            );
          }

          final DraftCasResult dispatchResult;
          try {
            dispatchResult = await localDraftStore!.markDraftStageAndDispatch(
              localDraftId: localDraftId,
              leaseToken: leaseToken,
              authenticatedActorId: initialContext.userId,
              targetStage: hasResolvedEvidence
                  ? DraftSubmissionStatus.uploadingEvidence
                  : DraftSubmissionStatus.submittingAssessment,
              now: clock.now().toUtc(),
            );
          } catch (e) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.markDispatchStage,
              localDraftId: localDraftId,
              serverAssessmentId: knownServerAssessmentId,
              serverEvidenceId: knownServerEvidenceId,
              message: 'Failed to mark draft as possibly_dispatched due to a local storage error.',
              cause: e,
            );
          }
          if (!dispatchResult.isSuccess) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.markDispatchStage,
              localDraftId: localDraftId,
              casStatus: dispatchResult.status,
              serverAssessmentId: knownServerAssessmentId,
              serverEvidenceId: knownServerEvidenceId,
              message:
                  'Failed to mark draft as possibly_dispatched (${dispatchResult.status.name}).',
            );
          }

          // Revalidate session across async local draft write before remote RPC (R32-09)
          await assertValidStorageAuthSession(
            authSessionPort: authSessionPort,
            storagePath: '',
            context: initialContext,
            expectedSessionGeneration: initialContext.sessionGeneration,
            stage: 'assessment draft creation',
          );
        }

        // 4. Create server draft via server-authoritative trusted RPC using createCommandId
        final draft = await repository.createDraft(
          commandId: createCommandId,
          familyId: familyId,
          childId: childId,
          subjectKey: subjectKey,
          subject: normalizedSubject,
          title: normalizedTitle,
          type: type,
          difficulty: difficulty,
          score: score,
          occurredAt: normalizedOccurredAt,
          entryContext: entryContext,
        );
        knownServerAssessmentId = draft.id.value;

        // 5. Persist serverAssessmentId via leased CAS before upload/submit (R33-05)
        if (existingLocal != null &&
            localDraftStore != null &&
            localDraftId != null &&
            activeLeaseToken != null) {
          final DraftCasResult persistAssessResult;
          try {
            persistAssessResult = await localDraftStore!
                .persistServerAssessmentId(
                  localDraftId: localDraftId,
                  leaseToken: activeLeaseToken,
                  authenticatedActorId: initialContext.userId,
                  serverAssessmentId: draft.id.value,
                  now: clock.now().toUtc(),
                );
          } catch (e) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.persistServerAssessmentId,
              localDraftId: localDraftId,
              serverAssessmentId: draft.id.value,
              serverEvidenceId: knownServerEvidenceId,
              message: 'Failed to persist serverAssessmentId due to a local storage error.',
              cause: e,
            );
          }
          if (!persistAssessResult.isSuccess) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.persistServerAssessmentId,
              localDraftId: localDraftId,
              casStatus: persistAssessResult.status,
              serverAssessmentId: draft.id.value,
              serverEvidenceId: knownServerEvidenceId,
              message:
                  'Failed to persist serverAssessmentId (${persistAssessResult.status.name}).',
            );
          }
        }

        // 6. Upload/register canonical evidence (if not already registered & persisted),
        //    persist serverEvidenceId via CAS, and advance stage to submittingAssessment.
        if (hasResolvedEvidence) {
          if (knownServerEvidenceId == null || knownServerEvidenceId.isEmpty) {
            final uploadUseCase = UploadAssessmentEvidence(
              repository: repository,
              storage: storage,
              authSessionPort: authSessionPort,
            );

            final registeredEvidence = await uploadUseCase(
              familyId: familyId,
              childId: childId,
              assessmentId: draft.id,
              evidenceId: resolvedEvidenceId!,
              bytes: resolvedBytes,
              mediaType: resolvedMediaType!,
              context: initialContext,
              expectedSessionGeneration: initialContext.sessionGeneration,
            );
            knownServerEvidenceId = registeredEvidence.id.value;

            if (existingLocal != null &&
                localDraftStore != null &&
                localDraftId != null &&
                activeLeaseToken != null) {
              final DraftCasResult persistEvidenceResult;
              try {
                persistEvidenceResult = await localDraftStore!
                    .persistServerEvidenceId(
                      localDraftId: localDraftId,
                      leaseToken: activeLeaseToken,
                      authenticatedActorId: initialContext.userId,
                      serverEvidenceId: knownServerEvidenceId,
                      expectedEvidenceId: resolvedEvidenceId.value,
                      expectedSha256Checksum: resolvedSha256!,
                      now: clock.now().toUtc(),
                    );
              } catch (e) {
                throw DraftSubmissionCasException(
                  stage: DraftCasFailureStage.persistServerEvidenceId,
                  localDraftId: localDraftId,
                  serverAssessmentId: draft.id.value,
                  serverEvidenceId: knownServerEvidenceId,
                  message: 'Failed to persist serverEvidenceId due to a local storage error.',
                  cause: e,
                );
              }
              if (!persistEvidenceResult.isSuccess) {
                throw DraftSubmissionCasException(
                  stage: DraftCasFailureStage.persistServerEvidenceId,
                  localDraftId: localDraftId,
                  casStatus: persistEvidenceResult.status,
                  serverAssessmentId: draft.id.value,
                  serverEvidenceId: knownServerEvidenceId,
                  message:
                      'Failed to persist serverEvidenceId (${persistEvidenceResult.status.name}).',
                );
              }
            }
          }

          if (existingLocal != null &&
              localDraftStore != null &&
              localDraftId != null &&
              activeLeaseToken != null) {
            final DraftCasResult submitStageResult;
            try {
              submitStageResult = await localDraftStore!
                  .markDraftStageAndDispatch(
                    localDraftId: localDraftId,
                    leaseToken: activeLeaseToken,
                    authenticatedActorId: initialContext.userId,
                    targetStage: DraftSubmissionStatus.submittingAssessment,
                    now: clock.now().toUtc(),
                  );
            } catch (e) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.markSubmittingStage,
                localDraftId: localDraftId,
                serverAssessmentId: draft.id.value,
                serverEvidenceId: knownServerEvidenceId,
                message: 'Failed to advance local draft stage before submitAssessment due to a local storage error.',
                cause: e,
              );
            }
            if (!submitStageResult.isSuccess) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.markSubmittingStage,
                localDraftId: localDraftId,
                casStatus: submitStageResult.status,
                serverAssessmentId: draft.id.value,
                serverEvidenceId: knownServerEvidenceId,
                message:
                    'Failed to advance local draft stage before submitAssessment (${submitStageResult.status.name}).',
              );
            }
          }
        }

        // 7. Revalidate session across async boundary before submitAssessment
        await assertValidStorageAuthSession(
          authSessionPort: authSessionPort,
          storagePath: '',
          context: initialContext,
          expectedSessionGeneration: initialContext.sessionGeneration,
          stage: 'assessment submit',
        );

        // 8. Submit assessment for adult review with distinct submitCommandId
        final submitted = await repository.submitAssessment(
          assessmentId: draft.id,
          expectedVersion: draft.version,
          commandId: submitCommandId,
        );

        // 9. Transition local draft to confirmed_committed tombstone per I14 (never deleteLocalDraft)
        if (existingLocal != null &&
            localDraftId != null &&
            localDraftStore != null &&
            activeLeaseToken != null) {
          final DraftCasResult completion;
          try {
            completion = await localDraftStore!.completeDraftSubmission(
              localDraftId: localDraftId,
              leaseToken: activeLeaseToken,
              authenticatedActorId: initialContext.userId,
              serverAssessmentId: draft.id.value,
              serverEvidenceId: knownServerEvidenceId,
              now: clock.now().toUtc(),
            );
          } catch (e) {
            throw AssessmentReconciliationPendingException(
              submittedAssessment: submitted,
              localDraftId: localDraftId,
              serverEvidenceId: knownServerEvidenceId,
              message: 'Assessment submitted remotely, but local completion failed due to a storage error.',
              cause: e,
            );
          }

          final committedDraft = completion.draft;
          final bool hasMatchingServerAssessment =
              committedDraft != null &&
              committedDraft.serverAssessmentId == draft.id.value;
          final bool hasMatchingServerEvidence = knownServerEvidenceId != null
              ? committedDraft?.serverEvidenceId == knownServerEvidenceId
              : committedDraft?.serverEvidenceId == null;
          final committedSuccessfully =
              completion.isSuccess ||
              (completion.status == DraftCasStatus.alreadyCommitted &&
                  hasMatchingServerAssessment &&
                  hasMatchingServerEvidence);
          if (!committedSuccessfully) {
            throw AssessmentReconciliationPendingException(
              submittedAssessment: submitted,
              localDraftId: localDraftId,
              serverEvidenceId: knownServerEvidenceId,
              casStatus: completion.status,
              message:
                  'Assessment submitted remotely, but local completion was rejected (${completion.status.name}).',
            );
          }
          completedLocally = true;
        }

        return submitted;
      } catch (e) {
        primaryError = e;
        rethrow;
      }
    } finally {
      if (activeLeaseToken != null &&
          !completedLocally &&
          localDraftStore != null &&
          localDraftId != null) {
        DraftCasResult? releaseResult;
        Object? releaseError;
        try {
          releaseResult = await localDraftStore!.releaseDraftClaim(
            localDraftId: localDraftId,
            leaseToken: activeLeaseToken,
            authenticatedActorId: initialContext.userId,
            now: clock.now().toUtc(),
          );
        } catch (e) {
          releaseError = e;
        }

        final releaseFailed =
            releaseError != null ||
            releaseResult == null ||
            !releaseResult.isSuccess;
        if (releaseFailed) {
          onLeaseReleaseFailure?.call(
            localDraftId: localDraftId,
            status: releaseResult?.status,
            error: releaseError,
          );
          if (primaryError == null) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.releaseDraftClaim,
              localDraftId: localDraftId,
              casStatus: releaseResult?.status,
              serverAssessmentId: knownServerAssessmentId,
              serverEvidenceId: knownServerEvidenceId,
              message:
                  'Failed to release submission lease (${releaseResult?.status.name ?? 'storageError'}).',
              cause: releaseError,
            );
          }
        }
      }
    }
  }

  /// Compares caller submission inputs and pre-claim snapshot identity against a
  /// persisted/claimed [LocalAssessmentDraft] row (R33-07). Returns `null` if exact match.
  static String? _findJournalPayloadMismatch({
    required LocalAssessmentDraft candidate,
    LocalAssessmentDraft? baselineRow,
    required String authenticatedActorId,
    required FamilyId familyId,
    required ChildId childId,
    required String createCommandId,
    required String submitCommandId,
    required SubjectKey subjectKey,
    required String normalizedSubject,
    required String normalizedTitle,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    required DateTime? normalizedOccurredAt,
    required EntryContext entryContext,
    required EvidenceId? callerEvidenceId,
    required EvidenceId? resolvedEvidenceId,
    required String? resolvedSha256,
    required String? expectedCanonicalPath,
    required bool expectedHasEvidence,
  }) {
    if (candidate.actorUserId == null ||
        candidate.actorUserId != authenticatedActorId) {
      return 'actor provenance';
    }
    if (candidate.familyId != familyId.value) return 'familyId';
    if (candidate.childId != childId.value) return 'childId';
    if (candidate.createCommandId == null ||
        candidate.createCommandId != createCommandId) {
      return 'createCommandId';
    }
    if (candidate.submitCommandId == null ||
        candidate.submitCommandId != submitCommandId) {
      return 'submitCommandId';
    }
    if (candidate.subjectKey != subjectKey) return 'subjectKey';
    if (normalizeAssessmentSubject(candidate.subject) != normalizedSubject) {
      return 'subject';
    }
    if (normalizeAssessmentTitle(candidate.title) != normalizedTitle) {
      return 'title';
    }
    if (candidate.assessmentType != type.value) return 'assessmentType';
    if (candidate.difficulty != difficulty.value) return 'difficulty';
    if (candidate.rawScore != score.rawScore ||
        candidate.maxScore != score.maxScore) {
      return 'score';
    }
    if (normalizedOccurredAt == null ||
        normalizeAssessmentOccurredAt(candidate.occurredAt) !=
            normalizedOccurredAt) {
      return 'occurredAt';
    }
    if (candidate.entryContext != entryContext) return 'entryContext';

    final candidateHasEvidenceRef =
        candidate.hasVerifiedEvidenceSnapshot ||
        (candidate.evidenceId?.isNotEmpty ?? false) ||
        (candidate.localPhotoPath?.isNotEmpty ?? false) ||
        (candidate.localCompressedPhotoPath?.isNotEmpty ?? false) ||
        (candidate.sha256Checksum?.isNotEmpty ?? false);
    if (expectedHasEvidence) {
      if (!candidate.hasVerifiedEvidenceSnapshot) {
        return 'canonical evidence snapshot';
      }
      if (callerEvidenceId == null ||
          candidate.evidenceId != callerEvidenceId.value) {
        return 'evidenceId';
      }
      if (resolvedEvidenceId != null &&
          candidate.evidenceId != resolvedEvidenceId.value) {
        return 'bound evidenceId';
      }
      if (resolvedSha256 != null &&
          candidate.sha256Checksum != resolvedSha256) {
        return 'canonical snapshot SHA-256';
      }
      if (expectedCanonicalPath != null &&
          candidate.localCompressedPhotoPath != expectedCanonicalPath) {
        return 'canonical snapshot path';
      }
    } else if (candidateHasEvidenceRef) {
      return 'unexpected evidence attachment';
    }

    if (baselineRow != null) {
      if (candidate.actorUserId != baselineRow.actorUserId) {
        return 'persisted actor provenance';
      }
      if (candidate.subject != baselineRow.subject) return 'persisted subject';
      if (candidate.title != baselineRow.title) return 'persisted title';
      if (normalizeAssessmentOccurredAt(candidate.occurredAt) !=
          normalizeAssessmentOccurredAt(baselineRow.occurredAt)) {
        return 'persisted occurredAt';
      }
      if (candidate.localPhotoPath != baselineRow.localPhotoPath) {
        return 'persisted localPhotoPath';
      }
      if (candidate.dispatchState != baselineRow.dispatchState ||
          candidate.submissionStatus != baselineRow.submissionStatus ||
          candidate.serverAssessmentId != baselineRow.serverAssessmentId ||
          candidate.serverEvidenceId != baselineRow.serverEvidenceId) {
        return 'persisted dispatch provenance';
      }
      if (candidate.isLegacyUnknown ||
          candidate.hasUnboundActor ||
          candidate.hasMalformedLease ||
          candidate.isReadOnlyQuarantined ||
          candidate.hasWaitingOriginalActorMarker ||
          candidate.submissionStatus == DraftSubmissionStatus.terminalError ||
          (candidate.hasRecoveryMarker &&
              candidate.recoveryCode != DraftRecoveryCode.retryScheduled)) {
        return 'draft recovery state';
      }
    }

    return null;
  }
}
