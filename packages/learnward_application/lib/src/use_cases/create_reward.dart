import 'package:learnward_domain/learnward_domain.dart';

import '../ports/reward_repository.dart';

final class CreateReward {
  const CreateReward(this._repository);

  final RewardRepository _repository;

  Future<Reward> call({
    required FamilyId familyId,
    required String title,
    String? description,
    required RewardCategory category,
    String iconKey = 'default_star',
    bool storeEnabled = true,
    int? storeCostMinor,
    bool wheelEnabled = false,
    WheelTier? wheelTier,
    ChildId? targetChildId,
  }) {
    return _repository.createReward(
      familyId: familyId,
      title: title,
      description: description,
      category: category,
      iconKey: iconKey,
      storeEnabled: storeEnabled,
      storeCostMinor: storeCostMinor,
      wheelEnabled: wheelEnabled,
      wheelTier: wheelTier,
      targetChildId: targetChildId,
    );
  }
}
