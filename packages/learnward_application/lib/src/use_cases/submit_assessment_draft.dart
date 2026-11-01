import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/local_draft_store.dart';
import 'upload_assessment_evidence.dart';

/// Application use case coordinating the complete assessment submission workflow:
/// 1. Create or ensure server draft (idempotent via commandId)
/// 2. Upload and register evidence (with compensation cleanup on failure)
/// 3. Submit assessment for review
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
    required String commandId,
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
    // 1. Create server draft via server-authoritative trusted RPC
    final draft = await repository.createDraft(
      commandId: commandId,
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

    // 3. Submit assessment for adult review
    final submitted = await repository.submitAssessment(
      assessmentId: draft.id,
      expectedVersion: draft.version,
      commandId: commandId,
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
