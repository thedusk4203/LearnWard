import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('ConfidenceEngine', () {
    final familyId = FamilyId('fam-01');
    final childId = ChildId('child-01');
    final nodeId = LearningNodeId('node-01');
    final asOf = DateTime.utc(2026, 11, 2, 12, 0);

    test('low confidence when units < 1.5', () {
      final ev = LearningEvidenceEvent(
        id: 'ev-1',
        familyId: familyId,
        childId: childId,
        verifiedLearningEventId: 'vle-1',
        learningNodeId: nodeId,
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        scoreSource: ScoreSource.assessmentTotal,
        performancePct: 90.0,
        specificityWeight: 1.0,
        levelWeight: 1.0,
        effectiveOccurredAt: asOf.subtract(const Duration(days: 5)),
        verifiedAt: asOf.subtract(const Duration(days: 5)),
      );

      final eval = ConfidenceEngine.evaluate(
        masteryScore: 90.0,
        evidence: [ev],
        asOf: asOf,
      );

      expect(eval.confidenceUnits, equals(1.0));
      expect(eval.confidenceBand, equals(ConfidenceBand.low));
      // Score >= 85 but Low confidence -> masteryCandidate
      expect(eval.masteryBand, equals(MasteryBand.masteryCandidate));
    });

    test('medium confidence when units between 1.5 and 3.5', () {
      final ev1 = LearningEvidenceEvent(
        id: 'ev-1',
        familyId: familyId,
        childId: childId,
        verifiedLearningEventId: 'vle-1',
        learningNodeId: nodeId,
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        scoreSource: ScoreSource.assessmentTotal,
        performancePct: 90.0,
        specificityWeight: 1.0,
        levelWeight: 1.0,
        effectiveOccurredAt: asOf.subtract(const Duration(days: 10)),
        verifiedAt: asOf.subtract(const Duration(days: 10)),
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
        performancePct: 90.0,
        specificityWeight: 1.0,
        levelWeight: 1.0,
        effectiveOccurredAt: asOf.subtract(const Duration(days: 5)),
        verifiedAt: asOf.subtract(const Duration(days: 5)),
      );

      final eval = ConfidenceEngine.evaluate(
        masteryScore: 90.0,
        evidence: [ev1, ev2],
        asOf: asOf,
      );

      expect(eval.confidenceUnits, equals(2.0));
      expect(eval.confidenceBand, equals(ConfidenceBand.medium));
      expect(eval.masteryBand, equals(MasteryBand.masteryCandidate));
    });

    test('high confidence and Mastered band when units > 3.5 and distinct VLEs >= 2', () {
      final events = List.generate(4, (i) {
        return LearningEvidenceEvent(
          id: 'ev-$i',
          familyId: familyId,
          childId: childId,
          verifiedLearningEventId: 'vle-$i',
          learningNodeId: nodeId,
          nodeType: LearningNodeType.skill,
          subjectKey: 'math',
          scoreSource: ScoreSource.assessmentTotal,
          performancePct: 90.0,
          specificityWeight: 1.0,
          levelWeight: 1.0,
          effectiveOccurredAt: asOf.subtract(Duration(days: 10 - i)),
          verifiedAt: asOf.subtract(Duration(days: 10 - i)),
        );
      });

      final eval = ConfidenceEngine.evaluate(
        masteryScore: 90.0,
        evidence: events,
        asOf: asOf,
      );

      expect(eval.confidenceUnits, equals(4.0));
      expect(eval.confidenceBand, equals(ConfidenceBand.high));
      expect(eval.masteryBand, equals(MasteryBand.mastered));
    });

    test(
      'medium confidence when units > 3.5 but single VLE (anti-inflation)',
      () {
        // 4 observations from the SAME VLE
        final events = List.generate(4, (i) {
          return LearningEvidenceEvent(
            id: 'ev-$i',
            familyId: familyId,
            childId: childId,
            verifiedLearningEventId: 'vle-single',
            learningNodeId: nodeId,
            nodeType: LearningNodeType.skill,
            subjectKey: 'math',
            scoreSource: ScoreSource.componentScore,
            componentKey: 'q$i',
            performancePct: 90.0,
            specificityWeight: 1.0,
            levelWeight: 1.0,
            effectiveOccurredAt: asOf.subtract(const Duration(days: 5)),
            verifiedAt: asOf.subtract(const Duration(days: 5)),
          );
        });

        final eval = ConfidenceEngine.evaluate(
          masteryScore: 90.0,
          evidence: events,
          asOf: asOf,
        );

        // Even though units = 4.0, distinct VLEs = 1 => Medium confidence
        expect(eval.confidenceBand, equals(ConfidenceBand.medium));
        expect(eval.masteryBand, equals(MasteryBand.masteryCandidate));
      },
    );

    test('evidence older than 60 days is excluded from confidence', () {
      final oldEv = LearningEvidenceEvent(
        id: 'ev-old',
        familyId: familyId,
        childId: childId,
        verifiedLearningEventId: 'vle-old',
        learningNodeId: nodeId,
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        scoreSource: ScoreSource.assessmentTotal,
        performancePct: 95.0,
        specificityWeight: 1.0,
        levelWeight: 1.0,
        effectiveOccurredAt: asOf.subtract(const Duration(days: 61)),
        verifiedAt: asOf.subtract(const Duration(days: 61)),
      );

      final eval = ConfidenceEngine.evaluate(
        masteryScore: 95.0,
        evidence: [oldEv],
        asOf: asOf,
      );

      expect(eval.confidenceUnits, equals(0.0));
      expect(eval.distinctRecentVles, equals(0));
      expect(eval.masteryBand, equals(MasteryBand.noData));
    });

    test('sticky mastery: once attained, aging past 60 days preserves Mastered band even when confidence drops to Low', () {
      final attainedAt = asOf.subtract(const Duration(days: 65));
      final oldEv1 = LearningEvidenceEvent(
        id: 'ev-old1',
        familyId: familyId,
        childId: childId,
        verifiedLearningEventId: 'vle-old1',
        learningNodeId: nodeId,
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        scoreSource: ScoreSource.assessmentTotal,
        performancePct: 90.0,
        specificityWeight: 1.0,
        levelWeight: 1.0,
        effectiveOccurredAt: attainedAt,
        verifiedAt: attainedAt,
      );

      final eval = ConfidenceEngine.evaluate(
        masteryScore: 90.0,
        evidence: [oldEv1],
        asOf: asOf,
        masteryAttainedAt: attainedAt,
      );

      // Confidence has aged out (0 units in last 60 days, Low confidence)
      expect(eval.confidenceUnits, equals(0.0));
      expect(eval.confidenceBand, equals(ConfidenceBand.low));
      // Sticky mastery ensures masteryBand remains Mastered
      expect(eval.masteryBand, equals(MasteryBand.mastered));
    });

    test('sticky mastery: later lower score updates numeric score but preserves Mastered band when masteryAttainedAt is present', () {
      final attainedAt = asOf.subtract(const Duration(days: 30));
      final recentEv = LearningEvidenceEvent(
        id: 'ev-recent',
        familyId: familyId,
        childId: childId,
        verifiedLearningEventId: 'vle-recent',
        learningNodeId: nodeId,
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        scoreSource: ScoreSource.assessmentTotal,
        performancePct: 60.0,
        specificityWeight: 1.0,
        levelWeight: 1.0,
        effectiveOccurredAt: asOf.subtract(const Duration(days: 2)),
        verifiedAt: asOf.subtract(const Duration(days: 2)),
      );

      final eval = ConfidenceEngine.evaluate(
        masteryScore: 75.0,
        evidence: [recentEv],
        asOf: asOf,
        masteryAttainedAt: attainedAt,
      );

      // Numeric score is 75.0, but historic attainment is sticky
      expect(eval.masteryBand, equals(MasteryBand.mastered));
    });
  });
}
