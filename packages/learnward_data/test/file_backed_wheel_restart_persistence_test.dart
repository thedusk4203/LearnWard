import 'dart:io';

import 'package:drift/native.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  group('File-Backed SQLite Restart Persistence for Celebration Wheel', () {
    late Directory tempDir;
    late File dbFile;
    late FakeWheelRepository fakeServer;
    late FakeAuthSessionPort defaultAuth;
    late FakeRecoveryAuthorizationPort defaultAuthz;

    final familyId = FamilyId('fam-wheel-restart-1');
    final childId = ChildId('ch-wheel-restart-1');
    final now = DateTime.utc(2026, 11, 2, 10, 0);

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('learnward_wheel_restart_');
      dbFile = File('${tempDir.path}/wheel_commands.sqlite');
      fakeServer = FakeWheelRepository(randomSeed: 123);
      defaultAuth = FakeAuthSessionPort(
        activeUserId: 'usr-child-1',
        role: 'child',
      );
      defaultAuthz = FakeRecoveryAuthorizationPort(
        defaultStatus: TargetAuthorizationStatus.authorized,
      );

      // Seed 3 active eligible wheel rewards
      fakeServer.addReward(
        Reward(
          id: RewardId('rw-1'),
          familyId: familyId,
          title: 'Extra Screen Time',
          category: RewardCategory.privilege,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.common,
          createdAt: now,
          updatedAt: now,
        ),
      );
      fakeServer.addReward(
        Reward(
          id: RewardId('rw-2'),
          familyId: familyId,
          title: 'Ice Cream Sundae',
          category: RewardCategory.treat,
          storeEnabled: true,
          storeCostMinor: 1500,
          wheelEnabled: true,
          wheelTier: WheelTier.special,
          createdAt: now,
          updatedAt: now,
        ),
      );
      fakeServer.addReward(
        Reward(
          id: RewardId('rw-3'),
          familyId: familyId,
          title: 'Theme Park Trip',
          category: RewardCategory.experience,
          storeEnabled: false,
          wheelEnabled: true,
          wheelTier: WheelTier.rare,
          createdAt: now,
          updatedAt: now,
        ),
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('Spin: persists command to real SQLite file, survives process restart, retries safely without duplicate spin, and cleans disk journal', () async {
      // --- Process / Session 1: Initial Spin Attempt with commit-response-loss ---
      final dbA = AppDatabase(NativeDatabase(dbFile));
      final spinUseCaseA = SpinRewardWheel(
        fakeServer,
        dbA,
        authSessionPort: defaultAuth,
        authorizationPort: defaultAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );

      fakeServer.failAfterCommitResponseLost = true;

      await expectLater(
        spinUseCaseA(
          familyId: familyId,
          childId: childId,
          actorUserId: 'usr-child-1',
        ),
        throwsA(isA<Exception>()),
      );

      // Server committed 1 spin in session 1
      final spinsAfterSession1 = await fakeServer.listWheelSpins(
        familyId: familyId,
        childId: childId,
      );
      expect(spinsAfterSession1.length, equals(1));
      final originalSpinId = spinsAfterSession1.first.id;

      // Close dbA to simulate process crash / termination
      await dbA.close();

      // --- Process / Session 2: Fresh App Launch Reopening Same SQLite File ---
      final dbB = AppDatabase(NativeDatabase(dbFile));

      // Verify exact pending command payload survived the database close/reopen
      final pendingOnDisk = await dbB.findPendingSpinCommand(
        familyId: familyId.value,
        childId: childId.value,
      );
      expect(
        pendingOnDisk,
        isNotNull,
        reason:
            'Wheel spin command must persist to disk across process restart',
      );
      expect(
        pendingOnDisk!.operation,
        equals(RewardCommandOperation.spinWheel),
      );
      expect(pendingOnDisk.familyId, equals(familyId.value));
      expect(pendingOnDisk.childId, equals(childId.value));
      expect(pendingOnDisk.actorUserId, equals('usr-child-1'));
      expect(
        pendingOnDisk.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );
      final persistedCommandId = pendingOnDisk.commandId;
      expect(persistedCommandId, isNotEmpty);

      // Retry spin with dbB on fresh app session with matching actor
      final spinUseCaseB = SpinRewardWheel(
        fakeServer,
        dbB,
        authSessionPort: defaultAuth,
        authorizationPort: defaultAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
      final recoveredResult = await spinUseCaseB(
        commandId: persistedCommandId,
        familyId: familyId,
        childId: childId,
        actorUserId: 'usr-child-1',
      );

      // Assert server deduplicated via command receipt: exactly 1 spin exists
      final spinsAfterRecovery = await fakeServer.listWheelSpins(
        familyId: familyId,
        childId: childId,
      );
      expect(
        spinsAfterRecovery.length,
        equals(1),
        reason: 'Retry must not trigger a second spin or debit',
      );
      expect(recoveredResult.spinId, equals(originalSpinId));

      // Verify journal row is deleted from disk after confirmed outcome
      final remainingOnDisk = await dbB.listPendingCommands();
      expect(remainingOnDisk, isEmpty);

      // --- Process / Session 3: Subsequent User Action gets a BRAND NEW command ID ---
      final spinUseCaseC = SpinRewardWheel(
        fakeServer,
        dbB,
        authSessionPort: defaultAuth,
        authorizationPort: defaultAuthz,
        jitterSource: const DeterministicJitterSource(0.0),
      );
      final nextResult = await spinUseCaseC(
        familyId: familyId,
        childId: childId,
        actorUserId: 'usr-child-1',
      );

      expect(nextResult.spinId, isNot(equals(originalSpinId)));
      final finalSpins = await fakeServer.listWheelSpins(
        familyId: familyId,
        childId: childId,
      );
      expect(finalSpins.length, equals(2));

      await dbB.close();
    });
  });
}
