import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';
import '../ports/auth_session_port.dart';

/// Use case to upload evidence file to Storage and register the evidence record in the database.
///
/// Invariant I04: Unconditional compensation deletion has been removed. If metadata
/// registration fails or yields an ambiguous response, remote Storage bytes are preserved
/// for future authorized reconciliation rather than blindly deleted.
final class UploadAssessmentEvidence {
  const UploadAssessmentEvidence({
    required this.repository,
    required this.storage,
    this.authSessionPort,
    @Deprecated('Compensation cleanup is removed per Invariant I04')
    this.onCleanupError,
  });

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;
  final AuthSessionPort? authSessionPort;
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
    // 1. Authoritative session validation (R31-08 / Invariant I07)
    if (authSessionPort != null) {
      final freshContext = await authSessionPort!.validateForMutation();
      if (freshContext == null ||
          !freshContext.isValidAt(DateTime.now().toUtc())) {
        throw EvidenceStorageAuthException(
          const AuthFailureOutcome(
            storagePath: '',
            reason:
                'Unauthenticated or expired session before evidence upload.',
          ),
        );
      }
      final genToCheck =
          expectedSessionGeneration ?? context?.sessionGeneration;
      if (genToCheck != null && freshContext.sessionGeneration != genToCheck) {
        throw EvidenceStorageAuthException(
          const AuthFailureOutcome(
            storagePath: '',
            reason: 'Session generation changed across asynchronous boundary.',
          ),
        );
      }
      if (context != null && freshContext.userId != context.userId) {
        throw EvidenceStorageAuthException(
          const AuthFailureOutcome(
            storagePath: '',
            reason: 'Actor switch detected: active session does not match original actor.',
          ),
        );
      }
    }

    // 2. Client-side size validation
    if (bytes.length > maxFileSizeBytes) {
      throw const InvalidAssessmentException(
        'Evidence file size must not exceed 10 MiB.',
      );
    }

    // 3. Client-side MIME validation
    if (mediaType != 'image/jpeg' && mediaType != 'image/png') {
      throw InvalidAssessmentException(
        'Unsupported media type: $mediaType. Only JPEG and PNG are allowed.',
      );
    }

    // 4. Upload object with opaque evidence ID and immutable upsert:false
    final storagePath = await storage.uploadEvidence(
      familyId: familyId,
      childId: childId,
      assessmentId: assessmentId,
      evidenceId: evidenceId,
      bytes: bytes,
      mediaType: mediaType,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
    );

    // 5. Register metadata. Per I04, if registration fails, we do NOT delete
    // the remote storage object; it is retained for future reconciliation.
    return await repository.registerEvidence(
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: bytes.length,
    );
  }
}
