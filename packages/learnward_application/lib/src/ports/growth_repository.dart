import 'package:learnward_domain/learnward_domain.dart';

/// Port for managing server-authoritative Growth Engine calculation and economic balance reads.
abstract interface class GrowthRepository {
  /// Invokes server-authoritative Growth Engine calculation on a target [VerifiedLearningEvent].
  ///
  /// Guaranteed to be idempotent and append to XP/RP ledgers exactly once.
  Future<GrowthEvent> processVerifiedLearningEvent({
    required String verifiedLearningEventId,
    String? commandId,
  });

  /// Retrieves the current projected balance (XP progression and spendable RP) for a child.
  Future<ChildBalance?> getChildBalance(ChildId childId);

  /// Retrieves the latest GrowthEvent for a child, or null if no events exist.
  Future<GrowthEvent?> getLatestGrowthEvent(ChildId childId);

  /// Lists all chronological GrowthEvents for a child (most recent first).
  Future<List<GrowthEvent>> listGrowthEvents(ChildId childId);

  /// Retrieves the GrowthEvent corresponding to a given assessment, or null if uncalculated.
  Future<GrowthEvent?> getGrowthEventByAssessmentId(AssessmentId assessmentId);
}
