import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'R24-3-05: Real Android SQLite runtime FFI smoke test — open, write, claim, mark, complete, restart and recover',
    (tester) async {
      final dbFile = File('${Directory.systemTemp.path}/test_runtime_smoke.db');
      if (await dbFile.exists()) {
        await dbFile.delete();
      }

      // 1. Initial Launch: Open AppDatabase (loads native bundled libsqlite3.so via FFI)
      var db = AppDatabase(NativeDatabase(dbFile));

      // 2. Insert outbox row
      final t0 = DateTime.utc(2026, 11, 8, 12, 0);
      const cmdId = 'cmd-android-smoke-1';
      final command = PendingRewardCommand(
        operation: RewardCommandOperation.spinWheel,
        commandId: cmdId,
        familyId: 'fam-smoke',
        childId: 'child-smoke',
        actorUserId: 'actor-smoke',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );

      await db.savePendingCommand(command, now: t0);

      // 3. Read back from real SQLite on device
      final fetched = await db.getPendingCommand(cmdId);
      expect(fetched, isNotNull);
      expect(fetched!.commandId, equals(cmdId));
      expect(
        fetched.dispatchState,
        equals(CommandDispatchState.neverDispatched),
      );
      expect(fetched.recoveryState, equals(CommandRecoveryState.active));

      // 4. Acquire atomic lease claim
      final leaseToken = await db.acquireClaim(
        commandId: cmdId,
        actorUserId: 'actor-smoke',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(leaseToken, isNotNull);

      // 5. Pre-send token-fenced marker
      final marked = await db.markPossiblyDispatched(
        commandId: cmdId,
        leaseToken: leaseToken!,
        authenticatedActorId: 'actor-smoke',
        now: t0,
      );
      expect(marked, isTrue);

      final markedRow = await db.getPendingCommand(cmdId);
      expect(
        markedRow!.dispatchState,
        equals(CommandDispatchState.possiblyDispatched),
      );

      // 6. Complete command
      final completed = await db.completeCommand(
        commandId: cmdId,
        leaseToken: leaseToken,
      );
      expect(completed, isTrue);

      final afterComplete = await db.getPendingCommand(cmdId);
      expect(afterComplete, isNull);

      // 7. Restart simulation: Close database and reopen from persistent file
      await db.close();

      db = AppDatabase(NativeDatabase(dbFile));

      // 8. Write second command, simulate crash during retry backoff, verify persistent recovery
      const cmdId2 = 'cmd-android-smoke-2';
      final command2 = PendingRewardCommand(
        operation: RewardCommandOperation.redeemReward,
        commandId: cmdId2,
        familyId: 'fam-smoke',
        childId: 'child-smoke',
        rewardId: 'rew-smoke',
        actorUserId: 'actor-smoke',
        createdAt: t0,
        recoveryState: CommandRecoveryState.active,
        dispatchState: CommandDispatchState.neverDispatched,
      );
      await db.savePendingCommand(command2, now: t0);

      final lease2 = await db.acquireClaim(
        commandId: cmdId2,
        actorUserId: 'actor-smoke',
        leaseDuration: const Duration(seconds: 30),
        now: t0,
      );
      expect(lease2, isNotNull);

      final scheduledTime = t0.add(const Duration(seconds: 5));
      final released = await db.releaseClaim(
        commandId: cmdId2,
        leaseToken: lease2!,
        nextAttemptAt: scheduledTime,
        lastErrorMessage: 'Temporary 503 service unavailable',
      );
      expect(released, isTrue);

      // Verify persisted state across restart
      await db.close();
      db = AppDatabase(NativeDatabase(dbFile));

      final persistedAfterRestart = await db.getPendingCommand(cmdId2);
      expect(persistedAfterRestart, isNotNull);
      expect(persistedAfterRestart!.retryCount, equals(1));
      expect(persistedAfterRestart.lastErrorMessage, contains('503'));
      expect(persistedAfterRestart.leaseToken, isNull);

      await db.close();
      if (await dbFile.exists()) {
        await dbFile.delete();
      }
    },
  );
}
