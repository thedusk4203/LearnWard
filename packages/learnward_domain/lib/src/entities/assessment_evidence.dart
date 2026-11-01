import '../exceptions/domain_exceptions.dart';
import '../value_objects/identifiers.dart';

/// Metadata for an evidence file (photo or scan) attached to an assessment.
final class AssessmentEvidence {
  AssessmentEvidence({
    required this.id,
    required this.familyId,
    required this.assessmentId,
    required String storagePath,
    required this.mediaType,
    required this.fileSizeBytes,
    required this.uploadedByUserId,
    required this.createdAt,
  }) : storagePath = _validateStoragePath(storagePath) {
    if (fileSizeBytes <= 0 || fileSizeBytes > maxFileSizeBytes) {
      throw const InvalidAssessmentException(
        'Evidence file size must be between 1 byte and 10 MiB.',
      );
    }
    if (mediaType != 'image/jpeg' && mediaType != 'image/png') {
      throw const InvalidAssessmentException(
        'Evidence media type must be image/jpeg or image/png.',
      );
    }
  }

  static const int maxFileSizeBytes = 10 * 1024 * 1024; // 10 MiB

  final EvidenceId id;
  final FamilyId familyId;
  final AssessmentId assessmentId;
  final String storagePath;
  final String mediaType;
  final int fileSizeBytes;
  final String uploadedByUserId;
  final DateTime createdAt;

  static String _validateStoragePath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const InvalidAssessmentException(
        'Evidence storage path cannot be empty.',
      );
    }
    return trimmed;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AssessmentEvidence && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'AssessmentEvidence($id, $storagePath, $fileSizeBytes B)';
}
