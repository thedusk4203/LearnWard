import 'dart:math';

import 'package:learnward_domain/learnward_domain.dart';

import 'assessment_evidence_storage.dart';
import 'canonical_evidence_snapshot.dart';
import 'command_lifecycle_states.dart';
import 'local_draft_store.dart';

/// Shared precondition evaluator for `LocalDraftStore.deleteDraftSafely`.
/// Returns `null` when [current] passed all safety and CAS checks and may be deleted.
DraftDeletionOutcome? evaluateDeleteDraftSafelyPreconditions({
  required String localDraftId,
  required LocalAssessmentDraft? current,
  required LocalAssessmentDraft expectedDraft,
  DateTime? now,
}) {
  if (current == null) {
    return DraftDeletionOutcome(
      status: DraftDeletionStatus.notFound,
      localDraftId: localDraftId,
      reason: 'Draft not found in local store.',
    );
  }
  if (current.hasCoreUnsafeDeletionState(now: now)) {
    return DraftDeletionOutcome(
      status: DraftDeletionStatus.blockedUnsafeState,
      localDraftId: localDraftId,
      reason: current.deletionBlockedReason(now: now),
      currentDraft: current,
    );
  }
  if (current.hasConflictWith(expectedDraft)) {
    return DraftDeletionOutcome(
      status: DraftDeletionStatus.concurrencyConflict,
      localDraftId: localDraftId,
      reason: 'Draft was modified while deletion was being confirmed.',
      currentDraft: current,
    );
  }
  if (current.isUnsafeToDelete(now: now)) {
    return DraftDeletionOutcome(
      status: DraftDeletionStatus.blockedUnsafeState,
      localDraftId: localDraftId,
      reason: current.deletionBlockedReason(now: now),
      currentDraft: current,
    );
  }
  return null;
}

/// Applies a pure CAS evaluator [evaluate] against an in-memory draft map,
/// storing the resulting draft only on [DraftCasStatus.succeeded].
DraftCasResult applyInMemoryDraftCas(
  Map<String, LocalAssessmentDraft> drafts,
  String localDraftId,
  DraftCasResult Function(LocalAssessmentDraft? current) evaluate,
) {
  final result = evaluate(drafts[localDraftId]);
  if (result.isSuccess && result.draft != null) {
    drafts[result.draft!.localDraftId] = result.draft!;
  }
  return result;
}

/// Cryptographically random UUIDv4 lease token generator shared across SQLite and in-memory stores.
String generateDraftLeaseToken() {
  final random = Random.secure();
  final values = List<int>.generate(16, (i) => random.nextInt(256));
  values[6] = (values[6] & 0x0f) | 0x40;
  values[8] = (values[8] & 0x3f) | 0x80;
  final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
}

/// Normalizes [now] to UTC (defaults to [DateTime.now]).
DateTime normalizeDraftUtcNow(DateTime? now) => (now ?? DateTime.now()).toUtc();

/// Normalizes an assessment occurrence timestamp to UTC whole seconds to match
/// Drift SQLite persistence precision across registration and remote dispatch.
DateTime normalizeAssessmentOccurredAt(DateTime occurredAt) {
  final utc = occurredAt.toUtc();
  final millis = utc.millisecondsSinceEpoch;
  final wholeSeconds = millis >= 0 ? millis ~/ 1000 : (millis - 999) ~/ 1000;
  return DateTime.fromMillisecondsSinceEpoch(wholeSeconds * 1000, isUtc: true);
}

/// Normalizes an assessment subject consistently across draft registration and dispatch.
String normalizeAssessmentSubject(
  String rawSubject, {
  SubjectKey? fallbackSubjectKey,
}) {
  final trimmed = rawSubject.trim();
  if (trimmed.isEmpty && fallbackSubjectKey != null) {
    return fallbackSubjectKey.displayLabel;
  }
  return trimmed;
}

/// Normalizes an assessment title consistently across draft registration and dispatch.
String normalizeAssessmentTitle(String rawTitle, {String? fallbackTitle}) {
  final trimmed = rawTitle.trim();
  if (trimmed.isEmpty && fallbackTitle != null) {
    return fallbackTitle;
  }
  return trimmed;
}

/// Whether a persisted draft's assessment payload (`subjectKey`, `subject`,
/// `title`, `assessmentType`, `difficulty`, `rawScore`, `maxScore`, `occurredAt`,
/// `entryContext`, and evidence) must be treated as immutable in UI/presentation.
bool isDraftPayloadLocked(LocalAssessmentDraft draft, {DateTime? now}) {
  final effectiveNow = normalizeDraftUtcNow(now);
  return draft.dispatchState != CommandDispatchState.neverDispatched ||
      draft.submissionStatus != DraftSubmissionStatus.draft ||
      draft.isReadOnlyQuarantined ||
      draft.isLegacyUnknown ||
      draft.hasRecoveryMarker ||
      draft.hasActiveLease(now: effectiveNow) ||
      draft.leaseToken != null ||
      draft.leaseExpiresAt != null ||
      draft.hasMalformedLease ||
      draft.hasUnboundActor ||
      _hasText(draft.serverAssessmentId) ||
      _hasText(draft.serverEvidenceId);
}

/// Whether [draft] is in a safe state for direct retry/submission in UI,
/// assuming the displayed payload still matches the persisted row identically.
bool isDraftDirectRetryAllowed(LocalAssessmentDraft draft, {DateTime? now}) {
  final effectiveNow = normalizeDraftUtcNow(now);
  if (draft.isLegacyUnknown ||
      draft.hasUnboundActor ||
      draft.isReadOnlyQuarantined ||
      draft.hasMalformedLease) {
    return false;
  }
  if (draft.dispatchState == CommandDispatchState.confirmedCommitted ||
      draft.hasWaitingOriginalActorMarker ||
      draft.submissionStatus == DraftSubmissionStatus.terminalError ||
      (draft.hasRecoveryMarker &&
          draft.recoveryCode != DraftRecoveryCode.retryScheduled) ||
      draft.hasActiveLease(now: effectiveNow)) {
    return false;
  }
  return true;
}

/// Returns whether a string is present and non-empty.
bool _hasText(String? value) => value != null && value.isNotEmpty;

/// Compares optional non-empty immutable strings; permits `null -> value` during
/// legacy WP1 flows while forbidding overwriting or clearing an already-bound value.
bool _mutatedExistingImmutableText(String? existing, String? desired) =>
    _hasText(existing) && desired != existing;

/// Validates `deleteLocalDraft` against ALL unsafe local draft states:
/// active/expired/malformed leases, unbound actor quarantine, legacy unknown,
/// non-draft submission stages, in-flight or committed dispatch states,
/// frozen canonical snapshots, persisted server IDs, and recovery markers.
void validateRawLocalDraftDelete(
  LocalAssessmentDraft existing, {
  DateTime? now,
}) {
  if (existing.hasMalformedLease) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'malformed_lease_delete_blocked',
      message:
          'Cannot delete draft ${existing.localDraftId} with malformed lease metadata.',
    );
  }
  if (existing.leaseToken != null || existing.leaseExpiresAt != null) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'leased_draft_delete_blocked',
      message:
          'Cannot delete draft ${existing.localDraftId} while lease metadata is held.',
    );
  }
  if (existing.hasUnboundActor) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'unbound_actor_delete_blocked',
      message:
          'Cannot delete quarantined draft ${existing.localDraftId} without bound actor provenance.',
    );
  }
  if (existing.isLegacyUnknown) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'legacy_quarantine_delete_blocked',
      message:
          'Cannot delete unknown_legacy draft ${existing.localDraftId} via deleteLocalDraft.',
    );
  }
  if (existing.dispatchState == CommandDispatchState.confirmedCommitted) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'confirmed_committed_delete_blocked',
      message:
          'Cannot delete confirmed_committed draft ${existing.localDraftId}.',
    );
  }
  if (existing.dispatchState != CommandDispatchState.neverDispatched) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'dispatched_draft_delete_blocked',
      message:
          'Cannot delete dispatched draft ${existing.localDraftId} while outcome reconciliation may be needed.',
    );
  }
  if (existing.submissionStatus == DraftSubmissionStatus.terminalError ||
      existing.hasRecoveryMarker ||
      existing.isReadOnlyQuarantined) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'quarantined_draft_delete_blocked',
      message:
          'Cannot delete quarantined or paused draft ${existing.localDraftId}.',
    );
  }
  if (existing.submissionStatus != DraftSubmissionStatus.draft) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'non_draft_stage_delete_blocked',
      message:
          'Cannot delete draft ${existing.localDraftId} in stage ${existing.submissionStatus.wireValue}.',
    );
  }
  if (_hasText(existing.serverAssessmentId) ||
      _hasText(existing.serverEvidenceId)) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'server_linked_delete_blocked',
      message:
          'Cannot delete draft ${existing.localDraftId} with persisted server IDs.',
    );
  }
  if (_hasText(existing.localCompressedPhotoPath) ||
      _hasText(existing.sha256Checksum)) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'frozen_evidence_delete_blocked',
      message:
          'Cannot delete draft ${existing.localDraftId} with frozen canonical evidence.',
    );
  }
  if (existing.isUnsafeToDelete(now: now)) {
    throw DraftWriteConflictException(
      localDraftId: existing.localDraftId,
      code: 'unsafe_draft_delete_blocked',
      message: 'Cannot delete unsafe draft ${existing.localDraftId}.',
    );
  }
}

/// Validates legacy `saveLocalDraft` writes against unbound actor provenance
/// (R33-01), dispatched/in-flight immutability (R33-03), leases, frozen
/// canonical snapshots, server IDs, and quarantine states.
void validateLegacySaveLocalDraft({
  required LocalAssessmentDraft? existing,
  required LocalAssessmentDraft desired,
  DateTime? now,
}) {
  final effectiveNow = normalizeDraftUtcNow(now);

  if (desired.hasMalformedLease) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'malformed_lease',
      message:
          'Cannot save draft ${desired.localDraftId} with partial lease metadata.',
    );
  }
  if (desired.localCompressedPhotoPath != null &&
      desired.localCompressedPhotoPath!.isEmpty) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'empty_canonical_path',
      message:
          'Cannot save draft ${desired.localDraftId} with an empty canonical photo path.',
    );
  }
  if (existing == null) {
    return;
  }

  if (existing.hasMalformedLease) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'existing_malformed_lease',
      message:
          'Cannot overwrite draft ${desired.localDraftId}: existing row has malformed lease metadata.',
    );
  }
  if (existing.leaseToken != null ||
      existing.leaseExpiresAt != null ||
      existing.hasActiveLease(now: effectiveNow)) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'active_lease_conflict',
      message:
          'Cannot overwrite draft ${desired.localDraftId}: lease metadata is currently held.',
    );
  }
  if (existing.hasUnboundActor) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'unbound_actor_immutable',
      message:
          'Cannot overwrite or adopt unbound-actor draft ${desired.localDraftId} via saveLocalDraft.',
    );
  }
  if (existing.isLegacyUnknown) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'legacy_unknown_immutable',
      message:
          'Cannot overwrite unknown_legacy draft ${desired.localDraftId} via saveLocalDraft.',
    );
  }
  if (existing.dispatchState == CommandDispatchState.confirmedCommitted) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'confirmed_committed_immutable',
      message:
          'Cannot overwrite confirmed_committed draft ${desired.localDraftId}.',
    );
  }
  if (existing.submissionStatus == DraftSubmissionStatus.terminalError ||
      existing.hasRecoveryMarker ||
      existing.isReadOnlyQuarantined) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'quarantined_or_paused_immutable',
      message:
          'Cannot overwrite quarantined or paused draft ${desired.localDraftId}.',
    );
  }
  if (existing.dispatchState != CommandDispatchState.neverDispatched ||
      existing.submissionStatus != DraftSubmissionStatus.draft) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'dispatched_or_non_draft_immutable',
      message:
          'Cannot overwrite draft ${desired.localDraftId} via saveLocalDraft once dispatch or submission has started.',
    );
  }
  if (_hasText(existing.localCompressedPhotoPath) ||
      _hasText(existing.sha256Checksum) ||
      _hasText(existing.serverEvidenceId) ||
      _hasText(existing.serverAssessmentId)) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'frozen_evidence_immutable',
      message:
          'Cannot use saveLocalDraft to overwrite draft ${desired.localDraftId} once canonical evidence or server IDs exist.',
    );
  }
  if (desired.hasUnboundActor || desired.actorUserId != existing.actorUserId) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'actor_provenance_immutable',
      message:
          'Cannot clear or change actorUserId on existing draft ${desired.localDraftId}.',
    );
  }
  if (desired.familyId != existing.familyId ||
      desired.childId != existing.childId) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'bound_scope_immutable',
      message:
          'Cannot change familyId or childId on bound draft ${desired.localDraftId}.',
    );
  }
  if (_mutatedExistingImmutableText(existing.actorRole, desired.actorRole) ||
      _mutatedExistingImmutableText(
        existing.createCommandId,
        desired.createCommandId,
      ) ||
      _mutatedExistingImmutableText(
        existing.submitCommandId,
        desired.submitCommandId,
      ) ||
      _mutatedExistingImmutableText(existing.evidenceId, desired.evidenceId)) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'immutable_identity_conflict',
      message:
          'Cannot overwrite immutable identity or command ID on draft ${desired.localDraftId}.',
    );
  }
  if (desired.leaseToken != null ||
      desired.leaseExpiresAt != null ||
      desired.dispatchState != CommandDispatchState.neverDispatched ||
      desired.submissionStatus != DraftSubmissionStatus.draft ||
      desired.hasRecoveryMarker ||
      _hasText(desired.serverAssessmentId) ||
      _hasText(desired.serverEvidenceId) ||
      _hasText(desired.localCompressedPhotoPath) ||
      _hasText(desired.sha256Checksum) ||
      desired.nextAttemptAt != null) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'legacy_lifecycle_transition_forbidden',
      message:
          'Cannot advance lifecycle, lease, snapshot, or server IDs via saveLocalDraft on ${desired.localDraftId}; use CAS draft store operations.',
    );
  }
  if (desired.retryCount < existing.retryCount) {
    throw DraftWriteConflictException(
      localDraftId: desired.localDraftId,
      code: 'retry_count_downgrade_forbidden',
      message: 'Cannot decrement retryCount on draft ${desired.localDraftId}.',
    );
  }
}

/// Evaluates atomic draft creation or pre-dispatch CAS update for
/// [LocalDraftStore.registerOrUpdateDraftIfUnchanged].
DraftCasResult evaluateDraftRegistrationCas({
  required LocalAssessmentDraft? existing,
  required LocalAssessmentDraft? expected,
  required LocalAssessmentDraft desired,
  bool secondPrecisionTimestamps = false,
  DateTime? now,
}) {
  final effectiveNow = normalizeDraftUtcNow(now);

  if (!_hasText(desired.localDraftId) ||
      !_hasText(desired.familyId) ||
      !_hasText(desired.childId)) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'Draft registration requires non-empty localDraftId, familyId, and childId.',
    );
  }
  if (desired.hasUnboundActor) {
    return DraftCasResult(
      status: DraftCasStatus.actorMismatch,
      draft: existing,
      reason: 'Draft registration requires an authenticated actorUserId.',
    );
  }
  if (!_hasText(desired.createCommandId) ||
      !_hasText(desired.submitCommandId)) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'Draft registration requires stable createCommandId and submitCommandId.',
    );
  }
  if (desired.hasMalformedLease ||
      desired.leaseToken != null ||
      desired.leaseExpiresAt != null) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'Pre-dispatch draft registration/update must not carry lease metadata.',
    );
  }
  if (desired.dispatchState != CommandDispatchState.neverDispatched ||
      desired.submissionStatus != DraftSubmissionStatus.draft ||
      desired.hasRecoveryMarker) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'Pre-dispatch draft registration/update requires neverDispatched and draft status without LW4B1 markers.',
    );
  }

  final hasAnySnapshotField =
      desired.localCompressedPhotoPath != null ||
      desired.sha256Checksum != null;
  if (hasAnySnapshotField) {
    if (!_hasText(desired.localCompressedPhotoPath) ||
        !isValidSha256Hex(desired.sha256Checksum) ||
        !_hasText(desired.evidenceId)) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: existing,
        reason: 'Canonical evidence metadata requires non-empty localCompressedPhotoPath, valid 64-char lowercase sha256Checksum, and non-empty evidenceId.',
      );
    }
  }

  final sanitizedDesired = desired.copyWith(
    occurredAt: desired.occurredAt.toUtc(),
    updatedAt: desired.updatedAt.toUtc(),
    nextAttemptAt: desired.nextAttemptAt?.toUtc(),
    leaseToken: null,
    leaseExpiresAt: null,
  );

  if (expected == null) {
    if (existing != null) {
      return DraftCasResult(
        status: DraftCasStatus.casConflict,
        draft: existing,
        reason:
            'Draft ${desired.localDraftId} already exists; fresh registration rejected.',
      );
    }
    if (_hasText(desired.serverAssessmentId) ||
        _hasText(desired.serverEvidenceId)) {
      return const DraftCasResult(
        status: DraftCasStatus.invalidInput,
        reason: 'Fresh draft registration cannot preset serverAssessmentId or serverEvidenceId.',
      );
    }
    return DraftCasResult(
      status: DraftCasStatus.succeeded,
      draft: sanitizedDesired,
    );
  }

  if (existing == null) {
    return DraftCasResult(
      status: DraftCasStatus.notFound,
      reason: 'Draft ${desired.localDraftId} was not found for CAS update.',
    );
  }

  final blocked = _checkMutablePreDispatchEligibility(
    existing: existing,
    authenticatedActorId: desired.actorUserId!,
    familyId: desired.familyId,
    childId: desired.childId,
    now: effectiveNow,
  );
  if (blocked != null) {
    return blocked;
  }

  if (!existing.matchesPersistedRowForCas(
    expected,
    secondPrecisionTimestamps: secondPrecisionTimestamps,
  )) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: existing,
      reason:
          'Draft ${desired.localDraftId} changed concurrently before CAS update.',
    );
  }

  if (desired.localDraftId != existing.localDraftId ||
      desired.familyId != existing.familyId ||
      desired.childId != existing.childId ||
      desired.actorUserId != existing.actorUserId ||
      _mutatedExistingImmutableText(
        existing.createCommandId,
        desired.createCommandId,
      ) ||
      _mutatedExistingImmutableText(
        existing.submitCommandId,
        desired.submitCommandId,
      ) ||
      desired.serverAssessmentId != existing.serverAssessmentId ||
      desired.serverEvidenceId != existing.serverEvidenceId) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: existing,
      reason: 'Pre-dispatch CAS update cannot alter immutable draft, actor, command, or server IDs.',
    );
  }
  if (_hasText(existing.evidenceId) &&
      desired.evidenceId != existing.evidenceId) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: existing,
      reason: 'Cannot rotate or clear already-bound evidenceId during pre-dispatch CAS update.',
    );
  }
  if (existing.hasVerifiedEvidenceSnapshot &&
      (desired.localCompressedPhotoPath != existing.localCompressedPhotoPath ||
          desired.sha256Checksum != existing.sha256Checksum)) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: existing,
      reason: 'Cannot overwrite or clear frozen canonical snapshot path/checksum during pre-dispatch CAS update.',
    );
  }

  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: sanitizedDesired,
  );
}

DraftCasResult? _checkMutablePreDispatchEligibility({
  required LocalAssessmentDraft existing,
  required String authenticatedActorId,
  required String familyId,
  required String childId,
  required DateTime now,
}) {
  if (existing.dispatchState == CommandDispatchState.confirmedCommitted &&
      !existing.isReadOnlyQuarantined) {
    return DraftCasResult(
      status: DraftCasStatus.alreadyCommitted,
      draft: existing,
      reason: 'Draft is already confirmedCommitted.',
    );
  }
  if (existing.hasMalformedLease ||
      existing.isReadOnlyQuarantined ||
      existing.submissionStatus == DraftSubmissionStatus.terminalError) {
    return DraftCasResult(
      status: DraftCasStatus.blockedQuarantined,
      draft: existing,
      reason:
          'Draft is quarantined (${existing.derivedQuarantineCode ?? existing.recoveryCode ?? 'terminal_error'}).',
    );
  }
  if (existing.hasWaitingOriginalActorMarker) {
    return DraftCasResult(
      status: DraftCasStatus.blockedQuarantined,
      draft: existing,
      reason: 'Draft is paused waiting for the original actor.',
    );
  }
  if (existing.actorUserId != authenticatedActorId) {
    return DraftCasResult(
      status: DraftCasStatus.actorMismatch,
      draft: existing,
      reason: 'Authenticated actor does not match original draft actor.',
    );
  }
  if (existing.familyId != familyId || existing.childId != childId) {
    return DraftCasResult(
      status: DraftCasStatus.familyOrChildMismatch,
      draft: existing,
      reason: 'Draft familyId/childId scope mismatch.',
    );
  }
  if (existing.hasActiveLease(now: now) || existing.leaseToken != null) {
    return DraftCasResult(
      status: DraftCasStatus.leaseConflict,
      draft: existing,
      reason: 'Draft currently holds lease metadata.',
    );
  }
  if (existing.dispatchState != CommandDispatchState.neverDispatched ||
      existing.submissionStatus != DraftSubmissionStatus.draft) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: existing,
      reason: 'Draft is no longer in pre-dispatch editable state.',
    );
  }
  return null;
}

/// Shared eligibility check for claim/expiry-reclamation; returns `null` when eligible.
DraftCasResult? _checkDraftClaimPreconditions({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String actorUserId,
  required String familyId,
  required String childId,
  required DateTime effectiveNow,
  required bool expectingExpiredLease,
  String? overrideLeaseToken,
  bool ignoreRetryBackoff = false,
}) {
  if (existing == null) {
    return DraftCasResult(
      status: DraftCasStatus.notFound,
      reason: 'Draft $localDraftId was not found.',
    );
  }
  if (existing.hasMalformedLease ||
      existing.isReadOnlyQuarantined ||
      existing.submissionStatus == DraftSubmissionStatus.terminalError ||
      existing.hasWaitingOriginalActorMarker ||
      (existing.recoveryCode != null &&
          existing.recoveryCode != DraftRecoveryCode.retryScheduled)) {
    return DraftCasResult(
      status: DraftCasStatus.blockedQuarantined,
      draft: existing,
      reason:
          'Draft $localDraftId is blocked in ${existing.derivedQuarantineCode ?? existing.recoveryCode ?? 'terminal_error'}.',
    );
  }
  if (existing.dispatchState == CommandDispatchState.confirmedCommitted) {
    return DraftCasResult(
      status: DraftCasStatus.alreadyCommitted,
      draft: existing,
      reason: 'Draft $localDraftId is already confirmedCommitted.',
    );
  }
  if (existing.actorUserId != actorUserId) {
    return DraftCasResult(
      status: DraftCasStatus.actorMismatch,
      draft: existing,
      reason: 'Draft $localDraftId belongs to a different actor.',
    );
  }
  if (existing.familyId != familyId || existing.childId != childId) {
    return DraftCasResult(
      status: DraftCasStatus.familyOrChildMismatch,
      draft: existing,
      reason:
          'Draft $localDraftId does not belong to the specified family/child.',
    );
  }
  if (expectingExpiredLease) {
    if (existing.leaseToken == null || existing.leaseExpiresAt == null) {
      return DraftCasResult(
        status: DraftCasStatus.leaseConflict,
        draft: existing,
        reason:
            'Draft $localDraftId has no expired lease to resume; acquire a fresh claim.',
      );
    }
    if (existing.hasActiveLease(now: effectiveNow)) {
      return DraftCasResult(
        status: DraftCasStatus.leaseConflict,
        draft: existing,
        reason: 'Draft $localDraftId still holds an active unexpired lease.',
      );
    }
    if (overrideLeaseToken != null &&
        overrideLeaseToken == existing.leaseToken) {
      return DraftCasResult(
        status: DraftCasStatus.invalidInput,
        draft: existing,
        reason: 'Resumed lease token must rotate to a new unique token.',
      );
    }
  } else if (existing.leaseToken != null || existing.leaseExpiresAt != null) {
    return DraftCasResult(
      status: DraftCasStatus.leaseConflict,
      draft: existing,
      reason: existing.hasActiveLease(now: effectiveNow)
          ? 'Draft $localDraftId is currently claimed under an active lease.'
          : 'Draft $localDraftId holds an expired lease; use resumeDraftClaimAfterExpiry.',
    );
  }
  if (!ignoreRetryBackoff &&
      (existing.submissionStatus == DraftSubmissionStatus.failedRetryable ||
          existing.recoveryCode == DraftRecoveryCode.retryScheduled) &&
      existing.nextAttemptAt != null &&
      existing.nextAttemptAt!.isAfter(effectiveNow)) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: existing,
      reason:
          'Draft $localDraftId retry backoff is scheduled until ${existing.nextAttemptAt!.toUtc().toIso8601String()}.',
    );
  }
  return null;
}

/// Shared diagnosis helper when an atomic SQLite claim/reclaim `UPDATE` matched 0 rows.
DraftCasResult diagnoseDraftClaimFailure({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String actorUserId,
  required String familyId,
  required String childId,
  required DateTime effectiveNow,
  required bool expectingExpiredLease,
  String? existingLeaseToken,
  bool ignoreRetryBackoff = false,
}) {
  return _checkDraftClaimPreconditions(
        existing: existing,
        localDraftId: localDraftId,
        actorUserId: actorUserId,
        familyId: familyId,
        childId: childId,
        effectiveNow: effectiveNow,
        expectingExpiredLease: expectingExpiredLease,
        overrideLeaseToken: existingLeaseToken,
        ignoreRetryBackoff: ignoreRetryBackoff,
      ) ??
      DraftCasResult(
        status: DraftCasStatus.casConflict,
        draft: existing,
        reason:
            'Draft $localDraftId is not currently eligible for claim acquisition.',
      );
}

/// Evaluates `acquireDraftClaim` or `resumeDraftClaimAfterExpiry` on an in-memory draft.
DraftCasResult evaluateDraftClaim({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String actorUserId,
  required String familyId,
  required String childId,
  required Duration leaseDuration,
  required bool expectingExpiredLease,
  DateTime? now,
  String? overrideLeaseToken,
  bool ignoreRetryBackoff = false,
}) {
  if (!_hasText(actorUserId) ||
      !_hasText(familyId) ||
      !_hasText(childId) ||
      leaseDuration <= Duration.zero) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'Claim requires non-empty actorUserId, familyId, childId, and positive leaseDuration.',
    );
  }
  if (overrideLeaseToken != null && overrideLeaseToken.isEmpty) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'overrideLeaseToken cannot be empty.',
    );
  }

  final effectiveNow = normalizeDraftUtcNow(now);
  final failure = _checkDraftClaimPreconditions(
    existing: existing,
    localDraftId: localDraftId,
    actorUserId: actorUserId,
    familyId: familyId,
    childId: childId,
    effectiveNow: effectiveNow,
    expectingExpiredLease: expectingExpiredLease,
    overrideLeaseToken: overrideLeaseToken,
    ignoreRetryBackoff: ignoreRetryBackoff,
  );
  if (failure != null) {
    return failure;
  }

  final current = existing!;
  final newToken = overrideLeaseToken ?? generateDraftLeaseToken();
  if (expectingExpiredLease && newToken == current.leaseToken) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: current,
      reason: 'Resumed lease token must differ from expired lease token.',
    );
  }

  final updated = current.copyWith(
    leaseToken: newToken,
    leaseExpiresAt: effectiveNow.add(leaseDuration),
    nextAttemptAt: null,
    updatedAt: effectiveNow,
  );
  return DraftCasResult(status: DraftCasStatus.succeeded, draft: updated);
}

DraftCasResult? _checkLeasedPreconditions({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required DateTime effectiveNow,
  bool rejectUnknownLegacy = true,
}) {
  if (existing == null) {
    return DraftCasResult(
      status: DraftCasStatus.notFound,
      reason: 'Draft $localDraftId was not found.',
    );
  }
  if (existing.hasMalformedLease ||
      (rejectUnknownLegacy && existing.isLegacyUnknown) ||
      existing.isReadOnlyQuarantined ||
      existing.submissionStatus == DraftSubmissionStatus.terminalError ||
      existing.hasWaitingOriginalActorMarker ||
      (existing.recoveryCode != null &&
          existing.recoveryCode != DraftRecoveryCode.retryScheduled)) {
    return DraftCasResult(
      status: DraftCasStatus.blockedQuarantined,
      draft: existing,
      reason:
          'Draft $localDraftId is quarantined or paused (${existing.derivedQuarantineCode ?? existing.recoveryCode ?? 'terminal_error'}).',
    );
  }
  if (existing.dispatchState == CommandDispatchState.confirmedCommitted) {
    return DraftCasResult(
      status: DraftCasStatus.alreadyCommitted,
      draft: existing,
      reason: 'Draft $localDraftId is already confirmedCommitted.',
    );
  }
  if (existing.actorUserId != authenticatedActorId) {
    return DraftCasResult(
      status: DraftCasStatus.actorMismatch,
      draft: existing,
      reason: 'Authenticated actor does not match draft owner.',
    );
  }
  if (existing.leaseToken == null ||
      existing.leaseToken != leaseToken ||
      existing.leaseExpiresAt == null ||
      !existing.leaseExpiresAt!.isAfter(effectiveNow)) {
    return DraftCasResult(
      status: DraftCasStatus.leaseConflict,
      draft: existing,
      reason:
          'Stale, mismatched, or expired lease token for draft $localDraftId.',
    );
  }
  return null;
}

/// Shared diagnosis helper when an atomic SQLite lease-fenced `UPDATE` matched 0 rows.
DraftCasResult diagnoseLeasedMutationFailure({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required DateTime effectiveNow,
  bool rejectUnknownLegacy = true,
}) {
  return _checkLeasedPreconditions(
        existing: existing,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        authenticatedActorId: authenticatedActorId,
        effectiveNow: effectiveNow,
        rejectUnknownLegacy: rejectUnknownLegacy,
      ) ??
      DraftCasResult(
        status: DraftCasStatus.casConflict,
        draft: existing,
        reason: 'Draft CAS precondition failed for $localDraftId.',
      );
}

DraftCasResult _requireValidActiveLease({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required DateTime effectiveNow,
}) {
  if (!_hasText(leaseToken) || !_hasText(authenticatedActorId)) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'leaseToken and authenticatedActorId must be non-empty.',
    );
  }
  final failure = _checkLeasedPreconditions(
    existing: existing,
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
  );
  if (failure != null) return failure;
  return DraftCasResult(status: DraftCasStatus.succeeded, draft: existing);
}

DraftCasResult evaluateMarkDraftStageAndDispatch({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required DraftSubmissionStatus targetStage,
  required DateTime now,
}) {
  if (targetStage != DraftSubmissionStatus.uploadingEvidence &&
      targetStage != DraftSubmissionStatus.submittingAssessment) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'markDraftStageAndDispatch supports only uploadingEvidence or submittingAssessment.',
    );
  }
  final effectiveNow = now.toUtc();
  final leaseCheck = _requireValidActiveLease(
    existing: existing,
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
  );
  if (!leaseCheck.isSuccess) return leaseCheck;

  final current = leaseCheck.draft!;
  final clearedError = current.recoveryCode == DraftRecoveryCode.retryScheduled
      ? null
      : current.lastErrorMessage;

  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      submissionStatus: targetStage,
      dispatchState: CommandDispatchState.possiblyDispatched,
      nextAttemptAt: null,
      lastErrorMessage: clearedError,
      updatedAt: effectiveNow,
    ),
  );
}

DraftCasResult evaluatePersistServerAssessmentId({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required String serverAssessmentId,
  required DateTime now,
}) {
  if (!_hasText(serverAssessmentId)) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'serverAssessmentId must be non-empty.',
    );
  }
  final effectiveNow = now.toUtc();
  final leaseCheck = _requireValidActiveLease(
    existing: existing,
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
  );
  if (!leaseCheck.isSuccess) return leaseCheck;

  final current = leaseCheck.draft!;
  if (_hasText(current.serverAssessmentId) &&
      current.serverAssessmentId != serverAssessmentId) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: current,
      reason: 'Draft $localDraftId already has a distinct serverAssessmentId.',
    );
  }
  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      serverAssessmentId: serverAssessmentId,
      updatedAt: effectiveNow,
    ),
  );
}

DraftCasResult evaluatePersistServerEvidenceId({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required String serverEvidenceId,
  required String expectedEvidenceId,
  required String expectedSha256Checksum,
  required DateTime now,
}) {
  if (!_hasText(serverEvidenceId) ||
      !_hasText(expectedEvidenceId) ||
      !isValidSha256Hex(expectedSha256Checksum)) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'persistServerEvidenceId requires non-empty serverEvidenceId, expectedEvidenceId, and valid 64-char sha256Checksum.',
    );
  }
  final effectiveNow = now.toUtc();
  final leaseCheck = _requireValidActiveLease(
    existing: existing,
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
  );
  if (!leaseCheck.isSuccess) return leaseCheck;

  final current = leaseCheck.draft!;
  if (current.evidenceId != expectedEvidenceId ||
      current.sha256Checksum != expectedSha256Checksum) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: current,
      reason:
          'Draft $localDraftId evidenceId or sha256Checksum does not match expected snapshot.',
    );
  }
  if (_hasText(current.serverEvidenceId) &&
      current.serverEvidenceId != serverEvidenceId) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: current,
      reason: 'Draft $localDraftId already has a distinct serverEvidenceId.',
    );
  }
  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      serverEvidenceId: serverEvidenceId,
      updatedAt: effectiveNow,
    ),
  );
}

/// Sanitizes error text and wraps it in a normalized `LW4B1:` recovery envelope.
String formatSanitizedRecoveryEnvelope({
  required String recoveryCode,
  required String errorMessage,
}) {
  final sanitized = sanitizeStorageError(errorMessage).trim();
  return DraftRecoveryCode.format(
    recoveryCode,
    sanitized.isEmpty ? null : sanitized,
  );
}

DraftCasResult evaluateScheduleDraftRetry({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required DateTime nextAttemptAt,
  required String recoveryCode,
  required String errorMessage,
  DateTime? now,
}) {
  final normalizedCode = DraftRecoveryCode.parseCode(recoveryCode);
  if (normalizedCode != DraftRecoveryCode.retryScheduled) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason:
          'scheduleDraftRetry requires recoveryCode ${DraftRecoveryCode.retryScheduled}.',
    );
  }
  final effectiveNow = normalizeDraftUtcNow(now);
  final leaseCheck = _requireValidActiveLease(
    existing: existing,
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
  );
  if (!leaseCheck.isSuccess) return leaseCheck;

  final current = leaseCheck.draft!;
  final envelope = formatSanitizedRecoveryEnvelope(
    recoveryCode: DraftRecoveryCode.retryScheduled,
    errorMessage: errorMessage,
  );
  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      submissionStatus: DraftSubmissionStatus.failedRetryable,
      retryCount: current.retryCount + 1,
      nextAttemptAt: nextAttemptAt.toUtc(),
      lastErrorMessage: envelope,
      leaseToken: null,
      leaseExpiresAt: null,
      updatedAt: effectiveNow,
    ),
  );
}

DraftCasResult evaluateQuarantineDraftOutcome({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required String recoveryCode,
  required String errorMessage,
  DateTime? now,
}) {
  final parsedCode = DraftRecoveryCode.parseCode(recoveryCode);
  final isAllowedCode =
      parsedCode != null &&
      (DraftRecoveryCode.quarantineCodes.contains(parsedCode) ||
          parsedCode == DraftRecoveryCode.terminalPolicyDenial ||
          parsedCode == DraftRecoveryCode.authContextExpiredOrMismatched);
  if (!isAllowedCode) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'Unsupported quarantine recoveryCode: $recoveryCode',
    );
  }
  final effectiveNow = normalizeDraftUtcNow(now);
  final leaseCheck = _requireValidActiveLease(
    existing: existing,
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
  );
  if (!leaseCheck.isSuccess) return leaseCheck;

  final current = leaseCheck.draft!;
  final envelope = parsedCode == DraftRecoveryCode.unknownWireStatus
      ? DraftRecoveryCode.format(
          DraftRecoveryCode.unknownWireStatus,
          sanitizeStorageError(errorMessage),
        )
      : formatSanitizedRecoveryEnvelope(
          recoveryCode: parsedCode,
          errorMessage: errorMessage,
        );

  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      submissionStatus: DraftSubmissionStatus.terminalError,
      nextAttemptAt: null,
      lastErrorMessage: envelope,
      leaseToken: null,
      leaseExpiresAt: null,
      updatedAt: effectiveNow,
    ),
  );
}

DraftCasResult evaluateCompleteDraftSubmission({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  required String serverAssessmentId,
  required DateTime now,
  String? serverEvidenceId,
}) {
  if (!_hasText(serverAssessmentId) ||
      (serverEvidenceId != null && serverEvidenceId.isEmpty)) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'completeDraftSubmission requires non-empty serverAssessmentId and non-empty serverEvidenceId when supplied.',
    );
  }
  final effectiveNow = now.toUtc();
  final leaseCheck = _requireValidActiveLease(
    existing: existing,
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
  );
  if (!leaseCheck.isSuccess) return leaseCheck;

  final current = leaseCheck.draft!;
  if (_hasText(current.serverAssessmentId) &&
      current.serverAssessmentId != serverAssessmentId) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: current,
      reason:
          'Draft $localDraftId already has a different persisted serverAssessmentId.',
    );
  }
  if (serverEvidenceId != null &&
      _hasText(current.serverEvidenceId) &&
      current.serverEvidenceId != serverEvidenceId) {
    return DraftCasResult(
      status: DraftCasStatus.casConflict,
      draft: current,
      reason:
          'Draft $localDraftId already has a different persisted serverEvidenceId.',
    );
  }

  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      serverAssessmentId: serverAssessmentId,
      serverEvidenceId: serverEvidenceId ?? current.serverEvidenceId,
      submissionStatus: DraftSubmissionStatus.submittingAssessment,
      dispatchState: CommandDispatchState.confirmedCommitted,
      nextAttemptAt: null,
      lastErrorMessage: null,
      leaseToken: null,
      leaseExpiresAt: null,
      updatedAt: effectiveNow,
    ),
  );
}

DraftCasResult evaluateReleaseDraftClaim({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String leaseToken,
  required String authenticatedActorId,
  DateTime? now,
}) {
  final effectiveNow = normalizeDraftUtcNow(now);
  final leaseCheck = _requireValidActiveLease(
    existing: existing,
    localDraftId: localDraftId,
    leaseToken: leaseToken,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
  );
  if (!leaseCheck.isSuccess) return leaseCheck;

  final current = leaseCheck.draft!;
  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      leaseToken: null,
      leaseExpiresAt: null,
      updatedAt: effectiveNow,
    ),
  );
}

DraftCasResult? _checkActorPauseOrResumePreconditions({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String familyId,
  required String authenticatedActorId,
  required DateTime effectiveNow,
  required bool expectingResume,
}) {
  if (existing == null) {
    return DraftCasResult(
      status: DraftCasStatus.notFound,
      reason: 'Draft $localDraftId was not found.',
    );
  }
  if (existing.hasMalformedLease ||
      existing.isReadOnlyQuarantined ||
      existing.submissionStatus == DraftSubmissionStatus.terminalError) {
    return DraftCasResult(
      status: DraftCasStatus.blockedQuarantined,
      draft: existing,
      reason:
          'Draft $localDraftId is quarantined (${existing.derivedQuarantineCode ?? existing.recoveryCode ?? 'terminal_error'}).',
    );
  }
  if (existing.dispatchState == CommandDispatchState.confirmedCommitted) {
    return DraftCasResult(
      status: DraftCasStatus.alreadyCommitted,
      draft: existing,
      reason: 'Draft $localDraftId is already confirmedCommitted.',
    );
  }
  if (existing.familyId != familyId) {
    return DraftCasResult(
      status: DraftCasStatus.familyOrChildMismatch,
      draft: existing,
      reason: 'Draft $localDraftId belongs to a different family.',
    );
  }
  if (existing.hasActiveLease(now: effectiveNow)) {
    return DraftCasResult(
      status: DraftCasStatus.leaseConflict,
      draft: existing,
      reason: 'Draft $localDraftId holds an active unexpired lease.',
    );
  }
  if (expectingResume) {
    if (existing.actorUserId != authenticatedActorId) {
      return DraftCasResult(
        status: DraftCasStatus.actorMismatch,
        draft: existing,
        reason: 'Only the original draft actor may resume draft $localDraftId.',
      );
    }
    if (!existing.hasWaitingOriginalActorMarker) {
      return DraftCasResult(
        status: DraftCasStatus.casConflict,
        draft: existing,
        reason: 'Draft $localDraftId is not paused for original actor.',
      );
    }
  } else {
    if (existing.actorUserId == authenticatedActorId) {
      return DraftCasResult(
        status: DraftCasStatus.actorMismatch,
        draft: existing,
        reason: 'Active session matches the original draft actor.',
      );
    }
    if (existing.hasWaitingOriginalActorMarker) {
      return DraftCasResult(
        status: DraftCasStatus.casConflict,
        draft: existing,
        reason:
            'Draft $localDraftId is already paused waiting for original actor.',
      );
    }
  }
  return null;
}

/// Diagnoses failures for `pauseMismatchedActorDraft` and `resumeOriginalActorDraft`.
DraftCasResult diagnoseActorPauseOrResumeFailure({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String familyId,
  required String authenticatedActorId,
  required DateTime effectiveNow,
  required bool expectingResume,
}) {
  return _checkActorPauseOrResumePreconditions(
        existing: existing,
        localDraftId: localDraftId,
        familyId: familyId,
        authenticatedActorId: authenticatedActorId,
        effectiveNow: effectiveNow,
        expectingResume: expectingResume,
      ) ??
      DraftCasResult(
        status: DraftCasStatus.casConflict,
        draft: existing,
        reason:
            'Actor pause/resume precondition failed for draft $localDraftId.',
      );
}

DraftCasResult evaluatePauseMismatchedActorDraft({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String familyId,
  required String authenticatedActorId,
  String? mismatchReason,
  DateTime? now,
}) {
  if (!_hasText(familyId) || !_hasText(authenticatedActorId)) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'familyId and authenticatedActorId must be non-empty.',
    );
  }
  final effectiveNow = normalizeDraftUtcNow(now);
  final failure = _checkActorPauseOrResumePreconditions(
    existing: existing,
    localDraftId: localDraftId,
    familyId: familyId,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
    expectingResume: false,
  );
  if (failure != null) {
    return failure;
  }
  final current = existing!;
  final envelope = formatSanitizedRecoveryEnvelope(
    recoveryCode: DraftRecoveryCode.waitingOriginalActor,
    errorMessage: mismatchReason ?? 'Paused because active session switched away from original draft author.',
  );
  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      lastErrorMessage: envelope,
      leaseToken: null,
      leaseExpiresAt: null,
      updatedAt: effectiveNow,
    ),
  );
}

DraftCasResult evaluateResumeOriginalActorDraft({
  required LocalAssessmentDraft? existing,
  required String localDraftId,
  required String familyId,
  required String authenticatedActorId,
  DateTime? now,
}) {
  if (!_hasText(familyId) || !_hasText(authenticatedActorId)) {
    return DraftCasResult(
      status: DraftCasStatus.invalidInput,
      draft: existing,
      reason: 'familyId and authenticatedActorId must be non-empty.',
    );
  }
  final effectiveNow = normalizeDraftUtcNow(now);
  final failure = _checkActorPauseOrResumePreconditions(
    existing: existing,
    localDraftId: localDraftId,
    familyId: familyId,
    authenticatedActorId: authenticatedActorId,
    effectiveNow: effectiveNow,
    expectingResume: true,
  );
  if (failure != null) {
    return failure;
  }
  final current = existing!;
  return DraftCasResult(
    status: DraftCasStatus.succeeded,
    draft: current.copyWith(
      lastErrorMessage: null,
      leaseToken: null,
      leaseExpiresAt: null,
      updatedAt: effectiveNow,
    ),
  );
}
