import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/cold_start_containment_bootstrap.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart'
    as mobile_mem;
import 'package:learnward/app/routing/app_router.dart';
import 'package:learnward/app/routing/app_routes.dart';
import 'package:learnward/features/assessments/services/local_evidence_file_store.dart';
import 'package:learnward/features/auth/presentation/auth_screen.dart';
import 'package:learnward/features/child/presentation/child_mode_screen.dart';
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

Future<AppDatabase> _openDb(Directory dir, String filename) async =>
    AppDatabase(NativeDatabase(File(p.join(dir.path, filename))));

void main() {
  setUpAll(() {
    _ensureSqliteInitialized();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  final nowUtc = DateTime.utc(2026, 11, 28, 12, 0);

  final familyA = Family(
    id: FamilyId('fam-a'),
    name: 'Alpha Family',
    timezone: 'UTC',
    locale: 'en_US',
    createdByUserId: 'adult-a',
    createdAt: DateTime.utc(2026, 10, 31),
  );
  final familyB = Family(
    id: FamilyId('fam-b'),
    name: 'Bravo Family',
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

  void setActor(
    FakeAuthSessionPort port, {
    required String userId,
    required String sessionGeneration,
    String role = 'owner',
    bool isAnonymous = false,
  }) {
    port.setContext(
      ValidatedActorContext(
        userId: userId,
        sessionGeneration: sessionGeneration,
        observedAt: nowUtc,
        role: role,
        isAnonymous: isAnonymous,
      ),
    );
  }

  Future<ParentGateCredentialV2> seedBoundPin(
    LocalMetadataStore store, {
    required String pin,
    required String ownerFamilyId,
    required String actorUserId,
  }) {
    final service = ParentGateService(
      store,
      clock: FixedClock(nowUtc),
      minIterations: 1000,
      configuredIterations: 1000,
      runInIsolate: false,
    );
    return service.setPin(
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

  Future<({String path, String sha256Hex, List<int> bytes})> writeEvidenceFile(
    DefaultLocalEvidenceFileStore fileStore, {
    required String draftId,
  }) async {
    final bytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 0xD9];
    final path = await fileStore.saveDurableEvidence(
      localDraftId: draftId,
      bytes: bytes,
      mediaType: 'image/jpeg',
    );
    return (
      path: path,
      sha256Hex: sha256.convert(bytes).toString(),
      bytes: bytes,
    );
  }

  group('Group A — Auth, Routing, Offline Exit & Paired/Revoked Containment (C0-01..C0-13, C0-19, C0-28, C0-29, C0-36)', () {
    test('C0-01: Signed-out file-backed SQLite boot with persisted v2 and legacy v1 sessions stays unauthenticated and preserves drafts, commands, PIN, and photos', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp4_c001_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });
      final db = await _openDb(tempDir, 'c0_01.sqlite');
      var dbClosed = false;
      Future<void> closeDb() async {
        if (!dbClosed) {
          dbClosed = true;
          await db.close();
        }
      }

      addTearDown(closeDb);

      final fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
      final photo = await writeEvidenceFile(fileStore, draftId: 'd-c001');
      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'd-c001',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createCommandId: 'cmd-c-01',
          submitCommandId: 'cmd-s-01',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Signed Out Draft',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8,
          maxScore: 10,
          localCompressedPhotoPath: photo.path,
          sha256Checksum: photo.sha256Hex,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-spin-01',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createdAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await seedBoundPin(
        db,
        pin: '8392',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );

      // First verify signed-out boot with v2 envelope, then legacy v1 envelope.
      for (final sessionValue in [
        PersistedChildModeSession(
          modeKind: PersistedChildModeKind.sharedDeviceAdult,
          actorUserId: 'adult-a',
          familyId: familyA.id,
          childId: childA.id,
          childProfileSnapshot: childA,
          persistedAtUtc: nowUtc,
        ).toJsonString(),
        jsonEncode({
          'id': childA.id.value,
          'family_id': familyA.id.value,
          'display_name': childA.displayName,
        }),
      ]) {
        await db.writeMetadata(
          key: ActiveChildModeNotifier.activeSessionKey,
          value: sessionValue,
          updatedAt: nowUtc,
        );
        final fakeAuth = FakeAuthSessionPort(activeUserId: null);
        final verifier = FakeContainmentAuthorizationVerifier();
        final container = ProviderContainer(
          overrides: [
            appConfigProvider.overrideWithValue(
              const AppConfig(
                environment: AppEnvironment.production,
                supabaseUrl: 'https://test.supabase.co',
                supabasePublishableKey: 'anon-key',
              ),
            ),
            appClockProvider.overrideWithValue(() => nowUtc),
            authSessionPortProvider.overrideWithValue(fakeAuth),
            localMetadataStoreProvider.overrideWithValue(db),
            localDraftStoreProvider.overrideWithValue(db),
            pendingRewardCommandStoreProvider.overrideWithValue(db),
            legacyOutboxProvenanceSourceProvider.overrideWithValue(db),
            containmentAuthorizationVerifierProvider.overrideWithValue(
              verifier,
            ),
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
        await container.read(sessionContainmentProvider.notifier).rehydrate();
        expect(
          container.read(sessionContainmentProvider).status,
          ColdStartContainmentStatus.unauthenticated,
        );
        expect(container.read(activeChildModeProvider), isNull);
        expect(container.read(activeFamilyProvider), isNull);
        expect(verifier.calls, isEmpty);
        container.dispose();
      }

      await Future<void>.delayed(Duration.zero);
      await closeDb();

      final reopened = await _openDb(tempDir, 'c0_01.sqlite');
      addTearDown(reopened.close);
      expect(await reopened.getLocalDraft('d-c001'), isNotNull);
      expect(await reopened.getPendingCommand('cmd-spin-01'), isNotNull);
      expect(
        await reopened.readMetadata(ParentGateService.credentialV2Key),
        isNotNull,
      );
      expect(
        sha256.convert(await File(photo.path).readAsBytes()).toString(),
        equals(photo.sha256Hex),
      );
    });

    testWidgets(
      'C0-02: Live expired session and auth stream error force GoRouter /child -> /auth fail-closed with zero RPCs',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        await seedBoundPin(
          store,
          pin: '8392',
          ownerFamilyId: familyA.id.value,
          actorUserId: 'supa-adult-a',
        );
        final sessionJson = PersistedChildModeSession(
          modeKind: PersistedChildModeKind.sharedDeviceAdult,
          actorUserId: 'supa-adult-a',
          familyId: familyA.id,
          childId: childA.id,
          childProfileSnapshot: childA,
          persistedAtUtc: nowUtc,
        ).toJsonString();
        await store.writeMetadata(
          key: ActiveChildModeNotifier.activeSessionKey,
          value: sessionJson,
          updatedAt: nowUtc,
        );

        final user = User(
          id: 'supa-adult-a',
          appMetadata: const {'role': 'owner'},
          userMetadata: const {},
          aud: 'authenticated',
          createdAt: nowUtc.toIso8601String(),
        );
        String jwtWithExp(DateTime expUtc) {
          final headerB64 = base64Url
              .encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})))
              .replaceAll('=', '');
          final payloadB64 = base64Url
              .encode(
                utf8.encode(
                  jsonEncode({
                    'sub': 'supa-adult-a',
                    'exp': expUtc.millisecondsSinceEpoch ~/ 1000,
                  }),
                ),
              )
              .replaceAll('=', '');
          return '$headerB64.$payloadB64.sig';
        }

        final wallNow = DateTime.now().toUtc();
        final validSession = Session(
          accessToken: jwtWithExp(wallNow.add(const Duration(hours: 1))),
          tokenType: 'bearer',
          user: user,
          expiresIn: 3600,
        );
        final expiredSession = Session(
          accessToken: jwtWithExp(wallNow.subtract(const Duration(minutes: 5))),
          tokenType: 'bearer',
          user: user,
          expiresIn: -300,
        );

        final client = SupabaseClient(
          'https://test.supabase.co',
          'anon-key',
          authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: EmptyLocalStorage(),
          ),
        );
        final authStream = StreamController<AuthState>.broadcast();
        addTearDown(() async {
          await authStream.close();
          unawaited(client.dispose());
        });

        var currentSess = validSession;
        final verifierCallsBeforeStop = <ContainmentVerificationCall>[];
        final verifier = FakeContainmentAuthorizationVerifier(
          onVerify: (call) async {
            verifierCallsBeforeStop.add(call);
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: familyA,
              verifiedFamilies: [familyA],
              verifiedRolesByFamilyId: {
                familyA.id.value: VerifiedAdultRole.owner,
              },
              verifiedChild: childA,
            );
          },
        );

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(
                const AppConfig(
                  environment: AppEnvironment.production,
                  supabaseUrl: 'https://test.supabase.co',
                  supabasePublishableKey: 'anon-key',
                ),
              ),
              supabaseClientProvider.overrideWithValue(client),
              authStateProvider.overrideWith((ref) => authStream.stream),
              authSessionPortProvider.overrideWith((ref) {
                final adapter = _StreamBackedSupabaseAuthAdapter(
                  client: client,
                  clock: FixedClock(nowUtc),
                  stream: authStream.stream,
                  sessionGetter: () => currentSess,
                );
                ref.onDispose(adapter.dispose);
                return adapter;
              }),
              localMetadataStoreProvider.overrideWithValue(store),
              growthRepositoryProvider.overrideWithValue(
                mobile_mem.InMemoryGrowthRepository(),
              ),
              rewardRepositoryProvider.overrideWithValue(
                mobile_mem.InMemoryRewardRepository(),
              ),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
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
        authStream.add(AuthState(AuthChangeEvent.signedIn, validSession));
        await tester.pumpAndSettle();
        expect(find.byType(ChildModeScreen), findsOneWidget);
        final callsInChildMode = verifierCallsBeforeStop.length;

        // Inject live expired token -> fail closed immediately to /auth with zero extra verifier RPCs
        currentSess = expiredSession;
        authStream.add(
          AuthState(AuthChangeEvent.tokenRefreshed, expiredSession),
        );
        await tester.pumpAndSettle();

        expect(container.read(currentUserIdProvider), isNull);
        expect(
          container.read(authSessionStateProvider).isAuthenticated,
          isFalse,
        );
        expect(find.byType(AuthScreen), findsOneWidget);
        expect(find.byType(ChildModeScreen), findsNothing);
        expect(verifierCallsBeforeStop.length, equals(callsInChildMode));

        // Recover briefly and inject sticky stream error -> also routes /child -> /auth
        currentSess = validSession;
        authStream.add(AuthState(AuthChangeEvent.signedIn, validSession));
        await tester.pumpAndSettle();
        expect(find.byType(ChildModeScreen), findsOneWidget);

        authStream.addError(Exception('network refresh failure'));
        await tester.pumpAndSettle();
        expect(container.read(currentUserIdProvider), isNull);
        expect(
          container.read(authSessionStateProvider).isFailClosedInvalidated,
          isTrue,
        );
        expect(find.byType(AuthScreen), findsOneWidget);
      },
    );

    test('C0-06: Actor A -> B -> A lifecycle on file-backed SQLite preserves draft IDs, SHA-256 photo bytes, and pauses/retains Actor A reward command', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp4_c006_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });
      final db = await _openDb(tempDir, 'c0_06.sqlite');
      addTearDown(() async {
        await db.close();
      });
      final fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
      final photo = await writeEvidenceFile(fileStore, draftId: 'd-c006');
      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'd-c006',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createCommandId: 'cmd-c-06',
          submitCommandId: 'cmd-s-06',
          subjectKey: SubjectKey.science,
          subject: 'Science',
          title: 'Actor A Roundtrip Draft',
          assessmentType: 'homework',
          difficulty: 'normal',
          rawScore: 9.5,
          maxScore: 10,
          localCompressedPhotoPath: photo.path,
          sha256Checksum: photo.sha256Hex,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-redeem-c006',
          familyId: familyA.id.value,
          childId: childA.id.value,
          rewardId: 'rew-1',
          createdAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );

      final fakeAuth = FakeAuthSessionPort(activeUserId: null);
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-1');
      final verifier = FakeContainmentAuthorizationVerifier(
        onVerify: (call) async {
          final fam = call.context.userId == 'adult-a' ? familyA : familyB;
          return AuthorizedActiveAdult(
            verifiedRole: VerifiedAdultRole.owner,
            verifiedFamily: fam,
            verifiedFamilies: [fam],
            verifiedRolesByFamilyId: {fam.id.value: VerifiedAdultRole.owner},
          );
        },
      );
      final container = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          restrictedShellSignOutProvider.overrideWithValue(
            () async => fakeAuth.signOut(),
          ),
          localMetadataStoreProvider.overrideWithValue(db),
          localDraftStoreProvider.overrideWithValue(db),
          pendingRewardCommandStoreProvider.overrideWithValue(db),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db),
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

      final ctrl = container.read(sessionContainmentProvider.notifier);
      await ctrl.rehydrate();
      await ctrl.signOutNormal();

      setActor(fakeAuth, userId: 'adult-b', sessionGeneration: 'gen-b-1');
      await ctrl.rehydrate();
      final pausedCmd = await db.getPendingCommand('cmd-redeem-c006');
      expect(
        pausedCmd?.recoveryState,
        CommandRecoveryState.pendingOriginalActor,
      );
      expect(pausedCmd?.actorUserId, 'adult-a');

      await ctrl.signOutNormal();
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-2');
      await ctrl.rehydrate();

      final restoredDraft = await db.getLocalDraft('d-c006');
      expect(restoredDraft?.createCommandId, 'cmd-c-06');
      expect(restoredDraft?.submitCommandId, 'cmd-s-06');
      expect(restoredDraft?.actorUserId, 'adult-a');
      expect(restoredDraft?.sha256Checksum, photo.sha256Hex);
      expect(
        sha256.convert(await File(photo.path).readAsBytes()).toString(),
        equals(photo.sha256Hex),
      );
      final restoredCmd = await db.getPendingCommand('cmd-redeem-c006');
      expect(restoredCmd?.commandId, 'cmd-redeem-c006');
      expect(restoredCmd?.actorUserId, 'adult-a');
      await Future<void>.delayed(Duration.zero);
    });

    testWidgets(
      'C0-07 & C0-08: Family Switch drops prior family UI & increments epoch; online Child Mode restart resolves child reward stores and requires valid PIN to exit',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        await seedBoundPin(
          store,
          pin: '8392',
          ownerFamilyId: familyA.id.value,
          actorUserId: 'adult-a',
        );
        final fakeAuth = FakeAuthSessionPort(activeUserId: null);
        setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-1');
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
              authUserId: 'adult-a',
              role: FamilyRole.owner,
              status: MembershipStatus.active,
              joinedAt: nowUtc,
            ),
          ],
        );
        final childRepo = FakeChildProfileRepository(
          children: [childA, childB],
        );
        final rewardRepo = mobile_mem.InMemoryRewardRepository();
        await rewardRepo.createReward(
          familyId: familyA.id,
          title: 'Alpha Sticker',
          category: RewardCategory.item,
          storeCostMinor: 500,
        );
        final verifier = FakeContainmentAuthorizationVerifier(
          onVerify: (call) async {
            final targetFamId =
                call.persistedChildSession?.familyId ?? call.preferredFamilyId;
            final selectedFam = targetFamId == familyB.id ? familyB : familyA;
            final matchingChild = selectedFam.id == familyA.id
                ? childA
                : childB;
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: selectedFam,
              verifiedFamilies: [familyA, familyB],
              verifiedRolesByFamilyId: {
                familyA.id.value: VerifiedAdultRole.owner,
                familyB.id.value: VerifiedAdultRole.owner,
              },
              verifiedChild: matchingChild,
            );
          },
        );

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appClockProvider.overrideWithValue(() => nowUtc),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localMetadataStoreProvider.overrideWithValue(store),
              familyRepositoryProvider.overrideWithValue(familyRepo),
              childProfileRepositoryProvider.overrideWithValue(childRepo),
              rewardRepositoryProvider.overrideWithValue(rewardRepo),
              growthRepositoryProvider.overrideWithValue(
                mobile_mem.InMemoryGrowthRepository(),
              ),
              assessmentRepositoryProvider.overrideWithValue(
                FakeAssessmentRepository(),
              ),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
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

        // C0-07: Switch Family A -> Family B via FamilyHomeScreen switcher
        expect(find.byType(FamilyHomeScreen), findsOneWidget);
        expect(find.text('Alpha Family'), findsOneWidget);
        final initialEpoch = container
            .read(sessionContainmentProvider)
            .sessionScopeEpoch;

        await tester.tap(find.byKey(const Key('family_switcher_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('switch_family_${familyB.id.value}')));
        await tester.pumpAndSettle();

        expect(find.text('Bravo Family'), findsOneWidget);
        expect(find.text('Alpha Family'), findsNothing);
        expect(
          container.read(sessionContainmentProvider).sessionScopeEpoch,
          greaterThan(initialEpoch),
        );
        expect(
          ContainmentFenceV1.tryParse(
            await store.readMetadata(ParentGateService.containmentFenceV1Key),
          )?.fenceEpoch,
          greaterThanOrEqualTo(1),
        );

        // C0-08: Enter Child Mode (Family A), re-launch cold restart online -> /child, /parent blocked, reward stores work, wrong PIN fails, 8392 unlocks
        await store.writeMetadata(
          key: ActiveChildModeNotifier.activeSessionKey,
          value: PersistedChildModeSession(
            modeKind: PersistedChildModeKind.sharedDeviceAdult,
            actorUserId: 'adult-a',
            familyId: familyA.id,
            childId: childA.id,
            childProfileSnapshot: childA,
            persistedAtUtc: nowUtc,
          ).toJsonString(),
          updatedAt: nowUtc,
        );
        await container.read(sessionContainmentProvider.notifier).rehydrate();
        await tester.pumpAndSettle();

        expect(
          container.read(sessionContainmentProvider).status,
          ColdStartContainmentStatus.verifiedChildMode,
        );
        expect(find.byType(ChildModeScreen), findsOneWidget);

        container.read(routerProvider).go(AppRoutes.parentHome);
        await tester.pumpAndSettle();
        expect(find.byType(ChildModeScreen), findsOneWidget);

        container.read(routerProvider).go(AppRoutes.childStore);
        await tester.pumpAndSettle();
        expect(find.byType(ChildStoreScreen), findsOneWidget);

        container.read(routerProvider).go(AppRoutes.childRedemptions);
        await tester.pumpAndSettle();
        expect(find.byType(ChildRedemptionHistoryScreen), findsOneWidget);

        container.read(routerProvider).go(AppRoutes.childMode);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('exit_child_mode_button')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '1234',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();
        expect(find.byType(ChildModeScreen), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '8392',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();
        expect(find.byType(FamilyHomeScreen), findsOneWidget);
      },
    );

    testWidgets(
      'C0-09: Offline restart stays ChildModeOfflineContained, PIN unlock moves strictly to /account/unverified (never /parent), then reconnect opens /parent',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        await seedBoundPin(
          store,
          pin: '8392',
          ownerFamilyId: familyA.id.value,
          actorUserId: 'adult-a',
        );
        await store.writeMetadata(
          key: ActiveChildModeNotifier.activeSessionKey,
          value: PersistedChildModeSession(
            modeKind: PersistedChildModeKind.sharedDeviceAdult,
            actorUserId: 'adult-a',
            familyId: familyA.id,
            childId: childA.id,
            childProfileSnapshot: childA,
            persistedAtUtc: nowUtc,
          ).toJsonString(),
          updatedAt: nowUtc,
        );
        final fakeAuth = FakeAuthSessionPort(activeUserId: null);
        setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-1');
        final verifier = FakeContainmentAuthorizationVerifier(
          defaultOutcome: const SessionAuthorizationUnverified(
            reason: 'airplane_mode_offline',
            allowsOfflineChildContainment: true,
          ),
        );

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appClockProvider.overrideWithValue(() => nowUtc),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localMetadataStoreProvider.overrideWithValue(store),
              familyRepositoryProvider.overrideWithValue(
                FakeFamilyRepository(
                  currentUserId: 'adult-a',
                  families: [familyA],
                ),
              ),
              childProfileRepositoryProvider.overrideWithValue(
                FakeChildProfileRepository(children: [childA]),
              ),
              assessmentRepositoryProvider.overrideWithValue(
                FakeAssessmentRepository(),
              ),
              growthRepositoryProvider.overrideWithValue(
                mobile_mem.InMemoryGrowthRepository(),
              ),
              rewardRepositoryProvider.overrideWithValue(
                mobile_mem.InMemoryRewardRepository(),
              ),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
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

        expect(
          container.read(sessionContainmentProvider).status,
          ColdStartContainmentStatus.offlineContainedChildMode,
        );
        expect(find.byType(ChildModeScreen), findsOneWidget);

        // Deep-link /parent stays blocked offline
        container.read(routerProvider).go(AppRoutes.parentHome);
        await tester.pumpAndSettle();
        expect(find.byType(ChildModeScreen), findsOneWidget);

        // Solve Parent PIN while still offline -> transitions cleanly to AuthorizationUnverified (NEVER /parent)
        await tester.tap(find.byKey(const Key('exit_child_mode_button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '8392',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        expect(
          container.read(sessionContainmentProvider).status,
          ColdStartContainmentStatus.authorizationUnverified,
        );
        expect(
          find.byKey(const Key('cold_start_authorization_unverified_shell')),
          findsOneWidget,
        );
        expect(find.byType(FamilyHomeScreen), findsNothing);
        expect(container.read(activeFamilyProvider), isNull);
        expect(
          await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
          isNull,
        );

        // Reconnect with positive active adult verification -> Retry opens ParentMode
        verifier.defaultOutcome = AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA],
          verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
        );
        await tester.tap(find.byKey(const Key('cold_start_retry_button')));
        await tester.pumpAndSettle();
        expect(find.byType(FamilyHomeScreen), findsOneWidget);
      },
    );

    test('C0-10: Shared-device child archived OR RLS 0-row (TargetChildNotActiveOrVisible) locks into containmentLocked across file SQLite restart and preserves work', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp4_c010_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });
      final db1 = await _openDb(tempDir, 'c0_10.sqlite');
      var db1Closed = false;
      Future<void> closeDb1() async {
        if (!db1Closed) {
          db1Closed = true;
          await db1.close();
        }
      }

      addTearDown(closeDb1);

      final fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
      final photo = await writeEvidenceFile(fileStore, draftId: 'd-c010');
      await db1.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'd-c010',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createCommandId: 'cmd-c-10',
          submitCommandId: 'cmd-s-10',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Archived Child Draft',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8,
          maxScore: 10,
          localCompressedPhotoPath: photo.path,
          sha256Checksum: photo.sha256Hex,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await seedBoundPin(
        db1,
        pin: '8392',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );
      await db1.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: PersistedChildModeSession(
          modeKind: PersistedChildModeKind.sharedDeviceAdult,
          actorUserId: 'adult-a',
          familyId: familyA.id,
          childId: childA.id,
          childProfileSnapshot: childA,
          persistedAtUtc: nowUtc,
        ).toJsonString(),
        updatedAt: nowUtc,
      );

      final fakeAuth = FakeAuthSessionPort(activeUserId: null);
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-1');
      final verifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedAdultChildUnavailable(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA],
          verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
          reason: TargetChildUnavailabilityReason.notActiveOrRlsHidden,
          targetChildId: childA.id,
          targetFamilyId: familyA.id,
        ),
      );

      final c1 = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          restrictedShellSignOutProvider.overrideWithValue(
            () async => fakeAuth.signOut(),
          ),
          localMetadataStoreProvider.overrideWithValue(db1),
          localDraftStoreProvider.overrideWithValue(db1),
          pendingRewardCommandStoreProvider.overrideWithValue(db1),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db1),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              db1,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      final ctrl1 = c1.read(sessionContainmentProvider.notifier);
      await ctrl1.rehydrate();
      expect(
        c1.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );
      expect(c1.read(activeChildModeProvider), isNull);
      expect(c1.read(activeFamilyProvider), isNull);

      // Wrong PIN stays locked
      final wrongPin = await ctrl1.submitParentGateUnlock('0000');
      expect(wrongPin.outcome, PinVerificationOutcome.incorrectPin);
      expect(
        c1.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      c1.dispose();
      await Future<void>.delayed(Duration.zero);
      await closeDb1();

      // Restart with confirmedArchived -> still containmentLocked, then Exit Path A unlocks to ParentMode
      final db2 = await _openDb(tempDir, 'c0_10.sqlite');
      addTearDown(db2.close);
      verifier.defaultOutcome = AuthorizedAdultChildUnavailable(
        verifiedRole: VerifiedAdultRole.owner,
        verifiedFamily: familyA,
        verifiedFamilies: [familyA],
        verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
        reason: TargetChildUnavailabilityReason.confirmedArchived,
        targetChildId: childA.id,
        targetFamilyId: familyA.id,
      );

      final c2 = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          restrictedShellSignOutProvider.overrideWithValue(
            () async => fakeAuth.signOut(),
          ),
          localMetadataStoreProvider.overrideWithValue(db2),
          localDraftStoreProvider.overrideWithValue(db2),
          pendingRewardCommandStoreProvider.overrideWithValue(db2),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db2),
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
      addTearDown(c2.dispose);
      final ctrl2 = c2.read(sessionContainmentProvider.notifier);
      await ctrl2.rehydrate();
      expect(
        c2.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );

      final exitOk = await ctrl2.submitParentGateUnlock('8392');
      expect(exitOk.isAuthorizedToExitChildMode, isTrue);
      expect(
        c2.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.verifiedParentMode,
      );
      expect(await db2.getLocalDraft('d-c010'), isNotNull);
      expect(
        sha256.convert(await File(photo.path).readAsBytes()).toString(),
        equals(photo.sha256Hex),
      );
      await Future<void>.delayed(Duration.zero);
    });

    testWidgets(
      'C0-12 & C0-13: Paired-child active isolation, all 4 PairedChildUnverified causes, reconnect recovery -> /child or /child/revoked, sign-out & actor switch',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        await seedBoundPin(
          store,
          pin: '8392',
          ownerFamilyId: familyA.id.value,
          actorUserId: 'adult-a',
        );
        final fakeAuth = FakeAuthSessionPort(activeUserId: null);
        setActor(
          fakeAuth,
          userId: 'child-device-1',
          role: 'child',
          isAnonymous: true,
          sessionGeneration: 'gen-pc-1',
        );
        final verifier = FakeContainmentAuthorizationVerifier(
          defaultOutcome: AuthorizedPairedChild(
            verifiedChild: childA,
            verifiedFamily: familyA,
            grantId: 'grant-active-1',
          ),
        );

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appClockProvider.overrideWithValue(() => nowUtc),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localMetadataStoreProvider.overrideWithValue(store),
              assessmentRepositoryProvider.overrideWithValue(
                FakeAssessmentRepository(),
              ),
              growthRepositoryProvider.overrideWithValue(
                mobile_mem.InMemoryGrowthRepository(),
              ),
              rewardRepositoryProvider.overrideWithValue(
                mobile_mem.InMemoryRewardRepository(),
              ),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
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

        // C0-12: AuthorizedPairedChild lands in /child, hides exit button, blocks /parent and /family/create
        expect(find.byType(ChildModeScreen), findsOneWidget);
        expect(find.byKey(const Key('exit_child_mode_button')), findsNothing);
        container.read(routerProvider).go(AppRoutes.parentHome);
        await tester.pumpAndSettle();
        expect(find.byType(ChildModeScreen), findsOneWidget);
        container.read(routerProvider).go(AppRoutes.createFamily);
        await tester.pumpAndSettle();
        expect(find.byType(ChildModeScreen), findsOneWidget);

        // C0-13(b): All 4 PairedChildUnverified reasons -> /child/unverified with 0 PII
        for (final reason in PairedChildUnverifiedReason.values) {
          verifier.defaultOutcome = PairedChildUnverified(reason: reason);
          await container.read(sessionContainmentProvider.notifier).rehydrate();
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('cold_start_paired_child_unverified_shell')),
            findsOneWidget,
          );
          expect(container.read(activeChildModeProvider), isNull);
          expect(find.textContaining('Aria Alpha'), findsNothing);
        }

        // Reconnect recovery from PairedChildUnverified -> AuthorizedPairedChild (/child)
        verifier.defaultOutcome = AuthorizedPairedChild(
          verifiedChild: childA,
          verifiedFamily: familyA,
          grantId: 'grant-active-1',
        );
        await tester.tap(find.byKey(const Key('cold_start_retry_button')));
        await tester.pumpAndSettle();
        expect(find.byType(ChildModeScreen), findsOneWidget);

        // Unverified -> Revoked proof -> /child/revoked -> Sign Out -> /auth
        verifier.defaultOutcome = const PairedChildUnverified(
          reason: PairedChildUnverifiedReason.grantVerificationTimeoutOrError,
        );
        await container.read(sessionContainmentProvider.notifier).rehydrate();
        await tester.pumpAndSettle();

        verifier.defaultOutcome = ConfirmedPairedChildGrantRevoked(
          revokedAt: nowUtc,
          grantId: 'grant-active-1',
        );
        await tester.tap(find.byKey(const Key('cold_start_retry_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('cold_start_paired_child_revoked_shell')),
          findsOneWidget,
        );
        expect(find.byType(AuthScreen), findsNothing);

        await tester.tap(find.byKey(const Key('cold_start_sign_out_button')));
        await tester.pumpAndSettle();
        expect(find.byType(AuthScreen), findsOneWidget);
      },
    );

    testWidgets(
      'C0-19, C0-28, C0-29, C0-36: Strict segment exclusion, AuthorizationUnverified hold & recovery, anonymous blocking, and 0-row neutral onboarding',
      (tester) async {
        expect(isActiveChildContentPath('/childish'), isFalse);
        expect(isActiveChildContentPath('/children'), isFalse);
        expect(isActiveChildContentPath(AppRoutes.childStore), isTrue);

        final store = InMemoryLocalMetadataStore();
        final fakeAuth = FakeAuthSessionPort(activeUserId: null);
        setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-1');
        final verifier = FakeContainmentAuthorizationVerifier(
          defaultOutcome: const SessionAuthorizationUnverified(
            reason: 'transient_network',
          ),
        );

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appClockProvider.overrideWithValue(() => nowUtc),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localMetadataStoreProvider.overrideWithValue(store),
              familyRepositoryProvider.overrideWithValue(
                FakeFamilyRepository(
                  currentUserId: 'adult-a',
                  families: [familyA],
                ),
              ),
              childProfileRepositoryProvider.overrideWithValue(
                FakeChildProfileRepository(children: [childA]),
              ),
              assessmentRepositoryProvider.overrideWithValue(
                FakeAssessmentRepository(),
              ),
              containmentAuthorizationVerifierProvider.overrideWithValue(
                verifier,
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

        // C0-28: AuthorizationUnverified blocks /parent then recovers cleanly on retry
        expect(
          find.byKey(const Key('cold_start_authorization_unverified_shell')),
          findsOneWidget,
        );
        container.read(routerProvider).go(AppRoutes.parentHome);
        await tester.pumpAndSettle();
        expect(find.byType(FamilyHomeScreen), findsNothing);

        // C0-36: Clean 0-row NoActiveFamilyMembershipObserved -> /family/onboarding with neutral non-revocation copy & zero historical PII
        verifier.defaultOutcome = const NoActiveFamilyMembershipObserved();
        await tester.tap(find.byKey(const Key('cold_start_retry_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('cold_start_no_active_family_shell')),
          findsOneWidget,
        );
        expect(find.textContaining('revoked'), findsNothing);
        expect(find.textContaining('Alpha Family'), findsNothing);

        // C0-29: Anonymous session NEVER reaches /family/onboarding or /parent
        setActor(
          fakeAuth,
          userId: 'anon-user',
          isAnonymous: true,
          role: 'authenticated',
          sessionGeneration: 'gen-anon-1',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('cold_start_paired_child_unverified_shell')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('cold_start_no_active_family_shell')),
          findsNothing,
        );

        // Adult AuthorizedActiveAdult opens ParentMode cleanly
        setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-2');
        verifier.defaultOutcome = AuthorizedActiveAdult(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA],
          verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
        );
        await container.read(sessionContainmentProvider.notifier).rehydrate();
        await tester.pumpAndSettle();
        expect(find.byType(FamilyHomeScreen), findsOneWidget);
      },
    );
  });

  group('Group B — Mid-KDF Async Races & Household Ownership (C0-27, C0-31, C0-32, C0-33)', () {
    test('C0-27: Integrated SessionLifecycleController cross-household PIN ownership & reassignment on file-backed SQLite preserves 100% Family A work', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp4_c027_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });
      final db = await _openDb(tempDir, 'c0_27.sqlite');
      addTearDown(db.close);
      final fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
      final photo = await writeEvidenceFile(fileStore, draftId: 'd-c027');
      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'd-c027',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createCommandId: 'cmd-c-27',
          submitCommandId: 'cmd-s-27',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Family A Protected Draft',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 8,
          maxScore: 10,
          localCompressedPhotoPath: photo.path,
          sha256Checksum: photo.sha256Hex,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );

      final fakeAuth = FakeAuthSessionPort(activeUserId: null);
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-1');
      final verifier = FakeContainmentAuthorizationVerifier(
        onVerify: (call) async {
          final uid = call.context.userId;
          if (uid == 'adult-a') {
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
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          restrictedShellSignOutProvider.overrideWithValue(
            () async => fakeAuth.signOut(),
          ),
          localMetadataStoreProvider.overrideWithValue(db),
          localDraftStoreProvider.overrideWithValue(db),
          pendingRewardCommandStoreProvider.overrideWithValue(db),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db),
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

      final ctrl = container.read(sessionContainmentProvider.notifier);
      await ctrl.rehydrate();
      final pinA = await ctrl.submitInitialPinSetup('8392');
      expect(pinA.ownerFamilyId, familyA.id.value);

      await ctrl.signOutNormal();
      setActor(fakeAuth, userId: 'adult-b', sessionGeneration: 'gen-b-1');
      await ctrl.rehydrate();

      // Default setup in Family B throws ParentPinOwnershipConflict without leaking Family A name
      await expectLater(
        () => ctrl.submitInitialPinSetup('4455'),
        throwsA(
          isA<ParentGateOwnershipConflictException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('Alpha Family')),
          ),
        ),
      );

      // Explicit cross-family reassignment succeeds and binds Family B while keeping Family A local work 100% intact
      final reassigned = await ctrl.submitCrossFamilyPinReassignment(
        newPin: '4455',
      );
      expect(reassigned.ownerFamilyId, familyB.id.value);
      expect(
        container.read(sessionContainmentProvider).pinOwnerFamilyId,
        familyB.id.value,
      );
      expect(await db.getLocalDraft('d-c027'), isNotNull);
      expect(
        sha256.convert(await File(photo.path).readAsBytes()).toString(),
        equals(photo.sha256Hex),
      );
      await Future<void>.delayed(Duration.zero);
    });

    test('C0-31, C0-32, C0-33: Mid-KDF suspensions across Actor A->B (zero B lockout reset), session rotation, F1->F2 family switch, and Child Archival/Revocation precedence', () async {
      final store = InMemoryLocalMetadataStore();
      await seedBoundPin(
        store,
        pin: '8392',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );
      final fakeAuth = FakeAuthSessionPort(activeUserId: null);
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-1');

      final verifier = FakeContainmentAuthorizationVerifier(
        onVerify: (call) async {
          final target = call.preferredFamilyId == familyB.id
              ? familyB
              : familyA;
          return AuthorizedActiveAdult(
            verifiedRole: VerifiedAdultRole.owner,
            verifiedFamily: target,
            verifiedFamilies: [familyA, familyB],
            verifiedRolesByFamilyId: {
              familyA.id.value: VerifiedAdultRole.owner,
              familyB.id.value: VerifiedAdultRole.owner,
            },
            verifiedChild: childA,
          );
        },
      );
      final gateService = ParentGateService(
        store,
        clock: FixedClock(nowUtc),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );

      final container = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          localMetadataStoreProvider.overrideWithValue(store),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(gateService),
        ],
      );
      addTearDown(container.dispose);

      final ctrl = container.read(sessionContainmentProvider.notifier);
      await ctrl.rehydrate();

      // 1) C0-32: submitParentPinChange paused mid-KDF while user switches F1 -> F2
      final kdfChangeRes = await ctrl.submitParentPinChange(
        currentPin: '8392',
        newPin: '5555',
        onAfterKdfBeforeFinalize: (_) async {
          await ctrl.switchActiveFamily(familyB);
        },
      );
      expect(kdfChangeRes.outcome, PinVerificationOutcome.staleFence);
      final credAfterChangeSwitch = ParentGateCredentialV2.tryParse(
        await store.readMetadata(ParentGateService.credentialV2Key),
        minIterations: 1000,
      );
      expect(credAfterChangeSwitch?.ownerFamilyId, familyA.id.value);

      // 2) C0-32: submitCrossFamilyPinReassignment paused after KDF while user switches F1 -> F2
      await expectLater(
        () => ctrl.submitCrossFamilyPinReassignment(
          newPin: '7777',
          onAfterKdfBeforeCommit: () async {
            await ctrl.switchActiveFamily(familyA);
          },
        ),
        throwsA(isA<ParentGateFencedOperationException>()),
      );
      final credAfterReassignSwitch = ParentGateCredentialV2.tryParse(
        await store.readMetadata(ParentGateService.credentialV2Key),
        minIterations: 1000,
      );
      expect(credAfterReassignSwitch?.ownerFamilyId, familyA.id.value);

      // 3) C0-31(b): Enter Child Mode, suspend unlock mid-KDF while Actor A -> B switch + B wrong PIN failure happens
      await ctrl.enterChildMode(childA);
      final bSwitchRes = await ctrl.submitParentGateUnlock(
        '8392',
        onAfterKdfBeforeFinalize: (_) async {
          setActor(fakeAuth, userId: 'adult-b', sessionGeneration: 'gen-b-1');
          await ctrl.runSerializedForTest(() async {
            await gateService.verifyPin('0000');
          });
        },
      );
      expect(bSwitchRes.outcome, PinVerificationOutcome.staleFence);
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNotNull,
      );
      final lockoutAfterB = ParentGateLockoutV1.tryParse(
        await store.readMetadata(ParentGateService.lockoutV1Key),
      );
      expect(lockoutAfterB?.failedAttempts, greaterThanOrEqualTo(1));
      expect(lockoutAfterB?.inFlightReservations, isEmpty);

      // 4) C0-31(c): Same-actor sessionGeneration rotation mid-KDF
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-2');
      await ctrl.rehydrate();
      final rotRes = await ctrl.submitParentGateUnlock(
        '8392',
        onAfterKdfBeforeFinalize: (_) async {
          fakeAuth.setSessionGeneration('gen-a-3');
        },
      );
      expect(rotRes.outcome, PinVerificationOutcome.staleFence);
      expect(
        await store.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNotNull,
      );

      // Steps 1-4 accumulated 4 speculative/wrong attempts (preserved across abortFencedAttempt per D1.2/C0-24), so a 5th triggers 30s lockout.
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-3');
      await ctrl.rehydrate();
      final fifthLocked = await ctrl.submitParentGateUnlock('1111');
      expect(fifthLocked.outcome, PinVerificationOutcome.lockedOut);

      // 5) C0-33 (isolated lockout state): Wrong-PIN attempt persists failure count; valid-PIN mid-KDF child archival keeps containmentLocked without clearing child session
      final store33 = InMemoryLocalMetadataStore();
      await seedBoundPin(
        store33,
        pin: '8392',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );
      final fakeAuth33 = FakeAuthSessionPort(activeUserId: null);
      setActor(fakeAuth33, userId: 'adult-a', sessionGeneration: 'gen-a-1');
      final gate33 = ParentGateService(
        store33,
        clock: FixedClock(nowUtc),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      final container33 = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth33),
          localMetadataStoreProvider.overrideWithValue(store33),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(gate33),
        ],
      );
      addTearDown(container33.dispose);
      final ctrl33 = container33.read(sessionContainmentProvider.notifier);
      await ctrl33.rehydrate();
      await ctrl33.enterChildMode(childA);

      final wrongFirst = await ctrl33.submitParentGateUnlock('1111');
      expect(wrongFirst.outcome, PinVerificationOutcome.incorrectPin);
      expect(wrongFirst.failedAttempts, equals(1));

      final archivalKdfRes = await ctrl33.submitParentGateUnlock(
        '8392',
        onAfterKdfBeforeFinalize: (_) async {
          ctrl33.applyContainmentInvalidation(
            targetStatus: ColdStartContainmentStatus.containmentLocked,
            reason: 'child_archived_mid_kdf',
          );
        },
      );
      expect(archivalKdfRes.outcome, PinVerificationOutcome.staleFence);
      expect(
        container33.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );
      expect(
        await store33.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNotNull,
      );
    });
  });

  group('Group C — Full 16-Case C0-37 Two-Barrier Matrix on File-Backed SQLite', () {
    for (final barrierKind in ['barrier1', 'barrier2']) {
      for (final opKind in ['unlock', 'pin_change']) {
        for (final eventKind in [
          'sign_out',
          'actor_switch_b_lockout',
          'session_rotation',
          'containment_downgrade',
        ]) {
          test(
            'C0-37 [$opKind][$barrierKind][$eventKind] enforces immediate fail-closed UI, SQLite rollback vs commit-wins, zero B lockout reset & restart safety',
            () async {
              final tempDir = await Directory.systemTemp.createTemp(
                'lw_c037_${opKind}_${barrierKind}_${eventKind}_',
              );
              addTearDown(() async {
                if (tempDir.existsSync()) {
                  await tempDir.delete(recursive: true);
                }
              });

              final db1 = await _openDb(tempDir, 'c037.sqlite');
              var db1Closed = false;
              Future<void> closeDb1() async {
                if (!db1Closed) {
                  db1Closed = true;
                  await db1.close();
                }
              }

              addTearDown(closeDb1);

              final fileStore = DefaultLocalEvidenceFileStore(
                baseDirectory: tempDir,
              );
              final photo = await writeEvidenceFile(
                fileStore,
                draftId: 'd-c037',
              );
              await db1.saveLocalDraft(
                LocalAssessmentDraft(
                  localDraftId: 'd-c037',
                  familyId: familyA.id.value,
                  childId: childA.id.value,
                  createCommandId: 'cmd-c-37',
                  submitCommandId: 'cmd-s-37',
                  subjectKey: SubjectKey.math,
                  subject: 'Math',
                  title: 'Two Barrier Draft',
                  assessmentType: 'quiz',
                  difficulty: 'normal',
                  rawScore: 9,
                  maxScore: 10,
                  localCompressedPhotoPath: photo.path,
                  sha256Checksum: photo.sha256Hex,
                  occurredAt: nowUtc,
                  updatedAt: nowUtc,
                  actorUserId: 'adult-a',
                  actorRole: 'owner',
                ),
              );

              await seedBoundPin(
                db1,
                pin: '8392',
                ownerFamilyId: familyA.id.value,
                actorUserId: 'adult-a',
              );
              if (opKind == 'unlock') {
                await db1.writeMetadata(
                  key: ActiveChildModeNotifier.activeSessionKey,
                  value: PersistedChildModeSession(
                    modeKind: PersistedChildModeKind.sharedDeviceAdult,
                    actorUserId: 'adult-a',
                    familyId: familyA.id,
                    childId: childA.id,
                    childProfileSnapshot: childA,
                    persistedAtUtc: nowUtc,
                  ).toJsonString(),
                  updatedAt: nowUtc,
                );
              }

              final fakeAuth = FakeAuthSessionPort(activeUserId: null);
              setActor(
                fakeAuth,
                userId: 'adult-a',
                sessionGeneration: 'gen-a-1',
              );
              final verifier = FakeContainmentAuthorizationVerifier(
                defaultOutcome: AuthorizedActiveAdult(
                  verifiedRole: VerifiedAdultRole.owner,
                  verifiedFamily: familyA,
                  verifiedFamilies: [familyA],
                  verifiedRolesByFamilyId: {
                    familyA.id.value: VerifiedAdultRole.owner,
                  },
                  verifiedChild: childA,
                ),
              );
              final gateService = ParentGateService(
                db1,
                clock: FixedClock(nowUtc),
                minIterations: 1000,
                configuredIterations: 1000,
                runInIsolate: false,
              );

              final c1 = ProviderContainer(
                overrides: [
                  appClockProvider.overrideWithValue(() => nowUtc),
                  authSessionPortProvider.overrideWithValue(fakeAuth),
                  localMetadataStoreProvider.overrideWithValue(db1),
                  localDraftStoreProvider.overrideWithValue(db1),
                  pendingRewardCommandStoreProvider.overrideWithValue(db1),
                  legacyOutboxProvenanceSourceProvider.overrideWithValue(db1),
                  containmentAuthorizationVerifierProvider.overrideWithValue(
                    verifier,
                  ),
                  parentGateServiceProvider.overrideWithValue(gateService),
                ],
              );

              final ctrl1 = c1.read(sessionContainmentProvider.notifier);
              await ctrl1.rehydrate();
              expect(
                c1.read(sessionContainmentProvider).status,
                opKind == 'unlock'
                    ? ColdStartContainmentStatus.verifiedChildMode
                    : ColdStartContainmentStatus.verifiedParentMode,
              );

              final enteredBarrier = Completer<void>();
              final releaseBarrier = Completer<void>();

              Future<void> hook() async {
                if (!enteredBarrier.isCompleted) {
                  enteredBarrier.complete();
                }
                await releaseBarrier.future;
              }

              late final Future<PinVerificationResult> opFuture;
              if (opKind == 'unlock') {
                opFuture = ctrl1.submitParentGateUnlock(
                  '8392',
                  onBeforeFinalizePreCommitGuard: barrierKind == 'barrier1'
                      ? hook
                      : null,
                  onAfterFinalizeGuardBeforeCommit: barrierKind == 'barrier2'
                      ? hook
                      : null,
                );
              } else {
                opFuture = ctrl1.submitParentPinChange(
                  currentPin: '8392',
                  newPin: '9999',
                  onBeforeFinalizePreCommitGuard: barrierKind == 'barrier1'
                      ? hook
                      : null,
                  onAfterFinalizeGuardBeforeCommit: barrierKind == 'barrier2'
                      ? hook
                      : null,
                );
              }

              await enteredBarrier.future;

              Future<void>? actorBWrongPinFuture;
              switch (eventKind) {
                case 'sign_out':
                  fakeAuth.signOut();
                case 'actor_switch_b_lockout':
                  setActor(
                    fakeAuth,
                    userId: 'adult-b',
                    sessionGeneration: 'gen-b-1',
                  );
                  // Yield a microtask so synchronous stream handler marks A->B before queuing B wrong PIN after arbiter slot
                  await Future<void>.delayed(Duration.zero);
                  actorBWrongPinFuture = ctrl1.runSerializedForTest(() async {
                    await gateService.verifyPin('0000');
                  });
                case 'session_rotation':
                  fakeAuth.setSessionGeneration('gen-a-rotated');
                case 'containment_downgrade':
                  ctrl1.applyContainmentInvalidation(
                    targetStatus: ColdStartContainmentStatus.containmentLocked,
                    reason: 'archived_or_revoked_downgrade',
                  );
              }

              // Allow broadcast stream listener microtask to run while Barrier is STILL paused.
              await Future<void>.delayed(Duration.zero);

              // Assert immediate fail-closed UI mask BEFORE SQLite commit resolves!
              final liveStatusWhilePaused = c1
                  .read(sessionContainmentProvider)
                  .status;
              expect(
                liveStatusWhilePaused ==
                        ColdStartContainmentStatus.verifiedParentMode ||
                    liveStatusWhilePaused ==
                        ColdStartContainmentStatus.verifiedChildMode,
                isFalse,
                reason:
                    'UI must already be synchronously fail-closed while $barrierKind is paused ($liveStatusWhilePaused)',
              );

              // Release Barrier 1 / Barrier 2 and await ordered completion
              releaseBarrier.complete();
              final opResult = await opFuture;
              if (actorBWrongPinFuture != null) {
                await actorBWrongPinFuture;
              }
              await ctrl1.runSerializedForTest(() async {});

              expect(opResult.outcome, PinVerificationOutcome.staleFence);

              // Verify Barrier 1 vs Barrier 2 DB invariants
              final rawChildAfter = await db1.readMetadata(
                ActiveChildModeNotifier.activeSessionKey,
              );
              final rawCredAfter = await db1.readMetadata(
                ParentGateService.credentialV2Key,
              );
              final rawFenceAfter = await db1.readMetadata(
                ParentGateService.containmentFenceV1Key,
              );
              final rawLockoutAfter = await db1.readMetadata(
                ParentGateService.lockoutV1Key,
              );
              final parsedCredAfter = ParentGateCredentialV2.tryParse(
                rawCredAfter,
                minIterations: 1000,
              );
              final parsedLockoutAfter = ParentGateLockoutV1.tryParse(
                rawLockoutAfter,
              );
              expect(
                ContainmentFenceV1.tryParse(rawFenceAfter)?.fenceEpoch,
                greaterThanOrEqualTo(1),
              );

              if (barrierKind == 'barrier1') {
                // Barrier 1: SQLite ROLLED BACK
                if (opKind == 'unlock') {
                  expect(rawChildAfter, isNotNull);
                } else {
                  expect(parsedCredAfter?.credentialRevision, equals(1));
                }
              } else {
                // Barrier 2: Commit linearized at t_commit < t_event, zero compensating rewrite
                if (opKind == 'unlock') {
                  expect(rawChildAfter, isNull);
                } else {
                  expect(parsedCredAfter?.credentialRevision, equals(2));
                }
              }

              if (eventKind == 'actor_switch_b_lockout') {
                // Zero cross-actor lockout reset under BOTH barriers!
                // Under Barrier 1, Actor A's aborted Phase 1 attempt + Actor B's wrong PIN = 2;
                // under Barrier 2, Actor A committed reset to 0 before Actor B's wrong PIN = 1.
                expect(
                  parsedLockoutAfter?.failedAttempts,
                  equals(barrierKind == 'barrier1' ? 2 : 1),
                );
              }

              c1.dispose();
              await Future<void>.delayed(Duration.zero);
              await closeDb1();

              // Reopen file-backed SQLite to confirm persistence + 100% draft/photo preservation
              final db2 = await _openDb(tempDir, 'c037.sqlite');
              addTearDown(db2.close);
              expect(await db2.getLocalDraft('d-c037'), isNotNull);
              expect(
                sha256.convert(await File(photo.path).readAsBytes()).toString(),
                equals(photo.sha256Hex),
              );
              if (barrierKind == 'barrier1' && opKind == 'unlock') {
                expect(
                  await db2.readMetadata(
                    ActiveChildModeNotifier.activeSessionKey,
                  ),
                  isNotNull,
                );
              }
            },
          );
        }
      }
    }
  });

  group('Group D — Exhaustive C0-30, C0-38, C0-39 & C0-21 File-Backed SQLite Exit Path B, Provenance & Data-Loss Matrix', () {
    test('C0-30 & C0-38: Exit Path B durable recovery lock survives sign-out, SQLite restart, failed login, stale generation, unrelated B, 0-family, revoked & paired child until fresh owner login', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp4_c038_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final db1 = await _openDb(tempDir, 'c0_38.sqlite');
      var db1Closed = false;
      Future<void> closeDb1() async {
        if (!db1Closed) {
          db1Closed = true;
          await db1.close();
        }
      }

      addTearDown(closeDb1);

      final fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
      final photo = await writeEvidenceFile(fileStore, draftId: 'd-c038');
      await db1.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'd-c038',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createCommandId: 'cmd-c-38',
          submitCommandId: 'cmd-s-38',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Exit Path B Draft',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 7,
          maxScore: 10,
          localCompressedPhotoPath: photo.path,
          sha256Checksum: photo.sha256Hex,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await db1.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-spin-38',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createdAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await seedBoundPin(
        db1,
        pin: '8392',
        ownerFamilyId: familyA.id.value,
        actorUserId: 'adult-a',
      );
      await db1.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: PersistedChildModeSession(
          modeKind: PersistedChildModeKind.sharedDeviceAdult,
          actorUserId: 'adult-a',
          familyId: familyA.id,
          childId: childA.id,
          childProfileSnapshot: childA,
          persistedAtUtc: nowUtc,
        ).toJsonString(),
        updatedAt: nowUtc,
      );

      final fakeAuth = FakeAuthSessionPort(activeUserId: null);
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-init');
      final verifier = FakeContainmentAuthorizationVerifier(
        onVerify: (call) async {
          final uid = call.context.userId;
          if (uid == 'adult-a') {
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: familyA,
              verifiedFamilies: [familyA],
              verifiedRolesByFamilyId: {
                familyA.id.value: VerifiedAdultRole.owner,
              },
            );
          }
          if (uid == 'adult-b') {
            return AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: familyB,
              verifiedFamilies: [familyB],
              verifiedRolesByFamilyId: {
                familyB.id.value: VerifiedAdultRole.owner,
              },
            );
          }
          if (uid == 'adult-zero') {
            return const NoActiveFamilyMembershipObserved();
          }
          if (uid == 'adult-revoked') {
            return const ConfirmedAdultMembershipRevoked(reason: 'revoked');
          }
          return AuthorizedPairedChild(
            verifiedChild: childB,
            verifiedFamily: familyB,
            grantId: 'grant-b',
          );
        },
      );

      // Simulate Parent entering Child Mode, then child archived/lock triggered -> Recovery Sign Out
      await db1.writeMetadata(
        key: ParentGateService.lockoutV1Key,
        value: const ParentGateLockoutV1(
          version: 1,
          revision: 1,
          failedAttempts: 3,
          lockoutDurationSeconds: 0,
          credentialRevision: 1,
          inFlightReservations: [],
        ).toJsonString(),
        updatedAt: nowUtc,
      );
      verifier.defaultOutcome = AuthorizedAdultChildUnavailable(
        verifiedRole: VerifiedAdultRole.owner,
        verifiedFamily: familyA,
        verifiedFamilies: [familyA],
        verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
        reason: TargetChildUnavailabilityReason.confirmedArchived,
        targetChildId: childA.id,
        targetFamilyId: familyA.id,
      );

      // Temporarily return child-archived outcome for initial recovery lock
      final archivedVerifier = FakeContainmentAuthorizationVerifier(
        defaultOutcome: AuthorizedAdultChildUnavailable(
          verifiedRole: VerifiedAdultRole.owner,
          verifiedFamily: familyA,
          verifiedFamilies: [familyA],
          verifiedRolesByFamilyId: {familyA.id.value: VerifiedAdultRole.owner},
          reason: TargetChildUnavailabilityReason.confirmedArchived,
          targetChildId: childA.id,
          targetFamilyId: familyA.id,
        ),
      );

      final c1 = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          restrictedShellSignOutProvider.overrideWithValue(
            () async => fakeAuth.signOut(),
          ),
          localMetadataStoreProvider.overrideWithValue(db1),
          localDraftStoreProvider.overrideWithValue(db1),
          pendingRewardCommandStoreProvider.overrideWithValue(db1),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db1),
          containmentAuthorizationVerifierProvider.overrideWithValue(
            archivedVerifier,
          ),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              db1,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      final ctrl1 = c1.read(sessionContainmentProvider.notifier);
      await ctrl1.rehydrate();
      expect(
        c1.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.containmentLocked,
      );
      // Wrong-PIN accumulation on locked screen
      final wrongLocked = await ctrl1.submitParentGateUnlock('0000');
      expect(wrongLocked.outcome, PinVerificationOutcome.incorrectPin);

      // Recovery Sign Out durably persists lock & keeps active_child_session
      await ctrl1.signOutFromContainmentRecovery();
      expect(
        c1.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.unauthenticated,
      );
      c1.dispose();
      await Future<void>.delayed(Duration.zero);
      await closeDb1();

      // Reopen DB across process kill while signed out & cancelled login -> stays unauthenticated with lock intact
      final db2 = await _openDb(tempDir, 'c0_38.sqlite');
      addTearDown(db2.close);
      final c2 = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          restrictedShellSignOutProvider.overrideWithValue(
            () async => fakeAuth.signOut(),
          ),
          localMetadataStoreProvider.overrideWithValue(db2),
          localDraftStoreProvider.overrideWithValue(db2),
          pendingRewardCommandStoreProvider.overrideWithValue(db2),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(db2),
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
      addTearDown(c2.dispose);
      final ctrl2 = c2.read(sessionContainmentProvider.notifier);
      await ctrl2.rehydrate();
      expect(
        c2.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.unauthenticated,
      );

      // Blocked actors: stale generation reuse, unrelated Family B, 0-family, revoked adult, paired child
      for (final attempt in [
        (uid: 'adult-a', gen: 'gen-init', role: 'owner', anon: false),
        (uid: 'adult-b', gen: 'gen-b-fresh', role: 'owner', anon: false),
        (uid: 'adult-zero', gen: 'gen-zero-fresh', role: 'owner', anon: false),
        (
          uid: 'adult-revoked',
          gen: 'gen-rev-fresh',
          role: 'owner',
          anon: false,
        ),
        (
          uid: 'child-paired',
          gen: 'gen-child-fresh',
          role: 'child',
          anon: true,
        ),
      ]) {
        setActor(
          fakeAuth,
          userId: attempt.uid,
          sessionGeneration: attempt.gen,
          role: attempt.role,
          isAnonymous: attempt.anon,
        );
        await ctrl2.rehydrate();
        final st = c2.read(sessionContainmentProvider);
        expect(st.status, ColdStartContainmentStatus.containmentLocked);
        expect(st.verifiedFamily, isNull);
        expect(st.allowsExitPathAPinAttempt, equals(attempt.uid == 'adult-a'));
        expect(st.allowsManualUnboundLegacyRecovery, isFalse);
        expect(
          await db2.readMetadata(
            SessionLifecycleController.containmentRecoveryLockV1Key,
          ),
          isNotNull,
        );
      }

      // Fresh owning Adult A login clears both keys cleanly & preserves all local work
      setActor(fakeAuth, userId: 'adult-a', sessionGeneration: 'gen-a-fresh');
      await ctrl2.rehydrate();
      expect(
        c2.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.verifiedParentMode,
      );
      expect(
        await db2.readMetadata(
          SessionLifecycleController.containmentRecoveryLockV1Key,
        ),
        isNull,
      );
      expect(
        await db2.readMetadata(ActiveChildModeNotifier.activeSessionKey),
        isNull,
      );
      expect(await db2.getLocalDraft('d-c038'), isNotNull);
      expect(await db2.getPendingCommand('cmd-spin-38'), isNotNull);
      expect(
        sha256.convert(await File(photo.path).readAsBytes()).toString(),
        equals(photo.sha256Hex),
      );
      await Future<void>.delayed(Duration.zero);
    });

    test('C0-39(a)-(g) & C0-21: Exhaustive legacy v1/malformed provenance subcases and Restricted Manual Unbound Recovery with bit-identical photo SHA-256', () async {
      final tempDir = await Directory.systemTemp.createTemp('lw_wp4_c039_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      // Case (a)+(b)+(f): bare v1 hint (child-a, fam-a) + child_id==null reward command (uncorrelated) + v1 PIN '2580':
      // Fails Exit Path B auto-unlock & blocks Family B, allows v1 PIN Exit Path A for verified Family A adult.
      final dbF = await _openDb(tempDir, 'c0_39_f.sqlite');
      addTearDown(dbF.close);
      await dbF.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'cmd-null-child',
          familyId: familyA.id.value,
          childId: null,
          redemptionId: 'red-1',
          createdAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      final v1Salt = 'legacy-salt-c039';
      await dbF.writeMetadata(
        key: ParentGateService.pinSaltKey,
        value: v1Salt,
        updatedAt: nowUtc,
      );
      await dbF.writeMetadata(
        key: ParentGateService.pinHashKey,
        value: ParentGateCrypto.sha256V1PinHex(pin: '2580', salt: v1Salt),
        updatedAt: nowUtc,
      );
      await dbF.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: jsonEncode({
          'id': childA.id.value,
          'family_id': familyA.id.value,
          'display_name': childA.displayName,
        }),
        updatedAt: nowUtc,
      );
      final gateF = ParentGateService(
        dbF,
        clock: FixedClock(nowUtc),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      final resF = await gateF.resolveLegacyOwnership(
        provenanceSource: dbF,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: [familyA.id.value],
      );
      expect(resF, isA<UnresolvableLegacyOwnershipResolution>());

      // Different child-other != child-a also stays Unresolvable
      await dbF.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-other-child',
          familyId: familyA.id.value,
          childId: 'child-other',
          createdAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      final resOtherChild = await gateF.resolveLegacyOwnership(
        provenanceSource: dbF,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: [familyA.id.value],
      );
      expect(resOtherChild, isA<UnresolvableLegacyOwnershipResolution>());

      // Case (e): Family A hint + Family B outbox stays Unresolvable
      await dbF.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.spinWheel,
          commandId: 'cmd-fam-b',
          familyId: familyB.id.value,
          childId: childB.id.value,
          createdAt: nowUtc,
          actorUserId: 'adult-b',
          actorRole: 'owner',
        ),
      );
      final resE = await gateF.resolveLegacyOwnership(
        provenanceSource: dbF,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: [familyA.id.value, familyB.id.value],
      );
      expect(resE, isA<UnresolvableLegacyOwnershipResolution>());

      // Case (g): Corrupt PIN + malformed session blocks 0-family/revoked/paired/offline; ONLY fresh verified adult Manual Unbound Recovery succeeds cleanly & keeps photo SHA-256
      final dbG = await _openDb(tempDir, 'c0_39_g.sqlite');
      addTearDown(dbG.close);
      final fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
      final photo = await writeEvidenceFile(fileStore, draftId: 'd-c039g');
      await dbG.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'd-c039g',
          familyId: familyA.id.value,
          childId: childA.id.value,
          createCommandId: 'cmd-c-39g',
          submitCommandId: 'cmd-s-39g',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Unbound Recovery Draft',
          assessmentType: 'quiz',
          difficulty: 'normal',
          rawScore: 10,
          maxScore: 10,
          localCompressedPhotoPath: photo.path,
          sha256Checksum: photo.sha256Hex,
          occurredAt: nowUtc,
          updatedAt: nowUtc,
          actorUserId: 'adult-a',
          actorRole: 'owner',
        ),
      );
      await dbG.writeMetadata(
        key: ActiveChildModeNotifier.activeSessionKey,
        value: '{corrupt-session',
        updatedAt: nowUtc,
      );
      await dbG.writeMetadata(
        key: ParentGateService.credentialV2Key,
        value: '{corrupt-pin',
        updatedAt: nowUtc,
      );

      final fakeAuth = FakeAuthSessionPort(activeUserId: null);
      setActor(fakeAuth, userId: 'adult-zero', sessionGeneration: 'gen-0');
      final verifier = FakeContainmentAuthorizationVerifier(
        onVerify: (call) async {
          return switch (call.context.userId) {
            'adult-zero' => const NoActiveFamilyMembershipObserved(),
            'adult-rev' => const ConfirmedAdultMembershipRevoked(
              reason: 'revoked',
            ),
            'adult-off' => const SessionAuthorizationUnverified(
              reason: 'offline',
            ),
            'child-pc' => AuthorizedPairedChild(
              verifiedChild: childB,
              verifiedFamily: familyB,
              grantId: 'g-b',
            ),
            _ => AuthorizedActiveAdult(
              verifiedRole: VerifiedAdultRole.owner,
              verifiedFamily: familyB,
              verifiedFamilies: [familyB],
              verifiedRolesByFamilyId: {
                familyB.id.value: VerifiedAdultRole.owner,
              },
            ),
          };
        },
      );

      final cG = ProviderContainer(
        overrides: [
          appClockProvider.overrideWithValue(() => nowUtc),
          authSessionPortProvider.overrideWithValue(fakeAuth),
          restrictedShellSignOutProvider.overrideWithValue(
            () async => fakeAuth.signOut(),
          ),
          localMetadataStoreProvider.overrideWithValue(dbG),
          localDraftStoreProvider.overrideWithValue(dbG),
          pendingRewardCommandStoreProvider.overrideWithValue(dbG),
          legacyOutboxProvenanceSourceProvider.overrideWithValue(dbG),
          containmentAuthorizationVerifierProvider.overrideWithValue(verifier),
          parentGateServiceProvider.overrideWithValue(
            ParentGateService(
              dbG,
              clock: FixedClock(nowUtc),
              minIterations: 1000,
              configuredIterations: 1000,
              runInIsolate: false,
            ),
          ),
        ],
      );
      addTearDown(cG.dispose);
      final ctrlG = cG.read(sessionContainmentProvider.notifier);

      for (final bad in [
        (uid: 'adult-zero', gen: 'gen-0', role: 'owner', anon: false),
        (uid: 'adult-rev', gen: 'gen-r', role: 'owner', anon: false),
        (uid: 'adult-off', gen: 'gen-off', role: 'owner', anon: false),
        (uid: 'child-pc', gen: 'gen-pc', role: 'child', anon: true),
      ]) {
        setActor(
          fakeAuth,
          userId: bad.uid,
          sessionGeneration: bad.gen,
          role: bad.role,
          isAnonymous: bad.anon,
        );
        await ctrlG.rehydrate();
        expect(
          cG.read(sessionContainmentProvider).allowsManualUnboundLegacyRecovery,
          isFalse,
        );
        await expectLater(
          () => ctrlG.submitManualUnboundLegacyRecovery(
            newPin: '7391',
            targetFamilyId: familyB.id.value,
          ),
          throwsException,
        );
      }

      // Sign in same-gen verified Adult B -> sign out -> fresh post-sign-out verified Adult B succeeds manual recovery
      setActor(fakeAuth, userId: 'adult-b', sessionGeneration: 'gen-b-old');
      await ctrlG.rehydrate();
      await ctrlG.signOutFromContainmentRecovery();
      setActor(fakeAuth, userId: 'adult-b', sessionGeneration: 'gen-b-new');
      await ctrlG.rehydrate();
      expect(
        cG.read(sessionContainmentProvider).allowsManualUnboundLegacyRecovery,
        isTrue,
      );

      await ctrlG.submitManualUnboundLegacyRecovery(
        newPin: '7391',
        targetFamilyId: familyB.id.value,
      );
      expect(
        cG.read(sessionContainmentProvider).status,
        ColdStartContainmentStatus.verifiedParentMode,
      );
      final auditRaw = await dbG.readMetadata(
        ParentGateService.lastContainmentRecoveryAuditV1Key,
      );
      expect(auditRaw, isNotNull);
      expect(auditRaw, isNot(contains('7391')));
      expect(auditRaw, isNot(contains('Aria Alpha')));
      expect(await dbG.getLocalDraft('d-c039g'), isNotNull);
      expect(
        sha256.convert(await File(photo.path).readAsBytes()).toString(),
        equals(photo.sha256Hex),
      );
      await Future<void>.delayed(Duration.zero);
    });
  });
}

final class _StreamBackedSupabaseAuthAdapter implements AuthSessionPort {
  _StreamBackedSupabaseAuthAdapter({
    required SupabaseClient client,
    required this.clock,
    required Stream<AuthState> stream,
    required this.sessionGetter,
  }) {
    _sub = stream.listen(
      (event) {
        final s = event.session;
        if (event.event == AuthChangeEvent.signedOut ||
            s == null ||
            s.isExpired) {
          _stickyInvalid = true;
          _gen = null;
        } else {
          _stickyInvalid = false;
          _epoch++;
          _gen = '${s.user.id}:$_epoch';
        }
        _ctrl.add(_gen);
      },
      onError: (_) {
        _stickyInvalid = true;
        _gen = null;
        _ctrl.add(null);
      },
    );
    final initSess = client.auth.currentSession;
    if (initSess != null && !initSess.isExpired) {
      _epoch++;
      _gen = '${initSess.user.id}:$_epoch';
    }
  }

  final Clock clock;
  final Session? Function() sessionGetter;
  final _ctrl = StreamController<String?>.broadcast();
  late final StreamSubscription<AuthState> _sub;
  int _epoch = 0;
  String? _gen;
  bool _stickyInvalid = false;

  @override
  String? get currentSessionGeneration => _stickyInvalid ? null : _gen;

  @override
  Stream<String?> get sessionGenerationStream => _ctrl.stream;

  @override
  Future<ValidatedActorContext?> validateForMutation() async {
    if (_stickyInvalid) return null;
    final s = sessionGetter();
    if (s == null || s.isExpired || _gen == null) return null;
    return ValidatedActorContext(
      userId: s.user.id,
      sessionGeneration: _gen!,
      observedAt: clock.now().toUtc(),
      role: s.user.appMetadata['role']?.toString(),
      isAnonymous: s.user.isAnonymous,
    );
  }

  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_ctrl.close());
  }
}
