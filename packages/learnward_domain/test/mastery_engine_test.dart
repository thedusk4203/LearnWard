import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('MasteryEngine', () {
    test('effective alpha calculation obeys weights', () {
      // Skill (1.0), standard (1.0) -> 0.35
      expect(
        MasteryEngine.calculateEffectiveAlpha(
          specificityWeight: 1.0,
          levelWeight: 1.0,
        ),
        equals(0.35),
      );

      // Topic (0.75), standard (1.0) -> 0.2625
      expect(
        MasteryEngine.calculateEffectiveAlpha(
          specificityWeight: 0.75,
          levelWeight: 1.0,
        ),
        equals(0.2625),
      );

      // Domain (0.50), standard (1.0) -> 0.1750
      expect(
        MasteryEngine.calculateEffectiveAlpha(
          specificityWeight: 0.50,
          levelWeight: 1.0,
        ),
        equals(0.1750),
      );

      // Subject (0.35), standard (1.0) -> 0.1225
      expect(
        MasteryEngine.calculateEffectiveAlpha(
          specificityWeight: 0.35,
          levelWeight: 1.0,
        ),
        equals(0.1225),
      );

      // Skill (1.0), below_level (0.50) -> 0.1750
      expect(
        MasteryEngine.calculateEffectiveAlpha(
          specificityWeight: 1.0,
          levelWeight: 0.50,
        ),
        equals(0.1750),
      );
    });

    test('Option A initializes to first observation score', () {
      final familyId = FamilyId('fam-01');
      final childId = ChildId('child-01');
      final nodeId = LearningNodeId('node-01');
      final now = DateTime.utc(2026, 11, 2, 10, 0);

      final ev = LearningEvidenceEvent(
        id: 'ev-1',
        familyId: familyId,
        childId: childId,
        verifiedLearningEventId: 'vle-1',
        learningNodeId: nodeId,
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        scoreSource: ScoreSource.assessmentTotal,
        performancePct: 92.50,
        specificityWeight: 1.0,
        levelWeight: 1.0,
        effectiveOccurredAt: now,
        verifiedAt: now,
      );

      final result = MasteryEngine.rebuildNodeMastery([ev]);
      expect(result.masteryScore, equals(92.50));
      expect(result.effectiveEvidenceCount, equals(1));
      expect(result.distinctAssessmentCount, equals(1));
      expect(result.steps.first.type, equals('initial'));
    });

    test(
      'canonical ordering ensures determinism regardless of input order',
      () {
        final familyId = FamilyId('fam-01');
        final childId = ChildId('child-01');
        final nodeId = LearningNodeId('node-01');
        final t1 = DateTime.utc(2026, 10, 15);
        final t2 = DateTime.utc(2026, 10, 20);

        final ev1 = LearningEvidenceEvent(
          id: 'ev-1',
          familyId: familyId,
          childId: childId,
          verifiedLearningEventId: 'vle-1',
          learningNodeId: nodeId,
          nodeType: LearningNodeType.skill,
          subjectKey: 'math',
          scoreSource: ScoreSource.assessmentTotal,
          performancePct: 80.00,
          specificityWeight: 1.0,
          levelWeight: 1.0,
          effectiveOccurredAt: t1,
          verifiedAt: t1,
        );

        final ev2 = LearningEvidenceEvent(
          id: 'ev-2',
          familyId: familyId,
          childId: childId,
          verifiedLearningEventId: 'vle-2',
          learningNodeId: nodeId,
          nodeType: LearningNodeType.skill,
          subjectKey: 'math',
          scoreSource: ScoreSource.assessmentTotal,
          performancePct: 100.00,
          specificityWeight: 1.0,
          levelWeight: 1.0,
          effectiveOccurredAt: t2,
          verifiedAt: t2,
        );

        // Rebuilding [ev1, ev2] vs [ev2, ev1] must produce identical result (87.00)
        final resForward = MasteryEngine.rebuildNodeMastery([ev1, ev2]);
        final resReverse = MasteryEngine.rebuildNodeMastery([ev2, ev1]);

        expect(resForward.masteryScore, equals(87.00));
        expect(resReverse.masteryScore, equals(87.00));
        expect(resForward.masteryScore, equals(resReverse.masteryScore));
      },
    );

    test('aggregates component scores by score mass', () {
      final scores = [
        (rawScore: 9.0, maxScore: 10.0),
        (rawScore: 9.0, maxScore: 10.0),
      ];
      expect(MasteryEngine.aggregateComponentScores(scores), equals(90.00));
    });

    test('aggregates item groups by item counts', () {
      final groups = [
        (correctCount: 4, itemCount: 5),
        (correctCount: 5, itemCount: 5),
      ];
      expect(MasteryEngine.aggregateItemGroups(groups), equals(90.00));
    });
  });
}
