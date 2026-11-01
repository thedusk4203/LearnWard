import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

final class FakeAssessmentEvidenceStorage implements AssessmentEvidenceStorage {
  final Map<String, List<int>> storage = {};

  @override
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required String fileName,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final path =
        '${familyId.value}/${childId.value}/${assessmentId.value}/$fileName';
    storage[path] = bytes;
    return path;
  }

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 60),
  }) async {
    return 'https://storage.fake.learnward.local/$storagePath?signed=true';
  }

  @override
  Future<void> deleteEvidence(String storagePath) async {
    storage.remove(storagePath);
  }
}
