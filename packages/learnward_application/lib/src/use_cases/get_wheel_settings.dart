import 'package:learnward_domain/learnward_domain.dart';

import '../ports/wheel_repository.dart';

/// Retrieves parental Celebration Wheel settings for a given family.
final class GetWheelSettings {
  const GetWheelSettings(this._repository);

  final WheelRepository _repository;

  Future<WheelSettings> call({required FamilyId familyId}) {
    return _repository.getWheelSettings(familyId: familyId);
  }
}
