import 'dart:io';

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
}

final class DefaultLocalEvidenceFileStore implements LocalEvidenceFileStore {
  DefaultLocalEvidenceFileStore({Directory? baseDirectory})
    : _customBaseDir = baseDirectory;

  final Directory? _customBaseDir;

  Future<Directory> _getEvidenceDirectory() async {
    final Directory base =
        _customBaseDir ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/draft_evidence');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
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
    await file.writeAsBytes(bytes, flush: true);
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
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<List<int>?> readEvidenceBytes(String filePath) async {
    final file = File(filePath);
    if (await file.exists()) {
      return file.readAsBytes();
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
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore if already deleted
    }
  }

  @override
  Future<void> deleteEvidence(String filePath) =>
      deleteDurableEvidence(filePath);
}
