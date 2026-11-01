import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';

/// Use case to upload evidence file to Storage and register the evidence record in the database.
///
/// Implements compensation cleanup: if metadata registration fails, the uploaded storage
/// object is immediately deleted to prevent orphan storage assets.
final class UploadAssessmentEvidence {
  const UploadAssessmentEvidence({
    required this.repository,
    required this.storage,
  });

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;

  static const int maxFileSizeBytes = 10 * 1024 * 1024; // 10 MiB

  Future<AssessmentEvidence> call({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    // 1. Client-side size validation
    if (bytes.length > maxFileSizeBytes) {
      throw const InvalidAssessmentException(
        'Evidence file size must not exceed 10 MiB.',
      );
    }

    // 2. Client-side MIME validation
    if (mediaType != 'image/jpeg' && mediaType != 'image/png') {
      throw InvalidAssessmentException(
        'Unsupported media type: $mediaType. Only JPEG and PNG are allowed.',
      );
    }

    // 3. Upload object with opaque evidence ID
    final storagePath = await storage.uploadEvidence(
      familyId: familyId,
      childId: childId,
      assessmentId: assessmentId,
      evidenceId: evidenceId,
      bytes: bytes,
      mediaType: mediaType,
    );

    // 4. Register metadata with compensation cleanup on failure
    try {
      return await repository.registerEvidence(
        assessmentId: assessmentId,
        storagePath: storagePath,
        mediaType: mediaType,
        fileSizeBytes: bytes.length,
      );
    } catch (registrationError) {
      try {
        await storage.deleteEvidence(storagePath);
      } catch (_) {
        // Suppress cleanup secondary error to preserve original registration failure
      }
      rethrow;
    }
  }
}
