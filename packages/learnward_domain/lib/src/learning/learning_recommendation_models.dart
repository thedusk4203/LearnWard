import '../value_objects/identifiers.dart';
import 'learning_enums.dart';

/// Result of evaluating Freshness relative to server-authoritative `asOf`.
final class FreshnessEvaluation {
  const FreshnessEvaluation({
    required this.freshness,
    required this.daysSinceLastEvidence,
  });

  final MasteryFreshness freshness;
  final int? daysSinceLastEvidence;
}

/// Result of evaluating Recovery replay and 30-day recency relative to `asOf`.
final class RecoveryEvaluation {
  const RecoveryEvaluation({
    required this.signal,
    required this.latestUnresolvedWeaknessAt,
  });

  final RecoverySignal signal;
  final DateTime? latestUnresolvedWeaknessAt;
}

/// Overall coverage summary across the active catalog in `get_child_learning_overview`.
final class LearningOverallCoverage {
  const LearningOverallCoverage({
    required this.totalTopics,
    required this.observedTopics,
    required this.unseenTopics,
    required this.totalSkills,
    required this.observedSkills,
    required this.unseenSkills,
    required this.masteredSkills,
    required this.masteryCandidateSkills,
    required this.secureSkills,
    required this.developingSkills,
    required this.emergingSkills,
    required this.needsRefreshCount,
    required this.activeRecoveryCount,
  });

  final int totalTopics;
  final int observedTopics;
  final int unseenTopics;
  final int totalSkills;
  final int observedSkills;
  final int unseenSkills;
  final int masteredSkills;
  final int masteryCandidateSkills;
  final int secureSkills;
  final int developingSkills;
  final int emergingSkills;
  final int needsRefreshCount;
  final int activeRecoveryCount;

  factory LearningOverallCoverage.fromJson(Map<String, dynamic> json) {
    return LearningOverallCoverage(
      totalTopics: (json['total_topics'] as num).toInt(),
      observedTopics: (json['observed_topics'] as num).toInt(),
      unseenTopics: (json['unseen_topics'] as num).toInt(),
      totalSkills: (json['total_skills'] as num).toInt(),
      observedSkills: (json['observed_skills'] as num).toInt(),
      unseenSkills: (json['unseen_skills'] as num).toInt(),
      masteredSkills: (json['mastered_skills'] as num).toInt(),
      masteryCandidateSkills: (json['mastery_candidate_skills'] as num).toInt(),
      secureSkills: (json['secure_skills'] as num).toInt(),
      developingSkills: (json['developing_skills'] as num).toInt(),
      emergingSkills: (json['emerging_skills'] as num).toInt(),
      needsRefreshCount: (json['needs_refresh_count'] as num).toInt(),
      activeRecoveryCount: (json['active_recovery_count'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'total_topics': totalTopics,
    'observed_topics': observedTopics,
    'unseen_topics': unseenTopics,
    'total_skills': totalSkills,
    'observed_skills': observedSkills,
    'unseen_skills': unseenSkills,
    'mastered_skills': masteredSkills,
    'mastery_candidate_skills': masteryCandidateSkills,
    'secure_skills': secureSkills,
    'developing_skills': developingSkills,
    'emerging_skills': emergingSkills,
    'needs_refresh_count': needsRefreshCount,
    'active_recovery_count': activeRecoveryCount,
  };
}

/// Subject-level descendant coverage summary in `get_child_learning_overview`.
final class LearningSubjectCoverage {
  const LearningSubjectCoverage({
    required this.totalDomains,
    required this.observedDomains,
    required this.unseenDomains,
    required this.totalTopics,
    required this.observedTopics,
    required this.unseenTopics,
    required this.totalSkills,
    required this.observedSkills,
    required this.unseenSkills,
    required this.masteredSkills,
    required this.masteryCandidateSkills,
    required this.secureSkills,
    required this.developingSkills,
    required this.emergingSkills,
    required this.needsRefreshCount,
    required this.activeRecoveryCount,
  });

  final int totalDomains;
  final int observedDomains;
  final int unseenDomains;
  final int totalTopics;
  final int observedTopics;
  final int unseenTopics;
  final int totalSkills;
  final int observedSkills;
  final int unseenSkills;
  final int masteredSkills;
  final int masteryCandidateSkills;
  final int secureSkills;
  final int developingSkills;
  final int emergingSkills;
  final int needsRefreshCount;
  final int activeRecoveryCount;

  factory LearningSubjectCoverage.fromJson(Map<String, dynamic> json) {
    return LearningSubjectCoverage(
      totalDomains: (json['total_domains'] as num).toInt(),
      observedDomains: (json['observed_domains'] as num).toInt(),
      unseenDomains: (json['unseen_domains'] as num).toInt(),
      totalTopics: (json['total_topics'] as num).toInt(),
      observedTopics: (json['observed_topics'] as num).toInt(),
      unseenTopics: (json['unseen_topics'] as num).toInt(),
      totalSkills: (json['total_skills'] as num).toInt(),
      observedSkills: (json['observed_skills'] as num).toInt(),
      unseenSkills: (json['unseen_skills'] as num).toInt(),
      masteredSkills: (json['mastered_skills'] as num).toInt(),
      masteryCandidateSkills: (json['mastery_candidate_skills'] as num).toInt(),
      secureSkills: (json['secure_skills'] as num).toInt(),
      developingSkills: (json['developing_skills'] as num).toInt(),
      emergingSkills: (json['emerging_skills'] as num).toInt(),
      needsRefreshCount: (json['needs_refresh_count'] as num).toInt(),
      activeRecoveryCount: (json['active_recovery_count'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'total_domains': totalDomains,
    'observed_domains': observedDomains,
    'unseen_domains': unseenDomains,
    'total_topics': totalTopics,
    'observed_topics': observedTopics,
    'unseen_topics': unseenTopics,
    'total_skills': totalSkills,
    'observed_skills': observedSkills,
    'unseen_skills': unseenSkills,
    'mastered_skills': masteredSkills,
    'mastery_candidate_skills': masteryCandidateSkills,
    'secure_skills': secureSkills,
    'developing_skills': developingSkills,
    'emerging_skills': emergingSkills,
    'needs_refresh_count': needsRefreshCount,
    'active_recovery_count': activeRecoveryCount,
  };
}

/// Topic-level child Skill coverage summary in `get_child_learning_overview`.
final class LearningTopicSkillCoverage {
  const LearningTopicSkillCoverage({
    required this.totalSkills,
    required this.observedSkills,
    required this.unseenSkills,
    required this.masteredSkills,
    required this.needsRefreshSkills,
    required this.activeRecoverySkills,
  });

  final int totalSkills;
  final int observedSkills;
  final int unseenSkills;
  final int masteredSkills;
  final int needsRefreshSkills;
  final int activeRecoverySkills;

  factory LearningTopicSkillCoverage.fromJson(Map<String, dynamic> json) {
    return LearningTopicSkillCoverage(
      totalSkills: (json['total_skills'] as num).toInt(),
      observedSkills: (json['observed_skills'] as num).toInt(),
      unseenSkills: (json['unseen_skills'] as num).toInt(),
      masteredSkills: (json['mastered_skills'] as num).toInt(),
      needsRefreshSkills: (json['needs_refresh_skills'] as num).toInt(),
      activeRecoverySkills: (json['active_recovery_skills'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'total_skills': totalSkills,
    'observed_skills': observedSkills,
    'unseen_skills': unseenSkills,
    'mastered_skills': masteredSkills,
    'needs_refresh_skills': needsRefreshSkills,
    'active_recovery_skills': activeRecoverySkills,
  };
}

/// Direct observation state on a Subject root node in `get_child_learning_overview`.
final class LearningSubjectDirectState {
  const LearningSubjectDirectState({
    required this.isObserved,
    required this.masteryScore,
    required this.masteryBand,
    required this.confidenceBand,
    required this.confidenceUnits,
    required this.freshness,
    required this.effectiveEvidenceCount,
    required this.distinctAssessmentCount,
    required this.latestEffectiveOccurredAt,
    required this.masteryAttainedAt,
  });

  final bool isObserved;
  final double? masteryScore;
  final MasteryBand? masteryBand;
  final ConfidenceBand? confidenceBand;
  final double confidenceUnits;
  final MasteryFreshness freshness;
  final int effectiveEvidenceCount;
  final int distinctAssessmentCount;
  final DateTime? latestEffectiveOccurredAt;
  final DateTime? masteryAttainedAt;

  factory LearningSubjectDirectState.fromJson(Map<String, dynamic> json) {
    return LearningSubjectDirectState(
      isObserved: json['is_observed'] as bool,
      masteryScore: (json['mastery_score'] as num?)?.toDouble(),
      masteryBand: json['mastery_band'] != null
          ? MasteryBand.fromValue(json['mastery_band'] as String)
          : null,
      confidenceBand: json['confidence_band'] != null
          ? ConfidenceBand.fromValue(json['confidence_band'] as String)
          : null,
      confidenceUnits: (json['confidence_units'] as num).toDouble(),
      freshness: MasteryFreshness.fromValue(json['freshness'] as String),
      effectiveEvidenceCount: (json['effective_evidence_count'] as num).toInt(),
      distinctAssessmentCount: (json['distinct_assessment_count'] as num)
          .toInt(),
      latestEffectiveOccurredAt: json['latest_effective_occurred_at'] != null
          ? DateTime.parse(json['latest_effective_occurred_at'] as String)
          : null,
      masteryAttainedAt: json['mastery_attained_at'] != null
          ? DateTime.parse(json['mastery_attained_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'is_observed': isObserved,
    'mastery_score': masteryScore,
    'mastery_band': masteryBand?.value,
    'confidence_band': confidenceBand?.value,
    'confidence_units': confidenceUnits,
    'freshness': freshness.value,
    'effective_evidence_count': effectiveEvidenceCount,
    'distinct_assessment_count': distinctAssessmentCount,
    'latest_effective_occurred_at': latestEffectiveOccurredAt
        ?.toUtc()
        .toIso8601String(),
    'mastery_attained_at': masteryAttainedAt?.toUtc().toIso8601String(),
  };
}

/// Skill item inside a Topic in `get_child_learning_overview`.
final class LearningSkillOverviewItem {
  const LearningSkillOverviewItem({
    required this.learningNodeId,
    required this.canonicalKey,
    required this.title,
    required this.gradeMin,
    required this.gradeMax,
    required this.sortOrder,
    required this.catalogSortPath,
    required this.isObserved,
    required this.masteryScore,
    required this.masteryBand,
    required this.confidenceBand,
    required this.confidenceUnits,
    required this.freshness,
    required this.recoverySignal,
    required this.latestEffectiveOccurredAt,
    required this.masteryAttainedAt,
    required this.prerequisiteCount,
    required this.attainedPrerequisiteCount,
    required this.isPrerequisiteSatisfied,
    required this.isGradeCompatible,
  });

  final String learningNodeId;
  final String canonicalKey;
  final String title;
  final int? gradeMin;
  final int? gradeMax;
  final int sortOrder;
  final List<int> catalogSortPath;
  final bool isObserved;
  final double? masteryScore;
  final MasteryBand? masteryBand;
  final ConfidenceBand? confidenceBand;
  final double confidenceUnits;
  final MasteryFreshness freshness;
  final RecoverySignal recoverySignal;
  final DateTime? latestEffectiveOccurredAt;
  final DateTime? masteryAttainedAt;
  final int prerequisiteCount;
  final int attainedPrerequisiteCount;
  final bool isPrerequisiteSatisfied;
  final bool isGradeCompatible;

  factory LearningSkillOverviewItem.fromJson(Map<String, dynamic> json) {
    return LearningSkillOverviewItem(
      learningNodeId: json['learning_node_id'] as String,
      canonicalKey: json['canonical_key'] as String,
      title: json['title'] as String,
      gradeMin: (json['grade_min'] as num?)?.toInt(),
      gradeMax: (json['grade_max'] as num?)?.toInt(),
      sortOrder: (json['sort_order'] as num).toInt(),
      catalogSortPath: (json['catalog_sort_path'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      isObserved: json['is_observed'] as bool,
      masteryScore: (json['mastery_score'] as num?)?.toDouble(),
      masteryBand: json['mastery_band'] != null
          ? MasteryBand.fromValue(json['mastery_band'] as String)
          : null,
      confidenceBand: json['confidence_band'] != null
          ? ConfidenceBand.fromValue(json['confidence_band'] as String)
          : null,
      confidenceUnits: (json['confidence_units'] as num).toDouble(),
      freshness: MasteryFreshness.fromValue(json['freshness'] as String),
      recoverySignal: RecoverySignal.fromValue(
        json['recovery_signal'] as String,
      ),
      latestEffectiveOccurredAt: json['latest_effective_occurred_at'] != null
          ? DateTime.parse(json['latest_effective_occurred_at'] as String)
          : null,
      masteryAttainedAt: json['mastery_attained_at'] != null
          ? DateTime.parse(json['mastery_attained_at'] as String)
          : null,
      prerequisiteCount: (json['prerequisite_count'] as num).toInt(),
      attainedPrerequisiteCount: (json['attained_prerequisite_count'] as num)
          .toInt(),
      isPrerequisiteSatisfied: json['is_prerequisite_satisfied'] as bool,
      isGradeCompatible: json['is_grade_compatible'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {
    'learning_node_id': learningNodeId,
    'canonical_key': canonicalKey,
    'title': title,
    'grade_min': gradeMin,
    'grade_max': gradeMax,
    'sort_order': sortOrder,
    'catalog_sort_path': catalogSortPath,
    'is_observed': isObserved,
    'mastery_score': masteryScore,
    'mastery_band': masteryBand?.value,
    'confidence_band': confidenceBand?.value,
    'confidence_units': confidenceUnits,
    'freshness': freshness.value,
    'recovery_signal': recoverySignal.value,
    'latest_effective_occurred_at': latestEffectiveOccurredAt
        ?.toUtc()
        .toIso8601String(),
    'mastery_attained_at': masteryAttainedAt?.toUtc().toIso8601String(),
    'prerequisite_count': prerequisiteCount,
    'attained_prerequisite_count': attainedPrerequisiteCount,
    'is_prerequisite_satisfied': isPrerequisiteSatisfied,
    'is_grade_compatible': isGradeCompatible,
  };
}

/// Topic item inside a Subject in `get_child_learning_overview`.
final class LearningTopicOverview {
  const LearningTopicOverview({
    required this.learningNodeId,
    required this.domainNodeId,
    required this.domainTitle,
    required this.canonicalKey,
    required this.title,
    required this.gradeMin,
    required this.gradeMax,
    required this.sortOrder,
    required this.catalogSortPath,
    required this.isObserved,
    required this.masteryScore,
    required this.masteryBand,
    required this.confidenceBand,
    required this.confidenceUnits,
    required this.freshness,
    required this.recoverySignal,
    required this.latestEffectiveOccurredAt,
    required this.masteryAttainedAt,
    required this.skillCoverage,
    required this.skills,
  });

  final String learningNodeId;
  final String domainNodeId;
  final String domainTitle;
  final String canonicalKey;
  final String title;
  final int? gradeMin;
  final int? gradeMax;
  final int sortOrder;
  final List<int> catalogSortPath;
  final bool isObserved;
  final double? masteryScore;
  final MasteryBand? masteryBand;
  final ConfidenceBand? confidenceBand;
  final double confidenceUnits;
  final MasteryFreshness freshness;
  final RecoverySignal recoverySignal;
  final DateTime? latestEffectiveOccurredAt;
  final DateTime? masteryAttainedAt;
  final LearningTopicSkillCoverage skillCoverage;
  final List<LearningSkillOverviewItem> skills;

  factory LearningTopicOverview.fromJson(Map<String, dynamic> json) {
    return LearningTopicOverview(
      learningNodeId: json['learning_node_id'] as String,
      domainNodeId: json['domain_node_id'] as String,
      domainTitle: json['domain_title'] as String,
      canonicalKey: json['canonical_key'] as String,
      title: json['title'] as String,
      gradeMin: (json['grade_min'] as num?)?.toInt(),
      gradeMax: (json['grade_max'] as num?)?.toInt(),
      sortOrder: (json['sort_order'] as num).toInt(),
      catalogSortPath: (json['catalog_sort_path'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      isObserved: json['is_observed'] as bool,
      masteryScore: (json['mastery_score'] as num?)?.toDouble(),
      masteryBand: json['mastery_band'] != null
          ? MasteryBand.fromValue(json['mastery_band'] as String)
          : null,
      confidenceBand: json['confidence_band'] != null
          ? ConfidenceBand.fromValue(json['confidence_band'] as String)
          : null,
      confidenceUnits: (json['confidence_units'] as num).toDouble(),
      freshness: MasteryFreshness.fromValue(json['freshness'] as String),
      recoverySignal: RecoverySignal.fromValue(
        json['recovery_signal'] as String,
      ),
      latestEffectiveOccurredAt: json['latest_effective_occurred_at'] != null
          ? DateTime.parse(json['latest_effective_occurred_at'] as String)
          : null,
      masteryAttainedAt: json['mastery_attained_at'] != null
          ? DateTime.parse(json['mastery_attained_at'] as String)
          : null,
      skillCoverage: LearningTopicSkillCoverage.fromJson(
        Map<String, dynamic>.from(json['skill_coverage'] as Map),
      ),
      skills: (json['skills'] as List<dynamic>)
          .map(
            (e) => LearningSkillOverviewItem.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'learning_node_id': learningNodeId,
    'domain_node_id': domainNodeId,
    'domain_title': domainTitle,
    'canonical_key': canonicalKey,
    'title': title,
    'grade_min': gradeMin,
    'grade_max': gradeMax,
    'sort_order': sortOrder,
    'catalog_sort_path': catalogSortPath,
    'is_observed': isObserved,
    'mastery_score': masteryScore,
    'mastery_band': masteryBand?.value,
    'confidence_band': confidenceBand?.value,
    'confidence_units': confidenceUnits,
    'freshness': freshness.value,
    'recovery_signal': recoverySignal.value,
    'latest_effective_occurred_at': latestEffectiveOccurredAt
        ?.toUtc()
        .toIso8601String(),
    'mastery_attained_at': masteryAttainedAt?.toUtc().toIso8601String(),
    'skill_coverage': skillCoverage.toJson(),
    'skills': skills.map((s) => s.toJson()).toList(),
  };
}

/// Subject item in `get_child_learning_overview`.
final class LearningSubjectOverview {
  const LearningSubjectOverview({
    required this.subjectNodeId,
    required this.subjectKey,
    required this.canonicalKey,
    required this.title,
    required this.sortOrder,
    required this.subjectState,
    required this.coverage,
    required this.topics,
  });

  final String subjectNodeId;
  final String subjectKey;
  final String canonicalKey;
  final String title;
  final int sortOrder;
  final LearningSubjectDirectState subjectState;
  final LearningSubjectCoverage coverage;
  final List<LearningTopicOverview> topics;

  factory LearningSubjectOverview.fromJson(Map<String, dynamic> json) {
    return LearningSubjectOverview(
      subjectNodeId: json['subject_node_id'] as String,
      subjectKey: json['subject_key'] as String,
      canonicalKey: json['canonical_key'] as String,
      title: json['title'] as String,
      sortOrder: (json['sort_order'] as num).toInt(),
      subjectState: LearningSubjectDirectState.fromJson(
        Map<String, dynamic>.from(json['subject_state'] as Map),
      ),
      coverage: LearningSubjectCoverage.fromJson(
        Map<String, dynamic>.from(json['coverage'] as Map),
      ),
      topics: (json['topics'] as List<dynamic>)
          .map(
            (e) => LearningTopicOverview.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'subject_node_id': subjectNodeId,
    'subject_key': subjectKey,
    'canonical_key': canonicalKey,
    'title': title,
    'sort_order': sortOrder,
    'subject_state': subjectState.toJson(),
    'coverage': coverage.toJson(),
    'topics': topics.map((t) => t.toJson()).toList(),
  };
}

/// Canonical domain representation of `public.get_child_learning_overview`.
final class LearningOverview {
  const LearningOverview({
    required this.childId,
    required this.schoolGrade,
    required this.activeCatalogVersion,
    required this.asOf,
    required this.overallCoverage,
    required this.subjects,
  });

  final ChildId childId;
  final int? schoolGrade;
  final String activeCatalogVersion;
  final DateTime asOf;
  final LearningOverallCoverage overallCoverage;
  final List<LearningSubjectOverview> subjects;

  factory LearningOverview.fromJson(Map<String, dynamic> json) {
    return LearningOverview(
      childId: ChildId(json['child_id'] as String),
      schoolGrade: (json['school_grade'] as num?)?.toInt(),
      activeCatalogVersion: json['active_catalog_version'] as String,
      asOf: DateTime.parse(json['as_of'] as String),
      overallCoverage: LearningOverallCoverage.fromJson(
        Map<String, dynamic>.from(json['overall_coverage'] as Map),
      ),
      subjects: (json['subjects'] as List<dynamic>)
          .map(
            (e) => LearningSubjectOverview.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'child_id': childId.value,
    'school_grade': schoolGrade,
    'active_catalog_version': activeCatalogVersion,
    'as_of': asOf.toUtc().toIso8601String(),
    'overall_coverage': overallCoverage.toJson(),
    'subjects': subjects.map((s) => s.toJson()).toList(),
  };
}

/// Node metadata block inside `get_node_learning_state`.
final class LearningNodeSummary {
  const LearningNodeSummary({
    required this.learningNodeId,
    required this.catalogVersion,
    required this.nodeType,
    required this.subjectKey,
    required this.canonicalKey,
    required this.title,
    required this.parentId,
    required this.parentTopicId,
    required this.parentTopicTitle,
    required this.parentDomainId,
    required this.parentDomainTitle,
    required this.subjectNodeId,
    required this.gradeMin,
    required this.gradeMax,
    required this.sortOrder,
    required this.catalogSortPath,
  });

  final String learningNodeId;
  final String catalogVersion;
  final LearningNodeType nodeType;
  final String subjectKey;
  final String canonicalKey;
  final String title;
  final String? parentId;
  final String? parentTopicId;
  final String? parentTopicTitle;
  final String? parentDomainId;
  final String? parentDomainTitle;
  final String subjectNodeId;
  final int? gradeMin;
  final int? gradeMax;
  final int sortOrder;
  final List<int> catalogSortPath;

  factory LearningNodeSummary.fromJson(Map<String, dynamic> json) {
    return LearningNodeSummary(
      learningNodeId: json['learning_node_id'] as String,
      catalogVersion: json['catalog_version'] as String,
      nodeType: LearningNodeType.fromValue(json['node_type'] as String),
      subjectKey: json['subject_key'] as String,
      canonicalKey: json['canonical_key'] as String,
      title: json['title'] as String,
      parentId: json['parent_id'] as String?,
      parentTopicId: json['parent_topic_id'] as String?,
      parentTopicTitle: json['parent_topic_title'] as String?,
      parentDomainId: json['parent_domain_id'] as String?,
      parentDomainTitle: json['parent_domain_title'] as String?,
      subjectNodeId: json['subject_node_id'] as String,
      gradeMin: (json['grade_min'] as num?)?.toInt(),
      gradeMax: (json['grade_max'] as num?)?.toInt(),
      sortOrder: (json['sort_order'] as num).toInt(),
      catalogSortPath: (json['catalog_sort_path'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'learning_node_id': learningNodeId,
    'catalog_version': catalogVersion,
    'node_type': nodeType.value,
    'subject_key': subjectKey,
    'canonical_key': canonicalKey,
    'title': title,
    'parent_id': parentId,
    'parent_topic_id': parentTopicId,
    'parent_topic_title': parentTopicTitle,
    'parent_domain_id': parentDomainId,
    'parent_domain_title': parentDomainTitle,
    'subject_node_id': subjectNodeId,
    'grade_min': gradeMin,
    'grade_max': gradeMax,
    'sort_order': sortOrder,
    'catalog_sort_path': catalogSortPath,
  };
}

/// Node learning state block inside `get_node_learning_state`.
final class LearningNodeStateDetail {
  const LearningNodeStateDetail({
    required this.isObserved,
    required this.masteryScore,
    required this.masteryBand,
    required this.masteryAttainedAt,
    required this.confidenceBand,
    required this.confidenceUnits,
    required this.distinctRecentVleCount,
    required this.effectiveEvidenceCount,
    required this.distinctAssessmentCount,
    required this.freshness,
    required this.daysSinceLastEvidence,
    required this.recoverySignal,
    required this.latestUnresolvedWeaknessAt,
    required this.recommendedDifficulty,
    required this.isGradeCompatible,
  });

  final bool isObserved;
  final double? masteryScore;
  final MasteryBand? masteryBand;
  final DateTime? masteryAttainedAt;
  final ConfidenceBand? confidenceBand;
  final double confidenceUnits;
  final int distinctRecentVleCount;
  final int effectiveEvidenceCount;
  final int distinctAssessmentCount;
  final MasteryFreshness freshness;
  final int? daysSinceLastEvidence;
  final RecoverySignal recoverySignal;
  final DateTime? latestUnresolvedWeaknessAt;
  final RecommendedDifficulty? recommendedDifficulty;
  final bool isGradeCompatible;

  factory LearningNodeStateDetail.fromJson(Map<String, dynamic> json) {
    return LearningNodeStateDetail(
      isObserved: json['is_observed'] as bool,
      masteryScore: (json['mastery_score'] as num?)?.toDouble(),
      masteryBand: json['mastery_band'] != null
          ? MasteryBand.fromValue(json['mastery_band'] as String)
          : null,
      masteryAttainedAt: json['mastery_attained_at'] != null
          ? DateTime.parse(json['mastery_attained_at'] as String)
          : null,
      confidenceBand: json['confidence_band'] != null
          ? ConfidenceBand.fromValue(json['confidence_band'] as String)
          : null,
      confidenceUnits: (json['confidence_units'] as num).toDouble(),
      distinctRecentVleCount: (json['distinct_recent_vle_count'] as num)
          .toInt(),
      effectiveEvidenceCount: (json['effective_evidence_count'] as num).toInt(),
      distinctAssessmentCount: (json['distinct_assessment_count'] as num)
          .toInt(),
      freshness: MasteryFreshness.fromValue(json['freshness'] as String),
      daysSinceLastEvidence: (json['days_since_last_evidence'] as num?)
          ?.toInt(),
      recoverySignal: RecoverySignal.fromValue(
        json['recovery_signal'] as String,
      ),
      latestUnresolvedWeaknessAt: json['latest_unresolved_weakness_at'] != null
          ? DateTime.parse(json['latest_unresolved_weakness_at'] as String)
          : null,
      recommendedDifficulty: json['recommended_difficulty'] != null
          ? RecommendedDifficulty.fromValue(
              json['recommended_difficulty'] as String,
            )
          : null,
      isGradeCompatible: json['is_grade_compatible'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {
    'is_observed': isObserved,
    'mastery_score': masteryScore,
    'mastery_band': masteryBand?.value,
    'mastery_attained_at': masteryAttainedAt?.toUtc().toIso8601String(),
    'confidence_band': confidenceBand?.value,
    'confidence_units': confidenceUnits,
    'distinct_recent_vle_count': distinctRecentVleCount,
    'effective_evidence_count': effectiveEvidenceCount,
    'distinct_assessment_count': distinctAssessmentCount,
    'freshness': freshness.value,
    'days_since_last_evidence': daysSinceLastEvidence,
    'recovery_signal': recoverySignal.value,
    'latest_unresolved_weakness_at': latestUnresolvedWeaknessAt
        ?.toUtc()
        .toIso8601String(),
    'recommended_difficulty': recommendedDifficulty?.value,
    'is_grade_compatible': isGradeCompatible,
  };
}

/// Summary of the latest Phase 5.2-visible `LearningEvidenceEvent` on a node.
final class LatestLearningEvidenceSummary {
  const LatestLearningEvidenceSummary({
    required this.evidenceEventId,
    required this.verifiedLearningEventId,
    required this.assessmentId,
    required this.scoreSource,
    required this.performancePct,
    required this.difficulty,
    required this.itemCount,
    required this.correctCount,
    required this.effectiveOccurredAt,
    required this.verifiedAt,
  });

  final String evidenceEventId;
  final String verifiedLearningEventId;
  final String? assessmentId;
  final ScoreSource scoreSource;
  final double performancePct;
  final String? difficulty;
  final int? itemCount;
  final int? correctCount;
  final DateTime effectiveOccurredAt;
  final DateTime verifiedAt;

  factory LatestLearningEvidenceSummary.fromJson(Map<String, dynamic> json) {
    return LatestLearningEvidenceSummary(
      evidenceEventId: json['evidence_event_id'] as String,
      verifiedLearningEventId: json['verified_learning_event_id'] as String,
      assessmentId: json['assessment_id'] as String?,
      scoreSource: ScoreSource.fromValue(json['score_source'] as String),
      performancePct: (json['performance_pct'] as num).toDouble(),
      difficulty: json['difficulty'] as String?,
      itemCount: (json['item_count'] as num?)?.toInt(),
      correctCount: (json['correct_count'] as num?)?.toInt(),
      effectiveOccurredAt: DateTime.parse(
        json['effective_occurred_at'] as String,
      ),
      verifiedAt: DateTime.parse(json['verified_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'evidence_event_id': evidenceEventId,
    'verified_learning_event_id': verifiedLearningEventId,
    'assessment_id': assessmentId,
    'score_source': scoreSource.value,
    'performance_pct': performancePct,
    'difficulty': difficulty,
    'item_count': itemCount,
    'correct_count': correctCount,
    'effective_occurred_at': effectiveOccurredAt.toUtc().toIso8601String(),
    'verified_at': verifiedAt.toUtc().toIso8601String(),
  };
}

/// Descendant coverage counts inside `get_node_learning_state`.
final class LearningDescendantCoverage {
  const LearningDescendantCoverage({
    required this.totalDescendantTopics,
    required this.observedDescendantTopics,
    required this.unseenDescendantTopics,
    required this.totalDescendantSkills,
    required this.observedDescendantSkills,
    required this.unseenDescendantSkills,
  });

  final int totalDescendantTopics;
  final int observedDescendantTopics;
  final int unseenDescendantTopics;
  final int totalDescendantSkills;
  final int observedDescendantSkills;
  final int unseenDescendantSkills;

  factory LearningDescendantCoverage.fromJson(Map<String, dynamic> json) {
    return LearningDescendantCoverage(
      totalDescendantTopics: (json['total_descendant_topics'] as num).toInt(),
      observedDescendantTopics: (json['observed_descendant_topics'] as num)
          .toInt(),
      unseenDescendantTopics: (json['unseen_descendant_topics'] as num).toInt(),
      totalDescendantSkills: (json['total_descendant_skills'] as num).toInt(),
      observedDescendantSkills: (json['observed_descendant_skills'] as num)
          .toInt(),
      unseenDescendantSkills: (json['unseen_descendant_skills'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'total_descendant_topics': totalDescendantTopics,
    'observed_descendant_topics': observedDescendantTopics,
    'unseen_descendant_topics': unseenDescendantTopics,
    'total_descendant_skills': totalDescendantSkills,
    'observed_descendant_skills': observedDescendantSkills,
    'unseen_descendant_skills': unseenDescendantSkills,
  };
}

/// Incoming prerequisite Skill item inside `prerequisite_state.prerequisites`.
final class LearningPrerequisiteItem {
  const LearningPrerequisiteItem({
    required this.learningNodeId,
    required this.canonicalKey,
    required this.title,
    required this.isObserved,
    required this.masteryScore,
    required this.masteryBand,
    required this.masteryAttainedAt,
    required this.isAttained,
  });

  final String learningNodeId;
  final String canonicalKey;
  final String title;
  final bool isObserved;
  final double? masteryScore;
  final MasteryBand? masteryBand;
  final DateTime? masteryAttainedAt;
  final bool isAttained;

  factory LearningPrerequisiteItem.fromJson(Map<String, dynamic> json) {
    return LearningPrerequisiteItem(
      learningNodeId: json['learning_node_id'] as String,
      canonicalKey: json['canonical_key'] as String,
      title: json['title'] as String,
      isObserved: json['is_observed'] as bool,
      masteryScore: (json['mastery_score'] as num?)?.toDouble(),
      masteryBand: json['mastery_band'] != null
          ? MasteryBand.fromValue(json['mastery_band'] as String)
          : null,
      masteryAttainedAt: json['mastery_attained_at'] != null
          ? DateTime.parse(json['mastery_attained_at'] as String)
          : null,
      isAttained: json['is_attained'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {
    'learning_node_id': learningNodeId,
    'canonical_key': canonicalKey,
    'title': title,
    'is_observed': isObserved,
    'mastery_score': masteryScore,
    'mastery_band': masteryBand?.value,
    'mastery_attained_at': masteryAttainedAt?.toUtc().toIso8601String(),
    'is_attained': isAttained,
  };
}

/// Outgoing dependent Skill item inside `prerequisite_state.dependents`.
final class LearningDependentItem {
  const LearningDependentItem({
    required this.learningNodeId,
    required this.canonicalKey,
    required this.title,
    required this.gradeMin,
    required this.gradeMax,
    required this.isObserved,
    required this.isGradeCompatible,
    required this.prerequisiteCount,
    required this.attainedPrerequisiteCount,
    required this.isPrerequisiteSatisfied,
  });

  final String learningNodeId;
  final String canonicalKey;
  final String title;
  final int? gradeMin;
  final int? gradeMax;
  final bool isObserved;
  final bool isGradeCompatible;
  final int prerequisiteCount;
  final int attainedPrerequisiteCount;
  final bool isPrerequisiteSatisfied;

  /// Whether this dependent Skill is currently unlocked for the child.
  bool get isUnlocked =>
      !isObserved && isGradeCompatible && isPrerequisiteSatisfied;

  factory LearningDependentItem.fromJson(Map<String, dynamic> json) {
    return LearningDependentItem(
      learningNodeId: json['learning_node_id'] as String,
      canonicalKey: json['canonical_key'] as String,
      title: json['title'] as String,
      gradeMin: (json['grade_min'] as num?)?.toInt(),
      gradeMax: (json['grade_max'] as num?)?.toInt(),
      isObserved: json['is_observed'] as bool,
      isGradeCompatible: json['is_grade_compatible'] as bool,
      prerequisiteCount: (json['prerequisite_count'] as num).toInt(),
      attainedPrerequisiteCount: (json['attained_prerequisite_count'] as num)
          .toInt(),
      isPrerequisiteSatisfied: json['is_prerequisite_satisfied'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {
    'learning_node_id': learningNodeId,
    'canonical_key': canonicalKey,
    'title': title,
    'grade_min': gradeMin,
    'grade_max': gradeMax,
    'is_observed': isObserved,
    'is_grade_compatible': isGradeCompatible,
    'prerequisite_count': prerequisiteCount,
    'attained_prerequisite_count': attainedPrerequisiteCount,
    'is_prerequisite_satisfied': isPrerequisiteSatisfied,
  };
}

/// Prerequisite and dependent graph state inside `get_node_learning_state`.
final class NodePrerequisiteState {
  const NodePrerequisiteState({
    required this.applicable,
    required this.prerequisiteCount,
    required this.attainedPrerequisiteCount,
    required this.isSatisfied,
    required this.prerequisites,
    required this.dependents,
  });

  final bool applicable;
  final int prerequisiteCount;
  final int attainedPrerequisiteCount;
  final bool isSatisfied;
  final List<LearningPrerequisiteItem> prerequisites;
  final List<LearningDependentItem> dependents;

  factory NodePrerequisiteState.fromJson(Map<String, dynamic> json) {
    return NodePrerequisiteState(
      applicable: json['applicable'] as bool,
      prerequisiteCount: (json['prerequisite_count'] as num).toInt(),
      attainedPrerequisiteCount: (json['attained_prerequisite_count'] as num)
          .toInt(),
      isSatisfied: json['is_satisfied'] as bool,
      prerequisites: (json['prerequisites'] as List<dynamic>)
          .map(
            (e) => LearningPrerequisiteItem.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
      dependents: (json['dependents'] as List<dynamic>)
          .map(
            (e) => LearningDependentItem.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'applicable': applicable,
    'prerequisite_count': prerequisiteCount,
    'attained_prerequisite_count': attainedPrerequisiteCount,
    'is_satisfied': isSatisfied,
    'prerequisites': prerequisites.map((p) => p.toJson()).toList(),
    'dependents': dependents.map((d) => d.toJson()).toList(),
  };
}

/// Canonical domain representation of `public.get_node_learning_state`.
final class LearningNodeState {
  const LearningNodeState({
    required this.childId,
    required this.schoolGrade,
    required this.activeCatalogVersion,
    required this.asOf,
    required this.node,
    required this.state,
    required this.latestEvidence,
    required this.coverage,
    required this.prerequisiteState,
  });

  final ChildId childId;
  final int? schoolGrade;
  final String activeCatalogVersion;
  final DateTime asOf;
  final LearningNodeSummary node;
  final LearningNodeStateDetail state;
  final LatestLearningEvidenceSummary? latestEvidence;
  final LearningDescendantCoverage coverage;
  final NodePrerequisiteState prerequisiteState;

  factory LearningNodeState.fromJson(Map<String, dynamic> json) {
    return LearningNodeState(
      childId: ChildId(json['child_id'] as String),
      schoolGrade: (json['school_grade'] as num?)?.toInt(),
      activeCatalogVersion: json['active_catalog_version'] as String,
      asOf: DateTime.parse(json['as_of'] as String),
      node: LearningNodeSummary.fromJson(
        Map<String, dynamic>.from(json['node'] as Map),
      ),
      state: LearningNodeStateDetail.fromJson(
        Map<String, dynamic>.from(json['state'] as Map),
      ),
      latestEvidence: json['latest_evidence'] != null
          ? LatestLearningEvidenceSummary.fromJson(
              Map<String, dynamic>.from(json['latest_evidence'] as Map),
            )
          : null,
      coverage: LearningDescendantCoverage.fromJson(
        Map<String, dynamic>.from(json['coverage'] as Map),
      ),
      prerequisiteState: NodePrerequisiteState.fromJson(
        Map<String, dynamic>.from(json['prerequisite_state'] as Map),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'child_id': childId.value,
    'school_grade': schoolGrade,
    'active_catalog_version': activeCatalogVersion,
    'as_of': asOf.toUtc().toIso8601String(),
    'node': node.toJson(),
    'state': state.toJson(),
    'latest_evidence': latestEvidence?.toJson(),
    'coverage': coverage.toJson(),
    'prerequisite_state': prerequisiteState.toJson(),
  };
}

/// Structured explanation payload for a `NextChallengeCandidate`.
final class NextChallengeExplanation {
  const NextChallengeExplanation({
    required this.latestEffectiveOccurredAt,
    required this.daysSinceLastEvidence,
    required this.latestUnresolvedWeaknessAt,
    required this.prerequisiteCount,
    required this.attainedPrerequisiteTitles,
    required this.exploreProximityRank,
  });

  final DateTime? latestEffectiveOccurredAt;
  final int? daysSinceLastEvidence;
  final DateTime? latestUnresolvedWeaknessAt;
  final int prerequisiteCount;
  final List<String> attainedPrerequisiteTitles;
  final int? exploreProximityRank;

  factory NextChallengeExplanation.fromJson(Map<String, dynamic> json) {
    return NextChallengeExplanation(
      latestEffectiveOccurredAt: json['latest_effective_occurred_at'] != null
          ? DateTime.parse(json['latest_effective_occurred_at'] as String)
          : null,
      daysSinceLastEvidence: (json['days_since_last_evidence'] as num?)
          ?.toInt(),
      latestUnresolvedWeaknessAt: json['latest_unresolved_weakness_at'] != null
          ? DateTime.parse(json['latest_unresolved_weakness_at'] as String)
          : null,
      prerequisiteCount: (json['prerequisite_count'] as num).toInt(),
      attainedPrerequisiteTitles:
          (json['attained_prerequisite_titles'] as List<dynamic>)
              .map((e) => e as String)
              .toList(),
      exploreProximityRank: (json['explore_proximity_rank'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
    'latest_effective_occurred_at': latestEffectiveOccurredAt
        ?.toUtc()
        .toIso8601String(),
    'days_since_last_evidence': daysSinceLastEvidence,
    'latest_unresolved_weakness_at': latestUnresolvedWeaknessAt
        ?.toUtc()
        .toIso8601String(),
    'prerequisite_count': prerequisiteCount,
    'attained_prerequisite_titles': attainedPrerequisiteTitles,
    'explore_proximity_rank': exploreProximityRank,
  };
}

/// Single ranked recommendation item inside `get_next_challenge_candidates`.
final class NextChallengeCandidate {
  const NextChallengeCandidate({
    required this.rank,
    required this.learningNodeId,
    required this.catalogVersion,
    required this.canonicalKey,
    required this.title,
    required this.nodeType,
    required this.subjectKey,
    required this.parentTopicId,
    required this.parentTopicTitle,
    required this.parentDomainId,
    required this.parentDomainTitle,
    required this.gradeMin,
    required this.gradeMax,
    required this.sortOrder,
    required this.catalogSortPath,
    required this.priorityClass,
    required this.reasonCode,
    required this.recommendedDifficulty,
    required this.isObserved,
    required this.masteryScore,
    required this.masteryBand,
    required this.confidenceBand,
    required this.freshness,
    required this.recoverySignal,
    required this.explanation,
    required this.asOf,
  });

  final int rank;
  final String learningNodeId;
  final String catalogVersion;
  final String canonicalKey;
  final String title;
  final LearningNodeType nodeType;
  final String subjectKey;
  final String? parentTopicId;
  final String? parentTopicTitle;
  final String? parentDomainId;
  final String? parentDomainTitle;
  final int? gradeMin;
  final int? gradeMax;
  final int sortOrder;
  final List<int> catalogSortPath;
  final RecommendationPriority priorityClass;
  final NextChallengeReason reasonCode;
  final RecommendedDifficulty recommendedDifficulty;
  final bool isObserved;
  final double? masteryScore;
  final MasteryBand? masteryBand;
  final ConfidenceBand? confidenceBand;
  final MasteryFreshness freshness;
  final RecoverySignal recoverySignal;
  final NextChallengeExplanation explanation;
  final DateTime asOf;

  factory NextChallengeCandidate.fromJson(Map<String, dynamic> json) {
    return NextChallengeCandidate(
      rank: (json['rank'] as num).toInt(),
      learningNodeId: json['learning_node_id'] as String,
      catalogVersion: json['catalog_version'] as String,
      canonicalKey: json['canonical_key'] as String,
      title: json['title'] as String,
      nodeType: LearningNodeType.fromValue(json['node_type'] as String),
      subjectKey: json['subject_key'] as String,
      parentTopicId: json['parent_topic_id'] as String?,
      parentTopicTitle: json['parent_topic_title'] as String?,
      parentDomainId: json['parent_domain_id'] as String?,
      parentDomainTitle: json['parent_domain_title'] as String?,
      gradeMin: (json['grade_min'] as num?)?.toInt(),
      gradeMax: (json['grade_max'] as num?)?.toInt(),
      sortOrder: (json['sort_order'] as num).toInt(),
      catalogSortPath: (json['catalog_sort_path'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      priorityClass: RecommendationPriority.fromValue(
        json['priority_class'] as String,
      ),
      reasonCode: NextChallengeReason.fromValue(json['reason_code'] as String),
      recommendedDifficulty: RecommendedDifficulty.fromValue(
        json['recommended_difficulty'] as String,
      ),
      isObserved: json['is_observed'] as bool,
      masteryScore: (json['mastery_score'] as num?)?.toDouble(),
      masteryBand: json['mastery_band'] != null
          ? MasteryBand.fromValue(json['mastery_band'] as String)
          : null,
      confidenceBand: json['confidence_band'] != null
          ? ConfidenceBand.fromValue(json['confidence_band'] as String)
          : null,
      freshness: MasteryFreshness.fromValue(json['freshness'] as String),
      recoverySignal: RecoverySignal.fromValue(
        json['recovery_signal'] as String,
      ),
      explanation: NextChallengeExplanation.fromJson(
        Map<String, dynamic>.from(json['explanation'] as Map),
      ),
      asOf: DateTime.parse(json['as_of'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'rank': rank,
    'learning_node_id': learningNodeId,
    'catalog_version': catalogVersion,
    'canonical_key': canonicalKey,
    'title': title,
    'node_type': nodeType.value,
    'subject_key': subjectKey,
    'parent_topic_id': parentTopicId,
    'parent_topic_title': parentTopicTitle,
    'parent_domain_id': parentDomainId,
    'parent_domain_title': parentDomainTitle,
    'grade_min': gradeMin,
    'grade_max': gradeMax,
    'sort_order': sortOrder,
    'catalog_sort_path': catalogSortPath,
    'priority_class': priorityClass.value,
    'reason_code': reasonCode.value,
    'recommended_difficulty': recommendedDifficulty.value,
    'is_observed': isObserved,
    'mastery_score': masteryScore,
    'mastery_band': masteryBand?.value,
    'confidence_band': confidenceBand?.value,
    'freshness': freshness.value,
    'recovery_signal': recoverySignal.value,
    'explanation': explanation.toJson(),
    'as_of': asOf.toUtc().toIso8601String(),
  };
}

/// Canonical domain representation of `public.get_next_challenge_candidates`.
final class NextChallengeRecommendationSet {
  const NextChallengeRecommendationSet({
    required this.childId,
    required this.schoolGrade,
    required this.activeCatalogVersion,
    required this.subjectKeyFilter,
    required this.limit,
    required this.asOf,
    required this.candidates,
  });

  final ChildId childId;
  final int? schoolGrade;
  final String activeCatalogVersion;
  final String? subjectKeyFilter;
  final int limit;
  final DateTime asOf;
  final List<NextChallengeCandidate> candidates;

  factory NextChallengeRecommendationSet.fromJson(Map<String, dynamic> json) {
    return NextChallengeRecommendationSet(
      childId: ChildId(json['child_id'] as String),
      schoolGrade: (json['school_grade'] as num?)?.toInt(),
      activeCatalogVersion: json['active_catalog_version'] as String,
      subjectKeyFilter: json['subject_key_filter'] as String?,
      limit: (json['limit'] as num).toInt(),
      asOf: DateTime.parse(json['as_of'] as String),
      candidates: (json['candidates'] as List<dynamic>)
          .map(
            (e) => NextChallengeCandidate.fromJson(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'child_id': childId.value,
    'school_grade': schoolGrade,
    'active_catalog_version': activeCatalogVersion,
    'subject_key_filter': subjectKeyFilter,
    'limit': limit,
    'as_of': asOf.toUtc().toIso8601String(),
    'candidates': candidates.map((c) => c.toJson()).toList(),
  };
}
