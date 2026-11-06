import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/command_lifecycle_states.dart';
import '../ports/local_draft_store.dart';
import 'upload_assessment_evidence.dart';

/// Application use case coordinating the complete assessment submission workflow:
/// 1. Create or ensure server draft (idempotent via createCommandId)
/// 2. Upload and register evidence (with compensation cleanup on failure)
/// 3. Submit assessment for review (idempotent via submitCommandId)
/// 4. Delete local offline draft upon success
final class SubmitAssessmentDraft {
  const SubmitAssessmentDraft({
    required this.repository,
    required this.storage,
    this.localDraftStore,
  });

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;
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
  }) async {
    // Durable pre-dispatch check & provenance:
    // If draft is unknown_legacy, fail closed immediately.
    // Otherwise record possibly_dispatched before issuing remote RPC.
    if (localDraftStore != null && localDraftId != null) {
      final existingLocal = await localDraftStore!.getLocalDraft(localDraftId);
      if (existingLocal != null) {
        if (existingLocal.isLegacyUnknown) {
          throw StateError(
            'Cannot submit quarantined legacy assessment draft (id: $localDraftId). '
            'Draft is in unknown_legacy dispatch state and requires reconciliation before submission.',
          );
        }
        await localDraftStore!.saveLocalDraft(
          existingLocal.copyWith(
            submissionStatus: DraftSubmissionStatus.submittingAssessment,
            dispatchState: CommandDispatchState.possiblyDispatched,
          ),
        );
      }
    }

    // 1. Create server draft via server-authoritative trusted RPC using createCommandId
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
        final existingLocal = await localDraftStore!.getLocalDraft(
          localDraftId,
        );
        if (existingLocal != null &&
            existingLocal.serverAssessmentId != draft.id.value) {
          await localDraftStore!.saveLocalDraft(
            existingLocal.copyWith(serverAssessmentId: draft.id.value),
          );
        }
      } catch (_) {
        // Non-blocking local persistence update
      }
    }

    // 2. Upload evidence if provided (with compensation cleanup on failure)
    if (evidenceBytes != null &&
        evidenceBytes.isNotEmpty &&
        evidenceMediaType != null &&
        evidenceId != null) {
      final uploadUseCase = UploadAssessmentEvidence(
        repository: repository,
        storage: storage,
      );

      await uploadUseCase(
        familyId: familyId,
        childId: childId,
        assessmentId: draft.id,
        evidenceId: evidenceId,
        bytes: evidenceBytes,
        mediaType: evidenceMediaType,
      );
    }

    // 3. Submit assessment for adult review with distinct submitCommandId
    final submitted = await repository.submitAssessment(
      assessmentId: draft.id,
      expectedVersion: draft.version,
      commandId: submitCommandId,
    );

    // 4. Remove local draft upon successful submission
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
