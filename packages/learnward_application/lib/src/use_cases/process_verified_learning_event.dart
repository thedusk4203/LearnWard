import 'package:learnward_domain/learnward_domain.dart';

import '../ports/growth_repository.dart';

/// Use case to process a VerifiedLearningEvent into deterministic Growth, RP, and XP awards.
final class ProcessVerifiedLearningEvent {
  const ProcessVerifiedLearningEvent(this._repository);

  final GrowthRepository _repository;

  Future<GrowthEvent> call({
    required String verifiedLearningEventId,
    String? commandId,
  }) {
    return _repository.processVerifiedLearningEvent(
      verifiedLearningEventId: verifiedLearningEventId,
      commandId: commandId,
    );
  }
}
