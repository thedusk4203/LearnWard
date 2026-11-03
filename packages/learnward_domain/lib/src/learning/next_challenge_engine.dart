import '../value_objects/identifiers.dart';
import 'confidence_engine.dart';
import 'freshness_engine.dart';
import 'learning_enums.dart';
import 'learning_models.dart';
import 'learning_recommendation_models.dart';
import 'recovery_engine.dart';

/// Internal resolved active-catalog node with hierarchy and derived read state.
final class _EvaluatedActiveNode {
  const _EvaluatedActiveNode({
    required this.node,
    required this.subjectNodeId,
    required this.parentDomainId,
    required this.parentDomainTitle,
    required this.parentTopicId,
    required this.parentTopicTitle,
    required this.catalogSortPath,
    required this.isObserved,
    required this.masteryScore,
    required this.masteryBand,
    required this.masteryAttainedAt,
    required this.confidenceBand,
    required this.confidenceUnits,
    required this.distinctRecentVleCount,
    required this.effectiveEvidenceCount,
    required this.distinctAssessmentCount,
    required this.latestEffectiveOccurredAt,
    required this.freshness,
    required this.daysSinceLastEvidence,
    required this.recoverySignal,
    required this.latestUnresolvedWeaknessAt,
    required this.isGradeCompatible,
    required this.prerequisiteCount,
    required this.attainedPrerequisiteCount,
    required this.isPrerequisiteSatisfied,
    required this.attainedPrerequisiteTitles,
    required this.prerequisitesList,
  });

  final LearningNode node;
  final String subjectNodeId;
  final String? parentDomainId;
  final String? parentDomainTitle;
  final String? parentTopicId;
  final String? parentTopicTitle;
  final List<int> catalogSortPath;
  final bool isObserved;
  final double? masteryScore;
  final MasteryBand? masteryBand;
  final DateTime? masteryAttainedAt;
  final ConfidenceBand? confidenceBand;
  final double confidenceUnits;
  final int distinctRecentVleCount;
  final int effectiveEvidenceCount;
  final int distinctAssessmentCount;
  final DateTime? latestEffectiveOccurredAt;
  final MasteryFreshness freshness;
  final int? daysSinceLastEvidence;
  final RecoverySignal recoverySignal;
  final DateTime? latestUnresolvedWeaknessAt;
  final bool isGradeCompatible;
  final int prerequisiteCount;
  final int attainedPrerequisiteCount;
  final bool isPrerequisiteSatisfied;
  final List<String> attainedPrerequisiteTitles;
  final List<LearningPrerequisiteItem> prerequisitesList;
}

/// Pure Dart implementation of LearnWard Phase 5.2 Skill Graph, Overview,
/// Node Learning State, and Next Challenge Engine v0.1.
class NextChallengeEngine {
  const NextChallengeEngine();

  static const Set<String> validSubjectKeys = {
    'math',
    'english',
    'literature',
    'science',
    'other',
  };

  /// Authoritative Phase 5.2 `MasteryBand` evaluation.
  ///
  /// Sticky attainment (`masteryAttainedAt != null && !masteryAttainedAt.isAfter(asOf)`)
  /// is the **sole** route to [MasteryBand.mastered]. Read-time evaluation never
  /// manufactures `mastered` from unattained high scores or `ConfidenceEngine.masteryBand`.
  static MasteryBand? evaluateAuthoritativeMasteryBand({
    required bool isObserved,
    required double? masteryScore,
    required DateTime? masteryAttainedAt,
    required DateTime asOf,
  }) {
    if (!isObserved || masteryScore == null) {
      return null;
    }
    if (masteryAttainedAt != null && !masteryAttainedAt.isAfter(asOf)) {
      return MasteryBand.mastered;
    }
    if (masteryScore >= 85.0) {
      return MasteryBand.masteryCandidate;
    }
    if (masteryScore >= 70.0) {
      return MasteryBand.secure;
    }
    if (masteryScore >= 50.0) {
      return MasteryBand.developing;
    }
    return MasteryBand.emerging;
  }

  /// Evaluates grade compatibility against `child_profiles.school_grade`.
  ///
  /// - Unbounded node (`gradeMin == null && gradeMax == null`) -> `true`.
  /// - Grade-scoped node with `schoolGrade == null` -> `false` (fails closed).
  /// - Inclusive bounds `[gradeMin, gradeMax]`.
  static bool isGradeCompatible({
    required int? schoolGrade,
    required int? gradeMin,
    required int? gradeMax,
  }) {
    if (gradeMin == null && gradeMax == null) {
      return true;
    }
    if (schoolGrade == null) {
      return false;
    }
    if (gradeMin != null && schoolGrade < gradeMin) {
      return false;
    }
    if (gradeMax != null && schoolGrade > gradeMax) {
      return false;
    }
    return true;
  }

  /// Compares two integer `catalog_sort_path` arrays lexicographically.
  static int compareCatalogSortPath(List<int> a, List<int> b) {
    final minLen = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < minLen; i++) {
      final cmp = a[i].compareTo(b[i]);
      if (cmp != 0) return cmp;
    }
    return a.length.compareTo(b.length);
  }

  /// Compares two canonical UUID strings in lowercase ASCII order
  /// (identical to PostgreSQL `uuid` byte comparison).
  static int compareNodeIds(String a, String b) {
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  /// Evaluates recommended difficulty for a Next Challenge candidate.
  static RecommendedDifficulty evaluateCandidateDifficulty({
    required RecommendationPriority priorityClass,
    required double? masteryScore,
  }) {
    switch (priorityClass) {
      case RecommendationPriority.recovery:
        return RecommendedDifficulty.belowLevel;
      case RecommendationPriority.refresh:
        return RecommendedDifficulty.normal;
      case RecommendationPriority.developing:
        if ((masteryScore ?? 0.0) >= 70.0) {
          return RecommendedDifficulty.hard;
        }
        return RecommendedDifficulty.normal;
      case RecommendationPriority.unlock:
      case RecommendationPriority.explore:
        return RecommendedDifficulty.normal;
    }
  }

  /// Evaluates recommended difficulty for `get_node_learning_state`.
  static RecommendedDifficulty? evaluateNodeDetailDifficulty({
    required LearningNodeType nodeType,
    required bool isObserved,
    required bool isGradeCompatible,
    required bool isPrerequisiteSatisfied,
    required double? masteryScore,
    required MasteryBand? masteryBand,
    required ConfidenceBand? confidenceBand,
    required MasteryFreshness freshness,
    required RecoverySignal recoverySignal,
  }) {
    if (nodeType == LearningNodeType.subject ||
        nodeType == LearningNodeType.domain) {
      return null;
    }
    if (nodeType == LearningNodeType.topic && !isObserved) {
      return null;
    }
    if (nodeType == LearningNodeType.skill && !isObserved) {
      if (isGradeCompatible && isPrerequisiteSatisfied) {
        return RecommendedDifficulty.normal;
      }
      return null;
    }

    // Observed Topic or Skill
    if (recoverySignal == RecoverySignal.reviewSuggested) {
      return RecommendedDifficulty.belowLevel;
    }
    final score = masteryScore ?? 0.0;
    if (freshness == MasteryFreshness.needsRefresh && score >= 70.0) {
      return RecommendedDifficulty.normal;
    }
    if ((freshness == MasteryFreshness.recent ||
            freshness == MasteryFreshness.aging) &&
        score >= 50.0 &&
        score < 70.0 &&
        masteryBand != MasteryBand.mastered) {
      return RecommendedDifficulty.normal;
    }
    if ((freshness == MasteryFreshness.recent ||
            freshness == MasteryFreshness.aging) &&
        score >= 70.0 &&
        score < 85.0 &&
        masteryBand != MasteryBand.mastered) {
      return RecommendedDifficulty.hard;
    }
    if (score >= 85.0 || masteryBand == MasteryBand.mastered) {
      if (score >= 90.0 && confidenceBand == ConfidenceBand.high) {
        return RecommendedDifficulty.challenge;
      }
      return RecommendedDifficulty.hard;
    }
    return RecommendedDifficulty.normal;
  }

  /// Builds `LearningOverview` (`public.get_child_learning_overview`).
  static LearningOverview buildOverview({
    required ChildId childId,
    required int? schoolGrade,
    required String activeCatalogVersion,
    required Iterable<LearningNode> catalogNodes,
    required Iterable<LearningPrerequisite> prerequisites,
    required Iterable<ChildMasteryState> masteryStates,
    required Iterable<LearningEvidenceEvent> evidenceEvents,
    required DateTime asOf,
  }) {
    final evaluated = _evaluateUniverse(
      childId: childId,
      schoolGrade: schoolGrade,
      activeCatalogVersion: activeCatalogVersion,
      catalogNodes: catalogNodes,
      prerequisites: prerequisites,
      masteryStates: masteryStates,
      evidenceEvents: evidenceEvents,
      asOf: asOf,
    );

    final allTopics = evaluated.values
        .where((n) => n.node.nodeType == LearningNodeType.topic)
        .toList();
    final allSkills = evaluated.values
        .where((n) => n.node.nodeType == LearningNodeType.skill)
        .toList();
    final allTopicsAndSkills = evaluated.values
        .where(
          (n) =>
              n.node.nodeType == LearningNodeType.topic ||
              n.node.nodeType == LearningNodeType.skill,
        )
        .toList();

    final overallCoverage = LearningOverallCoverage(
      totalTopics: allTopics.length,
      observedTopics: allTopics.where((t) => t.isObserved).length,
      unseenTopics: allTopics.where((t) => !t.isObserved).length,
      totalSkills: allSkills.length,
      observedSkills: allSkills.where((s) => s.isObserved).length,
      unseenSkills: allSkills.where((s) => !s.isObserved).length,
      masteredSkills: allSkills
          .where((s) => s.isObserved && s.masteryBand == MasteryBand.mastered)
          .length,
      masteryCandidateSkills: allSkills
          .where(
            (s) =>
                s.isObserved && s.masteryBand == MasteryBand.masteryCandidate,
          )
          .length,
      secureSkills: allSkills
          .where((s) => s.isObserved && s.masteryBand == MasteryBand.secure)
          .length,
      developingSkills: allSkills
          .where((s) => s.isObserved && s.masteryBand == MasteryBand.developing)
          .length,
      emergingSkills: allSkills
          .where((s) => s.isObserved && s.masteryBand == MasteryBand.emerging)
          .length,
      needsRefreshCount: allTopicsAndSkills
          .where(
            (n) => n.isObserved && n.freshness == MasteryFreshness.needsRefresh,
          )
          .length,
      activeRecoveryCount: allTopicsAndSkills
          .where(
            (n) =>
                n.isObserved &&
                n.recoverySignal == RecoverySignal.reviewSuggested,
          )
          .length,
    );

    final subjects =
        evaluated.values
            .where((n) => n.node.nodeType == LearningNodeType.subject)
            .toList()
          ..sort((a, b) {
            final cmp = a.node.sortOrder.compareTo(b.node.sortOrder);
            if (cmp != 0) return cmp;
            return compareNodeIds(a.node.id.value, b.node.id.value);
          });

    final subjectItems = <LearningSubjectOverview>[];
    for (final sub in subjects) {
      final subId = sub.node.id.value;
      final subNodes = evaluated.values
          .where((n) => n.subjectNodeId == subId)
          .toList();
      final subDomains = subNodes
          .where((n) => n.node.nodeType == LearningNodeType.domain)
          .toList();
      final subTopics =
          subNodes
              .where((n) => n.node.nodeType == LearningNodeType.topic)
              .toList()
            ..sort((a, b) {
              final cmp = compareCatalogSortPath(
                a.catalogSortPath,
                b.catalogSortPath,
              );
              if (cmp != 0) return cmp;
              return compareNodeIds(a.node.id.value, b.node.id.value);
            });
      final subSkills = subNodes
          .where((n) => n.node.nodeType == LearningNodeType.skill)
          .toList();
      final subTopicsAndSkills = subNodes
          .where(
            (n) =>
                n.node.nodeType == LearningNodeType.topic ||
                n.node.nodeType == LearningNodeType.skill,
          )
          .toList();

      final topicOverviews = <LearningTopicOverview>[];
      for (final t in subTopics) {
        final tId = t.node.id.value;
        final tSkills = subSkills.where((s) => s.parentTopicId == tId).toList()
          ..sort((a, b) {
            final cmp = compareCatalogSortPath(
              a.catalogSortPath,
              b.catalogSortPath,
            );
            if (cmp != 0) return cmp;
            return compareNodeIds(a.node.id.value, b.node.id.value);
          });

        final skillItems = tSkills
            .map(
              (s) => LearningSkillOverviewItem(
                learningNodeId: s.node.id.value,
                canonicalKey: s.node.canonicalKey,
                title: s.node.title,
                gradeMin: s.node.gradeMin,
                gradeMax: s.node.gradeMax,
                sortOrder: s.node.sortOrder,
                catalogSortPath: s.catalogSortPath,
                isObserved: s.isObserved,
                masteryScore: s.masteryScore,
                masteryBand: s.masteryBand,
                confidenceBand: s.confidenceBand,
                confidenceUnits: s.confidenceUnits,
                freshness: s.freshness,
                recoverySignal: s.recoverySignal,
                latestEffectiveOccurredAt: s.latestEffectiveOccurredAt,
                masteryAttainedAt: s.masteryAttainedAt,
                prerequisiteCount: s.prerequisiteCount,
                attainedPrerequisiteCount: s.attainedPrerequisiteCount,
                isPrerequisiteSatisfied: s.isPrerequisiteSatisfied,
                isGradeCompatible: s.isGradeCompatible,
              ),
            )
            .toList();

        topicOverviews.add(
          LearningTopicOverview(
            learningNodeId: tId,
            domainNodeId: t.parentDomainId!,
            domainTitle: t.parentDomainTitle!,
            canonicalKey: t.node.canonicalKey,
            title: t.node.title,
            gradeMin: t.node.gradeMin,
            gradeMax: t.node.gradeMax,
            sortOrder: t.node.sortOrder,
            catalogSortPath: t.catalogSortPath,
            isObserved: t.isObserved,
            masteryScore: t.masteryScore,
            masteryBand: t.masteryBand,
            confidenceBand: t.confidenceBand,
            confidenceUnits: t.confidenceUnits,
            freshness: t.freshness,
            recoverySignal: t.recoverySignal,
            latestEffectiveOccurredAt: t.latestEffectiveOccurredAt,
            masteryAttainedAt: t.masteryAttainedAt,
            skillCoverage: LearningTopicSkillCoverage(
              totalSkills: tSkills.length,
              observedSkills: tSkills.where((s) => s.isObserved).length,
              unseenSkills: tSkills.where((s) => !s.isObserved).length,
              masteredSkills: tSkills
                  .where(
                    (s) =>
                        s.isObserved && s.masteryBand == MasteryBand.mastered,
                  )
                  .length,
              needsRefreshSkills: tSkills
                  .where(
                    (s) =>
                        s.isObserved &&
                        s.freshness == MasteryFreshness.needsRefresh,
                  )
                  .length,
              activeRecoverySkills: tSkills
                  .where(
                    (s) =>
                        s.isObserved &&
                        s.recoverySignal == RecoverySignal.reviewSuggested,
                  )
                  .length,
            ),
            skills: skillItems,
          ),
        );
      }

      subjectItems.add(
        LearningSubjectOverview(
          subjectNodeId: subId,
          subjectKey: sub.node.subjectKey,
          canonicalKey: sub.node.canonicalKey,
          title: sub.node.title,
          sortOrder: sub.node.sortOrder,
          subjectState: LearningSubjectDirectState(
            isObserved: sub.isObserved,
            masteryScore: sub.masteryScore,
            masteryBand: sub.masteryBand,
            confidenceBand: sub.confidenceBand,
            confidenceUnits: sub.confidenceUnits,
            freshness: sub.freshness,
            effectiveEvidenceCount: sub.effectiveEvidenceCount,
            distinctAssessmentCount: sub.distinctAssessmentCount,
            latestEffectiveOccurredAt: sub.latestEffectiveOccurredAt,
            masteryAttainedAt: sub.masteryAttainedAt,
          ),
          coverage: LearningSubjectCoverage(
            totalDomains: subDomains.length,
            observedDomains: subDomains.where((d) => d.isObserved).length,
            unseenDomains: subDomains.where((d) => !d.isObserved).length,
            totalTopics: subTopics.length,
            observedTopics: subTopics.where((t) => t.isObserved).length,
            unseenTopics: subTopics.where((t) => !t.isObserved).length,
            totalSkills: subSkills.length,
            observedSkills: subSkills.where((s) => s.isObserved).length,
            unseenSkills: subSkills.where((s) => !s.isObserved).length,
            masteredSkills: subSkills
                .where(
                  (s) => s.isObserved && s.masteryBand == MasteryBand.mastered,
                )
                .length,
            masteryCandidateSkills: subSkills
                .where(
                  (s) =>
                      s.isObserved &&
                      s.masteryBand == MasteryBand.masteryCandidate,
                )
                .length,
            secureSkills: subSkills
                .where(
                  (s) => s.isObserved && s.masteryBand == MasteryBand.secure,
                )
                .length,
            developingSkills: subSkills
                .where(
                  (s) =>
                      s.isObserved && s.masteryBand == MasteryBand.developing,
                )
                .length,
            emergingSkills: subSkills
                .where(
                  (s) => s.isObserved && s.masteryBand == MasteryBand.emerging,
                )
                .length,
            needsRefreshCount: subTopicsAndSkills
                .where(
                  (n) =>
                      n.isObserved &&
                      n.freshness == MasteryFreshness.needsRefresh,
                )
                .length,
            activeRecoveryCount: subTopicsAndSkills
                .where(
                  (n) =>
                      n.isObserved &&
                      n.recoverySignal == RecoverySignal.reviewSuggested,
                )
                .length,
          ),
          topics: topicOverviews,
        ),
      );
    }

    return LearningOverview(
      childId: childId,
      schoolGrade: schoolGrade,
      activeCatalogVersion: activeCatalogVersion,
      asOf: asOf,
      overallCoverage: overallCoverage,
      subjects: subjectItems,
    );
  }

  /// Builds `LearningNodeState` (`public.get_node_learning_state`).
  static LearningNodeState buildNodeState({
    required ChildId childId,
    required String learningNodeId,
    required int? schoolGrade,
    required String activeCatalogVersion,
    required Iterable<LearningNode> catalogNodes,
    required Iterable<LearningPrerequisite> prerequisites,
    required Iterable<ChildMasteryState> masteryStates,
    required Iterable<LearningEvidenceEvent> evidenceEvents,
    required DateTime asOf,
  }) {
    if (learningNodeId.trim().isEmpty) {
      throw ArgumentError.value(
        learningNodeId,
        'learningNodeId',
        'Learning node ID is required',
      );
    }

    final evaluated = _evaluateUniverse(
      childId: childId,
      schoolGrade: schoolGrade,
      activeCatalogVersion: activeCatalogVersion,
      catalogNodes: catalogNodes,
      prerequisites: prerequisites,
      masteryStates: masteryStates,
      evidenceEvents: evidenceEvents,
      asOf: asOf,
    );

    final target = evaluated[learningNodeId];
    if (target == null) {
      throw StateError('Learning node not found in active catalog');
    }

    // Descendant coverage
    final descendants = evaluated.values.where((u) {
      if (u.node.id.value == target.node.id.value) return false;
      switch (target.node.nodeType) {
        case LearningNodeType.subject:
          return u.subjectNodeId == target.node.id.value;
        case LearningNodeType.domain:
          return u.parentDomainId == target.node.id.value;
        case LearningNodeType.topic:
          return u.parentTopicId == target.node.id.value;
        case LearningNodeType.skill:
          return false;
      }
    }).toList();

    final descTopics = descendants
        .where((d) => d.node.nodeType == LearningNodeType.topic)
        .toList();
    final descSkills = descendants
        .where((d) => d.node.nodeType == LearningNodeType.skill)
        .toList();

    // Latest visible evidence
    LatestLearningEvidenceSummary? latestEvidence;
    if (target.isObserved) {
      final visibleEv =
          evidenceEvents
              .where(
                (ev) =>
                    ev.childId == childId &&
                    ev.learningNodeId.value == learningNodeId &&
                    !ev.effectiveOccurredAt.isAfter(asOf) &&
                    !ev.verifiedAt.isAfter(asOf),
              )
              .toList()
            ..sort((a, b) {
              final occCmp = b.effectiveOccurredAt.compareTo(
                a.effectiveOccurredAt,
              );
              if (occCmp != 0) return occCmp;
              final verCmp = b.verifiedAt.compareTo(a.verifiedAt);
              if (verCmp != 0) return verCmp;
              return compareNodeIds(
                b.verifiedLearningEventId,
                a.verifiedLearningEventId,
              );
            });
      if (visibleEv.isNotEmpty) {
        final top = visibleEv.first;
        latestEvidence = LatestLearningEvidenceSummary(
          evidenceEventId: top.id,
          verifiedLearningEventId: top.verifiedLearningEventId,
          assessmentId: top.assessmentId,
          scoreSource: top.scoreSource,
          performancePct: top.performancePct,
          difficulty: top.difficulty,
          itemCount: top.itemCount,
          correctCount: top.correctCount,
          effectiveOccurredAt: top.effectiveOccurredAt,
          verifiedAt: top.verifiedAt,
        );
      }
    }

    // Outgoing dependents (for Skill nodes only)
    final dependents = <LearningDependentItem>[];
    if (target.node.nodeType == LearningNodeType.skill) {
      final outgoingEdges = prerequisites.where(
        (lp) =>
            lp.catalogVersion == activeCatalogVersion &&
            lp.prerequisiteNodeId.value == learningNodeId,
      );
      final depNodes = <_EvaluatedActiveNode>[];
      for (final edge in outgoingEdges) {
        final depEval = evaluated[edge.dependentNodeId.value];
        if (depEval != null &&
            depEval.node.nodeType == LearningNodeType.skill) {
          depNodes.add(depEval);
        }
      }
      depNodes.sort((a, b) {
        final cmp = compareCatalogSortPath(
          a.catalogSortPath,
          b.catalogSortPath,
        );
        if (cmp != 0) return cmp;
        return compareNodeIds(a.node.id.value, b.node.id.value);
      });

      for (final dep in depNodes) {
        dependents.add(
          LearningDependentItem(
            learningNodeId: dep.node.id.value,
            canonicalKey: dep.node.canonicalKey,
            title: dep.node.title,
            gradeMin: dep.node.gradeMin,
            gradeMax: dep.node.gradeMax,
            isObserved: dep.isObserved,
            isGradeCompatible: dep.isGradeCompatible,
            prerequisiteCount: dep.prerequisiteCount,
            attainedPrerequisiteCount: dep.attainedPrerequisiteCount,
            isPrerequisiteSatisfied: dep.isPrerequisiteSatisfied,
          ),
        );
      }
    }

    final recDifficulty = evaluateNodeDetailDifficulty(
      nodeType: target.node.nodeType,
      isObserved: target.isObserved,
      isGradeCompatible: target.isGradeCompatible,
      isPrerequisiteSatisfied: target.isPrerequisiteSatisfied,
      masteryScore: target.masteryScore,
      masteryBand: target.masteryBand,
      confidenceBand: target.confidenceBand,
      freshness: target.freshness,
      recoverySignal: target.recoverySignal,
    );

    final isSkill = target.node.nodeType == LearningNodeType.skill;

    return LearningNodeState(
      childId: childId,
      schoolGrade: schoolGrade,
      activeCatalogVersion: activeCatalogVersion,
      asOf: asOf,
      node: LearningNodeSummary(
        learningNodeId: target.node.id.value,
        catalogVersion: target.node.catalogVersion,
        nodeType: target.node.nodeType,
        subjectKey: target.node.subjectKey,
        canonicalKey: target.node.canonicalKey,
        title: target.node.title,
        parentId: target.node.parentId?.value,
        parentTopicId: target.parentTopicId,
        parentTopicTitle: target.parentTopicTitle,
        parentDomainId: target.parentDomainId,
        parentDomainTitle: target.parentDomainTitle,
        subjectNodeId: target.subjectNodeId,
        gradeMin: target.node.gradeMin,
        gradeMax: target.node.gradeMax,
        sortOrder: target.node.sortOrder,
        catalogSortPath: target.catalogSortPath,
      ),
      state: LearningNodeStateDetail(
        isObserved: target.isObserved,
        masteryScore: target.masteryScore,
        masteryBand: target.masteryBand,
        masteryAttainedAt: target.masteryAttainedAt,
        confidenceBand: target.confidenceBand,
        confidenceUnits: target.confidenceUnits,
        distinctRecentVleCount: target.distinctRecentVleCount,
        effectiveEvidenceCount: target.effectiveEvidenceCount,
        distinctAssessmentCount: target.distinctAssessmentCount,
        freshness: target.freshness,
        daysSinceLastEvidence: target.daysSinceLastEvidence,
        recoverySignal: target.recoverySignal,
        latestUnresolvedWeaknessAt: target.latestUnresolvedWeaknessAt,
        recommendedDifficulty: recDifficulty,
        isGradeCompatible: target.isGradeCompatible,
      ),
      latestEvidence: latestEvidence,
      coverage: LearningDescendantCoverage(
        totalDescendantTopics: descTopics.length,
        observedDescendantTopics: descTopics.where((t) => t.isObserved).length,
        unseenDescendantTopics: descTopics.where((t) => !t.isObserved).length,
        totalDescendantSkills: descSkills.length,
        observedDescendantSkills: descSkills.where((s) => s.isObserved).length,
        unseenDescendantSkills: descSkills.where((s) => !s.isObserved).length,
      ),
      prerequisiteState: isSkill
          ? NodePrerequisiteState(
              applicable: true,
              prerequisiteCount: target.prerequisiteCount,
              attainedPrerequisiteCount: target.attainedPrerequisiteCount,
              isSatisfied: target.isPrerequisiteSatisfied,
              prerequisites: target.prerequisitesList,
              dependents: dependents,
            )
          : const NodePrerequisiteState(
              applicable: false,
              prerequisiteCount: 0,
              attainedPrerequisiteCount: 0,
              isSatisfied: true,
              prerequisites: [],
              dependents: [],
            ),
    );
  }

  /// Evaluates `NextChallengeRecommendationSet` (`public.get_next_challenge_candidates`).
  static NextChallengeRecommendationSet getNextChallengeCandidates({
    required ChildId childId,
    required int? schoolGrade,
    required String activeCatalogVersion,
    required Iterable<LearningNode> catalogNodes,
    required Iterable<LearningPrerequisite> prerequisites,
    required Iterable<ChildMasteryState> masteryStates,
    required Iterable<LearningEvidenceEvent> evidenceEvents,
    required DateTime asOf,
    String? subjectKeyFilter,
    int limit = 3,
  }) {
    if (limit < 1 || limit > 3) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Candidate limit must be between 1 and 3',
      );
    }
    if (subjectKeyFilter != null &&
        !validSubjectKeys.contains(subjectKeyFilter)) {
      throw ArgumentError.value(
        subjectKeyFilter,
        'subjectKeyFilter',
        'Invalid subject_key',
      );
    }

    final evaluated = _evaluateUniverse(
      childId: childId,
      schoolGrade: schoolGrade,
      activeCatalogVersion: activeCatalogVersion,
      catalogNodes: catalogNodes,
      prerequisites: prerequisites,
      masteryStates: masteryStates,
      evidenceEvents: evidenceEvents,
      asOf: asOf,
    );

    final allNodes = evaluated.values.toList();
    final filteredNodes = subjectKeyFilter == null
        ? allNodes
        : allNodes.where((n) => n.node.subjectKey == subjectKeyFilter).toList();

    final rawCandidates =
        <
          ({
            _EvaluatedActiveNode evalNode,
            RecommendationPriority priorityClass,
            NextChallengeReason reasonCode,
            RecommendedDifficulty recommendedDifficulty,
            int? exploreProximityRank,
          })
        >[];

    for (final n in filteredNodes) {
      final type = n.node.nodeType;
      if (type != LearningNodeType.topic && type != LearningNodeType.skill) {
        continue;
      }

      RecommendationPriority? priority;
      NextChallengeReason? reason;
      int? proximityRank;

      if (n.isObserved && n.recoverySignal == RecoverySignal.reviewSuggested) {
        priority = RecommendationPriority.recovery;
        reason = NextChallengeReason.recoveryRecentErrors;
      } else if (n.isObserved &&
          n.recoverySignal == RecoverySignal.none &&
          n.freshness == MasteryFreshness.needsRefresh &&
          (n.masteryScore ?? 0.0) >= 70.0) {
        priority = RecommendationPriority.refresh;
        reason = NextChallengeReason.refreshStaleSecureSkill;
      } else if (n.isObserved &&
          n.recoverySignal == RecoverySignal.none &&
          (n.freshness == MasteryFreshness.recent ||
              n.freshness == MasteryFreshness.aging) &&
          (n.masteryScore ?? 0.0) >= 50.0 &&
          (n.masteryScore ?? 0.0) < 85.0 &&
          n.masteryBand != MasteryBand.mastered) {
        priority = RecommendationPriority.developing;
        reason = NextChallengeReason.developingKeepPracticing;
      } else if (type == LearningNodeType.skill &&
          !n.isObserved &&
          n.prerequisiteCount >= 1 &&
          n.isPrerequisiteSatisfied &&
          n.isGradeCompatible) {
        priority = RecommendationPriority.unlock;
        reason = NextChallengeReason.unlockPrerequisitesMastered;
      } else if (type == LearningNodeType.skill &&
          !n.isObserved &&
          n.prerequisiteCount == 0 &&
          n.isGradeCompatible) {
        priority = RecommendationPriority.explore;
        reason = NextChallengeReason.exploreAvailableSkill;
        proximityRank = _computeExploreProximityRank(n, allNodes);
      }

      if (priority != null && reason != null) {
        final recDiff = evaluateCandidateDifficulty(
          priorityClass: priority,
          masteryScore: n.masteryScore,
        );
        rawCandidates.add((
          evalNode: n,
          priorityClass: priority,
          reasonCode: reason,
          recommendedDifficulty: recDiff,
          exploreProximityRank: proximityRank,
        ));
      }
    }

    // Global total comparator (§11.3)
    rawCandidates.sort((a, b) {
      // 1. priority_rank ASC
      final rankCmp = a.priorityClass.rank.compareTo(b.priorityClass.rank);
      if (rankCmp != 0) return rankCmp;

      // 2. Class-specific rank
      switch (a.priorityClass) {
        case RecommendationPriority.recovery:
          final aWeak = a.evalNode.latestUnresolvedWeaknessAt!;
          final bWeak = b.evalNode.latestUnresolvedWeaknessAt!;
          final weakCmp = bWeak.compareTo(aWeak); // DESC
          if (weakCmp != 0) return weakCmp;
        case RecommendationPriority.refresh:
          final aOcc = a.evalNode.latestEffectiveOccurredAt!;
          final bOcc = b.evalNode.latestEffectiveOccurredAt!;
          final occCmp = aOcc.compareTo(bOcc); // ASC
          if (occCmp != 0) return occCmp;
        case RecommendationPriority.developing:
          final aScore = ((a.evalNode.masteryScore ?? 0.0) * 100).round();
          final bScore = ((b.evalNode.masteryScore ?? 0.0) * 100).round();
          final scoreCmp = aScore.compareTo(bScore); // ASC
          if (scoreCmp != 0) return scoreCmp;
        case RecommendationPriority.unlock:
          break;
        case RecommendationPriority.explore:
          final aProx = a.exploreProximityRank ?? 3;
          final bProx = b.exploreProximityRank ?? 3;
          final proxCmp = aProx.compareTo(bProx); // ASC
          if (proxCmp != 0) return proxCmp;
      }

      // 3. catalog_sort_path ASC
      final pathCmp = compareCatalogSortPath(
        a.evalNode.catalogSortPath,
        b.evalNode.catalogSortPath,
      );
      if (pathCmp != 0) return pathCmp;

      // 4. learning_node_id ASC
      return compareNodeIds(a.evalNode.node.id.value, b.evalNode.node.id.value);
    });

    final sliced = rawCandidates.take(limit).toList();
    final candidates = <NextChallengeCandidate>[];

    for (var i = 0; i < sliced.length; i++) {
      final item = sliced[i];
      final n = item.evalNode;
      candidates.add(
        NextChallengeCandidate(
          rank: i + 1,
          learningNodeId: n.node.id.value,
          catalogVersion: n.node.catalogVersion,
          canonicalKey: n.node.canonicalKey,
          title: n.node.title,
          nodeType: n.node.nodeType,
          subjectKey: n.node.subjectKey,
          parentTopicId: n.parentTopicId,
          parentTopicTitle: n.parentTopicTitle,
          parentDomainId: n.parentDomainId,
          parentDomainTitle: n.parentDomainTitle,
          gradeMin: n.node.gradeMin,
          gradeMax: n.node.gradeMax,
          sortOrder: n.node.sortOrder,
          catalogSortPath: n.catalogSortPath,
          priorityClass: item.priorityClass,
          reasonCode: item.reasonCode,
          recommendedDifficulty: item.recommendedDifficulty,
          isObserved: n.isObserved,
          masteryScore: n.masteryScore,
          masteryBand: n.masteryBand,
          confidenceBand: n.confidenceBand,
          freshness: n.freshness,
          recoverySignal: n.recoverySignal,
          explanation: NextChallengeExplanation(
            latestEffectiveOccurredAt: n.latestEffectiveOccurredAt,
            daysSinceLastEvidence: n.daysSinceLastEvidence,
            latestUnresolvedWeaknessAt: n.latestUnresolvedWeaknessAt,
            prerequisiteCount: n.prerequisiteCount,
            attainedPrerequisiteTitles:
                item.priorityClass == RecommendationPriority.unlock
                ? n.attainedPrerequisiteTitles
                : const [],
            exploreProximityRank: item.exploreProximityRank,
          ),
          asOf: asOf,
        ),
      );
    }

    return NextChallengeRecommendationSet(
      childId: childId,
      schoolGrade: schoolGrade,
      activeCatalogVersion: activeCatalogVersion,
      subjectKeyFilter: subjectKeyFilter,
      limit: limit,
      asOf: asOf,
      candidates: candidates,
    );
  }

  static int _computeExploreProximityRank(
    _EvaluatedActiveNode skill,
    List<_EvaluatedActiveNode> allActiveNodes,
  ) {
    // Rank 0: Same Topic has at least one seen Skill
    final hasSeenSiblingSkill = allActiveNodes.any(
      (s2) =>
          s2.node.nodeType == LearningNodeType.skill &&
          s2.parentTopicId == skill.parentTopicId &&
          s2.isObserved,
    );
    if (hasSeenSiblingSkill) return 0;

    // Rank 1: Same Domain (Domain itself, any Topic under it, or any Skill under it) has seen evidence
    final domainId = skill.parentDomainId;
    if (domainId != null) {
      final hasSeenInDomain = allActiveNodes.any(
        (d2) =>
            (d2.node.id.value == domainId || d2.parentDomainId == domainId) &&
            d2.isObserved,
      );
      if (hasSeenInDomain) return 1;
    }

    // Rank 2: Same Subject has seen evidence (including Subject root fallback)
    final hasSeenInSubject = allActiveNodes.any(
      (sub2) =>
          sub2.node.subjectKey == skill.node.subjectKey && sub2.isObserved,
    );
    if (hasSeenInSubject) return 2;

    // Rank 3: Unexplored Subject (cold start)
    return 3;
  }

  static Map<String, _EvaluatedActiveNode> _evaluateUniverse({
    required ChildId childId,
    required int? schoolGrade,
    required String activeCatalogVersion,
    required Iterable<LearningNode> catalogNodes,
    required Iterable<LearningPrerequisite> prerequisites,
    required Iterable<ChildMasteryState> masteryStates,
    required Iterable<LearningEvidenceEvent> evidenceEvents,
    required DateTime asOf,
  }) {
    final versionNodes = catalogNodes
        .where((n) => n.catalogVersion == activeCatalogVersion)
        .toList();
    final nodeById = {for (final n in versionNodes) n.id.value: n};

    // 1. Resolve active universe along strict Subject -> Domain -> Topic -> Skill chain
    final activeSubjects = <String, LearningNode>{};
    for (final n in versionNodes) {
      if (n.nodeType == LearningNodeType.subject && n.isActive) {
        activeSubjects[n.id.value] = n;
      }
    }

    final activeDomains = <String, LearningNode>{};
    for (final n in versionNodes) {
      final pId = n.parentId?.value;
      if (n.nodeType == LearningNodeType.domain &&
          n.isActive &&
          pId != null &&
          activeSubjects.containsKey(pId)) {
        activeDomains[n.id.value] = n;
      }
    }

    final activeTopics = <String, LearningNode>{};
    for (final n in versionNodes) {
      final pId = n.parentId?.value;
      if (n.nodeType == LearningNodeType.topic &&
          n.isActive &&
          pId != null &&
          activeDomains.containsKey(pId)) {
        activeTopics[n.id.value] = n;
      }
    }

    final activeSkills = <String, LearningNode>{};
    for (final n in versionNodes) {
      final pId = n.parentId?.value;
      if (n.nodeType == LearningNodeType.skill &&
          n.isActive &&
          pId != null &&
          activeTopics.containsKey(pId)) {
        activeSkills[n.id.value] = n;
      }
    }

    final cmsByNodeId = <String, ChildMasteryState>{};
    for (final cms in masteryStates) {
      if (cms.childId == childId) {
        cmsByNodeId[cms.learningNodeId.value] = cms;
      }
    }

    final childEvidenceByNodeId = <String, List<LearningEvidenceEvent>>{};
    for (final ev in evidenceEvents) {
      if (ev.childId == childId) {
        childEvidenceByNodeId
            .putIfAbsent(ev.learningNodeId.value, () => [])
            .add(ev);
      }
    }

    List<int> sortPathFor(LearningNode n) {
      switch (n.nodeType) {
        case LearningNodeType.subject:
          return [n.sortOrder];
        case LearningNodeType.domain:
          final r = activeSubjects[n.parentId!.value]!;
          return [r.sortOrder, n.sortOrder];
        case LearningNodeType.topic:
          final d = activeDomains[n.parentId!.value]!;
          final r = activeSubjects[d.parentId!.value]!;
          return [r.sortOrder, d.sortOrder, n.sortOrder];
        case LearningNodeType.skill:
          final t = activeTopics[n.parentId!.value]!;
          final d = activeDomains[t.parentId!.value]!;
          final r = activeSubjects[d.parentId!.value]!;
          return [r.sortOrder, d.sortOrder, t.sortOrder, n.sortOrder];
      }
    }

    final allActive = <LearningNode>[
      ...activeSubjects.values,
      ...activeDomains.values,
      ...activeTopics.values,
      ...activeSkills.values,
    ];

    final result = <String, _EvaluatedActiveNode>{};

    for (final n in allActive) {
      final nodeId = n.id.value;
      final cms = cmsByNodeId[nodeId];
      final isObserved = cms != null;
      final nodeEv = childEvidenceByNodeId[nodeId] ?? const [];

      final String subjectNodeId;
      String? parentDomainId;
      String? parentDomainTitle;
      String? parentTopicId;
      String? parentTopicTitle;

      switch (n.nodeType) {
        case LearningNodeType.subject:
          subjectNodeId = nodeId;
        case LearningNodeType.domain:
          subjectNodeId = n.parentId!.value;
        case LearningNodeType.topic:
          final d = activeDomains[n.parentId!.value]!;
          subjectNodeId = d.parentId!.value;
          parentDomainId = d.id.value;
          parentDomainTitle = d.title;
        case LearningNodeType.skill:
          final t = activeTopics[n.parentId!.value]!;
          final d = activeDomains[t.parentId!.value]!;
          subjectNodeId = d.parentId!.value;
          parentDomainId = d.id.value;
          parentDomainTitle = d.title;
          parentTopicId = t.id.value;
          parentTopicTitle = t.title;
      }

      final sortPath = sortPathFor(n);

      double? masteryScore;
      MasteryBand? masteryBand;
      DateTime? masteryAttainedAt;
      ConfidenceBand? confidenceBand;
      var confidenceUnits = 0.0;
      var distinctRecentVleCount = 0;
      var effectiveEvidenceCount = 0;
      var distinctAssessmentCount = 0;
      DateTime? latestEffectiveOccurredAt;
      var freshness = MasteryFreshness.unknown;
      int? daysSinceLastEvidence;
      var recoverySignal = RecoverySignal.none;
      DateTime? latestUnresolvedWeaknessAt;

      if (isObserved) {
        masteryScore = cms.masteryScore;
        masteryAttainedAt = cms.masteryAttainedAt;
        effectiveEvidenceCount = cms.effectiveEvidenceCount;
        distinctAssessmentCount = cms.distinctAssessmentCount;

        // 1. Authoritative MasteryBand (sticky-only rule; never from ConfidenceEngine)
        masteryBand = evaluateAuthoritativeMasteryBand(
          isObserved: true,
          masteryScore: masteryScore,
          masteryAttainedAt: masteryAttainedAt,
          asOf: asOf,
        );

        // 2. Confidence (exact frozen Phase 5.1 60-day effective_occurred_at window)
        final confEval = ConfidenceEngine.evaluate(
          masteryScore: masteryScore,
          evidence: nodeEv,
          asOf: asOf,
          masteryAttainedAt: masteryAttainedAt,
        );
        confidenceUnits = confEval.confidenceUnits;
        distinctRecentVleCount = confEval.distinctRecentVles;
        confidenceBand = confEval.confidenceBand;

        // 3. Visible latest_effective_occurred_at & Freshness (dual visibility)
        for (final ev in nodeEv) {
          if (!ev.effectiveOccurredAt.isAfter(asOf) &&
              !ev.verifiedAt.isAfter(asOf)) {
            if (latestEffectiveOccurredAt == null ||
                ev.effectiveOccurredAt.isAfter(latestEffectiveOccurredAt)) {
              latestEffectiveOccurredAt = ev.effectiveOccurredAt;
            }
          }
        }
        final freshEval = FreshnessEngine.evaluate(
          latestEffectiveOccurredAt: latestEffectiveOccurredAt,
          asOf: asOf,
        );
        freshness = freshEval.freshness;
        daysSinceLastEvidence = freshEval.daysSinceLastEvidence;

        // 4. Recovery (dual visibility, canonical chronology replay, 30-day expiry)
        final recEval = RecoveryEngine.evaluate(
          nodeType: n.nodeType,
          evidence: nodeEv,
          asOf: asOf,
        );
        recoverySignal = recEval.signal;
        latestUnresolvedWeaknessAt = recEval.latestUnresolvedWeaknessAt;
      }

      final gradeCompat = isGradeCompatible(
        schoolGrade: schoolGrade,
        gradeMin: n.gradeMin,
        gradeMax: n.gradeMax,
      );

      var prereqCount = 0;
      var attainedPrereqCount = 0;
      var isPrereqSatisfied = true;
      final attainedTitles = <String>[];
      final prereqItems = <LearningPrerequisiteItem>[];

      if (n.nodeType == LearningNodeType.skill) {
        final incoming = prerequisites
            .where(
              (lp) =>
                  lp.catalogVersion == activeCatalogVersion &&
                  lp.dependentNodeId.value == nodeId,
            )
            .toList();
        prereqCount = incoming.length;

        final sortedIncoming =
            <
              ({
                LearningNode prereqNode,
                List<int> sortPath,
                bool isActiveSkill,
                ChildMasteryState? cmsP,
                bool isAttained,
              })
            >[];

        for (final edge in incoming) {
          final pNodeId = edge.prerequisiteNodeId.value;
          final pNode = nodeById[pNodeId];
          if (pNode == null) continue;
          final isActiveSkill = activeSkills.containsKey(pNodeId);
          final pSortPath = isActiveSkill
              ? sortPathFor(pNode)
              : <int>[pNode.sortOrder];
          final cmsP = cmsByNodeId[pNodeId];
          final isAttained =
              isActiveSkill &&
              cmsP?.masteryAttainedAt != null &&
              !cmsP!.masteryAttainedAt!.isAfter(asOf);
          sortedIncoming.add((
            prereqNode: pNode,
            sortPath: pSortPath,
            isActiveSkill: isActiveSkill,
            cmsP: cmsP,
            isAttained: isAttained,
          ));
        }

        sortedIncoming.sort((a, b) {
          final cmp = compareCatalogSortPath(a.sortPath, b.sortPath);
          if (cmp != 0) return cmp;
          return compareNodeIds(a.prereqNode.id.value, b.prereqNode.id.value);
        });

        for (final item in sortedIncoming) {
          if (item.isAttained) {
            attainedPrereqCount++;
            attainedTitles.add(item.prereqNode.title);
          }
          final pObserved = item.cmsP != null;
          prereqItems.add(
            LearningPrerequisiteItem(
              learningNodeId: item.prereqNode.id.value,
              canonicalKey: item.prereqNode.canonicalKey,
              title: item.prereqNode.title,
              isObserved: pObserved,
              masteryScore: item.cmsP?.masteryScore,
              masteryBand: evaluateAuthoritativeMasteryBand(
                isObserved: pObserved,
                masteryScore: item.cmsP?.masteryScore,
                masteryAttainedAt: item.cmsP?.masteryAttainedAt,
                asOf: asOf,
              ),
              masteryAttainedAt: item.cmsP?.masteryAttainedAt,
              isAttained: item.isAttained,
            ),
          );
        }

        isPrereqSatisfied = attainedPrereqCount == prereqCount;
      }

      result[nodeId] = _EvaluatedActiveNode(
        node: n,
        subjectNodeId: subjectNodeId,
        parentDomainId: parentDomainId,
        parentDomainTitle: parentDomainTitle,
        parentTopicId: parentTopicId,
        parentTopicTitle: parentTopicTitle,
        catalogSortPath: sortPath,
        isObserved: isObserved,
        masteryScore: masteryScore,
        masteryBand: masteryBand,
        masteryAttainedAt: masteryAttainedAt,
        confidenceBand: confidenceBand,
        confidenceUnits: confidenceUnits,
        distinctRecentVleCount: distinctRecentVleCount,
        effectiveEvidenceCount: effectiveEvidenceCount,
        distinctAssessmentCount: distinctAssessmentCount,
        latestEffectiveOccurredAt: latestEffectiveOccurredAt,
        freshness: freshness,
        daysSinceLastEvidence: daysSinceLastEvidence,
        recoverySignal: recoverySignal,
        latestUnresolvedWeaknessAt: latestUnresolvedWeaknessAt,
        isGradeCompatible: gradeCompat,
        prerequisiteCount: prereqCount,
        attainedPrerequisiteCount: attainedPrereqCount,
        isPrerequisiteSatisfied: isPrereqSatisfied,
        attainedPrerequisiteTitles: attainedTitles,
        prerequisitesList: prereqItems,
      );
    }

    return result;
  }
}
