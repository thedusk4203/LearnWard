import '../ports/learning_repository.dart';

/// Idempotently processes a verified learning event to update child mastery projections.
final class ProcessLearningEvent {
  const ProcessLearningEvent(this._repository);

  final LearningRepository _repository;

  Future<Map<String, dynamic>> call({
    required String commandId,
    required String verifiedLearningEventId,
  }) {
    return _repository.processLearningEvent(
      commandId: commandId,
      verifiedLearningEventId: verifiedLearningEventId,
    );
  }
}
