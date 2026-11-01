import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

class FakeRewardRepository implements RewardRepository {
  final Map<String, Reward> rewards = {};
  final Map<String, RewardRedemption> redemptions = {};
  final Set<String> commandIds = {};

  int createCallCount = 0;
  int updateCallCount = 0;
  int deleteCallCount = 0;
  int redeemCallCount = 0;
  int fulfillCallCount = 0;
  int cancelCallCount = 0;

  @override
  Future<Reward> createReward({
    required FamilyId familyId,
    required String title,
    String? description,
    required RewardCategory category,
    String iconKey = 'default_star',
    bool storeEnabled = true,
    int? storeCostMinor,
    bool wheelEnabled = false,
    WheelTier? wheelTier,
    ChildId? targetChildId,
  }) async {
    createCallCount++;
    final now = DateTime.utc(2026, 11, 1, 12, 0);
    final reward = Reward(
      id: RewardId('rew_${rewards.length + 1}'),
      familyId: familyId,
      title: title,
      description: description,
      category: category,
      iconKey: iconKey,
      storeEnabled: storeEnabled,
      storeCostMinor: storeCostMinor,
      wheelEnabled: wheelEnabled,
      wheelTier: wheelTier,
      targetChildId: targetChildId,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    );
    rewards[reward.id.value] = reward;
    return reward;
  }

  @override
  Future<Reward> updateReward(Reward reward) async {
    updateCallCount++;
    rewards[reward.id.value] = reward;
    return reward;
  }

  @override
  Future<void> deleteReward({
    required FamilyId familyId,
    required RewardId rewardId,
  }) async {
    deleteCallCount++;
    rewards.remove(rewardId.value);
  }

  @override
  Future<Reward?> getReward({
    required FamilyId familyId,
    required RewardId rewardId,
  }) async {
    return rewards[rewardId.value];
  }

  @override
  Future<List<Reward>> listFamilyRewards({
    required FamilyId familyId,
    bool? activeOnly,
  }) async {
    return rewards.values.where((r) {
      if (r.familyId != familyId) return false;
      if (activeOnly == true && !r.isActive) return false;
      return true;
    }).toList();
  }

  @override
  Future<List<Reward>> listStoreRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) async {
    return rewards.values.where((r) {
      if (r.familyId != familyId) return false;
      if (!r.isActive || !r.storeEnabled) return false;
      if (childId != null && !r.isEligibleFor(childId)) return false;
      return true;
    }).toList();
  }

  @override
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) async {
    redeemCallCount++;
    commandIds.add(commandId);
    final reward = rewards[rewardId.value]!;
    final now = DateTime.utc(2026, 11, 1, 12, 0);
    final redemption = RewardRedemption(
      id: RewardRedemptionId('red_${redemptions.length + 1}'),
      familyId: reward.familyId,
      childId: childId,
      rewardId: reward.id,
      origin: RewardOrigin.store,
      rpCostMinor: reward.storeCostMinor ?? 0,
      rewardSnapshot: {
        'title': reward.title,
        'category': reward.category.value,
      },
      status: RewardRedemptionStatus.pendingFulfillment,
      createdAt: now,
      updatedAt: now,
    );
    redemptions[redemption.id.value] = redemption;
    return redemption;
  }

  @override
  Future<RewardRedemption> fulfillRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
  }) async {
    fulfillCallCount++;
    commandIds.add(commandId);
    final existing = redemptions[redemptionId.value]!;
    final updated = existing.copyWith(
      status: RewardRedemptionStatus.fulfilled,
      fulfilledAt: DateTime.utc(2026, 11, 1, 13, 0),
    );
    redemptions[redemptionId.value] = updated;
    return updated;
  }

  @override
  Future<RewardRedemption> cancelRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
    required String cancellationReason,
  }) async {
    cancelCallCount++;
    commandIds.add(commandId);
    final existing = redemptions[redemptionId.value]!;
    final updated = existing.copyWith(
      status: RewardRedemptionStatus.cancelled,
      cancellationReason: cancellationReason,
    );
    redemptions[redemptionId.value] = updated;
    return updated;
  }

  @override
  Future<List<RewardRedemption>> listRedemptions({
    required FamilyId familyId,
    ChildId? childId,
    RewardRedemptionStatus? status,
  }) async {
    return redemptions.values.where((r) {
      if (r.familyId != familyId) return false;
      if (childId != null && r.childId != childId) return false;
      if (status != null && r.status != status) return false;
      return true;
    }).toList();
  }
}

void main() {
  late FakeRewardRepository repository;
  final familyId = FamilyId('fam-001');
  final childId = ChildId('child-001');
  final now = DateTime.utc(2026, 11, 1, 10, 0);

  setUp(() {
    repository = FakeRewardRepository();
  });

  group('Reward Catalog Use Cases', () {
    test(
      'CreateReward, UpdateReward, and DeleteReward call repository',
      () async {
        final create = CreateReward(repository);
        final update = UpdateReward(repository);
        final delete = DeleteReward(repository);

        final created = await create(
          familyId: familyId,
          title: 'Ice cream trip',
          category: RewardCategory.treat,
          storeCostMinor: 500,
          storeEnabled: true,
        );
        expect(repository.createCallCount, 1);
        expect(created.title, 'Ice cream trip');

        final updated = await update(
          created.copyWith(title: 'Ice cream party'),
        );
        expect(repository.updateCallCount, 1);
        expect(updated.title, 'Ice cream party');

        await delete(familyId: familyId, rewardId: created.id);
        expect(repository.deleteCallCount, 1);
        expect(repository.rewards.containsKey(created.id.value), isFalse);
      },
    );

    test('ListFamilyRewards filters active rewards correctly', () async {
      final list = ListFamilyRewards(repository);

      repository.rewards['active-1'] = Reward(
        id: RewardId('active-1'),
        familyId: familyId,
        title: 'Active Reward',
        category: RewardCategory.privilege,
        storeCostMinor: 200,
        storeEnabled: true,
        isActive: true,
        createdAt: now,
        updatedAt: now,
      );

      repository.rewards['inactive-1'] = Reward(
        id: RewardId('inactive-1'),
        familyId: familyId,
        title: 'Inactive Reward',
        category: RewardCategory.privilege,
        storeCostMinor: 200,
        storeEnabled: true,
        isActive: false,
        createdAt: now,
        updatedAt: now,
      );

      final all = await list(familyId: familyId);
      expect(all.length, 2);

      final activeOnly = await list(familyId: familyId, activeOnly: true);
      expect(activeOnly.length, 1);
      expect(activeOnly.first.id.value, 'active-1');
    });

    test(
      'ListStoreRewards returns only store-eligible rewards for the child',
      () async {
        final listStore = ListStoreRewards(repository);

        // Eligible reward
        repository.rewards['store-1'] = Reward(
          id: RewardId('store-1'),
          familyId: familyId,
          title: 'Eligible Item',
          category: RewardCategory.item,
          storeCostMinor: 1000,
          storeEnabled: true,
          isActive: true,
          createdAt: now,
          updatedAt: now,
        );

        // Inactive
        repository.rewards['store-2'] = Reward(
          id: RewardId('store-2'),
          familyId: familyId,
          title: 'Inactive Item',
          category: RewardCategory.item,
          storeCostMinor: 1000,
          storeEnabled: true,
          isActive: false,
          createdAt: now,
          updatedAt: now,
        );

        // Targeted to another child
        repository.rewards['store-3'] = Reward(
          id: RewardId('store-3'),
          familyId: familyId,
          title: 'Other Child Item',
          category: RewardCategory.item,
          storeCostMinor: 1000,
          storeEnabled: true,
          isActive: true,
          targetChildId: ChildId('other-child'),
          createdAt: now,
          updatedAt: now,
        );

        final storeRewards = await listStore(
          familyId: familyId,
          childId: childId,
        );

        expect(storeRewards.length, 1);
        expect(storeRewards.first.id.value, 'store-1');
      },
    );
  });

  group('Reward Redemption Use Cases', () {
    test(
      'RedeemStoreReward creates pending redemption and forwards commandId',
      () async {
        final redeem = RedeemStoreReward(repository);

        repository.rewards['rew-10'] = Reward(
          id: RewardId('rew-10'),
          familyId: familyId,
          title: 'Book purchase',
          category: RewardCategory.item,
          storeCostMinor: 1500,
          storeEnabled: true,
          isActive: true,
          createdAt: now,
          updatedAt: now,
        );

        final redemption = await redeem(
          commandId: 'cmd-redeem-1',
          rewardId: RewardId('rew-10'),
          childId: childId,
        );

        expect(repository.redeemCallCount, 1);
        expect(redemption.status, RewardRedemptionStatus.pendingFulfillment);
        expect(redemption.rpCostMinor, 1500);
        expect(repository.commandIds.contains('cmd-redeem-1'), isTrue);
      },
    );

    test('FulfillRewardRedemption completes delivery', () async {
      final fulfill = FulfillRewardRedemption(repository);

      final redId = RewardRedemptionId('red-1');
      repository.redemptions[redId.value] = RewardRedemption(
        id: redId,
        familyId: familyId,
        childId: childId,
        rewardId: RewardId('rew-1'),
        origin: RewardOrigin.store,
        rpCostMinor: 1000,
        rewardSnapshot: const {'title': 'Reward'},
        status: RewardRedemptionStatus.pendingFulfillment,
        createdAt: now,
        updatedAt: now,
      );

      final fulfilled = await fulfill(
        commandId: 'cmd-fulfill-1',
        redemptionId: redId,
      );

      expect(repository.fulfillCallCount, 1);
      expect(fulfilled.status, RewardRedemptionStatus.fulfilled);
      expect(fulfilled.isTerminal, isTrue);
      expect(repository.commandIds.contains('cmd-fulfill-1'), isTrue);
    });

    test('CancelRewardRedemption cancels and records reason', () async {
      final cancel = CancelRewardRedemption(repository);

      final redId = RewardRedemptionId('red-2');
      repository.redemptions[redId.value] = RewardRedemption(
        id: redId,
        familyId: familyId,
        childId: childId,
        rewardId: RewardId('rew-2'),
        origin: RewardOrigin.store,
        rpCostMinor: 500,
        rewardSnapshot: const {'title': 'Reward 2'},
        status: RewardRedemptionStatus.pendingFulfillment,
        createdAt: now,
        updatedAt: now,
      );

      final cancelled = await cancel(
        commandId: 'cmd-cancel-1',
        redemptionId: redId,
        cancellationReason: 'Event rained out',
      );

      expect(repository.cancelCallCount, 1);
      expect(cancelled.status, RewardRedemptionStatus.cancelled);
      expect(cancelled.cancellationReason, 'Event rained out');
      expect(repository.commandIds.contains('cmd-cancel-1'), isTrue);
    });

    test(
      'ListRewardRedemptions queries by family, child, and status filter',
      () async {
        final list = ListRewardRedemptions(repository);

        repository.redemptions['r1'] = RewardRedemption(
          id: RewardRedemptionId('r1'),
          familyId: familyId,
          childId: childId,
          rewardId: RewardId('rew-1'),
          origin: RewardOrigin.store,
          rpCostMinor: 100,
          rewardSnapshot: const {'title': 'R1'},
          status: RewardRedemptionStatus.pendingFulfillment,
          createdAt: now,
          updatedAt: now,
        );

        repository.redemptions['r2'] = RewardRedemption(
          id: RewardRedemptionId('r2'),
          familyId: familyId,
          childId: childId,
          rewardId: RewardId('rew-2'),
          origin: RewardOrigin.store,
          rpCostMinor: 200,
          rewardSnapshot: const {'title': 'R2'},
          status: RewardRedemptionStatus.fulfilled,
          createdAt: now,
          updatedAt: now,
        );

        final pendingOnly = await list(
          familyId: familyId,
          status: RewardRedemptionStatus.pendingFulfillment,
        );
        expect(pendingOnly.length, 1);
        expect(pendingOnly.first.id.value, 'r1');

        final allForChild = await list(familyId: familyId, childId: childId);
        expect(allForChild.length, 2);
      },
    );
  });
}
