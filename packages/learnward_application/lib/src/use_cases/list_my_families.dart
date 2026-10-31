import 'package:learnward_domain/learnward_domain.dart';

import '../ports/family_repository.dart';

/// Lists families for the currently authenticated adult.
final class ListMyFamilies {
  const ListMyFamilies(this._repository);

  final FamilyRepository _repository;

  Future<List<Family>> call() => _repository.listMyFamilies();
}
