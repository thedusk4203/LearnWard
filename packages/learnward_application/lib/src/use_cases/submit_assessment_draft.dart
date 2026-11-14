import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/auth_session_port.dart';
import '../ports/command_lifecycle_states.dart';
import '../ports/local_draft_store.dart';
import 'upload_assessment_evidence.dart';

/// Application use case coordinating the complete assessment submission workflow:
/// 1. Verify active authenticated session via [AuthSessionPort] (R32-06)
/// 2. Validate any attached evidence payload before remote mutation (R32-08)
/// 3. Record local dispatch state (when a local draft exists), revalidate session before `createDraft` (R32-09), and create or ensure server draft (idempotent via createCommandId)
/// 4. Upload and register evidence (preserving remote bytes on failure per I04)
/// 5. Revalidate session before submitting assessment for review (idempotent via submitCommandId)
/// 6. Delete local offline draft upon success
///
/// WP1 -> WP2/WP3 boundary: Live [AuthSessionPort] validity and session-generation
/// continuity are enforced throughout this workflow. Durable cross-restart draft
/// actor binding (`actorUserId`, persisted session epoch, and lease-token CAS)
/// depends on WP2/WP3.
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
    // 0. Check quarantined legacy drafts locally before touching session/network
    LocalAssessmentDraft? existingLocal;
    if (localDraftStore != null && localDraftId != null) {
      existingLocal = await localDraftStore!.getLocalDraft(localDraftId);
      if (existingLocal != null && existingLocal.isLegacyUnknown) {
        throw StateError(
          'Cannot submit quarantined legacy assessment draft (id: $localDraftId). '
          'Draft is in unknown_legacy dispatch state and requires reconciliation before submission.',
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

    // Record possibly_dispatched durably before issuing remote RPC
    if (existingLocal != null) {
      await localDraftStore!.saveLocalDraft(
        existingLocal.copyWith(
          submissionStatus: DraftSubmissionStatus.submittingAssessment,
          dispatchState: CommandDispatchState.possiblyDispatched,
        ),
      );

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

    // If local draft store is present and localDraftId is provided, persist serverAssessmentId
    if (localDraftStore != null && localDraftId != null) {
      try {
        final latestLocal = await localDraftStore!.getLocalDraft(localDraftId);
        if (latestLocal != null &&
            latestLocal.serverAssessmentId != draft.id.value) {
          await localDraftStore!.saveLocalDraft(
            latestLocal.copyWith(serverAssessmentId: draft.id.value),
          );
        }
      } catch (_) {
        // Non-blocking local persistence update
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

    // 7. Remove local draft upon successful submission
    if (localDraftId != null && localDraftStore != null) {
      try {
        await localDraftStore!.deleteLocalDraft(localDraftId);
      } catch (_) {
        // Safe to ignore if local draft was already removed
      }
    }

    return submitted;
  }
}
