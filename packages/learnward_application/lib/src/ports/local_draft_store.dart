import 'package:learnward_domain/learnward_domain.dart';

/// Unsent local assessment draft for offline capture and reliability.
final class LocalAssessmentDraft {
  const LocalAssessmentDraft({
    required this.localDraftId,
    required this.familyId,
    required this.childId,
    required this.createCommandId,
    required this.submitCommandId,
    this.evidenceId,
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
  final String createCommandId;
  final String submitCommandId;
  final String? evidenceId;
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

  LocalAssessmentDraft copyWith({
    String? familyId,
    String? childId,
    String? createCommandId,
    String? submitCommandId,
    String? evidenceId,
    String? serverAssessmentId,
    SubjectKey? subjectKey,
    String? subject,
    String? title,
    String? assessmentType,
    String? difficulty,
    double? rawScore,
    double? maxScore,
    String? localPhotoPath,
    EntryContext? entryContext,
    DateTime? occurredAt,
    DateTime? updatedAt,
  }) {
    return LocalAssessmentDraft(
      localDraftId: localDraftId,
      familyId: familyId ?? this.familyId,
      childId: childId ?? this.childId,
      createCommandId: createCommandId ?? this.createCommandId,
      submitCommandId: submitCommandId ?? this.submitCommandId,
      evidenceId: evidenceId ?? this.evidenceId,
      serverAssessmentId: serverAssessmentId ?? this.serverAssessmentId,
      subjectKey: subjectKey ?? this.subjectKey,
      subject: subject ?? this.subject,
      title: title ?? this.title,
      assessmentType: assessmentType ?? this.assessmentType,
      difficulty: difficulty ?? this.difficulty,
      rawScore: rawScore ?? this.rawScore,
      maxScore: maxScore ?? this.maxScore,
      localPhotoPath: localPhotoPath ?? this.localPhotoPath,
      entryContext: entryContext ?? this.entryContext,
      occurredAt: occurredAt ?? this.occurredAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
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
