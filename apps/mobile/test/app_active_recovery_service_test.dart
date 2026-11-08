import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_active_recovery_service.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime.utc(2026, 11, 8, 12);

  group(
    'AppActiveRecoveryService Lifecycle & Family-Switch Wiring (R24-2-03)',
    () {
      test('remains dormant when recoveryDispatcherEnabled is false', () async {
        expect(AppConfig.recoveryDispatcherEnabled, isFalse);

        final container = ProviderContainer(
          overrides: [
            authSessionPortProvider.overrideWithValue(
              FakeAuthSessionPort(
                activeUserId: 'user-1',
                sessionGeneration: 'gen-1',
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final service = container.read(appActiveRecoveryServiceProvider);

        // Lifecycle event on dormant service does not throw or trigger
        service.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });

      test('Riverpod wiring: family switch and foreground resume trigger recovery drain', () async {
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'user-parent-1',
          sessionGeneration: 'gen-parent-1',
        );
        final fakeStore = InMemoryPendingRewardCommandStore();

        // Seed a claimable command for Family 1
        final cmdFam1 = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-service-fam1',
          familyId: 'fam-1',
          childId: 'child-1',
          actorUserId: 'user-parent-1',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await fakeStore.savePendingCommand(cmdFam1, now: t0);

        // Seed a claimable command for Family 2
        final cmdFam2 = PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-service-fam2',
          familyId: 'fam-2',
          childId: 'child-2',
          actorUserId: 'user-parent-1',
          createdAt: t0,
          recoveryState: CommandRecoveryState.active,
          dispatchState: CommandDispatchState.neverDispatched,
        );
        await fakeStore.savePendingCommand(cmdFam2, now: t0);

        final fakeWheel = FakeWheelRepository();
        fakeWheel.addReward(
          Reward(
            id: RewardId('rew-1'),
            familyId: FamilyId('fam-1'),
            title: 'Prize 1',
            category: RewardCategory.privilege,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            iconKey: 'star',
            createdAt: t0,
            updatedAt: t0,
          ),
        );
        fakeWheel.addReward(
          Reward(
            id: RewardId('rew-2'),
            familyId: FamilyId('fam-1'),
            title: 'Prize 2',
            category: RewardCategory.privilege,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            iconKey: 'star',
            createdAt: t0,
            updatedAt: t0,
          ),
        );
        fakeWheel.addReward(
          Reward(
            id: RewardId('rew-3'),
            familyId: FamilyId('fam-1'),
            title: 'Prize 3',
            category: RewardCategory.privilege,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            iconKey: 'star',
            createdAt: t0,
            updatedAt: t0,
          ),
        );
        fakeWheel.addReward(
          Reward(
            id: RewardId('rew-4'),
            familyId: FamilyId('fam-2'),
            title: 'Prize 4',
            category: RewardCategory.privilege,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            iconKey: 'star',
            createdAt: t0,
            updatedAt: t0,
          ),
        );
        fakeWheel.addReward(
          Reward(
            id: RewardId('rew-5'),
            familyId: FamilyId('fam-2'),
            title: 'Prize 5',
            category: RewardCategory.privilege,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            iconKey: 'star',
            createdAt: t0,
            updatedAt: t0,
          ),
        );
        fakeWheel.addReward(
          Reward(
            id: RewardId('rew-6'),
            familyId: FamilyId('fam-2'),
            title: 'Prize 6',
            category: RewardCategory.privilege,
            storeEnabled: false,
            wheelEnabled: true,
            wheelTier: WheelTier.common,
            iconKey: 'star',
            createdAt: t0,
            updatedAt: t0,
          ),
        );

        final container = ProviderContainer(
          overrides: [
            authSessionPortProvider.overrideWithValue(fakeAuth),
            pendingRewardCommandStoreProvider.overrideWithValue(fakeStore),
            wheelRepositoryProvider.overrideWithValue(fakeWheel),
            recoveryAuthorizationPortProvider.overrideWith((ref) {
              return FakeRecoveryAuthorizationPort();
            }),
            outboxRecoveryDispatcherProvider.overrideWith((ref) {
              return OutboxRecoveryDispatcher(
                commandStore: fakeStore,
                coordinator: ref.read(recoveryCoordinatorProvider),
                authSessionPort: fakeAuth,
                activeFamilyIdProvider: () =>
                    ref.read(activeFamilyProvider)?.id.value,
                minimumDrainInterval: Duration.zero,
              );
            }),
            appActiveRecoveryServiceProvider.overrideWith((ref) {
              final service = AppActiveRecoveryService(
                ref,
                enabledOverride: true,
              );
              ref.onDispose(service.dispose);
              return service;
            }),
          ],
        );
        addTearDown(container.dispose);

        // Eagerly instantiate recovery service lifecycle
        final service = container.read(appActiveRecoveryServiceProvider);

        // 1. Selecting Family 1 triggers drain pass for Family 1
        final family1 = Family(
          id: FamilyId('fam-1'),
          name: 'Family One',
          timezone: 'America/New_York',
          locale: 'en_US',
          createdByUserId: 'user-parent-1',
          createdAt: DateTime.utc(2026, 11, 8),
        );
        container.read(activeFamilyProvider.notifier).selectFamily(family1);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // cmdFam1 is processed and cleared from store!
        expect(await fakeStore.getPendingCommand('cmd-service-fam1'), isNull);
        // cmdFam2 for Family 2 remains untouched!
        expect(
          await fakeStore.getPendingCommand('cmd-service-fam2'),
          isNotNull,
        );

        // 2. Switching to Family 2 triggers drain pass for Family 2
        final family2 = Family(
          id: FamilyId('fam-2'),
          name: 'Family Two',
          timezone: 'America/New_York',
          locale: 'en_US',
          createdByUserId: 'user-parent-1',
          createdAt: DateTime.utc(2026, 11, 8),
        );
        container.read(activeFamilyProvider.notifier).selectFamily(family2);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // cmdFam2 is now processed and cleared from store!
        expect(await fakeStore.getPendingCommand('cmd-service-fam2'), isNull);

        // 3. Foreground resume triggers drain pass without errors
        service.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    },
  );
}
