import 'package:learnward_domain/learnward_domain.dart';

/// Storage port for assessment evidence files (photos/documents).
abstract interface class AssessmentEvidenceStorage {
  /// Uploads binary evidence bytes to the private assessment-evidence bucket.
  ///
  /// Returns the storagePath in convention:
  /// `<family_id>/<child_id>/<assessment_id>/<fileName>`
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required String fileName,
    required List<int> bytes,
    required String mediaType,
  });

  /// Generates a temporary signed URL for authorized evidence viewing.
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 60),
  });

  /// Deletes an evidence file from storage.
  Future<void> deleteEvidence(String storagePath);
}
