import 'package:learnward_domain/learnward_domain.dart';

import '../ports/wheel_repository.dart';

/// Lists active eligible Wheel rewards for a child within a family.
final class ListWheelRewards {
  const ListWheelRewards(this._repository);

  final WheelRepository _repository;

  Future<List<Reward>> call({required FamilyId familyId, ChildId? childId}) {
    return _repository.listWheelRewards(familyId: familyId, childId: childId);
  }
}
