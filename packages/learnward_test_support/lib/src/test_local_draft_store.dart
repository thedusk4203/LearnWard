import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Shared in-memory [LocalDraftStore] for unit, parity, and crash-simulation tests.
///
/// Mirrors [AppDatabase] Slice 4B-1 CAS, lease-fencing, fail-closed wire status
/// decoding, and legacy compatibility rules via shared evaluators in `learnward_application`.
final class TestLocalDraftStore implements LocalDraftStore {
  final Map<String, LocalAssessmentDraft> drafts = {};
  final Map<String, String> _rawSubmissionStatuses = {};

  /// Optional async hook invoked right before persisting in [saveLocalDraft].
  Future<void> Function(LocalAssessmentDraft draft)? onSaveLocalDraft;

  /// Optional async hook invoked inside [markDraftStageAndDispatch] after applying the stage change.
  Future<void> Function(String localDraftId, DraftCasResult result)?
  onMarkDraftStageAndDispatch;

  /// Optional test overrides that return a simulated [DraftCasResult] (or throw) before mutating state.
  Future<DraftCasResult?> Function(
    LocalAssessmentDraft? expected,
    LocalAssessmentDraft desired,
  )?
  onRegisterOrUpdateDraftIfUnchangedOverride;
  Future<DraftCasResult?> Function(String localDraftId)?
  onAcquireDraftClaimOverride;
  Future<DraftCasResult?> Function(
    String localDraftId,
    DraftSubmissionStatus targetStage,
  )?
  onMarkDraftStageOverride;
  Future<DraftCasResult?> Function(
    String localDraftId,
    String serverAssessmentId,
  )?
  onPersistServerAssessmentIdOverride;
  Future<DraftCasResult?> Function(
    String localDraftId,
    String serverEvidenceId,
  )?
  onPersistServerEvidenceIdOverride;
  Future<DraftCasResult?> Function(
    String localDraftId,
    String serverAssessmentId,
  )?
  onCompleteDraftSubmissionOverride;
  Future<DraftCasResult?> Function(String localDraftId)?
  onReleaseDraftClaimOverride;

  int deleteLocalDraftCallCount = 0;

  /// Seeds a raw draft bypassing [saveLocalDraft] validation for malformed-state tests.
  void seedRawDraft(LocalAssessmentDraft draft, {String? rawSubmissionStatus}) {
    drafts[draft.localDraftId] = draft;
    if (rawSubmissionStatus != null) {
      _rawSubmissionStatuses[draft.localDraftId] = rawSubmissionStatus;
    } else {
      _rawSubmissionStatuses.remove(draft.localDraftId);
    }
  }

  /// Returns the raw persisted submission status string without fail-closed decoding.
  String? rawPersistedSubmissionStatus(String localDraftId) {
    return _rawSubmissionStatuses[localDraftId] ??
        drafts[localDraftId]?.submissionStatus.wireValue;
  }

  LocalAssessmentDraft? _decodeDraft(String localDraftId) {
    final stored = drafts[localDraftId];
    if (stored == null) return null;
    final rawStatus = _rawSubmissionStatuses[localDraftId];
    if (rawStatus == null) return stored;
    final parsed = DraftSubmissionStatus.tryFromString(rawStatus);
    if (parsed != null) return stored;
    return stored.copyWith(
      submissionStatus: DraftSubmissionStatus.terminalError,
      lastErrorMessage: DraftRecoveryCode.format(
        DraftRecoveryCode.unknownWireStatus,
        rawStatus.isEmpty ? '<empty>' : rawStatus,
      ),
    );
  }

  DraftCasResult _applyCas(
    String localDraftId,
    DraftCasResult Function(LocalAssessmentDraft? current) evaluate,
  ) {
    final current = _decodeDraft(localDraftId);
    final result = evaluate(current);
    if (result.isSuccess && result.draft != null) {
      drafts[result.draft!.localDraftId] = result.draft!;
      _rawSubmissionStatuses.remove(result.draft!.localDraftId);
    }
    return result;
  }

  @override
  Future<void> saveLocalDraft(LocalAssessmentDraft draft) async {
    await onSaveLocalDraft?.call(draft);
    final existing = _decodeDraft(draft.localDraftId);
    validateLegacySaveLocalDraft(existing: existing, desired: draft);
    drafts[draft.localDraftId] = draft;
    _rawSubmissionStatuses.remove(draft.localDraftId);
  }

  @override
  Future<LocalAssessmentDraft?> getLocalDraft(String localDraftId) async {
    return _decodeDraft(localDraftId);
  }

  @override
  Future<List<LocalAssessmentDraft>> listLocalDrafts(ChildId childId) async {
    final list = drafts.values
        .where((d) => d.childId == childId.value)
        .map((d) => _decodeDraft(d.localDraftId)!)
        .toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Future<void> deleteLocalDraft(String localDraftId) async {
    deleteLocalDraftCallCount++;
    final existing = _decodeDraft(localDraftId);
    if (existing == null) return;
    validateRawLocalDraftDelete(existing);
    drafts.remove(localDraftId);
    _rawSubmissionStatuses.remove(localDraftId);
  }

  @override
  Future<DraftDeletionOutcome> deleteDraftSafely({
    required String localDraftId,
    required LocalAssessmentDraft expectedDraft,
    DateTime? now,
  }) async {
    final current = _decodeDraft(localDraftId);
    final blockedOutcome = evaluateDeleteDraftSafelyPreconditions(
      localDraftId: localDraftId,
      current: current,
      expectedDraft: expectedDraft,
      now: now,
    );
    if (blockedOutcome != null) {
      return blockedOutcome;
    }
    drafts.remove(localDraftId);
    _rawSubmissionStatuses.remove(localDraftId);
    return DraftDeletionOutcome(
      status: DraftDeletionStatus.deleted,
      localDraftId: localDraftId,
    );
  }

  @override
  Future<bool> hasDraftReferenceToFile(String filePath) async {
    return drafts.values.any(
      (d) =>
          d.localPhotoPath == filePath ||
          d.localCompressedPhotoPath == filePath,
    );
  }

  @override
  Future<int> countDraftReferencesToFile(String filePath) async {
    return drafts.values
        .where(
          (d) =>
              d.localPhotoPath == filePath ||
              d.localCompressedPhotoPath == filePath,
        )
        .length;
  }

  @override
  Future<DraftCasResult> registerOrUpdateDraftIfUnchanged({
    required LocalAssessmentDraft? expected,
    required LocalAssessmentDraft desired,
    DateTime? now,
  }) async {
    final override = await onRegisterOrUpdateDraftIfUnchangedOverride?.call(
      expected,
      desired,
    );
    if (override != null) return override;
    return _applyCas(
      desired.localDraftId,
      (current) => evaluateDraftRegistrationCas(
        existing: current,
        expected: expected,
        desired: desired,
        now: now,
      ),
    );
  }

  @override
  Future<DraftCasResult> acquireDraftClaim({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    DateTime? now,
    String? overrideLeaseToken,
    bool ignoreRetryBackoff = false,
  }) async {
    final override = await onAcquireDraftClaimOverride?.call(localDraftId);
    if (override != null) return override;
    return _applyCas(
      localDraftId,
      (current) => evaluateDraftClaim(
        existing: current,
        localDraftId: localDraftId,
        actorUserId: actorUserId,
        familyId: familyId,
        childId: childId,
        leaseDuration: leaseDuration,
        expectingExpiredLease: false,
        now: now,
        overrideLeaseToken: overrideLeaseToken,
        ignoreRetryBackoff: ignoreRetryBackoff,
      ),
    );
  }

  @override
  Future<DraftCasResult> resumeDraftClaimAfterExpiry({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required Duration leaseDuration,
    required DateTime now,
    String? overrideLeaseToken,
    bool ignoreRetryBackoff = false,
  }) async => _applyCas(
    localDraftId,
    (current) => evaluateDraftClaim(
      existing: current,
      localDraftId: localDraftId,
      actorUserId: actorUserId,
      familyId: familyId,
      childId: childId,
      leaseDuration: leaseDuration,
      expectingExpiredLease: true,
      now: now,
      overrideLeaseToken: overrideLeaseToken,
      ignoreRetryBackoff: ignoreRetryBackoff,
    ),
  );

  @override
  Future<DraftCasResult> markDraftStageAndDispatch({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DraftSubmissionStatus targetStage,
    required DateTime now,
  }) async {
    final override = await onMarkDraftStageOverride?.call(
      localDraftId,
      targetStage,
    );
    if (override != null) return override;
    final result = _applyCas(
      localDraftId,
      (current) => evaluateMarkDraftStageAndDispatch(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        targetStage: targetStage,
        now: now,
      ),
    );
    await onMarkDraftStageAndDispatch?.call(localDraftId, result);
    return result;
  }

  @override
  Future<DraftCasResult> persistServerAssessmentId({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
  }) async {
    final override = await onPersistServerAssessmentIdOverride?.call(
      localDraftId,
      serverAssessmentId,
    );
    if (override != null) return override;
    return _applyCas(
      localDraftId,
      (current) => evaluatePersistServerAssessmentId(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        serverAssessmentId: serverAssessmentId,
        now: now,
      ),
    );
  }

  @override
  Future<DraftCasResult> persistServerEvidenceId({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverEvidenceId,
    required String expectedEvidenceId,
    required String expectedSha256Checksum,
    required DateTime now,
  }) async {
    final override = await onPersistServerEvidenceIdOverride?.call(
      localDraftId,
      serverEvidenceId,
    );
    if (override != null) return override;
    return _applyCas(
      localDraftId,
      (current) => evaluatePersistServerEvidenceId(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        serverEvidenceId: serverEvidenceId,
        expectedEvidenceId: expectedEvidenceId,
        expectedSha256Checksum: expectedSha256Checksum,
        now: now,
      ),
    );
  }

  @override
  Future<DraftCasResult> scheduleDraftRetry({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required DateTime nextAttemptAt,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  }) async => _applyCas(
    localDraftId,
    (current) => evaluateScheduleDraftRetry(
      existing: current,
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      nextAttemptAt: nextAttemptAt,
      recoveryCode: recoveryCode,
      errorMessage: errorMessage,
      now: now,
    ),
  );

  @override
  Future<DraftCasResult> quarantineDraftOutcome({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String recoveryCode,
    required String errorMessage,
    DateTime? now,
  }) async => _applyCas(
    localDraftId,
    (current) => evaluateQuarantineDraftOutcome(
      existing: current,
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: authenticatedActorId,
      recoveryCode: recoveryCode,
      errorMessage: errorMessage,
      now: now,
    ),
  );

  @override
  Future<DraftCasResult> completeDraftSubmission({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    required String serverAssessmentId,
    required DateTime now,
    String? serverEvidenceId,
  }) async {
    final override = await onCompleteDraftSubmissionOverride?.call(
      localDraftId,
      serverAssessmentId,
    );
    if (override != null) return override;
    return _applyCas(
      localDraftId,
      (current) => evaluateCompleteDraftSubmission(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        serverAssessmentId: serverAssessmentId,
        now: now,
        serverEvidenceId: serverEvidenceId,
      ),
    );
  }

  @override
  Future<DraftCasResult> releaseDraftClaim({
    required String localDraftId,
    required String leaseToken,
    required String authenticatedActorId,
    DateTime? now,
  }) async {
    final override = await onReleaseDraftClaimOverride?.call(localDraftId);
    if (override != null) return override;
    return _applyCas(
      localDraftId,
      (current) => evaluateReleaseDraftClaim(
        existing: current,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        now: now,
      ),
    );
  }

  @override
  Future<DraftCasResult> pauseMismatchedActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  }) async => _applyCas(
    localDraftId,
    (current) => evaluatePauseMismatchedActorDraft(
      existing: current,
      localDraftId: localDraftId,
      familyId: familyId,
      authenticatedActorId: authenticatedActorId,
      mismatchReason: mismatchReason,
      now: now,
    ),
  );

  @override
  Future<DraftCasResult> resumeOriginalActorDraft({
    required String localDraftId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  }) async => _applyCas(
    localDraftId,
    (current) => evaluateResumeOriginalActorDraft(
      existing: current,
      localDraftId: localDraftId,
      familyId: familyId,
      authenticatedActorId: authenticatedActorId,
      now: now,
    ),
  );
}
