import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/auth_session_port.dart';
import '../ports/recovery_authorization_port.dart';
import '../services/assessment_submission_orchestrator.dart';

/// Validates, uploads (without overwriting existing bytes), reconciles any
/// conflicting 409/lost-ack state, and registers evidence metadata with the
/// assessment repository via the shared WP3 evidence reconciliation engine.
///
/// Invariants & security guarantees:
/// - Revalidates live session via [AuthSessionPort.validateForMutation] and
///   target membership/child status via [RecoveryAuthorizationPort.verifyAssessmentTarget]
///   before Storage upload and DB registration (R32-06, B1-16).
/// - Fails closed on missing/invalid/switched auth sessions and revoked targets.
/// - Handles `LW109` after non-draft transitions via `(assessmentId, familyId, storagePath)`
///   and byte SHA-256 reconciliation without deleting or overwriting remote bytes (`I03`, `I04`).
final class UploadAssessmentEvidence {
  const UploadAssessmentEvidence({
    required this.repository,
    required this.storage,
    required this.authSessionPort,
    required RecoveryAuthorizationPort this.recoveryAuthorizationPort,
    @Deprecated('Compensation cleanup is removed per Invariant I04')
    this.onCleanupError,
  }) : _allowMissingAuthorizationForTesting = false;

  /// Explicit isolated constructor for unit tests that do not test target
  /// authorization behavior.
  const UploadAssessmentEvidence.forTesting({
    required this.repository,
    required this.storage,
    required this.authSessionPort,
    this.recoveryAuthorizationPort,
    @Deprecated('Compensation cleanup is removed per Invariant I04')
    this.onCleanupError,
  }) : _allowMissingAuthorizationForTesting = true;

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;
  final AuthSessionPort authSessionPort;
  final RecoveryAuthorizationPort? recoveryAuthorizationPort;
  final void Function(String message, Object? error)? onCleanupError;
  final bool _allowMissingAuthorizationForTesting;

  static const int maxFileSizeBytes =
      AssessmentEvidenceStorage.maxFileSizeBytes; // 10 MiB

  Future<AssessmentEvidence> call({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
    String? persistedServerEvidenceId,
    bool preCheckServerEvidenceList = false,
  }) async {
    final orchestrator = AssessmentSubmissionOrchestrator.unjournaledForTesting(
      repository: repository,
      storage: storage,
      authSessionPort: authSessionPort,
      recoveryAuthorizationPort: recoveryAuthorizationPort,
    );
    if (!_allowMissingAuthorizationForTesting &&
        recoveryAuthorizationPort == null) {
      throw StateError(
        'RecoveryAuthorizationPort is required for UploadAssessmentEvidence.',
      );
    }
    try {
      final res = await orchestrator.reconcileAndRegisterEvidence(
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
      );
      return res.evidence;
    } on TargetAuthorizationDeniedException {
      throw const AssessmentPolicyDeniedException(
        recoveryCode: 'LW4B1:TERMINAL_POLICY_DENIAL',
        message: 'Target assessment authorization denied or revoked before upload/registration.',
      );
    } on TargetAuthorizationUnverifiedException {
      throw const BackendRpcException(
        code: '503',
        message:
            'Unable to verify target assessment authorization; retry later.',
      );
    }
  }
}
