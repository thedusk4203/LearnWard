import 'package:learnward_domain/learnward_domain.dart';

import '../ports/assessment_evidence_storage.dart';
import '../ports/assessment_repository.dart';

/// Use case to upload evidence file to Storage and register the evidence record in the database.
final class UploadAssessmentEvidence {
  const UploadAssessmentEvidence({
    required this.repository,
    required this.storage,
  });

  final AssessmentRepository repository;
  final AssessmentEvidenceStorage storage;

  Future<AssessmentEvidence> call({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required String fileName,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final storagePath = await storage.uploadEvidence(
      familyId: familyId,
      childId: childId,
      assessmentId: assessmentId,
      fileName: fileName,
      bytes: bytes,
      mediaType: mediaType,
    );

    return repository.registerEvidence(
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: bytes.length,
    );
  }
}
