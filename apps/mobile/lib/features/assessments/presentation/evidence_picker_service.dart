import 'package:image_picker/image_picker.dart';

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

/// Production implementation using official `image_picker` plugin for Android and iOS.
final class NativeEvidencePickerService implements EvidencePickerService {
  NativeEvidencePickerService([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<SelectedEvidenceFile?> pickEvidencePhoto() async {
    final xFile = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 2400,
      maxHeight: 2400,
      imageQuality: 85,
    );
    if (xFile == null) return null;

    final bytes = await xFile.readAsBytes();
    final lowerName = xFile.name.toLowerCase();
    final mediaType = lowerName.endsWith('.png') ? 'image/png' : 'image/jpeg';

    return SelectedEvidenceFile(
      fileName: xFile.name,
      bytes: bytes,
      mediaType: mediaType,
      localPath: xFile.path,
    );
  }
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
