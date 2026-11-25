import 'package:learnward_application/learnward_application.dart';

/// In-memory implementation of [LocalMetadataStore] for deterministic headless unit tests.
final class InMemoryLocalMetadataStore implements LocalMetadataStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> readMetadata(String key) async {
    return _data[key];
  }

  @override
  Future<void> writeMetadata({
    required String key,
    required String value,
    required DateTime updatedAt,
  }) async {
    _data[key] = value;
  }

  @override
  Future<void> applyMetadataBatch(List<MetadataMutation> mutations) async {
    for (final mutation in mutations) {
      if (mutation.isDelete) {
        _data.remove(mutation.key);
      } else {
        _data[mutation.key] = mutation.value!;
      }
    }
  }

  @override
  Future<bool> compareAndSwapMetadataBatch({
    required Map<String, String?> expectedValues,
    required List<MetadataMutation> mutations,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) async {
    if (!_matchesExpected(expectedValues)) {
      return false;
    }
    if (onBeforePreCommitGuard != null) {
      await onBeforePreCommitGuard();
    }
    if (preCommitGuard != null && !preCommitGuard()) {
      return false;
    }
    if (!_matchesExpected(expectedValues)) {
      return false;
    }
    if (onAfterGuardBeforeCommit != null) {
      await onAfterGuardBeforeCommit();
    }
    if (!_matchesExpected(expectedValues)) {
      return false;
    }
    for (final mutation in mutations) {
      if (mutation.isDelete) {
        _data.remove(mutation.key);
      } else {
        _data[mutation.key] = mutation.value!;
      }
    }
    return true;
  }

  bool _matchesExpected(Map<String, String?> expectedValues) {
    for (final entry in expectedValues.entries) {
      if (_data[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }
}
