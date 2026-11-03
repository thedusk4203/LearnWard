import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  group('Learning Use Cases', () {
    late FakeLearningRepository repository;
    final familyId = FamilyId('fam-01');
    final childId = ChildId('child-01');
    final assessmentId = AssessmentId('assess-01');
    final nodeId = LearningNodeId('b0000003-0000-0000-0000-000000000001');

    setUp(() {
      repository = FakeLearningRepository();
    });

    test('Set and Get AssessmentLearningMappings', () async {
      final setMappings = SetAssessmentLearningMappings(repository);
      final getMappings = GetAssessmentLearningMappings(repository);

      final mapping = AssessmentLearningMapping(
        id: '00000000-0000-0000-0000-000000000099',
        familyId: familyId,
        childId: childId,
        assessmentId: assessmentId,
        learningNodeId: nodeId,
        scoreSource: ScoreSource.componentScore,
        componentKey: 'q1',
        componentRawScore: 9,
        componentMaxScore: 10,
        confirmedByUserId: '00000000-0000-0000-0000-000000000001',
        createdAt: DateTime.utc(2026, 11, 2, 10, 0, 0),
        updatedAt: DateTime.utc(2026, 11, 2, 10, 0, 0),
      );

      final result = await setMappings(
        assessmentId: assessmentId,
        mappings: [mapping],
      );
      expect(result.length, equals(1));
      expect(result.first.learningNodeId, equals(nodeId));

      final retrieved = await getMappings(assessmentId);
      expect(retrieved.length, equals(1));
      expect(retrieved.first.componentKey, equals('q1'));
    });

    test(
      'ProcessLearningEvent records command receipt and returns status',
      () async {
        final processEvent = ProcessLearningEvent(repository);

        final res1 = await processEvent(
          commandId: 'cmd-01',
          verifiedLearningEventId: 'vle-01',
        );
        expect(res1['status'], equals('completed'));

        // Replay returns identical result
        final res2 = await processEvent(
          commandId: 'cmd-01',
          verifiedLearningEventId: 'vle-01',
        );
        expect(res2['status'], equals('completed'));
      },
    );

    test('CatchUpUnprocessedLearning executes bulk catchup', () async {
      final catchUp = CatchUpUnprocessedLearning(repository);
      final res = await catchUp(familyId);
      expect(res['status'], equals('completed'));
      expect(res['family_id'], equals(familyId.value));
    });

    test(
      'GetChildMastery returns calculated projections and confidence',
      () async {
        final getMastery = GetChildMastery(repository);
        final now = DateTime.utc(2026, 11, 2, 12, 0);

        // Add evidence to repository
        repository.addEvidence(
          LearningEvidenceEvent(
            id: 'ev-1',
            familyId: familyId,
            childId: childId,
            verifiedLearningEventId: 'vle-01',
            learningNodeId: nodeId,
            nodeType: LearningNodeType.skill,
            subjectKey: 'math',
            scoreSource: ScoreSource.componentScore,
            performancePct: 90.0,
            specificityWeight: 1.0,
            levelWeight: 1.0,
            effectiveOccurredAt: now.subtract(const Duration(days: 5)),
            verifiedAt: now.subtract(const Duration(days: 5)),
          ),
        );

        final projections = await getMastery(childId: childId);
        expect(projections.length, equals(1));
        expect(projections.first.masteryScore, equals(90.0));
        expect(projections.first.confidenceBand, equals(ConfidenceBand.low));
        expect(
          projections.first.masteryBand,
          equals(MasteryBand.masteryCandidate),
        );
      },
    );

    test('GetChildLearningOverview returns all 5 canonical subjects and pilot-v0.1 coverage', () async {
      final getOverview = GetChildLearningOverview(repository);
      final overview = await getOverview(childId: childId);

      expect(overview.childId, equals(childId));
      expect(overview.activeCatalogVersion, equals('pilot-v0.1'));
      expect(overview.subjects.length, equals(5));
      expect(overview.overallCoverage.totalSkills, equals(3));

      final mathSubject = overview.subjects.firstWhere(
        (s) => s.subjectKey == 'math',
      );
      final doubleDigit = mathSubject.topics.first.skills.firstWhere(
        (s) =>
            s.canonicalKey ==
            'pilot-v0.1:math:arithmetic:addition:double_digit',
      );
      expect(doubleDigit.isPrerequisiteSatisfied, isFalse);
      expect(doubleDigit.prerequisiteCount, equals(1));
      expect(doubleDigit.attainedPrerequisiteCount, equals(0));
    });

    test('GetNodeLearningState returns node detail with prerequisite edges and state', () async {
      final getNodeState = GetNodeLearningState(repository);
      const doubleDigitId = 'b0000003-0000-0000-0000-000000000002';

      final detail = await getNodeState(
        childId: childId,
        learningNodeId: doubleDigitId,
      );
      expect(detail.node.learningNodeId, equals(doubleDigitId));
      expect(detail.prerequisiteState.applicable, isTrue);
      expect(detail.prerequisiteState.isSatisfied, isFalse);
      expect(detail.prerequisiteState.prerequisites.length, equals(1));
      expect(detail.state.recommendedDifficulty, isNull);
    });

    test('GetNextChallengeCandidates returns up to 3 candidates, respects subject filter, and validates limit', () async {
      final getCandidates = GetNextChallengeCandidates(repository);

      final allCandidates = await getCandidates(childId: childId, limit: 3);
      expect(allCandidates.candidates.length, equals(2));
      expect(
        allCandidates.candidates.first.priorityClass,
        equals(RecommendationPriority.explore),
      );

      final mathOnly = await getCandidates(
        childId: childId,
        subjectKey: SubjectKey.math,
        limit: 2,
      );
      expect(mathOnly.subjectKeyFilter, equals('math'));
      expect(mathOnly.candidates.every((c) => c.subjectKey == 'math'), isTrue);

      expect(
        () => getCandidates(childId: childId, limit: 0),
        throwsArgumentError,
      );
      expect(
        () => getCandidates(childId: childId, limit: 4),
        throwsArgumentError,
      );
    });
  });
}
