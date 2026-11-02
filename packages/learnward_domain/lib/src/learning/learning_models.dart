import '../value_objects/identifiers.dart';
import 'learning_enums.dart';

/// Reference learning node in the hierarchical curriculum tree.
final class LearningNode {
  const LearningNode({
    required this.id,
    required this.catalogVersion,
    required this.nodeType,
    required this.subjectKey,
    required this.canonicalKey,
    required this.title,
    this.description,
    this.parentId,
    this.gradeMin,
    this.gradeMax,
    this.sortOrder = 0,
    this.isActive = true,
  });

  final LearningNodeId id;
  final String catalogVersion;
  final LearningNodeType nodeType;
  final String subjectKey;
  final String canonicalKey;
  final String title;
  final String? description;
  final LearningNodeId? parentId;
  final int? gradeMin;
  final int? gradeMax;
  final int sortOrder;
  final bool isActive;
}

/// Directed prerequisite edge between skills in the same catalog and subject.
final class LearningPrerequisite {
  const LearningPrerequisite({
    required this.catalogVersion,
    required this.subjectKey,
    required this.prerequisiteNodeId,
    required this.dependentNodeId,
  });

  final String catalogVersion;
  final String subjectKey;
  final LearningNodeId prerequisiteNodeId;
  final LearningNodeId dependentNodeId;
}

/// Mapping from an assessment or its component to a reference learning node.
final class AssessmentLearningMapping {
  const AssessmentLearningMapping({
    this.id,
    required this.familyId,
    required this.assessmentId,
    required this.learningNodeId,
    required this.scoreSource,
    this.componentKey,
    this.rawScore,
    this.maxScore,
    this.itemCount,
    this.correctCount,
  });

  final String? id;
  final FamilyId familyId;
  final AssessmentId assessmentId;
  final LearningNodeId learningNodeId;
  final ScoreSource scoreSource;
  final String? componentKey;
  final double? rawScore;
  final double? maxScore;
  final int? itemCount;
  final int? correctCount;

  Map<String, dynamic> toJson() => {
    'learning_node_id': learningNodeId.value,
    'score_source': scoreSource.value,
    if (componentKey != null) 'component_key': componentKey,
    if (rawScore != null) 'raw_score': rawScore,
    if (maxScore != null) 'max_score': maxScore,
    if (itemCount != null) 'item_count': itemCount,
    if (correctCount != null) 'correct_count': correctCount,
  };
}

/// Normalized evidence atom produced by processing a verified learning event.
final class LearningEvidenceEvent {
  const LearningEvidenceEvent({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.verifiedLearningEventId,
    required this.learningNodeId,
    required this.nodeType,
    required this.subjectKey,
    required this.scoreSource,
    this.componentKey,
    this.rawScore,
    this.maxScore,
    this.itemCount,
    this.correctCount,
    required this.performancePct,
    required this.specificityWeight,
    required this.levelWeight,
    required this.effectiveOccurredAt,
    required this.verifiedAt,
    this.gradeLevelSnapshot,
  });

  final String id;
  final FamilyId familyId;
  final ChildId childId;
  final String verifiedLearningEventId;
  final LearningNodeId learningNodeId;
  final LearningNodeType nodeType;
  final String subjectKey;
  final ScoreSource scoreSource;
  final String? componentKey;
  final double? rawScore;
  final double? maxScore;
  final int? itemCount;
  final int? correctCount;
  final double performancePct;
  final double specificityWeight;
  final double levelWeight;
  final DateTime effectiveOccurredAt;
  final DateTime verifiedAt;
  final int? gradeLevelSnapshot;
}

/// Immutable audit record of a mastery state recalculation.
final class MasteryStateRevision {
  const MasteryStateRevision({
    required this.id,
    required this.familyId,
    required this.childId,
    required this.learningNodeId,
    required this.triggerVerifiedLearningEventId,
    required this.engineVersion,
    this.previousMasteryScore,
    required this.newMasteryScore,
    required this.effectiveEvidenceCount,
    required this.latestEvidenceAt,
    required this.calculationSnapshot,
    required this.createdAt,
  });

  final String id;
  final FamilyId familyId;
  final ChildId childId;
  final LearningNodeId learningNodeId;
  final String triggerVerifiedLearningEventId;
  final String engineVersion;
  final double? previousMasteryScore;
  final double newMasteryScore;
  final int effectiveEvidenceCount;
  final DateTime latestEvidenceAt;
  final Map<String, dynamic> calculationSnapshot;
  final DateTime createdAt;
}

/// Materialized projection of current mastery for a child and learning node.
final class ChildMasteryState {
  const ChildMasteryState({
    required this.familyId,
    required this.childId,
    required this.learningNodeId,
    required this.engineVersion,
    required this.masteryScore,
    required this.effectiveEvidenceCount,
    required this.distinctAssessmentCount,
    required this.lastEvidenceEventId,
    required this.lastEvidenceOccurredAt,
    required this.updatedAt,
  });

  final FamilyId familyId;
  final ChildId childId;
  final LearningNodeId learningNodeId;
  final String engineVersion;
  final double masteryScore;
  final int effectiveEvidenceCount;
  final int distinctAssessmentCount;
  final String lastEvidenceEventId;
  final DateTime lastEvidenceOccurredAt;
  final DateTime updatedAt;
}

/// Read model presentation of child mastery and confidence.
final class ChildMasteryProjection {
  const ChildMasteryProjection({
    required this.childId,
    required this.learningNodeId,
    required this.nodeCanonicalKey,
    required this.nodeTitle,
    required this.nodeType,
    required this.subjectKey,
    required this.masteryScore,
    required this.distinctAssessmentCount,
    required this.lastEvidenceOccurredAt,
    required this.confidenceBand,
    required this.confidenceUnits,
    required this.masteryBand,
    required this.updatedAt,
  });

  final ChildId childId;
  final LearningNodeId learningNodeId;
  final String nodeCanonicalKey;
  final String nodeTitle;
  final LearningNodeType nodeType;
  final String subjectKey;
  final double masteryScore;
  final int distinctAssessmentCount;
  final DateTime lastEvidenceOccurredAt;
  final ConfidenceBand confidenceBand;
  final double confidenceUnits;
  final MasteryBand masteryBand;
  final DateTime updatedAt;

  factory ChildMasteryProjection.fromJson(Map<String, dynamic> json) {
    return ChildMasteryProjection(
      childId: ChildId((json['child_id'] ?? '') as String),
      learningNodeId: LearningNodeId(json['learning_node_id'] as String),
      nodeCanonicalKey:
          (json['node_canonical_key'] ?? json['canonical_key']) as String,
      nodeTitle: (json['node_title'] ?? json['title']) as String,
      nodeType: LearningNodeType.fromValue(json['node_type'] as String),
      subjectKey: json['subject_key'] as String,
      masteryScore: (json['mastery_score'] as num).toDouble(),
      distinctAssessmentCount: (json['distinct_assessment_count'] as num)
          .toInt(),
      lastEvidenceOccurredAt: DateTime.parse(
        json['last_evidence_occurred_at'] as String,
      ),
      confidenceBand: ConfidenceBand.fromValue(
        json['confidence_band'] as String,
      ),
      confidenceUnits: (json['confidence_units'] as num).toDouble(),
      masteryBand: MasteryBand.fromValue(json['mastery_band'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}
