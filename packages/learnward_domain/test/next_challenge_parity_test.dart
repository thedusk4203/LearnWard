import 'dart:convert';
import 'dart:io';

import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

File findFixturesFile() {
  final candidate1 = File(
    'fixtures/learning_v02_recommendation_parity_fixtures.json',
  );
  if (candidate1.existsSync()) return candidate1;
  final candidate2 = File(
    '../../fixtures/learning_v02_recommendation_parity_fixtures.json',
  );
  if (candidate2.existsSync()) return candidate2;
  final candidate3 = File(
    '../fixtures/learning_v02_recommendation_parity_fixtures.json',
  );
  if (candidate3.existsSync()) return candidate3;
  throw StateError(
    'Cannot locate fixtures/learning_v02_recommendation_parity_fixtures.json',
  );
}

List<LearningNode> buildBasePilotNodes() {
  return [
    LearningNode(
      id: LearningNodeId('a0000000-0000-0000-0000-000000000001'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.subject,
      subjectKey: 'math',
      canonicalKey: 'pilot-v0.1:subject:math',
      title: 'Mathematics',
      sortOrder: 1,
    ),
    LearningNode(
      id: LearningNodeId('a0000000-0000-0000-0000-000000000002'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.subject,
      subjectKey: 'english',
      canonicalKey: 'pilot-v0.1:subject:english',
      title: 'English Language Arts',
      sortOrder: 2,
    ),
    LearningNode(
      id: LearningNodeId('a0000000-0000-0000-0000-000000000003'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.subject,
      subjectKey: 'literature',
      canonicalKey: 'pilot-v0.1:subject:literature',
      title: 'Literature & Reading',
      sortOrder: 3,
    ),
    LearningNode(
      id: LearningNodeId('a0000000-0000-0000-0000-000000000004'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.subject,
      subjectKey: 'science',
      canonicalKey: 'pilot-v0.1:subject:science',
      title: 'Science',
      sortOrder: 4,
    ),
    LearningNode(
      id: LearningNodeId('a0000000-0000-0000-0000-000000000005'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.subject,
      subjectKey: 'other',
      canonicalKey: 'pilot-v0.1:subject:other',
      title: 'Other Subjects',
      sortOrder: 5,
    ),
    LearningNode(
      id: LearningNodeId('b0000001-0000-0000-0000-000000000001'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.domain,
      subjectKey: 'math',
      canonicalKey: 'pilot-v0.1:math:arithmetic',
      title: 'Arithmetic & Numbers',
      parentId: LearningNodeId('a0000000-0000-0000-0000-000000000001'),
      gradeMin: 1,
      gradeMax: 6,
      sortOrder: 1,
    ),
    LearningNode(
      id: LearningNodeId('b0000001-0000-0000-0000-000000000002'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.domain,
      subjectKey: 'english',
      canonicalKey: 'pilot-v0.1:english:grammar',
      title: 'Grammar & Mechanics',
      parentId: LearningNodeId('a0000000-0000-0000-0000-000000000002'),
      gradeMin: 1,
      gradeMax: 8,
      sortOrder: 1,
    ),
    LearningNode(
      id: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.topic,
      subjectKey: 'math',
      canonicalKey: 'pilot-v0.1:math:arithmetic:addition',
      title: 'Addition Operations',
      parentId: LearningNodeId('b0000001-0000-0000-0000-000000000001'),
      gradeMin: 1,
      gradeMax: 4,
      sortOrder: 1,
    ),
    LearningNode(
      id: LearningNodeId('b0000002-0000-0000-0000-000000000002'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.topic,
      subjectKey: 'english',
      canonicalKey: 'pilot-v0.1:english:grammar:punctuation',
      title: 'Punctuation',
      parentId: LearningNodeId('b0000001-0000-0000-0000-000000000002'),
      gradeMin: 1,
      gradeMax: 5,
      sortOrder: 1,
    ),
    LearningNode(
      id: LearningNodeId('b0000003-0000-0000-0000-000000000001'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.skill,
      subjectKey: 'math',
      canonicalKey: 'pilot-v0.1:math:arithmetic:addition:single_digit',
      title: 'Single Digit Addition',
      parentId: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
      gradeMin: 1,
      gradeMax: 2,
      sortOrder: 1,
    ),
    LearningNode(
      id: LearningNodeId('b0000003-0000-0000-0000-000000000002'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.skill,
      subjectKey: 'math',
      canonicalKey: 'pilot-v0.1:math:arithmetic:addition:double_digit',
      title: 'Double Digit Addition',
      parentId: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
      gradeMin: 2,
      gradeMax: 4,
      sortOrder: 2,
    ),
    LearningNode(
      id: LearningNodeId('b0000003-0000-0000-0000-000000000003'),
      catalogVersion: 'pilot-v0.1',
      nodeType: LearningNodeType.skill,
      subjectKey: 'english',
      canonicalKey: 'pilot-v0.1:english:grammar:punctuation:end_marks',
      title: 'End Punctuation Marks',
      parentId: LearningNodeId('b0000002-0000-0000-0000-000000000002'),
      gradeMin: 1,
      gradeMax: 3,
      sortOrder: 1,
    ),
  ];
}

List<LearningPrerequisite> buildBasePilotPrerequisites() {
  return [
    LearningPrerequisite(
      catalogVersion: 'pilot-v0.1',
      subjectKey: 'math',
      prerequisiteNodeId: LearningNodeId(
        'b0000003-0000-0000-0000-000000000001',
      ),
      dependentNodeId: LearningNodeId('b0000003-0000-0000-0000-000000000002'),
    ),
  ];
}

String resolveNodeId(String rawIdOrCanonicalKey, List<LearningNode> nodes) {
  for (final n in nodes) {
    if (n.id.value == rawIdOrCanonicalKey ||
        n.canonicalKey == rawIdOrCanonicalKey) {
      return n.id.value;
    }
  }
  return rawIdOrCanonicalKey;
}

void main() {
  group('Phase 5.2 Skill Graph & Next Challenge 61-Case Parity Matrix (Dart)', () {
    final file = findFixturesFile();
    final fixtures = (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();

    test('Fixture matrix contains all 61 numbered cases', () {
      expect(fixtures.length, equals(61));
      for (var i = 0; i < 61; i++) {
        expect(fixtures[i]['case_id'], equals(i + 1));
      }
    });

    for (final fixture in fixtures) {
      final caseId = fixture['case_id'] as int;
      final section = fixture['section'] as String;
      final scenario = fixture['scenario'] as String;

      test('Case $caseId [$section]: $scenario', () {
        final familyId = FamilyId('f5200000-0000-0000-0000-000000000001');
        final childId = ChildId('c5200000-0000-0000-0000-000000000001');
        final asOf = DateTime.parse(fixture['as_of'] as String).toUtc();
        final schoolGrade = (fixture['school_grade'] as num?)?.toInt();
        final activeCatalogVersion =
            fixture['active_catalog_version'] as String? ?? 'pilot-v0.1';
        final subjectKeyFilter = fixture['subject_key_filter'] as String?;
        final limit = (fixture['limit'] as num?)?.toInt() ?? 3;

        final nodes = buildBasePilotNodes();
        final rawExtraNodes =
            (fixture['extra_nodes'] as List?)?.cast<Map<String, dynamic>>() ??
            const [];
        for (final en in rawExtraNodes) {
          final rawParent = en['parent_id'] as String?;
          final resolvedParent = rawParent != null
              ? LearningNodeId(resolveNodeId(rawParent, nodes))
              : null;
          nodes.add(
            LearningNode(
              id: LearningNodeId(en['id'] as String),
              catalogVersion: en['catalog_version'] as String,
              nodeType: LearningNodeType.fromValue(en['node_type'] as String),
              subjectKey: en['subject_key'] as String,
              canonicalKey: en['canonical_key'] as String,
              title: en['title'] as String,
              parentId: resolvedParent,
              gradeMin: (en['grade_min'] as num?)?.toInt(),
              gradeMax: (en['grade_max'] as num?)?.toInt(),
              sortOrder: (en['sort_order'] as num?)?.toInt() ?? 0,
              isActive: en['is_active'] as bool? ?? true,
            ),
          );
        }

        final prerequisites = buildBasePilotPrerequisites();
        final rawExtraPrereqs =
            (fixture['extra_prerequisites'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            const [];
        for (final ep in rawExtraPrereqs) {
          prerequisites.add(
            LearningPrerequisite(
              catalogVersion: ep['catalog_version'] as String,
              subjectKey: ep['subject_key'] as String? ?? 'math',
              prerequisiteNodeId: LearningNodeId(
                ep['prerequisite_node_id'] as String,
              ),
              dependentNodeId: LearningNodeId(
                ep['dependent_node_id'] as String,
              ),
            ),
          );
        }

        final nodeById = {for (final n in nodes) n.id.value: n};

        final rawStates =
            (fixture['mastery_states'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            const [];
        final masteryStates = <ChildMasteryState>[];
        for (var i = 0; i < rawStates.length; i++) {
          final rs = rawStates[i];
          final nodeId = resolveNodeId(rs['node_id'] as String, nodes);
          masteryStates.add(
            ChildMasteryState(
              familyId: familyId,
              childId: childId,
              learningNodeId: LearningNodeId(nodeId),
              engineVersion: 'mastery-v0.1',
              masteryScore: (rs['mastery_score'] as num).toDouble(),
              effectiveEvidenceCount:
                  (rs['effective_evidence_count'] as num?)?.toInt() ?? 1,
              distinctAssessmentCount:
                  (rs['distinct_assessment_count'] as num?)?.toInt() ?? 1,
              lastEvidenceEventId: 'ev-last-$i',
              lastEvidenceOccurredAt: DateTime.parse(
                rs['last_evidence_occurred_at'] as String,
              ).toUtc(),
              masteryAttainedAt: rs['mastery_attained_at'] != null
                  ? DateTime.parse(rs['mastery_attained_at'] as String).toUtc()
                  : null,
              updatedAt: asOf,
            ),
          );
        }

        final rawEvidence =
            (fixture['evidence_events'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            const [];
        final evidenceEvents = <LearningEvidenceEvent>[];
        for (var i = 0; i < rawEvidence.length; i++) {
          final rev = rawEvidence[i];
          final nodeId = resolveNodeId(rev['node_id'] as String, nodes);
          final n = nodeById[nodeId]!;
          evidenceEvents.add(
            LearningEvidenceEvent(
              id: '00000000-0000-0000-0000-${(i + 1).toString().padLeft(12, '0')}',
              familyId: familyId,
              childId: childId,
              verifiedLearningEventId: rev['vle_id'] as String,
              assessmentId:
                  '20000000-0000-0000-0000-${(i + 1).toString().padLeft(12, '0')}',
              learningNodeId: LearningNodeId(nodeId),
              nodeType: n.nodeType,
              subjectKey: n.subjectKey,
              scoreSource: ScoreSource.fromValue(rev['score_source'] as String),
              performancePct: (rev['performance_pct'] as num).toDouble(),
              specificityWeight: (rev['specificity_weight'] as num).toDouble(),
              levelWeight: (rev['level_weight'] as num).toDouble(),
              difficulty: rev['difficulty'] as String? ?? 'normal',
              itemCount: (rev['item_count'] as num?)?.toInt(),
              correctCount: (rev['correct_count'] as num?)?.toInt(),
              effectiveOccurredAt: DateTime.parse(
                rev['effective_occurred_at'] as String,
              ).toUtc(),
              verifiedAt: DateTime.parse(rev['verified_at'] as String).toUtc(),
            ),
          );
        }

        // 1. Build Overview & verify JSON round-trip
        final overview = NextChallengeEngine.buildOverview(
          childId: childId,
          schoolGrade: schoolGrade,
          activeCatalogVersion: activeCatalogVersion,
          catalogNodes: nodes,
          prerequisites: prerequisites,
          masteryStates: masteryStates,
          evidenceEvents: evidenceEvents,
          asOf: asOf,
        );
        final overviewRoundTrip = LearningOverview.fromJson(
          jsonDecode(jsonEncode(overview.toJson())) as Map<String, dynamic>,
        );
        expect(
          overviewRoundTrip.activeCatalogVersion,
          equals(activeCatalogVersion),
        );

        // 2. Build Node State (if inspect_node_id provided) & verify JSON round-trip
        final inspectRaw = fixture['inspect_node_id'] as String?;
        LearningNodeState? nodeState;
        if (inspectRaw != null) {
          final inspectNodeId = resolveNodeId(inspectRaw, nodes);
          nodeState = NextChallengeEngine.buildNodeState(
            childId: childId,
            learningNodeId: inspectNodeId,
            schoolGrade: schoolGrade,
            activeCatalogVersion: activeCatalogVersion,
            catalogNodes: nodes,
            prerequisites: prerequisites,
            masteryStates: masteryStates,
            evidenceEvents: evidenceEvents,
            asOf: asOf,
          );
          final nodeRoundTrip = LearningNodeState.fromJson(
            jsonDecode(jsonEncode(nodeState.toJson())) as Map<String, dynamic>,
          );
          expect(nodeRoundTrip.node.learningNodeId, equals(inspectNodeId));
        }

        // 3. Build Next Challenge Candidates & verify JSON round-trip
        final nextChallenge = NextChallengeEngine.getNextChallengeCandidates(
          childId: childId,
          schoolGrade: schoolGrade,
          activeCatalogVersion: activeCatalogVersion,
          catalogNodes: nodes,
          prerequisites: prerequisites,
          masteryStates: masteryStates,
          evidenceEvents: evidenceEvents,
          asOf: asOf,
          subjectKeyFilter: subjectKeyFilter,
          limit: limit,
        );
        final recRoundTrip = NextChallengeRecommendationSet.fromJson(
          jsonDecode(jsonEncode(nextChallenge.toJson()))
              as Map<String, dynamic>,
        );
        expect(
          recRoundTrip.candidates.length,
          equals(nextChallenge.candidates.length),
        );

        final expected = fixture['expected'] as Map<String, dynamic>;

        // Check Phase 5.1 vs 5.2 overlap parity (Part A + Part B)
        final expOverlap = expected['phase51_overlap'] as Map<String, dynamic>?;
        if (expOverlap != null && nodeState != null) {
          final st = nodeState.state;
          expect(
            st.masteryScore,
            closeTo((expOverlap['mastery_score'] as num).toDouble(), 0.01),
          );
          expect(st.masteryBand?.value, equals(expOverlap['mastery_band']));
          expect(
            st.confidenceBand?.value,
            equals(expOverlap['confidence_band']),
          );
          expect(
            st.confidenceUnits,
            closeTo((expOverlap['confidence_units'] as num).toDouble(), 0.01),
          );
          if (expOverlap['mastery_attained_at'] == null) {
            expect(st.masteryAttainedAt, isNull);
          } else {
            expect(
              st.masteryAttainedAt,
              equals(
                DateTime.parse(expOverlap['mastery_attained_at'] as String)
                    .toUtc(),
              ),
            );
          }
          expect(
            st.distinctRecentVleCount,
            equals((expOverlap['distinct_recent_vle_count'] as num).toInt()),
          );

          // Verify ConfidenceEngine.evaluate 60-day window agreement (Part B)
          final targetId = nodeState.node.learningNodeId;
          final nodeEv = evidenceEvents
              .where((e) => e.learningNodeId.value == targetId)
              .toList();
          final confEval = ConfidenceEngine.evaluate(
            masteryScore: st.masteryScore!,
            evidence: nodeEv,
            asOf: asOf,
            masteryAttainedAt: st.masteryAttainedAt,
          );
          expect(st.confidenceUnits, closeTo(confEval.confidenceUnits, 0.001));
          expect(st.confidenceBand, equals(confEval.confidenceBand));
          expect(
            st.distinctRecentVleCount,
            equals(confEval.distinctRecentVles),
          );
        }

        // Check expected.node_state
        final expNode = expected['node_state'] as Map<String, dynamic>?;
        if (expNode != null && nodeState != null) {
          final st = nodeState.state;
          final pr = nodeState.prerequisiteState;
          if (expNode.containsKey('is_observed')) {
            expect(st.isObserved, equals(expNode['is_observed']));
          }
          if (expNode.containsKey('mastery_score')) {
            if (expNode['mastery_score'] == null) {
              expect(st.masteryScore, isNull);
            } else {
              expect(
                st.masteryScore,
                closeTo((expNode['mastery_score'] as num).toDouble(), 0.01),
              );
            }
          }
          if (expNode.containsKey('mastery_band')) {
            expect(st.masteryBand?.value, equals(expNode['mastery_band']));
          }
          if (expNode.containsKey('confidence_band')) {
            expect(
              st.confidenceBand?.value,
              equals(expNode['confidence_band']),
            );
          }
          if (expNode.containsKey('confidence_units')) {
            expect(
              st.confidenceUnits,
              closeTo((expNode['confidence_units'] as num).toDouble(), 0.01),
            );
          }
          if (expNode.containsKey('distinct_recent_vle_count')) {
            expect(
              st.distinctRecentVleCount,
              equals((expNode['distinct_recent_vle_count'] as num).toInt()),
            );
          }
          if (expNode.containsKey('freshness')) {
            expect(st.freshness.value, equals(expNode['freshness']));
          }
          if (expNode.containsKey('days_since_last_evidence')) {
            expect(
              st.daysSinceLastEvidence,
              equals((expNode['days_since_last_evidence'] as num?)?.toInt()),
            );
          }
          if (expNode.containsKey('recovery_signal')) {
            expect(st.recoverySignal.value, equals(expNode['recovery_signal']));
          }
          if (expNode.containsKey('latest_unresolved_weakness_at')) {
            final expWeak = expNode['latest_unresolved_weakness_at'] as String?;
            if (expWeak == null) {
              expect(st.latestUnresolvedWeaknessAt, isNull);
            } else {
              expect(
                st.latestUnresolvedWeaknessAt,
                equals(DateTime.parse(expWeak).toUtc()),
              );
            }
          }
          if (expNode.containsKey('recommended_difficulty')) {
            expect(
              st.recommendedDifficulty?.value,
              equals(expNode['recommended_difficulty']),
            );
          }
          if (expNode.containsKey('is_grade_compatible')) {
            expect(
              st.isGradeCompatible,
              equals(expNode['is_grade_compatible']),
            );
          }
          if (expNode.containsKey('latest_evidence_present')) {
            expect(
              nodeState.latestEvidence != null,
              equals(expNode['latest_evidence_present']),
            );
          }
          if (expNode.containsKey('prerequisite_applicable')) {
            expect(pr.applicable, equals(expNode['prerequisite_applicable']));
          }
          if (expNode.containsKey('prerequisite_count')) {
            expect(
              pr.prerequisiteCount,
              equals((expNode['prerequisite_count'] as num).toInt()),
            );
          }
          if (expNode.containsKey('attained_prerequisite_count')) {
            expect(
              pr.attainedPrerequisiteCount,
              equals((expNode['attained_prerequisite_count'] as num).toInt()),
            );
          }
          if (expNode.containsKey('is_prerequisite_satisfied')) {
            expect(
              pr.isSatisfied,
              equals(expNode['is_prerequisite_satisfied']),
            );
          }
          if (expNode.containsKey('dependent_ids')) {
            final expDeps = (expNode['dependent_ids'] as List).cast<String>();
            expect(
              pr.dependents.map((d) => d.learningNodeId).toList(),
              equals(expDeps),
            );
          }
          if (expNode.containsKey('dependents')) {
            final expDepList = (expNode['dependents'] as List)
                .cast<Map<String, dynamic>>();
            expect(pr.dependents.length, equals(expDepList.length));
            for (var i = 0; i < expDepList.length; i++) {
              expect(pr.dependents[i].toJson(), equals(expDepList[i]));
            }
          }
        }

        // Check expected.overview
        final expOverview = expected['overview'] as Map<String, dynamic>?;
        if (expOverview != null) {
          final cov = overview.overallCoverage;
          if (expOverview.containsKey('active_catalog_version')) {
            expect(
              overview.activeCatalogVersion,
              equals(expOverview['active_catalog_version']),
            );
          }
          if (expOverview.containsKey('total_skills')) {
            expect(
              cov.totalSkills,
              equals((expOverview['total_skills'] as num).toInt()),
            );
          }
          if (expOverview.containsKey('observed_skills')) {
            expect(
              cov.observedSkills,
              equals((expOverview['observed_skills'] as num).toInt()),
            );
          }
          if (expOverview.containsKey('unseen_skills')) {
            expect(
              cov.unseenSkills,
              equals((expOverview['unseen_skills'] as num).toInt()),
            );
          }
          if (expOverview.containsKey('mastered_skills')) {
            expect(
              cov.masteredSkills,
              equals((expOverview['mastered_skills'] as num).toInt()),
            );
          }
          if (expOverview.containsKey('active_recovery_count')) {
            expect(
              cov.activeRecoveryCount,
              equals((expOverview['active_recovery_count'] as num).toInt()),
            );
          }
        }

        // Check expected.next_challenge
        final expNext = expected['next_challenge'] as Map<String, dynamic>?;
        if (expNext != null) {
          if (expNext.containsKey('candidate_node_ids')) {
            final expIds = (expNext['candidate_node_ids'] as List)
                .cast<String>();
            expect(
              nextChallenge.candidates.map((c) => c.learningNodeId).toList(),
              equals(expIds),
            );
          }
          if (expNext.containsKey('candidates')) {
            final expCands = (expNext['candidates'] as List)
                .cast<Map<String, dynamic>>();
            expect(nextChallenge.candidates.length, equals(expCands.length));
            for (var i = 0; i < expCands.length; i++) {
              final actual = nextChallenge.candidates[i];
              final expC = expCands[i];
              expect(actual.rank, equals((expC['rank'] as num).toInt()));
              expect(actual.learningNodeId, equals(expC['learning_node_id']));
              if (expC.containsKey('priority_class')) {
                expect(
                  actual.priorityClass.value,
                  equals(expC['priority_class']),
                );
              }
              if (expC.containsKey('reason_code')) {
                expect(actual.reasonCode.value, equals(expC['reason_code']));
              }
              if (expC.containsKey('recommended_difficulty')) {
                expect(
                  actual.recommendedDifficulty.value,
                  equals(expC['recommended_difficulty']),
                );
              }
              if (expC.containsKey('explore_proximity_rank')) {
                expect(
                  actual.explanation.exploreProximityRank,
                  equals((expC['explore_proximity_rank'] as num?)?.toInt()),
                );
              }
              if (expC.containsKey('attained_prerequisite_titles')) {
                expect(
                  actual.explanation.attainedPrerequisiteTitles,
                  equals(
                    (expC['attained_prerequisite_titles'] as List)
                        .cast<String>(),
                  ),
                );
              }
            }
          }
        }

        // Check invalid limit/subject validation if specified (Case 51)
        final expErr = expected['rpc_expect_error'] as Map<String, dynamic>?;
        if (expErr != null) {
          final invalidLimits =
              (expErr['verify_invalid_limits'] as List?)?.cast<int>() ??
              const [];
          for (final badLimit in invalidLimits) {
            expect(
              () => NextChallengeEngine.getNextChallengeCandidates(
                childId: childId,
                schoolGrade: schoolGrade,
                activeCatalogVersion: activeCatalogVersion,
                catalogNodes: nodes,
                prerequisites: prerequisites,
                masteryStates: masteryStates,
                evidenceEvents: evidenceEvents,
                asOf: asOf,
                limit: badLimit,
              ),
              throwsArgumentError,
            );
          }
          final badSubject = expErr['verify_invalid_subject_key'] as String?;
          if (badSubject != null) {
            expect(
              () => NextChallengeEngine.getNextChallengeCandidates(
                childId: childId,
                schoolGrade: schoolGrade,
                activeCatalogVersion: activeCatalogVersion,
                catalogNodes: nodes,
                prerequisites: prerequisites,
                masteryStates: masteryStates,
                evidenceEvents: evidenceEvents,
                asOf: asOf,
                subjectKeyFilter: badSubject,
              ),
              throwsArgumentError,
            );
          }
        }

        if (caseId == 61) {
          // Explicit regression assertions for Case 61:
          // 1. At T2: freshness unknown + score 60 => no Developing candidate and absent from candidates
          final hasDevAtT2 = nextChallenge.candidates.any(
            (c) =>
                c.learningNodeId == fixture['inspect_node_id'] ||
                c.reasonCode == NextChallengeReason.developingKeepPracticing ||
                c.priorityClass == RecommendationPriority.developing,
          );
          expect(hasDevAtT2, isFalse);

          // 2. At T3 (post-verification at 2026-01-10T00:00:00Z):
          final t3AsOf = DateTime.utc(2026, 1, 10);
          final nodeAtT3 = NextChallengeEngine.buildNodeState(
            childId: childId,
            learningNodeId: fixture['inspect_node_id'] as String,
            schoolGrade: schoolGrade,
            activeCatalogVersion: activeCatalogVersion,
            catalogNodes: nodes,
            prerequisites: prerequisites,
            masteryStates: masteryStates,
            evidenceEvents: evidenceEvents,
            asOf: t3AsOf,
          );
          expect(nodeAtT3.state.freshness, equals(MasteryFreshness.recent));
          expect(nodeAtT3.state.recoverySignal, equals(RecoverySignal.none));

          final nextAtT3 = NextChallengeEngine.getNextChallengeCandidates(
            childId: childId,
            schoolGrade: schoolGrade,
            activeCatalogVersion: activeCatalogVersion,
            catalogNodes: nodes,
            prerequisites: prerequisites,
            masteryStates: masteryStates,
            evidenceEvents: evidenceEvents,
            asOf: t3AsOf,
          );
          expect(nextAtT3.candidates, isNotEmpty);
          expect(
            nextAtT3.candidates.first.learningNodeId,
            equals(fixture['inspect_node_id']),
          );
          expect(
            nextAtT3.candidates.first.priorityClass,
            equals(RecommendationPriority.developing),
          );
          expect(
            nextAtT3.candidates.first.reasonCode,
            equals(NextChallengeReason.developingKeepPracticing),
          );
          expect(
            nextAtT3.candidates.first.recommendedDifficulty,
            equals(RecommendedDifficulty.normal),
          );
        }
      });
    }
  });
}
