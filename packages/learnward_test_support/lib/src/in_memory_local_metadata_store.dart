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
}
