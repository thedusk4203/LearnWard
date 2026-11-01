/// Encapsulates a user-selected evidence file for an assessment.
final class SelectedEvidenceFile {
  const SelectedEvidenceFile({
    required this.fileName,
    required this.bytes,
    required this.mediaType,
    this.localPath,
  });

  final String fileName;
  final List<int> bytes;
  final String mediaType;
  final String? localPath;
}

/// Abstract service port for picking photo evidence.
abstract interface class EvidencePickerService {
  Future<SelectedEvidenceFile?> pickEvidencePhoto();
}

/// In-memory/test-friendly implementation for environments without native cameras.
final class SimulatedEvidencePickerService implements EvidencePickerService {
  SimulatedEvidencePickerService({this.stubFile});

  final SelectedEvidenceFile? stubFile;

  @override
  Future<SelectedEvidenceFile?> pickEvidencePhoto() async {
    return stubFile ??
        SelectedEvidenceFile(
          fileName: 'evidence_mock.jpg',
          bytes: List<int>.generate(1024, (i) => (i * 37) % 256),
          mediaType: 'image/jpeg',
          localPath: '/tmp/evidence_mock.jpg',
        );
  }
}
