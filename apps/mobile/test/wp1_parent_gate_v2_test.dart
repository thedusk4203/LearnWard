import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/shared_device/domain/parent_gate_service.dart';
import 'package:learnward/features/shared_device/presentation/parent_gate_dialog.dart';
import 'package:learnward/features/shared_device/presentation/parent_pin_setup_dialog.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:path/path.dart' as p;

void main() {
  setUpAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  group('ParentGateCrypto PBKDF2-HMAC-SHA-256 KATs & primitives', () {
    test('matches standard PBKDF2-HMAC-SHA-256 test vectors', () async {
      Future<String> deriveHex(
        List<int> password,
        List<int> salt,
        int c,
        int dkLen,
      ) async {
        final bytes = await ParentGateCrypto.pbkdf2HmacSha256(
          password: password,
          salt: salt,
          iterations: c,
          keyLengthBytes: dkLen,
          runInIsolate: false,
        );
        return ParentGateCrypto.bytesToHex(bytes);
      }

      expect(
        await deriveHex(utf8.encode('password'), utf8.encode('salt'), 1, 32),
        equals(
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
        ),
      );
      expect(
        await deriveHex(utf8.encode('password'), utf8.encode('salt'), 2, 32),
        equals(
          'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
        ),
      );
      expect(
        await deriveHex(utf8.encode('password'), utf8.encode('salt'), 4096, 32),
        equals(
          'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
        ),
      );
      expect(
        await deriveHex(
          utf8.encode('passwordPASSWORDpassword'),
          utf8.encode('saltSALTsaltSALTsaltSALTsaltSALTsalt'),
          4096,
          40,
        ),
        equals(
          '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9',
        ),
      );
      expect(
        await deriveHex(
          utf8.encode('pass\x00word'),
          utf8.encode('sa\x00lt'),
          4096,
          16,
        ),
        equals('89b69d0516f829893c696226650a8687'),
      );
    });

    test('CSPRNG salts are 16+ bytes and constant-time compare is exact', () {
      final salt1 = ParentGateCrypto.generateRandomHex(16);
      final salt2 = ParentGateCrypto.generateRandomHex(16);
      expect(salt1.length, equals(32));
      expect(salt2.length, equals(32));
      expect(salt1, isNot(equals(salt2)));

      expect(ParentGateCrypto.constantTimeEqualsHex('abcd', 'abcd'), isTrue);
      expect(ParentGateCrypto.constantTimeEqualsHex('abcd', 'abce'), isFalse);
      expect(ParentGateCrypto.constantTimeEqualsHex('abcd', 'abc'), isFalse);
      expect(ParentGateCrypto.constantTimeEqualsHex('', ''), isTrue);
    });
  });

  group(
    'C0-22 Production iteration floor & off-UI-thread isolate execution',
    () {
      test(
        'parentGateServiceProvider enforces >= 100,000 iterations in isolate',
        () {
          final store = InMemoryLocalMetadataStore();
          final container = ProviderContainer(
            overrides: [localMetadataStoreProvider.overrideWithValue(store)],
          );
          addTearDown(container.dispose);

          final service = container.read(parentGateServiceProvider);
          expect(service.minIterations, greaterThanOrEqualTo(100000));
          expect(service.configuredIterations, greaterThanOrEqualTo(100000));
          expect(service.runsInIsolate, isTrue);
        },
      );

      testWidgets(
        'ParentPinSetupDialog and ParentGateDialog stay responsive during 100k isolate PBKDF2',
        (tester) async {
          final store = InMemoryLocalMetadataStore();
          var unlocked = false;

          await tester.pumpWidget(
            ProviderScope(
              overrides: [localMetadataStoreProvider.overrideWithValue(store)],
              child: MaterialApp(
                home: Builder(
                  builder: (context) => Column(
                    children: [
                      ElevatedButton(
                        key: const Key('open_setup'),
                        onPressed: () => ParentPinSetupDialog.show(context),
                        child: const Text('Setup'),
                      ),
                      ElevatedButton(
                        key: const Key('open_gate'),
                        onPressed: () => ParentGateDialog.show(
                          context,
                          onGatePassed: () => unlocked = true,
                        ),
                        child: const Text('Gate'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

          // Open setup dialog and trigger isolate-offloaded 100k PBKDF2 setup
          await tester.tap(find.byKey(const Key('open_setup')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('parent_pin_setup_field')),
            '8392',
          );
          await tester.enterText(
            find.byKey(const Key('parent_pin_confirm_field')),
            '8392',
          );
          await tester.tap(find.byKey(const Key('parent_pin_setup_submit')));
          await tester.pump();
          expect(find.byType(CircularProgressIndicator), findsOneWidget);

          await tester.runAsync(() async {
            for (var i = 0; i < 40; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              if (await store.readMetadata(ParentGateService.credentialV2Key) !=
                  null) {
                break;
              }
            }
          });
          await tester.pumpAndSettle();

          expect(find.byType(ParentPinSetupDialog), findsNothing);
          expect(
            ParentGateCredentialV2.tryParse(
              await store.readMetadata(ParentGateService.credentialV2Key),
            ),
            isNotNull,
          );

          // Open gate dialog and verify with 100k isolate PBKDF2
          await tester.tap(find.byKey(const Key('open_gate')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('parent_gate_pin_field')),
            '8392',
          );
          await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
          await tester.pump();

          await tester.runAsync(() async {
            for (var i = 0; i < 40; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              final rawLock = await store.readMetadata(
                ParentGateService.lockoutV1Key,
              );
              final parsedLock = ParentGateLockoutV1.tryParse(rawLock);
              if (parsedLock != null &&
                  parsedLock.failedAttempts == 0 &&
                  parsedLock.inFlightReservations.isEmpty) {
                break;
              }
            }
          });
          await tester.pumpAndSettle();

          expect(unlocked, isTrue);
          expect(find.byType(ParentGateDialog), findsNothing);
        },
      );
    },
  );

  group('Progressive lockout, concurrency (C0-24, C0-25), dual clocks (C0-26)', () {
    test('sequential wrong attempts follow warning and backoff schedule (30/60/300/900/1800s) and survive restarts', () async {
      final store = InMemoryLocalMetadataStore();
      final clock = TestClock(DateTime.utc(2026, 11, 25, 12, 0));
      final mono = TestMonotonicClock();

      ParentGateService newService() => ParentGateService(
        store,
        clock: clock,
        monotonicClock: mono,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );

      final service = newService();
      await service.setPin('8392', ownerFamilyId: 'fam-a');

      final r1 = await service.verifyPinDetailed('0001');
      expect(r1.outcome, PinVerificationOutcome.incorrectPin);
      expect(r1.failedAttempts, 1);
      expect(r1.message, 'Incorrect PIN. Try again.');

      final r2 = await service.verifyPinDetailed('0002');
      expect(r2.failedAttempts, 2);
      expect(r2.message, 'Incorrect PIN. Try again.');

      final r3 = await service.verifyPinDetailed('0003');
      expect(r3.failedAttempts, 3);
      expect(r3.remainingAttemptsBeforeLockout, 2);
      expect(r3.message, contains('2 attempts remaining'));

      final r4 = await service.verifyPinDetailed('0004');
      expect(r4.failedAttempts, 4);
      expect(r4.remainingAttemptsBeforeLockout, 1);
      expect(r4.message, contains('1 attempt remaining'));

      // #5 -> 30s
      final r5 = await service.verifyPinDetailed('0005');
      expect(r5.outcome, PinVerificationOutcome.lockedOut);
      expect(r5.failedAttempts, 5);
      expect(r5.remainingLockout.inSeconds, 30);

      // Correct PIN blocked during lockout
      final blockedRight = await service.verifyPinDetailed('8392');
      expect(blockedRight.outcome, PinVerificationOutcome.lockedOut);

      void advanceBoth(Duration d) {
        clock.advance(d);
        mono.advance(d);
      }

      // Advance 31s -> #6 wrong gives 60s
      advanceBoth(const Duration(seconds: 31));
      final r6 = await service.verifyPinDetailed('0006');
      expect(r6.failedAttempts, 6);
      expect(r6.remainingLockout.inSeconds, 60);

      // #7 -> 300s (simulate app restart in between!)
      advanceBoth(const Duration(seconds: 61));
      final restarted = ParentGateService(
        store,
        clock: clock,
        monotonicClock: TestMonotonicClock(),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      final r7 = await restarted.verifyPinDetailed('0007');
      expect(r7.failedAttempts, 7);
      expect(r7.remainingLockout.inSeconds, 300);

      // #8 -> 900s
      clock.advance(const Duration(seconds: 301));
      final r8 = await ParentGateService(
        store,
        clock: clock,
        monotonicClock: TestMonotonicClock(),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      ).verifyPinDetailed('0008');
      expect(r8.failedAttempts, 8);
      expect(r8.remainingLockout.inSeconds, 900);

      // #9 -> 1800s cap
      clock.advance(const Duration(seconds: 901));
      final r9 = await ParentGateService(
        store,
        clock: clock,
        monotonicClock: TestMonotonicClock(),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      ).verifyPinDetailed('0009');
      expect(r9.failedAttempts, 9);
      expect(r9.remainingLockout.inSeconds, 1800);

      // #10 -> stays capped at 1800s
      clock.advance(const Duration(seconds: 1801));
      final r10 = await ParentGateService(
        store,
        clock: clock,
        monotonicClock: TestMonotonicClock(),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      ).verifyPinDetailed('0010');
      expect(r10.failedAttempts, 10);
      expect(r10.remainingLockout.inSeconds, 1800);
    });

    test('C0-24: 5 overlapping wrong-PIN calls across file-backed SQLite connections & in-memory lose zero failures and reject 6th immediately', () async {
      for (final mode in ['in_memory', 'sqlite_file']) {
        Directory? dir;
        AppDatabase? conn1;
        AppDatabase? conn2;
        late LocalMetadataStore store1;
        late LocalMetadataStore store2;

        if (mode == 'in_memory') {
          final shared = InMemoryLocalMetadataStore();
          store1 = shared;
          store2 = shared;
        } else {
          dir = Directory.systemTemp.createTempSync('lw_wp1_c024_');
          final dbFile = File(p.join(dir.path, 'c024.sqlite'));
          conn1 = AppDatabase(NativeDatabase.createInBackground(dbFile));
          conn2 = AppDatabase(NativeDatabase.createInBackground(dbFile));
          store1 = conn1;
          store2 = conn2;
        }

        try {
          final clock = TestClock(DateTime.utc(2026, 11, 25, 12, 0));
          final mono = TestMonotonicClock();
          final s1 = ParentGateService(
            store1,
            clock: clock,
            monotonicClock: mono,
            minIterations: 1000,
            configuredIterations: 1000,
            runInIsolate: false,
          );
          final s2 = ParentGateService(
            store2,
            clock: clock,
            monotonicClock: mono,
            minIterations: 1000,
            configuredIterations: 1000,
            runInIsolate: false,
          );
          await s1.setPin('8392', ownerFamilyId: 'fam-a');

          // Launch 4 concurrent wrong guesses held after Phase 2 KDF before Phase 3 finalize
          final gates = List.generate(4, (_) => Completer<void>());
          final releaseAll = Completer<void>();
          final concurrentCalls = <Future<PinVerificationResult>>[];
          for (var i = 0; i < 4; i++) {
            final svc = i.isEven ? s1 : s2;
            concurrentCalls.add(
              svc.verifyPinDetailed(
                '000$i',
                onAfterKdfBeforeFinalize: (_) async {
                  gates[i].complete();
                  await releaseAll.future;
                },
              ),
            );
          }
          await Future.wait(gates.map((g) => g.future));

          // 5th concurrent caller executes while 4 are still in-flight
          final fifthResult = await s2.verifyPinDetailed('9999');
          expect(fifthResult.outcome, PinVerificationOutcome.lockedOut);
          expect(fifthResult.failedAttempts, 5);

          // 6th caller must immediately fail with lockedOut before KDF
          var sixthExecutedKdfCallback = false;
          final sixthResult = await s1.verifyPinDetailed(
            '8392',
            onAfterKdfBeforeFinalize: (_) async {
              sixthExecutedKdfCallback = true;
            },
          );
          expect(sixthResult.outcome, PinVerificationOutcome.lockedOut);
          expect(sixthExecutedKdfCallback, isFalse);

          releaseAll.complete();
          await Future.wait(concurrentCalls);

          final rawLock = await store1.readMetadata(
            ParentGateService.lockoutV1Key,
          );
          final finalLock = ParentGateLockoutV1.tryParse(rawLock)!;
          expect(finalLock.failedAttempts, 5);
          expect(finalLock.inFlightReservations, isEmpty);
        } finally {
          await conn1?.close();
          await conn2?.close();
          if (dir != null && dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    });

    test('C0-25: (a) correct PIN paused behind lockout fails closed; (b) expired zombie reservation & abortFencedAttempt preserve failure count', () async {
      final store = InMemoryLocalMetadataStore();
      final clock = TestClock(DateTime.utc(2026, 11, 25, 12, 0));
      final mono = TestMonotonicClock();
      final service = ParentGateService(
        store,
        clock: clock,
        monotonicClock: mono,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      await service.setPin('8392', ownerFamilyId: 'fam-a');

      // 3 prior wrong attempts
      await service.verifyPinDetailed('0001');
      await service.verifyPinDetailed('0002');
      await service.verifyPinDetailed('0003');

      // Call A enters with CORRECT PIN '8392' (#4) and pauses after KDF
      final aReservedAndHashed = Completer<void>();
      final releaseA = Completer<void>();
      final callAFuture = service.verifyPinDetailed(
        '8392',
        onAfterKdfBeforeFinalize: (_) async {
          aReservedAndHashed.complete();
          await releaseA.future;
        },
      );
      await aReservedAndHashed.future;

      // While Call A is paused, Call B makes #5 wrong attempt -> engages 30s lockout
      final callBResult = await service.verifyPinDetailed('0005');
      expect(callBResult.outcome, PinVerificationOutcome.lockedOut);
      expect(callBResult.failedAttempts, 5);

      // Call A resumes -> MUST NOT bypass Call B's lockout!
      releaseA.complete();
      final callAResult = await callAFuture;
      expect(callAResult.outcome, PinVerificationOutcome.lockedOut);
      expect(callAResult.isVerified, isFalse);

      final afterLock = ParentGateLockoutV1.tryParse(
        await store.readMetadata(ParentGateService.lockoutV1Key),
      )!;
      expect(afterLock.failedAttempts, 5);
      expect(afterLock.lockoutUntilUtc, isNotNull);

      // (b) Reservation TTL expiry & zombie rejection + abortFencedAttempt
      clock.advance(const Duration(seconds: 31));
      mono.advance(const Duration(seconds: 31));
      // Unlock cleanly first so we test fresh zombie & abort
      expect((await service.verifyPinDetailed('8392')).isVerified, isTrue);

      final staged = await service.beginStagedVerification(enteredPin: '8392');
      expect(staged.isReserved, isTrue);
      final afterReserve = ParentGateLockoutV1.tryParse(
        await store.readMetadata(ParentGateService.lockoutV1Key),
      )!;
      expect(afterReserve.failedAttempts, 1);
      expect(afterReserve.inFlightReservations, hasLength(1));

      // Advance past 15s reservation TTL -> zombie completion MUST fail closed and prune
      clock.advance(const Duration(seconds: 20));
      mono.advance(const Duration(seconds: 20));
      final zombieResult = await service.completeStagedVerification(
        attempt: staged.attempt!,
      );
      expect(zombieResult.isVerified, isFalse);
      expect(zombieResult.outcome, PinVerificationOutcome.staleFence);
      final afterZombie = ParentGateLockoutV1.tryParse(
        await store.readMetadata(ParentGateService.lockoutV1Key),
      )!;
      expect(afterZombie.failedAttempts, 1);
      expect(afterZombie.inFlightReservations, isEmpty);

      // Staged abortFencedAttempt cleans ONLY its reservation while retaining failure count
      final staged2 = await service.beginStagedVerification(enteredPin: '8392');
      await service.abortFencedAttempt(staged2.attempt!.attemptId);
      final afterAbort = ParentGateLockoutV1.tryParse(
        await store.readMetadata(ParentGateService.lockoutV1Key),
      )!;
      expect(afterAbort.failedAttempts, 2);
      expect(afterAbort.inFlightReservations, isEmpty);
    });

    test('C0-26: dual-clock enforces monotonic live lockout across -10m/+1h UTC shifts and bounded clamp across restarts', () async {
      final store = InMemoryLocalMetadataStore();
      final clock = TestClock(DateTime.utc(2026, 11, 25, 12, 0));
      final mono = TestMonotonicClock();
      final service = ParentGateService(
        store,
        clock: clock,
        monotonicClock: mono,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      await service.setPin('8392', ownerFamilyId: 'fam-a');

      for (var i = 0; i < 5; i++) {
        await service.verifyPinDetailed('000$i');
      }

      // (a) In-process forward UTC shift +1h does NOT bypass 30s monotonic deadline
      clock.advance(const Duration(hours: 1));
      final forwardBlocked = await service.verifyPinDetailed('8392');
      expect(forwardBlocked.outcome, PinVerificationOutcome.lockedOut);
      expect(forwardBlocked.remainingLockout.inSeconds, 30);

      // In-process backward UTC shift -10m does NOT shorten or extend past remaining 30s
      clock.advance(const Duration(minutes: -70));
      mono.advance(const Duration(seconds: 10));
      final backBlocked = await service.verifyPinDetailed('8392');
      expect(backBlocked.outcome, PinVerificationOutcome.lockedOut);
      expect(backBlocked.remainingLockout.inSeconds, 20);

      // Advance remaining 20s on monotonic clock even while UTC is backward -> expires!
      mono.advance(const Duration(seconds: 21));
      expect((await service.verifyPinDetailed('8392')).isVerified, isTrue);

      // Trigger #5 30s lockout again for restart skew checks
      clock.setTime(DateTime.utc(2026, 11, 25, 13, 0));
      for (var i = 0; i < 5; i++) {
        await service.verifyPinDetailed('111$i');
      }

      // (b) Simulated restart with backward UTC jump (-1h) before lastAttemptAtUtc
      clock.setTime(DateTime.utc(2026, 11, 25, 12, 0));
      final monoAfterBackRestart = TestMonotonicClock();
      final backRestartService = ParentGateService(
        store,
        clock: clock,
        monotonicClock: monoAfterBackRestart,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      final backRestartRes = await backRestartService.verifyPinDetailed('8392');
      expect(backRestartRes.outcome, PinVerificationOutcome.lockedOut);
      // Bounded clamp enforces min(30s, 30m) = 30s (NOT 1h 30s!)
      expect(backRestartRes.remainingLockout.inSeconds, 30);

      // (c) Simulated restart with forward UTC jump (+1h) past lockoutUntilUtc:
      // lockout expired across reboot, BUT failedAttempts==5 persisted so next wrong guess triggers #6 (60s)!
      clock.setTime(DateTime.utc(2026, 11, 25, 14, 0));
      final forwardRestartService = ParentGateService(
        store,
        clock: clock,
        monotonicClock: TestMonotonicClock(),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      final nextWrong = await forwardRestartService.verifyPinDetailed('9999');
      expect(nextWrong.outcome, PinVerificationOutcome.lockedOut);
      expect(nextWrong.failedAttempts, 6);
      expect(nextWrong.remainingLockout.inSeconds, 60);
    });
  });

  group('v1->v2 migration, corruption recovery, ownership (C0-27) & fences', () {
    test('R39-02: legacy v1 verifyPinDetailed without actor/family/fence/adult-auth NEVER writes unowned v2, preserves legacy keys, and keeps lockout active', () async {
      final store = InMemoryLocalMetadataStore();
      final clock = TestClock(DateTime.utc(2026, 11, 25, 12, 0));
      const v1Salt = '00112233445566778899aabbccddeeff';
      final v1Hash = ParentGateCrypto.sha256V1PinHex(pin: '8392', salt: v1Salt);
      await store.applyMetadataBatch([
        MetadataMutation.upsert(
          key: ParentGateService.pinSaltKey,
          value: v1Salt,
          updatedAt: clock.now(),
        ),
        MetadataMutation.upsert(
          key: ParentGateService.pinHashKey,
          value: v1Hash,
          updatedAt: clock.now(),
        ),
      ]);

      final service = ParentGateService(
        store,
        clock: clock,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );

      // Wrong guess against legacy v1 still charges progressive lockout (zero free guesses)
      final wrong1 = await service.verifyPinDetailed('0000');
      expect(wrong1.outcome, PinVerificationOutcome.incorrectPin);
      expect(wrong1.failedAttempts, 1);

      // Case 1: bare call without actor/family/fence verifies v1 WITHOUT upgrading to unowned v2
      final bareOk = await service.verifyPinDetailed('8392');
      expect(bareOk.isVerified, isTrue);
      expect(bareOk.upgradedFromV1, isFalse);
      expect(bareOk.failedAttempts, 0);
      expect(
        await store.readMetadata(ParentGateService.credentialV2Key),
        isNull,
      );
      expect(
        await store.readMetadata(ParentGateService.pinHashKey),
        equals(v1Hash),
      );
      expect(
        await store.readMetadata(ParentGateService.pinSaltKey),
        equals(v1Salt),
      );

      // Case 2: actor + family + fence present, but negative adult verification -> NO v1->v2 upgrade
      final fence = const ParentGateOperationFence(
        actorUserId: 'actor-a',
        sessionGeneration: 1,
        containmentEpoch: 1,
        expectedContainmentStatus: 'active_child',
        verifiedFamilyId: 'fam-a',
        expectedChildId: 'child-a',
      );
      final unverifiedAdult = await service.verifyPinDetailed(
        '8392',
        actorFamilyId: 'fam-a',
        actorUserId: 'actor-a',
        fence: fence,
        hasPositiveServerAdultVerification: false,
        verifiedActiveAdultFamilyIds: const ['fam-a'],
      );
      expect(unverifiedAdult.isVerified, isTrue);
      expect(unverifiedAdult.upgradedFromV1, isFalse);
      expect(
        await store.readMetadata(ParentGateService.credentialV2Key),
        isNull,
      );

      // Case 3: unverified household -> NO v1->v2 upgrade
      final wrongFamilyList = await service.verifyPinDetailed(
        '8392',
        actorFamilyId: 'fam-a',
        actorUserId: 'actor-a',
        fence: fence,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-other'],
      );
      expect(wrongFamilyList.upgradedFromV1, isFalse);
      expect(
        await store.readMetadata(ParentGateService.credentialV2Key),
        isNull,
      );
      expect(
        await store.readMetadata(ParentGateService.pinHashKey),
        equals(v1Hash),
      );
    });

    testWidgets(
      'R39-02: ParentGateDialog pre-WP3 call path verifies legacy v1 without creating unowned v2 credential and preserves lockout',
      (tester) async {
        final store = InMemoryLocalMetadataStore();
        final clock = TestClock(DateTime.utc(2026, 11, 25, 12, 0));
        const v1Salt = 'aabbccddeeff00112233445566778899';
        final v1Hash = ParentGateCrypto.sha256V1PinHex(
          pin: '8392',
          salt: v1Salt,
        );
        await store.applyMetadataBatch([
          MetadataMutation.upsert(
            key: ParentGateService.pinSaltKey,
            value: v1Salt,
            updatedAt: clock.now(),
          ),
          MetadataMutation.upsert(
            key: ParentGateService.pinHashKey,
            value: v1Hash,
            updatedAt: clock.now(),
          ),
        ]);

        var passed = false;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              localMetadataStoreProvider.overrideWithValue(store),
              parentGateServiceProvider.overrideWithValue(
                ParentGateService(
                  store,
                  clock: clock,
                  minIterations: 1000,
                  configuredIterations: 1000,
                  runInIsolate: false,
                ),
              ),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => ElevatedButton(
                  key: const Key('open_v1_gate'),
                  onPressed: () => ParentGateDialog.show(
                    context,
                    onGatePassed: () => passed = true,
                  ),
                  child: const Text('Gate'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('open_v1_gate')));
        await tester.pumpAndSettle();

        // Wrong PIN increments lockout cleanly
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '1111',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();
        expect(passed, isFalse);
        expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);
        expect(
          ParentGateLockoutV1.tryParse(
            await store.readMetadata(ParentGateService.lockoutV1Key),
          )!.failedAttempts,
          equals(1),
        );

        // Valid v1 PIN passes gate WITHOUT upgrading to unowned v2
        await tester.enterText(
          find.byKey(const Key('parent_gate_pin_field')),
          '8392',
        );
        await tester.tap(find.byKey(const Key('parent_gate_verify_button')));
        await tester.pumpAndSettle();

        expect(passed, isTrue);
        expect(
          await store.readMetadata(ParentGateService.credentialV2Key),
          isNull,
        );
        expect(
          await store.readMetadata(ParentGateService.pinHashKey),
          equals(v1Hash),
        );
        expect(
          await store.readMetadata(ParentGateService.pinSaltKey),
          equals(v1Salt),
        );
      },
    );

    test('R39-02 & R39-01: authorized v1->v2 upgrade migrates atomically on SQLite and rolls back on Barrier 1 failure before mutation admission', () async {
      final tempDir = Directory.systemTemp.createTempSync('lw_wp1_v1v2_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final dbFile = File(p.join(tempDir.path, 'v1v2.sqlite'));
      final db = AppDatabase(NativeDatabase(dbFile));
      final clock = TestClock(DateTime.utc(2026, 11, 25, 12, 0));
      const v1Salt = '00112233445566778899aabbccddeeff';
      final v1Hash = ParentGateCrypto.sha256V1PinHex(pin: '8392', salt: v1Salt);
      await db.applyMetadataBatch([
        MetadataMutation.upsert(
          key: ParentGateService.pinSaltKey,
          value: v1Salt,
          updatedAt: clock.now(),
        ),
        MetadataMutation.upsert(
          key: ParentGateService.pinHashKey,
          value: v1Hash,
          updatedAt: clock.now(),
        ),
        MetadataMutation.upsert(
          key: ParentGateService.activeChildSessionKey,
          value: '{"id":"child-a","family_id":"fam-a"}',
          updatedAt: clock.now(),
        ),
      ]);

      final service = ParentGateService(
        db,
        clock: clock,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      expect(
        (await service.inspectCredential()).status,
        ParentGateCredentialStatus.legacyV1,
      );

      final fence = const ParentGateOperationFence(
        actorUserId: 'actor-a',
        sessionGeneration: 1,
        containmentEpoch: 1,
        expectedContainmentStatus: 'active_child',
        verifiedFamilyId: 'fam-a',
        expectedChildId: 'child-a',
        expectedChildSessionRaw: '{"id":"child-a","family_id":"fam-a"}',
      );

      // Barrier 1 aborts INSIDE SQLite transaction after preliminary read and
      // before mutation admission -> v1 & child session untouched on disk
      var guardOk = true;
      final aborted = await service.verifyPinDetailed(
        '8392',
        actorFamilyId: 'fam-a',
        actorUserId: 'actor-a',
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-a'],
        fence: fence,
        onBeforeFinalizePreCommitGuard: () async {
          guardOk = false;
        },
        preCommitGuard: () => guardOk,
        additionalMutationsBuilder: (_) => const [
          MetadataMutation.delete(key: ParentGateService.activeChildSessionKey),
        ],
      );
      expect(aborted.outcome, PinVerificationOutcome.staleFence);
      expect(await db.readMetadata(ParentGateService.credentialV2Key), isNull);
      expect(
        await db.readMetadata(ParentGateService.pinHashKey),
        equals(v1Hash),
      );
      expect(
        await db.readMetadata(ParentGateService.activeChildSessionKey),
        isNotNull,
      );

      // Authorized positive adult check without fence abort upgrades atomically
      final upgraded = await service.verifyPinDetailed(
        '8392',
        actorFamilyId: 'fam-a',
        actorUserId: 'actor-a',
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-a'],
        fence: fence,
      );
      expect(upgraded.isVerified, isTrue);
      expect(upgraded.upgradedFromV1, isTrue);
      await db.close();

      final reopened = AppDatabase(NativeDatabase(dbFile));
      addTearDown(reopened.close);
      expect(await reopened.readMetadata(ParentGateService.pinHashKey), isNull);
      expect(await reopened.readMetadata(ParentGateService.pinSaltKey), isNull);

      final v2 = ParentGateCredentialV2.tryParse(
        await reopened.readMetadata(ParentGateService.credentialV2Key),
        minIterations: 1000,
      )!;
      expect(v2.ownerFamilyId, equals('fam-a'));
      expect(v2.configuredByActorUserId, equals('actor-a'));
    });

    test('R39-03: corrupt credentials fail closed, reject setPin & restrict recoverCorruptCredential strictly to corrupted/missing states', () async {
      final store = InMemoryLocalMetadataStore();
      final clock = TestClock(DateTime.utc(2026, 11, 25, 12, 0));
      await store.writeMetadata(
        key: ParentGateService.credentialV2Key,
        value: '{"version":2,"corrupt":true}',
        updatedAt: clock.now(),
      );

      final service = ParentGateService(
        store,
        clock: clock,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      expect(
        (await service.inspectCredential()).status,
        ParentGateCredentialStatus.corrupt,
      );
      expect(
        (await service.verifyPinDetailed('8392')).outcome,
        PinVerificationOutcome.corruptCredential,
      );
      await expectLater(
        () => service.setPin('4455', ownerFamilyId: 'fam-a'),
        throwsA(isA<ParentGatePinCorruptException>()),
      );

      await service.recoverCorruptCredential(
        newPin: '4455',
        targetFamilyId: 'fam-a',
        actorUserId: 'actor-a',
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-a'],
      );
      expect(await service.verifyPin('4455', actorFamilyId: 'fam-a'), isTrue);

      // Once valid v2 is restored, recoverCorruptCredential MUST NOT act as a generic overwrite
      await expectLater(
        () => service.recoverCorruptCredential(
          newPin: '9999',
          targetFamilyId: 'fam-a',
          actorUserId: 'actor-a',
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const ['fam-a'],
        ),
        throwsA(isA<ParentGatePinAlreadyConfiguredException>()),
      );
      await expectLater(
        () => service.recoverCorruptCredential(
          newPin: '9999',
          targetFamilyId: 'fam-b',
          actorUserId: 'actor-b',
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const ['fam-b'],
        ),
        throwsA(isA<ParentGateOwnershipConflictException>()),
      );
    });

    test('R39-03 & C0-27: setPin restricted to initial setup; rejects same-family & cross-family overwrites, enforces changePin, and supports explicit reassignment', () async {
      final store = InMemoryLocalMetadataStore();
      final service = ParentGateService(
        store,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      // Initial setup on empty store succeeds
      await service.setPin(
        '8392',
        ownerFamilyId: 'fam-a',
        configuredByActorUserId: 'actor-a',
      );

      // Same-family unauthorized overwrite via setPin MUST FAIL
      await expectLater(
        () => service.setPin(
          '1122',
          ownerFamilyId: 'fam-a',
          configuredByActorUserId: 'actor-a',
        ),
        throwsA(isA<ParentGatePinAlreadyConfiguredException>()),
      );
      expect(await service.verifyPin('8392', actorFamilyId: 'fam-a'), isTrue);

      // Wrong household silent overwrite & cross-family resetPinAfterReauth rejected
      await expectLater(
        () => service.setPin('1122', ownerFamilyId: 'fam-b'),
        throwsA(isA<ParentGateOwnershipConflictException>()),
      );
      await expectLater(
        () => service.resetPinAfterReauth(
          newPin: '1122',
          targetFamilyId: 'fam-b',
          actorUserId: 'actor-b',
          isPostSignOutFreshAdultAuth: true,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const ['fam-b'],
        ),
        throwsA(isA<ParentGateOwnershipConflictException>()),
      );

      // Same household changePin requires current PIN first
      final badChange = await service.changePin(
        currentPin: '0000',
        newPin: '5566',
        actorFamilyId: 'fam-a',
        actorUserId: 'actor-a',
      );
      expect(badChange.outcome, PinVerificationOutcome.incorrectPin);

      final goodChange = await service.changePin(
        currentPin: '8392',
        newPin: '5566',
        actorFamilyId: 'fam-a',
        actorUserId: 'actor-a',
      );
      expect(goodChange.isVerified, isTrue);
      expect(await service.verifyPin('5566', actorFamilyId: 'fam-a'), isTrue);

      // Explicit confirmed cross-family reassignment rebinds ownership to fam-b
      await service.reassignCrossFamilyPin(
        newPin: '7788',
        targetFamilyId: 'fam-b',
        actorUserId: 'actor-b',
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-b'],
      );
      expect(await service.readOwnerFamilyId(), equals('fam-b'));
      expect(await service.verifyPin('7788', actorFamilyId: 'fam-b'), isTrue);

      // Legacy v1 store ALSO blocks setPin overwrite without authentication/recovery
      final v1Store = InMemoryLocalMetadataStore();
      await v1Store.applyMetadataBatch([
        MetadataMutation.upsert(
          key: ParentGateService.pinSaltKey,
          value: '00112233445566778899aabbccddeeff',
          updatedAt: DateTime.utc(2026),
        ),
        MetadataMutation.upsert(
          key: ParentGateService.pinHashKey,
          value: ParentGateCrypto.sha256V1PinHex(
            pin: '8392',
            salt: '00112233445566778899aabbccddeeff',
          ),
          updatedAt: DateTime.utc(2026),
        ),
      ]);
      final v1Service = ParentGateService(
        v1Store,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      await expectLater(
        () => v1Service.setPin('1234', ownerFamilyId: 'fam-a'),
        throwsA(isA<ParentGatePinAlreadyConfiguredException>()),
      );
    });

    test('Barrier 1 and Barrier 2 fence checks abort stale unlock without deleting child session', () async {
      final store = InMemoryLocalMetadataStore();
      final t0 = DateTime.utc(2026, 11, 25, 12, 0);
      await store.writeMetadata(
        key: ParentGateService.activeChildSessionKey,
        value: '{"id":"child-a","family_id":"fam-a"}',
        updatedAt: t0,
      );
      final initialFence = ContainmentFenceV1(
        version: 1,
        fenceEpoch: 1,
        actorUserId: 'actor-a',
        sessionGeneration: 1,
        lockState: ContainmentFenceLockState.activeChild,
        updatedAtUtc: DateTime.utc(2026, 11, 25, 12, 0),
      ).toJsonString();
      await store.writeMetadata(
        key: ParentGateService.containmentFenceV1Key,
        value: initialFence,
        updatedAt: t0,
      );

      final service = ParentGateService(
        store,
        clock: TestClock(t0),
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      await service.setPin(
        '8392',
        ownerFamilyId: 'fam-a',
        configuredByActorUserId: 'actor-a',
      );

      final fence = ParentGateOperationFence(
        actorUserId: 'actor-a',
        sessionGeneration: 1,
        containmentEpoch: 1,
        expectedContainmentStatus: 'active_child',
        verifiedFamilyId: 'fam-a',
        expectedChildId: 'child-a',
        expectedChildSessionRaw: '{"id":"child-a","family_id":"fam-a"}',
        expectedContainmentFenceRaw: initialFence,
        expectedCredentialRevision: 1,
      );

      // Barrier 1: preCommitGuard flips false right before commit
      var guardOk = true;
      final barrier1Res = await service.verifyPinDetailed(
        '8392',
        fence: fence,
        onBeforeFinalizePreCommitGuard: () async {
          guardOk = false;
        },
        preCommitGuard: () => guardOk,
        additionalMutationsBuilder: (_) => const [
          MetadataMutation.delete(key: ParentGateService.activeChildSessionKey),
        ],
      );
      expect(barrier1Res.outcome, PinVerificationOutcome.staleFence);
      expect(
        await store.readMetadata(ParentGateService.activeChildSessionKey),
        isNotNull,
      );

      // Barrier 2: concurrent containment fence bump lands during async commit window
      final barrier2Res = await service.verifyPinDetailed(
        '8392',
        fence: fence,
        onAfterFinalizeGuardBeforeCommit: () async {
          await store.writeMetadata(
            key: ParentGateService.containmentFenceV1Key,
            value: ContainmentFenceV1(
              version: 1,
              fenceEpoch: 2,
              actorUserId: null,
              sessionGeneration: 2,
              lockState: ContainmentFenceLockState.recoveryReauthPending,
              updatedAtUtc: DateTime.utc(2026, 11, 25, 12, 1),
            ).toJsonString(),
            updatedAt: t0,
          );
        },
        additionalMutationsBuilder: (_) => const [
          MetadataMutation.delete(key: ParentGateService.activeChildSessionKey),
        ],
      );
      expect(
        barrier2Res.outcome,
        anyOf(
          PinVerificationOutcome.staleFence,
          PinVerificationOutcome.concurrencyRetryExhausted,
        ),
      );
      expect(
        await store.readMetadata(ParentGateService.activeChildSessionKey),
        isNotNull,
      );
    });
  });

  group('C0-39 & R38-10 3-level legacy ownership & file-backed recovery preservation', () {
    test('R38-10 4-conjunct provenance predicate classifies BoundOwner, CorroboratedLegacyOwner, and all Unresolvable cases', () async {
      final store = InMemoryLocalMetadataStore();
      final provenance = InMemoryLegacyOutboxProvenanceSource();
      final service = ParentGateService(
        store,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );

      const validHintA =
          '{"id":"child-a","family_id":"fam-a","display_name":"Leo"}';
      await store.writeMetadata(
        key: ParentGateService.activeChildSessionKey,
        value: validHintA,
        updatedAt: DateTime.utc(2026),
      );

      // (a) Zero outbox rows + v1 PIN -> Unresolvable for Exit Path B auto-unlock
      final zeroOutbox = await service.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-a'],
      );
      expect(zeroOutbox, isA<UnresolvableLegacyOwnershipResolution>());
      expect(zeroOutbox.allowsExitPathBAutoUnlockForFamily('fam-a'), isFalse);

      // (c) Matching actor-bound (fam-a, child-a) outbox row + adult verification -> CorroboratedLegacyOwner
      provenance.setRecords([
        const ActorBoundOutboxRecord(
          source: LegacyOutboxRecordSource.assessmentDraft,
          recordId: 'd1',
          familyId: 'fam-a',
          childId: 'child-a',
          actorUserId: 'actor-a',
        ),
      ]);
      final corroborated = await service.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-a'],
      );
      expect(corroborated, isA<CorroboratedLegacyOwnerResolution>());
      expect(corroborated.allowsExitPathBAutoUnlockForFamily('fam-a'), isTrue);
      expect(corroborated.allowsExitPathBAutoUnlockForFamily('fam-b'), isFalse);

      // (d) Malformed legacy hint + single actor-bound fam-b outbox row -> Unresolvable (Conjunct (i) fails!)
      provenance.setRecords([
        const ActorBoundOutboxRecord(
          source: LegacyOutboxRecordSource.rewardCommand,
          recordId: 'c1',
          familyId: 'fam-b',
          childId: 'child-b',
          actorUserId: 'actor-b',
        ),
      ]);
      final malformedHint = await service.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-b'],
        legacyChildSessionRaw: '{broken-json',
      );
      expect(malformedHint, isA<UnresolvableLegacyOwnershipResolution>());
      expect(
        malformedHint.allowsExitPathBAutoUnlockForFamily('fam-b'),
        isFalse,
      );

      // (e) fam-a hint + fam-b outbox provenance -> Unresolvable (Conjuncts (ii)-(iii) fail)
      final contradictory = await service.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-a', 'fam-b'],
        legacyChildSessionRaw: validHintA,
      );
      expect(contradictory, isA<UnresolvableLegacyOwnershipResolution>());

      // (f1) fam-a (child-a) hint + ONLY childId==null command -> Unresolvable (Conjunct (iii) fails)
      provenance.setRecords([
        const ActorBoundOutboxRecord(
          source: LegacyOutboxRecordSource.rewardCommand,
          recordId: 'c-null',
          familyId: 'fam-a',
          childId: null,
          actorUserId: 'actor-a',
        ),
      ]);
      final nullChildCmd = await service.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-a'],
        legacyChildSessionRaw: validHintA,
      );
      expect(nullChildCmd, isA<UnresolvableLegacyOwnershipResolution>());

      // (f2) fam-a (child-a) hint + ONLY child-other row -> Unresolvable (Conjunct (iii) fails)
      provenance.setRecords([
        const ActorBoundOutboxRecord(
          source: LegacyOutboxRecordSource.assessmentDraft,
          recordId: 'd-other',
          familyId: 'fam-a',
          childId: 'child-other',
          actorUserId: 'actor-a',
        ),
      ]);
      final otherChildRow = await service.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-a'],
        legacyChildSessionRaw: validHintA,
      );
      expect(otherChildRow, isA<UnresolvableLegacyOwnershipResolution>());

      // BoundOwnerResolution takes authoritative precedence once v2 PIN is set
      await service.setPin('8392', ownerFamilyId: 'fam-a');
      final bound = await service.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-b'],
      );
      expect(bound, isA<BoundOwnerResolution>());
      expect(bound.allowsExitPathBAutoUnlockForFamily('fam-a'), isTrue);
      expect(bound.allowsExitPathBAutoUnlockForFamily('fam-b'), isFalse);
    });

    test('C0-39(g): Restricted Manual Unbound Recovery on file-backed SQLite clears locks, writes redacted audit, and preserves 100% drafts/commands/evidence bytes', () async {
      final tempDir = Directory.systemTemp.createTempSync('lw_wp1_c039_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final dbFile = File(p.join(tempDir.path, 'c039.sqlite'));
      final photoFile = File(p.join(tempDir.path, 'evidence.jpg'));
      final photoBytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6];
      await photoFile.writeAsBytes(photoBytes, flush: true);
      final expectedPhotoDigest = sha256.convert(photoBytes).toString();

      final db = AppDatabase(NativeDatabase(dbFile));
      final t0 = DateTime.utc(2026, 11, 25, 12, 0);

      await db.saveLocalDraft(
        LocalAssessmentDraft(
          localDraftId: 'draft-preserve-1',
          familyId: 'fam-a',
          childId: 'child-a',
          subjectKey: SubjectKey.math,
          subject: 'Math',
          title: 'Quiz 1',
          assessmentType: 'quiz',
          difficulty: 'easy',
          rawScore: 10,
          maxScore: 10,
          localCompressedPhotoPath: photoFile.path,
          sha256Checksum: expectedPhotoDigest,
          occurredAt: t0,
          updatedAt: t0,
          actorUserId: 'actor-a',
          actorRole: 'owner',
        ),
      );
      await db.registerFreshCommand(
        command: PendingRewardCommand(
          operation: RewardCommandOperation.redeemReward,
          commandId: 'cmd-preserve-1',
          familyId: 'fam-a',
          childId: 'child-a',
          rewardId: 'rew-1',
          createdAt: t0,
          actorUserId: 'actor-a',
          actorRole: 'owner',
        ),
      );

      await db.applyMetadataBatch([
        MetadataMutation.upsert(
          key: ParentGateService.activeChildSessionKey,
          value: '{malformed-legacy-session',
          updatedAt: t0,
        ),
        MetadataMutation.upsert(
          key: ParentGateService.containmentRecoveryLockV1Key,
          value: ContainmentRecoveryLockV1(
            version: 1,
            reason: 'manual_recovery_required',
            ownershipLevel: ContainmentRecoveryOwnershipLevel.unresolvable,
            initiatedFromSessionGeneration: 1,
            initiatedAtUtc: t0,
          ).toJsonString(),
          updatedAt: t0,
        ),
        MetadataMutation.upsert(
          key: ParentGateService.credentialV2Key,
          value: '{corrupt-v2',
          updatedAt: t0,
        ),
      ]);

      final clock = TestClock(t0.add(const Duration(minutes: 5)));
      final service = ParentGateService(
        db,
        clock: clock,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );

      final fence = const ParentGateOperationFence(
        actorUserId: 'actor-recover',
        sessionGeneration: 2,
        containmentEpoch: 1,
        expectedContainmentStatus: 'recovery_reauth_pending',
        verifiedFamilyId: 'fam-recover',
        expectedChildSessionRaw: '{malformed-legacy-session',
      );

      // Non-fresh / unverified callers MUST be rejected without mutating locks
      await expectLater(
        () => service.commitRestrictedManualUnboundRecovery(
          newPin: '2468',
          actorUserId: 'actor-recover',
          targetFamilyId: 'fam-recover',
          isPostSignOutFreshAdultAuth: false,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const ['fam-recover'],
          fence: fence,
        ),
        throwsA(isA<ParentGateFencedOperationException>()),
      );
      expect(
        await db.readMetadata(ParentGateService.containmentRecoveryLockV1Key),
        isNotNull,
      );

      // Authorized fresh post-sign-out verified adult completes Restricted Manual Unbound Recovery
      final newCred = await service.commitRestrictedManualUnboundRecovery(
        newPin: '2468',
        actorUserId: 'actor-recover',
        targetFamilyId: 'fam-recover',
        isPostSignOutFreshAdultAuth: true,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const ['fam-recover'],
        fence: fence,
      );
      expect(newCred.ownerFamilyId, equals('fam-recover'));
      expect(newCred.configuredByActorUserId, equals('actor-recover'));

      await db.close();

      // Reopen file-backed SQLite to verify durability, lock clearing, audit, and 100% data preservation
      final reopened = AppDatabase(NativeDatabase(dbFile));
      addTearDown(reopened.close);

      expect(
        await reopened.readMetadata(ParentGateService.activeChildSessionKey),
        isNull,
      );
      expect(
        await reopened.readMetadata(
          ParentGateService.containmentRecoveryLockV1Key,
        ),
        isNull,
      );

      final auditRaw = await reopened.readMetadata(
        ParentGateService.lastContainmentRecoveryAuditV1Key,
      );
      final audit = LastContainmentRecoveryAuditV1.tryParse(auditRaw)!;
      expect(
        audit.reason,
        equals(
          LastContainmentRecoveryAuditV1.manualUnboundLegacyRecoveryReason,
        ),
      );
      expect(audit.targetFamilyId, equals('fam-recover'));
      expect(audit.actorUserId, equals('actor-recover'));
      expect(auditRaw, isNot(contains('2468')));

      final drafts = await reopened.listActorBoundRecords();
      expect(
        drafts.where((r) => r.recordId == 'draft-preserve-1'),
        hasLength(1),
      );
      expect(drafts.where((r) => r.recordId == 'cmd-preserve-1'), hasLength(1));
      expect(
        sha256.convert(await photoFile.readAsBytes()).toString(),
        equals(expectedPhotoDigest),
      );
    });

    test('InMemoryMobileMetadataStore parity with LocalMetadataStore CAS & ParentGateService', () async {
      final mobileStore = InMemoryMobileMetadataStore();
      final t0 = DateTime.utc(2026, 11, 25, 12, 0);

      await mobileStore.applyMetadataBatch([
        MetadataMutation.upsert(key: 'a', value: '1', updatedAt: t0),
        MetadataMutation.upsert(key: 'b', value: '2', updatedAt: t0),
      ]);
      await mobileStore.applyMetadataBatch([
        const MetadataMutation.delete(key: 'b'),
      ]);
      expect(await mobileStore.readMetadata('a'), equals('1'));
      expect(await mobileStore.readMetadata('b'), isNull);

      // Barrier 1 abort
      var guard = true;
      final b1 = await mobileStore.compareAndSwapMetadataBatch(
        expectedValues: {'a': '1'},
        mutations: [
          MetadataMutation.upsert(key: 'a', value: 'bad', updatedAt: t0),
        ],
        onBeforePreCommitGuard: () async => guard = false,
        preCommitGuard: () => guard,
      );
      expect(b1, isFalse);
      expect(await mobileStore.readMetadata('a'), equals('1'));

      // Barrier 2 overlapping write abort
      final entered = Completer<void>();
      final release = Completer<void>();
      final first = mobileStore.compareAndSwapMetadataBatch(
        expectedValues: {'a': '1'},
        mutations: [
          MetadataMutation.upsert(key: 'a', value: 'first', updatedAt: t0),
        ],
        onAfterGuardBeforeCommit: () async {
          entered.complete();
          await release.future;
        },
      );
      await entered.future;
      final second = await mobileStore.compareAndSwapMetadataBatch(
        expectedValues: {'a': '1'},
        mutations: [
          MetadataMutation.upsert(key: 'a', value: 'second', updatedAt: t0),
        ],
      );
      release.complete();
      expect(second, isTrue);
      expect(await first, isFalse);
      expect(await mobileStore.readMetadata('a'), equals('second'));

      // ParentGateService round-trip
      final gate = ParentGateService(
        mobileStore,
        minIterations: 1000,
        configuredIterations: 1000,
        runInIsolate: false,
      );
      await gate.setPin('4242', ownerFamilyId: 'fam-m');
      expect(await gate.verifyPin('4242', actorFamilyId: 'fam-m'), isTrue);
    });
  });
}
