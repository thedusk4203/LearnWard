import 'dart:async';

import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/auth_session_port.dart';
import '../ports/canonical_evidence_snapshot.dart';
import '../ports/clock.dart';
import '../ports/command_lifecycle_states.dart';
import '../ports/draft_store_rules.dart';
import '../ports/local_draft_store.dart';
import '../ports/recovery_authorization_port.dart';
import 'jitter_source.dart';

export '../ports/command_lifecycle_states.dart' show CommandExecutionTrigger;

/// Lifecycle CAS stage at which a local draft transition failed.
enum DraftCasFailureStage {
  registerPreDispatchDraft,
  acquireLease,
  markDispatchStage,
  persistServerAssessmentId,
  persistServerEvidenceId,
  markSubmittingStage,
  completeSubmission,
  releaseDraftClaim,
}

/// Optional observer invoked when releasing an uncompleted CAS lease fails.
typedef LeaseReleaseFailureCallback = void Function({
  required String localDraftId,
  DraftCasStatus? status,
  Object? error,
});

/// Thrown when durable local draft journaling is missing before submission (R33-06).
final class MissingLocalDraftJournalException implements Exception {
  const MissingLocalDraftJournalException({this.localDraftId, String? reason})
    : _rawReason =
          reason ??
          'A persisted local draft journal entry is required before assessment submission.';

  final String? localDraftId;
  final String _rawReason;

  String get message => sanitizeStorageError(_rawReason);

  @override
  String toString() => 'MissingLocalDraftJournalException: $message';
}

/// Thrown when an evidence-bearing draft lacks a frozen canonical snapshot (R33-04).
final class MissingCanonicalEvidenceSnapshotException implements Exception {
  const MissingCanonicalEvidenceSnapshotException({
    this.localDraftId,
    String? message,
  }) : _rawMessage =
           message ??
           'Evidence-bearing assessment draft lacks a verified canonical snapshot.';

  final String? localDraftId;
  final String _rawMessage;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() => 'MissingCanonicalEvidenceSnapshotException: $message';
}

/// Typed exception raised when local CAS / lease state prevents safe dispatch.
final class DraftSubmissionCasException implements Exception {
  const DraftSubmissionCasException({
    required this.stage,
    required this.localDraftId,
    required String message,
    this.casStatus,
    this.serverAssessmentId,
    this.serverEvidenceId,
    this.cause,
  }) : _rawMessage = message;

  final DraftCasFailureStage stage;
  final String localDraftId;
  final DraftCasStatus? casStatus;
  final String? serverAssessmentId;
  final String? serverEvidenceId;
  final String _rawMessage;
  final Object? cause;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() =>
      'DraftSubmissionCasException(stage: ${stage.name}, status: ${casStatus?.name}, message: $message)';
}

/// Raised when remote submission succeeded but local `confirmedCommitted` CAS
/// could not complete, requiring fail-closed reconciliation rather than fake success.
final class AssessmentReconciliationPendingException implements Exception {
  const AssessmentReconciliationPendingException({
    required this.submittedAssessment,
    required this.localDraftId,
    this.serverEvidenceId,
    this.casStatus,
    required String message,
    this.cause,
  }) : _rawMessage = message;

  final Assessment submittedAssessment;
  final String localDraftId;
  final String? serverEvidenceId;
  final DraftCasStatus? casStatus;
  final String _rawMessage;
  final Object? cause;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() => 'AssessmentReconciliationPendingException: $message';
}

/// Raised when `LW109` occurs on evidence registration after remote assessment
/// transitioned out of `draft` and no matching registered DB evidence row exists
/// (`LW4B1:REGISTRATION_UNRESOLVED_REMOTE_RETAINED`, I04 remote bytes retained).
final class EvidenceRegistrationUnresolvedRemoteRetainedException
    implements Exception {
  const EvidenceRegistrationUnresolvedRemoteRetainedException({
    required this.storagePath,
    required String message,
  }) : _rawMessage = message;

  final String storagePath;
  final String _rawMessage;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() =>
      'EvidenceRegistrationUnresolvedRemoteRetainedException(path: ${redactStoragePath(storagePath)}, message: $message)';
}

/// Raised when server DB evidence ID conflicts with previously persisted `serverEvidenceId`.
final class EvidenceIdMismatchException implements Exception {
  const EvidenceIdMismatchException({required String message})
    : _rawMessage = message;

  final String _rawMessage;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() => 'EvidenceIdMismatchException: $message';
}

/// Raised when policy/authorization definitively denies an un-dispatched target.
final class AssessmentPolicyDeniedException implements Exception {
  const AssessmentPolicyDeniedException({
    required String message,
    required this.recoveryCode,
  }) : _rawMessage = message;

  final String recoveryCode;
  final String _rawMessage;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() =>
      'AssessmentPolicyDeniedException(code: $recoveryCode, message: $message)';
}

/// Raised on `.call()` when a draft enters a durable WP3 read-only quarantine state.
final class AssessmentQuarantinedException implements Exception {
  const AssessmentQuarantinedException({
    required this.recoveryCode,
    required this.disposition,
    required String message,
  }) : _rawMessage = message;

  final String recoveryCode;
  final DraftRecoveryDisposition disposition;
  final String _rawMessage;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() =>
      'AssessmentQuarantinedException(code: $recoveryCode, message: $message)';
}

/// Raised on `.call()` when a transient failure schedules bounded persisted retry backoff.
final class AssessmentRetryScheduledException implements Exception {
  const AssessmentRetryScheduledException({
    required this.nextAttemptAt,
    required this.retryCount,
    required String message,
    this.cause,
  }) : _rawMessage = message;

  final DateTime nextAttemptAt;
  final int retryCount;
  final String _rawMessage;
  final Object? cause;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() =>
      'AssessmentRetryScheduledException(retryCount: $retryCount, nextAttemptAt: ${nextAttemptAt.toUtc().toIso8601String()}, message: $message)';
}

/// Typed, exhaustive outcome of running [AssessmentSubmissionOrchestrator.execute].
sealed class AssessmentSubmissionOutcome {
  const AssessmentSubmissionOutcome();
}

final class AssessmentSubmissionConfirmed extends AssessmentSubmissionOutcome {
  const AssessmentSubmissionConfirmed({
    required this.assessment,
    this.draft,
    this.serverEvidence,
    this.evidenceReconciliation,
  });

  final Assessment assessment;
  final LocalAssessmentDraft? draft;
  final AssessmentEvidence? serverEvidence;
  final EvidenceStorageReconciliationResult? evidenceReconciliation;
}

final class AssessmentSubmissionPausedActorMismatch
    extends AssessmentSubmissionOutcome {
  const AssessmentSubmissionPausedActorMismatch({
    required this.localDraftId,
    this.draft,
    required this.message,
    this.cause,
  });

  final String localDraftId;
  final LocalAssessmentDraft? draft;
  final String message;
  final Object? cause;
}

final class AssessmentSubmissionPausedSessionInvalid
    extends AssessmentSubmissionOutcome {
  const AssessmentSubmissionPausedSessionInvalid({
    required this.localDraftId,
    this.draft,
    required this.message,
    this.isServerAuthRejection = false,
    this.cause,
  });

  final String localDraftId;
  final LocalAssessmentDraft? draft;
  final String message;
  final bool isServerAuthRejection;
  final Object? cause;
}

final class AssessmentSubmissionRetryScheduled
    extends AssessmentSubmissionOutcome {
  const AssessmentSubmissionRetryScheduled({
    required this.localDraftId,
    this.draft,
    required this.nextAttemptAt,
    required this.retryCount,
    required this.message,
    this.cause,
  });

  final String localDraftId;
  final LocalAssessmentDraft? draft;
  final DateTime nextAttemptAt;
  final int retryCount;
  final String message;
  final Object? cause;
}

final class AssessmentSubmissionQuarantined
    extends AssessmentSubmissionOutcome {
  const AssessmentSubmissionQuarantined({
    required this.localDraftId,
    this.draft,
    required this.recoveryCode,
    required this.disposition,
    required this.message,
    this.casStatus,
    this.wasPreExistingBlock = false,
    this.cause,
  });

  final String localDraftId;
  final LocalAssessmentDraft? draft;
  final String recoveryCode;
  final DraftRecoveryDisposition disposition;
  final String message;
  final DraftCasStatus? casStatus;
  final bool wasPreExistingBlock;
  final Object? cause;
}

final class AssessmentSubmissionPolicyDenied
    extends AssessmentSubmissionOutcome {
  const AssessmentSubmissionPolicyDenied({
    required this.localDraftId,
    this.draft,
    required this.recoveryCode,
    required this.message,
    this.quarantinedTerminally = true,
    this.cause,
  });

  final String localDraftId;
  final LocalAssessmentDraft? draft;
  final String recoveryCode;
  final String message;
  final bool quarantinedTerminally;
  final Object? cause;
}

final class AssessmentSubmissionLeaseConflict
    extends AssessmentSubmissionOutcome {
  const AssessmentSubmissionLeaseConflict({
    required this.localDraftId,
    this.draft,
    required this.message,
    this.casStatus,
    this.cause,
  });

  final String localDraftId;
  final LocalAssessmentDraft? draft;
  final String message;
  final DraftCasStatus? casStatus;
  final Object? cause;
}

final class TargetAuthorizationDeniedException implements Exception {
  const TargetAuthorizationDeniedException({
    required this.result,
    required this.stage,
  });

  final AdultTargetAuthorizationResult result;
  final RemoteAssessmentStage stage;
}

final class TargetAuthorizationUnverifiedException implements Exception {
  const TargetAuthorizationUnverifiedException({
    required this.result,
    required this.stage,
  });

  final AdultTargetAuthorizationResult result;
  final RemoteAssessmentStage stage;
}

final class _MissingRemoteAssessmentSignal implements Exception {
  const _MissingRemoteAssessmentSignal(this.message);

  final String message;
}

enum RemoteAssessmentStage {
  preDispatch,
  createDraft,
  reconcileDraft,
  uploadAndRegisterEvidence,
  submitAssessment,
}

/// Shared, crash-resumable staged assessment & evidence submission workflow.
///
/// Unifies fresh submission (`neverDispatched`), foreground retry
/// (`foregroundRetry`), and recovery replay (`recovery`) through one leased CAS
/// state machine enforcing:
/// - Durable intent & canonical byte verification before remote dispatch
/// - Mandatory live session validation ([AuthSessionPort.validateForMutation])
///   and target authorization ([RecoveryAuthorizationPort.verifyAssessmentTarget])
///   before every remote stage
/// - Server assessment actor/family/child/content/version reconciliation without
///   speculative version adoption (`version > 1` on `draft`)
/// - Evidence reconciliation on 409 / lost ACK / `LW109`, persisting server DB
///   IDs even when `serverEvidenceId != clientEvidenceId`, while preserving
///   remote bytes (`I03`, `I04`)
/// - Bounded persisted retry backoff (`nextAttemptAt` + [JitterSource]) and
///   fail-closed quarantine envelopes
final class AssessmentSubmissionOrchestrator {
  const AssessmentSubmissionOrchestrator({
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
  }) : _allowUnjournaledForTesting = false;

  /// Explicit isolated constructor for legacy unit tests that bypass durable
  /// local draft journaling.
  const AssessmentSubmissionOrchestrator.unjournaledForTesting({
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
  }) : localDraftStore = null,
       _allowUnjournaledForTesting = true;

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
  final bool _allowUnjournaledForTesting;

  static const int maxFileSizeBytes =
      AssessmentEvidenceStorage.maxFileSizeBytes;

  /// Reconciles or uploads + registers canonical evidence bytes for [assessmentId].
  ///
  /// Restricted to `.unjournaledForTesting` orchestrator instances (e.g.
  /// isolated unit tests via [UploadAssessmentEvidence.unjournaledForTesting]);
  /// production callers must execute the durable staged workflow via [execute].
  Future<
    ({
      AssessmentEvidence evidence,
      EvidenceStorageReconciliationResult? reconciliation,
    })
  >
  reconcileAndRegisterEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
    String? persistedServerEvidenceId,
    bool preCheckServerEvidenceList = false,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
    String? expectedActorUserId,
  }) {
    if (!_allowUnjournaledForTesting) {
      throw StateError(
        'Direct unjournaled reconcileAndRegisterEvidence is restricted to testing; use AssessmentSubmissionOrchestrator.execute() / SubmitAssessmentDraft.',
      );
    }
    return _reconcileOrUploadAndRegisterEvidence(
      familyId: familyId,
      childId: childId,
      assessmentId: assessmentId,
      evidenceId: evidenceId,
      bytes: bytes,
      mediaType: mediaType,
      persistedServerEvidenceId: persistedServerEvidenceId,
      preCheckServerEvidenceList: preCheckServerEvidenceList,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      expectedActorUserId: expectedActorUserId,
    );
  }

  /// Read-only verification of a persisted/registered DB evidence row and its
  /// remote Storage object bytes (SHA-256) without performing any uploads,
  /// registrations, or deletions.
  Future<
    ({
      AssessmentEvidence evidence,
      EvidenceStorageReconciliationResult reconciliation,
    })?
  >
  _verifyRegisteredEvidenceRowAndBytes({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required List<int> bytes,
    required String storagePath,
    required String normalizedMediaType,
    String? persistedServerEvidenceId,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
    required String stageLabel,
    required RemoteAssessmentStage authStage,
  }) async {
    final listAuth = await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: storagePath,
      context: context,
      expectedSessionGeneration:
          expectedSessionGeneration ?? context?.sessionGeneration,
      stage: '$stageLabel list',
    );
    await _verifyTargetOrThrow(
      context: listAuth,
      familyId: familyId,
      childId: childId,
      stage: authStage,
    );

    final rows = await repository.listEvidenceForAssessment(assessmentId);

    if (persistedServerEvidenceId != null &&
        persistedServerEvidenceId.isNotEmpty) {
      for (final row in rows) {
        if (row.id.value == persistedServerEvidenceId &&
            (row.familyId != familyId ||
                row.assessmentId != assessmentId ||
                row.storagePath != storagePath)) {
          throw const EvidenceIdMismatchException(
            message: 'Persisted serverEvidenceId conflicts with server evidence record scope or storagePath.',
          );
        }
      }
    }

    final matches = rows
        .where(
          (row) =>
              row.familyId == familyId &&
              row.assessmentId == assessmentId &&
              row.storagePath == storagePath,
        )
        .toList(growable: false);
    if (matches.length > 1) {
      throw const EvidenceIdMismatchException(
        message: 'Ambiguous duplicate registered evidence records detected for target assessment.',
      );
    }
    if (matches.isEmpty) {
      if (persistedServerEvidenceId != null &&
          persistedServerEvidenceId.isNotEmpty &&
          rows.isNotEmpty) {
        throw const EvidenceIdMismatchException(
          message: 'Server evidence records do not match persisted serverEvidenceId or canonical storagePath.',
        );
      }
      return null;
    }

    final matched = matches.single;
    if (persistedServerEvidenceId != null &&
        persistedServerEvidenceId.isNotEmpty &&
        matched.id.value != persistedServerEvidenceId) {
      throw const EvidenceIdMismatchException(
        message: 'Server evidence record ID conflicts with persisted local serverEvidenceId.',
      );
    }
    if (matched.mediaType.trim().toLowerCase() != normalizedMediaType ||
        matched.fileSizeBytes != bytes.length) {
      throw EvidenceStorageConflictException(
        ContentConflictOutcome(
          storagePath: storagePath,
          localSha256: computeSha256Hex(bytes),
          remoteSha256: '',
          localByteCount: bytes.length,
          remoteByteCount: matched.fileSizeBytes,
          reason: 'Registered evidence metadata conflicts with canonical local bytes.',
        ),
      );
    }

    // Revalidate live session + target authorization immediately before Storage download/reconcile.
    final storageAuth = await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: storagePath,
      context: context ?? listAuth,
      expectedSessionGeneration:
          expectedSessionGeneration ?? listAuth.sessionGeneration,
      stage: '$stageLabel storage reconcile',
    );
    await _verifyTargetOrThrow(
      context: storageAuth,
      familyId: familyId,
      childId: childId,
      stage: authStage,
    );

    final outcome = await storage.reconcileEvidence(
      storagePath: storagePath,
      localBytes: bytes,
      context: storageAuth,
      expectedSessionGeneration:
          expectedSessionGeneration ?? storageAuth.sessionGeneration,
    );
    switch (outcome) {
      case MatchingBytesOutcome():
        return (evidence: matched, reconciliation: outcome);
      case ContentConflictOutcome(:final reason):
        throw EvidenceStorageConflictException(outcome, reason);
      case UnknownOutcome(:final reason):
        throw EvidenceStorageUnknownOutcomeException(outcome, reason);
      case AuthFailureOutcome(:final reason):
        throw EvidenceStorageAuthException(outcome, reason);
    }
  }

  Future<
    ({
      AssessmentEvidence evidence,
      EvidenceStorageReconciliationResult? reconciliation,
    })
  >
  _reconcileOrUploadAndRegisterEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
    String? persistedServerEvidenceId,
    bool preCheckServerEvidenceList = false,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
    String? expectedActorUserId,
  }) async {
    final ext = validateEvidenceUploadPayload(
      bytes: bytes,
      mediaType: mediaType,
    );

    final storagePath =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}.$ext';
    final normalizedMediaType = mediaType.trim().toLowerCase();

    EvidenceStorageReconciliationResult? reconciliation;

    final initialActor = await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: storagePath,
      context: context,
      expectedSessionGeneration:
          expectedSessionGeneration ?? context?.sessionGeneration,
      stage: preCheckServerEvidenceList
          ? 'evidence registration pre-check'
          : 'evidence upload',
    );
    await _verifyTargetOrThrow(
      context: initialActor,
      familyId: familyId,
      childId: childId,
      stage: RemoteAssessmentStage.uploadAndRegisterEvidence,
    );
    var effectiveContext = context ?? initialActor;
    var effectiveGen =
        expectedSessionGeneration ?? initialActor.sessionGeneration;

    if (preCheckServerEvidenceList) {
      final preMatched = await _verifyRegisteredEvidenceRowAndBytes(
        familyId: familyId,
        childId: childId,
        assessmentId: assessmentId,
        bytes: bytes,
        storagePath: storagePath,
        normalizedMediaType: normalizedMediaType,
        persistedServerEvidenceId: persistedServerEvidenceId,
        context: effectiveContext,
        expectedSessionGeneration: effectiveGen,
        stageLabel: 'pre-check evidence reconciliation',
        authStage: RemoteAssessmentStage.uploadAndRegisterEvidence,
      );
      if (preMatched != null) {
        return (
          evidence: preMatched.evidence,
          reconciliation: preMatched.reconciliation,
        );
      }

      // Revalidate live session + target authorization after async pre-check before upload.
      final uploadActor = await assertValidStorageAuthSession(
        authSessionPort: authSessionPort,
        storagePath: storagePath,
        context: context ?? initialActor,
        expectedSessionGeneration: effectiveGen,
        stage: 'evidence upload',
      );
      await _verifyTargetOrThrow(
        context: uploadActor,
        familyId: familyId,
        childId: childId,
        stage: RemoteAssessmentStage.uploadAndRegisterEvidence,
      );
      effectiveContext = context ?? uploadActor;
      effectiveGen = expectedSessionGeneration ?? uploadActor.sessionGeneration;
    }

    // Upload bytes (upsert = false, Storage 409 reconciles bytes via SHA-256).
    await storage.uploadEvidence(
      familyId: familyId,
      childId: childId,
      assessmentId: assessmentId,
      evidenceId: evidenceId,
      bytes: bytes,
      mediaType: mediaType,
      context: effectiveContext,
      expectedSessionGeneration: effectiveGen,
    );

    // Revalidate live session & target authorization before DB registration.
    final validatedActor = await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: storagePath,
      context: effectiveContext,
      expectedSessionGeneration: effectiveGen,
      stage: 'evidence registration',
    );
    await _verifyTargetOrThrow(
      context: validatedActor,
      familyId: familyId,
      childId: childId,
      stage: RemoteAssessmentStage.uploadAndRegisterEvidence,
    );

    try {
      final registered = await repository.registerEvidence(
        assessmentId: assessmentId,
        storagePath: storagePath,
        mediaType: mediaType,
        fileSizeBytes: bytes.length,
      );
      if (persistedServerEvidenceId != null &&
          persistedServerEvidenceId.isNotEmpty &&
          registered.id.value != persistedServerEvidenceId) {
        throw const EvidenceIdMismatchException(
          message: 'Server evidence record ID conflicts with persisted local serverEvidenceId.',
        );
      }
      return (evidence: registered, reconciliation: reconciliation);
    } on BackendRpcException catch (e) {
      if (e.code != 'LW109') {
        rethrow;
      }

      // LW109: Assessment left `draft` (or duplicate constraint hit) — reconcile
      // existing DB evidence rows + Storage bytes without deleting remote bytes (I04).
      final reconActor = await assertValidStorageAuthSession(
        authSessionPort: authSessionPort,
        storagePath: storagePath,
        context: context ?? validatedActor,
        expectedSessionGeneration:
            expectedSessionGeneration ?? validatedActor.sessionGeneration,
        stage: 'LW109 evidence reconciliation',
      );
      await _verifyTargetOrThrow(
        context: reconActor,
        familyId: familyId,
        childId: childId,
        stage: RemoteAssessmentStage.uploadAndRegisterEvidence,
      );
      final remoteAssessment = await repository.getAssessment(assessmentId);
      if (remoteAssessment == null) {
        throw const _MissingRemoteAssessmentSignal(
          'Unable to verify assessment while reconciling LW109 evidence registration.',
        );
      }
      final actorToCheck = expectedActorUserId ?? reconActor.userId;
      if (remoteAssessment.familyId != familyId ||
          remoteAssessment.childId != childId ||
          remoteAssessment.createdByUserId != actorToCheck) {
        throw const EvidenceIdMismatchException(
          message: 'Remote assessment scope or actor conflicts with local draft during LW109 reconciliation.',
        );
      }

      final reconciled = await _verifyRegisteredEvidenceRowAndBytes(
        familyId: familyId,
        childId: childId,
        assessmentId: assessmentId,
        bytes: bytes,
        storagePath: storagePath,
        normalizedMediaType: normalizedMediaType,
        persistedServerEvidenceId: persistedServerEvidenceId,
        context: reconActor,
        expectedSessionGeneration:
            expectedSessionGeneration ?? reconActor.sessionGeneration,
        stageLabel: 'LW109 evidence reconciliation',
        authStage: RemoteAssessmentStage.uploadAndRegisterEvidence,
      );
      if (reconciled != null) {
        return (
          evidence: reconciled.evidence,
          reconciliation: reconciled.reconciliation,
        );
      }

      // Assessment is already non-draft and no matching registered row exists.
      // Retain remote bytes (I04) and quarantine as REGISTRATION_UNRESOLVED_REMOTE_RETAINED.
      throw EvidenceRegistrationUnresolvedRemoteRetainedException(
        storagePath: storagePath,
        message: 'Assessment transitioned out of draft before evidence could be registered; remote bytes retained.',
      );
    }
  }

  /// Executes the full durable, resumable assessment submission state machine.
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
  }) async {
    final normalizedSubject = normalizeAssessmentSubject(subject);
    final normalizedTitle = normalizeAssessmentTitle(title);
    final normalizedOccurredAt = occurredAt != null
        ? normalizeAssessmentOccurredAt(occurredAt)
        : null;
    if (normalizedSubject.isEmpty || normalizedTitle.isEmpty) {
      throw const InvalidAssessmentException(
        'Assessment subject and title must not be empty.',
      );
    }

    if (localDraftStore == null && !_allowUnjournaledForTesting) {
      throw const MissingLocalDraftJournalException(
        reason: 'Submission requires a durable LocalDraftStore unless running unjournaled unit tests.',
      );
    }
    if (localDraftStore == null &&
        localDraftId != null &&
        localDraftId.isNotEmpty) {
      throw MissingLocalDraftJournalException(
        localDraftId: localDraftId,
        reason: 'Unjournaled test mode cannot accept a localDraftId without a durable LocalDraftStore.',
      );
    }

    LocalAssessmentDraft? existingLocal;
    if (localDraftStore != null) {
      if (localDraftId == null || localDraftId.isEmpty) {
        throw const MissingLocalDraftJournalException(
          reason: 'Submission requires a non-empty persisted localDraftId.',
        );
      }
      existingLocal = await localDraftStore!.getLocalDraft(localDraftId);
      if (existingLocal == null) {
        throw MissingLocalDraftJournalException(
          localDraftId: localDraftId,
          reason:
              'Required local draft journal row "$localDraftId" was not found.',
        );
      }

      final preBlock = _checkStructuralPreAuthBlocks(
        existingLocal: existingLocal,
        localDraftId: localDraftId,
        familyId: familyId,
        childId: childId,
        createCommandId: createCommandId,
        submitCommandId: submitCommandId,
      );
      if (preBlock != null) {
        return preBlock;
      }
    }

    // 1. Live session check BEFORE claim or remote interaction (R32-06).
    final ValidatedActorContext initialContext;
    try {
      initialContext = await assertValidStorageAuthSession(
        authSessionPort: authSessionPort,
        storagePath: 'assessment-draft/${localDraftId ?? createCommandId}',
        context: context,
        expectedSessionGeneration:
            expectedSessionGeneration ?? context?.sessionGeneration,
        stage: 'assessment preflight',
      );
    } on EvidenceStorageAuthException catch (e) {
      return _outcomeFromAuthException(
        localDraftId: localDraftId ?? createCommandId,
        draft: existingLocal,
        error: e,
      );
    }

    // 1b. Handle cross-actor mismatch or original-actor return before claiming.
    if (existingLocal != null) {
      if (existingLocal.actorUserId != null &&
          existingLocal.actorUserId != initialContext.userId) {
        LocalAssessmentDraft latestDraft = existingLocal;
        if (!existingLocal.hasWaitingOriginalActorMarker &&
            !existingLocal.hasActiveLease(now: clock.now().toUtc())) {
          final pauseResult = await localDraftStore!.pauseMismatchedActorDraft(
            localDraftId: localDraftId!,
            familyId: existingLocal.familyId,
            authenticatedActorId: initialContext.userId,
            mismatchReason: 'Paused because active session switched away from original draft author.',
            now: clock.now().toUtc(),
          );
          if (pauseResult.draft != null) {
            latestDraft = pauseResult.draft!;
          }
        }
        return AssessmentSubmissionPausedActorMismatch(
          localDraftId: localDraftId!,
          draft: latestDraft,
          message: 'Draft was started by another signed-in account. Sign back in as the original author to resume or cancel.',
          cause: EvidenceStorageAuthException(
            AuthFailureOutcome(
              storagePath: 'assessment-draft/$localDraftId',
              reason: 'Actor switch detected: active session does not match original draft author.',
              actorSwitched: true,
              activeUserId: initialContext.userId,
            ),
          ),
        );
      }

      if (existingLocal.hasWaitingOriginalActorMarker &&
          existingLocal.actorUserId == initialContext.userId) {
        if (!existingLocal.hasActiveLease(now: clock.now().toUtc())) {
          final resumeResult = await localDraftStore!.resumeOriginalActorDraft(
            localDraftId: localDraftId!,
            familyId: existingLocal.familyId,
            authenticatedActorId: initialContext.userId,
            now: clock.now().toUtc(),
          );
          if (resumeResult.isSuccess && resumeResult.draft != null) {
            existingLocal = resumeResult.draft;
          } else if (!resumeResult.isSuccess) {
            if (resumeResult.status == DraftCasStatus.leaseConflict) {
              return AssessmentSubmissionLeaseConflict(
                localDraftId: localDraftId,
                draft: resumeResult.draft ?? existingLocal,
                casStatus: resumeResult.status,
                message:
                    resumeResult.reason ??
                    'Draft is currently claimed by another worker.',
              );
            }
            final fallbackDraft = resumeResult.draft ?? existingLocal;
            return AssessmentSubmissionQuarantined(
              localDraftId: localDraftId,
              draft: fallbackDraft,
              recoveryCode:
                  fallbackDraft.derivedQuarantineCode ??
                  fallbackDraft.recoveryCode ??
                  DraftRecoveryCode.quarantinedUnknownOutcome,
              disposition: fallbackDraft.recoveryDispositionAt(
                now: clock.now().toUtc(),
              ),
              casStatus: resumeResult.status,
              message: sanitizeStorageError(
                resumeResult.reason ?? 'Unable to resume paused draft.',
              ),
            );
          }
        }
      }
    }

    final expectedGen =
        expectedSessionGeneration ??
        context?.sessionGeneration ??
        initialContext.sessionGeneration;

    // 2. Resolve and verify canonical evidence bytes BEFORE claim/network dispatch.
    List<int>? resolvedBytes;
    String? resolvedMediaType;
    EvidenceId? resolvedEvidenceId;
    String? resolvedSha256;
    CanonicalEvidenceValidationException? deferredDispatchedSnapshotFailure;
    Object? deferredDispatchedSnapshotError;
    var missingDispatchedSnapshot = false;

    if (existingLocal == null) {
      if (evidenceBytes != null) {
        if (evidenceMediaType == null || evidenceId == null) {
          throw const InvalidAssessmentException(
            'Evidence metadata is incomplete for attached evidence bytes.',
          );
        }
        validateEvidenceUploadPayload(
          bytes: evidenceBytes,
          mediaType: evidenceMediaType,
        );
        resolvedBytes = evidenceBytes;
        resolvedMediaType = evidenceMediaType;
        resolvedEvidenceId = evidenceId;
      } else if (evidenceMediaType != null || evidenceId != null) {
        throw const InvalidAssessmentException(
          'Evidence metadata provided without attached evidence bytes.',
        );
      }
    } else {
      final localRow = existingLocal;
      final hasLocalEvidenceRef =
          localRow.hasVerifiedEvidenceSnapshot ||
          (localRow.evidenceId?.isNotEmpty ?? false) ||
          (localRow.localPhotoPath?.isNotEmpty ?? false) ||
          (localRow.localCompressedPhotoPath?.isNotEmpty ?? false) ||
          (localRow.sha256Checksum?.isNotEmpty ?? false);
      final hasInputEvidence =
          evidenceBytes != null ||
          evidenceMediaType != null ||
          evidenceId != null;

      if (hasLocalEvidenceRef || hasInputEvidence) {
        if (evidenceBytes != null) {
          if (evidenceMediaType == null) {
            throw const InvalidAssessmentException(
              'Evidence metadata is incomplete for attached evidence bytes.',
            );
          }
          validateEvidenceUploadPayload(
            bytes: evidenceBytes,
            mediaType: evidenceMediaType,
          );
        }

        if (!localRow.hasVerifiedEvidenceSnapshot) {
          if (localRow.dispatchState == CommandDispatchState.neverDispatched) {
            throw MissingCanonicalEvidenceSnapshotException(
              localDraftId: localRow.localDraftId,
              message: 'Evidence-bearing draft requires a durably frozen canonical snapshot before network dispatch.',
            );
          }
          missingDispatchedSnapshot = true;
        } else {
          final boundEvidenceId = localRow.evidenceId!;
          if (evidenceId == null || evidenceId.value != boundEvidenceId) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.acquireLease,
              localDraftId: localRow.localDraftId,
              casStatus: DraftCasStatus.casConflict,
              serverAssessmentId: localRow.serverAssessmentId,
              serverEvidenceId: localRow.serverEvidenceId,
              message: 'Attached evidenceId is required and must match the bound canonical draft evidenceId.',
            );
          }

          if (evidenceBytes != null) {
            try {
              final inspected = verifyCanonicalEvidenceBytes(
                bytes: evidenceBytes,
                expectedSha256: localRow.sha256Checksum!,
                expectedMediaType: evidenceMediaType,
              );
              resolvedBytes = inspected.bytes;
              resolvedMediaType = inspected.mediaType;
              resolvedSha256 = inspected.sha256Checksum;
            } on CanonicalEvidenceValidationException catch (e) {
              if (localRow.dispatchState ==
                  CommandDispatchState.neverDispatched) {
                rethrow;
              }
              deferredDispatchedSnapshotFailure = e;
            }
          } else {
            if (canonicalSnapshotStore == null) {
              if (localRow.dispatchState ==
                  CommandDispatchState.neverDispatched) {
                throw MissingCanonicalEvidenceSnapshotException(
                  localDraftId: localRow.localDraftId,
                  message: 'Canonical snapshot bytes or a CanonicalEvidenceSnapshotStore must be supplied for evidence submission.',
                );
              }
              missingDispatchedSnapshot = true;
            } else {
              try {
                final verified = await canonicalSnapshotStore!
                    .readVerifiedCanonicalSnapshot(draft: localRow);
                if (evidenceMediaType != null &&
                    verified.mediaType != evidenceMediaType) {
                  throw CanonicalEvidenceValidationException(
                    CanonicalEvidenceValidationCode.mediaTypeMismatch,
                    'Canonical evidence media type mismatch: expected $evidenceMediaType, got ${verified.mediaType}.',
                  );
                }
                resolvedBytes = verified.bytes;
                resolvedMediaType = verified.mediaType;
                resolvedSha256 = verified.sha256Checksum;
              } on CanonicalEvidenceValidationException catch (e) {
                if (localRow.dispatchState ==
                    CommandDispatchState.neverDispatched) {
                  rethrow;
                }
                deferredDispatchedSnapshotFailure = e;
              } catch (e) {
                if (localRow.dispatchState ==
                    CommandDispatchState.neverDispatched) {
                  rethrow;
                }
                deferredDispatchedSnapshotError = e;
                final lower = e.toString().toLowerCase();
                if (e is MissingCanonicalEvidenceSnapshotException ||
                    lower.contains('missing')) {
                  missingDispatchedSnapshot = true;
                }
              }
            }
          }
          resolvedEvidenceId = EvidenceId(boundEvidenceId);
        }
      }
    }

    // 3. Pre-claim full payload equality check (R33-07).
    if (existingLocal != null &&
        !missingDispatchedSnapshot &&
        deferredDispatchedSnapshotFailure == null) {
      final preClaimMismatch = _findDraftPayloadMismatch(
        candidate: existingLocal,
        authenticatedActorId: initialContext.userId,
        familyId: familyId,
        childId: childId,
        createCommandId: createCommandId,
        submitCommandId: submitCommandId,
        subjectKey: subjectKey,
        normalizedSubject: normalizedSubject,
        normalizedTitle: normalizedTitle,
        type: type,
        difficulty: difficulty,
        score: score,
        normalizedOccurredAt: normalizedOccurredAt,
        entryContext: entryContext,
        callerEvidenceId: evidenceId,
        resolvedEvidenceId: resolvedEvidenceId,
        resolvedSha256: resolvedSha256,
        expectedCanonicalPath: existingLocal.localCompressedPhotoPath,
        expectedHasEvidence: resolvedBytes != null,
      );
      if (preClaimMismatch != null) {
        throw DraftSubmissionCasException(
          stage: DraftCasFailureStage.acquireLease,
          localDraftId: existingLocal.localDraftId,
          casStatus: DraftCasStatus.casConflict,
          serverAssessmentId: existingLocal.serverAssessmentId,
          serverEvidenceId: existingLocal.serverEvidenceId,
          message:
              'Submission payload does not match persisted local draft journal ($preClaimMismatch).',
        );
      }
    }

    final hasResolvedEvidence = resolvedBytes != null;
    String? activeLeaseToken;
    var completedLocally = false;
    var wasPossiblyDispatchedOnEntry =
        existingLocal?.dispatchState == CommandDispatchState.possiblyDispatched;
    var remoteRpcAttempted =
        wasPossiblyDispatchedOnEntry ||
        (existingLocal?.serverAssessmentId?.isNotEmpty ?? false) ||
        (existingLocal?.serverEvidenceId?.isNotEmpty ?? false);
    String? knownServerAssessmentId = existingLocal?.serverAssessmentId;
    String? knownServerEvidenceId = existingLocal?.serverEvidenceId;
    Object? primaryError;
    LocalAssessmentDraft? currentClaimedDraft = existingLocal;
    var currentRemoteStage = RemoteAssessmentStage.preDispatch;
    EvidenceStorageReconciliationResult? latestReconciliation;
    AssessmentEvidence? latestServerEvidence;

    try {
      try {
        if (existingLocal != null && localDraftId != null) {
          final claimNow = clock.now().toUtc();
          final ignoreBackoff =
              trigger == CommandExecutionTrigger.foregroundRetry;

          var claimResult = await _invokeAcquireClaim(
            localDraftId: localDraftId,
            actorUserId: initialContext.userId,
            familyId: familyId.value,
            childId: childId.value,
            now: claimNow,
            ignoreRetryBackoff: ignoreBackoff,
          );

          // Reclaim expired leases safely on retry/recovery (never steal active leases).
          if (!claimResult.isSuccess &&
              claimResult.status == DraftCasStatus.leaseConflict &&
              claimResult.draft != null &&
              !claimResult.draft!.hasMalformedLease &&
              !claimResult.draft!.hasActiveLease(now: claimNow)) {
            claimResult = await _invokeResumeExpiredClaim(
              localDraftId: localDraftId,
              actorUserId: initialContext.userId,
              familyId: familyId.value,
              childId: childId.value,
              now: claimNow,
              ignoreRetryBackoff: ignoreBackoff,
            );
          }

          if (!claimResult.isSuccess || claimResult.draft?.leaseToken == null) {
            final failingDraft = claimResult.draft ?? existingLocal;
            if (claimResult.status == DraftCasStatus.leaseConflict) {
              return AssessmentSubmissionLeaseConflict(
                localDraftId: localDraftId,
                draft: failingDraft,
                casStatus: claimResult.status,
                message: 'Another submission worker already holds an active lease for this draft.',
              );
            }
            if (claimResult.status == DraftCasStatus.casConflict &&
                failingDraft.nextAttemptAt != null &&
                failingDraft.nextAttemptAt!.isAfter(claimNow)) {
              return AssessmentSubmissionRetryScheduled(
                localDraftId: localDraftId,
                draft: failingDraft,
                nextAttemptAt: failingDraft.nextAttemptAt!,
                retryCount: failingDraft.retryCount,
                message: sanitizeStorageError(
                  failingDraft.lastErrorMessage ??
                      'Submission retry is scheduled after backoff.',
                ),
              );
            }
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.acquireLease,
              localDraftId: localDraftId,
              casStatus: claimResult.status,
              serverAssessmentId: knownServerAssessmentId,
              serverEvidenceId: knownServerEvidenceId,
              message:
                  'Failed to acquire submission lease for draft (${claimResult.status.name}).',
            );
          }

          final claimedDraft = claimResult.draft!;
          currentClaimedDraft = claimedDraft;
          activeLeaseToken = claimedDraft.leaseToken!;
          wasPossiblyDispatchedOnEntry =
              claimedDraft.dispatchState ==
              CommandDispatchState.possiblyDispatched;
          knownServerAssessmentId = claimedDraft.serverAssessmentId;
          knownServerEvidenceId = claimedDraft.serverEvidenceId;
          if (wasPossiblyDispatchedOnEntry ||
              (knownServerAssessmentId?.isNotEmpty ?? false) ||
              (knownServerEvidenceId?.isNotEmpty ?? false)) {
            remoteRpcAttempted = true;
          }

          // Quarantine corrupted/missing canonical snapshot on possiblyDispatched recovery.
          if (missingDispatchedSnapshot ||
              deferredDispatchedSnapshotFailure != null ||
              deferredDispatchedSnapshotError != null) {
            final qCode = missingDispatchedSnapshot
                ? DraftRecoveryCode.localSnapshotMissing
                : deferredDispatchedSnapshotFailure?.code ==
                      CanonicalEvidenceValidationCode.mediaTypeMismatch
                ? DraftRecoveryCode.localMetadataTampered
                : DraftRecoveryCode.localSnapshotCorrupted;
            final outcome = await _quarantineWithLease(
              localDraftId: localDraftId,
              leaseToken: activeLeaseToken,
              actorUserId: initialContext.userId,
              recoveryCode: qCode,
              errorMessage:
                  deferredDispatchedSnapshotFailure?.message ??
                  (deferredDispatchedSnapshotError != null
                      ? sanitizeStorageError(
                          deferredDispatchedSnapshotError.toString(),
                        )
                      : 'Canonical evidence snapshot is missing or corrupted on disk.'),
              cause:
                  deferredDispatchedSnapshotFailure ??
                  deferredDispatchedSnapshotError ??
                  MissingCanonicalEvidenceSnapshotException(
                    localDraftId: localDraftId,
                  ),
            );
            activeLeaseToken = null;
            return outcome;
          }

          // Re-check payload against freshly claimed row (R33-07).
          final postClaimMismatch = _findDraftPayloadMismatch(
            candidate: claimedDraft,
            baselineRow: existingLocal,
            authenticatedActorId: initialContext.userId,
            familyId: familyId,
            childId: childId,
            createCommandId: createCommandId,
            submitCommandId: submitCommandId,
            subjectKey: subjectKey,
            normalizedSubject: normalizedSubject,
            normalizedTitle: normalizedTitle,
            type: type,
            difficulty: difficulty,
            score: score,
            normalizedOccurredAt: normalizedOccurredAt,
            entryContext: entryContext,
            callerEvidenceId: evidenceId,
            resolvedEvidenceId: resolvedEvidenceId,
            resolvedSha256: resolvedSha256,
            expectedCanonicalPath: existingLocal.localCompressedPhotoPath,
            expectedHasEvidence: hasResolvedEvidence,
          );
          if (postClaimMismatch != null) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.acquireLease,
              localDraftId: localDraftId,
              casStatus: DraftCasStatus.casConflict,
              serverAssessmentId: claimedDraft.serverAssessmentId,
              serverEvidenceId: claimedDraft.serverEvidenceId,
              message:
                  'Claimed local draft journal no longer matches intended submission payload ($postClaimMismatch).',
            );
          }

          // 4. Target authorization BEFORE markDraftStageAndDispatch / network RPC (B1-16, B1-17).
          await _verifyTargetOrThrow(
            context: initialContext,
            familyId: familyId,
            childId: childId,
            stage: RemoteAssessmentStage.preDispatch,
          );

          // 5. Durable pre-dispatch stage marker BEFORE any network write.
          final needsStageA =
              knownServerAssessmentId == null ||
              knownServerAssessmentId.isEmpty;
          final needsStageB =
              hasResolvedEvidence &&
              (knownServerEvidenceId == null || knownServerEvidenceId.isEmpty);
          final targetStage =
              (needsStageA || needsStageB) && hasResolvedEvidence
              ? DraftSubmissionStatus.uploadingEvidence
              : DraftSubmissionStatus.submittingAssessment;

          final shouldMarkDispatchStage =
              claimedDraft.dispatchState !=
                  CommandDispatchState.possiblyDispatched ||
              claimedDraft.submissionStatus != targetStage ||
              claimedDraft.recoveryCode == DraftRecoveryCode.retryScheduled;

          if (shouldMarkDispatchStage) {
            final DraftCasResult stageResult;
            try {
              stageResult = await localDraftStore!.markDraftStageAndDispatch(
                localDraftId: localDraftId,
                leaseToken: activeLeaseToken,
                authenticatedActorId: initialContext.userId,
                targetStage: targetStage,
                now: clock.now().toUtc(),
              );
            } catch (e) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.markDispatchStage,
                localDraftId: localDraftId,
                serverAssessmentId: knownServerAssessmentId,
                serverEvidenceId: knownServerEvidenceId,
                message: 'Failed to record pre-dispatch stage due to a local storage error.',
                cause: e,
              );
            }
            if (!stageResult.isSuccess || stageResult.draft == null) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.markDispatchStage,
                localDraftId: localDraftId,
                casStatus: stageResult.status,
                serverAssessmentId: knownServerAssessmentId,
                serverEvidenceId: knownServerEvidenceId,
                message:
                    'Failed to mark pre-dispatch stage (${stageResult.status.name}).',
              );
            }
            currentClaimedDraft = stageResult.draft!;
          }
        } else {
          // Unjournaled test path: still verify target authorization if port supplied.
          await _verifyTargetOrThrow(
            context: initialContext,
            familyId: familyId,
            childId: childId,
            stage: RemoteAssessmentStage.preDispatch,
          );
        }

        // 6. Stage A: Create OR reconcile server draft.
        final Assessment remoteAssessment;
        if (knownServerAssessmentId == null ||
            knownServerAssessmentId.isEmpty) {
          currentRemoteStage = RemoteAssessmentStage.preDispatch;
          final needsPreCreateRevalidation =
              localDraftStore != null ||
              recoveryAuthorizationPort != null ||
              context != null;
          final createAuth = needsPreCreateRevalidation
              ? await assertValidStorageAuthSession(
                  authSessionPort: authSessionPort,
                  storagePath:
                      'assessment-draft/${localDraftId ?? createCommandId}',
                  context: initialContext,
                  expectedSessionGeneration: expectedGen,
                  stage: 'create assessment draft',
                )
              : initialContext;
          await _verifyTargetOrThrow(
            context: createAuth,
            familyId: familyId,
            childId: childId,
            stage: RemoteAssessmentStage.preDispatch,
          );

          currentRemoteStage = RemoteAssessmentStage.createDraft;
          remoteRpcAttempted = true;
          remoteAssessment = await repository.createDraft(
            commandId: createCommandId,
            familyId: familyId,
            childId: childId,
            subjectKey: subjectKey,
            subject: normalizedSubject,
            title: normalizedTitle,
            type: type,
            difficulty: difficulty,
            score: score,
            occurredAt: normalizedOccurredAt ?? occurredAt,
            entryContext: entryContext,
          );
          knownServerAssessmentId = remoteAssessment.id.value;

          final contentMismatch = _findRemoteAssessmentMismatch(
            remote: remoteAssessment,
            expectedActorUserId:
                currentClaimedDraft?.actorUserId ?? createAuth.userId,
            familyId: familyId,
            childId: childId,
            subjectKey: subjectKey,
            normalizedSubject: normalizedSubject,
            normalizedTitle: normalizedTitle,
            type: type,
            difficulty: difficulty,
            score: score,
            normalizedOccurredAt:
                normalizedOccurredAt ??
                (currentClaimedDraft != null
                    ? normalizeAssessmentOccurredAt(
                        currentClaimedDraft.occurredAt,
                      )
                    : null),
            entryContext: entryContext,
          );
          if (contentMismatch != null) {
            if (localDraftId != null && activeLeaseToken != null) {
              final outcome = await _quarantineWithLease(
                localDraftId: localDraftId,
                leaseToken: activeLeaseToken,
                actorUserId: initialContext.userId,
                recoveryCode: DraftRecoveryCode.versionConflict,
                errorMessage:
                    'Server assessment draft does not match local draft ($contentMismatch).',
              );
              activeLeaseToken = null;
              return outcome;
            }
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.persistServerAssessmentId,
              localDraftId: localDraftId ?? createCommandId,
              serverAssessmentId: knownServerAssessmentId,
              message:
                  'Server assessment draft does not match local draft ($contentMismatch).',
            );
          }

          if (localDraftId != null &&
              localDraftStore != null &&
              activeLeaseToken != null) {
            final DraftCasResult persistAssessResult;
            try {
              persistAssessResult = await localDraftStore!
                  .persistServerAssessmentId(
                    localDraftId: localDraftId,
                    leaseToken: activeLeaseToken,
                    authenticatedActorId: initialContext.userId,
                    serverAssessmentId: remoteAssessment.id.value,
                    now: clock.now().toUtc(),
                  );
            } catch (e) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.persistServerAssessmentId,
                localDraftId: localDraftId,
                serverAssessmentId: remoteAssessment.id.value,
                serverEvidenceId: knownServerEvidenceId,
                message: 'Failed to persist serverAssessmentId due to a local storage error.',
                cause: e,
              );
            }
            if (!persistAssessResult.isSuccess ||
                persistAssessResult.draft == null) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.persistServerAssessmentId,
                localDraftId: localDraftId,
                casStatus: persistAssessResult.status,
                serverAssessmentId: remoteAssessment.id.value,
                serverEvidenceId: knownServerEvidenceId,
                message:
                    'Failed to persist serverAssessmentId (${persistAssessResult.status.name}).',
              );
            }
            currentClaimedDraft = persistAssessResult.draft!;
          }
        } else {
          // Resuming with existing serverAssessmentId: fetch & verify server row first.
          currentRemoteStage = RemoteAssessmentStage.reconcileDraft;
          final reconcileAuth = await assertValidStorageAuthSession(
            authSessionPort: authSessionPort,
            storagePath: 'assessment-draft/${localDraftId ?? createCommandId}',
            context: initialContext,
            expectedSessionGeneration: expectedGen,
            stage: 'reconcile assessment draft',
          );
          await _verifyTargetOrThrow(
            context: reconcileAuth,
            familyId: familyId,
            childId: childId,
            stage: RemoteAssessmentStage.reconcileDraft,
          );

          remoteRpcAttempted = true;
          final fetched = await repository.getAssessment(
            AssessmentId(knownServerAssessmentId),
          );
          if (fetched == null) {
            throw const _MissingRemoteAssessmentSignal(
              'Unable to retrieve existing server assessment during recovery reconciliation.',
            );
          }
          remoteAssessment = fetched;

          final contentMismatch = _findRemoteAssessmentMismatch(
            remote: remoteAssessment,
            expectedActorUserId:
                currentClaimedDraft?.actorUserId ?? reconcileAuth.userId,
            familyId: familyId,
            childId: childId,
            subjectKey: subjectKey,
            normalizedSubject: normalizedSubject,
            normalizedTitle: normalizedTitle,
            type: type,
            difficulty: difficulty,
            score: score,
            normalizedOccurredAt:
                normalizedOccurredAt ??
                (currentClaimedDraft != null
                    ? normalizeAssessmentOccurredAt(
                        currentClaimedDraft.occurredAt,
                      )
                    : null),
            entryContext: entryContext,
          );
          if (contentMismatch != null) {
            if (localDraftId != null && activeLeaseToken != null) {
              final outcome = await _quarantineWithLease(
                localDraftId: localDraftId,
                leaseToken: activeLeaseToken,
                actorUserId: initialContext.userId,
                recoveryCode: DraftRecoveryCode.versionConflict,
                errorMessage:
                    'Remote assessment content or provenance conflicts with local draft ($contentMismatch).',
              );
              activeLeaseToken = null;
              return outcome;
            }
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.persistServerAssessmentId,
              localDraftId: localDraftId ?? createCommandId,
              serverAssessmentId: knownServerAssessmentId,
              message:
                  'Remote assessment conflicts with local draft ($contentMismatch).',
            );
          }

          if (remoteAssessment.status == AssessmentStatus.draft &&
              remoteAssessment.version > 1) {
            if (localDraftId != null && activeLeaseToken != null) {
              final outcome = await _quarantineWithLease(
                localDraftId: localDraftId,
                leaseToken: activeLeaseToken,
                actorUserId: initialContext.userId,
                recoveryCode:
                    DraftRecoveryCode.unreconstructableExpectedVersion,
                errorMessage: 'Remote assessment draft mutated to version > 1; cannot safely reconstruct expected version.',
              );
              activeLeaseToken = null;
              return outcome;
            }
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.markSubmittingStage,
              localDraftId: localDraftId ?? createCommandId,
              serverAssessmentId: knownServerAssessmentId,
              message: 'Remote assessment draft mutated to version > 1.',
            );
          }
        }

        // Guard version > 1 on newly returned draft too (if concurrent update happened).
        if (remoteAssessment.status == AssessmentStatus.draft &&
            remoteAssessment.version > 1 &&
            localDraftId != null &&
            activeLeaseToken != null) {
          final outcome = await _quarantineWithLease(
            localDraftId: localDraftId,
            leaseToken: activeLeaseToken,
            actorUserId: initialContext.userId,
            recoveryCode: DraftRecoveryCode.unreconstructableExpectedVersion,
            errorMessage: 'Remote assessment draft mutated to version > 1; cannot safely reconstruct expected version.',
          );
          activeLeaseToken = null;
          return outcome;
        }

        // 7. Stage B: Reconcile or upload + register evidence and persist serverEvidenceId.
        if (hasResolvedEvidence) {
          final hasPersistedEvidenceId =
              knownServerEvidenceId != null && knownServerEvidenceId.isNotEmpty;
          final isNonDraftRemote =
              remoteAssessment.status != AssessmentStatus.draft;
          if (hasPersistedEvidenceId || isNonDraftRemote) {
            currentRemoteStage =
                RemoteAssessmentStage.uploadAndRegisterEvidence;
            remoteRpcAttempted = true;
            final ext = validateEvidenceUploadPayload(
              bytes: resolvedBytes,
              mediaType: resolvedMediaType!,
            );
            final expectedStoragePath =
                '${familyId.value}/${childId.value}/${remoteAssessment.id.value}/${resolvedEvidenceId!.value}.$ext';
            final verified = await _verifyRegisteredEvidenceRowAndBytes(
              familyId: familyId,
              childId: childId,
              assessmentId: remoteAssessment.id,
              bytes: resolvedBytes,
              storagePath: expectedStoragePath,
              normalizedMediaType: resolvedMediaType.trim().toLowerCase(),
              persistedServerEvidenceId: knownServerEvidenceId,
              context: initialContext,
              expectedSessionGeneration: expectedGen,
              stageLabel: isNonDraftRemote
                  ? 'non-draft read-only evidence verification'
                  : 'persisted evidence verification',
              authStage: RemoteAssessmentStage.uploadAndRegisterEvidence,
            );
            if (verified == null) {
              throw EvidenceRegistrationUnresolvedRemoteRetainedException(
                storagePath: expectedStoragePath,
                message: isNonDraftRemote
                    ? 'Assessment is non-draft and no matching registered evidence record exists; retaining remote bytes without upload/register.'
                    : 'Registered server evidence record could not be verified on server (missing or RLS-filtered).',
              );
            }
            latestServerEvidence = verified.evidence;
            latestReconciliation = verified.reconciliation;
            knownServerEvidenceId = verified.evidence.id.value;
          } else {
            currentRemoteStage =
                RemoteAssessmentStage.uploadAndRegisterEvidence;
            remoteRpcAttempted = true;
            final evResult = await _reconcileOrUploadAndRegisterEvidence(
              familyId: familyId,
              childId: childId,
              assessmentId: remoteAssessment.id,
              evidenceId: resolvedEvidenceId!,
              bytes: resolvedBytes,
              mediaType: resolvedMediaType!,
              persistedServerEvidenceId: knownServerEvidenceId,
              preCheckServerEvidenceList: wasPossiblyDispatchedOnEntry,
              context: initialContext,
              expectedSessionGeneration: expectedGen,
              expectedActorUserId:
                  currentClaimedDraft?.actorUserId ?? initialContext.userId,
            );
            latestServerEvidence = evResult.evidence;
            latestReconciliation = evResult.reconciliation;
            knownServerEvidenceId = evResult.evidence.id.value;
          }

          if (!hasPersistedEvidenceId &&
              localDraftId != null &&
              localDraftStore != null &&
              activeLeaseToken != null) {
            final DraftCasResult persistEvidenceResult;
            try {
              persistEvidenceResult = await localDraftStore!
                  .persistServerEvidenceId(
                    localDraftId: localDraftId,
                    leaseToken: activeLeaseToken,
                    authenticatedActorId: initialContext.userId,
                    serverEvidenceId: knownServerEvidenceId,
                    expectedEvidenceId: resolvedEvidenceId.value,
                    expectedSha256Checksum: resolvedSha256!,
                    now: clock.now().toUtc(),
                  );
            } catch (e) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.persistServerEvidenceId,
                localDraftId: localDraftId,
                serverAssessmentId: remoteAssessment.id.value,
                serverEvidenceId: knownServerEvidenceId,
                message: 'Failed to persist serverEvidenceId due to a local storage error.',
                cause: e,
              );
            }
            if (!persistEvidenceResult.isSuccess ||
                persistEvidenceResult.draft == null) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.persistServerEvidenceId,
                localDraftId: localDraftId,
                casStatus: persistEvidenceResult.status,
                serverAssessmentId: remoteAssessment.id.value,
                serverEvidenceId: knownServerEvidenceId,
                message:
                    'Failed to persist serverEvidenceId (${persistEvidenceResult.status.name}).',
              );
            }
            currentClaimedDraft = persistEvidenceResult.draft!;
          }

          if (localDraftId != null &&
              localDraftStore != null &&
              activeLeaseToken != null &&
              currentClaimedDraft?.submissionStatus !=
                  DraftSubmissionStatus.submittingAssessment) {
            final DraftCasResult submitStageResult;
            try {
              submitStageResult = await localDraftStore!
                  .markDraftStageAndDispatch(
                    localDraftId: localDraftId,
                    leaseToken: activeLeaseToken,
                    authenticatedActorId: initialContext.userId,
                    targetStage: DraftSubmissionStatus.submittingAssessment,
                    now: clock.now().toUtc(),
                  );
            } catch (e) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.markSubmittingStage,
                localDraftId: localDraftId,
                serverAssessmentId: remoteAssessment.id.value,
                serverEvidenceId: knownServerEvidenceId,
                message: 'Failed to advance local draft stage before submitAssessment due to a local storage error.',
                cause: e,
              );
            }
            if (!submitStageResult.isSuccess ||
                submitStageResult.draft == null) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.markSubmittingStage,
                localDraftId: localDraftId,
                casStatus: submitStageResult.status,
                serverAssessmentId: remoteAssessment.id.value,
                serverEvidenceId: knownServerEvidenceId,
                message:
                    'Failed to advance local draft stage before submitAssessment (${submitStageResult.status.name}).',
              );
            }
            currentClaimedDraft = submitStageResult.draft!;
          }
        }

        // 8. Stage C: Revalidate live session + target authorization, then submit (expectedVersion: 1).
        currentRemoteStage = RemoteAssessmentStage.submitAssessment;
        final submitAuth = await assertValidStorageAuthSession(
          authSessionPort: authSessionPort,
          storagePath: 'assessment-draft/${localDraftId ?? createCommandId}',
          context: initialContext,
          expectedSessionGeneration: expectedGen,
          stage: 'submit assessment',
        );
        await _verifyTargetOrThrow(
          context: submitAuth,
          familyId: familyId,
          childId: childId,
          stage: RemoteAssessmentStage.submitAssessment,
        );

        remoteRpcAttempted = true;
        final submitted = await repository.submitAssessment(
          assessmentId: remoteAssessment.id,
          commandId: submitCommandId,
          expectedVersion: 1,
        );

        final submittedMismatch = _findRemoteAssessmentMismatch(
          remote: submitted,
          expectedActorUserId:
              currentClaimedDraft?.actorUserId ?? submitAuth.userId,
          familyId: familyId,
          childId: childId,
          subjectKey: subjectKey,
          normalizedSubject: normalizedSubject,
          normalizedTitle: normalizedTitle,
          type: type,
          difficulty: difficulty,
          score: score,
          normalizedOccurredAt:
              normalizedOccurredAt ??
              (currentClaimedDraft != null
                  ? normalizeAssessmentOccurredAt(
                      currentClaimedDraft.occurredAt,
                    )
                  : null),
          entryContext: entryContext,
        );
        if (submittedMismatch != null) {
          if (localDraftId != null && activeLeaseToken != null) {
            final outcome = await _quarantineWithLease(
              localDraftId: localDraftId,
              leaseToken: activeLeaseToken,
              actorUserId: initialContext.userId,
              recoveryCode: DraftRecoveryCode.versionConflict,
              errorMessage:
                  'Submitted remote assessment conflicts with local draft ($submittedMismatch).',
            );
            activeLeaseToken = null;
            return outcome;
          }
          throw DraftSubmissionCasException(
            stage: DraftCasFailureStage.completeSubmission,
            localDraftId: localDraftId ?? createCommandId,
            serverAssessmentId: submitted.id.value,
            message:
                'Submitted remote assessment conflicts with local draft ($submittedMismatch).',
          );
        }

        // 9. Durable local completion (`confirmedCommitted` tombstone).
        LocalAssessmentDraft? finalDraft = currentClaimedDraft;
        if (localDraftId != null &&
            localDraftStore != null &&
            activeLeaseToken != null) {
          final DraftCasResult completion;
          try {
            completion = await localDraftStore!.completeDraftSubmission(
              localDraftId: localDraftId,
              leaseToken: activeLeaseToken,
              authenticatedActorId: initialContext.userId,
              serverAssessmentId: submitted.id.value,
              serverEvidenceId: knownServerEvidenceId,
              now: clock.now().toUtc(),
            );
          } catch (e) {
            throw AssessmentReconciliationPendingException(
              submittedAssessment: submitted,
              localDraftId: localDraftId,
              serverEvidenceId: knownServerEvidenceId,
              message: 'Assessment submitted remotely, but local completion persistence failed.',
              cause: e,
            );
          }

          final committedDraft = completion.draft;
          final bool hasMatchingServerAssessment =
              committedDraft != null &&
              committedDraft.serverAssessmentId == submitted.id.value;
          final bool hasMatchingServerEvidence = knownServerEvidenceId != null
              ? committedDraft?.serverEvidenceId == knownServerEvidenceId
              : committedDraft?.serverEvidenceId == null;
          final committedSuccessfully =
              completion.isSuccess ||
              (completion.status == DraftCasStatus.alreadyCommitted &&
                  hasMatchingServerAssessment &&
                  hasMatchingServerEvidence);
          if (!committedSuccessfully) {
            throw AssessmentReconciliationPendingException(
              submittedAssessment: submitted,
              localDraftId: localDraftId,
              serverEvidenceId: knownServerEvidenceId,
              casStatus: completion.status,
              message:
                  'Assessment submitted remotely, but local completion was rejected (${completion.status.name}).',
            );
          }
          finalDraft = committedDraft ?? finalDraft;
          completedLocally = true;
          activeLeaseToken = null;
        }

        return AssessmentSubmissionConfirmed(
          assessment: submitted,
          draft: finalDraft,
          serverEvidence: latestServerEvidence,
          evidenceReconciliation: latestReconciliation,
        );
      } catch (e) {
        // Handle recoverable/quarantinable failures inside the active lease before finally.
        if (e is DraftSubmissionCasException ||
            e is AssessmentReconciliationPendingException ||
            e is MissingLocalDraftJournalException ||
            e is MissingCanonicalEvidenceSnapshotException ||
            e is InvalidAssessmentException) {
          primaryError = e;
          rethrow;
        }

        if (localDraftStore != null && localDraftId != null) {
          final handled = await _handleExecutionError(
            error: e,
            stage: currentRemoteStage,
            localDraftId: localDraftId,
            familyId: familyId,
            childId: childId,
            actorContext: initialContext,
            claimedDraft: currentClaimedDraft,
            leaseToken: activeLeaseToken,
            wasAlreadyPossiblyDispatched:
                wasPossiblyDispatchedOnEntry || remoteRpcAttempted,
            serverAssessmentId: knownServerAssessmentId,
            releaseActiveLease: () async {
              if (activeLeaseToken == null) return;
              final tok = activeLeaseToken!;
              activeLeaseToken = null;
              try {
                final rel = await localDraftStore!.releaseDraftClaim(
                  localDraftId: localDraftId,
                  leaseToken: tok,
                  authenticatedActorId: initialContext.userId,
                  now: clock.now().toUtc(),
                );
                if (!rel.isSuccess &&
                    rel.status != DraftCasStatus.notFound &&
                    rel.status != DraftCasStatus.alreadyCommitted) {
                  onLeaseReleaseFailure?.call(
                    localDraftId: localDraftId,
                    status: rel.status,
                  );
                }
              } catch (relErr) {
                onLeaseReleaseFailure?.call(
                  localDraftId: localDraftId,
                  error: relErr,
                );
              }
            },
            clearLeaseToken: () {
              activeLeaseToken = null;
            },
          );
          if (handled != null) {
            return handled;
          }
        }

        primaryError = e;
        rethrow;
      }
    } finally {
      if (!completedLocally &&
          activeLeaseToken != null &&
          localDraftId != null &&
          localDraftStore != null) {
        try {
          final leaseTokenToRelease = activeLeaseToken!;
          final releaseResult = await localDraftStore!.releaseDraftClaim(
            localDraftId: localDraftId,
            leaseToken: leaseTokenToRelease,
            authenticatedActorId: initialContext.userId,
            now: clock.now().toUtc(),
          );
          if (!releaseResult.isSuccess &&
              releaseResult.status != DraftCasStatus.notFound &&
              releaseResult.status != DraftCasStatus.alreadyCommitted) {
            onLeaseReleaseFailure?.call(
              localDraftId: localDraftId,
              status: releaseResult.status,
            );
            if (primaryError == null) {
              throw DraftSubmissionCasException(
                stage: DraftCasFailureStage.releaseDraftClaim,
                localDraftId: localDraftId,
                casStatus: releaseResult.status,
                serverAssessmentId: knownServerAssessmentId,
                serverEvidenceId: knownServerEvidenceId,
                message:
                    'Failed to release submission lease (${releaseResult.status.name}).',
              );
            }
          }
        } catch (releaseError) {
          if (releaseError is DraftSubmissionCasException &&
              releaseError.stage == DraftCasFailureStage.releaseDraftClaim) {
            rethrow;
          }
          onLeaseReleaseFailure?.call(
            localDraftId: localDraftId,
            error: releaseError,
          );
          if (primaryError == null) {
            throw DraftSubmissionCasException(
              stage: DraftCasFailureStage.releaseDraftClaim,
              localDraftId: localDraftId,
              serverAssessmentId: knownServerAssessmentId,
              serverEvidenceId: knownServerEvidenceId,
              message: 'Failed to release submission lease due to a local storage error.',
              cause: releaseError,
            );
          }
        }
      }
    }
  }

  Future<DraftCasResult> _invokeAcquireClaim({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required DateTime now,
    required bool ignoreRetryBackoff,
  }) async {
    try {
      return await localDraftStore!.acquireDraftClaim(
        localDraftId: localDraftId,
        actorUserId: actorUserId,
        familyId: familyId,
        childId: childId,
        leaseDuration: leaseDuration,
        now: now,
        ignoreRetryBackoff: ignoreRetryBackoff,
      );
    } catch (e) {
      throw DraftSubmissionCasException(
        stage: DraftCasFailureStage.acquireLease,
        localDraftId: localDraftId,
        message:
            'Failed to acquire submission lease due to a local storage error.',
        cause: e,
      );
    }
  }

  Future<DraftCasResult> _invokeResumeExpiredClaim({
    required String localDraftId,
    required String actorUserId,
    required String familyId,
    required String childId,
    required DateTime now,
    required bool ignoreRetryBackoff,
  }) async {
    try {
      return await localDraftStore!.resumeDraftClaimAfterExpiry(
        localDraftId: localDraftId,
        actorUserId: actorUserId,
        familyId: familyId,
        childId: childId,
        leaseDuration: leaseDuration,
        now: now,
        ignoreRetryBackoff: ignoreRetryBackoff,
      );
    } catch (e) {
      throw DraftSubmissionCasException(
        stage: DraftCasFailureStage.acquireLease,
        localDraftId: localDraftId,
        message: 'Failed to reclaim expired submission lease due to a local storage error.',
        cause: e,
      );
    }
  }

  AssessmentSubmissionOutcome? _checkStructuralPreAuthBlocks({
    required LocalAssessmentDraft existingLocal,
    required String localDraftId,
    required FamilyId familyId,
    required ChildId childId,
    required String createCommandId,
    required String submitCommandId,
  }) {
    if (existingLocal.isLegacyUnknown) {
      final err = StateError(
        'Cannot submit quarantined legacy assessment draft (id: $localDraftId). '
        'Draft is in unknown_legacy dispatch state and requires reconciliation before submission.',
      );
      return AssessmentSubmissionQuarantined(
        localDraftId: localDraftId,
        draft: existingLocal,
        recoveryCode: DraftRecoveryCode.legacyUnknown,
        disposition: DraftRecoveryDisposition.quarantinedLegacyUnknown,
        message: sanitizeStorageError(err.message),
        casStatus: DraftCasStatus.blockedQuarantined,
        wasPreExistingBlock: true,
        cause: err,
      );
    }
    if (existingLocal.hasUnboundActor) {
      final err = StateError(
        'Cannot submit quarantined assessment draft (id: $localDraftId) without bound original actor provenance.',
      );
      return AssessmentSubmissionQuarantined(
        localDraftId: localDraftId,
        draft: existingLocal,
        recoveryCode: DraftRecoveryCode.unboundActorProvenance,
        disposition: DraftRecoveryDisposition.quarantinedUnknownOutcome,
        message: sanitizeStorageError(err.message),
        casStatus: DraftCasStatus.blockedQuarantined,
        wasPreExistingBlock: true,
        cause: err,
      );
    }
    if (existingLocal.hasMalformedLease ||
        existingLocal.isReadOnlyQuarantined ||
        existingLocal.submissionStatus == DraftSubmissionStatus.terminalError ||
        (existingLocal.hasRecoveryMarker &&
            existingLocal.recoveryCode != DraftRecoveryCode.retryScheduled &&
            existingLocal.recoveryCode !=
                DraftRecoveryCode.waitingOriginalActor)) {
      final err = StateError(
        'Cannot submit quarantined or paused assessment draft (id: $localDraftId).',
      );
      return AssessmentSubmissionQuarantined(
        localDraftId: localDraftId,
        draft: existingLocal,
        recoveryCode:
            existingLocal.derivedQuarantineCode ??
            existingLocal.recoveryCode ??
            DraftRecoveryCode.quarantinedUnknownOutcome,
        disposition: existingLocal.recoveryDispositionAt(
          now: clock.now().toUtc(),
        ),
        message: sanitizeStorageError(
          existingLocal.lastErrorMessage ?? err.message,
        ),
        casStatus: DraftCasStatus.blockedQuarantined,
        wasPreExistingBlock: true,
        cause: err,
      );
    }
    if (existingLocal.dispatchState ==
        CommandDispatchState.confirmedCommitted) {
      final err = StateError(
        'Cannot submit already confirmed_committed assessment draft (id: $localDraftId).',
      );
      return AssessmentSubmissionQuarantined(
        localDraftId: localDraftId,
        draft: existingLocal,
        recoveryCode: DraftRecoveryCode.quarantinedUnknownOutcome,
        disposition: DraftRecoveryDisposition.confirmedSubmitted,
        message: err.message,
        casStatus: DraftCasStatus.alreadyCommitted,
        wasPreExistingBlock: true,
        cause: err,
      );
    }
    if (existingLocal.familyId != familyId.value ||
        existingLocal.childId != childId.value) {
      final err = StateError(
        'Cannot submit assessment draft (id: $localDraftId) across mismatched family or child scope.',
      );
      return AssessmentSubmissionQuarantined(
        localDraftId: localDraftId,
        draft: existingLocal,
        recoveryCode: DraftRecoveryCode.quarantinedUnknownOutcome,
        disposition: existingLocal.recoveryDispositionAt(
          now: clock.now().toUtc(),
        ),
        message: err.message,
        casStatus: DraftCasStatus.familyOrChildMismatch,
        wasPreExistingBlock: true,
        cause: err,
      );
    }
    if (existingLocal.dispatchState ==
            CommandDispatchState.possiblyDispatched &&
        ((existingLocal.createCommandId != null &&
                existingLocal.createCommandId != createCommandId) ||
            (existingLocal.submitCommandId != null &&
                existingLocal.submitCommandId != submitCommandId))) {
      final err = StateError(
        'Cannot submit possibly_dispatched assessment draft (id: $localDraftId) with mismatched command IDs.',
      );
      return AssessmentSubmissionQuarantined(
        localDraftId: localDraftId,
        draft: existingLocal,
        recoveryCode: DraftRecoveryCode.localMetadataTampered,
        disposition: DraftRecoveryDisposition.quarantinedConflict,
        message: err.message,
        casStatus: DraftCasStatus.casConflict,
        wasPreExistingBlock: true,
        cause: err,
      );
    }
    return null;
  }

  Future<void> _verifyTargetOrThrow({
    required ValidatedActorContext context,
    required FamilyId familyId,
    required ChildId childId,
    required RemoteAssessmentStage stage,
  }) async {
    final port = recoveryAuthorizationPort;
    if (port == null) {
      if (_allowUnjournaledForTesting) return;
      throw StateError(
        'RecoveryAuthorizationPort is required for assessment target verification.',
      );
    }
    final result = await port.verifyAssessmentTarget(
      context: context,
      familyId: familyId.value,
      childId: childId.value,
    );
    switch (result.status) {
      case TargetAuthorizationStatus.authorized:
        return;
      case TargetAuthorizationStatus.confirmedRevoked:
      case TargetAuthorizationStatus.definitelyDenied:
        throw TargetAuthorizationDeniedException(result: result, stage: stage);
      case TargetAuthorizationStatus.unverified:
        throw TargetAuthorizationUnverifiedException(
          result: result,
          stage: stage,
        );
    }
  }

  AssessmentSubmissionOutcome _outcomeFromAuthException({
    required String localDraftId,
    required LocalAssessmentDraft? draft,
    required EvidenceStorageAuthException error,
  }) {
    if (error.result.actorSwitched) {
      return AssessmentSubmissionPausedActorMismatch(
        localDraftId: localDraftId,
        draft: draft,
        message: error.message,
        cause: error,
      );
    }
    return AssessmentSubmissionPausedSessionInvalid(
      localDraftId: localDraftId,
      draft: draft,
      message: error.message,
      isServerAuthRejection: error.result.isServerHttpAuthRejection,
      cause: error,
    );
  }

  Future<AssessmentSubmissionOutcome?> _handleExecutionError({
    required Object error,
    required RemoteAssessmentStage stage,
    required String localDraftId,
    required FamilyId familyId,
    required ChildId childId,
    required ValidatedActorContext actorContext,
    required LocalAssessmentDraft? claimedDraft,
    required String? leaseToken,
    required bool wasAlreadyPossiblyDispatched,
    required String? serverAssessmentId,
    required Future<void> Function() releaseActiveLease,
    required void Function() clearLeaseToken,
  }) async {
    if (error is EvidenceStorageAuthException) {
      await releaseActiveLease();
      LocalAssessmentDraft? updatedDraft = claimedDraft;
      if (error.result.actorSwitched && error.result.activeUserId != null) {
        final refreshed = await localDraftStore!.getLocalDraft(localDraftId);
        if (refreshed != null &&
            !refreshed.hasWaitingOriginalActorMarker &&
            !refreshed.isReadOnlyQuarantined &&
            refreshed.actorUserId != null &&
            refreshed.actorUserId != error.result.activeUserId &&
            !refreshed.hasActiveLease(now: clock.now().toUtc())) {
          final paused = await localDraftStore!.pauseMismatchedActorDraft(
            localDraftId: localDraftId,
            familyId: familyId.value,
            authenticatedActorId: error.result.activeUserId!,
            mismatchReason: error.message,
            now: clock.now().toUtc(),
          );
          if (paused.draft != null) {
            updatedDraft = paused.draft;
          }
        }
        return AssessmentSubmissionPausedActorMismatch(
          localDraftId: localDraftId,
          draft: updatedDraft,
          message: error.message,
          cause: error,
        );
      }
      updatedDraft = await localDraftStore!.getLocalDraft(localDraftId);
      return AssessmentSubmissionPausedSessionInvalid(
        localDraftId: localDraftId,
        draft: updatedDraft,
        message: error.message,
        isServerAuthRejection: error.result.isServerHttpAuthRejection,
        cause: error,
      );
    }

    if (leaseToken == null) {
      return null;
    }

    if (error is EvidenceStorageConflictException) {
      final res = await _quarantineWithLease(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        recoveryCode: DraftRecoveryCode.storageContentConflict,
        errorMessage: error.message,
        cause: error,
      );
      clearLeaseToken();
      return res;
    }

    if (error is EvidenceIdMismatchException) {
      final res = await _quarantineWithLease(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        recoveryCode: DraftRecoveryCode.evidenceIdMismatch,
        errorMessage: error.message,
        cause: error,
      );
      clearLeaseToken();
      return res;
    }

    if (error is EvidenceRegistrationUnresolvedRemoteRetainedException) {
      final res = await _quarantineWithLease(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        recoveryCode: DraftRecoveryCode.registrationUnresolvedRemoteRetained,
        errorMessage: error.message,
        cause: error,
      );
      clearLeaseToken();
      return res;
    }

    if (error is TargetAuthorizationDeniedException) {
      final canDeclareTerminalNegative =
          !wasAlreadyPossiblyDispatched &&
          serverAssessmentId == null &&
          error.stage != RemoteAssessmentStage.submitAssessment &&
          error.result.reason !=
              AdultTargetVerificationReason.childConfirmedArchived;
      final code = canDeclareTerminalNegative
          ? DraftRecoveryCode.terminalPolicyDenial
          : DraftRecoveryCode.ambiguous42501Outcome;
      final msg = canDeclareTerminalNegative
          ? 'Authorization revoked or denied before remote submission.'
          : 'Authorization or child archival encountered after possible dispatch; preserving ambiguous state.';
      final quarantined = await _quarantineWithLease(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        recoveryCode: code,
        errorMessage: msg,
        cause: error,
      );
      clearLeaseToken();
      if (canDeclareTerminalNegative) {
        return AssessmentSubmissionPolicyDenied(
          localDraftId: localDraftId,
          draft: quarantined.draft,
          recoveryCode: code,
          message: msg,
          quarantinedTerminally: true,
          cause: error,
        );
      }
      return quarantined;
    }

    if (error is TargetAuthorizationUnverifiedException) {
      final outcome = await _scheduleRetryOrQuarantineCap(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        currentRetryCount: claimedDraft?.retryCount ?? 0,
        sanitizedMessage: 'Unable to verify target authorization over network; retry scheduled.',
        capQuarantineCode: DraftRecoveryCode.ambiguous42501Outcome,
        cause: error,
      );
      clearLeaseToken();
      return outcome;
    }

    if (error is _MissingRemoteAssessmentSignal) {
      final outcome = await _recheckAuthzAfterRpcFailure(
        code: '42501',
        stage: stage,
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorContext: actorContext,
        familyId: familyId,
        childId: childId,
        wasAlreadyPossiblyDispatched: true,
        serverAssessmentId: serverAssessmentId,
        currentRetryCount: claimedDraft?.retryCount ?? 0,
        fallbackMessage: error.message,
        cause: error,
      );
      clearLeaseToken();
      return outcome;
    }

    if (error is BackendRpcException) {
      final rpcCode = error.code?.trim();
      if (rpcCode == '42501' || rpcCode == 'LW001' || rpcCode == 'LW105') {
        final outcome = await _recheckAuthzAfterRpcFailure(
          code: rpcCode!,
          stage: stage,
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          actorContext: actorContext,
          familyId: familyId,
          childId: childId,
          wasAlreadyPossiblyDispatched: wasAlreadyPossiblyDispatched,
          serverAssessmentId: serverAssessmentId,
          currentRetryCount: claimedDraft?.retryCount ?? 0,
          fallbackMessage: sanitizeStorageError(error.message),
          cause: error,
        );
        clearLeaseToken();
        return outcome;
      }
      if (rpcCode == 'LW101') {
        final res = await _quarantineWithLease(
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          actorUserId: actorContext.userId,
          recoveryCode: DraftRecoveryCode.versionConflict,
          errorMessage: sanitizeStorageError(error.message),
          cause: error,
        );
        clearLeaseToken();
        return res;
      }
      if (rpcCode == 'LW107') {
        final res = await _quarantineWithLease(
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          actorUserId: actorContext.userId,
          recoveryCode: DraftRecoveryCode.ambiguousSubmitOutcome,
          errorMessage: sanitizeStorageError(error.message),
          cause: error,
        );
        clearLeaseToken();
        return res;
      }
      if (rpcCode == '500' ||
          rpcCode == '502' ||
          rpcCode == '503' ||
          rpcCode == '504' ||
          _isTransientNetworkError(error)) {
        final res = await _scheduleRetryOrQuarantineCap(
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          actorUserId: actorContext.userId,
          currentRetryCount: claimedDraft?.retryCount ?? 0,
          sanitizedMessage: 'Temporary server error during assessment submission. Retry scheduled.',
          capQuarantineCode: DraftRecoveryCode.quarantinedUnknownOutcome,
          cause: error,
        );
        clearLeaseToken();
        return res;
      }
      final res = await _quarantineWithLease(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        recoveryCode: DraftRecoveryCode.quarantinedUnknownOutcome,
        errorMessage: sanitizeStorageError(error.message),
        cause: error,
      );
      clearLeaseToken();
      return res;
    }

    if (_isTransientNetworkError(error)) {
      final res = await _scheduleRetryOrQuarantineCap(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        currentRetryCount: claimedDraft?.retryCount ?? 0,
        sanitizedMessage: 'Network communication failure. Retry scheduled.',
        capQuarantineCode: DraftRecoveryCode.quarantinedUnknownOutcome,
        cause: error,
      );
      clearLeaseToken();
      return res;
    }

    return null;
  }

  Future<AssessmentSubmissionOutcome> _recheckAuthzAfterRpcFailure({
    required String code,
    required RemoteAssessmentStage stage,
    required String localDraftId,
    required String leaseToken,
    required ValidatedActorContext actorContext,
    required FamilyId familyId,
    required ChildId childId,
    required bool wasAlreadyPossiblyDispatched,
    required String? serverAssessmentId,
    required int currentRetryCount,
    required String fallbackMessage,
    required Object cause,
  }) async {
    final port = recoveryAuthorizationPort;
    if (port == null) {
      return _quarantineWithLease(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        recoveryCode: DraftRecoveryCode.ambiguous42501Outcome,
        errorMessage: fallbackMessage,
        cause: cause,
      );
    }

    AdultTargetAuthorizationResult authz;
    try {
      authz = await port.verifyAssessmentTarget(
        context: actorContext,
        familyId: familyId.value,
        childId: childId.value,
      );
    } catch (_) {
      return _scheduleRetryOrQuarantineCap(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorContext.userId,
        currentRetryCount: currentRetryCount,
        sanitizedMessage:
            'Unable to verify permissions after authorization error ($code); retry scheduled.',
        capQuarantineCode: DraftRecoveryCode.ambiguous42501Outcome,
        cause: cause,
      );
    }

    switch (authz.status) {
      case TargetAuthorizationStatus.unverified:
        return _scheduleRetryOrQuarantineCap(
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          actorUserId: actorContext.userId,
          currentRetryCount: currentRetryCount,
          sanitizedMessage:
              'Authorization state could not be confirmed after $code; retry scheduled.',
          capQuarantineCode: DraftRecoveryCode.ambiguous42501Outcome,
          cause: cause,
        );
      case TargetAuthorizationStatus.authorized:
        // Authorized per lookup yet server returned 42501/LW001/LW105 -> ambiguous!
        return _quarantineWithLease(
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          actorUserId: actorContext.userId,
          recoveryCode: DraftRecoveryCode.ambiguous42501Outcome,
          errorMessage:
              'Backend denied request ($code) despite active membership; preserving unknown outcome.',
          cause: cause,
        );
      case TargetAuthorizationStatus.confirmedRevoked:
      case TargetAuthorizationStatus.definitelyDenied:
        final isConfirmedPreSubmitNegative =
            !wasAlreadyPossiblyDispatched &&
            stage == RemoteAssessmentStage.preDispatch &&
            serverAssessmentId == null &&
            authz.reason !=
                AdultTargetVerificationReason.childConfirmedArchived;
        if (isConfirmedPreSubmitNegative) {
          final msg = sanitizeStorageError(
            'Assessment permission denied before creation ($code).',
          );
          final quarantined = await _quarantineWithLease(
            localDraftId: localDraftId,
            leaseToken: leaseToken,
            actorUserId: actorContext.userId,
            recoveryCode: DraftRecoveryCode.terminalPolicyDenial,
            errorMessage: msg,
            cause: cause,
          );
          return AssessmentSubmissionPolicyDenied(
            localDraftId: localDraftId,
            draft: quarantined.draft,
            recoveryCode: DraftRecoveryCode.terminalPolicyDenial,
            message: msg,
            quarantinedTerminally: true,
            cause: cause,
          );
        }
        return _quarantineWithLease(
          localDraftId: localDraftId,
          leaseToken: leaseToken,
          actorUserId: actorContext.userId,
          recoveryCode: DraftRecoveryCode.ambiguous42501Outcome,
          errorMessage:
              'Authorization or child archival ($code) after possible dispatch; preserving ambiguous state.',
          cause: cause,
        );
    }
  }

  Future<AssessmentSubmissionQuarantined> _quarantineWithLease({
    required String localDraftId,
    required String leaseToken,
    required String actorUserId,
    required String recoveryCode,
    required String errorMessage,
    Object? cause,
  }) async {
    final sanitized = sanitizeStorageError(errorMessage);
    final res = await localDraftStore!.quarantineDraftOutcome(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: actorUserId,
      recoveryCode: recoveryCode,
      errorMessage: sanitized,
      now: clock.now().toUtc(),
    );
    if (!res.isSuccess) {
      throw DraftSubmissionCasException(
        stage: DraftCasFailureStage.markDispatchStage,
        localDraftId: localDraftId,
        casStatus: res.status,
        serverAssessmentId: res.draft?.serverAssessmentId,
        serverEvidenceId: res.draft?.serverEvidenceId,
        message: 'Failed to quarantine draft outcome (${res.status.name}).',
        cause: cause,
      );
    }
    final updated = res.draft;
    final nowUtc = clock.now().toUtc();
    return AssessmentSubmissionQuarantined(
      localDraftId: localDraftId,
      draft: updated,
      recoveryCode: recoveryCode,
      disposition:
          updated?.recoveryDispositionAt(now: nowUtc) ??
          DraftRecoveryDisposition.quarantinedUnknownOutcome,
      message: updated?.lastErrorMessage ?? sanitized,
      casStatus: null,
      cause: cause,
    );
  }

  Future<AssessmentSubmissionOutcome> _scheduleRetryOrQuarantineCap({
    required String localDraftId,
    required String leaseToken,
    required String actorUserId,
    required int currentRetryCount,
    required String sanitizedMessage,
    required String capQuarantineCode,
    Object? cause,
  }) async {
    if (currentRetryCount >= maxRetryCount) {
      return _quarantineWithLease(
        localDraftId: localDraftId,
        leaseToken: leaseToken,
        actorUserId: actorUserId,
        recoveryCode: capQuarantineCode,
        errorMessage: 'Maximum assessment submission retry count reached; quarantined to preserve evidence and command state.',
        cause: cause,
      );
    }

    final nowUtc = clock.now().toUtc();
    final attempt = currentRetryCount + 1;
    final delay = calculateJitteredBackoff(attempt, jitterSource: jitterSource);
    final nextAttemptAt = nowUtc.add(delay);

    final res = await localDraftStore!.scheduleDraftRetry(
      localDraftId: localDraftId,
      leaseToken: leaseToken,
      authenticatedActorId: actorUserId,
      nextAttemptAt: nextAttemptAt,
      recoveryCode: DraftRecoveryCode.retryScheduled,
      errorMessage: sanitizeStorageError(sanitizedMessage),
      now: nowUtc,
    );

    if (!res.isSuccess) {
      throw DraftSubmissionCasException(
        stage: DraftCasFailureStage.markDispatchStage,
        localDraftId: localDraftId,
        casStatus: res.status,
        message: 'Failed to persist retry backoff (${res.status.name}).',
        cause: cause,
      );
    }

    final updated = res.draft;
    return AssessmentSubmissionRetryScheduled(
      localDraftId: localDraftId,
      draft: updated,
      nextAttemptAt: updated?.nextAttemptAt ?? nextAttemptAt,
      retryCount: updated?.retryCount ?? attempt,
      message: sanitizeStorageError(sanitizedMessage),
      cause: cause,
    );
  }

  static bool _isTransientNetworkError(Object error) {
    if (error is Error) {
      // Do not reinterpret programmer/mock StateError/AssertionError as network backoff.
      return false;
    }
    if (error is TimeoutException ||
        error is EvidenceStorageUnknownOutcomeException) {
      return true;
    }
    final typeName = error.runtimeType.toString();
    if (typeName.contains('SocketException') ||
        typeName.contains('ClientException') ||
        typeName.contains('HttpException')) {
      return true;
    }
    final str = error.toString().toLowerCase();
    return str.contains('socketexception') ||
        str.contains('clientexception') ||
        str.contains('httpexception') ||
        str.contains('connection reset') ||
        str.contains('connection refused') ||
        str.contains('network is unreachable') ||
        str.contains('timed out') ||
        str.contains('timeoutexception');
  }

  static String? _findRemoteAssessmentMismatch({
    required Assessment remote,
    required String expectedActorUserId,
    required FamilyId familyId,
    required ChildId childId,
    required SubjectKey subjectKey,
    required String normalizedSubject,
    required String normalizedTitle,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    required DateTime? normalizedOccurredAt,
    required EntryContext entryContext,
  }) {
    if (remote.createdByUserId != expectedActorUserId) {
      return 'actor provenance';
    }
    if (remote.familyId != familyId) return 'familyId';
    if (remote.childId != childId) return 'childId';
    if (remote.subjectKey != subjectKey) return 'subjectKey';
    if (normalizeAssessmentSubject(remote.subject) != normalizedSubject) {
      return 'subject';
    }
    if (normalizeAssessmentTitle(remote.title) != normalizedTitle) {
      return 'title';
    }
    if (remote.type != type) return 'assessmentType';
    if (remote.difficulty != difficulty) return 'difficulty';
    if (remote.score.rawScore != score.rawScore ||
        remote.score.maxScore != score.maxScore) {
      return 'score';
    }
    if (normalizedOccurredAt != null &&
        normalizeAssessmentOccurredAt(remote.occurredAt) !=
            normalizedOccurredAt) {
      return 'occurredAt';
    }
    if (remote.entryContext != entryContext) return 'entryContext';
    return null;
  }

  static String? _findDraftPayloadMismatch({
    required LocalAssessmentDraft candidate,
    LocalAssessmentDraft? baselineRow,
    required String authenticatedActorId,
    required FamilyId familyId,
    required ChildId childId,
    required String createCommandId,
    required String submitCommandId,
    required SubjectKey subjectKey,
    required String normalizedSubject,
    required String normalizedTitle,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    required DateTime? normalizedOccurredAt,
    required EntryContext entryContext,
    required EvidenceId? callerEvidenceId,
    required EvidenceId? resolvedEvidenceId,
    required String? resolvedSha256,
    required String? expectedCanonicalPath,
    required bool expectedHasEvidence,
  }) {
    if (candidate.actorUserId == null ||
        candidate.actorUserId != authenticatedActorId) {
      return 'actor provenance';
    }
    if (candidate.familyId != familyId.value) return 'familyId';
    if (candidate.childId != childId.value) return 'childId';
    if (candidate.createCommandId == null ||
        candidate.createCommandId != createCommandId) {
      return 'createCommandId';
    }
    if (candidate.submitCommandId == null ||
        candidate.submitCommandId != submitCommandId) {
      return 'submitCommandId';
    }
    if (candidate.subjectKey != subjectKey) return 'subjectKey';
    if (normalizeAssessmentSubject(candidate.subject) != normalizedSubject) {
      return 'subject';
    }
    if (normalizeAssessmentTitle(candidate.title) != normalizedTitle) {
      return 'title';
    }
    if (candidate.assessmentType != type.value) return 'assessmentType';
    if (candidate.difficulty != difficulty.value) return 'difficulty';
    if (candidate.rawScore != score.rawScore ||
        candidate.maxScore != score.maxScore) {
      return 'score';
    }
    if (normalizedOccurredAt == null ||
        normalizeAssessmentOccurredAt(candidate.occurredAt) !=
            normalizedOccurredAt) {
      return 'occurredAt';
    }
    if (candidate.entryContext != entryContext) return 'entryContext';

    final candidateHasEvidenceRef =
        candidate.hasVerifiedEvidenceSnapshot ||
        (candidate.evidenceId?.isNotEmpty ?? false) ||
        (candidate.localPhotoPath?.isNotEmpty ?? false) ||
        (candidate.localCompressedPhotoPath?.isNotEmpty ?? false) ||
        (candidate.sha256Checksum?.isNotEmpty ?? false);
    if (expectedHasEvidence) {
      if (!candidate.hasVerifiedEvidenceSnapshot) {
        return 'canonical evidence snapshot';
      }
      if (callerEvidenceId == null ||
          candidate.evidenceId != callerEvidenceId.value) {
        return 'evidenceId';
      }
      if (resolvedEvidenceId != null &&
          candidate.evidenceId != resolvedEvidenceId.value) {
        return 'bound evidenceId';
      }
      if (resolvedSha256 != null &&
          candidate.sha256Checksum != resolvedSha256) {
        return 'canonical snapshot SHA-256';
      }
      if (expectedCanonicalPath != null &&
          candidate.localCompressedPhotoPath != expectedCanonicalPath) {
        return 'canonical snapshot path';
      }
    } else if (candidateHasEvidenceRef) {
      return 'unexpected evidence attachment';
    }

    if (baselineRow != null) {
      if (candidate.actorUserId != baselineRow.actorUserId) {
        return 'persisted actor provenance';
      }
      if (candidate.subject != baselineRow.subject) return 'persisted subject';
      if (candidate.title != baselineRow.title) return 'persisted title';
      if (normalizeAssessmentOccurredAt(candidate.occurredAt) !=
          normalizeAssessmentOccurredAt(baselineRow.occurredAt)) {
        return 'persisted occurredAt';
      }
      if (candidate.localPhotoPath != baselineRow.localPhotoPath) {
        return 'persisted localPhotoPath';
      }
      if (candidate.dispatchState != baselineRow.dispatchState ||
          candidate.submissionStatus != baselineRow.submissionStatus ||
          candidate.serverAssessmentId != baselineRow.serverAssessmentId ||
          candidate.serverEvidenceId != baselineRow.serverEvidenceId) {
        return 'persisted dispatch provenance';
      }
      if (candidate.isLegacyUnknown ||
          candidate.hasUnboundActor ||
          candidate.hasMalformedLease ||
          candidate.isReadOnlyQuarantined ||
          candidate.hasWaitingOriginalActorMarker ||
          candidate.submissionStatus == DraftSubmissionStatus.terminalError ||
          (candidate.hasRecoveryMarker &&
              candidate.recoveryCode != DraftRecoveryCode.retryScheduled)) {
        return 'draft recovery state';
      }
    }

    return null;
  }
}
