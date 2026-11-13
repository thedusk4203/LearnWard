import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

final class FakeAssessmentEvidenceStorage implements AssessmentEvidenceStorage {
  FakeAssessmentEvidenceStorage({
    this.authSessionPort,
    this.allowUnauthenticatedForTesting = false,
  });

  /// Explicitly configures this test fake for unauthenticated mode without an [AuthSessionPort].
  FakeAssessmentEvidenceStorage.unauthenticated()
    : authSessionPort = null,
      allowUnauthenticatedForTesting = true;

  final AuthSessionPort? authSessionPort;
  final bool allowUnauthenticatedForTesting;
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
    required String stage,
  }) async {
    final port = authSessionPort;
    if (port == null) {
      if (allowUnauthenticatedForTesting) {
        return context;
      }
      throw EvidenceStorageAuthException(
        AuthFailureOutcome(
          storagePath: storagePath,
          reason: 'Missing AuthSessionPort for Storage operation ($stage).',
        ),
      );
    }
    return assertValidStorageAuthSession(
      authSessionPort: port,
      storagePath: storagePath,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      stage: stage,
    );
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
    final provisionalExt = mediaType == 'image/png' ? '.png' : '.jpg';
    final candidatePath =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}$provisionalExt';

    final validatedActor = await _checkAuth(
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      storagePath: candidatePath,
      stage: 'evidence upload',
    );

    final ext = validateEvidenceUploadPayload(
      bytes: bytes,
      mediaType: mediaType,
    );
    final path =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}.$ext';

    if (throwOnUpload != null) {
      throw throwOnUpload!;
    }

    // Check if object already exists: simulates Storage 409
    if (storage.containsKey(path)) {
      final reconciliation = await reconcileEvidence(
        storagePath: path,
        localBytes: bytes,
        context: context ?? validatedActor,
        expectedSessionGeneration:
            expectedSessionGeneration ?? validatedActor?.sessionGeneration,
      );
      switch (reconciliation) {
        case MatchingBytesOutcome():
          return path;
        case ContentConflictOutcome(:final reason):
          throw EvidenceStorageConflictException(reconciliation, reason);
        case UnknownOutcome(:final reason):
          throw EvidenceStorageUnknownOutcomeException(reconciliation, reason);
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
      stage: 'evidence download',
    );

    if (throwOnDownload != null) {
      throw throwOnDownload!;
    }

    final data = storage[storagePath];
    if (data == null) {
      throw EvidenceStorageUnknownOutcomeException(
        UnknownOutcome(
          storagePath: storagePath,
          reason: 'Remote storage object not found.',
        ),
      );
    }

    if (data.isEmpty) {
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
    }

    if (data.length > AssessmentEvidenceStorage.maxFileSizeBytes) {
      throw EvidenceStorageConflictException(
        ContentConflictOutcome(
          storagePath: storagePath,
          localSha256: '',
          remoteSha256: '',
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
    try {
      currentContext = await _checkAuth(
        context: context,
        expectedSessionGeneration: expectedSessionGeneration,
        storagePath: storagePath,
        stage: 'evidence reconciliation preflight',
      );
    } on EvidenceStorageAuthException catch (e) {
      return e.result;
    }

    final effectiveSessionGen =
        expectedSessionGeneration ??
        context?.sessionGeneration ??
        currentContext?.sessionGeneration;

    onAfterFirstReconcileAuthCheck?.call();

    if (throwOnReconcile != null) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Simulated reconciliation failure.',
      );
    }

    if (returnUnknownOnReconcile) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Simulated unknown outcome.',
      );
    }

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
    } catch (_) {
      return UnknownOutcome(
        storagePath: storagePath,
        reason: 'Download failed during reconciliation.',
      );
    }

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
    signedUrlCallCount++;
    await _checkAuth(
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
      storagePath: storagePath,
      stage: 'signed URL generation',
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
      stage: 'evidence deletion',
    );
    deleteCalls.add(storagePath);
    storage.remove(storagePath);
  }
}
