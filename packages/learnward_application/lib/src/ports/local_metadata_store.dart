/// Atomic metadata mutation descriptor for [LocalMetadataStore] batches.
final class MetadataMutation {
  const MetadataMutation._({
    required this.key,
    required this.value,
    required this.updatedAt,
  });

  /// Inserts or replaces [key] with [value].
  const MetadataMutation.upsert({
    required String key,
    required String value,
    required DateTime updatedAt,
  }) : this._(key: key, value: value, updatedAt: updatedAt);

  /// Deletes [key] if present.
  const MetadataMutation.delete({required String key})
    : this._(key: key, value: null, updatedAt: null);

  final String key;
  final String? value;
  final DateTime? updatedAt;

  /// Whether this mutation deletes [key].
  bool get isDelete => value == null;
}

/// Port for reading and writing technical metadata key-value pairs locally.
abstract interface class LocalMetadataStore {
  /// Reads a metadata value by key, or returns `null` if not found.
  Future<String?> readMetadata(String key);

  /// Writes a metadata entry, replacing any existing value.
  Future<void> writeMetadata({
    required String key,
    required String value,
    required DateTime updatedAt,
  });

  /// Atomically applies all [mutations] in a single transaction.
  Future<void> applyMetadataBatch(List<MetadataMutation> mutations);

  /// Atomically checks [expectedValues] (where `null` requires absence) and,
  /// if [preCommitGuard] still returns `true`, applies [mutations].
  ///
  /// Returns `true` when committed, or `false` when rolled back due to CAS
  /// mismatch or a `false` [preCommitGuard].
  ///
  /// [onBeforePreCommitGuard] and [onAfterGuardBeforeCommit] are deterministic
  /// test hooks modeling async windows immediately before [preCommitGuard] and
  /// between [preCommitGuard] and durable commit.
  Future<bool> compareAndSwapMetadataBatch({
    required Map<String, String?> expectedValues,
    required List<MetadataMutation> mutations,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  });
}
