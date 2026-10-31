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
}
