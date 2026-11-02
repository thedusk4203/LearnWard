import 'package:learnward_domain/learnward_domain.dart';

/// Repository interface for learning nodes, assessment mappings, and mastery states.
abstract interface class LearningRepository {
  /// Fetches reference nodes for a catalog version, optionally filtered by subject.
  Future<List<LearningNode>> getCatalogNodes({
    required String catalogVersion,
    String? subjectKey,
  });

  /// Retrieves mapped learning nodes for an assessment.
  Future<List<AssessmentLearningMapping>> getAssessmentLearningMappings(
    AssessmentId assessmentId,
  );

  /// Replaces or sets learning mappings on a pending_review assessment.
  Future<List<AssessmentLearningMapping>> setAssessmentLearningMappings({
    required AssessmentId assessmentId,
    required List<AssessmentLearningMapping> mappings,
  });

  /// Idempotently processes a verified learning event for mastery.
  Future<Map<String, dynamic>> processLearningEvent({
    required String commandId,
    required String verifiedLearningEventId,
  });

  /// Runs bulk catch-up processing for any unprocessed verified learning events in a family.
  Future<Map<String, dynamic>> catchUpUnprocessedLearning(FamilyId familyId);

  /// Retrieves current mastery and confidence projections for a child.
  Future<List<ChildMasteryProjection>> getChildMastery({
    required ChildId childId,
    DateTime? asOf,
  });

  /// Promotes a draft catalog to active (platform administration).
  Future<String> promoteLearningCatalogVersion(String targetVersion);
}
