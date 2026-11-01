import 'package:learnward_domain/learnward_domain.dart';

/// Repository port for assessment ingestion, workflow transitions, and audit records.
abstract interface class AssessmentRepository {
  /// Creates a draft assessment via server-authoritative RPC.
  Future<Assessment> createDraft({
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
    EntryContext entryContext = EntryContext.adult,
  });

  /// Updates an existing draft assessment.
  Future<Assessment> updateDraft({
    required AssessmentId assessmentId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    required int expectedVersion,
  });

  /// Submits a draft assessment for adult review.
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  });

  /// Verifies an assessment. Can only be invoked by an active adult in the family.
  Future<Assessment> verifyAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    String? notes,
  });

  /// Rejects an assessment with mandatory server-enforced feedback notes.
  Future<Assessment> rejectAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    required String reason,
  });

  /// Retrieves a specific assessment by id.
  Future<Assessment?> getAssessment(AssessmentId id);

  /// Lists assessments for a family, optionally filtered by status.
  Future<List<Assessment>> listAssessmentsByFamily(
    FamilyId familyId, {
    AssessmentStatus? status,
  });

  /// Lists assessments for a child, optionally filtered by status.
  Future<List<Assessment>> listAssessmentsByChild(
    ChildId childId, {
    AssessmentStatus? status,
  });

  /// Lists immutable verified learning events for a child.
  Future<List<VerifiedLearningEvent>> listVerifiedLearningEvents(
    ChildId childId,
  );

  /// Registers an uploaded evidence asset record for a draft assessment.
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  });

  /// Removes an evidence record from a draft assessment.
  Future<void> removeDraftEvidence(EvidenceId evidenceId);

  /// Lists all evidence records attached to an assessment.
  Future<List<AssessmentEvidence>> listEvidenceForAssessment(
    AssessmentId assessmentId,
  );
}
