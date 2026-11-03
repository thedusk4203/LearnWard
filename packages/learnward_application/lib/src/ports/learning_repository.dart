import 'package:learnward_domain/learnward_domain.dart';

/// Repository interface for learning nodes, assessment mappings, mastery states,
/// and Phase 5.2 skill-graph recommendation read models.
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
  });

  /// Retrieves the Phase 5.2 child learning overview across all active subjects,
  /// topics, skills, coverage counts, freshness, and recovery signals.
  Future<LearningOverview> getChildLearningOverview({required ChildId childId});

  /// Retrieves the Phase 5.2 detailed learning state for a single active-catalog node,
  /// including mastery, confidence, freshness, recovery, prerequisites, and dependents.
  Future<LearningNodeState> getNodeLearningState({
    required ChildId childId,
    required String learningNodeId,
  });

  /// Retrieves up to [limit] (1..3) deterministic Next Challenge candidates for a child.
  Future<NextChallengeRecommendationSet> getNextChallengeCandidates({
    required ChildId childId,
    SubjectKey? subjectKey,
    int limit = 3,
  });
}
