import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('WheelSettings Domain Entity', () {
    final familyId = FamilyId('fam-123');
    final now = DateTime.now();

    test('instantiates with default values', () {
      final settings = WheelSettings(
        familyId: familyId,
        createdAt: now,
        updatedAt: now,
      );

      expect(settings.spinCostMinor, equals(1000));
      expect(settings.spinCostRp, equals(10.0));
      expect(settings.dailySpinCap, equals(3));
      expect(settings.isEnabled, isTrue);
    });

    test('allows configurable spin cost within 500..5000 minor RP', () {
      final minSettings = WheelSettings(
        familyId: familyId,
        spinCostMinor: 500,
        createdAt: now,
        updatedAt: now,
      );
      expect(minSettings.spinCostRp, equals(5.0));

      final maxSettings = WheelSettings(
        familyId: familyId,
        spinCostMinor: 5000,
        createdAt: now,
        updatedAt: now,
      );
      expect(maxSettings.spinCostRp, equals(50.0));

      expect(
        () => WheelSettings(
          familyId: familyId,
          spinCostMinor: 499,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidWheelException>()),
      );

      expect(
        () => WheelSettings(
          familyId: familyId,
          spinCostMinor: 5001,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidWheelException>()),
      );
    });

    test('allows configurable daily spin cap within 1..5', () {
      final minCap = WheelSettings(
        familyId: familyId,
        dailySpinCap: 1,
        createdAt: now,
        updatedAt: now,
      );
      expect(minCap.dailySpinCap, equals(1));

      final maxCap = WheelSettings(
        familyId: familyId,
        dailySpinCap: 5,
        createdAt: now,
        updatedAt: now,
      );
      expect(maxCap.dailySpinCap, equals(5));

      expect(
        () => WheelSettings(
          familyId: familyId,
          dailySpinCap: 0,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidWheelException>()),
      );

      expect(
        () => WheelSettings(
          familyId: familyId,
          dailySpinCap: 6,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidWheelException>()),
      );
    });

    test('supports JSON roundtrip serialization', () {
      final settings = WheelSettings(
        familyId: familyId,
        spinCostMinor: 2500,
        dailySpinCap: 4,
        isEnabled: false,
        createdAt: DateTime.utc(2026, 11, 2, 12, 0),
        updatedAt: DateTime.utc(2026, 11, 2, 12, 30),
      );

      final json = settings.toJson();
      final restored = WheelSettings.fromJson(json);

      expect(restored.familyId.value, equals('fam-123'));
      expect(restored.spinCostMinor, equals(2500));
      expect(restored.dailySpinCap, equals(4));
      expect(restored.isEnabled, isFalse);
      expect(restored.spinCostRp, equals(25.0));
    });
  });

  group('Wheel Tiers and Relative Probabilities', () {
    test('tiers have fixed canonical relative weights: 60, 30, 10', () {
      expect(WheelTier.common.relativeWeight, equals(60));
      expect(WheelTier.special.relativeWeight, equals(30));
      expect(WheelTier.rare.relativeWeight, equals(10));
    });

    test(
      'calculates proportional probabilities across active eligible pool',
      () {
        // Pool of 4 rewards: 2 common (60 each), 1 special (30), 1 rare (10)
        // Total weight = 60 + 60 + 30 + 10 = 160
        const totalWeight = 160;
        final pCommon = (WheelTier.common.relativeWeight / totalWeight) * 100.0;
        final pSpecial =
            (WheelTier.special.relativeWeight / totalWeight) * 100.0;
        final pRare = (WheelTier.rare.relativeWeight / totalWeight) * 100.0;

        expect(pCommon, closeTo(37.5, 0.01));
        expect(pSpecial, closeTo(18.75, 0.01));
        expect(pRare, closeTo(6.25, 0.01));

        // Sum of probabilities for 2 common + 1 special + 1 rare = 100%
        final totalP = (pCommon * 2) + pSpecial + pRare;
        expect(totalP, closeTo(100.0, 0.01));
      },
    );
  });

  group('Wheel Models & Spin Result Deserialization', () {
    test('parses server-authoritative WheelSpinResult JSON correctly', () {
      final sampleJson = {
        'spin_id': 'sp-001',
        'redemption_id': 'rd-001',
        'family_id': 'fam-001',
        'child_id': 'ch-001',
        'reward_id': 'rw-001',
        'reward_title': '15m Video Game Time',
        'reward_category': 'privilege',
        'reward_icon_key': 'videogame_asset',
        'wheel_tier': 'common',
        'spin_cost_minor': 1000,
        'new_balance_minor': 4000,
        'selection_snapshot': {
          'wheel_config_version': 'wheel-v0.1',
          'spin_cost_minor': 1000,
          'deterministic_ordering': 'reward_id_asc',
          'total_weight': 100,
          'random_draw': 42,
          'winning_reward_id': 'rw-001',
          'ordered_pool': [
            {
              'reward_id': 'rw-001',
              'title': '15m Video Game Time',
              'category': 'privilege',
              'icon_key': 'videogame_asset',
              'tier': 'common',
              'weight': 60,
              'interval_start': 0,
              'interval_end': 60,
              'probability_pct': 60.0,
            },
            {
              'reward_id': 'rw-002',
              'title': 'Ice Cream Treat',
              'category': 'treat',
              'icon_key': 'icecream',
              'tier': 'special',
              'weight': 30,
              'interval_start': 60,
              'interval_end': 90,
              'probability_pct': 30.0,
            },
            {
              'reward_id': 'rw-003',
              'title': 'Movie Night Choice',
              'category': 'experience',
              'icon_key': 'movie',
              'tier': 'rare',
              'weight': 10,
              'interval_start': 90,
              'interval_end': 100,
              'probability_pct': 10.0,
            },
          ],
        },
        'created_at': '2026-11-02T08:00:00.000Z',
      };

      final result = WheelSpinResult.fromJson(sampleJson);

      expect(result.spinId.value, equals('sp-001'));
      expect(result.redemptionId.value, equals('rd-001'));
      expect(result.rewardTitle, equals('15m Video Game Time'));
      expect(result.rewardCategory, equals(RewardCategory.privilege));
      expect(result.wheelTier, equals(WheelTier.common));
      expect(result.spinCostRp, equals(10.0));
      expect(result.newBalanceRp, equals(40.0));

      final snapshot = result.selectionSnapshot;
      expect(snapshot.randomDraw, equals(42));
      expect(snapshot.totalWeight, equals(100));
      expect(snapshot.winningRewardId.value, equals('rw-001'));
      expect(snapshot.orderedPool.length, equals(3));
      expect(snapshot.orderedPool[0].tier, equals(WheelTier.common));
      expect(snapshot.orderedPool[1].tier, equals(WheelTier.special));
      expect(snapshot.orderedPool[2].tier, equals(WheelTier.rare));
    });
  });
}
