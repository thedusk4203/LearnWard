import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('SupabaseGrowthRepository Data Mapping', () {
    test('maps growth_events database JSON row to domain GrowthEvent entity', () {
      final Map<String, dynamic> row = {
        'id': 'ge_00000000-0000-0000-0000-000000000001',
        'family_id': 'f0000000-0000-0000-0000-000000000001',
        'child_id': 'c0000000-0000-0000-0000-000000000001',
        'verified_learning_event_id': 'v0000000-0000-0000-0000-000000000001',
        'assessment_id': 'a0000000-0000-0000-0000-000000000001',
        'engine_version': 'growth-v0.1',
        'normalized_score': 7.50,
        'baseline_score': 6.43,
        'baseline_sample_count': 3,
        'growth_delta': 1.07,
        'historical_best': 6.80,
        'score_rp_minor': 750,
        'growth_rp_minor': 200,
        'high_performer_rp_minor': 0,
        'goal_rp_minor': 0,
        'personal_best_rp_minor': 100,
        'difficulty_rp_minor': 100,
        'recovery_rp_minor': 0,
        'below_level_adjustment': false,
        'total_rp_minor': 1150,
        'xp_awarded': 33,
        'inputs_snapshot': {'engine_version': 'growth-v0.1'},
        'created_at': '2026-11-01T12:00:00Z',
      };

      // We test through a helper or reflection/mock
      final event = GrowthEvent(
        id: row['id'] as String,
        familyId: FamilyId(row['family_id'] as String),
        childId: ChildId(row['child_id'] as String),
        verifiedLearningEventId: row['verified_learning_event_id'] as String,
        assessmentId: AssessmentId(row['assessment_id'] as String),
        engineVersion: row['engine_version'] as String,
        normalizedScore: (row['normalized_score'] as num).toDouble(),
        baselineScore: (row['baseline_score'] as num?)?.toDouble(),
        baselineSampleCount: (row['baseline_sample_count'] as num).toInt(),
        growthDelta: (row['growth_delta'] as num?)?.toDouble(),
        historicalBest: (row['historical_best'] as num?)?.toDouble(),
        scoreRpMinor: RpMinor((row['score_rp_minor'] as num).toInt()),
        growthRpMinor: RpMinor((row['growth_rp_minor'] as num).toInt()),
        highPerformerRpMinor: RpMinor((row['high_performer_rp_minor'] as num).toInt()),
        goalRpMinor: RpMinor((row['goal_rp_minor'] as num).toInt()),
        personalBestRpMinor: RpMinor((row['personal_best_rp_minor'] as num).toInt()),
        difficultyRpMinor: RpMinor((row['difficulty_rp_minor'] as num).toInt()),
        recoveryRpMinor: RpMinor((row['recovery_rp_minor'] as num).toInt()),
        belowLevelAdjustment: row['below_level_adjustment'] as bool,
        totalRpMinor: RpMinor((row['total_rp_minor'] as num).toInt()),
        xpAwarded: XpAmount((row['xp_awarded'] as num).toInt()),
        inputsSnapshot: Map<String, dynamic>.from(row['inputs_snapshot'] as Map),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

      expect(event.normalizedScore, equals(7.50));
      expect(event.baselineScore, equals(6.43));
      expect(event.totalRpMinor.value, equals(1150));
      expect(event.totalRpMinor.formatRp(), equals('11.50'));
      expect(event.xpAwarded.value, equals(33));
      expect(event.belowLevelAdjustment, isFalse);
    });

    test('maps child_balances database JSON row to domain ChildBalance entity', () {
      final Map<String, dynamic> row = {
        'family_id': 'f0000000-0000-0000-0000-000000000001',
        'child_id': 'c0000000-0000-0000-0000-000000000001',
        'xp_total': 150,
        'rp_balance_minor': 4250,
        'updated_at': '2026-11-01T12:00:00Z',
      };

      final balance = ChildBalance(
        familyId: FamilyId(row['family_id'] as String),
        childId: ChildId(row['child_id'] as String),
        xpTotal: XpAmount((row['xp_total'] as num).toInt()),
        rpBalanceMinor: RpMinor((row['rp_balance_minor'] as num).toInt()),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

      expect(balance.xpTotal.value, equals(150));
      expect(balance.rpBalanceMinor.value, equals(4250));
      expect(balance.rpBalanceMinor.formatRp(), equals('42.50'));
    });
  });
}
