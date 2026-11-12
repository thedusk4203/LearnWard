import 'dart:typed_data';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase Storage implementation of [AssessmentEvidenceStorage] targeting
/// the private `assessment-evidence` bucket.
///
/// Invariants enforced:
/// - I01: Strict byte comparison (length and SHA-256) on HTTP 409 / duplicate responses.
/// - I03: `upsert = false` enforced on all uploads.
/// - I05: Positive byte proof required before 409 is treated as success.
/// - I06: Download failures (401/403/404/RLS 0-row/timeout) fail closed as unknown outcome.
/// - I07: Authoritative session validation via [AuthSessionPort] before mutation or download.
final class SupabaseAssessmentEvidenceStorage
    implements AssessmentEvidenceStorage {
  SupabaseAssessmentEvidenceStorage(this._client, {this.authSessionPort});

  final SupabaseClient _client;
  final AuthSessionPort? authSessionPort;

  static const String bucketName = 'assessment-evidence';

  Future<void> _assertValidAuthSession({
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
    required String storagePath,
  }) async {
    if (authSessionPort != null) {
      final freshContext = await authSessionPort!.validateForMutation();
      if (freshContext == null ||
          !freshContext.isValidAt(DateTime.now().toUtc())) {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason: 'Unauthenticated or expired session.',
          ),
        );
      }
      final genToCheck =
          expectedSessionGeneration ?? context?.sessionGeneration;
      if (genToCheck != null && freshContext.sessionGeneration != genToCheck) {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason: 'Session generation changed across asynchronous boundary.',
          ),
        );
      }
      if (context != null && freshContext.userId != context.userId) {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason: 'Actor switch detected: active session does not match original actor.',
          ),
        );
      }
    }
  }

  @override
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    // 1. Client-side size and MIME validation
    if (bytes.length > AssessmentEvidenceStorage.maxFileSizeBytes) {
      throw const InvalidAssessmentException(
        'Evidence file size must not exceed 10 MiB.',
      );
    }
    if (mediaType != 'image/jpeg' && mediaType != 'image/png') {
      throw InvalidAssessmentException(
        'Unsupported media type: $mediaType. Only JPEG and PNG are allowed.',
      );
    }

    final ext = mediaType == 'image/png' ? 'png' : 'jpg';
    final storagePath =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}.$ext';

    // 2. Authoritative session validation (R31-08 / Invariant I07)
    await _assertValidAuthSession(
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      storagePath: storagePath,
    );

    // 3. Strictly enforce immutable object identity: upsert = false
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
      final is409 =
          e.statusCode == '409' ||
          msg.contains('already exists') ||
          msg.contains('duplicate');

      if (is409) {
        // Strict HTTP 409 reconciliation: download remote bytes and compare length and SHA-256
        final reconciliation = await reconcileEvidence(
          storagePath: storagePath,
          localBytes: bytes,
          context: context,
          expectedSessionGeneration: expectedSessionGeneration,
        );

        switch (reconciliation) {
          case MatchingBytesOutcome():
            // Positive byte proof: identical bytes and size already present
            return storagePath;
          case ContentConflictOutcome(:final reason):
            throw EvidenceStorageConflictException(reconciliation, reason);
          case UnknownOutcome(:final reason, :final cause):
            throw EvidenceStorageUnknownOutcomeException(
              reconciliation,
              reason,
              cause,
            );
          case AuthFailureOutcome(:final reason):
            throw EvidenceStorageAuthException(reconciliation, reason);
        }
      }
      rethrow;
    }

    return storagePath;
  }

  @override
  Future<List<int>> downloadEvidence({
    required String storagePath,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    await _assertValidAuthSession(
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      storagePath: storagePath,
    );

    final Uint8List downloaded = await _client.storage
        .from(bucketName)
        .download(storagePath);
    return downloaded;
  }

  @override
  Future<EvidenceStorageReconciliationResult> reconcileEvidence({
    required String storagePath,
    required List<int> localBytes,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    // 1. Authoritative session check
    try {
      await _assertValidAuthSession(
        context: context,
        expectedSessionGeneration: expectedSessionGeneration,
        storagePath: storagePath,
      );
    } on EvidenceStorageAuthException catch (e) {
      return e.result;
    }

    // 2. Download remote object bytes
    List<int> remoteBytes;
    try {
      remoteBytes = await downloadEvidence(
        storagePath: storagePath,
        context: context,
        expectedSessionGeneration: expectedSessionGeneration,
      );
    } on StorageException catch (e) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Storage error during evidence download: ${e.message}',
        cause: e,
      );
    } catch (e) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Unexpected error during evidence download: $e',
        cause: e,
      );
    }

    // 3. Strict byte length and SHA-256 digest comparison
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
