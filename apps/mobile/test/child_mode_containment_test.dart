import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/routing/app_routes.dart';
import 'package:learnward/features/shared_device/domain/parent_gate_service.dart';
import 'package:learnward/features/shared_device/presentation/parent_gate_dialog.dart';
import 'package:learnward/features/shared_device/presentation/parent_pin_setup_dialog.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

class _PresetFamilyNotifier extends ActiveFamilyNotifier {
  _PresetFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

void main() {
  group('Shared-Device Child Mode Containment and Parent PIN Security', () {
    late InMemoryLocalMetadataStore store;
    late Family testFamily;
    late ChildProfile testChild;
    late FakeFamilyRepository fakeFamilyRepo;
    late FakeChildProfileRepository fakeChildRepo;

    const setupFence = ParentGateOperationFence(
      actorUserId: 'user-smith',
      sessionGeneration: 1,
      containmentEpoch: 1,
      expectedContainmentStatus: 'parent_mode',
      verifiedFamilyId: 'fam-containment',
    );
    const exitFence = ParentGateOperationFence(
      actorUserId: 'user-smith',
      sessionGeneration: 1,
      containmentEpoch: 1,
      expectedContainmentStatus: 'active_child',
      verifiedFamilyId: 'fam-containment',
      expectedChildId: 'child-smith-1',
    );

    setUp(() {
      store = InMemoryLocalMetadataStore();
      final now = DateTime.utc(2026, 10, 31);
      testFamily = Family(
        id: FamilyId('fam-containment'),
        name: 'The Smiths',
        timezone: 'UTC',
        locale: 'en_US',
        createdByUserId: 'user-smith',
        createdAt: now,
      );
      testChild = ChildProfile(
        id: ChildId('child-smith-1'),
        familyId: testFamily.id,
        displayName: 'Leo',
        schoolGrade: 5,
        createdAt: now,
      );
      fakeFamilyRepo = FakeFamilyRepository(
        currentUserId: 'user-smith',
        families: [testFamily],
        memberships: [
          FamilyMembership(
            familyId: testFamily.id,
            authUserId: 'user-smith',
            role: FamilyRole.owner,
            status: MembershipStatus.active,
            joinedAt: now,
          ),
        ],
      );
      fakeChildRepo = FakeChildProfileRepository(children: [testChild]);
    });

    testWidgets(
      'no PIN configured: FamilyHomeScreen opens ParentPinSetupDialog fail-closed and cannot enter Child Mode without verified delegate',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
              parentGateServiceProvider.overrideWithValue(
                ParentGateService(store, runInIsolate: false),
              ),
              familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
              childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
              activeFamilyProvider.overrideWith(
                () => _PresetFamilyNotifier(testFamily),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Tap enter Child Mode
        await tester.tap(
          find.byKey(Key('enter_child_mode_${testChild.id.value}')),
        );
        await tester.pumpAndSettle();

        // PIN setup dialog presented in fail-closed restricted state (R39-04)
        expect(find.byType(ParentPinSetupDialog), findsOneWidget);
        expect(find.text('Set Parent PIN'), findsOneWidget);
        expect(
          find.byKey(const Key('parent_pin_setup_restricted_notice')),
          findsOneWidget,
        );
        final submitButton = tester.widget<FilledButton>(
          find.byKey(const Key('parent_pin_setup_submit')),
        );
        expect(submitButton.onPressed, isNull);

        // Cancel dialog -> stays in Parent Mode with zero PIN written
        await tester.tap(find.byKey(const Key('parent_pin_setup_cancel')));
        await tester.pumpAndSettle();

        expect(find.text('The Smiths'), findsOneWidget);
        expect(find.text('Parent Mode'), findsOneWidget);
        expect(find.text('Hi, Leo!'), findsNothing);
        expect(
          await store.readMetadata(ParentGateService.credentialV2Key),
          isNull,
        );
      },
    );

    testWidgets(
      'setting PIN 8392 via authorized delegate never stores plaintext and validates mismatched confirmations',
      (tester) async {
        final gateService = ParentGateService(store, runInIsolate: false);
        var saved = false;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
              parentGateServiceProvider.overrideWithValue(gateService),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => ElevatedButton(
                  key: const Key('open_authorized_setup'),
                  onPressed: () async {
                    saved = await ParentPinSetupDialog.show(
                      context,
                      onSavePin: (pin) => gateService.setPin(
                        pin,
                        ownerFamilyId: testFamily.id.value,
                        configuredByActorUserId: 'user-smith',
                        hasPositiveServerAdultVerification: true,
                        verifiedActiveAdultFamilyIds: [testFamily.id.value],
                        fence: setupFence,
                      ),
                    );
                  },
                  child: const Text('Configure PIN'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('open_authorized_setup')));
        await tester.pumpAndSettle();

        // Enter PIN and mismatched confirmation
        await tester.enterText(
          find.byKey(const Key('parent_pin_setup_field')),
          '8392',
        );
        await tester.enterText(
          find.byKey(const Key('parent_pin_confirm_field')),
          '0000',
        );
        await tester.tap(find.byKey(const Key('parent_pin_setup_submit')));
        await tester.pumpAndSettle();

        expect(
          find.text('PINs do not match. Please verify and re-enter.'),
          findsOneWidget,
        );
        expect(saved, isFalse);

        // Enter matching confirmation
        await tester.enterText(
          find.byKey(const Key('parent_pin_confirm_field')),
          '8392',
        );
        await tester.tap(find.byKey(const Key('parent_pin_setup_submit')));
        await tester.pumpAndSettle();

        expect(saved, isTrue);

        // Verify plaintext 8392 is NOT present in storage and owned v2 PBKDF2 credential is stored
        final rawV2 = await store.readMetadata(
          ParentGateService.credentialV2Key,
        );
        final parsedV2 = ParentGateCredentialV2.tryParse(rawV2);
        expect(parsedV2, isNotNull);
        expect(parsedV2!.iterations, greaterThanOrEqualTo(100000));
        expect(parsedV2.ownerFamilyId, equals(testFamily.id.value));
        expect(parsedV2.configuredByActorUserId, equals('user-smith'));
        expect(rawV2, isNot(contains('8392')));
        expect(await store.readMetadata(ParentGateService.pinHashKey), isNull);
        expect(await store.readMetadata(ParentGateService.pinSaltKey), isNull);
      },
    );

    testWidgets(
      'exit Child Mode via authorized delegate: 1234 FAILS; verified 8392 PASSES; unfenced ChildModeScreen fails closed',
      (tester) async {
        final gateService = ParentGateService(store, runInIsolate: false);
        await gateService.setPin(
          '8392',
          ownerFamilyId: testFamily.id.value,
          configuredByActorUserId: 'user-smith',
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: [testFamily.id.value],
          fence: setupFence,
        );

        // Part A: ChildModeScreen without WP3 delegate fails closed (R39-05)
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
              parentGateServiceProvider.overrideWithValue(gateService),
              initialChildModeSessionProvider.overrideWithValue(testChild),
              familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
              childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
              activeFamilyProvider.overrideWith(
                () => _PresetFamilyNotifier(testFamily),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('exit_child_mode_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('parent_gate_restricted_notice')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('parent_gate_verify_button')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const Key('parent_gate_cancel_button')));
        await tester.pumpAndSettle();
        expect(find.text('Hi, Leo!'), findsOneWidget);

        // Part B: Authorized delegate rejects 1234 and approves 8392
        var gatePassed = false;
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
              parentGateServiceProvider.overrideWithValue(gateService),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => ElevatedButton(
                  key: const Key('open_authorized_gate'),
                  onPressed: () => ParentGateDialog.show(
                    context,
                    onGatePassed: () => gatePassed = true,
                    onSubmitPin: (pin) => gateService.verifyPinDetailed(
                      pin,
                      actorFamilyId: testFamily.id.value,
                      actorUserId: 'user-smith',
                      hasPositiveServerAdultVerification: true,
                      verifiedActiveAdultFamilyIds: [testFamily.id.value],
                      fence: exitFence,
                    ),
                  ),
                  child: const Text('Gate'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('open_authorized_gate')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '1234',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);
        expect(gatePassed, isFalse);

        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '8392',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        expect(gatePassed, isTrue);
        expect(find.byType(ParentGateDialog), findsNothing);
      },
    );

    testWidgets(
      'restart while Child Mode is active remains locked against /parent and fails closed on Exit Child Mode without WP3 delegate',
      (tester) async {
        // Pre-configure owned PIN 8392 and persist active child session
        await ParentGateService(store, runInIsolate: false).setPin(
          '8392',
          ownerFamilyId: testFamily.id.value,
          configuredByActorUserId: 'user-smith',
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: [testFamily.id.value],
          fence: setupFence,
        );
        await store.writeMetadata(
          key: ActiveChildModeNotifier.activeSessionKey,
          value: '{"id":"child-smith-1","family_id":"fam-containment","display_name":"Leo","school_grade":5,"status":"active","created_at":"2026-10-31T00:00:00.000Z"}',
          updatedAt: DateTime.now().toUtc(),
        );

        // Launch app
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
              parentGateServiceProvider.overrideWithValue(
                ParentGateService(store, runInIsolate: false),
              ),
              initialChildModeSessionProvider.overrideWithValue(testChild),
              familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
              childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
              activeFamilyProvider.overrideWith(
                () => _PresetFamilyNotifier(testFamily),
              ),
            ],
            child: const LearnWardApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Should boot directly into Child Mode
        expect(find.text('Hi, Leo!'), findsOneWidget);
        expect(find.text('The Smiths'), findsNothing);

        // Attempt router navigation to /parent
        final context = tester.element(find.byType(Scaffold));
        GoRouter.of(context).go(AppRoutes.parentHome);
        await tester.pumpAndSettle();

        // Router guard forced back to /child
        expect(find.text('Hi, Leo!'), findsOneWidget);
        expect(find.text('The Smiths'), findsNothing);

        // Exit Child Mode stays fail-closed while WP3 delegate is absent
        await tester.tap(find.byKey(const Key('exit_child_mode_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('parent_gate_restricted_notice')),
          findsOneWidget,
        );
      },
    );
  });
}
