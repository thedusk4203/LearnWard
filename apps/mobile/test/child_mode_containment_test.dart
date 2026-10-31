import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/routing/app_routes.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

class _PresetFamilyNotifier extends ActiveFamilyNotifier {
  _PresetFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

void main() {
  group('Shared-Device Child Mode Containment and Router Guard', () {
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

    testWidgets('entering Child Mode persists state to local store', (
      tester,
    ) async {
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

      // Enter Child Mode
      await tester.tap(
        find.byKey(Key('enter_child_mode_${testChild.id.value}')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Hi, Leo!'), findsOneWidget);

      // Verify that local store contains the persisted child session
      final storedSession = await store.readMetadata(
        ActiveChildModeNotifier.activeSessionKey,
      );
      expect(storedSession, isNotNull);
      expect(storedSession, contains('child-smith-1'));
      expect(storedSession, contains('Leo'));
    });

    testWidgets(
      'app restart with persisted Child Mode boots directly into Child Mode',
      (tester) async {
        // Pre-seed store with persisted child session (simulating previous app run)
        await store.writeMetadata(
          key: ActiveChildModeNotifier.activeSessionKey,
          value: '{"id":"child-smith-1","family_id":"fam-containment","display_name":"Leo","school_grade":5,"status":"active","created_at":"2026-10-31T00:00:00.000Z"}',
          updatedAt: DateTime.now().toUtc(),
        );

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

        // Should immediately be in Child Mode without showing Parent UI
        expect(find.text('Hi, Leo!'), findsOneWidget);
        expect(find.text('Welcome to LearnWard, Leo!'), findsOneWidget);
        expect(find.text('The Smiths'), findsNothing);
      },
    );

    testWidgets(
      'router guard intercepts attempt to navigate to /parent and redirects to /child',
      (tester) async {
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

        // Directly attempt navigation to /parent via GoRouter context
        final context = tester.element(find.byType(Scaffold));
        GoRouter.of(context).go(AppRoutes.parentHome);
        await tester.pumpAndSettle();

        // Router guard forces redirect back to /child
        expect(find.text('Hi, Leo!'), findsOneWidget);
        expect(find.text('The Smiths'), findsNothing);
      },
    );

    testWidgets(
      'incorrect Parent Gate PIN remains in Child Mode; correct PIN exits to Parent Mode',
      (tester) async {
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

        // Enter WRONG PIN
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '9999',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        // Error message shown and dialog stays open
        expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);
        expect(find.text('Parent Gate'), findsOneWidget);

        // Now enter CORRECT default PIN (1234)
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '1234',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        // Dialog is dismissed and Parent Mode is unlocked
        expect(find.text('Parent Gate'), findsNothing);
        expect(find.text('The Smiths'), findsOneWidget);
        expect(find.text('Parent Mode'), findsOneWidget);

        // Persisted metadata is cleared
        final storedSession = await store.readMetadata(
          ActiveChildModeNotifier.activeSessionKey,
        );
        expect(storedSession, isEmpty);
      },
    );
  });
}
