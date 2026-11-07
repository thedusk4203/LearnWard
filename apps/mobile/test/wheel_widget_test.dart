import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/rewards/presentation/child_wheel_screen.dart';
import 'package:learnward/features/rewards/presentation/parent_reward_form_screen.dart';
import 'package:learnward/features/rewards/presentation/parent_wheel_settings_screen.dart';
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
    id: FamilyId('fam-wheel-test-1'),
    name: 'Wheel Family',
    timezone: 'UTC',
    locale: 'en',
    createdByUserId: 'parent-1',
    createdAt: DateTime.utc(2026, 11, 1),
  );

  final testChild = ChildProfile(
    id: ChildId('child-wheel-test-1'),
    familyId: testFamily.id,
    displayName: 'Sammy',
    createdAt: DateTime.utc(2026, 11, 1),
  );

  final now = DateTime.utc(2026, 11, 2);

  final poolReward1 = Reward(
    id: RewardId('rw-1'),
    familyId: testFamily.id,
    title: '15m Video Game Time',
    category: RewardCategory.privilege,
    storeEnabled: false,
    wheelEnabled: true,
    wheelTier: WheelTier.common,
    createdAt: now,
    updatedAt: now,
  );

  final poolReward2 = Reward(
    id: RewardId('rw-2'),
    familyId: testFamily.id,
    title: 'Ice Cream Treat',
    category: RewardCategory.treat,
    storeEnabled: true,
    storeCostMinor: 1500,
    wheelEnabled: true,
    wheelTier: WheelTier.special,
    createdAt: now,
    updatedAt: now,
  );

  final poolReward3 = Reward(
    id: RewardId('rw-3'),
    familyId: testFamily.id,
    title: 'Movie Night Pick',
    category: RewardCategory.experience,
    storeEnabled: false,
    wheelEnabled: true,
    wheelTier: WheelTier.rare,
    createdAt: now,
    updatedAt: now,
  );

  group('ParentWheelSettingsScreen Widget Tests', () {
    testWidgets(
      'renders current settings, allows adjusting spin cost and daily cap, and saves',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final inMemoryWheel = InMemoryWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
        );

        // Seed 3 active wheel rewards
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward1.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward2.title,
          category: poolReward2.category,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: poolReward2.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward3.title,
          category: poolReward3.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward3.wheelTier,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              wheelRepositoryProvider.overrideWithValue(inMemoryWheel),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
            ],
            child: const MaterialApp(home: ParentWheelSettingsScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // Verify initial defaults (10 RP, 3 spins/day, enabled)
        expect(find.text('Enable Celebration Wheel'), findsOneWidget);
        expect(find.byKey(const Key('wheel_enabled_switch')), findsOneWidget);
        expect(find.byKey(const Key('wheel_spin_cost_text')), findsOneWidget);
        expect(find.text('10 RP'), findsOneWidget);
        expect(find.byKey(const Key('wheel_daily_cap_text')), findsOneWidget);
        expect(find.text('3 spins / day'), findsOneWidget);

        // Stepper interaction: increase spin cost
        await tester.tap(
          find.byKey(const Key('wheel_spin_cost_stepper_increase')),
        );
        await tester.pumpAndSettle();
        expect(find.text('11 RP'), findsOneWidget);

        // Stepper interaction: increase daily cap
        await tester.tap(find.byKey(const Key('wheel_daily_cap_increase')));
        await tester.pumpAndSettle();
        expect(find.text('4 spins / day'), findsOneWidget);

        // Toggle switch to disable
        await tester.tap(find.byKey(const Key('wheel_enabled_switch')));
        await tester.pumpAndSettle();

        // Tap Save
        await tester.ensureVisible(
          find.byKey(const Key('wheel_settings_save_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('wheel_settings_save_button')));
        await tester.pumpAndSettle();

        // Verify saved in repository
        final savedSettings = await inMemoryWheel.getWheelSettings(
          familyId: testFamily.id,
        );
        expect(savedSettings.spinCostMinor, equals(1100));
        expect(savedSettings.dailySpinCap, equals(4));
        expect(savedSettings.isEnabled, isFalse);
      },
    );

    testWidgets(
      'shows warning banner when active wheel pool has fewer than 3 rewards',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final inMemoryWheel = InMemoryWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
        );

        // Seed only 1 reward (less than 3)
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward1.wheelTier,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              wheelRepositoryProvider.overrideWithValue(inMemoryWheel),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
            ],
            child: const MaterialApp(home: ParentWheelSettingsScreen()),
          ),
        );

        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('wheel_pool_warning_banner')),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'At least 3 active Wheel rewards must be configured before any child can spin',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'displays relative tier weights and eligibility disclaimer without false aggregate percentages when siblings have targeted rewards',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final inMemoryWheel = InMemoryWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
        );

        // Seed:
        // Reward 1: Family-wide Common
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.common,
        );
        // Reward 2: Targeted to Child 1 (Special)
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          targetChildId: testChild.id,
          title: poolReward2.title,
          category: poolReward2.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.special,
        );
        // Reward 3: Targeted to Sibling (Child 2) (Rare)
        final siblingId = ChildId('child-sibling-2');
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          targetChildId: siblingId,
          title: poolReward3.title,
          category: poolReward3.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.rare,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserIdProvider.overrideWithValue('parent-1'),
              activeFamilyProvider.overrideWith(
                () => _PresetActiveFamilyNotifier(testFamily),
              ),
              wheelRepositoryProvider.overrideWithValue(inMemoryWheel),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
            ],
            child: const MaterialApp(home: ParentWheelSettingsScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // Verify truthful configured title and count
        expect(find.text('Configured Wheel Rewards'), findsOneWidget);
        expect(find.text('3 active Wheel rewards configured'), findsOneWidget);

        // Invariant: ZERO false family-wide "eligible pool" or "ready to spin" claims
        expect(find.textContaining('eligible pool'), findsNothing);
        expect(find.textContaining('Ready to spin'), findsNothing);
        expect(find.textContaining('valid pool'), findsNothing);

        // Verify tier items and weights are displayed
        expect(
          find.text('Common — weight 60 — 1 configured items'),
          findsOneWidget,
        );
        expect(
          find.text('Special — weight 30 — 1 configured items'),
          findsOneWidget,
        );
        expect(
          find.text('Rare — weight 10 — 1 configured items'),
          findsOneWidget,
        );

        // Verify eligibility disclaimer and per-child rule note
        expect(
          find.text(
            'Actual probability depends on which rewards are eligible for each child.',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Each child needs at least 3 active rewards that are eligible for them before they can spin.',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Child-targeted rewards count only for that child.',
          ),
          findsOneWidget,
        );

        // Invariant: ZERO misleading family-wide percentages
        expect(find.textContaining('% chance'), findsNothing);
      },
    );
  });

  group('ParentRewardFormScreen Wheel Controls Widget Tests', () {
    testWidgets('allows configuring wheel tier when wheel is enabled', (
      tester,
    ) async {
      final inMemoryRewards = InMemoryRewardRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeFamilyProvider.overrideWith(
              () => _PresetActiveFamilyNotifier(testFamily),
            ),
            rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
          ],
          child: const MaterialApp(home: ParentRewardFormScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('reward_wheel_enabled_switch')),
        findsOneWidget,
      );
      // Initially wheel tier dropdown is not visible because wheel is disabled by default
      expect(find.byKey(const Key('reward_wheel_tier_dropdown')), findsNothing);

      // Toggle wheel enabled switch
      await tester.ensureVisible(
        find.byKey(const Key('reward_wheel_enabled_switch')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reward_wheel_enabled_switch')));
      await tester.pumpAndSettle();

      // Dropdown is now visible
      expect(
        find.byKey(const Key('reward_wheel_tier_dropdown')),
        findsOneWidget,
      );
    });
  });

  group('ChildWheelScreen Widget Tests', () {
    testWidgets(
      'renders balance, spins today, and handles confirmed spin flow',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(5000), // 50.00 RP
          updatedAt: now,
        );

        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final inMemoryWheel = InMemoryWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
        );

        // Seed 3 active eligible wheel rewards
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward1.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward2.title,
          category: poolReward2.category,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: poolReward2.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward3.title,
          category: poolReward3.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward3.wheelTier,
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
              wheelRepositoryProvider.overrideWithValue(inMemoryWheel),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
            ],
            child: const MaterialApp(home: ChildWheelScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // Check balance text and daily quota text
        expect(
          find.byKey(const Key('child_wheel_balance_text')),
          findsOneWidget,
        );
        expect(find.text('50 RP'), findsOneWidget);
        expect(
          find.byKey(const Key('child_wheel_daily_cap_text')),
          findsOneWidget,
        );
        expect(find.text('0 / 3 spins'), findsOneWidget);

        // Spin button should be enabled
        final spinButtonFinder = find.byKey(const Key('spin_wheel_button'));
        expect(spinButtonFinder, findsOneWidget);
        expect(tester.widget<FilledButton>(spinButtonFinder).enabled, isTrue);

        // 1. Tap Spin Wheel -> shows confirmation dialog
        await tester.tap(spinButtonFinder);
        await tester.pumpAndSettle();

        expect(find.text('Spin the Celebration Wheel?'), findsOneWidget);
        expect(find.byKey(const Key('cancel_spin_button')), findsOneWidget);
        expect(find.byKey(const Key('confirm_spin_button')), findsOneWidget);

        // 2. Tap Confirm & Spin -> server commits, animation runs
        await tester.tap(find.byKey(const Key('confirm_spin_button')));
        await tester.pump();
        await tester.pump();

        // Fast forward animation
        await tester.pump(const Duration(milliseconds: 3600));
        await tester.pumpAndSettle();

        // Celebration dialog should appear
        expect(find.text('You Won a Prize!'), findsOneWidget);
        expect(
          find.byKey(const Key('claim_dialog_close_button')),
          findsOneWidget,
        );

        // Close celebration dialog
        await tester.tap(find.byKey(const Key('claim_dialog_close_button')));
        await tester.pumpAndSettle();

        // Verify updated spins count (1 / 3 spins) and debited balance
        expect(find.text('1 / 3 spins'), findsOneWidget);
      },
    );

    testWidgets('disables spin button when child has insufficient RP balance', (
      tester,
    ) async {
      final inMemoryGrowth = InMemoryGrowthRepository();
      inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
        familyId: testFamily.id,
        childId: testChild.id,
        xpTotal: const XpAmount(100),
        rpBalanceMinor: const RpMinor(500), // 5.00 RP < 10.00 RP cost
        updatedAt: now,
      );

      final inMemoryRewards = InMemoryRewardRepository(
        growthRepository: inMemoryGrowth,
      );
      final inMemoryWheel = InMemoryWheelRepository(
        rewardRepository: inMemoryRewards,
        growthRepository: inMemoryGrowth,
      );

      await inMemoryRewards.createReward(
        familyId: testFamily.id,
        title: poolReward1.title,
        category: poolReward1.category,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: poolReward1.wheelTier,
      );
      await inMemoryRewards.createReward(
        familyId: testFamily.id,
        title: poolReward2.title,
        category: poolReward2.category,
        storeCostMinor: 1500,
        wheelEnabled: true,
        wheelTier: poolReward2.wheelTier,
      );
      await inMemoryRewards.createReward(
        familyId: testFamily.id,
        title: poolReward3.title,
        category: poolReward3.category,
        storeEnabled: false,
        wheelEnabled: true,
        wheelTier: poolReward3.wheelTier,
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
            wheelRepositoryProvider.overrideWithValue(inMemoryWheel),
            rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
            growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
          ],
          child: const MaterialApp(home: ChildWheelScreen()),
        ),
      );

      await tester.pumpAndSettle();

      final spinButtonFinder = find.byKey(const Key('spin_wheel_button'));
      expect(tester.widget<FilledButton>(spinButtonFinder).enabled, isFalse);
      expect(find.text('Need 10 RP to Spin'), findsOneWidget);
    });

    testWidgets(
      'animates using server-committed snapshot pool and lands on winner even if pool differed from local preview',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(5000), // 50.00 RP
          updatedAt: now,
        );

        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );

        // Seed initial 3 rewards (A, B, C) that client initially sees in preview
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward1.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward2.title,
          category: poolReward2.category,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: poolReward2.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward3.title,
          category: poolReward3.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward3.wheelTier,
        );

        // Server has concurrently changed the pool: reward 2 disabled, reward 4 added, winner is 4
        final rewardD = Reward(
          id: RewardId('rw-4'),
          familyId: testFamily.id,
          title: 'Bonus Book Pick',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.special,
          createdAt: now,
          updatedAt: now,
        );

        final serverCommittedSnapshot = WheelSelectionSnapshot(
          wheelConfigVersion: 'wheel-v0.1',
          spinCostMinor: 1000,
          deterministicOrdering: 'reward_id_asc',
          totalWeight: 150,
          randomDraw: 120,
          winningRewardId: rewardD.id,
          orderedPool: [
            WheelPoolItem(
              rewardId: poolReward1.id,
              title: poolReward1.title,
              category: poolReward1.category,
              iconKey: poolReward1.iconKey,
              tier: WheelTier.common,
              weight: 60,
              intervalStart: 0,
              intervalEnd: 60,
              probabilityPct: 40.0,
            ),
            WheelPoolItem(
              rewardId: poolReward3.id,
              title: poolReward3.title,
              category: poolReward3.category,
              iconKey: poolReward3.iconKey,
              tier: WheelTier.rare,
              weight: 30,
              intervalStart: 60,
              intervalEnd: 90,
              probabilityPct: 20.0,
            ),
            WheelPoolItem(
              rewardId: rewardD.id,
              title: rewardD.title,
              category: rewardD.category,
              iconKey: rewardD.iconKey,
              tier: WheelTier.special,
              weight: 60,
              intervalStart: 90,
              intervalEnd: 150,
              probabilityPct: 40.0,
            ),
          ],
        );

        final serverResult = WheelSpinResult(
          spinId: WheelSpinId('spin-committed-d'),
          redemptionId: RewardRedemptionId('red-committed-d'),
          familyId: testFamily.id,
          childId: testChild.id,
          rewardId: rewardD.id,
          rewardTitle: rewardD.title,
          rewardCategory: rewardD.category,
          rewardIconKey: rewardD.iconKey,
          wheelTier: WheelTier.special,
          spinCostMinor: 1000,
          newBalanceMinor: 4000,
          selectionSnapshot: serverCommittedSnapshot,
          createdAt: now,
        );

        final baseRepo = InMemoryWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
        );
        final changingRepo = _ChangingPoolWheelRepository(
          delegate: baseRepo,
          committedResult: serverResult,
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
              wheelRepositoryProvider.overrideWithValue(changingRepo),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
            ],
            child: const MaterialApp(home: ChildWheelScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // Spin
        await tester.tap(find.byKey(const Key('spin_wheel_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm_spin_button')));
        await tester.pump();
        await tester.pump();

        // Advance animation
        await tester.pump(const Duration(milliseconds: 3600));
        await tester.pumpAndSettle();

        // Verify winner dialog shows rewardD ('Bonus Book Pick')
        expect(find.text('Bonus Book Pick'), findsOneWidget);
        expect(find.text('Special Prize'), findsOneWidget);

        await tester.tap(find.byKey(const Key('claim_dialog_close_button')));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'durable pending-spin recovery: recovers interrupted spin without double-debit or losing intent',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(5000), // 50.00 RP
          updatedAt: now,
        );

        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final inMemoryWheel = InMemoryWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
        );
        final commandStore = InMemoryPendingRewardCommandStore();

        // Seed 3 rewards
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward1.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward2.title,
          category: poolReward2.category,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: poolReward2.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward3.title,
          category: poolReward3.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward3.wheelTier,
        );

        // Pre-seed an interrupted pending spin in the local durable journal
        const interruptedCommandId = 'interrupted-spin-uuid-1';
        await commandStore.savePendingCommand(
          PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: interruptedCommandId,
            familyId: testFamily.id.value,
            childId: testChild.id.value,
            actorUserId: 'parent-1',
            createdAt: now,
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
              wheelRepositoryProvider.overrideWithValue(inMemoryWheel),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
              pendingRewardCommandStoreProvider.overrideWithValue(commandStore),
            ],
            child: const MaterialApp(home: ChildWheelScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // Verify recovery banner is prominently shown
        expect(
          find.byKey(const Key('pending_spin_recovery_card')),
          findsOneWidget,
        );
        expect(
          find.text("We're checking whether your spin was completed."),
          findsOneWidget,
        );

        // Verify normal spin button is blocked while pending command exists
        final spinButtonFinder = find.byKey(const Key('spin_wheel_button'));
        expect(tester.widget<FilledButton>(spinButtonFinder).enabled, isFalse);
        expect(find.text('Resolve Interrupted Spin First'), findsOneWidget);

        // Tap Check / Retry Spin
        final retryButtonFinder = find.byKey(
          const Key('retry_pending_spin_button'),
        );
        expect(retryButtonFinder, findsOneWidget);
        await tester.tap(retryButtonFinder);
        await tester.pump();
        await tester.pump();

        // Advance animation
        await tester.pump(const Duration(milliseconds: 3600));
        await tester.pumpAndSettle();

        // Prize dialog should be presented
        expect(find.text('You Won a Prize!'), findsOneWidget);
        await tester.tap(find.byKey(const Key('claim_dialog_close_button')));
        await tester.pumpAndSettle();

        // Verify journal cleared the resolved pending command
        final pendingAfter = await commandStore.findPendingSpinCommand(
          familyId: testFamily.id.value,
          childId: testChild.id.value,
        );
        expect(pendingAfter, isNull);

        // Verify recovery card is dismissed
        expect(
          find.byKey(const Key('pending_spin_recovery_card')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'pure RP confirmation dialog: shows cost in RP, balance delta, and zero dollar/currency signs',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(5000), // 50 RP
          updatedAt: now,
        );

        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );
        final inMemoryWheel = InMemoryWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
        );

        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward1.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward2.title,
          category: poolReward2.category,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: poolReward2.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward3.title,
          category: poolReward3.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward3.wheelTier,
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
              wheelRepositoryProvider.overrideWithValue(inMemoryWheel),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
            ],
            child: const MaterialApp(home: ChildWheelScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // Open confirmation dialog
        await tester.tap(find.byKey(const Key('spin_wheel_button')));
        await tester.pumpAndSettle();

        // Verify Pure RP text
        expect(find.text('Spin the Celebration Wheel?'), findsOneWidget);
        expect(find.text('Cost: 10 RP'), findsOneWidget);
        expect(find.text('50 RP → 40 RP'), findsOneWidget);
        expect(
          find.text('Every spin gives one family-approved reward.'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('cancel_spin_button')), findsOneWidget);
        expect(find.byKey(const Key('confirm_spin_button')), findsOneWidget);

        // Invariant check: ZERO dollar signs or USD notation in child-facing prompt
        expect(find.textContaining(r'$'), findsNothing);
        expect(find.textContaining('USD'), findsNothing);

        // Dismiss dialog via Cancel
        await tester.tap(find.byKey(const Key('cancel_spin_button')));
        await tester.pumpAndSettle();

        // Verify dialog closed and balance remained 50 RP
        expect(find.text('Spin the Celebration Wheel?'), findsNothing);
        expect(find.text('50 RP'), findsOneWidget);
      },
    );

    testWidgets(
      'server-authoritative status: displays server-bounded daily cap and blocks spin when daily limit reached',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(5000), // 50 RP
          updatedAt: now,
        );

        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );

        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward1.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward2.title,
          category: poolReward2.category,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: poolReward2.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward3.title,
          category: poolReward3.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward3.wheelTier,
        );

        final fixedStatus = WheelStatus(
          familyId: testFamily.id,
          childId: testChild.id,
          spinCostMinor: 1000,
          dailySpinCap: 3,
          isEnabled: true,
          spinsToday: 3,
          spinsRemaining: 0,
          eligibleRewardCount: 3,
          localDayStart: DateTime.utc(2026, 11, 2),
          localDayEnd: DateTime.utc(2026, 11, 3),
        );

        final baseRepo = InMemoryWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
        );
        final fixedRepo = _FixedStatusWheelRepository(
          delegate: baseRepo,
          statusToReturn: fixedStatus,
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
              wheelRepositoryProvider.overrideWithValue(fixedRepo),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
            ],
            child: const MaterialApp(home: ChildWheelScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // Authoritative cap display
        expect(find.text('3 / 3 spins'), findsOneWidget);

        // Spin button should reflect limit reached and be disabled
        final spinButtonFinder = find.byKey(const Key('spin_wheel_button'));
        expect(tester.widget<FilledButton>(spinButtonFinder).enabled, isFalse);
        expect(find.text('Daily Limit Reached (3/3)'), findsOneWidget);
      },
    );

    testWidgets(
      'uncertain network drop leaves pending command, displays recovery banner without definite failure wording',
      (tester) async {
        final inMemoryGrowth = InMemoryGrowthRepository();
        inMemoryGrowth.balancesByChild[testChild.id.value] = ChildBalance(
          familyId: testFamily.id,
          childId: testChild.id,
          xpTotal: const XpAmount(100),
          rpBalanceMinor: const RpMinor(5000), // 50 RP
          updatedAt: now,
        );

        final inMemoryRewards = InMemoryRewardRepository(
          growthRepository: inMemoryGrowth,
        );

        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward1.title,
          category: poolReward1.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward1.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward2.title,
          category: poolReward2.category,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: poolReward2.wheelTier,
        );
        await inMemoryRewards.createReward(
          familyId: testFamily.id,
          title: poolReward3.title,
          category: poolReward3.category,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: poolReward3.wheelTier,
        );

        final commandStore = InMemoryPendingRewardCommandStore();

        // Repository that throws an uncertain network error on first spin, but succeeds on retry with original result
        final failingWheelRepo = _TransientNetworkWheelRepository(
          rewardRepository: inMemoryRewards,
          growthRepository: inMemoryGrowth,
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
              wheelRepositoryProvider.overrideWithValue(failingWheelRepo),
              rewardRepositoryProvider.overrideWithValue(inMemoryRewards),
              growthRepositoryProvider.overrideWithValue(inMemoryGrowth),
              pendingRewardCommandStoreProvider.overrideWithValue(commandStore),
            ],
            child: const MaterialApp(home: ChildWheelScreen()),
          ),
        );

        await tester.pumpAndSettle();

        // 1. User taps Spin -> confirmation dialog appears -> user confirms
        await tester.tap(find.byKey(const Key('spin_wheel_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm_spin_button')));
        await tester.pumpAndSettle();

        // 2. Network dropped: pending command remains in store!
        final pending = await commandStore.findPendingSpinCommand(
          familyId: testFamily.id.value,
          childId: testChild.id.value,
        );
        expect(pending, isNotNull);

        // 3. UI shows recovery card and disables fresh spin
        expect(
          find.byKey(const Key('pending_spin_recovery_card')),
          findsOneWidget,
        );
        expect(
          find.text("We're checking whether your spin was completed."),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('retry_pending_spin_button')),
          findsOneWidget,
        );
        final spinButtonFinder = find.byKey(const Key('spin_wheel_button'));
        expect(tester.widget<FilledButton>(spinButtonFinder).enabled, isFalse);
        expect(find.text('Resolve Interrupted Spin First'), findsOneWidget);

        // 4. Assert NO definite failure wording is displayed!
        expect(find.textContaining('Could not spin'), findsNothing);
        expect(find.textContaining('Spin failed'), findsNothing);

        // 5. Tapping Check / Retry Spin reuses the exact same command and resolves the spin
        await tester.tap(find.byKey(const Key('retry_pending_spin_button')));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 3600));
        await tester.pumpAndSettle();

        // Win dialog appears
        expect(find.text('You Won a Prize!'), findsOneWidget);
        await tester.tap(find.byKey(const Key('claim_dialog_close_button')));
        await tester.pumpAndSettle();

        // Journal cleared and recovery banner dismissed
        final pendingAfter = await commandStore.findPendingSpinCommand(
          familyId: testFamily.id.value,
          childId: testChild.id.value,
        );
        expect(pendingAfter, isNull);
        expect(
          find.byKey(const Key('pending_spin_recovery_card')),
          findsNothing,
        );
      },
    );
  });
}

class _TransientNetworkWheelRepository implements WheelRepository {
  _TransientNetworkWheelRepository({
    required InMemoryRewardRepository rewardRepository,
    required InMemoryGrowthRepository growthRepository,
  }) : _delegate = InMemoryWheelRepository(
         rewardRepository: rewardRepository,
         growthRepository: growthRepository,
       );

  final InMemoryWheelRepository _delegate;
  int _callCount = 0;

  @override
  Future<WheelSettings> getWheelSettings({required FamilyId familyId}) =>
      _delegate.getWheelSettings(familyId: familyId);

  @override
  Future<WheelSettings> updateWheelSettings(WheelSettings settings) =>
      _delegate.updateWheelSettings(settings);

  @override
  Future<List<Reward>> listWheelRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) => _delegate.listWheelRewards(familyId: familyId, childId: childId);

  @override
  Future<int> getTodaySpinCount({
    required FamilyId familyId,
    required ChildId childId,
  }) => _delegate.getTodaySpinCount(familyId: familyId, childId: childId);

  @override
  Future<WheelStatus> getWheelStatus({
    required FamilyId familyId,
    required ChildId childId,
  }) => _delegate.getWheelStatus(familyId: familyId, childId: childId);

  @override
  Future<List<WheelSpin>> listWheelSpins({
    required FamilyId familyId,
    ChildId? childId,
    int? limit,
  }) => _delegate.listWheelSpins(
    familyId: familyId,
    childId: childId,
    limit: limit,
  );

  @override
  Future<WheelSpinResult> spinRewardWheel({
    required String commandId,
    required ChildId childId,
  }) async {
    _callCount++;
    if (_callCount == 1) {
      // Simulate server committing the spin, but client experiencing network drop / response timeout
      await _delegate.spinRewardWheel(commandId: commandId, childId: childId);
      throw Exception('SocketException: Connection reset by peer');
    }
    // On retry, replaying same command returns the committed result
    return _delegate.spinRewardWheel(commandId: commandId, childId: childId);
  }
}

class _ChangingPoolWheelRepository implements WheelRepository {
  _ChangingPoolWheelRepository({
    required this.delegate,
    required this.committedResult,
  });

  final InMemoryWheelRepository delegate;
  final WheelSpinResult committedResult;

  @override
  Future<WheelSettings> getWheelSettings({required FamilyId familyId}) =>
      delegate.getWheelSettings(familyId: familyId);

  @override
  Future<WheelSettings> updateWheelSettings(WheelSettings settings) =>
      delegate.updateWheelSettings(settings);

  @override
  Future<List<Reward>> listWheelRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) => delegate.listWheelRewards(familyId: familyId, childId: childId);

  @override
  Future<int> getTodaySpinCount({
    required FamilyId familyId,
    required ChildId childId,
  }) => delegate.getTodaySpinCount(familyId: familyId, childId: childId);

  @override
  Future<WheelStatus> getWheelStatus({
    required FamilyId familyId,
    required ChildId childId,
  }) => delegate.getWheelStatus(familyId: familyId, childId: childId);

  @override
  Future<List<WheelSpin>> listWheelSpins({
    required FamilyId familyId,
    ChildId? childId,
    int? limit,
  }) => delegate.listWheelSpins(
    familyId: familyId,
    childId: childId,
    limit: limit,
  );

  @override
  Future<WheelSpinResult> spinRewardWheel({
    required String commandId,
    required ChildId childId,
  }) async {
    return committedResult;
  }
}

class _FixedStatusWheelRepository implements WheelRepository {
  _FixedStatusWheelRepository({
    required this.delegate,
    required this.statusToReturn,
  });

  final InMemoryWheelRepository delegate;
  final WheelStatus statusToReturn;

  @override
  Future<WheelSettings> getWheelSettings({required FamilyId familyId}) =>
      delegate.getWheelSettings(familyId: familyId);

  @override
  Future<WheelSettings> updateWheelSettings(WheelSettings settings) =>
      delegate.updateWheelSettings(settings);

  @override
  Future<List<Reward>> listWheelRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) => delegate.listWheelRewards(familyId: familyId, childId: childId);

  @override
  Future<int> getTodaySpinCount({
    required FamilyId familyId,
    required ChildId childId,
  }) => delegate.getTodaySpinCount(familyId: familyId, childId: childId);

  @override
  Future<WheelStatus> getWheelStatus({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    return statusToReturn;
  }

  @override
  Future<List<WheelSpin>> listWheelSpins({
    required FamilyId familyId,
    ChildId? childId,
    int? limit,
  }) => delegate.listWheelSpins(
    familyId: familyId,
    childId: childId,
    limit: limit,
  );

  @override
  Future<WheelSpinResult> spinRewardWheel({
    required String commandId,
    required ChildId childId,
  }) => delegate.spinRewardWheel(commandId: commandId, childId: childId);
}
