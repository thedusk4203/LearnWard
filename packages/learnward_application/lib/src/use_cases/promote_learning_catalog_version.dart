import '../ports/learning_repository.dart';

/// Platform administration use case to promote a draft catalog version to active.
final class PromoteLearningCatalogVersion {
  const PromoteLearningCatalogVersion(this._repository);

  final LearningRepository _repository;

  Future<String> call(String targetVersion) {
    return _repository.promoteLearningCatalogVersion(targetVersion);
  }
}
