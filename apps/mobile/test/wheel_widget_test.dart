import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/rewards/presentation/child_wheel_screen.dart';
import 'package:learnward/features/rewards/presentation/parent_reward_form_screen.dart';
import 'package:learnward/features/rewards/presentation/parent_wheel_settings_screen.dart';
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
          find.textContaining('requires at least 3 active eligible rewards'),
          findsOneWidget,
        );
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
  });
}
