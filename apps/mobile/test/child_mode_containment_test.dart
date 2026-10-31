import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/routing/app_routes.dart';
import 'package:learnward/features/shared_device/domain/parent_gate_service.dart';
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
      'no PIN configured: cannot enter Child Mode without configuring PIN (cancelling cancels entry)',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
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

        // PIN setup dialog must be presented because no PIN exists
        expect(find.byType(ParentPinSetupDialog), findsOneWidget);
        expect(find.text('Set Parent PIN'), findsOneWidget);

        // Cancel dialog
        await tester.tap(find.byKey(const Key('parent_pin_setup_cancel')));
        await tester.pumpAndSettle();

        // Must still be in Parent Mode
        expect(find.text('The Smiths'), findsOneWidget);
        expect(find.text('Parent Mode'), findsOneWidget);
        expect(find.text('Hi, Leo!'), findsNothing);
      },
    );

    testWidgets(
      'setting PIN 8392 never stores plaintext, enters Child Mode, and persists session',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
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

        expect(find.byType(ParentPinSetupDialog), findsOneWidget);

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

        // Enter matching confirmation
        await tester.enterText(
          find.byKey(const Key('parent_pin_confirm_field')),
          '8392',
        );
        await tester.tap(find.byKey(const Key('parent_pin_setup_submit')));
        await tester.pumpAndSettle();

        // Successfully entered Child Mode
        expect(find.text('Hi, Leo!'), findsOneWidget);

        // Verify plaintext 8392 is NOT present in storage
        final storedHash = await store.readMetadata(
          ParentGateService.pinHashKey,
        );
        final storedSalt = await store.readMetadata(
          ParentGateService.pinSaltKey,
        );
        expect(storedHash, isNotNull);
        expect(storedSalt, isNotNull);
        expect(storedHash, isNot(contains('8392')));
        expect(storedSalt, isNot(contains('8392')));

        // Verify active child session is persisted
        final storedSession = await store.readMetadata(
          ActiveChildModeNotifier.activeSessionKey,
        );
        expect(storedSession, contains('child-smith-1'));
        expect(storedSession, contains('Leo'));
      },
    );

    testWidgets(
      'exit Child Mode with 1234 FAILS; exit with configured PIN 8392 PASSES',
      (tester) async {
        // Pre-configure PIN 8392
        await ParentGateService(store).setPin('8392');

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
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

        // Tap Exit Child Mode
        await tester.tap(find.byKey(const Key('exit_child_mode_button')));
        await tester.pumpAndSettle();

        expect(find.text('Parent Gate'), findsOneWidget);

        // Attempt default PIN 1234 -> MUST FAIL
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '1234',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);
        expect(find.text('Parent Gate'), findsOneWidget);

        // Attempt configured PIN 8392 -> MUST PASS
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '8392',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        // Unlocked to Parent Mode
        expect(find.text('Parent Gate'), findsNothing);
        expect(find.text('The Smiths'), findsOneWidget);
        expect(find.text('Parent Mode'), findsOneWidget);
      },
    );

    testWidgets(
      'restart while Child Mode is active remains locked and requires same configured PIN 8392',
      (tester) async {
        // Pre-configure PIN 8392 and persist active child session
        await ParentGateService(store).setPin('8392');
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

        // Exit Child Mode
        await tester.tap(find.byKey(const Key('exit_child_mode_button')));
        await tester.pumpAndSettle();

        // 1234 fails
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '1234',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();
        expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);

        // 8392 succeeds
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '8392',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        expect(find.text('The Smiths'), findsOneWidget);
        expect(find.text('Parent Mode'), findsOneWidget);
      },
    );
  });
}
