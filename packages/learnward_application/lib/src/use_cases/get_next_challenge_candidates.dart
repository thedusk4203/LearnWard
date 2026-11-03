import 'package:learnward_domain/learnward_domain.dart';

import '../ports/learning_repository.dart';

/// Retrieves up to [limit] (1..3) deterministic Next Challenge candidates for a child.
final class GetNextChallengeCandidates {
  const GetNextChallengeCandidates(this._repository);

  final LearningRepository _repository;

  Future<NextChallengeRecommendationSet> call({
    required ChildId childId,
    SubjectKey? subjectKey,
    int limit = 3,
  }) {
    if (limit < 1 || limit > 3) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Candidate limit must be between 1 and 3',
      );
    }
    return _repository.getNextChallengeCandidates(
      childId: childId,
      subjectKey: subjectKey,
      limit: limit,
    );
  }
}

typedef GetNextChallengeCandidatesUseCase = GetNextChallengeCandidates;
