import 'package:learnward_domain/learnward_domain.dart';

/// Storage port for assessment evidence files (photos/documents).
abstract interface class AssessmentEvidenceStorage {
  /// Uploads binary evidence bytes to the private assessment-evidence bucket.
  ///
  /// Generates the storagePath in convention:
  /// `<family_id>/<child_id>/<assessment_id>/<evidence_id>.<ext>`
  ///
  /// Uses upsert = false to enforce object identity immutability.
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
  });

  /// Generates a temporary signed URL for authorized evidence viewing.
  /// Defaults to a short 10-minute expiry suitable for parent review.
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
  });

  /// Deletes an evidence file from storage (allowed only while assessment is in draft).
  Future<void> deleteEvidence(String storagePath);
}
