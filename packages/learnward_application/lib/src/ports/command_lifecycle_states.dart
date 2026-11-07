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

  static DraftSubmissionStatus fromString(String value) {
    for (final s in DraftSubmissionStatus.values) {
      if (s.wireValue == value) return s;
    }
    return DraftSubmissionStatus.draft;
  }
}
