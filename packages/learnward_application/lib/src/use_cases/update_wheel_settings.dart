import 'package:learnward_domain/learnward_domain.dart';

import '../ports/wheel_repository.dart';

/// Updates parental Celebration Wheel settings for a given family.
final class UpdateWheelSettings {
  const UpdateWheelSettings(this._repository);

  final WheelRepository _repository;

  Future<WheelSettings> call(WheelSettings settings) {
    return _repository.updateWheelSettings(settings);
  }
}
