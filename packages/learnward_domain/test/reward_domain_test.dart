import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('RewardEnums', () {
    test('RewardCategory fromString parses canonical and rejects unknown', () {
      expect(
        RewardCategory.fromString('privilege'),
        equals(RewardCategory.privilege),
      );
      expect(
        RewardCategory.fromString('experience'),
        equals(RewardCategory.experience),
      );
      expect(RewardCategory.fromString('item'), equals(RewardCategory.item));
      expect(
        RewardCategory.fromString('custom'),
        equals(RewardCategory.custom),
      );
      expect(
        () => RewardCategory.fromString('invalid'),
        throwsA(isA<InvalidRewardException>()),
      );
    });

    test('WheelTier fromString parses canonical and rejects unknown', () {
      expect(WheelTier.fromString('common'), equals(WheelTier.common));
      expect(WheelTier.fromString('special'), equals(WheelTier.special));
      expect(WheelTier.fromString('rare'), equals(WheelTier.rare));
      expect(
        () => WheelTier.fromString('legendary'),
        throwsA(isA<InvalidRewardException>()),
      );
    });

    test('RewardOrigin fromString parses canonical and rejects unknown', () {
      expect(RewardOrigin.fromString('store'), equals(RewardOrigin.store));
      expect(RewardOrigin.fromString('wheel'), equals(RewardOrigin.wheel));
      expect(
        () => RewardOrigin.fromString('lootbox'),
        throwsA(isA<InvalidRedemptionException>()),
      );
    });

    test(
      'RewardRedemptionStatus fromString parses and identifies terminal states',
      () {
        expect(
          RewardRedemptionStatus.fromString('pending_fulfillment'),
          equals(RewardRedemptionStatus.pendingFulfillment),
        );
        expect(
          RewardRedemptionStatus.fromString('fulfilled'),
          equals(RewardRedemptionStatus.fulfilled),
        );
        expect(
          RewardRedemptionStatus.fromString('cancelled'),
          equals(RewardRedemptionStatus.cancelled),
        );

        expect(RewardRedemptionStatus.pendingFulfillment.isTerminal, isFalse);
        expect(RewardRedemptionStatus.fulfilled.isTerminal, isTrue);
        expect(RewardRedemptionStatus.cancelled.isTerminal, isTrue);
      },
    );
  });

  group('Reward Entity', () {
    final familyId = FamilyId('fam-001');
    final childId = ChildId('child-001');
    final now = DateTime.utc(2026, 11, 1, 12, 0);

    test('creates valid reward with defaults', () {
      final reward = Reward(
        id: RewardId('rew-001'),
        familyId: familyId,
        title: '30 mins extra gaming',
        description: 'Enjoy extra console time',
        category: RewardCategory.privilege,
        storeCostMinor: 1000,
        storeEnabled: true,
        wheelEnabled: false,
        isActive: true,
        createdAt: now,
        updatedAt: now,
      );

      expect(reward.title, '30 mins extra gaming');
      expect(reward.storeCostRp, 10.0);
      expect(reward.storeCostMinor, 1000);
      expect(reward.isEligibleFor(childId), isTrue);
    });

    test('rejects empty or single char title', () {
      expect(
        () => Reward(
          id: RewardId('rew-001'),
          familyId: familyId,
          title: 'A',
          category: RewardCategory.privilege,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidRewardException>()),
      );
    });

    test('rejects title longer than 100 chars', () {
      expect(
        () => Reward(
          id: RewardId('rew-001'),
          familyId: familyId,
          title: 'A' * 101,
          category: RewardCategory.privilege,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidRewardException>()),
      );
    });

    test('rejects negative or zero store cost when storeEnabled', () {
      expect(
        () => Reward(
          id: RewardId('rew-001'),
          familyId: familyId,
          title: 'Valid Title',
          category: RewardCategory.privilege,
          storeEnabled: true,
          storeCostMinor: -500,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidRewardException>()),
      );

      expect(
        () => Reward(
          id: RewardId('rew-001'),
          familyId: familyId,
          title: 'Valid Title',
          category: RewardCategory.privilege,
          storeEnabled: true,
          storeCostMinor: 0,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidRewardException>()),
      );
    });

    test('rejects wheelEnabled=true without wheelTier', () {
      expect(
        () => Reward(
          id: RewardId('rew-001'),
          familyId: familyId,
          title: 'Valid Title',
          category: RewardCategory.privilege,
          wheelEnabled: true,
          wheelTier: null,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidRewardException>()),
      );
    });

    test('child eligibility respects targetChildId', () {
      final targetedReward = Reward(
        id: RewardId('rew-001'),
        familyId: familyId,
        title: 'Special privilege',
        category: RewardCategory.privilege,
        storeCostMinor: 1000,
        targetChildId: childId,
        createdAt: now,
        updatedAt: now,
      );

      expect(targetedReward.isEligibleFor(childId), isTrue);
      expect(targetedReward.isEligibleFor(ChildId('other-child')), isFalse);
    });

    test('copyWith preserves properties and updates specified', () {
      final reward = Reward(
        id: RewardId('rew-001'),
        familyId: familyId,
        title: 'Original Title',
        category: RewardCategory.privilege,
        storeCostMinor: 1000,
        storeEnabled: true,
        createdAt: now,
        updatedAt: now,
      );

      final updated = reward.copyWith(
        title: 'Updated Title',
        storeCostMinor: 1500,
      );

      expect(updated.title, 'Updated Title');
      expect(updated.storeCostRp, 15.0);
      expect(updated.storeCostMinor, 1500);
      expect(updated.category, RewardCategory.privilege);
    });
  });

  group('RewardRedemption Entity', () {
    final familyId = FamilyId('fam-001');
    final childId = ChildId('child-001');
    final rewardId = RewardId('rew-001');
    final redemptionId = RewardRedemptionId('red-001');
    final now = DateTime.utc(2026, 11, 1, 12, 0);

    test('creates pending redemption with valid parameters', () {
      final redemption = RewardRedemption(
        id: redemptionId,
        familyId: familyId,
        childId: childId,
        rewardId: rewardId,
        origin: RewardOrigin.store,
        rpCostMinor: 1000,
        rewardSnapshot: const {
          'title': '30 mins extra gaming',
          'category': 'privilege',
        },
        status: RewardRedemptionStatus.pendingFulfillment,
        createdAt: now,
        updatedAt: now,
      );

      expect(redemption.status, RewardRedemptionStatus.pendingFulfillment);
      expect(redemption.rpCostMinor, 1000);
      expect(redemption.rpCost, 10.0);
      expect(redemption.isTerminal, isFalse);
    });

    test('rejects negative rpCostMinor', () {
      expect(
        () => RewardRedemption(
          id: redemptionId,
          familyId: familyId,
          childId: childId,
          rewardId: rewardId,
          origin: RewardOrigin.store,
          rpCostMinor: -100,
          rewardSnapshot: const {'title': 'Invalid'},
          status: RewardRedemptionStatus.pendingFulfillment,
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidRedemptionException>()),
      );
    });

    test('transitions to fulfilled properly', () {
      final pending = RewardRedemption(
        id: redemptionId,
        familyId: familyId,
        childId: childId,
        rewardId: rewardId,
        origin: RewardOrigin.store,
        rpCostMinor: 1000,
        rewardSnapshot: const {'title': 'Gaming time'},
        status: RewardRedemptionStatus.pendingFulfillment,
        createdAt: now,
        updatedAt: now,
      );

      final fulfilled = pending.copyWith(
        status: RewardRedemptionStatus.fulfilled,
        fulfilledAt: now.add(const Duration(hours: 1)),
        updatedAt: now.add(const Duration(hours: 1)),
      );

      expect(fulfilled.status, RewardRedemptionStatus.fulfilled);
      expect(fulfilled.isTerminal, isTrue);
      expect(fulfilled.fulfilledAt, isNotNull);
    });

    test('transitions to cancelled with reason properly', () {
      final pending = RewardRedemption(
        id: redemptionId,
        familyId: familyId,
        childId: childId,
        rewardId: rewardId,
        origin: RewardOrigin.store,
        rpCostMinor: 1000,
        rewardSnapshot: const {'title': 'Gaming time'},
        status: RewardRedemptionStatus.pendingFulfillment,
        createdAt: now,
        updatedAt: now,
      );

      final cancelled = pending.copyWith(
        status: RewardRedemptionStatus.cancelled,
        cancellationReason: 'Console broken, refunded RP',
        updatedAt: now.add(const Duration(hours: 1)),
      );

      expect(cancelled.status, RewardRedemptionStatus.cancelled);
      expect(cancelled.isTerminal, isTrue);
      expect(cancelled.cancellationReason, 'Console broken, refunded RP');
    });

    test('rejects cancelled redemption without valid reason', () {
      expect(
        () => RewardRedemption(
          id: redemptionId,
          familyId: familyId,
          childId: childId,
          rewardId: rewardId,
          origin: RewardOrigin.store,
          rpCostMinor: 1000,
          rewardSnapshot: const {'title': 'Gaming time'},
          status: RewardRedemptionStatus.cancelled,
          cancellationReason: '',
          createdAt: now,
          updatedAt: now,
        ),
        throwsA(isA<InvalidRedemptionException>()),
      );
    });
  });
}
