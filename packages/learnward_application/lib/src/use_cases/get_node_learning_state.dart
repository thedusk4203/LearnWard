import 'package:learnward_domain/learnward_domain.dart';

import '../ports/learning_repository.dart';

/// Retrieves the Phase 5.2 detailed learning state for a single active-catalog node.
final class GetNodeLearningState {
  const GetNodeLearningState(this._repository);

  final LearningRepository _repository;

  Future<LearningNodeState> call({
    required ChildId childId,
    required String learningNodeId,
  }) {
    final trimmed = learningNodeId.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        learningNodeId,
        'learningNodeId',
        'Learning node ID is required',
      );
    }
    return _repository.getNodeLearningState(
      childId: childId,
      learningNodeId: trimmed,
    );
  }
}

typedef GetNodeLearningStateUseCase = GetNodeLearningState;
