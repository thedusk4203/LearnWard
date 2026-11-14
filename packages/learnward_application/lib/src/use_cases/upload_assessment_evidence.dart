import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/auth_session_port.dart';

/// Application use case to upload evidence binary bytes to remote Storage and register
/// metadata in the database.
///
/// Invariants and design rules:
/// - I04: Unconditional compensation deletion is removed. If metadata registration fails
///   or yields an ambiguous response, remote Storage bytes are preserved for authorized
///   reconciliation rather than blindly deleted.
/// - I07 / R32-02 / R32-06: Mandatory live [AuthSessionPort] validation is enforced
///   prior to upload AND revalidated across the asynchronous upload boundary before
///   `repository.registerEvidence()`. No production path may skip authentication.
/// - WP1 -> WP2/WP3 boundary: WP1 enforces live session validity, actor continuity, and
///   session-generation invariance within the active call. Durable cross-restart draft
///   actor binding (`actorUserId`, persisted session epoch, and lease-token CAS) is
///   deferred to WP2/WP3.
final class UploadAssessmentEvidence {
  const UploadAssessmentEvidence({
    required this.repository,
    required this.storage,
    required this.authSessionPort,
    @Deprecated('Compensation cleanup is removed per Invariant I04')
    this.onCleanupError,
  });

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;
  final AuthSessionPort authSessionPort;
  final void Function(String message, Object? error)? onCleanupError;

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
  }) async {
    // 1. Authoritative live session validation (R31-08 / R32-06 / Invariant I07)
    final initialContext = await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: '',
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      stage: 'evidence upload preflight',
    );

    // 2. Client-side size (non-empty and <= 10 MiB) and MIME validation (R32-08)
    validateEvidenceUploadPayload(bytes: bytes, mediaType: mediaType);

    // 3. Upload object with opaque evidence ID and immutable upsert:false
    final storagePath = await storage.uploadEvidence(
      familyId: familyId,
      childId: childId,
      assessmentId: assessmentId,
      evidenceId: evidenceId,
      bytes: bytes,
      mediaType: mediaType,
      context: initialContext,
      expectedSessionGeneration: initialContext.sessionGeneration,
    );

    // 4. Post-upload session revalidation across async boundary (R32-02 / I07)
    await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: storagePath,
      context: initialContext,
      expectedSessionGeneration: initialContext.sessionGeneration,
      stage: 'post-upload metadata registration',
    );

    // 5. Register metadata. Per I04, if registration fails, remote bytes are retained.
    return await repository.registerEvidence(
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: bytes.length,
    );
  }
}
