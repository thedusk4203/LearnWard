import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

final class FakeAssessmentEvidenceStorage implements AssessmentEvidenceStorage {
  FakeAssessmentEvidenceStorage({this.authSessionPort});

  final AuthSessionPort? authSessionPort;
  final Map<String, List<int>> storage = {};
  final List<String> deleteCalls = [];

  bool throwOnRegister = false;
  Object? throwOnUpload;
  Object? throwOnDownload;
  Object? throwOnReconcile;
  bool returnUnknownOnReconcile = false;

  void Function()? onAfterFirstReconcileAuthCheck;
  void Function()? onAfterUpload;

  int uploadCallCount = 0;
  int downloadCallCount = 0;
  int reconcileCallCount = 0;
  int deleteCallCount = 0;
  int signedUrlCallCount = 0;

  Future<ValidatedActorContext?> _checkAuth({
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
    required String storagePath,
  }) async {
    if (authSessionPort != null) {
      final fresh = await authSessionPort!.validateForMutation();
      if (fresh == null || !fresh.isValidAt(DateTime.now().toUtc())) {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason: 'Unauthenticated or expired session.',
          ),
        );
      }
      final genToCheck =
          expectedSessionGeneration ?? context?.sessionGeneration;
      if (genToCheck != null && fresh.sessionGeneration != genToCheck) {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason: 'Session generation changed across asynchronous boundary.',
          ),
        );
      }
      if (context != null && fresh.userId != context.userId) {
        throw EvidenceStorageAuthException(
          AuthFailureOutcome(
            storagePath: storagePath,
            reason: 'Actor switch detected: active session does not match original actor.',
          ),
        );
      }
      return fresh;
    }
    return context;
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
    uploadCallCount++;
    final ext = mediaType == 'image/png' ? 'png' : 'jpg';
    final path =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}.$ext';

    await _checkAuth(
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      storagePath: path,
    );

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

    if (throwOnUpload != null) {
      throw throwOnUpload!;
    }

    // Check if object already exists: simulates Storage 409
    if (storage.containsKey(path)) {
      final reconciliation = await reconcileEvidence(
        storagePath: path,
        localBytes: bytes,
        context: context,
        expectedSessionGeneration: expectedSessionGeneration,
      );
      switch (reconciliation) {
        case MatchingBytesOutcome():
          return path;
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

    storage[path] = List<int>.from(bytes);
    onAfterUpload?.call();
    return path;
  }

  @override
  Future<List<int>> downloadEvidence({
    required String storagePath,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    downloadCallCount++;
    await _checkAuth(
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      storagePath: storagePath,
    );

    if (throwOnDownload != null) {
      throw throwOnDownload!;
    }

    final data = storage[storagePath];
    if (data == null) {
      throw StateError('Remote storage object not found: $storagePath');
    }

    if (data.length > AssessmentEvidenceStorage.maxFileSizeBytes) {
      throw EvidenceStorageConflictException(
        ContentConflictOutcome(
          storagePath: storagePath,
          localSha256: '',
          remoteSha256: computeSha256Hex(data),
          localByteCount: 0,
          remoteByteCount: data.length,
          reason:
              'Remote evidence object exceeds maximum allowed size (10 MiB).',
        ),
      );
    }

    return List<int>.from(data);
  }

  @override
  Future<EvidenceStorageReconciliationResult> reconcileEvidence({
    required String storagePath,
    required List<int> localBytes,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    reconcileCallCount++;
    ValidatedActorContext? currentContext;
    if (authSessionPort != null) {
      try {
        currentContext = await _checkAuth(
          context: context,
          expectedSessionGeneration: expectedSessionGeneration,
          storagePath: storagePath,
        );
      } on EvidenceStorageAuthException catch (e) {
        return e.result;
      }
    }

    final effectiveSessionGen =
        expectedSessionGeneration ??
        context?.sessionGeneration ??
        currentContext?.sessionGeneration;

    onAfterFirstReconcileAuthCheck?.call();

    if (throwOnReconcile != null) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Simulated reconciliation failure',
        cause: throwOnReconcile,
      );
    }

    if (returnUnknownOnReconcile) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Simulated unknown outcome',
      );
    }

    List<int> remoteBytes;
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
      return e.result;
    } catch (e) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Download failed during reconciliation: $e',
        cause: e,
      );
    }

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
        remoteSha256: computeSha256Hex(remoteBytes),
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

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    signedUrlCallCount++;
    await _checkAuth(
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      storagePath: storagePath,
    );
    return 'https://storage.fake.learnward.local/$storagePath?signed=true';
  }

  @override
  Future<void> deleteEvidence(
    String storagePath, {
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    deleteCallCount++;
    await _checkAuth(
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      storagePath: storagePath,
    );
    deleteCalls.add(storagePath);
    storage.remove(storagePath);
  }
}
