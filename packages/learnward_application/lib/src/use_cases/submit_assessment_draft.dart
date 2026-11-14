import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/auth_session_port.dart';
import '../ports/canonical_evidence_snapshot.dart';
import '../ports/clock.dart';
import '../ports/local_draft_store.dart';
import '../ports/recovery_authorization_port.dart';
import '../services/assessment_submission_orchestrator.dart';
import '../services/jitter_source.dart';

export '../services/assessment_submission_orchestrator.dart'
    show
        AssessmentPolicyDeniedException,
        AssessmentQuarantinedException,
        AssessmentReconciliationPendingException,
        AssessmentRetryScheduledException,
        AssessmentSubmissionConfirmed,
        AssessmentSubmissionLeaseConflict,
        AssessmentSubmissionOutcome,
        AssessmentSubmissionPausedActorMismatch,
        AssessmentSubmissionPausedSessionInvalid,
        AssessmentSubmissionPolicyDenied,
        AssessmentSubmissionQuarantined,
        AssessmentSubmissionRetryScheduled,
        CommandExecutionTrigger,
        DraftCasFailureStage,
        DraftSubmissionCasException,
        EvidenceIdMismatchException,
        EvidenceRegistrationUnresolvedRemoteRetainedException,
        LeaseReleaseFailureCallback,
        MissingCanonicalEvidenceSnapshotException,
        MissingLocalDraftJournalException;

/// Submits an assessment draft through the shared WP3 crash-resumable
/// [AssessmentSubmissionOrchestrator] state machine.
final class SubmitAssessmentDraft {
  const SubmitAssessmentDraft({
    required this.repository,
    required this.storage,
    required this.authSessionPort,
    required LocalDraftStore this.localDraftStore,
    required RecoveryAuthorizationPort this.recoveryAuthorizationPort,
    this.canonicalSnapshotStore,
    this.clock = const SystemClock(),
    this.jitterSource = const RandomJitterSource(),
    this.leaseDuration = const Duration(minutes: 2),
    this.maxRetryCount = 5,
    this.onLeaseReleaseFailure,
  });

  /// Explicit isolated constructor for unit tests exercising repository/storage
  /// behavior without a local draft journal store.
  const SubmitAssessmentDraft.unjournaledForTesting({
    required this.repository,
    required this.storage,
    required this.authSessionPort,
    this.recoveryAuthorizationPort,
    this.canonicalSnapshotStore,
    this.clock = const SystemClock(),
    this.jitterSource = const RandomJitterSource(),
    this.leaseDuration = const Duration(minutes: 2),
    this.maxRetryCount = 5,
    this.onLeaseReleaseFailure,
  }) : localDraftStore = null;

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;
  final AuthSessionPort authSessionPort;
  final LocalDraftStore? localDraftStore;
  final RecoveryAuthorizationPort? recoveryAuthorizationPort;
  final CanonicalEvidenceSnapshotStore? canonicalSnapshotStore;
  final Clock clock;
  final JitterSource jitterSource;
  final Duration leaseDuration;
  final int maxRetryCount;
  final LeaseReleaseFailureCallback? onLeaseReleaseFailure;

  AssessmentSubmissionOrchestrator _buildOrchestrator() {
    if (localDraftStore != null && recoveryAuthorizationPort != null) {
      return AssessmentSubmissionOrchestrator(
        repository: repository,
        storage: storage,
        authSessionPort: authSessionPort,
        localDraftStore: localDraftStore!,
        recoveryAuthorizationPort: recoveryAuthorizationPort!,
        canonicalSnapshotStore: canonicalSnapshotStore,
        clock: clock,
        jitterSource: jitterSource,
        leaseDuration: leaseDuration,
        maxRetryCount: maxRetryCount,
        onLeaseReleaseFailure: onLeaseReleaseFailure,
      );
    }
    return AssessmentSubmissionOrchestrator.unjournaledForTesting(
      repository: repository,
      storage: storage,
      authSessionPort: authSessionPort,
      recoveryAuthorizationPort: recoveryAuthorizationPort,
      canonicalSnapshotStore: canonicalSnapshotStore,
      clock: clock,
      jitterSource: jitterSource,
      leaseDuration: leaseDuration,
      maxRetryCount: maxRetryCount,
      onLeaseReleaseFailure: onLeaseReleaseFailure,
    );
  }

  /// Executes the workflow and returns the typed [AssessmentSubmissionOutcome].
  Future<AssessmentSubmissionOutcome> execute({
    required FamilyId familyId,
    required ChildId childId,
    required String createCommandId,
    required String submitCommandId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    EntryContext entryContext = EntryContext.sharedChild,
    List<int>? evidenceBytes,
    String? evidenceMediaType,
    EvidenceId? evidenceId,
    String? localDraftId,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
    CommandExecutionTrigger trigger = CommandExecutionTrigger.foreground,
  }) {
    return _buildOrchestrator().execute(
      familyId: familyId,
      childId: childId,
      createCommandId: createCommandId,
      submitCommandId: submitCommandId,
      subjectKey: subjectKey,
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      occurredAt: occurredAt,
      entryContext: entryContext,
      evidenceBytes: evidenceBytes,
      evidenceMediaType: evidenceMediaType,
      evidenceId: evidenceId,
      localDraftId: localDraftId,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      trigger: trigger,
    );
  }

  /// Runs [execute] and returns the committed [Assessment], translating
  /// non-confirmed outcomes into deterministic typed exceptions for legacy
  /// callers and tests.
  Future<Assessment> call({
    required FamilyId familyId,
    required ChildId childId,
    required String createCommandId,
    required String submitCommandId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    EntryContext entryContext = EntryContext.sharedChild,
    List<int>? evidenceBytes,
    String? evidenceMediaType,
    EvidenceId? evidenceId,
    String? localDraftId,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
    CommandExecutionTrigger trigger = CommandExecutionTrigger.foreground,
  }) async {
    final outcome = await execute(
      familyId: familyId,
      childId: childId,
      createCommandId: createCommandId,
      submitCommandId: submitCommandId,
      subjectKey: subjectKey,
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      occurredAt: occurredAt,
      entryContext: entryContext,
      evidenceBytes: evidenceBytes,
      evidenceMediaType: evidenceMediaType,
      evidenceId: evidenceId,
      localDraftId: localDraftId,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      trigger: trigger,
    );

    switch (outcome) {
      case AssessmentSubmissionConfirmed(:final assessment):
        return assessment;
      case AssessmentSubmissionPausedActorMismatch(
        :final cause,
        :final message,
      ):
        if (cause is EvidenceStorageAuthException) {
          throw cause;
        }
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: 'assessment-draft/${outcome.localDraftId}',
            reason: message,
            actorSwitched: true,
          ),
        );
      case AssessmentSubmissionPausedSessionInvalid(
        :final cause,
        :final message,
        :final isServerAuthRejection,
      ):
        if (cause is EvidenceStorageAuthException) {
          throw cause;
        }
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: 'assessment-draft/${outcome.localDraftId}',
            reason: message,
            isLocalSessionInvalid: !isServerAuthRejection,
            isServerHttpAuthRejection: isServerAuthRejection,
          ),
        );
      case AssessmentSubmissionLeaseConflict(
        :final localDraftId,
        :final casStatus,
        :final message,
      ):
        throw DraftSubmissionCasException(
          stage: DraftCasFailureStage.acquireLease,
          localDraftId: localDraftId,
          casStatus: casStatus ?? DraftCasStatus.leaseConflict,
          message: message,
        );
      case AssessmentSubmissionPolicyDenied(
        :final recoveryCode,
        :final message,
      ):
        throw AssessmentPolicyDeniedException(
          recoveryCode: recoveryCode,
          message: message,
        );
      case AssessmentSubmissionQuarantined(
        :final wasPreExistingBlock,
        :final cause,
        :final recoveryCode,
        :final disposition,
        :final message,
      ):
        if (wasPreExistingBlock && cause is StateError) {
          throw cause;
        }
        if (cause is EvidenceStorageConflictException) {
          throw cause;
        }
        if (cause is EvidenceRegistrationUnresolvedRemoteRetainedException) {
          throw cause;
        }
        if (cause is EvidenceIdMismatchException) {
          throw cause;
        }
        throw AssessmentQuarantinedException(
          recoveryCode: recoveryCode,
          disposition: disposition,
          message: message,
        );
      case AssessmentSubmissionRetryScheduled(
        :final nextAttemptAt,
        :final retryCount,
        :final message,
        :final cause,
      ):
        throw AssessmentRetryScheduledException(
          nextAttemptAt: nextAttemptAt,
          retryCount: retryCount,
          message: message,
          cause: cause,
        );
    }
  }
}
