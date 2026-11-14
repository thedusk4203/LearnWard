import 'dart:async';
import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../shared/utils/uuid_generator.dart';

/// Machine-readable classification for [EvidenceStorageException].
enum EvidenceStorageFailureKind {
  ioOrCollision,
  missingSnapshot,
  corruptedOrTamperedSnapshot,
  outOfBoundsOrSymlink,
  invalidInput,
}

/// Exception thrown when evidence file storage operations fail safely
/// without risking data loss, collision, or uncoordinated file destruction.
final class EvidenceStorageException implements Exception {
  const EvidenceStorageException(
    this.message, {
    this.cause,
    this.kind = EvidenceStorageFailureKind.ioOrCollision,
  });

  final String message;
  final Object? cause;
  final EvidenceStorageFailureKind kind;

  @override
  String toString() => 'EvidenceStorageException(${kind.name}): $message';
}

/// Status of an unreferenced evidence file deletion attempt.
enum EvidenceFileDeletionStatus {
  /// File was safely deleted from durable storage.
  /// (Deprecated in Slice 4B-0: retained for API compatibility, but physical unlinking is disabled).
  deleted,

  /// File was already absent from storage (idempotent success).
  alreadyAbsent,

  /// File was preserved because one or more drafts still reference it.
  preservedReferenced,

  /// File was preserved under Slice 4B-0 conservative evidence retention policy.
  /// Physical garbage collection is explicitly deferred pending an approved design.
  preservedConservative,

  /// Deletion was rejected because the path targets outside the managed evidence directory
  /// or attempts path traversal/symlink escape.
  rejectedOutOfBounds,

  /// Deletion failed due to a filesystem or I/O error.
  deletionFailed,
}

/// Explicit, typed result of [LocalEvidenceFileStore.deleteEvidenceIfUnreferenced].
final class EvidenceFileDeletionResult {
  const EvidenceFileDeletionResult({
    required this.status,
    required this.filePath,
    this.reason,
    this.referenceCount = 0,
  });

  final EvidenceFileDeletionStatus status;
  final String filePath;
  final String? reason;
  final int referenceCount;

  bool get isDeleted => status == EvidenceFileDeletionStatus.deleted;
  bool get isAlreadyAbsent =>
      status == EvidenceFileDeletionStatus.alreadyAbsent;
  bool get isPreserved =>
      status == EvidenceFileDeletionStatus.preservedReferenced ||
      status == EvidenceFileDeletionStatus.preservedConservative;
  bool get isRejectedOutOfBounds =>
      status == EvidenceFileDeletionStatus.rejectedOutOfBounds;
  bool get isFailed => status == EvidenceFileDeletionStatus.deletionFailed;

  @override
  String toString() =>
      'EvidenceFileDeletionResult(status: $status, path: $filePath, refs: $referenceCount, reason: $reason)';
}

/// Persistent app-private file store for offline evidence attachments.
///
/// Ensures evidence attached to local drafts survives process death and app restarts.
/// Under Slice 4B-0 conservative evidence retention policy, physical unlinking is
/// disabled across all cleanup paths to eliminate the risk of destroying unsynced
/// or unverified evidence. Physical garbage collection is explicitly deferred
/// pending an approved design.
abstract interface class LocalEvidenceFileStore {
  /// Saves durable evidence attached to [localDraftId] using exclusive, non-overwriting creation.
  ///
  /// Throws [EvidenceStorageException] if [localDraftId] is invalid, if path traversal is attempted,
  /// or if all exclusive creation attempts collide without overwriting existing files.
  Future<String> saveDurableEvidence({
    required String localDraftId,
    required List<int> bytes,
    required String mediaType,
  });

  /// Saves evidence with [fileName] using exclusive, non-overwriting creation.
  ///
  /// Throws [EvidenceStorageException] if [fileName] is invalid, if path traversal is attempted,
  /// or if all exclusive creation attempts collide without overwriting existing files.
  Future<String> saveEvidence({
    required String fileName,
    required List<int> bytes,
  });

  Future<List<int>?> readEvidenceBytes(String filePath);

  Future<List<int>?> loadEvidence(String filePath);

  /// Disabled under Slice 4B-0 conservative evidence retention policy.
  ///
  /// Physical unlinking is a safe no-op. Physical garbage collection is explicitly
  /// deferred pending an approved design.
  Future<void> deleteDurableEvidence(String filePath);

  /// Disabled under Slice 4B-0 conservative evidence retention policy.
  ///
  /// Physical unlinking is a safe no-op. Physical garbage collection is explicitly
  /// deferred pending an approved design.
  Future<void> deleteEvidence(String filePath);

  /// Reference-aware evidence file cleanup.
  ///
  /// In Phase 6 Slice 4B-0, conservative evidence retention is strictly enforced.
  /// Physical unlinking is completely disabled to eliminate cross-connection
  /// reference-check-to-unlink gaps without risking destruction of unverified evidence.
  /// Physical garbage collection is explicitly deferred pending an approved design.
  ///
  /// Returns a typed [EvidenceFileDeletionResult] detailing the outcome.
  /// Fails closed and conservatively retains files on any error, ambiguity, or boundary violation.
  Future<EvidenceFileDeletionResult> deleteEvidenceIfUnreferenced({
    required String filePath,
    required LocalDraftStore draftStore,
  });

  /// Freezes an immutable canonical JPEG/PNG evidence snapshot for [localDraftId]
  /// using exclusive file creation, `RandomAccessFile` write + `flushSync` + `closeSync`,
  /// and mandatory disk re-read checksum verification.
  Future<CanonicalEvidenceSnapshot> saveCanonicalEvidenceSnapshot({
    required String localDraftId,
    required List<int> bytes,
  });

  /// Verifies an existing canonical snapshot file on disk against directory confinement,
  /// symlink safety, magic-byte MIME, optional length/mediaType, and lowercase SHA-256.
  Future<VerifiedCanonicalEvidence> verifyCanonicalEvidenceSnapshot({
    required String localDraftId,
    required String canonicalFilePath,
    required String expectedSha256,
    int? expectedByteLength,
    String? expectedMediaType,
    DateTime? frozenAt,
  });

  /// Reads and verifies ONLY the immutable `draft.localCompressedPhotoPath` using
  /// `draft.sha256Checksum`. Never falls back to mutable `draft.localPhotoPath`.
  Future<VerifiedCanonicalEvidence> readVerifiedCanonicalSnapshot({
    required LocalAssessmentDraft draft,
  });
}

final class DefaultLocalEvidenceFileStore implements LocalEvidenceFileStore {
  DefaultLocalEvidenceFileStore({
    Directory? baseDirectory,
    this.onPreUnlink,
    this.onBeforeCanonicalVerify,
    String Function()? suffixGenerator,
    DateTime Function()? clock,
  }) : _customBaseDir = baseDirectory,
       _suffixGenerator = suffixGenerator ?? generateUuid,
       _clock = clock ?? DateTime.now;

  final Directory? _customBaseDir;

  /// Optional test seam invoked during reference checks.
  final Future<void> Function(String filePath)? onPreUnlink;

  /// Optional test seam invoked after closing the canonical file and before disk verification.
  final FutureOr<void> Function(String filePath)? onBeforeCanonicalVerify;

  /// Deterministic suffix generator seam for collision testing. Defaults to [generateUuid].
  final String Function() _suffixGenerator;

  /// Clock seam for deterministic timestamping. Defaults to [DateTime.now].
  final DateTime Function() _clock;

  Future<Directory> _getEvidenceDirectory() async {
    final Directory base =
        _customBaseDir ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/draft_evidence');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  void _validateSafeLocalDraftId(String localDraftId) {
    if (localDraftId.isEmpty ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(localDraftId)) {
      throw EvidenceStorageException(
        'Invalid localDraftId "$localDraftId": must contain only alphanumeric characters, dashes, and underscores.',
        kind: EvidenceStorageFailureKind.invalidInput,
      );
    }
  }

  Future<
    ({
      bool inBounds,
      bool isSymlinkEscape,
      String canonicalEvidenceDir,
      String resolvedEvidenceDir,
      String canonicalFilePath,
      String? resolvedFilePath,
      FileSystemEntityType entityType,
      String? errorReason,
    })
  >
  _inspectConfinedPath(String filePath) async {
    final Directory evidenceDir = await _getEvidenceDirectory();
    final canonicalEvidenceDir = p.canonicalize(evidenceDir.path);
    final resolvedEvidenceDir = evidenceDir.existsSync()
        ? p.canonicalize(evidenceDir.resolveSymbolicLinksSync())
        : canonicalEvidenceDir;
    final canonicalFilePath = p.canonicalize(filePath);

    if (filePath.isEmpty ||
        (!p.isWithin(canonicalEvidenceDir, canonicalFilePath) &&
            !p.isWithin(resolvedEvidenceDir, canonicalFilePath))) {
      return (
        inBounds: false,
        isSymlinkEscape: false,
        canonicalEvidenceDir: canonicalEvidenceDir,
        resolvedEvidenceDir: resolvedEvidenceDir,
        canonicalFilePath: canonicalFilePath,
        resolvedFilePath: null,
        entityType: FileSystemEntityType.notFound,
        errorReason:
            'Target path "$canonicalFilePath" is outside evidence directory "$canonicalEvidenceDir".',
      );
    }

    final linkAwareType = FileSystemEntity.typeSync(
      canonicalFilePath,
      followLinks: false,
    );
    if (linkAwareType == FileSystemEntityType.link) {
      return (
        inBounds: true,
        isSymlinkEscape: true,
        canonicalEvidenceDir: canonicalEvidenceDir,
        resolvedEvidenceDir: resolvedEvidenceDir,
        canonicalFilePath: canonicalFilePath,
        resolvedFilePath: null,
        entityType: FileSystemEntityType.link,
        errorReason: 'Symlinks are not permitted inside evidence storage.',
      );
    }
    if (linkAwareType == FileSystemEntityType.notFound) {
      return (
        inBounds: true,
        isSymlinkEscape: false,
        canonicalEvidenceDir: canonicalEvidenceDir,
        resolvedEvidenceDir: resolvedEvidenceDir,
        canonicalFilePath: canonicalFilePath,
        resolvedFilePath: null,
        entityType: FileSystemEntityType.notFound,
        errorReason: null,
      );
    }
    if (linkAwareType != FileSystemEntityType.file) {
      return (
        inBounds: true,
        isSymlinkEscape: false,
        canonicalEvidenceDir: canonicalEvidenceDir,
        resolvedEvidenceDir: resolvedEvidenceDir,
        canonicalFilePath: canonicalFilePath,
        resolvedFilePath: null,
        entityType: linkAwareType,
        errorReason: 'Target entity is not a regular file.',
      );
    }

    try {
      final resolved = p.canonicalize(
        File(canonicalFilePath).resolveSymbolicLinksSync(),
      );
      if (!p.isWithin(resolvedEvidenceDir, resolved) &&
          !p.isWithin(canonicalEvidenceDir, resolved)) {
        return (
          inBounds: true,
          isSymlinkEscape: true,
          canonicalEvidenceDir: canonicalEvidenceDir,
          resolvedEvidenceDir: resolvedEvidenceDir,
          canonicalFilePath: canonicalFilePath,
          resolvedFilePath: resolved,
          entityType: FileSystemEntityType.file,
          errorReason:
              'Target symlink resolves to "$resolved" outside evidence directory "$resolvedEvidenceDir".',
        );
      }
      return (
        inBounds: true,
        isSymlinkEscape: false,
        canonicalEvidenceDir: canonicalEvidenceDir,
        resolvedEvidenceDir: resolvedEvidenceDir,
        canonicalFilePath: canonicalFilePath,
        resolvedFilePath: resolved,
        entityType: FileSystemEntityType.file,
        errorReason: null,
      );
    } catch (e) {
      return (
        inBounds: true,
        isSymlinkEscape: true,
        canonicalEvidenceDir: canonicalEvidenceDir,
        resolvedEvidenceDir: resolvedEvidenceDir,
        canonicalFilePath: canonicalFilePath,
        resolvedFilePath: null,
        entityType: FileSystemEntityType.file,
        errorReason: 'Failed to resolve symbolic links safely: $e',
      );
    }
  }

  @override
  Future<CanonicalEvidenceSnapshot> saveCanonicalEvidenceSnapshot({
    required String localDraftId,
    required List<int> bytes,
  }) async {
    _validateSafeLocalDraftId(localDraftId);

    final InspectedEvidenceBytes inspected;
    try {
      inspected = inspectAndValidateEvidenceBytes(bytes);
    } on CanonicalEvidenceValidationException catch (e) {
      throw EvidenceStorageException(
        e.message,
        cause: e,
        kind: EvidenceStorageFailureKind.invalidInput,
      );
    }

    final dir = await _getEvidenceDirectory();
    final canonicalEvidenceDir = p.canonicalize(dir.path);
    final resolvedEvidenceDir = dir.existsSync()
        ? p.canonicalize(dir.resolveSymbolicLinksSync())
        : canonicalEvidenceDir;
    final timestamp = _clock().toUtc().millisecondsSinceEpoch;

    for (int attempt = 0; attempt < 5; attempt++) {
      final uniqueSuffix = _suffixGenerator();
      final targetPath = p.join(
        dir.path,
        '${localDraftId}_canonical_${timestamp}_$uniqueSuffix.${inspected.fileExtension}',
      );
      final canonicalFilePath = p.canonicalize(targetPath);
      if (!p.isWithin(canonicalEvidenceDir, canonicalFilePath) &&
          !p.isWithin(resolvedEvidenceDir, canonicalFilePath)) {
        throw const EvidenceStorageException(
          'Canonical snapshot target path escapes evidence storage directory.',
          kind: EvidenceStorageFailureKind.outOfBoundsOrSymlink,
        );
      }

      final File file;
      try {
        file = File(canonicalFilePath)..createSync(exclusive: true);
      } on PathExistsException {
        continue;
      } on FileSystemException catch (e) {
        if (File(canonicalFilePath).existsSync()) continue;
        throw EvidenceStorageException(
          'I/O failure allocating canonical snapshot for draft "$localDraftId".',
          cause: e,
          kind: EvidenceStorageFailureKind.ioOrCollision,
        );
      }

      try {
        final raf = file.openSync(mode: FileMode.writeOnly);
        try {
          raf.writeFromSync(inspected.bytes);
          raf.flushSync();
        } finally {
          raf.closeSync();
        }
      } on FileSystemException catch (e) {
        throw EvidenceStorageException(
          'Failed writing canonical evidence bytes for draft "$localDraftId".',
          cause: e,
          kind: EvidenceStorageFailureKind.ioOrCollision,
        );
      }

      if (onBeforeCanonicalVerify != null) {
        await onBeforeCanonicalVerify!(canonicalFilePath);
      }

      final verified = await verifyCanonicalEvidenceSnapshot(
        localDraftId: localDraftId,
        canonicalFilePath: canonicalFilePath,
        expectedSha256: inspected.sha256Checksum,
        expectedByteLength: inspected.byteLength,
        expectedMediaType: inspected.mediaType,
        frozenAt: _clock().toUtc(),
      );
      return verified.snapshot;
    }

    throw EvidenceStorageException(
      'Failed to exclusively create canonical evidence snapshot after 5 collision attempts for draft "$localDraftId".',
      kind: EvidenceStorageFailureKind.ioOrCollision,
    );
  }

  @override
  Future<VerifiedCanonicalEvidence> verifyCanonicalEvidenceSnapshot({
    required String localDraftId,
    required String canonicalFilePath,
    required String expectedSha256,
    int? expectedByteLength,
    String? expectedMediaType,
    DateTime? frozenAt,
  }) async {
    _validateSafeLocalDraftId(localDraftId);
    if (!isValidSha256Hex(expectedSha256)) {
      throw const EvidenceStorageException(
        'Canonical snapshot SHA-256 checksum must be a lowercase 64-character hex digest.',
        kind: EvidenceStorageFailureKind.invalidInput,
      );
    }

    final inspection = await _inspectConfinedPath(canonicalFilePath);
    if (!inspection.inBounds || inspection.isSymlinkEscape) {
      throw const EvidenceStorageException(
        'Canonical snapshot path rejected due to directory confinement or symlink policy.',
        kind: EvidenceStorageFailureKind.outOfBoundsOrSymlink,
      );
    }
    if (inspection.entityType == FileSystemEntityType.notFound) {
      throw EvidenceStorageException(
        'Canonical evidence snapshot file is missing: ${redactStoragePath(canonicalFilePath)}.',
        kind: EvidenceStorageFailureKind.missingSnapshot,
      );
    }
    if (inspection.entityType != FileSystemEntityType.file) {
      throw const EvidenceStorageException(
        'Canonical evidence snapshot target is not a regular file.',
        kind: EvidenceStorageFailureKind.corruptedOrTamperedSnapshot,
      );
    }

    final file = File(
      inspection.resolvedFilePath ?? inspection.canonicalFilePath,
    );
    final List<int> diskBytes;
    try {
      final length = file.lengthSync();
      if (length == 0 || length > AssessmentEvidenceStorage.maxFileSizeBytes) {
        throw EvidenceStorageException(
          'Canonical evidence snapshot has invalid byte length: $length.',
          kind: EvidenceStorageFailureKind.corruptedOrTamperedSnapshot,
        );
      }
      diskBytes = file.readAsBytesSync();
    } on FileSystemException catch (e) {
      throw EvidenceStorageException(
        'Failed reading canonical evidence snapshot ${redactStoragePath(canonicalFilePath)}.',
        cause: e,
        kind: EvidenceStorageFailureKind.ioOrCollision,
      );
    }

    final InspectedEvidenceBytes verified;
    try {
      verified = verifyCanonicalEvidenceBytes(
        bytes: diskBytes,
        expectedSha256: expectedSha256,
        expectedByteLength: expectedByteLength,
        expectedMediaType: expectedMediaType,
      );
    } on CanonicalEvidenceValidationException catch (e) {
      throw EvidenceStorageException(
        e.message,
        cause: e,
        kind: EvidenceStorageFailureKind.corruptedOrTamperedSnapshot,
      );
    }

    return VerifiedCanonicalEvidence(
      snapshot: CanonicalEvidenceSnapshot(
        localDraftId: localDraftId,
        filePath: inspection.canonicalFilePath,
        mediaType: verified.mediaType,
        fileExtension: verified.fileExtension,
        byteLength: verified.byteLength,
        sha256Checksum: verified.sha256Checksum,
        frozenAt: (frozenAt ?? _clock()).toUtc(),
      ),
      bytes: verified.bytes,
    );
  }

  @override
  Future<VerifiedCanonicalEvidence> readVerifiedCanonicalSnapshot({
    required LocalAssessmentDraft draft,
  }) async {
    final canonicalPath = draft.localCompressedPhotoPath;
    final expectedSha256 = draft.sha256Checksum;
    if (canonicalPath == null || canonicalPath.isEmpty) {
      throw const EvidenceStorageException(
        'Draft does not have a frozen canonical snapshot path; refusing fallback to mutable source path.',
        kind: EvidenceStorageFailureKind.missingSnapshot,
      );
    }
    if (!isValidSha256Hex(expectedSha256)) {
      throw const EvidenceStorageException(
        'Draft canonical SHA-256 checksum is missing or malformed.',
        kind: EvidenceStorageFailureKind.corruptedOrTamperedSnapshot,
      );
    }
    return verifyCanonicalEvidenceSnapshot(
      localDraftId: draft.localDraftId,
      canonicalFilePath: canonicalPath,
      expectedSha256: expectedSha256!,
      frozenAt: draft.updatedAt,
    );
  }

  @override
  Future<String> saveDurableEvidence({
    required String localDraftId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    _validateSafeLocalDraftId(localDraftId);

    final dir = await _getEvidenceDirectory();
    final canonicalEvidenceDir = p.canonicalize(dir.path);
    final ext = mediaType == 'image/png' ? 'png' : 'jpg';
    final timestamp = _clock().millisecondsSinceEpoch;

    // Collision-resistant unique naming with non-overwriting exclusive creation semantics
    for (int attempt = 0; attempt < 5; attempt++) {
      final uniqueSuffix = _suffixGenerator();
      final targetPath = p.join(
        dir.path,
        '${localDraftId}_${timestamp}_$uniqueSuffix.$ext',
      );
      final canonicalFilePath = p.canonicalize(targetPath);
      if (!p.isWithin(canonicalEvidenceDir, canonicalFilePath)) {
        throw EvidenceStorageException(
          'Target file path "$canonicalFilePath" is outside evidence directory "$canonicalEvidenceDir".',
        );
      }

      final file = File(canonicalFilePath);
      try {
        file.createSync(exclusive: true);
        file.writeAsBytesSync(bytes, flush: true);
        return file.path;
      } on PathExistsException {
        continue;
      } on FileSystemException {
        if (file.existsSync()) continue;
        rethrow;
      }
    }

    // Eliminate fallback write without exclusive creation: fail closed
    throw EvidenceStorageException(
      'Failed to exclusively create durable evidence file after 5 collision attempts for draft "$localDraftId".',
    );
  }

  @override
  Future<String> saveEvidence({
    required String fileName,
    required List<int> bytes,
  }) async {
    final sanitizedBase = p
        .basename(fileName)
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (sanitizedBase.isEmpty ||
        sanitizedBase == '.' ||
        sanitizedBase == '..' ||
        sanitizedBase.replaceAll('_', '').isEmpty) {
      throw EvidenceStorageException(
        'Invalid fileName "$fileName": must contain valid filename characters.',
      );
    }

    final dir = await _getEvidenceDirectory();
    final canonicalEvidenceDir = p.canonicalize(dir.path);
    final timestamp = _clock().millisecondsSinceEpoch;

    // Collision-resistant unique naming with non-overwriting exclusive creation semantics
    for (int attempt = 0; attempt < 5; attempt++) {
      final uniqueSuffix = _suffixGenerator();
      final targetPath = p.join(
        dir.path,
        '${timestamp}_${uniqueSuffix}_$sanitizedBase',
      );
      final canonicalFilePath = p.canonicalize(targetPath);
      if (!p.isWithin(canonicalEvidenceDir, canonicalFilePath)) {
        throw EvidenceStorageException(
          'Target file path "$canonicalFilePath" is outside evidence directory "$canonicalEvidenceDir".',
        );
      }

      final file = File(canonicalFilePath);
      try {
        file.createSync(exclusive: true);
        file.writeAsBytesSync(bytes, flush: true);
        return file.path;
      } on PathExistsException {
        continue;
      } on FileSystemException {
        if (file.existsSync()) continue;
        rethrow;
      }
    }

    // Eliminate fallback write without exclusive creation: fail closed
    throw EvidenceStorageException(
      'Failed to exclusively create evidence file after 5 collision attempts for file "$fileName".',
    );
  }

  @override
  Future<List<int>?> readEvidenceBytes(String filePath) async {
    final file = File(filePath);
    if (file.existsSync()) {
      return file.readAsBytesSync();
    }
    return null;
  }

  @override
  Future<List<int>?> loadEvidence(String filePath) =>
      readEvidenceBytes(filePath);

  @override
  Future<void> deleteDurableEvidence(String filePath) async {
    // Under Slice 4B-0 conservative evidence retention policy, physical unlinking
    // is disabled across all cleanup paths to eliminate the risk of deleting
    // unsynced or unverified evidence.
    // Physical garbage collection is explicitly deferred pending an approved design.
    return;
  }

  @override
  Future<void> deleteEvidence(String filePath) =>
      deleteDurableEvidence(filePath);

  @override
  Future<EvidenceFileDeletionResult> deleteEvidenceIfUnreferenced({
    required String filePath,
    required LocalDraftStore draftStore,
  }) async {
    try {
      final inspection = await _inspectConfinedPath(filePath);
      final canonicalFilePath = inspection.canonicalFilePath;

      if (!inspection.inBounds || inspection.isSymlinkEscape) {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.rejectedOutOfBounds,
          filePath: filePath,
          reason: inspection.errorReason,
        );
      }
      if (inspection.entityType == FileSystemEntityType.notFound) {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.alreadyAbsent,
          filePath: filePath,
        );
      }
      if (inspection.entityType != FileSystemEntityType.file ||
          inspection.resolvedFilePath == null) {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.deletionFailed,
          filePath: filePath,
          reason:
              inspection.errorReason ?? 'Target entity is not a regular file.',
        );
      }

      final resolved = inspection.resolvedFilePath!;

      // 3. Initial reference count check in draftStore
      final initialCount = await draftStore.countDraftReferencesToFile(
        filePath,
      );
      final initialCanonicalCount = canonicalFilePath != filePath
          ? await draftStore.countDraftReferencesToFile(canonicalFilePath)
          : 0;
      final initialResolvedCount =
          (resolved != filePath && resolved != canonicalFilePath)
          ? await draftStore.countDraftReferencesToFile(resolved)
          : 0;
      final totalInitial =
          initialCount + initialCanonicalCount + initialResolvedCount;

      if (totalInitial > 0) {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.preservedReferenced,
          filePath: filePath,
          referenceCount: totalInitial,
          reason:
              'Preserved because $totalInitial active draft reference(s) exist.',
        );
      }

      // 4. Test seam hook (e.g. concurrent reference injection)
      if (onPreUnlink != null) {
        await onPreUnlink!(filePath);
      }

      // 5. Pre-unlink reference re-check: eliminate reference-check-to-unlink race gap
      final preUnlinkCount = await draftStore.countDraftReferencesToFile(
        filePath,
      );
      final preUnlinkCanonicalCount = canonicalFilePath != filePath
          ? await draftStore.countDraftReferencesToFile(canonicalFilePath)
          : 0;
      final preUnlinkResolvedCount =
          (resolved != filePath && resolved != canonicalFilePath)
          ? await draftStore.countDraftReferencesToFile(resolved)
          : 0;
      final totalPreUnlink =
          preUnlinkCount + preUnlinkCanonicalCount + preUnlinkResolvedCount;

      if (totalPreUnlink > 0) {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.preservedReferenced,
          filePath: filePath,
          referenceCount: totalPreUnlink,
          reason:
              'Preserved because $totalPreUnlink draft reference(s) appeared immediately prior to unlink.',
        );
      }

      // 6. Conservative retention enforcement (Phase 6 Slice 4B-0 R26-4-01):
      // In Phase 6 Slice 4B-0, conservative evidence retention is strictly enforced.
      // Physical unlinking is completely removed/disabled to eliminate cross-connection
      // reference-check-to-unlink gaps without risking destruction of unverified evidence.
      // Physical garbage collection is explicitly deferred pending an approved design.
      return EvidenceFileDeletionResult(
        status: EvidenceFileDeletionStatus.preservedConservative,
        filePath: filePath,
        reason: 'Preserved under Phase 6 Slice 4B-0 conservative evidence retention policy (physical garbage collection is deferred).',
      );
    } catch (e) {
      // Conservative retention: fail closed on any unexpected exception
      return EvidenceFileDeletionResult(
        status: EvidenceFileDeletionStatus.deletionFailed,
        filePath: filePath,
        reason: 'Unexpected error in deleteEvidenceIfUnreferenced: $e',
      );
    }
  }
}
