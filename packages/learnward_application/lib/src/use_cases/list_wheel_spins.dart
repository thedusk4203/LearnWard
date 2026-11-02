import 'package:learnward_domain/learnward_domain.dart';

import '../ports/wheel_repository.dart';

/// Lists past wheel spins for a child or family.
final class ListWheelSpins {
  const ListWheelSpins(this._repository);

  final WheelRepository _repository;

  Future<List<WheelSpin>> call({
    required FamilyId familyId,
    ChildId? childId,
    int? limit,
  }) {
    return _repository.listWheelSpins(
      familyId: familyId,
      childId: childId,
      limit: limit,
    );
  }
}
