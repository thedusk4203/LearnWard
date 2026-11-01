import 'dart:convert';
import 'dart:io';

import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

File findFixturesFile() {
  final candidate1 = File('fixtures/growth_v01_parity_fixtures.json');
  if (candidate1.existsSync()) return candidate1;
  final candidate2 = File('../../fixtures/growth_v01_parity_fixtures.json');
  if (candidate2.existsSync()) return candidate2;
  final candidate3 = File('../fixtures/growth_v01_parity_fixtures.json');
  if (candidate3.existsSync()) return candidate3;
  throw StateError('Cannot locate fixtures/growth_v01_parity_fixtures.json');
}

void main() {
  group('Growth Engine v0.1 Parity Fixture Matrix (Dart)', () {
    final file = findFixturesFile();
    final jsonContent = file.readAsStringSync();
    final fixtures = (jsonDecode(jsonContent) as List)
        .cast<Map<String, dynamic>>();

    final now = DateTime.utc(2026, 11, 1, 12, 0);

    for (final fixture in fixtures) {
      final id = fixture['id'] as String;
      final description = fixture['description'] as String;
      final current = fixture['current'] as Map<String, dynamic>;
      final historyRaw = (fixture['history'] as List)
          .cast<Map<String, dynamic>>();
      final expected = fixture['expected'] as Map<String, dynamic>;

      test('[$id] $description', () {
        final subjectKey = SubjectKey.parse(current['subject_key'] as String);
        final difficulty = AssessmentDifficulty.fromValue(
          current['difficulty'] as String,
        );
        final assessmentType = AssessmentType.fromValue(
          current['assessment_type'] as String,
        );
        final currentGrade = (current['grade_level'] as num?)?.toInt();
        final rawScore = (current['raw_score'] as num).toDouble();
        final maxScore = (current['max_score'] as num).toDouble();

        final history = historyRaw.map((h) {
          final hId = h['id'] as String;
          final hScore = (h['score'] as num).toDouble();
          final hType = AssessmentType.fromValue(h['type'] as String);
          final hDiff = AssessmentDifficulty.fromValue(
            h['difficulty'] as String,
          );
          final hGrade = (h['grade_level'] as num?)?.toInt();
          final daysAgo = h['days_ago'] as int;

          return ComparableResult(
            id: hId,
            subjectKey: subjectKey,
            normalizedScore: hScore,
            difficulty: hDiff,
            assessmentType: hType,
            gradeLevel: hGrade,
            occurredAt: now.subtract(Duration(days: daysAgo)),
            verifiedAt: now.subtract(Duration(days: daysAgo, minutes: -5)),
          );
        }).toList();

        final input = GrowthInput(
          currentEventId: 'test-event-$id',
          subjectKey: subjectKey,
          currentScore: NormalizedScore.fromRaw(
            rawScore: rawScore,
            maxScore: maxScore,
          ),
          difficulty: difficulty,
          assessmentType: assessmentType,
          gradeLevel: currentGrade,
          occurredAt: now,
          verifiedAt: now.add(const Duration(minutes: 5)),
          comparableHistory: history,
        );

        final result = GrowthEngine.calculate(input);
        final b = result.breakdown;

        expect(
          b.baselineScore,
          equals(
            expected['baseline_score'] != null
                ? (expected['baseline_score'] as num).toDouble()
                : null,
          ),
          reason: '[$id] baselineScore mismatch',
        );
        expect(
          b.baselineSampleCount,
          equals(expected['baseline_sample_count']),
          reason: '[$id] baselineSampleCount mismatch',
        );
        expect(
          b.growthDelta,
          equals(
            expected['growth_delta'] != null
                ? (expected['growth_delta'] as num).toDouble()
                : null,
          ),
          reason: '[$id] growthDelta mismatch',
        );
        expect(
          b.historicalBest,
          equals(
            expected['historical_best'] != null
                ? (expected['historical_best'] as num).toDouble()
                : null,
          ),
          reason: '[$id] historicalBest mismatch',
        );

        expect(
          b.scoreRpMinor.value,
          equals(expected['score_rp_minor']),
          reason: '[$id] scoreRpMinor mismatch',
        );
        expect(
          b.growthRpMinor.value,
          equals(expected['growth_rp_minor']),
          reason: '[$id] growthRpMinor mismatch',
        );
        expect(
          b.highPerformerRpMinor.value,
          equals(expected['high_performer_rp_minor']),
          reason: '[$id] highPerformerRpMinor mismatch',
        );
        expect(
          b.personalBestRpMinor.value,
          equals(expected['personal_best_rp_minor']),
          reason: '[$id] personalBestRpMinor mismatch',
        );
        expect(
          b.difficultyRpMinor.value,
          equals(expected['difficulty_rp_minor']),
          reason: '[$id] difficultyRpMinor mismatch',
        );
        expect(
          b.totalRpMinor.value,
          equals(expected['total_rp_minor']),
          reason: '[$id] totalRpMinor mismatch',
        );
        expect(
          b.xpAwarded.value,
          equals(expected['xp_awarded']),
          reason: '[$id] xpAwarded mismatch',
        );
      });
    }
  });
}
