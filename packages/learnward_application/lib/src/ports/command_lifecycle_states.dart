/// Command lifecycle, dispatch provenance, and recovery state enums for Phase 6 offline resilience.
library;

/// Durable dispatch provenance state for offline command journals.
///
/// Governs whether a command may be replayed, is in-flight, or was migrated
/// from an uninstrumented legacy schema (Drift v4).
enum CommandDispatchState {
  /// Migrated from Drift v4 with unknown network and retry history.
  /// Quarantined until server-authorized reconciliation.
  unknownLegacy('unknown_legacy'),

  /// Created in Drift v5 and never transmitted over the network.
  neverDispatched('never_dispatched'),

  /// Committed locally prior to network transmission, or in-flight.
  possiblyDispatched('possibly_dispatched'),

  /// Authoritatively confirmed by the server or matching command receipt.
  confirmedCommitted('confirmed_committed');

  const CommandDispatchState(this.wireValue);
  final String wireValue;

  static CommandDispatchState fromString(String value) {
    for (final state in CommandDispatchState.values) {
      if (state.wireValue == value) return state;
    }
    return CommandDispatchState.unknownLegacy;
  }
}

/// Recovery lifecycle state for pending commands.
///
/// Keeps error classification and recovery status distinct from network dispatchState.
enum CommandRecoveryState {
  /// Actively pending or eligible for normal idempotent retry by current actor.
  active('active'),

  /// Quarantined due to unknown outcome or legacy migration. Never automatically replayed.
  quarantinedUnknownOutcome('quarantined_unknown_outcome'),

  /// Paused pending the original authenticated actor who initiated the command.
  pendingOriginalActor('pending_original_actor'),

  /// Terminal failure that should not be retried.
  terminalError('terminal_error');

  const CommandRecoveryState(this.wireValue);
  final String wireValue;

  static CommandRecoveryState fromString(String value) {
    for (final s in CommandRecoveryState.values) {
      if (s.wireValue == value) return s;
    }
    return CommandRecoveryState.active;
  }
}

/// Local submission pipeline status for assessment drafts.
enum DraftSubmissionStatus {
  /// Local offline draft being edited.
  draft('draft'),

  /// Compressed photo evidence is being uploaded to storage.
  uploadingEvidence('uploading_evidence'),

  /// Evidence registered; server assessment submission in progress.
  submittingAssessment('submitting_assessment'),

  /// Transient network or server failure; eligible for retry.
  failedRetryable('failed_retryable'),

  /// Non-retryable error (e.g. boundary violation or terminal validation failure).
  terminalError('terminal_error');

  const DraftSubmissionStatus(this.wireValue);
  final String wireValue;

  /// Parses [value] strictly, returning `null` for unknown wire statuses.
  static DraftSubmissionStatus? tryFromString(String value) {
    for (final s in DraftSubmissionStatus.values) {
      if (s.wireValue == value) return s;
    }
    return null;
  }

  /// Fails closed to [DraftSubmissionStatus.terminalError] on unknown wire values.
  static DraftSubmissionStatus fromString(String value) {
    return tryFromString(value) ?? DraftSubmissionStatus.terminalError;
  }
}

/// Canonical Slice 4B-1 recovery / quarantine codes stored in `last_error_message`
/// when schema v6 remains unchanged (`LW4B1:` envelope).
abstract final class DraftRecoveryCode {
  static const String prefix = 'LW4B1:';

  static const String unknownWireStatus = 'LW4B1:UNKNOWN_WIRE_STATUS';
  static const String unknownWireStatusPrefix = 'LW4B1:UNKNOWN_WIRE_STATUS:';
  static const String unboundActorProvenance = 'LW4B1:UNBOUND_ACTOR_PROVENANCE';
  static const String legacyUnknown = 'LW4B1:LEGACY_UNKNOWN';
  static const String legacyInFlightUnverifiedBytes =
      'LW4B1:LEGACY_IN_FLIGHT_UNVERIFIED_BYTES';
  static const String waitingOriginalActor = 'LW4B1:WAITING_ORIGINAL_ACTOR';
  static const String retryScheduled = 'LW4B1:RETRY_SCHEDULED';
  static const String storageContentConflict = 'LW4B1:STORAGE_CONTENT_CONFLICT';
  static const String localSnapshotMissing = 'LW4B1:LOCAL_SNAPSHOT_MISSING';
  static const String localSnapshotCorrupted = 'LW4B1:LOCAL_SNAPSHOT_CORRUPTED';
  static const String localMetadataTampered = 'LW4B1:LOCAL_METADATA_TAMPERED';
  static const String ambiguousDuplicateRow = 'LW4B1:AMBIGUOUS_DUPLICATE_ROW';
  static const String malformedLeaseMetadata = 'LW4B1:MALFORMED_LEASE_METADATA';
  static const String authContextExpiredOrMismatched =
      'LW4B1:AUTH_CONTEXT_EXPIRED_OR_MISMATCHED';
  static const String terminalPolicyDenial = 'LW4B1:TERMINAL_POLICY_DENIAL';
  static const String quarantinedUnknownOutcome =
      'LW4B1:QUARANTINED_UNKNOWN_OUTCOME';

  /// Fail-closed quarantine codes that must never be automatically retried or deleted.
  static const Set<String> quarantineCodes = {
    unknownWireStatus,
    unboundActorProvenance,
    legacyUnknown,
    legacyInFlightUnverifiedBytes,
    storageContentConflict,
    localSnapshotMissing,
    localSnapshotCorrupted,
    localMetadataTampered,
    ambiguousDuplicateRow,
    malformedLeaseMetadata,
    quarantinedUnknownOutcome,
  };

  /// All recognized `LW4B1:` codes.
  static const Set<String> allCodes = {
    ...quarantineCodes,
    waitingOriginalActor,
    retryScheduled,
    authContextExpiredOrMismatched,
    terminalPolicyDenial,
  };

  static final RegExp _codePattern = RegExp(r'^(LW4B1:[A-Z0-9_]+)(?::|$)');

  /// Formats a normalized `LW4B1:` message envelope for [code] and optional [detail].
  static String format(String code, [String? detail]) {
    final normalizedCode = _normalizeCode(code);
    final trimmedDetail = detail?.trim();
    if (trimmedDetail == null || trimmedDetail.isEmpty) {
      return normalizedCode;
    }
    if (normalizedCode == unknownWireStatus) {
      return '$unknownWireStatusPrefix$trimmedDetail';
    }
    return '$normalizedCode: $trimmedDetail';
  }

  /// Extracts the canonical `LW4B1:...` code prefix from [lastErrorMessage], if any.
  static String? parseCode(String? lastErrorMessage) {
    if (lastErrorMessage == null || !lastErrorMessage.startsWith(prefix)) {
      return null;
    }
    final match = _codePattern.firstMatch(lastErrorMessage);
    return match?.group(1);
  }

  /// Whether [lastErrorMessage] carries any structured `LW4B1:` marker.
  static bool isRecoveryMarker(String? lastErrorMessage) =>
      parseCode(lastErrorMessage) != null;

  static String _normalizeCode(String code) {
    final parsed = parseCode(code);
    if (parsed != null) return parsed;
    final upper = code.trim().toUpperCase();
    return upper.startsWith(prefix) ? upper : '$prefix$upper';
  }
}

/// Derived read-only recovery disposition for assessment drafts in Slice 4B-1.
enum DraftRecoveryDisposition {
  /// Plain unsent draft bound to an actor and eligible for normal editing/submission.
  editableDraft,

  /// Actively held by an unexpired worker lease in the current session.
  inProgressSameSession,

  /// Transient failure scheduled for bounded retry via `nextAttemptAt`.
  retryScheduled,

  /// Interrupted upload/submit (`possibly_dispatched`) awaiting idempotent server reconciliation.
  verificationPending,

  /// Paused because the active session switched away from `actorUserId`.
  waitingOriginalActor,

  /// Fail-closed quarantine when outcome, actor provenance, lease, or wire state cannot be verified.
  quarantinedUnknownOutcome,

  /// Canonical snapshot file referenced by draft is missing from app storage.
  quarantinedMissingSnapshot,

  /// Canonical snapshot failed byte length, magic-byte MIME, or SHA-256 verification.
  quarantinedCorruptedSnapshot,

  /// Storage 409 remote byte conflict or local metadata tampering detected.
  quarantinedConflict,

  /// Legacy v4 row or unverified in-flight row requiring manual intervention.
  quarantinedLegacyUnknown,

  /// Deterministic server/policy denial.
  terminalPolicyDenial,

  /// Server authoritatively committed draft and assessment outcome.
  confirmedSubmitted,
}
