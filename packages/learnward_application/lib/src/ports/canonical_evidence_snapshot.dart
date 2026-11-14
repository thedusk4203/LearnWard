import 'dart:typed_data';

import 'assessment_evidence_storage.dart';
import 'local_draft_store.dart';

/// Machine-readable failure reason codes for canonical evidence byte inspection.
enum CanonicalEvidenceValidationCode {
  emptyBytes,
  oversizedBytes,
  unsupportedMagicBytes,
  lengthMismatch,
  sha256Mismatch,
  invalidSha256Format,
  mediaTypeMismatch,
}

/// Thrown when raw or persisted canonical evidence bytes fail fail-closed integrity checks.
final class CanonicalEvidenceValidationException implements Exception {
  const CanonicalEvidenceValidationException(this.code, this.message);

  final CanonicalEvidenceValidationCode code;
  final String message;

  @override
  String toString() =>
      'CanonicalEvidenceValidationException(${code.name}): $message';
}

/// Metadata describing an immutable canonical evidence snapshot frozen before dispatch.
final class CanonicalEvidenceSnapshot {
  const CanonicalEvidenceSnapshot({
    required this.localDraftId,
    required this.filePath,
    required this.mediaType,
    required this.fileExtension,
    required this.byteLength,
    required this.sha256Checksum,
    required this.frozenAt,
  });

  final String localDraftId;
  final String filePath;
  final String mediaType;
  final String fileExtension;
  final int byteLength;
  final String sha256Checksum;
  final DateTime frozenAt;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is CanonicalEvidenceSnapshot &&
            localDraftId == other.localDraftId &&
            filePath == other.filePath &&
            mediaType == other.mediaType &&
            fileExtension == other.fileExtension &&
            byteLength == other.byteLength &&
            sha256Checksum == other.sha256Checksum &&
            frozenAt.isAtSameMomentAs(other.frozenAt);
  }

  @override
  int get hashCode => Object.hash(
    localDraftId,
    filePath,
    mediaType,
    fileExtension,
    byteLength,
    sha256Checksum,
    frozenAt.toUtc().millisecondsSinceEpoch,
  );

  @override
  String toString() =>
      'CanonicalEvidenceSnapshot(localDraftId: $localDraftId, '
      'path: ${redactStoragePath(filePath)}, mediaType: $mediaType, '
      'bytes: $byteLength, sha256: $sha256Checksum)';
}

/// Verified immutable bytes read from a canonical evidence snapshot.
final class VerifiedCanonicalEvidence {
  VerifiedCanonicalEvidence({required this.snapshot, required List<int> bytes})
    : bytes = Uint8List.fromList(bytes);

  final CanonicalEvidenceSnapshot snapshot;

  /// Defensive immutable copy of verified evidence bytes.
  final Uint8List bytes;

  String get localDraftId => snapshot.localDraftId;
  String get filePath => snapshot.filePath;
  String get mediaType => snapshot.mediaType;
  String get fileExtension => snapshot.fileExtension;
  int get byteLength => snapshot.byteLength;
  String get sha256Checksum => snapshot.sha256Checksum;
  DateTime get frozenAt => snapshot.frozenAt;
}

/// Inspected canonical evidence byte properties derived exclusively from binary content.
typedef InspectedEvidenceBytes = ({
  Uint8List bytes,
  String mediaType,
  String fileExtension,
  int byteLength,
  String sha256Checksum,
});

final RegExp _lowercaseSha256Regex = RegExp(r'^[0-9a-f]{64}$');

/// Validates whether [value] is a lowercase 64-character hex SHA-256 digest.
bool isValidSha256Hex(String? value) =>
    value != null && _lowercaseSha256Regex.hasMatch(value);

/// Detects JPEG or PNG media type purely from magic bytes, ignoring filenames/extensions.
///
/// Throws [CanonicalEvidenceValidationException] if the signature is not JPEG or PNG.
({String mediaType, String fileExtension}) detectEvidenceMagicBytes(
  List<int> bytes,
) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return (mediaType: 'image/jpeg', fileExtension: 'jpg');
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return (mediaType: 'image/png', fileExtension: 'png');
  }
  throw const CanonicalEvidenceValidationException(
    CanonicalEvidenceValidationCode.unsupportedMagicBytes,
    'Unsupported evidence binary format. Only JPEG and PNG signatures are accepted.',
  );
}

/// Validates and copies [bytes] into an immutable buffer, verifying non-empty length,
/// max 10 MiB limit, magic-byte MIME signature, and lowercase 64-hex SHA-256 digest.
InspectedEvidenceBytes inspectAndValidateEvidenceBytes(List<int> bytes) {
  final copy = Uint8List.fromList(bytes);
  if (copy.isEmpty) {
    throw const CanonicalEvidenceValidationException(
      CanonicalEvidenceValidationCode.emptyBytes,
      'Evidence bytes must not be empty.',
    );
  }
  if (copy.length > AssessmentEvidenceStorage.maxFileSizeBytes) {
    throw const CanonicalEvidenceValidationException(
      CanonicalEvidenceValidationCode.oversizedBytes,
      'Evidence bytes exceed the maximum allowed size of 10 MiB.',
    );
  }
  final detected = detectEvidenceMagicBytes(copy);
  final digest = computeSha256Hex(copy);
  return (
    bytes: copy,
    mediaType: detected.mediaType,
    fileExtension: detected.fileExtension,
    byteLength: copy.length,
    sha256Checksum: digest,
  );
}

/// Verifies [bytes] against expected SHA-256 digest and optional expected byte length / media type.
InspectedEvidenceBytes verifyCanonicalEvidenceBytes({
  required List<int> bytes,
  required String expectedSha256,
  int? expectedByteLength,
  String? expectedMediaType,
}) {
  if (!isValidSha256Hex(expectedSha256)) {
    throw const CanonicalEvidenceValidationException(
      CanonicalEvidenceValidationCode.invalidSha256Format,
      'Expected SHA-256 checksum must be a lowercase 64-character hex string.',
    );
  }
  final inspected = inspectAndValidateEvidenceBytes(bytes);
  if (expectedByteLength != null &&
      inspected.byteLength != expectedByteLength) {
    throw CanonicalEvidenceValidationException(
      CanonicalEvidenceValidationCode.lengthMismatch,
      'Canonical evidence byte length mismatch: expected $expectedByteLength, got ${inspected.byteLength}.',
    );
  }
  if (expectedMediaType != null && inspected.mediaType != expectedMediaType) {
    throw CanonicalEvidenceValidationException(
      CanonicalEvidenceValidationCode.mediaTypeMismatch,
      'Canonical evidence media type mismatch: expected $expectedMediaType, got ${inspected.mediaType}.',
    );
  }
  if (inspected.sha256Checksum != expectedSha256) {
    throw const CanonicalEvidenceValidationException(
      CanonicalEvidenceValidationCode.sha256Mismatch,
      'Canonical evidence SHA-256 digest mismatch.',
    );
  }
  return inspected;
}

/// Application port for durable canonical evidence snapshot creation and verification.
///
/// Implementations write immutable, magic-byte-validated bytes keyed by `localDraftId`
/// and re-verify file length, MIME magic bytes, and SHA-256 digest before upload.
abstract interface class CanonicalEvidenceSnapshotStore {
  Future<CanonicalEvidenceSnapshot> saveCanonicalEvidenceSnapshot({
    required String localDraftId,
    required List<int> bytes,
  });

  Future<VerifiedCanonicalEvidence> readVerifiedCanonicalSnapshot({
    required LocalAssessmentDraft draft,
  });
}
