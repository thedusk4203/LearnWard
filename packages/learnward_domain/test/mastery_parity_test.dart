import 'dart:convert';
import 'dart:io';

import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

File findFixturesFile() {
  final candidate1 = File('fixtures/learning_v01_parity_fixtures.json');
  if (candidate1.existsSync()) return candidate1;
  final candidate2 = File('../../fixtures/learning_v01_parity_fixtures.json');
  if (candidate2.existsSync()) return candidate2;
  final candidate3 = File('../fixtures/learning_v01_parity_fixtures.json');
  if (candidate3.existsSync()) return candidate3;
  throw StateError('Cannot locate fixtures/learning_v01_parity_fixtures.json');
}

void main() {
  group('Learning Mastery v0.1 Parity Fixture Matrix (Dart)', () {
    final file = findFixturesFile();
    final jsonContent = file.readAsStringSync();
    final fixtures = (jsonDecode(jsonContent) as List)
        .cast<Map<String, dynamic>>();

    final asOf = DateTime.utc(2026, 11, 2, 12, 0);

    for (var i = 0; i < fixtures.length; i++) {
      final fixture = fixtures[i];
      final scenario = fixture['scenario'] as String;
      final nodeType = LearningNodeType.fromValue(
        fixture['node_type'] as String,
      );
      final difficulty = fixture['difficulty_level'] as String? ?? 'standard';
      final rawObservations = (fixture['observations'] as List)
          .cast<Map<String, dynamic>>();
      final expected = fixture['expected'] as Map<String, dynamic>;

      test('[Fixture ${i + 1}] $scenario', () {
        final familyId = FamilyId('fam-001');
        final childId = ChildId('child-001');
        final nodeId = LearningNodeId('node-001');

        final evidenceEvents = <LearningEvidenceEvent>[];
        for (var obsIdx = 0; obsIdx < rawObservations.length; obsIdx++) {
          final obs = rawObservations[obsIdx];
          final perfPct = (obs['performance_pct'] as num).toDouble();
          final offsetDays = (obs['occurred_offset_days'] as num).toInt();
          final diff = obs['difficulty_override'] as String? ?? difficulty;
          final lvlWeight = MasteryEngine.getLevelWeight(diff);

          final occurredAt = asOf.subtract(Duration(days: offsetDays));

          evidenceEvents.add(
            LearningEvidenceEvent(
              id: 'ev-$obsIdx',
              familyId: familyId,
              childId: childId,
              verifiedLearningEventId: 'vle-$obsIdx',
              learningNodeId: nodeId,
              nodeType: nodeType,
              subjectKey: 'math',
              scoreSource: ScoreSource.componentScore,
              performancePct: perfPct,
              specificityWeight: nodeType.specificityWeight,
              levelWeight: lvlWeight,
              effectiveOccurredAt: occurredAt,
              verifiedAt: occurredAt,
            ),
          );
        }

        // Run MasteryEngine rebuild
        final rebuild = MasteryEngine.rebuildNodeMastery(evidenceEvents);
        expect(
          rebuild.masteryScore,
          closeTo((expected['mastery_score'] as num).toDouble(), 0.05),
          reason: 'Mastery score mismatch',
        );

        // Determine if attainment occurred at declaration time (processing)
        DateTime? attainedAt;
        for (var stepIdx = 0; stepIdx < evidenceEvents.length; stepIdx++) {
          final subList = evidenceEvents.sublist(0, stepIdx + 1);
          final stepScore = rebuild.steps[stepIdx].resultScore;
          final stepAsOf = subList.last.verifiedAt;
          final stepEval = ConfidenceEngine.evaluate(
            masteryScore: stepScore,
            evidence: subList,
            asOf: stepAsOf,
          );
          if (attainedAt == null &&
              stepScore >= 85.0 &&
              stepEval.confidenceBand == ConfidenceBand.high &&
              stepEval.distinctRecentVles >= 2) {
            attainedAt = stepAsOf;
          }
        }

        final readMode = fixture['read_mode'] as String?;
        final DateTime readAsOf;
        if (readMode == 'before_attainment') {
          readAsOf = (attainedAt ?? asOf).subtract(const Duration(seconds: 1));
        } else if (readMode == 'aged_61_days') {
          readAsOf = asOf.add(const Duration(days: 61));
        } else {
          readAsOf = asOf;
        }

        // Run ConfidenceEngine evaluation
        final confEval = ConfidenceEngine.evaluate(
          masteryScore: rebuild.masteryScore,
          evidence: evidenceEvents,
          asOf: readAsOf,
          masteryAttainedAt: attainedAt,
        );

        expect(
          confEval.confidenceUnits,
          closeTo((expected['confidence_units'] as num).toDouble(), 0.05),
          reason: 'Confidence units mismatch',
        );
        expect(
          confEval.confidenceBand.value,
          equals(expected['confidence_band']),
          reason: 'Confidence band mismatch',
        );
        expect(
          confEval.masteryBand.value,
          equals(expected['mastery_band']),
          reason: 'Mastery band mismatch',
        );
      });
    }
  });
}
