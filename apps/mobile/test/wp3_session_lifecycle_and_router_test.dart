import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/cold_start_containment_bootstrap.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart'
    as mobile_mem;
import 'package:learnward/app/bootstrap/supabase_auth_session_adapter.dart';
import 'package:learnward/app/routing/app_router.dart';
import 'package:learnward/app/routing/app_routes.dart';
import 'package:learnward/features/auth/presentation/auth_screen.dart';
import 'package:learnward/features/child/presentation/child_mode_screen.dart';
import 'package:learnward/features/family/presentation/create_family_screen.dart';
import 'package:learnward/features/family/presentation/family_home_screen.dart';
import 'package:learnward/features/rewards/presentation/child_redemption_history_screen.dart';
import 'package:learnward/features/rewards/presentation/child_store_screen.dart';
import 'package:learnward/features/shared_device/domain/parent_gate_service.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

void _ensureSqliteInitialized() {
  if (Platform.isWindows) {
    try {
      DynamicLibrary.open('sqlite3.dll');
    } catch (_) {
      for (final candidate in [
        File('.dart_tool/lib/sqlite3.dll'),
        File('../../.dart_tool/lib/sqlite3.dll'),
        File('../.dart_tool/lib/sqlite3.dll'),
      ]) {
        if (candidate.existsSync()) {
          try {
            DynamicLibrary.open(candidate.absolute.path);
            return;
          } catch (_) {}
        }
      }
    }
  }
}

Future<AppDatabase> _openTempDb(Directory dir, String name) async {
  final file = File(p.join(dir.path, name));
  return AppDatabase(NativeDatabase(file));
}

void main() {
  setUpAll(_ensureSqliteInitialized);

  final nowUtc = DateTime.utc(2026, 11, 27, 14, 0);
  final familyA = Family(
    id: FamilyId('fam-a'),
    name: 'Alpha Household',
    timezone: 'UTC',
    locale: 'en_US',
    createdByUserId: 'adult-a',
    createdAt: DateTime.utc(2026, 10, 31),
  );
  final familyB = Family(
    id: FamilyId('fam-b'),
    name: 'Bravo Household',
    timezone: 'UTC',
    locale: 'en_US',
    createdByUserId: 'adult-b',
    createdAt: DateTime.utc(2026, 10, 31),
  );
  final childA = ChildProfile(
    id: ChildId('child-a'),
    familyId: familyA.id,
    displayName: 'Aria Alpha',
    schoolGrade: 4,
    birthYear: 2016,
    avatarKey: 'avatar-owl',
    createdAt: DateTime.utc(2026, 10, 31),
  );
  final childB = ChildProfile(
    id: ChildId('child-b'),
    familyId: familyB.id,
    displayName: 'Ben Bravo',
    schoolGrade: 5,
    birthYear: 2015,
    avatarKey: 'avatar-fox',
    createdAt: DateTime.utc(2026, 10, 31),
  );

  Future<ParentGateCredentialV2> seedBoundPin(
    LocalMetadataStore store, {
    required String pin,
    required String ownerFamilyId,
    required String actorUserId,
  }) async {
    final svc = ParentGateService(
      store,
      clock: FixedClock(nowUtc),
      minIterations: 1000,
      configuredIterations: 1000,
      runInIsolate: false,
    );
    return svc.setPin(
      pin,
      ownerFamilyId: ownerFamilyId,
      configuredByActorUserId: actorUserId,
      hasPositiveServerAdultVerification: true,
      verifiedActiveAdultFamilyIds: [ownerFamilyId],
      fence: ParentGateOperationFence(
        actorUserId: actorUserId,
        sessionGeneration: 1,
        containmentEpoch: 0,
        expectedContainmentStatus: 'verifiedParentMode',
        verifiedFamilyId: ownerFamilyId,
      ),
    );
  }

  group('WP3-1: GoRouter 10-Step Precedence & Strict Path Containment', () {
    test('isActiveChildContentPath performs strict segment matching excluding restricted child shells', () {
      expect(isActiveChildContentPath(AppRoutes.childMode), isTrue);
      expect(isActiveChildContentPath(AppRoutes.childStore), isTrue);
      expect(isActiveChildContentPath(AppRoutes.childRedemptions), isTrue);
      expect(isActiveChildContentPath(AppRoutes.childWheel), isTrue);
      expect(isActiveChildContentPath(AppRoutes.childMastery), isTrue);
      expect(isActiveChildContentPath(AppRoutes.childAddAssessment), isTrue);

      expect(isActiveChildContentPath(AppRoutes.childRevoked), isFalse);
      expect(isActiveChildContentPath(AppRoutes.childUnverified), isFalse);
      expect(
        isActiveChildContentPath(AppRoutes.childContainmentLocked),
        isFalse,
      );
      expect(isActiveChildContentPath('/child-other'), isFalse);
      expect(isActiveChildContentPath(AppRoutes.parentHome), isFalse);
      expect(isActiveChildContentPath(AppRoutes.auth), isFalse);
    });

    testWidgets(
      'redirects deep-linked /parent away from every non-parent containment state',
      (tester) async {
        final cases =
            <
              ({
                String label,
                bool signedIn,
                String userId,
                bool isAnonymous,
                String? role,
                ContainmentVerificationOutcome outcome,
                Key expectedKey,
                bool persistRevokedPaired,
              })
            >[
              (
                label: 'unauthenticated',
                signedIn: false,
                userId: 'adult-a',
                isAnonymous: false,
                role: 'owner',
                outcome: const NoActiveFamilyMembershipObserved(),
                expectedKey: const Key('auth_email_field'),
                persistRevokedPaired: false,
              ),
              (
                label: 'pairedChildRevoked',
                signedIn: true,
                userId: 'child-device-1',
                isAnonymous: true,
                role: 'child',
                outcome: ConfirmedPairedChildGrantRevoked(
                  revokedAt: nowUtc,
                  grantId: 'grant-revoked-1',
                ),
                expectedKey: const Key('cold_start_paired_child_revoked_shell'),
                persistRevokedPaired: false,
              ),
              (
                label: 'pairedChildUnverified',
                signedIn: true,
                userId: 'child-device-1',
                isAnonymous: true,
                role: 'child',
                outcome: const PairedChildUnverified(
                  reason: PairedChildUnverifiedReason
                      .grantVerificationTimeoutOrError,
                ),
                expectedKey: const Key(
                  'cold_start_paired_child_unverified_shell',
                ),
                persistRevokedPaired: false,
              ),
              (
                label: 'authorizationUnverified',
                signedIn: true,
                userId: 'adult-a',
                isAnonymous: false,
                role: 'owner',
                outcome: const SessionAuthorizationUnverified(
                  reason: 'offline',
                  allowsOfflineChildContainment: false,
                ),
                expectedKey: const Key(
                  'cold_start_authorization_unverified_shell',
                ),
                persistRevokedPaired: false,
              ),
              (
                label: 'adultAccessRestricted',
                signedIn: true,
                userId: 'adult-a',
                isAnonymous: false,
                role: 'owner',
                outcome: const ConfirmedAdultMembershipRevoked(
                  reason: 'revoked',
                ),
                expectedKey: const Key(
                  'cold_start_adult_access_restricted_shell',
                ),
                persistRevokedPaired: false,
              ),
              (
                label: 'noActiveFamilyMembership',
                signedIn: true,
                userId: 'adult-a',
                isAnonymous: false,
                role: 'owner',
                outcome: const NoActiveFamilyMembershipObserved(),
                expectedKey: const Key('cold_start_no_active_family_shell'),
                persistRevokedPaired: false,
              ),
            ];

        for (final tc in cases) {
          final store = InMemoryLocalMetadataStore();
          final fakeAuth = FakeAuthSessionPort(
            activeUserId: tc.signedIn ? tc.userId : null,
            role: tc.role,
            isAnonymous: tc.isAnonymous,
          );
          if (!tc.signedIn) {
            fakeAuth.invalidateSession();
          }

          late ProviderContainer container;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                authSessionPortProvider.overrideWithValue(fakeAuth),
                localMetadataStoreProvider.overrideWithValue(store),
                containmentAuthorizationVerifierProvider.overrideWithValue(
                  FakeContainmentAuthorizationVerifier(
                    defaultOutcome: tc.outcome,
                  ),
                ),
                parentGateServiceProvider.overrideWithValue(
                  ParentGateService(
                    store,
                    clock: FixedClock(nowUtc),
                    minIterations: 1000,
                    configuredIterations: 1000,
                    runInIsolate: false,
                  ),
                ),
              ],
              child: Consumer(
                builder: (context, ref, _) {
                  container = ProviderScope.containerOf(context);
                  return const LearnWardApp();
                },
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Attempt deep link to /parent and verify redirect blocks access.
          container.read(routerProvider).go(AppRoutes.parentHome);
          await tester.pumpAndSettle();
          expect(find.byType(FamilyHomeScreen), findsNothing, reason: tc.label);
          if (tc.signedIn) {
            expect(
              find.byKey(tc.expectedKey),
              findsOneWidget,
              reason: tc.label,
            );
          } else {
            expect(find.byType(AuthScreen), findsOneWidget, reason: tc.label);
          }

          if (tc.label == 'noActiveFamilyMembership') {
            await tester.tap(find.byKey(const Key('create_family_button')));
            await tester.pumpAndSettle();
            expect(find.byType(CreateFamilyScreen), findsOneWidget);
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
      },
    );

    testWidgets(
      'hydrating gate renders ContainmentHydratingScreen and blocks /parent while verifier is pending',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-a',
          role: 'owner',
        );
        final barrier = Completer<void>();
        final verifier = FakeContainmentAuthorizationVerifier(
          barrier: barrier,
          defaultOutcome: AuthorizedActiveAdult(
            verifiedRole: VerifiedAdultRole.owner,
            verifiedFamily: familyA,
            verifiedFamilies: [familyA],
            verifiedRolesByFamilyId: {
              familyA.id.value: VerifiedAdultRole.owner,
            },
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localMetadataStoreProvider.overrideWithValue(store),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
              ),
              parentGateServiceProvider.overrideWithValue(
                ParentGateService(
                  store,
                  minIterations: 1000,
                  configuredIterations: 1000,
                  runInIsolate: false,
                ),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pump();
        expect(find.byType(ContainmentHydratingScreen), findsOneWidget);
        expect(find.byType(FamilyHomeScreen), findsNothing);

        barrier.complete();
        await tester.pumpAndSettle();
      },
    );
  });

  group('WP3-2: Fail-Closed Auth Providers & Disposal Lifecycle', () {
    test('currentUserIdProvider has zero client.auth.currentUser fallback on signOut, expiry, and stream error', () async {
      final user = User(
        id: 'supa-adult-1',
        appMetadata: const {'role': 'owner'},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: nowUtc.toIso8601String(),
      );
      final liveSession = Session(
        accessToken: 'token-1',
        tokenType: 'bearer',
        user: user,
        expiresIn: 3600,
      );
      final client = SupabaseClient('https://test.supabase.co', 'anon-key');
      final authController = StreamController<AuthState>.broadcast();
      addTearDown(() async {
        await authController.close();
        unawaited(client.dispose());
      });

      final adapter = SupabaseAuthSessionAdapter(
        client,
        clock: FixedClock(nowUtc),
        authStateStream: authController.stream,
        currentSessionProvider: () => liveSession,
      );
      addTearDown(adapter.dispose);

      final container = ProviderContainer(
        overrides: [
          supabaseClientProvider.overrideWithValue(client),
          authStateProvider.overrideWith((ref) => authController.stream),
          authSessionPortProvider.overrideWithValue(adapter),
        ],
      );
      addTearDown(container.dispose);
      final uidSub = container.listen(currentUserIdProvider, (_, _) {});
      addTearDown(uidSub.close);

      expect(container.read(currentUserIdProvider), equals('supa-adult-1'));
      expect(container.read(authSessionStateProvider).isAuthenticated, isTrue);

      // Even if liveSession stays non-null, signedOut or stream error forces null immediately.
      authController.add(AuthState(AuthChangeEvent.signedOut, liveSession));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(currentUserIdProvider), isNull);
      expect(container.read(authSessionStateProvider).isAuthenticated, isFalse);

      // Re-init fresh adapter and test stream error sticky invalidation.
      final errAdapter = SupabaseAuthSessionAdapter(
        client,
        clock: FixedClock(nowUtc),
        authStateStream: authController.stream,
        currentSessionProvider: () => liveSession,
      );
      addTearDown(errAdapter.dispose);
      final errContainer = ProviderContainer(
        overrides: [
          supabaseClientProvider.overrideWithValue(client),
          authStateProvider.overrideWith((ref) => authController.stream),
          authSessionPortProvider.overrideWithValue(errAdapter),
        ],
      );
      addTearDown(errContainer.dispose);
      final errSub = errContainer.listen(currentUserIdProvider, (_, _) {});
      addTearDown(errSub.close);
      expect(errContainer.read(currentUserIdProvider), equals('supa-adult-1'));

      authController.addError(Exception('refresh failed'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(errContainer.read(currentUserIdProvider), isNull);
      expect(
        errContainer.read(authSessionStateProvider).isFailClosedInvalidated,
        isTrue,
      );
    });

    test(
      'RouterListenable disposes cleanly without throwing on late events',
      () async {
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-a',
          role: 'owner',
        );
        final store = InMemoryLocalMetadataStore();
        final container = ProviderContainer(
          overrides: [
            authSessionPortProvider.overrideWithValue(fakeAuth),
            localMetadataStoreProvider.overrideWithValue(store),
            containmentAuthorizationVerifierProvider.overrideWithValue(
              FakeContainmentAuthorizationVerifier(
                defaultOutcome: const NoActiveFamilyMembershipObserved(),
              ),
            ),
          ],
        );

        final listenable = container.read(routerListenableProvider);
        final notifyCount = <int>[0];
        listenable.addListener(() => notifyCount[0]++);

        container.dispose();
        fakeAuth.invalidateSession();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(notifyCount[0], equals(0));
      },
    );
  });

  group('WP3-3 & WP3-4: Account Switch, Family Switch & Child Reward Offline Fallback', () {
    testWidgets(
      'Actor A -> B engages immediate fail-closed mask, increments sessionScopeEpoch, clears sticky Family A bleed, and pauses A reward command via CAS',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        final familyRepo = FakeFamilyRepository(
          currentUserId: 'adult-a',
          families: [familyA, familyB],
          memberships: [
            FamilyMembership(
              familyId: familyA.id,
              authUserId: 'adult-a',
              role: FamilyRole.owner,
              status: MembershipStatus.active,
              joinedAt: nowUtc,
            ),
            FamilyMembership(
              familyId: familyB.id,
              authUserId: 'adult-b',
              role: FamilyRole.owner,
              status: MembershipStatus.active,
              joinedAt: nowUtc,
            ),
          ],
        );
        final childRepo = FakeChildProfileRepository(
          children: [childA, childB],
        );
        final commandStore = InMemoryPendingRewardCommandStore();
        final draftStore = TestLocalDraftStore();
        final verifier = FakeContainmentAuthorizationVerifier(
          onVerify: (call) async {
            if (call.context.userId == 'adult-a') {
              return AuthorizedActiveAdult(
                verifiedRole: VerifiedAdultRole.owner,
                verifiedFamily: familyA,
                verifiedFamilies: [familyA],
                verifiedRolesByFamilyId: {
                  familyA.id.value: VerifiedAdultRole.owner,
                },
              );
            }
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: familyB,
              verifiedFamilies: [familyB],
              verifiedRolesByFamilyId: {
                familyB.id.value: VerifiedAdultRole.owner,
              },
            );
          },
        );
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-a',
          role: 'owner',
        );

        await commandStore.registerFreshCommand(
          command: PendingRewardCommand(
            operation: RewardCommandOperation.spinWheel,
            commandId: 'cmd-actor-a-spin',
            familyId: familyA.id.value,
            childId: childA.id.value,
            createdAt: nowUtc,
            actorUserId: 'adult-a',
            actorRole: 'owner',
          ),
        );
        await draftStore.saveLocalDraft(
          LocalAssessmentDraft(
            localDraftId: 'draft-actor-a',
            familyId: familyA.id.value,
            childId: childA.id.value,
            createCommandId: 'c1',
            submitCommandId: 's1',
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Actor A Draft',
            assessmentType: 'quiz',
            difficulty: 'normal',
            rawScore: 9,
            maxScore: 10,
            occurredAt: nowUtc,
            updatedAt: nowUtc,
            actorUserId: 'adult-a',
            actorRole: 'owner',
          ),
        );

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localMetadataStoreProvider.overrideWithValue(store),
              pendingRewardCommandStoreProvider.overrideWithValue(commandStore),
              localDraftStoreProvider.overrideWithValue(draftStore),
              familyRepositoryProvider.overrideWithValue(familyRepo),
              childProfileRepositoryProvider.overrideWithValue(childRepo),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
              ),
              parentGateServiceProvider.overrideWithValue(
                ParentGateService(
                  store,
                  minIterations: 1000,
                  configuredIterations: 1000,
                  runInIsolate: false,
                ),
              ),
            ],
            child: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return const LearnWardApp();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Alpha Household'), findsOneWidget);
        final epochBeforeSwitch = container
            .read(coldStartContainmentProvider)
            .sessionScopeEpoch;

        // Switch Actor A -> Actor B and flush broadcast stream microtask (zero FakeAsync timer hang).
        familyRepo.currentUserId = 'adult-b';
        fakeAuth.switchActor('adult-b', role: 'owner');
        await Future<void>.microtask(() {});
        expect(
          container
              .read(coldStartContainmentProvider.notifier)
              .isFailClosedMasked,
          isTrue,
        );
        expect(container.read(activeFamilyProvider), isNull);

        await tester.pumpAndSettle();

        expect(find.text('Bravo Household'), findsOneWidget);
        expect(find.text('Alpha Household'), findsNothing);
        expect(
          container.read(coldStartContainmentProvider).sessionScopeEpoch,
          greaterThan(epochBeforeSwitch),
        );
        expect(container.read(activeFamilyProvider)?.id, equals(familyB.id));

        // Assert Actor A's reward command was paused via CAS (zero deletion) & draft kept.
        final pausedCmd = await commandStore.getPendingCommand(
          'cmd-actor-a-spin',
        );
        expect(
          pausedCmd?.recoveryState,
          equals(CommandRecoveryState.pendingOriginalActor),
        );
        expect(await draftStore.getLocalDraft('draft-actor-a'), isNotNull);
      },
    );

    testWidgets(
      'offlineContainedChildMode with null activeFamilyProvider still renders ChildStoreScreen and ChildRedemptionHistoryScreen',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        await seedBoundPin(
          store,
          pin: '1357',
          ownerFamilyId: familyA.id.value,
          actorUserId: 'adult-a',
        );
        final envelope = PersistedChildModeSession(
          modeKind: PersistedChildModeKind.sharedDeviceAdult,
          actorUserId: 'adult-a',
          familyId: familyA.id,
          childId: childA.id,
          childProfileSnapshot: childA,
          persistedAtUtc: nowUtc,
        );
        await store.writeMetadata(
          key: ActiveChildModeNotifier.activeSessionKey,
          value: envelope.toJsonString(),
          updatedAt: nowUtc,
        );

        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'adult-a',
          role: 'owner',
        );
        final rewardRepo = mobile_mem.InMemoryRewardRepository();
        await rewardRepo.createReward(
          familyId: familyA.id,
          title: 'Extra Story Time',
          category: RewardCategory.experience,
          storeCostMinor: 5000,
        );

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localMetadataStoreProvider.overrideWithValue(store),
              rewardRepositoryProvider.overrideWithValue(rewardRepo),
              growthRepositoryProvider.overrideWithValue(
                mobile_mem.InMemoryGrowthRepository(),
              ),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                FakeContainmentAuthorizationVerifier(
                  defaultOutcome: const SessionAuthorizationUnverified(
                    reason: 'offline_timeout',
                    allowsOfflineChildContainment: true,
                  ),
                ),
              ),
              parentGateServiceProvider.overrideWithValue(
                ParentGateService(
                  store,
                  minIterations: 1000,
                  configuredIterations: 1000,
                  runInIsolate: false,
                ),
              ),
            ],
            child: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return const LearnWardApp();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          container.read(coldStartContainmentProvider).status,
          ColdStartContainmentStatus.offlineContainedChildMode,
        );
        expect(container.read(activeFamilyProvider), isNull);

        container.read(routerProvider).go(AppRoutes.childStore);
        await tester.pumpAndSettle();
        expect(find.byType(ChildStoreScreen), findsOneWidget);
        expect(find.text('Extra Story Time'), findsOneWidget);

        container.read(routerProvider).go(AppRoutes.childRedemptions);
        await tester.pumpAndSettle();
        expect(find.byType(ChildRedemptionHistoryScreen), findsOneWidget);
      },
    );
  });

  group('WP3-5 & WP3-6: PIN Management & Mid-KDF Concurrency Races', () {
    test('PIN setup, change, cross-family reassignment, forgotten reset fresh-auth gate & corrupt recovery work under arbiter', () async {
      final store = InMemoryLocalMetadataStore();
      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-1',
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA, familyB],
          verifiedRolesByFamilyId: {
            familyA.id.value: VerifiedAdultRole.owner,
            familyB.id.value: VerifiedAdultRole.owner,
          },
        ),
      );
      final container = ProviderContainer(
        overrides: [
          authSessionPortProvider.overrideWithValue(fakeAuth),
          localMetadataStoreProvider.overrideWithValue(store),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          restrictedShellSignOutProvider.overrideWithValue(() async {
            fakeAuth.invalidateSession();
          }),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              store,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(sessionContainmentProvider.notifier);
      await controller.rehydrate();
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.verifiedParentMode,
      );

      // 1. Initial setup
      final initialCred = await controller.submitInitialPinSetup('1111');
      expect(initialCred.ownerFamilyId, equals(familyA.id.value));

      // 2. Forgotten PIN reset rejected without fresh post-sign-out auth
      await expectLater(
        controller.submitForgottenPinReset(newPin: '2222'),
        throwsA(isA<ParentGateFencedOperationException>()),
      );

      // 3. Change PIN
      final changed = await controller.submitParentPinChange(
        currentPin: '1111',
        newPin: '2222',
      );
      expect(changed.isVerified, isTrue);

      // 4. Switch F1 -> F2 and cross-family reassign
      await controller.switchActiveFamily(familyB);
      expect(container.read(activeFamilyProvider)?.id, equals(familyB.id));
      final reassigned = await controller.submitCrossFamilyPinReassignment(
        newPin: '3333',
      );
      expect(reassigned.ownerFamilyId, equals(familyB.id.value));

      // 5. Normal sign-out -> fresh login -> switch back to familyB (which owns the reassigned PIN) enables forgotten reset
      await controller.signOutNormal();
      fakeAuth.setSession(
        userId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-2',
      );
      await controller.rehydrate();
      await controller.switchActiveFamily(familyB);
      expect(
        container.read(sessionContainmentProvider).isPostSignOutFreshAdultAuth,
        isTrue,
      );
      final resetCred = await controller.submitForgottenPinReset(
        newPin: '4444',
      );
      expect(resetCred.ownerFamilyId, equals(familyB.id.value));

      // 6. Corrupt credential recovery
      await store.writeMetadata(
        key: ParentGateService.credentialV2Key,
        value: '{corrupt_json',
        updatedAt: nowUtc,
      );
      final recovered = await controller.submitCorruptPinRecovery(
        newPin: '5555',
      );
      expect(recovered.ownerFamilyId, equals(familyB.id.value));
    });

    test('Sign-out during KDF executes synchronously without waiting on KDF, aborts attempt, and keeps active_child_session', () async {
      final store = InMemoryLocalMetadataStore();
      await seedBoundPin(
        store,
        pin: '4829',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );
      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-1',
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA],
          verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
          verifiedChild: childA,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          authSessionPortProvider.overrideWithValue(fakeAuth),
          localMetadataStoreProvider.overrideWithValue(store),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          restrictedShellSignOutProvider.overrideWithValue(() async {
            fakeAuth.invalidateSession();
          }),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              store,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(sessionContainmentProvider.notifier);
      await controller.rehydrate();
      await controller.enterChildMode(childA);

      final unlockResult = await controller.submitParentGateUnlock(
        '4829',
        onAfterKdfBeforeFinalize: (_) async {
          fakeAuth.invalidateSession();
          await Future<void>.delayed(Duration.zero);
          expect(controller.isFailClosedMasked, isTrue);
          expect(
            container.read(sessionContainmentProvider).status,
            ColdStartContainmentStatus.unauthenticated,
          );
        },
      );

      expect(unlockResult.outcome, PinVerificationOutcome.staleFence);
      expect(unlockResult.isAuthorizedToExitChildMode, isFalse);
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNotNull,
      );
    });
  });

  group('WP3-7 & WP3-9: Two-Barrier Linearizability (R38-07) & Exit Path B / D1.6 on File SQLite', () {
    test('Barrier 1 (onBeforeFinalizePreCommitGuard) rolls back SQLite unlock and keeps Child Mode locked across DB reopen', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp3_b1_');
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });
      final db = await _openTempDb(tempDir, 'barrier1.sqlite');
      var dbClosed = false;
      addTearDown(() async {
        if (!dbClosed) {
          dbClosed = true;
          await db.close();
        }
      });

      await seedBoundPin(
        db,
        pin: '2468',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );

      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-1',
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA],
          verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
          verifiedChild: childA,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(db),
          pendingRewardCommandStoreProvider.overrideWithValue(db),
          localDraftStoreProvider.overrideWithValue(db),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              db,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(sessionContainmentProvider.notifier);
      await controller.rehydrate();
      await controller.enterChildMode(childA);

      final res = await controller.submitParentGateUnlock(
        '2468',
        onBeforeFinalizePreCommitGuard: () async {
          fakeAuth.invalidateSession();
        },
      );
      expect(res.outcome, PinVerificationOutcome.staleFence);
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.unauthenticated,
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      dbClosed = true;
      await db.close();

      final reopened = await _openTempDb(tempDir, 'barrier1.sqlite');
      addTearDown(reopened.close);
      expect(
        await reopened.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNotNull,
      );
    });

    test('Barrier 2 (onAfterFinalizeGuardBeforeCommit) suppresses ParentMode UI even after SQLite COMMIT passes guard and bumps containment_fence_v1', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp3_b2_');
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });
      final db = await _openTempDb(tempDir, 'barrier2.sqlite');
      addTearDown(db.close);

      await seedBoundPin(
        db,
        pin: '2468',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );

      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-1',
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA],
          verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
          verifiedChild: childA,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(db),
          pendingRewardCommandStoreProvider.overrideWithValue(db),
          localDraftStoreProvider.overrideWithValue(db),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              db,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(sessionContainmentProvider.notifier);
      await controller.rehydrate();
      await controller.enterChildMode(childA);

      final res = await controller.submitParentGateUnlock(
        '2468',
        onAfterFinalizeGuardBeforeCommit: () async {
          // Arrives AFTER preCommitGuard succeeded inside transaction, BEFORE commit completes!
          fakeAuth.invalidateSession();
          await Future<void>.delayed(Duration.zero);
          expect(
            container.read(sessionContainmentProvider).status,
            ColdStartContainmentStatus.unauthenticated,
          );
        },
      );
      expect(res.outcome, PinVerificationOutcome.staleFence);
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.unauthenticated,
      );
      expect(container.read(activeFamilyProvider), isNull);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      final fenceRaw = await db.readMetadata(
        ParentGateService.containmentFenceV1Key,
      );
      final parsedFence = ContainmentFenceV1.tryParse(fenceRaw);
      expect(parsedFence, isNotNull);
      expect(parsedFence!.actorUserId, isNull);
    });

    test('R38-10 + D1.6: Malformed active_child_session + single outbox family stays unresolvable, survives recovery sign-out & reopen, and Restricted Manual Unbound Recovery preserves 100% drafts, commands & photo SHA-256', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp3_r38_10_');
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });
      final db = await _openTempDb(tempDir, 'unresolvable_recovery.sqlite');
      var dbClosed = false;
      Future<void> closeDb() async {
        if (!dbClosed) {
          dbClosed = true;
          await db.close();
        }
      }

      addTearDown(closeDb);

      final photoFile = File(p.join(tempDir.path, 'evidence_unbound.jpg'));
      final photoBytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 9, 8, 7, 6, 0xD9];
      await photoFile.writeAsBytes(photoBytes, flush: true);
      final expectedSha = sha256.convert(photoBytes).toString();

      // Single unrelated actor-bound command for Family B + malformed active_child_session
      await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-b-1',
          familyId: familyB.id.value,
          childId: childB.id.value,
          createdAt: nowUtc,
          actorUserId: 'adult-b',
          actorRole: 'owner',
        ),
      );
      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'draft-a-1',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createCommandId: 'c-a',
          submitCommandId: 's-a',
          subjectKey: SubjectKey.science,
          subject: 'Science',
          title: 'Unbound Recovery Preserved Draft',
          assessmentType: 'project',
          difficulty: 'hard',
          rawScore: 10,
          maxScore: 10,
          localCompressedPhotoPath: photoFile.path,
          sha256Checksum: expectedSha,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await db.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: '{"malformed_legacy": true}',
        updatedAt: nowUtc,
      );

      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-b',
        role: 'owner',
        sessionGeneration: 'gen-b-1',
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyB,
          verifiedFamilies: [familyB],
          verifiedRolesByFamilyId: {familyB.id.value: VerifiedAdultRole.owner},
        ),
      );

      final container1 = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(db),
          pendingRewardCommandStoreProvider.overrideWithValue(db),
          localDraftStoreProvider.overrideWithValue(db),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              db,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
          restrictedShellSignOutProvider.overrideWithValue(() async {
            fakeAuth.invalidateSession();
          }),
        ],
      );

      final c1 = container1.read(sessionContainmentProvider.notifier);
      await c1.rehydrate();
      expect(
        container1.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      // Normal sign-out refuses inside containmentLocked!
      await expectLater(c1.signOutNormal(), throwsStateError);
      expect(
        await db.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNotNull,
      );

      // Exit Path B Recovery Sign-Out persists unresolvable recovery lock & retains active_child_session
      await c1.signOutFromContainmentRecovery();
      container1.dispose();
      await closeDb();

      // Reopen SQLite and sign back in fresh as Adult B -> STILL LOCKED (no false CorroboratedLegacyOwner!)
      final db2 = await _openTempDb(tempDir, 'unresolvable_recovery.sqlite');
      addTearDown(db2.close);
      final fakeAuth2 = FakeAuthSessionPort(
        activeUserId: 'adult-b',
        role: 'owner',
        sessionGeneration: 'gen-b-2',
      );
      final container2 = ProviderContainer(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(db2),
          pendingRewardCommandStoreProvider.overrideWithValue(db2),
          localDraftStoreProvider.overrideWithValue(db2),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db2),
          authSessionPortProvider.overrideWithValue(fakeAuth2),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              db2,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container2.dispose);

      final c2 = container2.read(sessionContainmentProvider.notifier);
      await c2.rehydrate();
      final s2 = container2.read(sessionContainmentProvider);
      expect(s2.status, ColdStartContainmentStatus.containmentLocked);
      expect(s2.allowsManualUnboundLegacyRecovery, isTrue);

      // Restricted Manual Unbound Recovery requires confirmation + new v2 PIN -> clears lock, enters ParentMode
      await c2.submitManualUnboundLegacyRecovery(
        newPin: '7890',
        targetFamilyId: familyB.id.value,
      );
      expect(
        container2.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.verifiedParentMode,
      );
      expect(
        await db2.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );
      expect(
        await db2.readMetadata(
          SessionLifecycleController.containmentRecoveryLockV1Key,
        ),
        isNull,
      );
      final audit = LastContainmentRecoveryAuditV1.tryParse(
        await db2.readMetadata(
          ParentGateService.lastContainmentRecoveryAuditV1Key,
        ),
      );
      expect(audit?.targetFamilyId, equals(familyB.id.value));
      expect(await db2.getLocalDraft('draft-a-1'), isNotNull);
      expect(await db2.getPendingCommand('cmd-b-1'), isNotNull);
      expect(
        sha256.convert(await photoFile.readAsBytes()).toString(),
        equals(expectedSha),
      );
    });

    test('Bound Exit Path B stays locked on stale sessionGeneration & unrelated Family B, auto-unlocks ONLY for fresh owning Adult A', () async {
      final store = InMemoryLocalMetadataStore();
      await seedBoundPin(
        store,
        pin: '1122',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );
      final env = PersistedChildModeSession(
        modeKind: PersistedChildModeKind.sharedDeviceAdult,
        actorUserId: 'adult-a',
        familyId: familyA.id,
        childId: childA.id,
        childProfileSnapshot: childA,
        persistedAtUtc: nowUtc,
      );
      await store.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: env.toJsonString(),
        updatedAt: nowUtc,
      );
      final lock = ContainmentRecoveryLockV1(
        version: 1,
        reason: ContainmentRecoveryReason.forgottenPin,
        ownershipLevel: ContainmentRecoveryOwnershipLevel.boundV2,
        requiredOwnerFamilyId: familyA.id.value,
        originActorUserId: 'adult-a',
        initiatedFromSessionGeneration: 'gen-orig',
        initiatedAtUtc: nowUtc,
      );
      await store.writeMetadata(
        key: SessionLifecycleController.containmentRecoveryLockV1Key,
        value: lock.toJsonString(),
        updatedAt: nowUtc,
      );

      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-b',
        role: 'owner',
        sessionGeneration: 'gen-b-fresh',
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        onVerify: (call) async {
          if (call.context.userId == 'adult-b') {
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: familyB,
              verifiedFamilies: [familyB],
              verifiedRolesByFamilyId: {
                familyB.id.value: VerifiedAdultRole.owner,
              },
            );
          }
          return AuthorizedActiveAdult(
            verifiedRole: VerifiedAdultRole.owner,
            verifiedFamily: familyA,
            verifiedFamilies: [familyA],
            verifiedRolesByFamilyId: {
              familyA.id.value: VerifiedAdultRole.owner,
            },
          );
        },
      );

      final container = ProviderContainer(
        overrides: [
          authSessionPortProvider.overrideWithValue(fakeAuth),
          localMetadataStoreProvider.overrideWithValue(store),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              store,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(sessionContainmentProvider.notifier);
      await controller.rehydrate();
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      // Stale sessionGeneration matching initiatedFromSessionGeneration must NOT unlock.
      fakeAuth.setSession(
        userId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-orig',
      );
      await controller.rehydrate();
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      // Fresh post-sign-out owning Adult A auto-clears Exit Path B -> ParentMode.
      fakeAuth.setSession(
        userId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-a-fresh',
      );
      await controller.rehydrate();
      final unlocked = container.read(sessionContainmentProvider);
      expect(unlocked.status, ColdStartContainmentStatus.verifiedParentMode);
      expect(unlocked.needsPinReconfigurationAfterRecovery, isTrue);
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );
    });
  });

  group('WP3-10: Paired Child Exit Hiding & Adult Lock Preservation', () {
    testWidgets(
      'ChildModeScreen hides Exit Child Mode button in pairedChildMode',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        final env = PersistedChildModeSession(
          modeKind: PersistedChildModeKind.pairedChildDevice,
          actorUserId: 'paired-child-uid',
          familyId: familyA.id,
          childId: childA.id,
          childProfileSnapshot: childA,
          persistedAtUtc: nowUtc,
        );
        await store.writeMetadata(
          key: ActiveChildModeNotifier.activeSessionKey,
          value: env.toJsonString(),
          updatedAt: nowUtc,
        );
        final fakeAuth = FakeAuthSessionPort(
          activeUserId: 'paired-child-uid',
          role: 'child',
          isAnonymous: true,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localMetadataStoreProvider.overrideWithValue(store),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                FakeContainmentAuthorizationVerifier(
                  defaultOutcome: AuthorizedPairedChild(
                    verifiedChild: childA,
                    verifiedFamily: familyA,
                    grantId: 'grant-active-1',
                  ),
                ),
              ),
              parentGateServiceProvider.overrideWithValue(
                ParentGateService(
                  store,
                  minIterations: 1000,
                  configuredIterations: 1000,
                  runInIsolate: false,
                ),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ChildModeScreen), findsOneWidget);
        expect(find.byKey(const Key('exit_child_mode_button')), findsNothing);
      },
    );

    test('ConfirmedPairedChildGrantRevoked NEVER clears an adult containment_recovery_lock_v1, while PairedChildUnverified sign-out clears ONLY paired envelope and preserves local data', () async {
      final store = InMemoryLocalMetadataStore();
      final lock = ContainmentRecoveryLockV1(
        version: 1,
        reason: ContainmentRecoveryReason.forgottenPin,
        ownershipLevel: ContainmentRecoveryOwnershipLevel.boundV2,
        requiredOwnerFamilyId: familyA.id.value,
        initiatedFromSessionGeneration: 'gen-0',
        initiatedAtUtc: nowUtc,
      );
      await store.writeMetadata(
        key: SessionLifecycleController.containmentRecoveryLockV1Key,
        value: lock.toJsonString(),
        updatedAt: nowUtc,
      );
      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'paired-child-uid',
        role: 'child',
        isAnonymous: true,
      );
      final container = ProviderContainer(
        overrides: [
          authSessionPortProvider.overrideWithValue(fakeAuth),
          localMetadataStoreProvider.overrideWithValue(store),
          containmentAuthorizationVerifierProvider.overrideWithValue(
            FakeContainmentAuthorizationVerifier(
              defaultOutcome: ConfirmedPairedChildGrantRevoked(
                revokedAt: nowUtc,
                grantId: 'grant-revoked-2',
              ),
            ),
          ),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              store,
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(sessionContainmentProvider.notifier).rehydrate();
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );
      expect(
        await store.readMetadata(
          SessionLifecycleController.containmentRecoveryLockV1Key,
        ),
        isNotNull,
      );

      // Separate scenario: paired_child_device without adult lock clears paired envelope on revoked & signOut.
      final pairedStore = InMemoryLocalMetadataStore();
      await seedBoundPin(
        pairedStore,
        pin: '7777',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );
      final pairedEnv = PersistedChildModeSession(
        modeKind: PersistedChildModeKind.pairedChildDevice,
        actorUserId: 'paired-child-uid-2',
        familyId: familyA.id,
        childId: childA.id,
        childProfileSnapshot: childA,
        persistedAtUtc: nowUtc,
      );
      await pairedStore.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: pairedEnv.toJsonString(),
        updatedAt: nowUtc,
      );
      final draftStore = TestLocalDraftStore();
      await draftStore.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'paired-draft-1',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createCommandId: 'pc1',
          submitCommandId: 'ps1',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Paired Draft',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8,
          maxScore: 10,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'paired-child-uid-2',
          actorRole: 'child',
        ),
      );
      final pairedAuth = FakeAuthSessionPort(
        activeUserId: 'paired-child-uid-2',
        role: 'child',
        isAnonymous: true,
      );
      final pairedVerifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: const PairedChildUnverified(
          reason: PairedChildUnverifiedReason.grantVerificationTimeoutOrError,
        ),
      );
      final pairedContainer = ProviderContainer(
        overrides: [
          authSessionPortProvider.overrideWithValue(pairedAuth),
          localMetadataStoreProvider.overrideWithValue(pairedStore),
          localDraftStoreProvider.overrideWithValue(draftStore),
          containmentAuthorizationVerifierProvider.overrideWithValue(
            pairedVerifier,
          ),
          restrictedShellSignOutProvider.overrideWithValue(() async {
            pairedAuth.invalidateSession();
          }),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              pairedStore,
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(pairedContainer.dispose);

      final pCtrl = pairedContainer.read(sessionContainmentProvider.notifier);
      await pCtrl.rehydrate();
      expect(
        pairedContainer.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.pairedChildUnverified,
      );

      await pCtrl.signOutFromRestrictedShell();
      expect(
        pairedContainer.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.unauthenticated,
      );
      expect(
        await pairedStore.readMetadata(
          ActiveChildModeNotifier.activeSessionKey,
        ),
        isNull,
      );
      expect(await draftStore.getLocalDraft('paired-draft-1'), isNotNull);
      expect(
        await pairedStore.readMetadata(ParentGateService.credentialV2Key),
        isNotNull,
      );
    });
  });

  group('WP3-8 & WP3-9 Extra: Exit Path A, Offline Rejection, Legacy v1 Upgrade & Corroborated Exit Path B', () {
    test('Exit Path A unlocks verifiedChildMode, rejects offline PIN without clearing session, and atomically upgrades legacy v1 -> v2 online', () async {
      final store = InMemoryLocalMetadataStore();
      await seedBoundPin(
        store,
        pin: '4829',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );
      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        role: 'owner',
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA],
          verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
          verifiedChild: childA,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          authSessionPortProvider.overrideWithValue(fakeAuth),
          localMetadataStoreProvider.overrideWithValue(store),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              store,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(sessionContainmentProvider.notifier);
      await ctrl.rehydrate();
      await ctrl.enterChildMode(childA);

      // Offline verifier prevents Exit Path A unlock even with correct PIN and reverts speculative increment.
      verifier.defaultOutcome = const SessionAuthorizationUnverified(
        reason: 'offline',
        allowsOfflineChildContainment: true,
      );
      final offlineRes = await ctrl.submitParentGateUnlock('4829');
      expect(
        offlineRes.outcome,
        PinVerificationOutcome.pinMatchedAuthorizationRequired,
      );
      expect(offlineRes.failedAttempts, equals(0));
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNotNull,
      );

      // Revoked membership observed at Step 4 also rejects unlock safely.
      verifier.defaultOutcome = const ConfirmedAdultMembershipRevoked(
        reason: 'revoked',
      );
      final revokedRes = await ctrl.submitParentGateUnlock('4829');
      expect(
        revokedRes.outcome,
        PinVerificationOutcome.pinMatchedAuthorizationRequired,
      );
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNotNull,
      );

      // Online active adult succeeds & deletes active_child_session cleanly.
      verifier.defaultOutcome = AuthorizedActiveAdult(
        verifiedRole: VerifiedAdultRole.owner,
        verifiedFamily: familyA,
        verifiedFamilies: [familyA],
        verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
        verifiedChild: childA,
      );
      await ctrl.rehydrate();
      final onlineRes = await ctrl.submitParentGateUnlock('4829');
      expect(onlineRes.isAuthorizedToExitChildMode, isTrue);
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.verifiedParentMode,
      );
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );

      // Legacy v1 credential + hinted session upgrades atomically to owner-bound v2 on Exit Path A.
      final legacyStore = InMemoryLocalMetadataStore();
      const v1Salt = 'legacy-salt-1';
      await legacyStore.writeMetadata(
        key: ParentGateService.pinSaltKey,
        value: v1Salt,
        updatedAt: nowUtc,
      );
      await legacyStore.writeMetadata(
        key: ParentGateService.pinHashKey,
        value: ParentGateCrypto.sha256V1PinHex(pin: '2580', salt: v1Salt),
        updatedAt: nowUtc,
      );
      await legacyStore.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: jsonEncode({
          'id': childA.id.value,
          'family_id': familyA.id.value,
          'display_name': childA.displayName,
        }),
        updatedAt: nowUtc,
      );
      final legacyProvenance = InMemoryLegacyOutboxProvenanceSource([
        ActorBoundOutboxRecord(
          source: LegacyOutboxRecordSource.assessmentDraft,
          recordId: 'd-v1',
          familyId: familyA.id.value,
          childId: childA.id.value,
          actorUserId: 'adult-a',
        ),
      ]);
      final legacyContainer = ProviderContainer(
        overrides: [
          authSessionPortProvider.overrideWithValue(fakeAuth),
          localMetadataStoreProvider.overrideWithValue(legacyStore),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(
            legacyProvenance,
          ),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              legacyStore,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(legacyContainer.dispose);

      final legacyCtrl = legacyContainer.read(
        sessionContainmentProvider.notifier,
      );
      await legacyCtrl.rehydrate();
      expect(
        legacyContainer.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      final v1Unlock = await legacyCtrl.submitParentGateUnlock('2580');
      expect(v1Unlock.isAuthorizedToExitChildMode, isTrue);
      expect(v1Unlock.upgradedFromV1, isTrue);
      final v2Cred = ParentGateCredentialV2.tryParse(
        await legacyStore.readMetadata(ParentGateService.credentialV2Key),
        minIterations: 1000,
      );
      expect(v2Cred, isNotNull);
      expect(v2Cred?.ownerFamilyId, equals(familyA.id.value));
      expect(
        await legacyStore.readMetadata(ParentGateService.pinHashKey),
        isNull,
      );
    });

    test('CorroboratedLegacyOwner Exit Path B auto-unlocks ONLY for fresh verified adult matching corroborated family', () async {
      final store = InMemoryLocalMetadataStore();
      await store.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: jsonEncode({
          'id': childA.id.value,
          'family_id': familyA.id.value,
          'display_name': childA.displayName,
        }),
        updatedAt: nowUtc,
      );
      final provenance = InMemoryLegacyOutboxProvenanceSource([
        ActorBoundOutboxRecord(
          source: LegacyOutboxRecordSource.assessmentDraft,
          recordId: 'd-corrob',
          familyId: familyA.id.value,
          childId: childA.id.value,
          actorUserId: 'adult-a',
        ),
      ]);
      final fakeAuth = FakeAuthSessionPort(
        activeUserId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-legacy-1',
      );
      final verifier = FakeContainmentAuthorizationVerifier(
        onVerify: (call) async {
          if (call.context.userId == 'adult-a') {
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: familyA,
              verifiedFamilies: [familyA],
              verifiedRolesByFamilyId: {
                familyA.id.value: VerifiedAdultRole.owner,
              },
            );
          }
          return AuthorizedActiveAdult(
            verifiedRole: VerifiedAdultRole.owner,
            verifiedFamily: familyB,
            verifiedFamilies: [familyB],
            verifiedRolesByFamilyId: {
              familyB.id.value: VerifiedAdultRole.owner,
            },
          );
        },
      );

      final container = ProviderContainer(
        overrides: [
          authSessionPortProvider.overrideWithValue(fakeAuth),
          localMetadataStoreProvider.overrideWithValue(store),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(provenance),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          restrictedShellSignOutProvider.overrideWithValue(() async {
            fakeAuth.invalidateSession();
          }),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              store,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(sessionContainmentProvider.notifier);
      await ctrl.rehydrate();
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      await ctrl.signOutFromContainmentRecovery();
      final writtenLock = ContainmentRecoveryLockV1.parseStorageValue(
        await store.readMetadata(
          SessionLifecycleController.containmentRecoveryLockV1Key,
        ),
      );
      expect(writtenLock, isA<ValidContainmentRecoveryLockV1>());
      expect(
        (writtenLock as ValidContainmentRecoveryLockV1).lock.ownershipLevel,
        ContainmentRecoveryOwnershipLevel.corroboratedLegacy,
      );

      // Unrelated Family B login stays LOCKED.
      fakeAuth.setSession(
        userId: 'adult-b',
        role: 'owner',
        sessionGeneration: 'gen-b-fresh',
      );
      await ctrl.rehydrate();
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      // Fresh post-sign-out owning Adult A auto-clears Exit Path B -> ParentMode.
      fakeAuth.setSession(
        userId: 'adult-a',
        role: 'owner',
        sessionGeneration: 'gen-a-fresh',
      );
      await ctrl.rehydrate();
      expect(
        container.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.verifiedParentMode,
      );
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );
    });
  });
}
