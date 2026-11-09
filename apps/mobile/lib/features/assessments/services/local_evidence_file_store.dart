import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Status of an unreferenced evidence file deletion attempt.
enum EvidenceFileDeletionStatus {
  /// File was safely deleted from durable storage.
  deleted,

  /// File was already absent from storage (idempotent success).
  alreadyAbsent,

  /// File was preserved because one or more drafts still reference it.
  preservedReferenced,

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
      status == EvidenceFileDeletionStatus.preservedReferenced;
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
abstract interface class LocalEvidenceFileStore {
  Future<String> saveDurableEvidence({
    required String localDraftId,
    required List<int> bytes,
    required String mediaType,
  });

  Future<String> saveEvidence({
    required String fileName,
    required List<int> bytes,
  });

  Future<List<int>?> readEvidenceBytes(String filePath);

  Future<List<int>?> loadEvidence(String filePath);

  Future<void> deleteDurableEvidence(String filePath);

  Future<void> deleteEvidence(String filePath);

  /// Deletes [filePath] physically from storage only if no local draft
  /// in [draftStore] references it (neither as localPhotoPath nor localCompressedPhotoPath).
  ///
  /// Returns a typed [EvidenceFileDeletionResult] detailing the outcome.
  /// Fails closed and conservatively retains files on any error, ambiguity, or boundary violation.
  Future<EvidenceFileDeletionResult> deleteEvidenceIfUnreferenced({
    required String filePath,
    required LocalDraftStore draftStore,
  });
}

final class DefaultLocalEvidenceFileStore implements LocalEvidenceFileStore {
  DefaultLocalEvidenceFileStore({Directory? baseDirectory, this.onPreUnlink})
    : _customBaseDir = baseDirectory;

  final Directory? _customBaseDir;

  /// Optional test seam invoked immediately before physical file unlink.
  final Future<void> Function(String filePath)? onPreUnlink;

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
    final dir = await _getEvidenceDirectory();
    final ext = mediaType == 'image/png' ? 'png' : 'jpg';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/${localDraftId}_$timestamp.$ext');
    file.writeAsBytesSync(bytes, flush: true);
    return file.path;
  }

  @override
  Future<String> saveEvidence({
    required String fileName,
    required List<int> bytes,
  }) async {
    final dir = await _getEvidenceDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/${timestamp}_$fileName');
    file.writeAsBytesSync(bytes, flush: true);
    return file.path;
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
    try {
      final Directory evidenceDir = await _getEvidenceDirectory();
      final canonicalEvidenceDir = p.canonicalize(evidenceDir.path);
      final resolvedEvidenceDir = evidenceDir.existsSync()
          ? p.canonicalize(evidenceDir.resolveSymbolicLinksSync())
          : canonicalEvidenceDir;
      final canonicalFilePath = p.canonicalize(filePath);

      if (!p.isWithin(canonicalEvidenceDir, canonicalFilePath) &&
          !p.isWithin(resolvedEvidenceDir, canonicalFilePath)) {
        return;
      }
      final file = File(canonicalFilePath);
      if (file.existsSync()) {
        final resolved = p.canonicalize(file.resolveSymbolicLinksSync());
        if (p.isWithin(resolvedEvidenceDir, resolved) ||
            p.isWithin(canonicalEvidenceDir, resolved)) {
          file.deleteSync();
        }
      }
    } catch (_) {
      // Ignore if already deleted
    }
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

      // 6. Physical unlink
      try {
        file.deleteSync();
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.deleted,
          filePath: filePath,
        );
      } on PathNotFoundException {
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.alreadyAbsent,
          filePath: filePath,
        );
      } on FileSystemException catch (e) {
        if (!file.existsSync()) {
          return EvidenceFileDeletionResult(
            status: EvidenceFileDeletionStatus.alreadyAbsent,
            filePath: filePath,
          );
        }
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.deletionFailed,
          filePath: filePath,
          reason: 'Filesystem deleteSync failed: $e',
        );
      } catch (e) {
        if (!file.existsSync()) {
          return EvidenceFileDeletionResult(
            status: EvidenceFileDeletionStatus.alreadyAbsent,
            filePath: filePath,
          );
        }
        return EvidenceFileDeletionResult(
          status: EvidenceFileDeletionStatus.deletionFailed,
          filePath: filePath,
          reason: 'Filesystem deleteSync failed: $e',
        );
      }
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
