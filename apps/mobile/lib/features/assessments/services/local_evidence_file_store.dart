import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:path_provider/path_provider.dart';

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
  /// Returns `true` if the file was safely deleted, or `false` if it was preserved
  /// because other references still exist or the reference check failed.
  Future<bool> deleteEvidenceIfUnreferenced({
    required String filePath,
    required LocalDraftStore draftStore,
  });
}

final class DefaultLocalEvidenceFileStore implements LocalEvidenceFileStore {
  DefaultLocalEvidenceFileStore({Directory? baseDirectory})
    : _customBaseDir = baseDirectory;

  final Directory? _customBaseDir;

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
      final file = File(filePath);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {
      // Ignore if already deleted
    }
  }

  @override
  Future<void> deleteEvidence(String filePath) =>
      deleteDurableEvidence(filePath);

  @override
  Future<bool> deleteEvidenceIfUnreferenced({
    required String filePath,
    required LocalDraftStore draftStore,
  }) async {
    try {
      final hasRef = await draftStore.hasDraftReferenceToFile(filePath);
      if (hasRef) {
        return false;
      }
      await deleteEvidence(filePath);
      return true;
    } catch (_) {
      return false;
    }
  }
}
