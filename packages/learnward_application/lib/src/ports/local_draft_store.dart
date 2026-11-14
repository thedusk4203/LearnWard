import 'package:learnward_domain/learnward_domain.dart';

import 'canonical_evidence_snapshot.dart';
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

  /// Whether this draft lacks durable actor provenance.
  bool get hasUnboundActor => actorUserId == null || actorUserId!.isEmpty;

  /// Whether lease metadata is half-populated (`leaseToken` XOR `leaseExpiresAt`).
  bool get hasMalformedLease =>
      (leaseToken != null) != (leaseExpiresAt != null);

  /// Whether a valid, unexpired lease token is currently held at [now].
  bool hasActiveLease({DateTime? now}) {
    final currentTime = (now ?? DateTime.now()).toUtc();
    return leaseToken != null &&
        leaseExpiresAt != null &&
        leaseExpiresAt!.isAfter(currentTime);
  }

  /// Whether a lease token exists and has expired on or before [now].
  bool hasExpiredLease({DateTime? now}) {
    final currentTime = (now ?? DateTime.now()).toUtc();
    return leaseToken != null &&
        leaseExpiresAt != null &&
        !leaseExpiresAt!.isAfter(currentTime);
  }

  /// Whether immutable canonical evidence path + 64-char SHA-256 checksum are persisted.
  bool get hasVerifiedEvidenceSnapshot =>
      localCompressedPhotoPath != null &&
      localCompressedPhotoPath!.isNotEmpty &&
      isValidSha256Hex(sha256Checksum);

  /// Whether a `possibly_dispatched` draft carries unverified legacy evidence
  /// references without a frozen canonical snapshot and SHA-256 checksum.
  bool get hasUnverifiedPossiblyDispatchedEvidence {
    if (dispatchState != CommandDispatchState.possiblyDispatched) {
      return false;
    }
    if (hasVerifiedEvidenceSnapshot) {
      return false;
    }
    return (localPhotoPath != null && localPhotoPath!.isNotEmpty) ||
        (localCompressedPhotoPath != null &&
            localCompressedPhotoPath!.isNotEmpty) ||
        (sha256Checksum != null && sha256Checksum!.isNotEmpty) ||
        (evidenceId != null && evidenceId!.isNotEmpty);
  }

  /// Normalized `LW4B1:...` recovery/quarantine code from [lastErrorMessage], if any.
  String? get recoveryCode => DraftRecoveryCode.parseCode(lastErrorMessage);

  /// Whether [lastErrorMessage] carries a structured `LW4B1:` marker.
  bool get hasRecoveryMarker => recoveryCode != null;

  /// Whether this draft is paused waiting for sign-in of the original author.
  bool get hasWaitingOriginalActorMarker =>
      recoveryCode == DraftRecoveryCode.waitingOriginalActor;

  /// Derived fail-closed quarantine code for read-only / non-auto-submittable drafts.
  String? get derivedQuarantineCode {
    final code = recoveryCode;
    if (code != null && DraftRecoveryCode.quarantineCodes.contains(code)) {
      return code;
    }
    if (submissionStatus == DraftSubmissionStatus.terminalError &&
        code != DraftRecoveryCode.terminalPolicyDenial &&
        code != DraftRecoveryCode.authContextExpiredOrMismatched) {
      return DraftRecoveryCode.quarantinedUnknownOutcome;
    }
    if (isLegacyUnknown) {
      return DraftRecoveryCode.legacyUnknown;
    }
    if (hasMalformedLease) {
      return DraftRecoveryCode.malformedLeaseMetadata;
    }
    if (hasUnboundActor) {
      return DraftRecoveryCode.unboundActorProvenance;
    }
    if (hasUnverifiedPossiblyDispatchedEvidence) {
      return DraftRecoveryCode.legacyInFlightUnverifiedBytes;
    }
    return null;
  }

  /// Whether this draft must fail closed into read-only quarantine.
  bool get isReadOnlyQuarantined => derivedQuarantineCode != null;

  /// Computes the fail-closed recovery disposition at [now].
  DraftRecoveryDisposition recoveryDispositionAt({DateTime? now}) {
    final code = recoveryCode;
    if (code == DraftRecoveryCode.storageContentConflict ||
        code == DraftRecoveryCode.localMetadataTampered ||
        code == DraftRecoveryCode.ambiguousDuplicateRow ||
        code == DraftRecoveryCode.evidenceIdMismatch ||
        code == DraftRecoveryCode.versionConflict) {
      return DraftRecoveryDisposition.quarantinedConflict;
    }
    if (code == DraftRecoveryCode.localSnapshotMissing) {
      return DraftRecoveryDisposition.quarantinedMissingSnapshot;
    }
    if (code == DraftRecoveryCode.localSnapshotCorrupted) {
      return DraftRecoveryDisposition.quarantinedCorruptedSnapshot;
    }
    if (code == DraftRecoveryCode.unknownWireStatus ||
        code == DraftRecoveryCode.quarantinedUnknownOutcome ||
        code == DraftRecoveryCode.malformedLeaseMetadata ||
        code == DraftRecoveryCode.unboundActorProvenance ||
        code == DraftRecoveryCode.registrationUnresolvedRemoteRetained ||
        code == DraftRecoveryCode.unreconstructableExpectedVersion ||
        code == DraftRecoveryCode.ambiguousSubmitOutcome ||
        code == DraftRecoveryCode.ambiguous42501Outcome) {
      return DraftRecoveryDisposition.quarantinedUnknownOutcome;
    }
    if (code == DraftRecoveryCode.legacyUnknown ||
        code == DraftRecoveryCode.legacyInFlightUnverifiedBytes ||
        isLegacyUnknown ||
        hasUnverifiedPossiblyDispatchedEvidence) {
      return DraftRecoveryDisposition.quarantinedLegacyUnknown;
    }
    if (hasMalformedLease || hasUnboundActor) {
      return DraftRecoveryDisposition.quarantinedUnknownOutcome;
    }
    if (code == DraftRecoveryCode.terminalPolicyDenial) {
      return DraftRecoveryDisposition.terminalPolicyDenial;
    }
    if (submissionStatus == DraftSubmissionStatus.terminalError) {
      return DraftRecoveryDisposition.quarantinedUnknownOutcome;
    }
    if (dispatchState == CommandDispatchState.confirmedCommitted) {
      return DraftRecoveryDisposition.confirmedSubmitted;
    }
    if (code == DraftRecoveryCode.waitingOriginalActor) {
      return DraftRecoveryDisposition.waitingOriginalActor;
    }
    if (submissionStatus == DraftSubmissionStatus.failedRetryable ||
        code == DraftRecoveryCode.retryScheduled) {
      return DraftRecoveryDisposition.retryScheduled;
    }
    if (hasActiveLease(now: now) ||
        submissionStatus == DraftSubmissionStatus.uploadingEvidence ||
        submissionStatus == DraftSubmissionStatus.submittingAssessment ||
        dispatchState == CommandDispatchState.possiblyDispatched) {
      return hasActiveLease(now: now)
          ? DraftRecoveryDisposition.inProgressSameSession
          : DraftRecoveryDisposition.verificationPending;
    }
    return DraftRecoveryDisposition.editableDraft;
  }

  /// Derived read-only recovery disposition evaluated at current UTC time.
  DraftRecoveryDisposition get recoveryDisposition => recoveryDispositionAt();

  /// Whether this draft is eligible for automated background submission.
  /// Fails closed if quarantined, waiting for original actor, terminally denied,
  /// already confirmed committed, missing actor provenance, or in-flight with unverified bytes.
  bool get canAutoSubmit =>
      !hasUnboundActor &&
      !isReadOnlyQuarantined &&
      !hasWaitingOriginalActorMarker &&
      recoveryCode != DraftRecoveryCode.terminalPolicyDenial &&
      submissionStatus != DraftSubmissionStatus.terminalError &&
      dispatchState != CommandDispatchState.unknownLegacy &&
      dispatchState != CommandDispatchState.confirmedCommitted;

  /// Returns whether this draft has core lifecycle/lease/recovery state that
  /// must block deletion even before comparing concurrent metadata snapshots.
  bool hasCoreUnsafeDeletionState({DateTime? now}) {
    return hasActiveLease(now: now) ||
        leaseToken != null ||
        leaseExpiresAt != null ||
        hasMalformedLease ||
        hasUnboundActor ||
        isLegacyUnknown ||
        isReadOnlyQuarantined ||
        dispatchState != CommandDispatchState.neverDispatched ||
        submissionStatus != DraftSubmissionStatus.draft ||
        hasRecoveryMarker;
  }

  /// Returns whether this draft is in an unsafe state that forbids local deletion.
  ///
  /// Fails closed on active, expired, or malformed leases, missing actor
  /// provenance, unknown legacy rows, non-draft submission stages,
  /// non-neverDispatched states, frozen canonical snapshots, persisted server
  /// IDs, or Slice 4B-1 recovery/quarantine markers.
  bool isUnsafeToDelete({DateTime? now}) {
    return hasCoreUnsafeDeletionState(now: now) ||
        (serverAssessmentId != null && serverAssessmentId!.isNotEmpty) ||
        (serverEvidenceId != null && serverEvidenceId!.isNotEmpty) ||
        (localCompressedPhotoPath != null &&
            localCompressedPhotoPath!.isNotEmpty) ||
        (sha256Checksum != null && sha256Checksum!.isNotEmpty);
  }

  /// Returns a user-friendly diagnostic reason why this draft cannot currently be deleted.
  String? deletionBlockedReason({DateTime? now}) {
    if (!isUnsafeToDelete(now: now)) return null;

    if (isLegacyUnknown) {
      return 'This draft was migrated from a previous version and requires recovery reconciliation before it can be deleted.';
    }
    if (hasMalformedLease) {
      return 'This draft has malformed lease metadata and is quarantined until recovery reconciliation.';
    }
    if (hasActiveLease(now: now)) {
      return 'This draft is currently being processed under an active lease.';
    }
    if (leaseToken != null || leaseExpiresAt != null) {
      return 'This draft holds unreleased lease metadata and requires recovery reconciliation before deletion.';
    }
    if (hasUnboundActor) {
      return 'This draft is missing original author provenance and is quarantined until recovery reconciliation.';
    }
    if (hasWaitingOriginalActorMarker) {
      return 'This draft is paused waiting for the original author session before it can be modified or deleted.';
    }
    if (dispatchState == CommandDispatchState.confirmedCommitted) {
      return 'This draft has already been confirmed committed on the server.';
    }
    if (dispatchState == CommandDispatchState.possiblyDispatched) {
      return 'This draft has an in-flight server command and cannot be deleted until the outcome is confirmed.';
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
    if (submissionStatus == DraftSubmissionStatus.terminalError ||
        hasRecoveryMarker) {
      return 'This draft is in a quarantined recovery state and cannot be deleted automatically.';
    }
    if ((serverAssessmentId != null && serverAssessmentId!.isNotEmpty) ||
        (serverEvidenceId != null && serverEvidenceId!.isNotEmpty)) {
      return 'This draft references persisted server records and cannot be deleted locally.';
    }
    if ((localCompressedPhotoPath != null &&
            localCompressedPhotoPath!.isNotEmpty) ||
        (sha256Checksum != null && sha256Checksum!.isNotEmpty)) {
      return 'This draft has frozen canonical evidence metadata that must be preserved.';
    }
    return 'This draft is in an unsafe state and cannot be deleted.';
  }

  /// Returns whether this draft has substantive content or state differences
  /// compared to [other] that would represent a concurrent modification conflict.
  ///
  /// Fails closed if ANY durable identity, ownership, command, evidence, or
  /// recovery field diverged while deletion confirmation was pending, even if
  /// [updatedAt] was not modified.
  bool hasConflictWith(LocalAssessmentDraft other) =>
      !matchesPersistedRowForCas(other, secondPrecisionTimestamps: false);

  /// Compares all 30 persisted columns for exact CAS equality.
  ///
  /// Set [secondPrecisionTimestamps] to `true` when matching against SQLite Drift
  /// `DateTimeColumn` values, which persist whole UTC seconds by default.
  bool matchesPersistedRowForCas(
    LocalAssessmentDraft other, {
    bool secondPrecisionTimestamps = false,
  }) {
    return localDraftId == other.localDraftId &&
        familyId == other.familyId &&
        childId == other.childId &&
        createCommandId == other.createCommandId &&
        submitCommandId == other.submitCommandId &&
        evidenceId == other.evidenceId &&
        serverAssessmentId == other.serverAssessmentId &&
        subjectKey == other.subjectKey &&
        subject == other.subject &&
        title == other.title &&
        assessmentType == other.assessmentType &&
        difficulty == other.difficulty &&
        rawScore == other.rawScore &&
        maxScore == other.maxScore &&
        localPhotoPath == other.localPhotoPath &&
        entryContext == other.entryContext &&
        _nullableDateTimeEquals(
          occurredAt,
          other.occurredAt,
          secondPrecision: secondPrecisionTimestamps,
        ) &&
        _nullableDateTimeEquals(
          updatedAt,
          other.updatedAt,
          secondPrecision: secondPrecisionTimestamps,
        ) &&
        serverEvidenceId == other.serverEvidenceId &&
        sha256Checksum == other.sha256Checksum &&
        localCompressedPhotoPath == other.localCompressedPhotoPath &&
        submissionStatus == other.submissionStatus &&
        retryCount == other.retryCount &&
        dispatchState == other.dispatchState &&
        lastErrorMessage == other.lastErrorMessage &&
        actorUserId == other.actorUserId &&
        actorRole == other.actorRole &&
        _nullableDateTimeEquals(
          nextAttemptAt,
          other.nextAttemptAt,
          secondPrecision: secondPrecisionTimestamps,
        ) &&
        leaseToken == other.leaseToken &&
        _nullableDateTimeEquals(
          leaseExpiresAt,
          other.leaseExpiresAt,
          secondPrecision: secondPrecisionTimestamps,
        );
  }

  static bool _nullableDateTimeEquals(
    DateTime? a,
    DateTime? b, {
    bool secondPrecision = false,
  }) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (!secondPrecision) {
      return a.isAtSameMomentAs(b);
    }
    return (a.toUtc().millisecondsSinceEpoch ~/ 1000) ==
        (b.toUtc().millisecondsSinceEpoch ~/ 1000);
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

/// Thrown when `saveLocalDraft` or `deleteLocalDraft` violates active lease,
/// frozen snapshot, committed/quarantined state, or immutable identity guards.
final class DraftWriteConflictException implements Exception {
  const DraftWriteConflictException({
    required this.localDraftId,
    required this.code,
    required this.message,
  });

  final String localDraftId;
  final String code;
  final String message;

  @override
  String toString() =>
      'DraftWriteConflictException($code, draftId: $localDraftId): $message';
}

/// Typed status outcomes for Slice 4B-1 atomic CAS and lease operations on [LocalDraftStore].
enum DraftCasStatus {
  succeeded,
  notFound,
  casConflict,
  leaseConflict,
  actorMismatch,
  familyOrChildMismatch,
  blockedQuarantined,
  alreadyCommitted,
  invalidInput,
}

/// Result of an atomic CAS or lease-fenced mutation on [LocalDraftStore].
final class DraftCasResult {
  const DraftCasResult({required this.status, this.draft, this.reason});

  final DraftCasStatus status;
  final LocalAssessmentDraft? draft;
  final String? reason;

  bool get isSuccess => status == DraftCasStatus.succeeded;

  @override
  String toString() =>
      'DraftCasResult(status: $status, draftId: ${draft?.localDraftId}, reason: $reason)';
}

/// Port for local offline assessment drafts storage.
abstract interface class LocalDraftStore {
  /// Saves or updates a local draft (hardened legacy compatibility method).
  Future<void> saveLocalDraft(LocalAssessmentDraft draft);

  /// Retrieves a specific local draft by its stable local id.
  Future<LocalAssessmentDraft?> getLocalDraft(String localDraftId);

  /// Lists all local drafts for a given child.
  Future<List<LocalAssessmentDraft>> listLocalDrafts(ChildId childId);

  /// Deletes a local draft after successful server submission when unleased and
  /// unquarantined.
  Future<void> deleteLocalDraft(String localDraftId);

  /// Atomically and safely deletes [localDraftId] only after revalidating that its
  /// current persisted state matches [expectedDraft] and is safe for deletion.
  ///
  /// Rejects deletion if the draft is quarantined (unknown legacy), in-flight
  /// (possibly dispatched or confirmed committed), has an active lease, has frozen
  /// canonical snapshots/server IDs, or is currently undergoing submission or evidence upload.
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

  /// Atomically inserts a new pre-dispatch draft ([expected] == `null`) or
  /// updates an existing unleased `neverDispatched` draft ([expected] != `null`)
  /// using full-column CAS verification and actor binding.
  Future<DraftCasResult> registerOrUpdateDraftIfUnchanged({
    required LocalAssessmentDraft? expected,
    required LocalAssessmentDraft desired,
    DateTime? now,
  });

  /// Atomically acquires a lease claim on an unclaimed, eligible draft belonging
  /// to [actorUserId], [familyId], and [childId].
  Future<DraftCasResult> acquireDraftClaim({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    DateTime? now,
    String? overrideLeaseToken,
    bool ignoreRetryBackoff = false,
  });

  /// Atomically reclaims a draft whose existing lease has expired and rotates
  /// to a new unique lease token.
  Future<DraftCasResult> resumeDraftClaimAfterExpiry({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    required DateTime now,
    String? overrideLeaseToken,
    bool ignoreRetryBackoff = false,
  });

  /// Lease-fenced stage transition marking the draft `possiblyDispatched`
  /// before network execution.
  Future<DraftCasResult> markDraftStageAndDispatch({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DraftSubmissionStatus targetStage,
    required DateTime now,
  });

  /// Lease-fenced persistence of server-assigned `assessments.id`.
  Future<DraftCasResult> persistServerAssessmentId({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
  });

  /// Lease-fenced persistence of server-assigned `assessment_evidence.id`,
  /// fenced on expected `evidenceId` and `sha256Checksum` without requiring
  /// server row ID equality with client `evidenceId`.
  Future<DraftCasResult> persistServerEvidenceId({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverEvidenceId,
    required String expectedEvidenceId,
    required String expectedSha256Checksum,
    required DateTime now,
  });

  /// Lease-fenced retry scheduling that increments `retryCount`, stores a
  /// sanitized `LW4B1:RETRY_SCHEDULED` envelope, and releases the active lease.
  Future<DraftCasResult> scheduleDraftRetry({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DateTime nextAttemptAt,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  });

  /// Lease-fenced quarantine transition that persists `terminalError` and a
  /// sanitized `LW4B1:` marker without deleting or rotating draft identity or
  /// canonical evidence bytes.
  Future<DraftCasResult> quarantineDraftOutcome({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  });

  /// Lease-fenced completion marking the draft `confirmedCommitted` and
  /// clearing lease/error state while preserving evidence paths and server IDs.
  Future<DraftCasResult> completeDraftSubmission({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
    String? serverEvidenceId,
  });

  /// Lease-fenced release of an active claim without marking retry/error.
  Future<DraftCasResult> releaseDraftClaim({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    DateTime? now,
  });

  /// Pauses a draft under `LW4B1:WAITING_ORIGINAL_ACTOR` when the active session
  /// switched away from `actorUserId`, preserving all IDs and canonical bytes.
  Future<DraftCasResult> pauseMismatchedActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  });

  /// Resumes a paused draft back from `LW4B1:WAITING_ORIGINAL_ACTOR` when the
  /// original author re-authenticates.
  Future<DraftCasResult> resumeOriginalActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  });
}
