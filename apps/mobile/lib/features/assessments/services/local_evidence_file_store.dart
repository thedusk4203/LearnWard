import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../shared/utils/uuid_generator.dart';

/// Exception thrown when evidence file storage operations fail safely
/// without risking data loss, collision, or uncoordinated file destruction.
final class EvidenceStorageException implements Exception {
  const EvidenceStorageException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'EvidenceStorageException: $message';
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
}

final class DefaultLocalEvidenceFileStore implements LocalEvidenceFileStore {
  DefaultLocalEvidenceFileStore({
    Directory? baseDirectory,
    this.onPreUnlink,
    String Function()? suffixGenerator,
    DateTime Function()? clock,
  }) : _customBaseDir = baseDirectory,
       _suffixGenerator = suffixGenerator ?? generateUuid,
       _clock = clock ?? DateTime.now;

  final Directory? _customBaseDir;

  /// Optional test seam invoked during reference checks.
  final Future<void> Function(String filePath)? onPreUnlink;

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

  @override
  Future<String> saveDurableEvidence({
    required String localDraftId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    if (localDraftId.isEmpty ||
        !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(localDraftId)) {
      throw EvidenceStorageException(
        'Invalid localDraftId "$localDraftId": must contain only alphanumeric characters, dashes, and underscores.',
      );
    }

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
      final Directory evidenceDir = await _getEvidenceDirectory();
      final canonicalEvidenceDir = p.canonicalize(evidenceDir.path);
      final resolvedEvidenceDir = evidenceDir.existsSync()
          ? p.canonicalize(evidenceDir.resolveSymbolicLinksSync())
          : canonicalEvidenceDir;
      final canonicalFilePath = p.canonicalize(filePath);

      // 1. Boundary check: ensure target path is strictly within canonical evidence directory
      if (!p.isWithin(canonicalEvidenceDir, canonicalFilePath) &&
          !p.isWithin(resolvedEvidenceDir, canonicalFilePath)) {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.rejectedOutOfBounds,
          filePath: filePath,
          reason:
              'Target path "$canonicalFilePath" is outside evidence directory "$canonicalEvidenceDir".',
        );
      }

      final entityType = FileSystemEntity.typeSync(canonicalFilePath);
      if (entityType == FileSystemEntityType.notFound) {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.alreadyAbsent,
          filePath: filePath,
        );
      }
      if (entityType != FileSystemEntityType.file) {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.deletionFailed,
          filePath: filePath,
          reason: 'Target entity is not a regular file.',
        );
      }

      final file = File(canonicalFilePath);

      // 2. Symlink escape check
      String resolved;
      try {
        resolved = p.canonicalize(file.resolveSymbolicLinksSync());
        if (!p.isWithin(resolvedEvidenceDir, resolved) &&
            !p.isWithin(canonicalEvidenceDir, resolved)) {
          return EvidenceFileDeletionResult(
            status: EvidenceFileDeletionStatus.rejectedOutOfBounds,
            filePath: filePath,
            reason:
                'Target symlink resolves to "$resolved" outside evidence directory "$resolvedEvidenceDir".',
          );
        }
      } catch (e) {
        // If symlink resolution fails, conservatively reject deletion
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.rejectedOutOfBounds,
          filePath: filePath,
          reason: 'Failed to resolve symbolic links safely: $e',
        );
      }

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
