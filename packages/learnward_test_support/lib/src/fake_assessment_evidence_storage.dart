import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

final class FakeAssessmentEvidenceStorage implements AssessmentEvidenceStorage {
  final Map<String, List<int>> storage = {};
  bool throwOnRegister = false;

  @override
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final ext = mediaType == 'image/png' ? 'png' : 'jpg';
    final path =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}.$ext';
    storage[path] = bytes;
    return path;
  }

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
  }) async {
    return 'https://storage.fake.learnward.local/$storagePath?signed=true';
  }

  @override
  Future<void> deleteEvidence(String storagePath) async {
    storage.remove(storagePath);
  }
}
