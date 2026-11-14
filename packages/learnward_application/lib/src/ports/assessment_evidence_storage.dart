import 'package:crypto/crypto.dart';
import 'package:learnward_domain/learnward_domain.dart';

import 'auth_session_port.dart';

/// Helper to compute lowercase 64-character hex SHA-256 digest from binary bytes.
String computeSha256Hex(List<int> bytes) {
  return sha256.convert(bytes).toString();
}

/// Helper to redact full storage paths for privacy (Invariant I16).
/// Masks family, child, and assessment identifiers, preserving only the filename.
String redactStoragePath(String path) {
  if (path.isEmpty) return '<empty>';
  final cleanPath = path.split('?').first;
  if (cleanPath.isEmpty) return '<empty>';
  final lastSlash = cleanPath.lastIndexOf('/');
  final filename = lastSlash != -1
      ? cleanPath.substring(lastSlash + 1)
      : cleanPath;
  return '.../$filename';
}

/// Helper to sanitize error messages so raw tokens, JWTs, URLs, query parameters,
/// and private Storage paths are never exposed in exception messages or logs.
String sanitizeStorageError(String message) {
  var sanitized = message;
  // 1. Redact Bearer authorization headers/tokens
  sanitized = sanitized.replaceAll(
    RegExp(r'\bBearer\s+[A-Za-z0-9\-_\.~+/]+=*', caseSensitive: false),
    'Bearer <redacted>',
  );
  // 2. Redact JWTs (header.payload[.signature])
  sanitized = sanitized.replaceAll(
    RegExp(r'\beyJ[A-Za-z0-9_-]{3,}\.[A-Za-z0-9_-]{3,}(?:\.[A-Za-z0-9_-]*)?'),
    '<redacted_jwt>',
  );
  // 3. Redact token/secret query or key-value assignments
  sanitized = sanitized.replaceAllMapped(
    RegExp(
      r'\b(access_token|refresh_token|id_token|apikey|api_key|token|signature|sig|secret|secret_jwt|authorization)\s*[:=]\s*[^\s,;\]\}\)"\x27]+',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}=<redacted>',
  );
  // 4. Redact full URLs (including signed URLs and Supabase project hosts)
  sanitized = sanitized.replaceAll(
    RegExp(r'https?://[^\s\)\]\}",\x27]+', caseSensitive: false),
    '<redacted_url>',
  );
  // 5. Redact Storage API endpoint paths
  sanitized = sanitized.replaceAll(
    RegExp(r'/storage/v1/[^\s\)\]\}",\x27]+', caseSensitive: false),
    '<redacted_storage_url>',
  );
  // 6. Redact any remaining URL query parameters
  sanitized = sanitized.replaceAll(
    RegExp(r'\?[^"\s\)\]]+'),
    '?<redacted_params>',
  );
  // 7. Redact 4-part private storage paths: <family>/<child>/<assessment>/<filename>
  sanitized = sanitized.replaceAllMapped(
    RegExp(r'(?:[A-Za-z0-9_\-]{3,}/){3}([^/\s\?\)\]\}",\x27]+)'),
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
    required String reason,
  }) : _rawReason = reason;

  final String localSha256;
  final String remoteSha256;
  final int localByteCount;
  final int remoteByteCount;
  final String _rawReason;

  String get reason => sanitizeStorageError(_rawReason);

  @override
  EvidenceStorageReconciliationOutcome get outcome =>
      EvidenceStorageReconciliationOutcome.contentConflict;

  @override
  String toString() =>
      'ContentConflictOutcome(path: ${redactStoragePath(storagePath)}, localBytes: $localByteCount, remoteBytes: $remoteByteCount, reason: $reason)';
}

/// Remote status cannot be determined due to transport failure, timeout, 401/403, 404, or RLS filtering.
final class UnknownOutcome extends EvidenceStorageReconciliationResult {
  const UnknownOutcome({
    required super.storagePath,
    required String reason,
    this.cause,
  }) : _rawReason = reason;

  final String _rawReason;
  final Object? cause;

  String get reason => sanitizeStorageError(_rawReason);

  @override
  EvidenceStorageReconciliationOutcome get outcome =>
      EvidenceStorageReconciliationOutcome.unknownOutcome;

  @override
  String toString() =>
      'UnknownOutcome(path: ${redactStoragePath(storagePath)}, reason: $reason)';
}

/// Authenticated session check failed before Storage interaction.
final class AuthFailureOutcome extends EvidenceStorageReconciliationResult {
  const AuthFailureOutcome({
    required super.storagePath,
    required String reason,
    this.actorSwitched = false,
    String? activeUserId,
    this.isLocalSessionInvalid = false,
    this.isServerHttpAuthRejection = false,
  }) : _rawReason = reason,
       _rawActiveUserId = activeUserId;

  final String _rawReason;
  final bool actorSwitched;
  final String? _rawActiveUserId;
  final bool isLocalSessionInvalid;
  final bool isServerHttpAuthRejection;

  String get reason => sanitizeStorageError(_rawReason);

  String? get activeUserId => _rawActiveUserId;

  @override
  EvidenceStorageReconciliationOutcome get outcome =>
      EvidenceStorageReconciliationOutcome.authFailure;

  @override
  String toString() =>
      'AuthFailureOutcome(path: ${redactStoragePath(storagePath)}, reason: $reason)';
}

/// Base exception for remote Storage evidence errors.
sealed class AssessmentEvidenceStorageException implements Exception {
  const AssessmentEvidenceStorageException(String message)
    : _rawMessage = message;

  final String _rawMessage;

  String get message => sanitizeStorageError(_rawMessage);

  @override
  String toString() => 'AssessmentEvidenceStorageException: $message';
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

/// Validates client-side upload payload invariants: non-empty bytes,
/// [AssessmentEvidenceStorage.maxFileSizeBytes] cap (10 MiB), and allowed MIME types.
///
/// Returns the normalized file extension (`'jpg'` or `'png'`).
String validateEvidenceUploadPayload({
  required List<int> bytes,
  required String mediaType,
}) {
  if (bytes.isEmpty) {
    throw const InvalidAssessmentException('Evidence file must not be empty.');
  }
  if (bytes.length > AssessmentEvidenceStorage.maxFileSizeBytes) {
    throw const InvalidAssessmentException(
      'Evidence file size must not exceed 10 MiB.',
    );
  }
  if (mediaType != 'image/jpeg' && mediaType != 'image/png') {
    throw const InvalidAssessmentException(
      'Unsupported media type. Only JPEG and PNG are allowed.',
    );
  }
  return mediaType == 'image/png' ? 'png' : 'jpg';
}

/// Enforces mandatory live session authentication, session-generation invariance,
/// and original-actor parity via [authSessionPort].
///
/// WP1 -> WP2/WP3 boundary note: In WP1, this validates active in-flight
/// [AuthSessionPort] state and caller-supplied [ValidatedActorContext] /
/// [expectedSessionGeneration]. Durable cross-restart actor provenance on local
/// drafts (`actorUserId`, persisted session epoch, and lease-fenced CAS)
/// depends on WP2/WP3 schema and journal extensions.
Future<ValidatedActorContext> assertValidStorageAuthSession({
  required AuthSessionPort authSessionPort,
  required String storagePath,
  ValidatedActorContext? context,
  String? expectedSessionGeneration,
  String stage = 'Storage operation',
}) async {
  final freshContext = await authSessionPort.validateForMutation();
  if (freshContext == null || !freshContext.isValidAt(DateTime.now().toUtc())) {
    throw EvidenceStorageAuthException(
      AuthFailureOutcome(
        storagePath: storagePath,
        reason: 'Unauthenticated or expired session during $stage.',
        isLocalSessionInvalid: true,
      ),
    );
  }
  if (context != null && freshContext.userId != context.userId) {
    throw EvidenceStorageAuthException(
      AuthFailureOutcome(
        storagePath: storagePath,
        reason:
            'Actor switch detected: active session does not match original actor ($stage).',
        actorSwitched: true,
        activeUserId: freshContext.userId,
      ),
    );
  }
  final genToCheck = expectedSessionGeneration ?? context?.sessionGeneration;
  if (genToCheck != null && freshContext.sessionGeneration != genToCheck) {
    throw EvidenceStorageAuthException(
      AuthFailureOutcome(
        storagePath: storagePath,
        reason:
            'Session generation changed across asynchronous boundary ($stage).',
        isLocalSessionInvalid: true,
      ),
    );
  }
  return freshContext;
}

/// Reconciles downloaded [remoteBytes] against [localBytes] using bounded size
/// validation, non-empty checks, and SHA-256 digest equality.
EvidenceStorageReconciliationResult reconcileRemoteEvidenceBytes({
  required String storagePath,
  required List<int> localBytes,
  required List<int> remoteBytes,
}) {
  if (remoteBytes.isEmpty) {
    return ContentConflictOutcome(
      storagePath: storagePath,
      localSha256: computeSha256Hex(localBytes),
      remoteSha256: '',
      localByteCount: localBytes.length,
      remoteByteCount: 0,
      reason: 'Remote evidence object is empty.',
    );
  }
  if (remoteBytes.length > AssessmentEvidenceStorage.maxFileSizeBytes) {
    return ContentConflictOutcome(
      storagePath: storagePath,
      localSha256: computeSha256Hex(localBytes),
      remoteSha256: '',
      localByteCount: localBytes.length,
      remoteByteCount: remoteBytes.length,
      reason: 'Remote evidence object exceeds maximum allowed size (10 MiB).',
    );
  }

  final localSha = computeSha256Hex(localBytes);
  final remoteSha = computeSha256Hex(remoteBytes);
  if (remoteBytes.length == localBytes.length && remoteSha == localSha) {
    return MatchingBytesOutcome(
      storagePath: storagePath,
      remoteBytes: remoteBytes,
      remoteSha256: remoteSha,
    );
  }

  return ContentConflictOutcome(
    storagePath: storagePath,
    localSha256: localSha,
    remoteSha256: remoteSha,
    localByteCount: localBytes.length,
    remoteByteCount: remoteBytes.length,
    reason: remoteBytes.length != localBytes.length
        ? 'Byte length mismatch: local=${localBytes.length}, remote=${remoteBytes.length}'
        : 'SHA-256 digest mismatch with identical length',
  );
}
