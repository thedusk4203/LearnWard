import 'package:learnward_domain/learnward_domain.dart';

import 'command_lifecycle_states.dart';

/// Unsent local assessment draft for offline capture, content-integrity, and reliability.
final class LocalAssessmentDraft {
  const LocalAssessmentDraft({
    required this.localDraftId,
    required this.familyId,
    required this.childId,
    this.createCommandId,
    this.submitCommandId,
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
    this.serverEvidenceId,
    this.sha256Checksum,
    this.localCompressedPhotoPath,
    this.submissionStatus = DraftSubmissionStatus.draft,
    this.retryCount = 0,
    this.dispatchState = CommandDispatchState.neverDispatched,
    this.lastErrorMessage,
    this.actorUserId,
    this.actorRole,
    this.nextAttemptAt,
    this.leaseToken,
    this.leaseExpiresAt,
  });

  final String localDraftId;
  final String familyId;
  final String childId;
  final String? createCommandId;
  final String? submitCommandId;
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

  // Phase 6.1 Additions (v5):
  final String? serverEvidenceId;
  final String? sha256Checksum;
  final String? localCompressedPhotoPath;
  final DraftSubmissionStatus submissionStatus;
  final int retryCount;
  final CommandDispatchState dispatchState;
  final String? lastErrorMessage;
  final String? actorUserId;
  final String? actorRole;

  // Phase 6 Slice 4A-0 Additions (v6):
  final DateTime? nextAttemptAt;
  final String? leaseToken;
  final DateTime? leaseExpiresAt;

  /// Whether this draft was migrated from an uninstrumented legacy schema (Drift v4)
  /// with unknown network outcome.
  bool get isLegacyUnknown =>
      dispatchState == CommandDispatchState.unknownLegacy;

  /// Whether this draft is eligible for automated background submission.
  /// Fails closed if quarantined as unknown legacy or missing actor identity.
  bool get canAutoSubmit =>
      dispatchState != CommandDispatchState.unknownLegacy &&
      submissionStatus != DraftSubmissionStatus.terminalError &&
      actorUserId != null &&
      actorUserId!.isNotEmpty;

  LocalAssessmentDraft copyWith({
    String? familyId,
    String? childId,
    Object? createCommandId = _sentinel,
    Object? submitCommandId = _sentinel,
    Object? evidenceId = _sentinel,
    Object? serverAssessmentId = _sentinel,
    SubjectKey? subjectKey,
    String? subject,
    String? title,
    String? assessmentType,
    String? difficulty,
    double? rawScore,
    double? maxScore,
    Object? localPhotoPath = _sentinel,
    EntryContext? entryContext,
    DateTime? occurredAt,
    DateTime? updatedAt,
    Object? serverEvidenceId = _sentinel,
    Object? sha256Checksum = _sentinel,
    Object? localCompressedPhotoPath = _sentinel,
    DraftSubmissionStatus? submissionStatus,
    int? retryCount,
    CommandDispatchState? dispatchState,
    Object? lastErrorMessage = _sentinel,
    Object? actorUserId = _sentinel,
    Object? actorRole = _sentinel,
    Object? nextAttemptAt = _sentinel,
    Object? leaseToken = _sentinel,
    Object? leaseExpiresAt = _sentinel,
  }) {
    return LocalAssessmentDraft(
      localDraftId: localDraftId,
      familyId: familyId ?? this.familyId,
      childId: childId ?? this.childId,
      createCommandId: identical(createCommandId, _sentinel)
          ? this.createCommandId
          : createCommandId as String?,
      submitCommandId: identical(submitCommandId, _sentinel)
          ? this.submitCommandId
          : submitCommandId as String?,
      evidenceId: identical(evidenceId, _sentinel)
          ? this.evidenceId
          : evidenceId as String?,
      serverAssessmentId: identical(serverAssessmentId, _sentinel)
          ? this.serverAssessmentId
          : serverAssessmentId as String?,
      subjectKey: subjectKey ?? this.subjectKey,
      subject: subject ?? this.subject,
      title: title ?? this.title,
      assessmentType: assessmentType ?? this.assessmentType,
      difficulty: difficulty ?? this.difficulty,
      rawScore: rawScore ?? this.rawScore,
      maxScore: maxScore ?? this.maxScore,
      localPhotoPath: identical(localPhotoPath, _sentinel)
          ? this.localPhotoPath
          : localPhotoPath as String?,
      entryContext: entryContext ?? this.entryContext,
      occurredAt: occurredAt ?? this.occurredAt,
      updatedAt: updatedAt ?? this.updatedAt,
      serverEvidenceId: identical(serverEvidenceId, _sentinel)
          ? this.serverEvidenceId
          : serverEvidenceId as String?,
      sha256Checksum: identical(sha256Checksum, _sentinel)
          ? this.sha256Checksum
          : sha256Checksum as String?,
      localCompressedPhotoPath: identical(localCompressedPhotoPath, _sentinel)
          ? this.localCompressedPhotoPath
          : localCompressedPhotoPath as String?,
      submissionStatus: submissionStatus ?? this.submissionStatus,
      retryCount: retryCount ?? this.retryCount,
      dispatchState: dispatchState ?? this.dispatchState,
      lastErrorMessage: identical(lastErrorMessage, _sentinel)
          ? this.lastErrorMessage
          : lastErrorMessage as String?,
      actorUserId: identical(actorUserId, _sentinel)
          ? this.actorUserId
          : actorUserId as String?,
      actorRole: identical(actorRole, _sentinel)
          ? this.actorRole
          : actorRole as String?,
      nextAttemptAt: identical(nextAttemptAt, _sentinel)
          ? this.nextAttemptAt
          : nextAttemptAt as DateTime?,
      leaseToken: identical(leaseToken, _sentinel)
          ? this.leaseToken
          : leaseToken as String?,
      leaseExpiresAt: identical(leaseExpiresAt, _sentinel)
          ? this.leaseExpiresAt
          : leaseExpiresAt as DateTime?,
    );
  }
}

const Object _sentinel = Object();

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
