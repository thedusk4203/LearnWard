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
        familyId: familyId,
        childId: childId,
        assessmentId: assessmentId,
        learningNodeId: nodeId,
        scoreSource: ScoreSource.componentScore,
        componentKey: 'q1',
        componentRawScore: 9,
        componentMaxScore: 10,
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
  });
}
