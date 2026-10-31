import 'package:learnward_domain/learnward_domain.dart';

import '../ports/child_profile_repository.dart';

/// Archives a child profile.
final class ArchiveChildProfile {
  const ArchiveChildProfile(this._repository);

  final ChildProfileRepository _repository;

  Future<void> call({required FamilyId familyId, required ChildId childId}) {
    return _repository.archiveChildProfile(
      familyId: familyId,
      childId: childId,
    );
  }
}
