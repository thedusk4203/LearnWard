import 'package:learnward_domain/learnward_domain.dart';

import '../ports/child_profile_repository.dart';

/// Lists child profiles for a specific family.
final class ListFamilyChildren {
  const ListFamilyChildren(this._repository);

  final ChildProfileRepository _repository;

  Future<List<ChildProfile>> call(FamilyId familyId) {
    return _repository.listChildren(familyId);
  }
}
