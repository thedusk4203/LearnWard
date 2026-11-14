import 'dart:typed_data';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase Storage implementation of [AssessmentEvidenceStorage] targeting
/// the private `assessment-evidence` bucket.
///
/// Invariants and security boundaries enforced:
/// - I01: Strict byte comparison (length and SHA-256) on HTTP 409 / duplicate responses.
/// - I03: `upsert = false` enforced on all uploads.
/// - I04: Remote bytes are preserved on DB registration or reconciliation failure.
/// - I05: Positive byte proof required before 409 is treated as success.
/// - I06: Download failures (401/403/404/RLS 0-row/timeout) fail closed as unknown outcome.
/// - I07 / R32-06: Mandatory live session validation via [AuthSessionPort] on every call.
/// - R32-07 / I16: Raw SDK/transport exceptions, bearer tokens, JWTs, URLs, and
///   private Storage paths are never exposed in thrown errors or outcomes.
/// - R32-08: Zero-length uploads/downloads rejected and > 10 MiB remote responses are
///   aborted mid-stream via `storage_client-2.8.1` `StorageFileApi.downloadStream`.
/// - WP1 -> WP2/WP3 boundary: WP1 verifies live [AuthSessionPort] state and
///   in-flight [ValidatedActorContext] / `expectedSessionGeneration` invariance.
///   Durable cross-restart actor provenance (`actorUserId`, persisted session epoch,
///   and lease-fenced CAS on local drafts) depends on WP2/WP3.
final class SupabaseAssessmentEvidenceStorage
    implements AssessmentEvidenceStorage {
  SupabaseAssessmentEvidenceStorage(
    this._client, {
    required this.authSessionPort,
  });

  final SupabaseClient _client;
  final AuthSessionPort authSessionPort;

  static const String bucketName = 'assessment-evidence';

  String _formatStorageStatusReason(String operation, String? statusCode) {
    final trimmed = statusCode?.trim();
    if (trimmed != null && RegExp(r'^\d{3}$').hasMatch(trimmed)) {
      return 'Remote storage error during $operation (status: $trimmed).';
    }
    return 'Remote storage error during $operation.';
  }

  /// Streams remote evidence bytes using `StorageFileApi.downloadStream`
  /// (supported in `storage_client-2.8.1`), cancelling immediately if total bytes
  /// exceed [AssessmentEvidenceStorage.maxFileSizeBytes] (10 MiB) or rejecting
  /// empty 0-byte objects.
  ///
  /// Unlike `download()`, which buffers the entire response body via
  /// `http.Response.fromStream`, `downloadStream()` yields chunks directly from
  /// `http.StreamedResponse.stream` so oversized responses are aborted without
  /// retaining unbounded bytes in memory.
  Future<Uint8List> _downloadBoundedBytes(String storagePath) async {
    final stream = _client.storage.from(bucketName).downloadStream(storagePath);
    final builder = BytesBuilder(copy: false);
    var totalBytes = 0;

    await for (final chunk in stream) {
      totalBytes += chunk.length;
      if (totalBytes > AssessmentEvidenceStorage.maxFileSizeBytes) {
        throw _RemoteEvidenceTooLargeException(totalBytes);
      }
      builder.add(chunk);
    }

    final downloaded = builder.takeBytes();
    if (downloaded.isEmpty) {
      throw const _RemoteEvidenceEmptyException();
    }
    return downloaded;
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
    final provisionalExt = mediaType == 'image/png' ? '.png' : '.jpg';
    final candidatePath =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}$provisionalExt';

    // 1. Mandatory live session validation before processing upload (R32-06 / I07)
    final validatedActor = await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: candidatePath,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      stage: 'evidence upload',
    );

    // 2. Client-side non-empty, 10 MiB size cap, and MIME validation (R32-08)
    final ext = validateEvidenceUploadPayload(
      bytes: bytes,
      mediaType: mediaType,
    );
    final storagePath =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}.$ext';

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
        // Strict HTTP 409 reconciliation: stream-bounded download and compare length + SHA-256
        final reconciliation = await reconcileEvidence(
          storagePath: storagePath,
          localBytes: bytes,
          context: context ?? validatedActor,
          expectedSessionGeneration:
              expectedSessionGeneration ?? validatedActor.sessionGeneration,
        );

        switch (reconciliation) {
          case MatchingBytesOutcome():
            return storagePath;
          case ContentConflictOutcome(:final reason):
            throw EvidenceStorageConflictException(reconciliation, reason);
          case UnknownOutcome(:final reason):
            throw EvidenceStorageUnknownOutcomeException(
              reconciliation,
              reason,
            );
          case AuthFailureOutcome(:final reason):
            throw EvidenceStorageAuthException(reconciliation, reason);
        }
      }

      if (e.statusCode?.trim() == '401') {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason:
                'Remote storage upload rejected due to authentication failure.',
            isServerHttpAuthRejection: true,
          ),
        );
      }

      final unknownOutcome = UnknownOutcome(
        storagePath: storagePath,
        reason: _formatStorageStatusReason('evidence upload', e.statusCode),
      );
      throw EvidenceStorageUnknownOutcomeException(unknownOutcome);
    } on AssessmentEvidenceStorageException {
      rethrow;
    } on InvalidAssessmentException {
      rethrow;
    } catch (_) {
      final unknownOutcome = UnknownOutcome(
        storagePath: storagePath,
        reason: 'Unexpected transport error during evidence upload.',
      );
      throw EvidenceStorageUnknownOutcomeException(unknownOutcome);
    }

    return storagePath;
  }

  @override
  Future<List<int>> downloadEvidence({
    required String storagePath,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: storagePath,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      stage: 'evidence download',
    );

    try {
      return await _downloadBoundedBytes(storagePath);
    } on _RemoteEvidenceTooLargeException catch (e) {
      throw EvidenceStorageConflictException(
        ContentConflictOutcome(
          storagePath: storagePath,
          localSha256: '',
          remoteSha256: '',
          localByteCount: 0,
          remoteByteCount: e.observedByteCount,
          reason:
              'Remote evidence object exceeds maximum allowed size (10 MiB).',
        ),
      );
    } on _RemoteEvidenceEmptyException {
      throw EvidenceStorageConflictException(
        ContentConflictOutcome(
          storagePath: storagePath,
          localSha256: '',
          remoteSha256: '',
          localByteCount: 0,
          remoteByteCount: 0,
          reason: 'Remote evidence object is empty.',
        ),
      );
    } on StorageException catch (e) {
      throw EvidenceStorageUnknownOutcomeException(
        UnknownOutcome(
          storagePath: storagePath,
          reason: _formatStorageStatusReason('evidence download', e.statusCode),
        ),
      );
    } on AssessmentEvidenceStorageException {
      rethrow;
    } catch (_) {
      throw EvidenceStorageUnknownOutcomeException(
        UnknownOutcome(
          storagePath: storagePath,
          reason: 'Unexpected transport error during evidence download.',
        ),
      );
    }
  }

  @override
  Future<EvidenceStorageReconciliationResult> reconcileEvidence({
    required String storagePath,
    required List<int> localBytes,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    // 1. Authoritative session check before Storage interaction
    final ValidatedActorContext currentContext;
    try {
      currentContext = await assertValidStorageAuthSession(
        authSessionPort: authSessionPort,
        storagePath: storagePath,
        context: context,
        expectedSessionGeneration: expectedSessionGeneration,
        stage: 'evidence reconciliation preflight',
      );
    } on EvidenceStorageAuthException catch (e) {
      return e.result;
    }

    final effectiveSessionGen =
        expectedSessionGeneration ??
        context?.sessionGeneration ??
        currentContext.sessionGeneration;

    // 2. Bounded stream download with revalidated auth & size limits
    final List<int> remoteBytes;
    try {
      remoteBytes = await downloadEvidence(
        storagePath: storagePath,
        context: context ?? currentContext,
        expectedSessionGeneration: effectiveSessionGen,
      );
    } on EvidenceStorageAuthException catch (e) {
      // Finding R32-03: Preserve distinct AuthFailureOutcome! Do NOT convert to UnknownOutcome!
      return e.result;
    } on EvidenceStorageConflictException catch (e) {
      return ContentConflictOutcome(
        storagePath: storagePath,
        localSha256: computeSha256Hex(localBytes),
        remoteSha256: e.result.remoteSha256,
        localByteCount: localBytes.length,
        remoteByteCount: e.result.remoteByteCount,
        reason: e.result.reason,
      );
    } on EvidenceStorageUnknownOutcomeException catch (e) {
      return e.result;
    } on StorageException catch (e) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: _formatStorageStatusReason(
          'evidence reconciliation',
          e.statusCode,
        ),
      );
    } catch (_) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Unexpected transport error during evidence reconciliation.',
      );
    }

    // 3. Strict byte length and SHA-256 digest comparison (R32-08)
    return reconcileRemoteEvidenceBytes(
      storagePath: storagePath,
      localBytes: localBytes,
      remoteBytes: remoteBytes,
    );
  }

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: storagePath,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      stage: 'signed URL generation',
    );

    try {
      return await _client.storage
          .from(bucketName)
          .createSignedUrl(storagePath, expiresIn.inSeconds);
    } on StorageException catch (e) {
      if (e.statusCode?.trim() == '401') {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason: 'Remote storage signed URL request rejected due to authentication failure.',
            isServerHttpAuthRejection: true,
          ),
        );
      }
      throw EvidenceStorageUnknownOutcomeException(
        UnknownOutcome(
          storagePath: storagePath,
          reason: _formatStorageStatusReason(
            'signed URL generation',
            e.statusCode,
          ),
        ),
      );
    } on AssessmentEvidenceStorageException {
      rethrow;
    } catch (_) {
      throw EvidenceStorageUnknownOutcomeException(
        UnknownOutcome(
          storagePath: storagePath,
          reason: 'Unexpected transport error during signed URL generation.',
        ),
      );
    }
  }

  @override
  Future<void> deleteEvidence(
    String storagePath, {
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    await assertValidStorageAuthSession(
      authSessionPort: authSessionPort,
      storagePath: storagePath,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      stage: 'evidence deletion',
    );

    try {
      await _client.storage.from(bucketName).remove([storagePath]);
    } on StorageException catch (e) {
      if (e.statusCode?.trim() == '401') {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason:
                'Remote storage delete rejected due to authentication failure.',
            isServerHttpAuthRejection: true,
          ),
        );
      }
      throw EvidenceStorageUnknownOutcomeException(
        UnknownOutcome(
          storagePath: storagePath,
          reason: _formatStorageStatusReason('evidence deletion', e.statusCode),
        ),
      );
    } on AssessmentEvidenceStorageException {
      rethrow;
    } catch (_) {
      throw EvidenceStorageUnknownOutcomeException(
        UnknownOutcome(
          storagePath: storagePath,
          reason: 'Unexpected transport error during evidence deletion.',
        ),
      );
    }
  }
}

final class _RemoteEvidenceTooLargeException implements Exception {
  const _RemoteEvidenceTooLargeException(this.observedByteCount);
  final int observedByteCount;
}

final class _RemoteEvidenceEmptyException implements Exception {
  const _RemoteEvidenceEmptyException();
}
