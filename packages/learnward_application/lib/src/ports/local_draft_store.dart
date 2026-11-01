import 'package:learnward_domain/learnward_domain.dart';

/// Unsent local assessment draft for offline capture and reliability.
final class LocalAssessmentDraft {
  const LocalAssessmentDraft({
    required this.localDraftId,
    required this.familyId,
    required this.childId,
    this.serverAssessmentId,
    required this.subjectKey,
    required this.subject,
    required this.title,
    required this.assessmentType,
    required this.difficulty,
    required this.rawScore,
    required this.maxScore,
    this.localPhotoPath,
    this.entryContext = EntryContext.sharedChild,
    required this.occurredAt,
    required this.updatedAt,
  });

  final String localDraftId;
  final String familyId;
  final String childId;
  final String? serverAssessmentId;
  final SubjectKey subjectKey;
  final String subject;
  final String title;
  final String assessmentType;
  final String difficulty;
  final double rawScore;
  final double maxScore;
  final String? localPhotoPath;
  final EntryContext entryContext;
  final DateTime occurredAt;
  final DateTime updatedAt;
}

/// Port for local offline assessment drafts storage.
abstract interface class LocalDraftStore {
  /// Saves or updates a local draft.
  Future<void> saveLocalDraft(LocalAssessmentDraft draft);

  /// Retrieves a specific local draft by its stable local id.
  Future<LocalAssessmentDraft?> getLocalDraft(String localDraftId);

  /// Lists all local drafts for a given child.
  Future<List<LocalAssessmentDraft>> listLocalDrafts(ChildId childId);

  /// Deletes a local draft after successful server submission.
  Future<void> deleteLocalDraft(String localDraftId);
}
