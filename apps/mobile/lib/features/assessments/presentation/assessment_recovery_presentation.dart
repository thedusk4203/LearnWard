import 'package:learnward_application/learnward_application.dart';

/// Visual severity for surfaced draft recovery states.
enum RecoveryBannerSeverity { neutral, info, warning, error, success }

/// Differentiated UI actions supported by the WP4 assessment recovery surface.
enum AssessmentRecoveryUiActionKind {
  submitEditable,
  retryNow,
  waitScheduled,
  inProgressWait,
  signInAsOriginalActor,
  manualReviewRequired,
  reviewConfirmedResult,
}

/// Safe, redacted UI presentation derived from persisted draft recovery state
/// and authoritative live session/target verification.
final class AssessmentRecoveryPresentation {
  const AssessmentRecoveryPresentation({
    required this.disposition,
    required this.badgeLabel,
    required this.title,
    required this.explanation,
    required this.actionKind,
    required this.severity,
    required this.canEditDraft,
    required this.canRetryNow,
    required this.canResumeOriginalActor,
    required this.canReviewConfirmed,
    required this.canRefreshStatus,
    this.safeRecoveryCode,
    this.scheduleDetail,
    this.leaseDetail,
    this.signInGuidance,
    this.manualReviewNotice,
  });

  final DraftRecoveryDisposition disposition;
  final String? safeRecoveryCode;
  final String badgeLabel;
  final String title;
  final String explanation;
  final String? scheduleDetail;
  final String? leaseDetail;
  final String? signInGuidance;
  final String? manualReviewNotice;
  final AssessmentRecoveryUiActionKind actionKind;
  final RecoveryBannerSeverity severity;
  final bool canEditDraft;
  final bool canRetryNow;
  final bool canResumeOriginalActor;
  final bool canReviewConfirmed;
  final bool canRefreshStatus;
}

/// Returns only a safe filename or `'Unavailable'`, never exposing private
/// device directory paths in diagnostics or UI copy (`I16`).
String sanitizeDiagnosticBasename(String? filePath) {
  if (filePath == null || filePath.trim().isEmpty) {
    return 'Unavailable';
  }
  final normalized = filePath.trim();
  final segments = normalized.split(RegExp(r'[/\\]'));
  final last = segments.isNotEmpty ? segments.last.trim() : '';
  return last.isEmpty ? 'Unavailable' : last;
}

/// Formats a UTC timestamp concisely for user-facing backoff / lease notices.
String formatRecoveryUtcTimestamp(DateTime timestamp) {
  final utc = timestamp.toUtc();
  final y = utc.year.toString().padLeft(4, '0');
  final m = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  final hh = utc.hour.toString().padLeft(2, '0');
  final mm = utc.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm UTC';
}

/// Computes the typed recovery presentation and eligible foreground actions for [draft]
/// from persisted WP3 journal metadata and authoritative live session/target verification.
AssessmentRecoveryPresentation buildAssessmentRecoveryPresentation({
  required LocalAssessmentDraft draft,
  required DateTime now,
  ValidatedActorContext? liveActor,
  bool liveAuthChecked = false,
  bool liveAuthInvalid = false,
  AdultTargetAuthorizationResult? liveTargetAuthorization,
}) {
  final effectiveNow = now.toUtc();
  final disposition = draft.recoveryDispositionAt(now: effectiveNow);
  final rawCode = draft.derivedQuarantineCode ?? draft.recoveryCode;
  final safeCode =
      (rawCode != null && DraftRecoveryCode.allCodes.contains(rawCode))
      ? rawCode
      : draft.isLegacyUnknown
      ? DraftRecoveryCode.legacyUnknown
      : draft.hasUnboundActor
      ? DraftRecoveryCode.unboundActorProvenance
      : null;

  final bool sessionIsValid =
      liveAuthChecked &&
      !liveAuthInvalid &&
      liveActor != null &&
      liveActor.isValidAt(effectiveNow);
  final bool actorMatchesDraft =
      draft.actorUserId != null &&
      draft.actorUserId!.isNotEmpty &&
      (!liveAuthChecked ||
          (sessionIsValid && liveActor.userId == draft.actorUserId));
  final bool targetConfirmedDenied =
      liveTargetAuthorization?.status ==
      TargetAuthorizationStatus.confirmedRevoked;

  switch (disposition) {
    case DraftRecoveryDisposition.confirmedSubmitted:
      final canReview =
          (draft.serverAssessmentId?.isNotEmpty ?? false) &&
          (!liveAuthChecked || (sessionIsValid && !targetConfirmedDenied));
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Confirmed',
        title: 'Submitted Assessment Confirmed',
        explanation: 'This assessment submission has been confirmed on the server. Local draft metadata and evidence remain preserved on this device.',
        actionKind: AssessmentRecoveryUiActionKind.reviewConfirmedResult,
        severity: RecoveryBannerSeverity.success,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: canReview,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.quarantinedMissingSnapshot:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode ?? DraftRecoveryCode.localSnapshotMissing,
        badgeLabel: 'Snapshot Missing',
        title: 'Evidence Snapshot Missing',
        explanation: 'The locked evidence photo snapshot could not be found on this device. Your draft record is preserved read-only so another photo is not accidentally substituted.',
        manualReviewNotice: 'Manual review required: restore the original device snapshot or create a new assessment entry without deleting existing recovery metadata.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.error,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.quarantinedCorruptedSnapshot:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode ?? DraftRecoveryCode.localSnapshotCorrupted,
        badgeLabel: 'Snapshot Corrupted',
        title: 'Evidence Integrity Verification Failed',
        explanation: 'The locked evidence photo snapshot did not pass checksum or format verification. Upload is blocked to prevent submitting modified bytes.',
        manualReviewNotice: 'Manual review required: existing recovery records and local files remain untouched for inspection.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.error,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.quarantinedConflict:
      final isVersionConflict = safeCode == DraftRecoveryCode.versionConflict;
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: isVersionConflict
            ? 'Version Conflict'
            : 'Evidence Conflict',
        title: isVersionConflict
            ? 'Server Version Conflict Detected'
            : 'Evidence Conflict Detected',
        explanation: isVersionConflict
            ? 'The server assessment record changed or no longer matches the local submission version. Automatic submission is disabled to protect data integrity.'
            : 'Remote storage or server evidence metadata differs from the local snapshot. Existing local and remote artifacts are preserved safely without overwriting.',
        manualReviewNotice: 'Manual review required: inspect the assessment in parent review or start a fresh submission if needed.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.error,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.quarantinedLegacyUnknown:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode ?? DraftRecoveryCode.legacyUnknown,
        badgeLabel: 'Legacy Quarantine',
        title: 'Legacy Draft Quarantined',
        explanation: 'This draft came from an earlier version or lacks verified evidence snapshots before dispatch and is locked read-only.',
        manualReviewNotice: 'Manual review required: automatic replay and editing are disabled while preserving existing files and IDs.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.terminalPolicyDenial:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode ?? DraftRecoveryCode.terminalPolicyDenial,
        badgeLabel: 'Permission Denied',
        title: 'Submission Not Permitted',
        explanation: 'Authoritative family or child permissions did not allow this submission before remote creation. No further retries will run automatically.',
        manualReviewNotice: 'Manual review required: verify family membership and child profile status before creating a new submission.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.error,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.quarantinedUnknownOutcome:
      return _buildQuarantinedUnknownPresentation(
        disposition: disposition,
        safeCode: safeCode,
      );

    case DraftRecoveryDisposition.inProgressSameSession:
      final leaseExpiryText = draft.leaseExpiresAt != null
          ? 'Active sync lease held until ${formatRecoveryUtcTimestamp(draft.leaseExpiresAt!)}.'
          : 'An active sync worker currently holds a lease on this draft.';
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'In Progress',
        title: 'Submission Sync In Progress',
        explanation: 'Another active sync task is currently processing this draft. Refresh status to inspect completion without interrupting the active worker.',
        leaseDetail: leaseExpiryText,
        actionKind: AssessmentRecoveryUiActionKind.inProgressWait,
        severity: RecoveryBannerSeverity.info,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.waitingOriginalActor:
      final canResume =
          liveAuthChecked &&
          sessionIsValid &&
          actorMatchesDraft &&
          !targetConfirmedDenied &&
          !draft.hasActiveLease(now: effectiveNow);
      if (targetConfirmedDenied) {
        return AssessmentRecoveryPresentation(
          disposition: disposition,
          safeRecoveryCode: safeCode ?? DraftRecoveryCode.waitingOriginalActor,
          badgeLabel: 'Permission Denied',
          title: 'Authorization Revoked',
          explanation: 'Even under the original author account, target permissions for this family or child are currently revoked.',
          manualReviewNotice: 'Manual review required: draft metadata and evidence remain safely preserved.',
          actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
          severity: RecoveryBannerSeverity.error,
          canEditDraft: false,
          canRetryNow: false,
          canResumeOriginalActor: false,
          canReviewConfirmed: false,
          canRefreshStatus: true,
        );
      }
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode ?? DraftRecoveryCode.waitingOriginalActor,
        badgeLabel: 'Sign-In Required',
        title: 'Waiting for Original Author',
        explanation: canResume
            ? 'The original author session is active again. You may safely resume verification and submission without altering draft ownership.'
            : 'A different or signed-out account was active when sync checked this draft. Draft ownership is preserved and never reassigned.',
        signInGuidance: canResume
            ? 'Original author verified. Tap Resume Submission below to continue.'
            : 'Sign in as the original author account to resume this submission.',
        actionKind: AssessmentRecoveryUiActionKind.signInAsOriginalActor,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: canResume,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.retryScheduled:
      if (liveAuthChecked && (!sessionIsValid || !actorMatchesDraft)) {
        return AssessmentRecoveryPresentation(
          disposition: disposition,
          safeRecoveryCode: safeCode ?? DraftRecoveryCode.retryScheduled,
          badgeLabel: 'Sign-In Required',
          title: 'Waiting for Original Author',
          explanation: 'A retry is scheduled for this draft, but the active session does not match the original author or has expired.',
          signInGuidance: 'Sign in as the original author account to retry. Provenance cannot be reassigned.',
          scheduleDetail: _buildScheduleDetail(draft, effectiveNow),
          actionKind: AssessmentRecoveryUiActionKind.signInAsOriginalActor,
          severity: RecoveryBannerSeverity.warning,
          canEditDraft: false,
          canRetryNow: false,
          canResumeOriginalActor: false,
          canReviewConfirmed: false,
          canRefreshStatus: true,
        );
      }
      if (targetConfirmedDenied) {
        return AssessmentRecoveryPresentation(
          disposition: disposition,
          safeRecoveryCode: safeCode ?? DraftRecoveryCode.retryScheduled,
          badgeLabel: 'Permission Denied',
          title: 'Retry Blocked by Permissions',
          explanation: 'Family or child authorization for this draft was revoked before retry.',
          manualReviewNotice: 'Manual review required: retry is disabled while preserving local files and command IDs.',
          scheduleDetail: _buildScheduleDetail(draft, effectiveNow),
          actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
          severity: RecoveryBannerSeverity.error,
          canEditDraft: false,
          canRetryNow: false,
          canResumeOriginalActor: false,
          canReviewConfirmed: false,
          canRefreshStatus: true,
        );
      }
      final hasFutureBackoff =
          draft.nextAttemptAt != null &&
          draft.nextAttemptAt!.isAfter(effectiveNow);
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode ?? DraftRecoveryCode.retryScheduled,
        badgeLabel: 'Retry Scheduled',
        title: hasFutureBackoff
            ? 'Retry Scheduled After Connection Error'
            : 'Ready for Retry',
        explanation: hasFutureBackoff
            ? 'A temporary failure paused submission with persisted backoff. No automatic background dispatch is running; you can wait or tap Retry Now.'
            : 'The scheduled backoff window has elapsed and this draft is eligible for authorized foreground retry.',
        scheduleDetail: _buildScheduleDetail(draft, effectiveNow),
        actionKind: AssessmentRecoveryUiActionKind.retryNow,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: true,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.verificationPending:
      if (liveAuthChecked && (!sessionIsValid || !actorMatchesDraft)) {
        return AssessmentRecoveryPresentation(
          disposition: disposition,
          safeRecoveryCode: safeCode,
          badgeLabel: 'Sign-In Required',
          title: 'Verification Needs Original Author',
          explanation: 'This interrupted submission must be verified under the original author account before continuing.',
          signInGuidance: 'Sign in as the original author account to reconcile remote status safely.',
          actionKind: AssessmentRecoveryUiActionKind.signInAsOriginalActor,
          severity: RecoveryBannerSeverity.warning,
          canEditDraft: false,
          canRetryNow: false,
          canResumeOriginalActor: false,
          canReviewConfirmed: false,
          canRefreshStatus: true,
        );
      }
      if (targetConfirmedDenied) {
        return AssessmentRecoveryPresentation(
          disposition: disposition,
          safeRecoveryCode: safeCode,
          badgeLabel: 'Permission Denied',
          title: 'Verification Blocked by Permissions',
          explanation: 'Current permissions do not allow reconciling or submitting this assessment for the child.',
          manualReviewNotice: 'Manual review required: local draft and evidence remain preserved.',
          actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
          severity: RecoveryBannerSeverity.error,
          canEditDraft: false,
          canRetryNow: false,
          canResumeOriginalActor: false,
          canReviewConfirmed: false,
          canRefreshStatus: true,
        );
      }
      final hasExpiredLease = draft.hasExpiredLease(now: effectiveNow);
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Verification Pending',
        title: hasExpiredLease
            ? 'Previous Sync Interrupted'
            : 'Verification Pending',
        explanation: hasExpiredLease
            ? 'A prior sync lease expired before completion. Tap Retry Now to verify server state idempotently using the same command IDs.'
            : 'Submission progress is uncertain after an interruption. Tap Retry Now to verify server state before continuing.',
        leaseDetail: hasExpiredLease
            ? 'Previous sync lease expired and can be safely reclaimed on retry.'
            : null,
        actionKind: AssessmentRecoveryUiActionKind.retryNow,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: true,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryDisposition.editableDraft:
      if (liveAuthChecked && (!sessionIsValid || !actorMatchesDraft)) {
        return AssessmentRecoveryPresentation(
          disposition: disposition,
          safeRecoveryCode: safeCode,
          badgeLabel: 'Sign-In Required',
          title: 'Saved by Another Account',
          explanation: 'This local draft belongs to a different or expired session and is locked read-only until that author signs back in.',
          signInGuidance: 'Sign in as the original author account to edit or submit this draft.',
          actionKind: AssessmentRecoveryUiActionKind.signInAsOriginalActor,
          severity: RecoveryBannerSeverity.warning,
          canEditDraft: false,
          canRetryNow: false,
          canResumeOriginalActor: false,
          canReviewConfirmed: false,
          canRefreshStatus: true,
        );
      }
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Draft',
        title: 'Editable Local Draft',
        explanation: 'This draft has not been submitted yet and can be edited, saved locally, or submitted for review.',
        actionKind: AssessmentRecoveryUiActionKind.submitEditable,
        severity: RecoveryBannerSeverity.neutral,
        canEditDraft: true,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );
  }
}

AssessmentRecoveryPresentation _buildQuarantinedUnknownPresentation({
  required DraftRecoveryDisposition disposition,
  required String? safeCode,
}) {
  switch (safeCode) {
    case DraftRecoveryCode.registrationUnresolvedRemoteRetained:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Registration Unresolved',
        title: 'Evidence Registration Unresolved',
        explanation: 'Uploaded evidence bytes remain retained in remote storage, but database registration could not be confirmed automatically.',
        manualReviewNotice: 'Manual review required: remote and local files are retained without deletion or duplicate upload.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryCode.unreconstructableExpectedVersion:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Version Conflict',
        title: 'Server Version Cannot Be Reconstructed',
        explanation: 'The server draft version advanced beyond version 1 while offline, so automatic submission cannot safely prove the original version.',
        manualReviewNotice: 'Manual review required: speculative overwrites are blocked while local bytes and IDs stay preserved.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.error,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryCode.unboundActorProvenance:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Author Unverified',
        title: 'Draft Author Account Missing',
        explanation: 'This saved draft has no recorded author account and is quarantined read-only so the current user cannot adopt or alter it.',
        manualReviewNotice: 'Manual review required: original files and metadata remain preserved unmodified.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryCode.unknownWireStatus:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Unsupported Status',
        title: 'Unsupported Local Draft Status',
        explanation: 'This draft uses an unrecognized status token from storage and is quarantined read-only to prevent unsafe edits.',
        manualReviewNotice: 'Manual review required: existing storage data and evidence remain untouched.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    case DraftRecoveryCode.ambiguous42501Outcome:
    case DraftRecoveryCode.ambiguousSubmitOutcome:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Manual Verification',
        title: 'Submission Verification Pending Review',
        explanation: 'Server verification returned an ambiguous authorization or state outcome, so the client cannot prove whether the prior submission already committed.',
        manualReviewNotice: 'Manual review required: check parent review history before submitting again. Local IDs and evidence remain preserved.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );

    default:
      return AssessmentRecoveryPresentation(
        disposition: disposition,
        safeRecoveryCode: safeCode,
        badgeLabel: 'Manual Review',
        title: 'Draft Quarantined for Safety',
        explanation: 'This draft cannot be safely edited or retried automatically and is preserved read-only on this device.',
        manualReviewNotice: 'Manual review required: local draft records and attached evidence remain intact.',
        actionKind: AssessmentRecoveryUiActionKind.manualReviewRequired,
        severity: RecoveryBannerSeverity.warning,
        canEditDraft: false,
        canRetryNow: false,
        canResumeOriginalActor: false,
        canReviewConfirmed: false,
        canRefreshStatus: true,
      );
  }
}

String? _buildScheduleDetail(LocalAssessmentDraft draft, DateTime now) {
  final nextAttemptAt = draft.nextAttemptAt?.toUtc();
  if (nextAttemptAt == null) {
    return draft.retryCount > 0
        ? 'Retry attempts so far: ${draft.retryCount}.'
        : null;
  }
  final formatted = formatRecoveryUtcTimestamp(nextAttemptAt);
  if (nextAttemptAt.isAfter(now)) {
    final diff = nextAttemptAt.difference(now);
    final waitLabel = diff.inMinutes >= 1
        ? '${diff.inMinutes}m'
        : '${diff.inSeconds.clamp(1, 59)}s';
    return 'Next automatic retry window: $formatted (in ~$waitLabel, attempt #${draft.retryCount}).';
  }
  return 'Scheduled retry window reached ($formatted, attempt #${draft.retryCount}).';
}
