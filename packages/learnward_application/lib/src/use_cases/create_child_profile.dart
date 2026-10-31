import 'package:learnward_domain/learnward_domain.dart';

import '../ports/child_profile_repository.dart';

/// Orchestrates child profile creation within an authorized family.
final class CreateChildProfile {
  const CreateChildProfile(this._repository);

  final ChildProfileRepository _repository;

  Future<ChildProfile> call({
    required FamilyId familyId,
    required String displayName,
    int? schoolGrade,
    int? birthYear,
    String? avatarKey,
  }) {
    return _repository.createChildProfile(
      familyId: familyId,
      displayName: displayName,
      schoolGrade: schoolGrade,
      birthYear: birthYear,
      avatarKey: avatarKey,
    );
  }
}
