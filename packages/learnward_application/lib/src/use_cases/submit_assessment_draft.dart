import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/auth_session_port.dart';
import '../ports/command_lifecycle_states.dart';
import '../ports/local_draft_store.dart';
import 'upload_assessment_evidence.dart';

/// Application use case coordinating the complete assessment submission workflow:
/// 1. Fail closed on quarantined, unbound-actor, committed, or already in-flight local drafts
/// 2. Verify active authenticated session via [AuthSessionPort] (R32-06) and match bound draft actor
/// 3. Validate any attached evidence payload before remote mutation (R32-08)
/// 4. Acquire a CAS lease and transition the local draft to `possiblyDispatched`/`submittingAssessment` via CAS (R33-01..03), revalidate session before `createDraft` (R32-09), and create or ensure server draft (idempotent via createCommandId)
/// 5. Persist `serverAssessmentId` via leased CAS
/// 6. Upload and register evidence (preserving remote bytes on failure per I04)
/// 7. Revalidate session before submitting assessment for review (idempotent via submitCommandId)
/// 8. Complete local draft as `confirmedCommitted` tombstone (I14) or release uncompleted lease in `finally`
///
/// WP1 -> WP2/WP3 boundary: Live [AuthSessionPort] validity, session-generation
/// continuity, original draft actor matching, and leased CAS lifecycle transitions
/// are enforced here. Freezing a canonical compressed evidence snapshot BEFORE
/// dispatch (`saveCanonicalEvidenceSnapshot` + `persistServerEvidenceId`) for
/// evidence-bearing foreground submissions depends on WP3 orchestrator wiring.
final class SubmitAssessmentDraft {
  const SubmitAssessmentDraft({
    required this.repository,
    required this.storage,
    required this.authSessionPort,
    this.localDraftStore,
  });

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;
  final AuthSessionPort authSessionPort;
  final LocalDraftStore? localDraftStore;

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
    // 0. Fail closed on unsafe/quarantined/in-flight local drafts before touching session/network
    LocalAssessmentDraft? existingLocal;
    if (localDraftStore != null && localDraftId != null) {
      existingLocal = await localDraftStore!.getLocalDraft(localDraftId);
      if (existingLocal != null) {
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
                existingLocal.recoveryCode !=
                    DraftRecoveryCode.retryScheduled)) {
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

    // 2. Fail closed on invalid, empty, or oversized evidence before creating draft
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
    }

    String? activeLeaseToken;
    var completedLocally = false;

    try {
      // Claim lease and record possibly_dispatched durably via CAS before issuing remote RPC
      if (existingLocal != null && localDraftId != null) {
        final claimResult = await localDraftStore!.acquireDraftClaim(
          localDraftId: localDraftId,
          actorUserId: initialContext.userId,
          familyId: familyId.value,
          childId: childId.value,
          leaseDuration: const Duration(minutes: 2),
          now: DateTime.now().toUtc(),
        );
        if (!claimResult.isSuccess || claimResult.draft?.leaseToken == null) {
          throw StateError(
            'Failed to acquire submission lease for draft $localDraftId (${claimResult.status.name}).',
          );
        }
        activeLeaseToken = claimResult.draft!.leaseToken;

        final dispatchResult = await localDraftStore!.markDraftStageAndDispatch(
          localDraftId: localDraftId,
          leaseToken: activeLeaseToken!,
          authenticatedActorId: initialContext.userId,
          targetStage: DraftSubmissionStatus.submittingAssessment,
          now: DateTime.now().toUtc(),
        );
        if (!dispatchResult.isSuccess) {
          throw StateError(
            'Failed to mark draft $localDraftId as possibly_dispatched (${dispatchResult.status.name}).',
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

      // 3. Create server draft via server-authoritative trusted RPC using createCommandId
      final draft = await repository.createDraft(
        commandId: createCommandId,
        familyId: familyId,
        childId: childId,
        subjectKey: subjectKey,
        subject: subject,
        title: title,
        type: type,
        difficulty: difficulty,
        score: score,
        occurredAt: occurredAt,
        entryContext: entryContext,
      );

      // Persist serverAssessmentId via leased CAS when local draft is present
      if (existingLocal != null &&
          localDraftStore != null &&
          localDraftId != null &&
          activeLeaseToken != null) {
        try {
          await localDraftStore!.persistServerAssessmentId(
            localDraftId: localDraftId,
            leaseToken: activeLeaseToken,
            authenticatedActorId: initialContext.userId,
            serverAssessmentId: draft.id.value,
            now: DateTime.now().toUtc(),
          );
        } catch (_) {
          // Non-blocking CAS update; pre-WP3 evidence-bearing drafts without canonical
          // snapshot return blockedQuarantined here until WP3 freezes snapshots before dispatch.
        }
      }

      // 4. Upload and register evidence if provided (preserving remote bytes per I04)
      if (evidenceBytes != null &&
          evidenceMediaType != null &&
          evidenceId != null) {
        final uploadUseCase = UploadAssessmentEvidence(
          repository: repository,
          storage: storage,
          authSessionPort: authSessionPort,
        );

        await uploadUseCase(
          familyId: familyId,
          childId: childId,
          assessmentId: draft.id,
          evidenceId: evidenceId,
          bytes: evidenceBytes,
          mediaType: evidenceMediaType,
          context: initialContext,
          expectedSessionGeneration: initialContext.sessionGeneration,
        );
      }

      // 5. Revalidate session across async boundary before submitAssessment
      await assertValidStorageAuthSession(
        authSessionPort: authSessionPort,
        storagePath: '',
        context: initialContext,
        expectedSessionGeneration: initialContext.sessionGeneration,
        stage: 'assessment submit',
      );

      // 6. Submit assessment for adult review with distinct submitCommandId
      final submitted = await repository.submitAssessment(
        assessmentId: draft.id,
        expectedVersion: draft.version,
        commandId: submitCommandId,
      );

      // 7. Transition local draft to confirmed_committed tombstone per I14 (never deleteLocalDraft)
      if (existingLocal != null &&
          localDraftId != null &&
          localDraftStore != null &&
          activeLeaseToken != null) {
        try {
          final completion = await localDraftStore!.completeDraftSubmission(
            localDraftId: localDraftId,
            leaseToken: activeLeaseToken,
            authenticatedActorId: initialContext.userId,
            serverAssessmentId: draft.id.value,
            now: DateTime.now().toUtc(),
          );
          if (completion.isSuccess ||
              completion.status == DraftCasStatus.alreadyCommitted) {
            completedLocally = true;
          }
        } catch (_) {
          // Pre-WP3 evidence-bearing drafts without canonical snapshot return blockedQuarantined
          // until WP3 freezes canonical snapshots prior to dispatch.
        }
      }

      return submitted;
    } finally {
      if (activeLeaseToken != null &&
          !completedLocally &&
          localDraftStore != null &&
          localDraftId != null) {
        try {
          await localDraftStore!.releaseDraftClaim(
            localDraftId: localDraftId,
            leaseToken: activeLeaseToken,
            authenticatedActorId: initialContext.userId,
            now: DateTime.now().toUtc(),
          );
        } catch (_) {
          // Best-effort lease release on abort/failure.
        }
      }
    }
  }
}
