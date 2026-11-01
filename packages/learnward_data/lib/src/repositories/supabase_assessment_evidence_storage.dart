import 'dart:typed_data';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase Storage implementation of [AssessmentEvidenceStorage] targeting
/// the private `assessment-evidence` bucket.
final class SupabaseAssessmentEvidenceStorage
    implements AssessmentEvidenceStorage {
  SupabaseAssessmentEvidenceStorage(this._client);

  final SupabaseClient _client;

  static const String bucketName = 'assessment-evidence';

  @override
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required String fileName,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final storagePath =
        '${familyId.value}/${childId.value}/${assessmentId.value}/$fileName';

    await _client.storage
        .from(bucketName)
        .uploadBinary(
          storagePath,
          Uint8List.fromList(bytes),
          fileOptions: FileOptions(contentType: mediaType, upsert: true),
        );

    return storagePath;
  }

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 60),
  }) async {
    return _client.storage
        .from(bucketName)
        .createSignedUrl(storagePath, expiresIn.inSeconds);
  }

  @override
  Future<void> deleteEvidence(String storagePath) async {
    await _client.storage.from(bucketName).remove([storagePath]);
  }
}
