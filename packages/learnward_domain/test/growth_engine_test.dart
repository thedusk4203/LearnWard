import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('GrowthEngine v0.1', () {
    final now = DateTime.utc(2026, 11, 1, 12, 0);

    ComparableResult makeResult({
      required String id,
      required double score,
      SubjectKey subjectKey = SubjectKey.math,
      AssessmentDifficulty difficulty = AssessmentDifficulty.normal,
      AssessmentType type = AssessmentType.quiz,
      int daysAgo = 1,
      int minutesAgo = 0,
    }) {
      return ComparableResult(
        id: id,
        subjectKey: subjectKey,
        normalizedScore: score,
        difficulty: difficulty,
        assessmentType: type,
        occurredAt: now.subtract(Duration(days: daysAgo, minutes: minutesAgo)),
        verifiedAt: now.subtract(Duration(days: daysAgo, minutes: minutesAgo - 5)),
      );
    }

    test('Engine version is growth-v0.1', () {
      expect(GrowthEngine.engineVersion, equals('growth-v0.1'));
    });

    test('Documented canonical example from spec: 6.43 baseline -> 7.50 Hard = 11.50 RP, 33 XP', () {
      final history = [
        makeResult(id: 'c1', score: 6.0, daysAgo: 3),
        makeResult(id: 'c2', score: 6.5, daysAgo: 2),
        makeResult(id: 'c3', score: 6.8, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'current',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 15, maxScore: 20), // 7.50
        difficulty: AssessmentDifficulty.hard,
        assessmentType: AssessmentType.practice,
        occurredAt: now,
        verifiedAt: now.add(const Duration(minutes: 5)),
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      final b = result.breakdown;

      expect(b.normalizedScore, equals(7.50));
      expect(b.baselineScore, equals(6.43));
      expect(b.baselineSampleCount, equals(3));
      expect(b.growthDelta, equals(1.07));
      expect(b.historicalBest, equals(6.80));

      expect(b.scoreRpMinor.value, equals(750)); // +7.50 RP
      expect(b.growthRpMinor.value, equals(200)); // +2.00 RP (delta 1.07 in [1.0, 1.49])
      expect(b.personalBestRpMinor.value, equals(100)); // +1.00 RP (7.50 - 6.80 = 0.70 >= 0.25)
      expect(b.difficultyRpMinor.value, equals(100)); // +1.00 RP (Hard)
      expect(b.highPerformerRpMinor.value, equals(0)); // 0 RP (baseline 6.43 < 8.5)
      expect(b.goalRpMinor.value, equals(0)); // 0 RP (deferred)
      expect(b.recoveryRpMinor.value, equals(0)); // 0 RP (deferred)
      expect(b.belowLevelAdjustment, isFalse);

      expect(b.totalRpMinor.value, equals(1150)); // +11.50 RP
      expect(b.totalRpMinor.formatRp(), equals('11.50'));
      expect(b.xpAwarded.value, equals(33)); // 10 + 2 * 11.50 = 33 XP
    });

    test('no history: baseline is null, no growth/PB bonus, challenge bonus active if >= 5.0', () {
      final input = GrowthInput(
        currentEventId: 'ev1',
        subjectKey: SubjectKey.science,
        currentScore: NormalizedScore.fromRaw(rawScore: 8, maxScore: 10), // 8.00
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: [],
      );

      final result = GrowthEngine.calculate(input);
      final b = result.breakdown;

      expect(b.baselineScore, isNull);
      expect(b.baselineSampleCount, equals(0));
      expect(b.growthDelta, isNull);
      expect(b.historicalBest, isNull);
      expect(b.scoreRpMinor.value, equals(800)); // 8.00 RP
      expect(b.growthRpMinor.value, equals(0));
      expect(b.personalBestRpMinor.value, equals(0));
      expect(b.totalRpMinor.value, equals(800)); // 8.00 RP
      expect(b.xpAwarded.value, equals(26)); // 10 + 2 * 8.00 = 26 XP
    });

    test('1 comparable result: baseline remains null, historical best tracks and can trigger PB', () {
      final history = [
        makeResult(id: 'c1', score: 6.0, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'ev2',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 7, maxScore: 10), // 7.00
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      final b = result.breakdown;

      expect(b.baselineScore, isNull);
      expect(b.baselineSampleCount, equals(1));
      expect(b.historicalBest, equals(6.00));
      expect(b.growthRpMinor.value, equals(0)); // no baseline => no growth bonus
      expect(b.personalBestRpMinor.value, equals(100)); // 7.00 - 6.00 >= 0.25 => +1 RP
      expect(b.totalRpMinor.value, equals(800)); // 700 + 100 = 800 (8.00 RP)
      expect(b.xpAwarded.value, equals(26));
    });

    test('2 comparable results: baseline remains null (requires at least 3 samples)', () {
      final history = [
        makeResult(id: 'c1', score: 7.0, daysAgo: 2),
        makeResult(id: 'c2', score: 7.2, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'ev3',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 7, maxScore: 10), // 7.00
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      final b = result.breakdown;

      expect(b.baselineScore, isNull);
      expect(b.baselineSampleCount, equals(2));
      expect(b.historicalBest, equals(7.20));
      expect(b.growthRpMinor.value, equals(0));
      expect(b.personalBestRpMinor.value, equals(0)); // 7.00 < 7.20
      expect(b.totalRpMinor.value, equals(700));
    });

    test('3+ comparable results: uses rolling last 3 only', () {
      final history = [
        makeResult(id: 'c_oldest', score: 2.0, daysAgo: 10), // ignored by rolling 3
        makeResult(id: 'c1', score: 7.0, daysAgo: 3),
        makeResult(id: 'c2', score: 8.0, daysAgo: 2),
        makeResult(id: 'c3', score: 9.0, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'ev4',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 9, maxScore: 10), // 9.00
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      final b = result.breakdown;

      // Last 3 are 7.0, 8.0, 9.0 -> mean is 8.00 (not including 2.0)
      expect(b.baselineScore, equals(8.00));
      expect(b.baselineSampleCount, equals(3));
      expect(b.growthDelta, equals(1.00));
      expect(b.growthRpMinor.value, equals(200)); // delta 1.00 -> +2 RP
      expect(b.historicalBest, equals(9.00)); // across all records
      expect(b.personalBestRpMinor.value, equals(0)); // 9.00 - 9.00 = 0 < 0.25
    });

    test('non-comparable subject is strictly ignored', () {
      final history = [
        makeResult(id: 'eng1', score: 9.0, subjectKey: SubjectKey.english, daysAgo: 3),
        makeResult(id: 'eng2', score: 9.0, subjectKey: SubjectKey.english, daysAgo: 2),
        makeResult(id: 'eng3', score: 9.0, subjectKey: SubjectKey.english, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'math_ev',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 8, maxScore: 10),
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      expect(result.breakdown.baselineScore, isNull);
      expect(result.breakdown.baselineSampleCount, equals(0));
    });

    test('current event is strictly excluded from its own baseline', () {
      final history = [
        makeResult(id: 'self_ev', score: 10.0, daysAgo: 0), // same id as current
        makeResult(id: 'c1', score: 5.0, daysAgo: 3),
        makeResult(id: 'c2', score: 5.0, daysAgo: 2),
        makeResult(id: 'c3', score: 5.0, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'self_ev',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 10, maxScore: 10),
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      // Baseline should be mean of c1, c2, c3 = 5.00, NOT containing 10.0
      expect(result.breakdown.baselineScore, equals(5.00));
      expect(result.breakdown.growthDelta, equals(5.00));
      expect(result.breakdown.growthRpMinor.value, equals(400)); // delta >= 2.0 -> +4 RP
    });

    group('Growth bonus delta thresholds', () {
      GrowthBreakdown runDelta(double delta) {
        final baselineScore = 5.0;
        final currentScore = baselineScore + delta;
        final history = [
          makeResult(id: 'c1', score: 5.0, daysAgo: 3),
          makeResult(id: 'c2', score: 5.0, daysAgo: 2),
          makeResult(id: 'c3', score: 5.0, daysAgo: 1),
        ];

        final input = GrowthInput(
          currentEventId: 'ev',
          subjectKey: SubjectKey.math,
          currentScore: NormalizedScore.fromRaw(rawScore: currentScore, maxScore: 10),
          difficulty: AssessmentDifficulty.normal,
          assessmentType: AssessmentType.quiz,
          occurredAt: now,
          verifiedAt: now,
          comparableHistory: history,
        );

        return GrowthEngine.calculate(input).breakdown;
      }

      test('delta < 0.50 -> 0 RP', () {
        expect(runDelta(0.49).growthRpMinor.value, equals(0));
        expect(runDelta(-0.50).growthRpMinor.value, equals(0));
      });

      test('delta 0.50 to 0.99 -> +1 RP (100 minor)', () {
        expect(runDelta(0.50).growthRpMinor.value, equals(100));
        expect(runDelta(0.99).growthRpMinor.value, equals(100));
      });

      test('delta 1.00 to 1.49 -> +2 RP (200 minor)', () {
        expect(runDelta(1.00).growthRpMinor.value, equals(200));
        expect(runDelta(1.49).growthRpMinor.value, equals(200));
      });

      test('delta 1.50 to 1.99 -> +3 RP (300 minor)', () {
        expect(runDelta(1.50).growthRpMinor.value, equals(300));
        expect(runDelta(1.99).growthRpMinor.value, equals(300));
      });

      test('delta >= 2.00 -> +4 RP (400 minor)', () {
        expect(runDelta(2.00).growthRpMinor.value, equals(400));
        expect(runDelta(3.50).growthRpMinor.value, equals(400));
      });
    });

    test('high performer maintenance: baseline >= 8.5 AND current >= 8.5 -> +1 RP', () {
      final history = [
        makeResult(id: 'c1', score: 9.0, daysAgo: 3),
        makeResult(id: 'c2', score: 9.0, daysAgo: 2),
        makeResult(id: 'c3', score: 9.0, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'hp_ev',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 9, maxScore: 10), // 9.00
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      final b = result.breakdown;

      expect(b.baselineScore, equals(9.00));
      expect(b.growthDelta, equals(0.00));
      expect(b.growthRpMinor.value, equals(0)); // delta 0 -> no growth bonus
      expect(b.highPerformerRpMinor.value, equals(100)); // +1 RP maintenance!
      expect(b.personalBestRpMinor.value, equals(0));
      expect(b.totalRpMinor.value, equals(1000)); // 900 base + 100 maintenance = 10.00 RP
      expect(b.xpAwarded.value, equals(30)); // 10 + 2 * 10 = 30 XP
    });

    test('high performer not awarded if baseline < 8.5 even if current >= 8.5', () {
      final history = [
        makeResult(id: 'c1', score: 8.0, daysAgo: 3),
        makeResult(id: 'c2', score: 8.0, daysAgo: 2),
        makeResult(id: 'c3', score: 8.0, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'ev',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 9, maxScore: 10), // 9.00
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      expect(result.breakdown.highPerformerRpMinor.value, equals(0));
      expect(result.breakdown.growthRpMinor.value, equals(200)); // delta +1.00 -> +2 RP
    });

    test('personal best boundary: exactly +0.25 vs +0.24', () {
      final history = [
        makeResult(id: 'c1', score: 7.0, daysAgo: 1),
      ];

      // Current 7.25: exceeds by 0.25 -> +1 RP
      final inputExact = GrowthInput(
        currentEventId: 'ev_exact',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 7.25, maxScore: 10),
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );
      expect(GrowthEngine.calculate(inputExact).breakdown.personalBestRpMinor.value, equals(100));

      // Current 7.24: exceeds by 0.24 -> 0 RP
      final inputBelow = GrowthInput(
        currentEventId: 'ev_below',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 7.24, maxScore: 10),
        difficulty: AssessmentDifficulty.normal,
        assessmentType: AssessmentType.quiz,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );
      expect(GrowthEngine.calculate(inputBelow).breakdown.personalBestRpMinor.value, equals(0));
    });

    group('Difficulty bonuses', () {
      test('normal difficulty -> 0 RP', () {
        final input = GrowthInput(
          currentEventId: 'ev',
          subjectKey: SubjectKey.math,
          currentScore: NormalizedScore.fromRaw(rawScore: 7, maxScore: 10),
          difficulty: AssessmentDifficulty.normal,
          assessmentType: AssessmentType.quiz,
          occurredAt: now,
          verifiedAt: now,
        );
        expect(GrowthEngine.calculate(input).breakdown.difficultyRpMinor.value, equals(0));
      });

      test('hard difficulty -> +1 RP (100 minor)', () {
        final input = GrowthInput(
          currentEventId: 'ev',
          subjectKey: SubjectKey.math,
          currentScore: NormalizedScore.fromRaw(rawScore: 7, maxScore: 10),
          difficulty: AssessmentDifficulty.hard,
          assessmentType: AssessmentType.quiz,
          occurredAt: now,
          verifiedAt: now,
        );
        expect(GrowthEngine.calculate(input).breakdown.difficultyRpMinor.value, equals(100));
      });

      test('challenge score below 5.0 -> 0 RP (no farming bonus for low scores)', () {
        final input = GrowthInput(
          currentEventId: 'ev',
          subjectKey: SubjectKey.math,
          currentScore: NormalizedScore.fromRaw(rawScore: 4.9, maxScore: 10),
          difficulty: AssessmentDifficulty.challenge,
          assessmentType: AssessmentType.quiz,
          occurredAt: now,
          verifiedAt: now,
        );
        expect(GrowthEngine.calculate(input).breakdown.difficultyRpMinor.value, equals(0));
      });

      test('challenge score >= 5.0 -> +2 RP (200 minor)', () {
        final input = GrowthInput(
          currentEventId: 'ev',
          subjectKey: SubjectKey.math,
          currentScore: NormalizedScore.fromRaw(rawScore: 5.0, maxScore: 10),
          difficulty: AssessmentDifficulty.challenge,
          assessmentType: AssessmentType.quiz,
          occurredAt: now,
          verifiedAt: now,
        );
        expect(GrowthEngine.calculate(input).breakdown.difficultyRpMinor.value, equals(200));
      });
    });

    test('below-level anti-farming: 25% base RP, growth/PB bonuses disabled, legitimate XP earned', () {
      final history = [
        makeResult(id: 'c1', score: 6.0, daysAgo: 3),
        makeResult(id: 'c2', score: 6.0, daysAgo: 2),
        makeResult(id: 'c3', score: 6.0, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'below_ev',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 10, maxScore: 10), // 10.00
        difficulty: AssessmentDifficulty.belowLevel,
        assessmentType: AssessmentType.practice,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result = GrowthEngine.calculate(input);
      final b = result.breakdown;

      expect(b.belowLevelAdjustment, isTrue);
      // Standard base is 1000 minor; 25% is 250 minor (2.50 RP)
      expect(b.scoreRpMinor.value, equals(250));
      expect(b.growthRpMinor.value, equals(0)); // disabled!
      expect(b.highPerformerRpMinor.value, equals(0)); // disabled!
      expect(b.personalBestRpMinor.value, equals(0)); // disabled!
      expect(b.difficultyRpMinor.value, equals(0));

      expect(b.totalRpMinor.value, equals(250)); // 2.50 RP
      expect(b.totalRpMinor.formatRp(), equals('2.50'));
      // XP = 10 + 2 * 2.50 = 15 XP (legitimate Study XP earned)
      expect(b.xpAwarded.value, equals(15));
    });

    test('deterministic repeated calculation produces identical results', () {
      final history = [
        makeResult(id: 'c1', score: 7.2, daysAgo: 3),
        makeResult(id: 'c2', score: 7.5, daysAgo: 2),
        makeResult(id: 'c3', score: 8.0, daysAgo: 1),
      ];

      final input = GrowthInput(
        currentEventId: 'rep_ev',
        subjectKey: SubjectKey.math,
        currentScore: NormalizedScore.fromRaw(rawScore: 8.8, maxScore: 10),
        difficulty: AssessmentDifficulty.hard,
        assessmentType: AssessmentType.exam,
        occurredAt: now,
        verifiedAt: now,
        comparableHistory: history,
      );

      final result1 = GrowthEngine.calculate(input);
      final result2 = GrowthEngine.calculate(input);

      expect(result1.breakdown.totalRpMinor.value, equals(result2.breakdown.totalRpMinor.value));
      expect(result1.breakdown.xpAwarded.value, equals(result2.breakdown.xpAwarded.value));
      expect(result1.inputsSnapshot, equals(result2.inputsSnapshot));
    });
  });
}
