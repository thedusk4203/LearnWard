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

  /// Returns whether this draft is in an unsafe state that forbids local deletion.
  ///
  /// Fails closed if quarantined as unknown legacy, possibly dispatched, confirmed
  /// committed, actively uploading/submitting, pending retry, or held under an unexpired lease.
  bool isUnsafeToDelete({DateTime? now}) {
    final currentTime = (now ?? DateTime.now()).toUtc();
    final hasActiveLease =
        leaseToken != null &&
        leaseExpiresAt != null &&
        leaseExpiresAt!.isAfter(currentTime);

    return isLegacyUnknown ||
        dispatchState == CommandDispatchState.possiblyDispatched ||
        dispatchState == CommandDispatchState.confirmedCommitted ||
        submissionStatus == DraftSubmissionStatus.submittingAssessment ||
        submissionStatus == DraftSubmissionStatus.uploadingEvidence ||
        submissionStatus == DraftSubmissionStatus.failedRetryable ||
        hasActiveLease;
  }

  /// Returns a user-friendly diagnostic reason why this draft cannot currently be deleted.
  String? deletionBlockedReason({DateTime? now}) {
    if (!isUnsafeToDelete(now: now)) return null;
    final currentTime = (now ?? DateTime.now()).toUtc();
    final hasActiveLease =
        leaseToken != null &&
        leaseExpiresAt != null &&
        leaseExpiresAt!.isAfter(currentTime);

    if (isLegacyUnknown) {
      return 'This draft was migrated from a previous version and requires recovery reconciliation before it can be deleted.';
    }
    if (hasActiveLease) {
      return 'This draft is currently being processed under an active lease.';
    }
    if (dispatchState == CommandDispatchState.possiblyDispatched) {
      return 'This draft has an in-flight server command and cannot be deleted until the outcome is confirmed.';
    }
    if (dispatchState == CommandDispatchState.confirmedCommitted) {
      return 'This draft has already been confirmed committed on the server.';
    }
    if (submissionStatus == DraftSubmissionStatus.submittingAssessment) {
      return 'This draft is currently being submitted to the server.';
    }
    if (submissionStatus == DraftSubmissionStatus.uploadingEvidence) {
      return 'Evidence for this draft is currently being uploaded.';
    }
    if (submissionStatus == DraftSubmissionStatus.failedRetryable) {
      return 'This draft encountered a transient error and is queued for retry.';
    }
    return 'This draft is in an unsafe state and cannot be deleted.';
  }

  /// Returns whether this draft has substantive content or state differences
  /// compared to [other] that would represent a concurrent modification conflict.
  bool hasConflictWith(LocalAssessmentDraft other) {
    return !updatedAt.isAtSameMomentAs(other.updatedAt) ||
        localPhotoPath != other.localPhotoPath ||
        localCompressedPhotoPath != other.localCompressedPhotoPath ||
        title != other.title ||
        rawScore != other.rawScore ||
        maxScore != other.maxScore ||
        subjectKey != other.subjectKey ||
        entryContext != other.entryContext ||
        submissionStatus != other.submissionStatus ||
        dispatchState != other.dispatchState;
  }

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

/// Status outcomes for atomic, state-aware local draft deletion.
enum DraftDeletionStatus {
  /// Draft row was safely deleted from local storage.
  deleted,

  /// Deletion was rejected because the draft is in an unsafe state
  /// (e.g. unknown legacy, in-flight dispatch, confirmed committed, active lease, or active submission).
  blockedUnsafeState,

  /// Deletion was rejected because the persisted draft was modified
  /// concurrently while the deletion confirmation was pending.
  concurrencyConflict,

  /// Draft record was not found in local storage.
  notFound,
}

/// Explicit outcome of an atomic [LocalDraftStore.deleteDraftSafely] operation.
final class DraftDeletionOutcome {
  const DraftDeletionOutcome({
    required this.status,
    required this.localDraftId,
    this.reason,
    this.currentDraft,
  });

  final DraftDeletionStatus status;
  final String localDraftId;
  final String? reason;
  final LocalAssessmentDraft? currentDraft;

  bool get isDeleted => status == DraftDeletionStatus.deleted;
  bool get isBlockedUnsafeState =>
      status == DraftDeletionStatus.blockedUnsafeState;
  bool get isConcurrencyConflict =>
      status == DraftDeletionStatus.concurrencyConflict;
  bool get isNotFound => status == DraftDeletionStatus.notFound;

  @override
  String toString() =>
      'DraftDeletionOutcome(status: $status, draftId: $localDraftId, reason: $reason)';
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

  /// Atomically and safely deletes [localDraftId] only after revalidating that its
  /// current persisted state matches [expectedDraft] and is safe for deletion.
  ///
  /// Rejects deletion if the draft is quarantined (unknown legacy), in-flight
  /// (possibly dispatched or confirmed committed), has an active lease, or is currently
  /// undergoing submission or evidence upload.
  ///
  /// Rejects deletion with [DraftDeletionStatus.concurrencyConflict] if the draft
  /// was modified concurrently while the deletion decision was pending.
  Future<DraftDeletionOutcome> deleteDraftSafely({
    required String localDraftId,
    required LocalAssessmentDraft expectedDraft,
    DateTime? now,
  });

  /// Returns whether any local assessment draft currently references [filePath]
  /// in either its [localPhotoPath] or [localCompressedPhotoPath].
  Future<bool> hasDraftReferenceToFile(String filePath);

  /// Returns the total count of local drafts referencing [filePath].
  Future<int> countDraftReferencesToFile(String filePath);
}
