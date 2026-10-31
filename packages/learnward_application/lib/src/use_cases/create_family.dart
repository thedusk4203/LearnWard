import 'package:learnward_domain/learnward_domain.dart';

import '../ports/family_repository.dart';

/// Orchestrates atomic family creation.
final class CreateFamily {
  const CreateFamily(this._repository);

  final FamilyRepository _repository;

  Future<Family> call({
    required String name,
    required String timezone,
    required String locale,
  }) {
    return _repository.createFamily(
      name: name,
      timezone: timezone,
      locale: locale,
    );
  }
}
