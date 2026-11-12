import 'package:crypto/crypto.dart';
import 'package:learnward_domain/learnward_domain.dart';

import 'auth_session_port.dart';

/// Helper to compute lowercase 64-character hex SHA-256 digest from binary bytes.
String computeSha256Hex(List<int> bytes) {
  return sha256.convert(bytes).toString();
}

/// Helper to redact full storage paths for privacy (Invariant I16).
/// Masks family and child identifiers, preserving only the relative filename.
String redactStoragePath(String path) {
  if (path.isEmpty) return '<empty>';
  final lastSlash = path.lastIndexOf('/');
  final filename = lastSlash != -1 ? path.substring(lastSlash + 1) : path;
  return '.../$filename';
}

/// Helper to sanitize error messages so full paths, signed URLs, and tokens are redacted.
String sanitizeStorageError(String message) {
  var sanitized = message;
  // Redact URL query parameters (which may contain access tokens or signatures)
  sanitized = sanitized.replaceAll(RegExp(r'\?[^"\s]+'), '?<redacted_params>');
  // Redact 4-part UUID storage paths: <uuid>/<uuid>/<uuid>/<filename>
  sanitized = sanitized.replaceAllMapped(
    RegExp(
      r'[0-9a-fA-F\-]{36}/[0-9a-fA-F\-]{36}/[0-9a-fA-F\-]{36}/([^/\s\?"]+)',
    ),
    (m) => '.../${m.group(1)}',
  );
  return sanitized;
}

/// Typed outcome status for Storage evidence reconciliation.
enum EvidenceStorageReconciliationOutcome {
  /// Remote object exists and its byte length and SHA-256 match local bytes exactly.
  matchingBytes,

  /// Remote object exists at the path, but byte length or SHA-256 differs (quarantined conflict).
  contentConflict,

  /// Visibility or transport failure (HTTP 401/403/404, RLS 0-row, timeout, socket error).
  unknownOutcome,

  /// Authenticated session invalid, expired, revoked, or session generation changed.
  authFailure,
}

/// Sealed hierarchy representing the result of reconciling local evidence bytes
/// against the remote Storage object at `storagePath`.
sealed class EvidenceStorageReconciliationResult {
  const EvidenceStorageReconciliationResult({required this.storagePath});

  /// Target storage path in convention `<family_id>/<child_id>/<assessment_id>/<evidence_id>.<ext>`.
  final String storagePath;

  /// High-level typed outcome status.
  EvidenceStorageReconciliationOutcome get outcome;
}

/// Remote bytes exist at [storagePath] and positively match local byte length and SHA-256.
final class MatchingBytesOutcome extends EvidenceStorageReconciliationResult {
  const MatchingBytesOutcome({
    required super.storagePath,
    required this.remoteBytes,
    required this.remoteSha256,
  });

  /// Remote binary bytes downloaded from storage.
  final List<int> remoteBytes;

  /// Verified lowercase hex SHA-256 of the remote bytes.
  final String remoteSha256;

  int get remoteByteCount => remoteBytes.length;

  @override
  EvidenceStorageReconciliationOutcome get outcome =>
      EvidenceStorageReconciliationOutcome.matchingBytes;

  @override
  String toString() =>
      'MatchingBytesOutcome(path: ${redactStoragePath(storagePath)}, byteCount: $remoteByteCount)';
}

/// Remote bytes exist at [storagePath], but byte length or SHA-256 differs from local bytes.
final class ContentConflictOutcome extends EvidenceStorageReconciliationResult {
  const ContentConflictOutcome({
    required super.storagePath,
    required this.localSha256,
    required this.remoteSha256,
    required this.localByteCount,
    required this.remoteByteCount,
    required this.reason,
  });

  final String localSha256;
  final String remoteSha256;
  final int localByteCount;
  final int remoteByteCount;
  final String reason;

  @override
  EvidenceStorageReconciliationOutcome get outcome =>
      EvidenceStorageReconciliationOutcome.contentConflict;

  @override
  String toString() =>
      'ContentConflictOutcome(path: ${redactStoragePath(storagePath)}, localBytes: $localByteCount, remoteBytes: $remoteByteCount, reason: ${sanitizeStorageError(reason)})';
}

/// Remote status cannot be determined due to transport failure, timeout, 401/403, 404, or RLS filtering.
final class UnknownOutcome extends EvidenceStorageReconciliationResult {
  const UnknownOutcome({
    required super.storagePath,
    required this.reason,
    this.cause,
  });

  final String reason;
  final Object? cause;

  @override
  EvidenceStorageReconciliationOutcome get outcome =>
      EvidenceStorageReconciliationOutcome.unknownOutcome;

  @override
  String toString() =>
      'UnknownOutcome(path: ${redactStoragePath(storagePath)}, reason: ${sanitizeStorageError(reason)})';
}

/// Authenticated session check failed before Storage interaction.
final class AuthFailureOutcome extends EvidenceStorageReconciliationResult {
  const AuthFailureOutcome({required super.storagePath, required this.reason});

  final String reason;

  @override
  EvidenceStorageReconciliationOutcome get outcome =>
      EvidenceStorageReconciliationOutcome.authFailure;

  @override
  String toString() =>
      'AuthFailureOutcome(path: ${redactStoragePath(storagePath)}, reason: ${sanitizeStorageError(reason)})';
}

/// Base exception for remote Storage evidence errors.
sealed class AssessmentEvidenceStorageException implements Exception {
  const AssessmentEvidenceStorageException(this.message);
  final String message;

  @override
  String toString() =>
      'AssessmentEvidenceStorageException: ${sanitizeStorageError(message)}';
}

/// Thrown when remote storage contains conflicting bytes for the same evidence path.
final class EvidenceStorageConflictException
    extends AssessmentEvidenceStorageException {
  EvidenceStorageConflictException(this.result, [String? message])
    : super(message ?? result.reason);

  final ContentConflictOutcome result;
}

/// Thrown when remote outcome cannot be determined and must fail closed without deleting.
final class EvidenceStorageUnknownOutcomeException
    extends AssessmentEvidenceStorageException {
  EvidenceStorageUnknownOutcomeException(
    this.result, [
    String? message,
    this.cause,
  ]) : super(message ?? result.reason);

  final UnknownOutcome result;
  final Object? cause;
}

/// Thrown when authenticated session validation fails before storage mutation or download.
final class EvidenceStorageAuthException
    extends AssessmentEvidenceStorageException {
  EvidenceStorageAuthException(this.result, [String? message])
    : super(message ?? result.reason);

  final AuthFailureOutcome result;
}

/// Storage port for assessment evidence files (photos/documents).
abstract interface class AssessmentEvidenceStorage {
  /// Maximum permitted evidence file size in bytes (10 MiB).
  static const int maxFileSizeBytes = 10 * 1024 * 1024;

  /// Uploads binary evidence bytes to the private assessment-evidence bucket.
  ///
  /// Generates the storagePath in convention:
  /// `<family_id>/<child_id>/<assessment_id>/<evidence_id>.<ext>`
  ///
  /// Uses upsert = false to enforce object identity immutability.
  /// On HTTP 409 or duplicate response, strictly reconciles remote bytes against
  /// [bytes] by length and SHA-256.
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  });

  /// Downloads private object bytes from the assessment-evidence bucket.
  Future<List<int>> downloadEvidence({
    required String storagePath,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  });

  /// Reconciles local bytes against the remote Storage object at [storagePath].
  Future<EvidenceStorageReconciliationResult> reconcileEvidence({
    required String storagePath,
    required List<int> localBytes,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  });

  /// Generates a temporary signed URL for authorized evidence viewing.
  /// Defaults to a short 10-minute expiry suitable for parent review.
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  });

  /// Deletes an evidence file from storage (allowed only while assessment is in draft).
  Future<void> deleteEvidence(
    String storagePath, {
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  });
}
