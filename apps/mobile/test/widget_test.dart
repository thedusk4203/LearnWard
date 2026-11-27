import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/features/shared_device/domain/parent_gate_service.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

class _PresetFamilyNotifier extends ActiveFamilyNotifier {
  _PresetFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

void main() {
  testWidgets('renders No Family Found state when user has no family', (
    tester,
  ) async {
    final fakeFamilyRepo = FakeFamilyRepository();
    final fakeChildRepo = FakeChildProfileRepository();
    final fakeStore = InMemoryLocalMetadataStore();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeStore),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(fakeStore, runInIsolate: false),
          ),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
        ],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No Family Found'), findsOneWidget);
    expect(find.byKey(const Key('create_family_button')), findsOneWidget);
  });

  testWidgets('renders Family Home with registered children', (tester) async {
    final now = DateTime.utc(2026, 10, 31);
    final family = Family(
      id: FamilyId('fam-alpha'),
      name: 'The Millers',
      timezone: 'UTC',
      locale: 'en_US',
      createdByUserId: 'user-1',
      createdAt: now,
    );
    final child = ChildProfile(
      id: ChildId('child-1'),
      familyId: family.id,
      displayName: 'Maya',
      schoolGrade: 6,
      birthYear: 2014,
      createdAt: now,
    );

    final fakeFamilyRepo = FakeFamilyRepository(
      currentUserId: 'user-1',
      families: [family],
      memberships: [
        FamilyMembership(
          familyId: family.id,
          authUserId: 'user-1',
          role: FamilyRole.owner,
          status: MembershipStatus.active,
          joinedAt: now,
        ),
      ],
    );
    final fakeChildRepo = FakeChildProfileRepository(children: [child]);
    final fakeStore = InMemoryLocalMetadataStore();
    // Pre-configure parent PIN with bound household authorization
    await ParentGateService(fakeStore, runInIsolate: false).setPin(
      '8392',
      ownerFamilyId: 'fam-alpha',
      configuredByActorUserId: 'user-1',
      hasPositiveServerAdultVerification: true,
      verifiedActiveAdultFamilyIds: const ['fam-alpha'],
      fence: const ParentGateOperationFence(
        actorUserId: 'user-1',
        sessionGeneration: 1,
        containmentEpoch: 1,
        expectedContainmentStatus: 'parent_mode',
        verifiedFamilyId: 'fam-alpha',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authSessionPortProvider.overrideWithValue(
            FakeAuthSessionPort(activeUserId: 'user-1'),
          ),
          localMetadataStoreProvider.overrideWithValue(fakeStore),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(fakeStore, runInIsolate: false),
          ),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          activeFamilyProvider.overrideWith(
            () => _PresetFamilyNotifier(family),
          ),
        ],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The Millers'), findsOneWidget);
    expect(find.text('Parent Mode'), findsOneWidget);
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Grade 6 • Born 2014 • Status: active'), findsOneWidget);
    expect(find.byKey(const Key('enter_child_mode_child-1')), findsOneWidget);
  });

  testWidgets('enters Child Mode and exits via Parent Gate challenge', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 10, 31);
    final family = Family(
      id: FamilyId('fam-alpha'),
      name: 'The Millers',
      timezone: 'UTC',
      locale: 'en_US',
      createdByUserId: 'user-1',
      createdAt: now,
    );
    final child = ChildProfile(
      id: ChildId('child-1'),
      familyId: family.id,
      displayName: 'Maya',
      schoolGrade: 6,
      createdAt: now,
    );

    final fakeFamilyRepo = FakeFamilyRepository(
      currentUserId: 'user-1',
      families: [family],
      memberships: [
        FamilyMembership(
          familyId: family.id,
          authUserId: 'user-1',
          role: FamilyRole.owner,
          status: MembershipStatus.active,
          joinedAt: now,
        ),
      ],
    );
    final fakeChildRepo = FakeChildProfileRepository(children: [child]);
    final fakeStore = InMemoryLocalMetadataStore();
    // Pre-configure parent PIN with bound household authorization
    await ParentGateService(fakeStore, runInIsolate: false).setPin(
      '8392',
      ownerFamilyId: 'fam-alpha',
      configuredByActorUserId: 'user-1',
      hasPositiveServerAdultVerification: true,
      verifiedActiveAdultFamilyIds: const ['fam-alpha'],
      fence: const ParentGateOperationFence(
        actorUserId: 'user-1',
        sessionGeneration: 1,
        containmentEpoch: 1,
        expectedContainmentStatus: 'parent_mode',
        verifiedFamilyId: 'fam-alpha',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authSessionPortProvider.overrideWithValue(
            FakeAuthSessionPort(activeUserId: 'user-1'),
          ),
          localMetadataStoreProvider.overrideWithValue(fakeStore),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(fakeStore, runInIsolate: false),
          ),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          activeFamilyProvider.overrideWith(
            () => _PresetFamilyNotifier(family),
          ),
        ],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Enter Child Mode
    await tester.tap(find.byKey(const Key('enter_child_mode_child-1')));
    await tester.pumpAndSettle();

    // Verify restricted Child Mode screen is active
    expect(find.text('Hi, Maya!'), findsOneWidget);
    expect(find.text('Welcome to LearnWard, Maya!'), findsOneWidget);
    expect(find.text('Shared-Device Child Mode'), findsOneWidget);

    // Tap Exit Child Mode button
    await tester.tap(find.byKey(const Key('exit_child_mode_button')));
    await tester.pumpAndSettle();

    // Parent Gate is now backed by WP3 SessionLifecycleController; cancel stays in Child Mode,
    // and valid PIN (4829) unlocks cleanly back into Parent Mode.
    expect(find.text('Parent Gate'), findsOneWidget);
    await tester.tap(find.byKey(const Key('parent_gate_cancel_button')));
    await tester.pumpAndSettle();

    expect(find.text('Hi, Maya!'), findsOneWidget);
    expect(find.text('Parent Mode'), findsNothing);

    await tester.tap(find.byKey(const Key('exit_child_mode_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('parent_gate_pin_field')),
      '8392',
    );
    await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
    await tester.pumpAndSettle();

    expect(find.text('Parent Mode'), findsOneWidget);
    expect(find.text('Hi, Maya!'), findsNothing);
  });
}
