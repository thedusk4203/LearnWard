import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/rewards/presentation/child_store_screen.dart';
import 'package:learnward/features/rewards/presentation/parent_fulfillment_inbox_screen.dart';
import 'package:learnward/features/rewards/presentation/parent_reward_catalog_screen.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

class _PresetChildModeNotifier extends ActiveChildModeNotifier {
  _PresetChildModeNotifier(this._preset);
  final ChildProfile? _preset;

  @override
  ChildProfile? build() => _preset;
}

class _PresetActiveFamilyNotifier extends ActiveFamilyNotifier {
  _PresetActiveFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

void main() {
  final testFamily = Family(
    id: FamilyId('fam-001'),
    name: 'The Smiths',
    timezone: 'UTC',
    locale: 'en',
    createdByUserId: 'parent-1',
    createdAt: DateTime.utc(2026, 11, 1),
  );

  final testChild = ChildProfile(
    id: ChildId('child-001'),
    familyId: testFamily.id,
    displayName: 'Alice',
    createdAt: DateTime.utc(2026, 11, 1),
  );

  final testRewardAffordable = Reward(
    id: RewardId('rew-affordable'),
    familyId: testFamily.id,
    title: '30 mins screen time',
    description: 'Extra gaming or cartoon time',
    category: RewardCategory.privilege,
    storeCostMinor: 1000, // 10.00 RP
    storeEnabled: true,
    isActive: true,
    createdAt: DateTime.utc(2026, 11, 1),
    updatedAt: DateTime.utc(2026, 11, 1),
  );

  final testRewardExpensive = Reward(
    id: RewardId('rew-expensive'),
    familyId: testFamily.id,
    title: 'Amusement park trip',
    description: 'Weekend trip to theme park',
    category: RewardCategory.experience,
    storeCostMinor: 5000, // 50.00 RP
    storeEnabled: true,
    isActive: true,
    createdAt: DateTime.utc(2026, 11, 1),
    updatedAt: DateTime.utc(2026, 11, 1),
  );

  group('ChildStoreScreen Widget Tests', () {
    testWidgets('displays child balance and store rewards', (tester) async {
      final inMemoryGrowth = InMemoryGrowthRepository();
      inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
        familyId: testFamily.id,
        childId: testChild.id,
        xpTotal: const XpAmount(100),
        rpBalanceMinor: const RpMinor(2500), // 25.00 RP
        updatedAt: DateTime.utc(2026, 11, 1),
      );

      final inMemoryRewards = InMemoryRewardRepository(
        growthRepository: inMemoryGrowth,
      );
      await inMemoryRewards.createReward(
        familyId: testFamily.id,
        title: testRewardAffordable.title,
        description: testRewardAffordable.description,
        category: testRewardAffordable.category,
        storeCostMinor: testRewardAffordable.storeCostMinor,
        storeEnabled: true,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeFamilyProvider.overrideWith(
              () => _PresetActiveFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetChildModeNotifier(testChild),
            ),
            growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
            rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
          ],
          child: const MaterialApp(home: ChildStoreScreen()),
        ),
      );

      await tester.pumpAndSettle();

      // Verify balance display and reward card
      expect(find.text('25.00 RP'), findsOneWidget);
      expect(find.text('30 mins screen time'), findsOneWidget);
      expect(find.text('10 RP'), findsOneWidget);
    });

    testWidgets(
      'shows confirmation dialog on affordable reward and debits RP balance',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(2500), // 25.00 RP
          updatedAt: DateTime.utc(2026, 11, 1),
        );

        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final createdReward = await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: testRewardAffordable.title,
          description: testRewardAffordable.description,
          category: testRewardAffordable.category,
          storeCostMinor: testRewardAffordable.storeCostMinor,
          storeEnabled: true,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              activeChildModeProvider.overrideWith(
                () => _PresetChildModeNotifier(testChild),
              ),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
            ],
            child: const MaterialApp(home: ChildStoreScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // Tap on the claim button
        final claimButtonFinder = find.byKey(
          Key('redeem_button_${createdReward.id.value}'),
        );
        expect(claimButtonFinder, findsOneWidget);
        await tester.tap(claimButtonFinder);
        await tester.pumpAndSettle();

        // Verify confirmation dialog contents
        expect(
          find.text('Get "30 mins screen time" for 10 RP?'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('confirm_redeem_button')), findsOneWidget);

        // Confirm claim
        await tester.tap(find.byKey(const Key('confirm_redeem_button')));
        await tester.pumpAndSettle();

        // Check remaining balance updated: 25.00 - 10.00 = 15.00 RP
        expect(find.text('15.00 RP'), findsOneWidget);
        expect(find.textContaining('Claimed'), findsOneWidget);
      },
    );

    testWidgets('disables or warns when child has insufficient RP balance', (
      tester,
    ) async {
      final inMemoryGrowth = InMemoryGrowthRepository();
      inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
        familyId: testFamily.id,
        childId: testChild.id,
        xpTotal: const XpAmount(100),
        rpBalanceMinor: const RpMinor(500), // Only 5.00 RP
        updatedAt: DateTime.utc(2026, 11, 1),
      );

      final inMemoryRewards = InMemoryRewardRepository(
        growthRepository: inMemoryGrowth,
      );
      await inMemoryRewards.createReward(
        familyId: testFamily.id,
        title: testRewardExpensive.title,
        description: testRewardExpensive.description,
        category: testRewardExpensive.category,
        storeCostMinor: testRewardExpensive.storeCostMinor,
        storeEnabled: true,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeFamilyProvider.overrideWith(
              () => _PresetActiveFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetChildModeNotifier(testChild),
            ),
            growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
            rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
          ],
          child: const MaterialApp(home: ChildStoreScreen()),
        ),
      );

      await tester.pumpAndSettle();

      // Check insufficient balance indication
      expect(find.text('Need 45 more'), findsOneWidget);
    });

    testWidgets(
      'shows recovery banner for pending redeem command and allows retry',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(5000),
          updatedAt: DateTime.utc(2026, 11, 1),
        );
        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final createdReward = await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: testRewardAffordable.title,
          description: testRewardAffordable.description,
          category: testRewardAffordable.category,
          storeCostMinor: testRewardAffordable.storeCostMinor,
          storeEnabled: true,
        );
        final commandStore = InMemoryPendingRewardCommandStore();
        await commandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.redeemReward,
            commandId: 'pending-cmd-123',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            rewardId: createdReward.id.value,
            actorUserId: 'parent-1',
            createdAt: DateTime.now().toUtc(),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              activeChildModeProvider.overrideWith(
                () => _PresetChildModeNotifier(testChild),
              ),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              pendingRewardCommandStoreProvider.overrideWithValue(commandStore),
            ],
            child: const MaterialApp(home: ChildStoreScreen()),
          ),
        );

        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('pending_redeem_recovery_banner')),
          findsOneWidget,
        );
        expect(
          find.text(
            "We're checking whether your reward request was completed.",
          ),
          findsOneWidget,
        );
        expect(find.text('Checking...'), findsOneWidget);

        await tester.tap(find.byKey(const Key('retry_pending_redeem_button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('pending_redeem_recovery_banner')),
          findsNothing,
        );
        expect(find.text('40.00 RP'), findsOneWidget);
        expect(await commandStore.listPendingCommands(), isEmpty);
      },
    );
  });

  group('ParentRewardCatalogScreen Widget Tests', () {
    testWidgets(
      'renders catalog list and allows toggling reward active status',
      (tester) async {
        final inMemoryRewards = InMemoryRewardRepository();
        final created = await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: testRewardAffordable.title,
          category: testRewardAffordable.category,
          storeCostMinor: testRewardAffordable.storeCostMinor,
          storeEnabled: true,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
            ],
            child: const MaterialApp(home: ParentRewardCatalogScreen()),
          ),
        );

        await tester.pumpAndSettle();

        expect(find.text('Reward Catalog'), findsOneWidget);
        expect(find.text('30 mins screen time'), findsOneWidget);
        final switchFinder = find.byKey(
          Key('toggle_active_${created.id.value}'),
        );
        expect(switchFinder, findsOneWidget);

        // Toggle switch
        await tester.tap(switchFinder);
        await tester.pumpAndSettle();

        final updated = await inMemoryRewards.getReward(
          familyId: testFamily.id,
          rewardId: created.id,
        );
        expect(updated?.isActive, isFalse);
      },
    );
  });

  group('ParentFulfillmentInboxScreen Widget Tests', () {
    testWidgets('renders pending claim, fulfills and completes delivery', (
      tester,
    ) async {
      final inMemoryGrowth = InMemoryGrowthRepository();
      inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
        familyId: testFamily.id,
        childId: testChild.id,
        xpTotal: const XpAmount(100),
        rpBalanceMinor: const RpMinor(5000),
        updatedAt: DateTime.utc(2026, 11, 1),
      );

      final inMemoryRewards = InMemoryRewardRepository(
        growthRepository: inMemoryGrowth,
      );
      final created = await inMemoryRewards.createReward(
        familyId: testFamily.id,
        title: testRewardAffordable.title,
        category: testRewardAffordable.category,
        storeCostMinor: testRewardAffordable.storeCostMinor,
        storeEnabled: true,
      );

      final redemption = await inMemoryRewards.redeemStoreReward(
        commandId: 'cmd-test-1',
        rewardId: created.id,
        childId: testChild.id,
      );

      final inMemoryChildRepo = InMemoryChildProfileRepository();
      inMemoryChildRepo.children.add(testChild);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeFamilyProvider.overrideWith(
              () => _PresetActiveFamilyNotifier(testFamily),
            ),
            rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
            childProfileRepositoryProvider.overrideWithValue(inMemoryChildRepo),
          ],
          child: const MaterialApp(home: ParentFulfillmentInboxScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Fulfillment Inbox'), findsOneWidget);
      expect(find.text('30 mins screen time'), findsOneWidget);
      final fulfillButton = find.byKey(
        Key('fulfill_button_${redemption.id.value}'),
      );
      expect(fulfillButton, findsOneWidget);

      // Fulfill redemption
      await tester.tap(fulfillButton);
      await tester.pumpAndSettle();

      // Check redemption is marked as fulfilled in repository
      final redemptions = await inMemoryRewards.listRedemptions(
        familyId: testFamily.id,
        status: RewardRedemptionStatus.fulfilled,
      );
      expect(redemptions.length, 1);
    });

    testWidgets(
      'cancels pending claim with reason dialog and triggers compensating RP refund',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(1000), // 10.00 RP
          updatedAt: DateTime.utc(2026, 11, 1),
        );

        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final created = await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: testRewardAffordable.title,
          category: testRewardAffordable.category,
          storeCostMinor: testRewardAffordable.storeCostMinor, // 10.00 RP cost
          storeEnabled: true,
        );

        // Child redeems reward: balance debited 10.00 -> 0.00 RP
        final redemption = await inMemoryRewards.redeemStoreReward(
          commandId: 'cmd-test-2',
          rewardId: created.id,
          childId: testChild.id,
        );

        final balanceAfterDebit = await inMemoryGrowth.getChildBalance(
          testChild.id,
        );
        expect(balanceAfterDebit?.rpBalanceMinor.value, 0);

        final inMemoryChildRepo = InMemoryChildProfileRepository();
        inMemoryChildRepo.children.add(testChild);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
              childProfileRepositoryProvider.overrideWithValue(
                inMemoryChildRepo,
              ),
            ],
            child: const MaterialApp(home: ParentFulfillmentInboxScreen()),
          ),
        );

        await tester.pumpAndSettle();

        final cancelButton = find.byKey(
          Key('cancel_button_${redemption.id.value}'),
        );
        expect(cancelButton, findsOneWidget);

        // Tap Cancel
        await tester.tap(cancelButton);
        await tester.pumpAndSettle();

        // Verify cancellation dialog appears
        expect(find.text('Cancel & Refund Reward'), findsOneWidget);
        expect(
          find.textContaining('10 RP will be immediately refunded'),
          findsOneWidget,
        );

        // Enter cancellation reason
        await tester.enterText(
          find.byKey(const Key('cancellation_reason_input')),
          'Game server down today',
        );
        await tester.pumpAndSettle();

        // Submit cancellation
        await tester.tap(find.byKey(const Key('confirm_cancel_button')));
        await tester.pumpAndSettle();

        // Verify redemption status is cancelled in repository
        final redemptions = await inMemoryRewards.listRedemptions(
          familyId: testFamily.id,
          status: RewardRedemptionStatus.cancelled,
        );
        expect(redemptions.length, 1);
        expect(redemptions.first.cancellationReason, 'Game server down today');

        // Verify compensating refund restored child balance to 10.00 RP!
        final refundedBalance = await inMemoryGrowth.getChildBalance(
          testChild.id,
        );
        expect(refundedBalance?.rpBalanceMinor.value, 1000);
      },
    );

    testWidgets(
      'shows recovery banner for pending fulfillment update and allows retry',
      (tester) async {
        final inMemoryRewards = InMemoryRewardRepository();
        final created = await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: 'Book',
          category: RewardCategory.item,
          storeCostMinor: 1000,
          storeEnabled: true,
        );
        final redemption = await inMemoryRewards.redeemStoreReward(
          commandId: 'cmd-pre-1',
          rewardId: created.id,
          childId: testChild.id,
        );

        final commandStore = InMemoryPendingRewardCommandStore();
        await commandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-fulfill-recovery-1',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            actorUserId: 'parent-1',
            actorRole: 'parent',
            redemptionId: redemption.id.value,
            createdAt: DateTime.now().toUtc(),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              childProfileRepositoryProvider.overrideWithValue(
                InMemoryChildProfileRepository()..children.add(testChild),
              ),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              pendingRewardCommandStoreProvider.overrideWithValue(commandStore),
            ],
            child: const MaterialApp(home: ParentFulfillmentInboxScreen()),
          ),
        );

        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('pending_fulfillment_recovery_banner')),
          findsOneWidget,
        );
        expect(
          find.text("We're checking whether a reward update was completed."),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('retry_pending_fulfillment_button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('pending_fulfillment_recovery_banner')),
          findsNothing,
        );
        expect(await commandStore.listPendingCommands(), isEmpty);
      },
    );

    testWidgets(
      'R29-03: multiple pending commands exposes each unresolved command; quarantined entry does not hide retryable entry',
      (tester) async {
        final inMemoryRewards = InMemoryRewardRepository();
        final created1 = await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: 'Reward Item 1',
          category: RewardCategory.privilege,
          storeCostMinor: 1000,
        );
        final created2 = await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: 'Reward Item 2',
          category: RewardCategory.treat,
          storeCostMinor: 2000,
        );

        final redemption1 = await inMemoryRewards.redeemStoreReward(
          commandId: 'cmd-seed-red-1',
          rewardId: created1.id,
          childId: testChild.id,
        );
        final redemption2 = await inMemoryRewards.redeemStoreReward(
          commandId: 'cmd-seed-red-2',
          rewardId: created2.id,
          childId: testChild.id,
        );

        final commandStore = InMemoryPendingRewardCommandStore();

        // Command 1: Quarantined
        await commandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-quarantined-1',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            actorUserId: 'parent-1',
            actorRole: 'parent',
            redemptionId: redemption1.id.value,
            recoveryState: CommandRecoveryState.quarantinedUnknownOutcome,
            dispatchState: CommandDispatchState.possiblyDispatched,
            lastErrorMessage: 'Pending update requires manual review.',
            createdAt: DateTime.now().toUtc(),
          ),
        );

        // Command 2: Active / Retryable
        await commandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.fulfillReward,
            commandId: 'cmd-retryable-2',
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            actorUserId: 'parent-1',
            actorRole: 'parent',
            redemptionId: redemption2.id.value,
            recoveryState: CommandRecoveryState.active,
            dispatchState: CommandDispatchState.possiblyDispatched,
            createdAt: DateTime.now().toUtc(),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              childProfileRepositoryProvider.overrideWithValue(
                InMemoryChildProfileRepository()..children.add(testChild),
              ),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              pendingRewardCommandStoreProvider.overrideWithValue(commandStore),
            ],
            child: const MaterialApp(home: ParentFulfillmentInboxScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // 1. Quarantined command banner is present and has NO retry button
        expect(
          find.byKey(
            const Key('pending_fulfillment_recovery_banner_cmd-quarantined-1'),
          ),
          findsOneWidget,
        );
        expect(
          find.text('Pending update requires manual review.'),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('retry_pending_fulfillment_button_cmd-quarantined-1'),
          ),
          findsNothing,
        );

        // 2. Quarantined entry did NOT hide retryable entry: Command 2 banner is also present with Retry button
        expect(
          find.byKey(
            const Key('pending_fulfillment_recovery_banner_cmd-retryable-2'),
          ),
          findsOneWidget,
        );
        expect(
          find.text("We're checking whether a reward update was completed."),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('retry_pending_fulfillment_button_cmd-retryable-2'),
          ),
          findsOneWidget,
        );

        // 3. Tap retry on command 2
        await tester.tap(
          find.byKey(
            const Key('retry_pending_fulfillment_button_cmd-retryable-2'),
          ),
        );
        await tester.pumpAndSettle();

        // Command 2 resolved and disappeared
        expect(
          find.byKey(
            const Key('pending_fulfillment_recovery_banner_cmd-retryable-2'),
          ),
          findsNothing,
        );

        // Command 1 remains visible and quarantined
        expect(
          find.byKey(
            const Key('pending_fulfillment_recovery_banner_cmd-quarantined-1'),
          ),
          findsOneWidget,
        );
        final remainingCommands = await commandStore.listPendingCommands();
        expect(remainingCommands.length, 1);
        expect(remainingCommands.first.commandId, 'cmd-quarantined-1');
      },
    );
  });
}
