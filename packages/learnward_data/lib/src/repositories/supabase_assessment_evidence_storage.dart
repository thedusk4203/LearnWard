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
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final ext = mediaType == 'image/png' ? 'png' : 'jpg';
    final storagePath =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}.$ext';

    // Strictly enforce immutable object identity: upsert = false
    try {
      await _client.storage
          .from(bucketName)
          .uploadBinary(
            storagePath,
            Uint8List.fromList(bytes),
            fileOptions: FileOptions(contentType: mediaType, upsert: false),
          );
    } on StorageException catch (e) {
      final msg = e.message.toLowerCase();
      if (e.statusCode == '409' ||
          msg.contains('already exists') ||
          msg.contains('duplicate')) {
        // Idempotent retry: object with this unique opaque UUID already exists in storage
        return storagePath;
      }
      rethrow;
    }

    return storagePath;
  }

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
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
