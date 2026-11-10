import 'package:learnward_application/learnward_application.dart';
import 'package:test/test.dart';

void main() {
  group(
    'R29-04: Strict Canonical Unverified-Miss Marker Parsing & Formatting',
    () {
      test('parses valid canonical markers strictly', () {
        final cmd1 = PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'c1',
          familyId: 'f1',
          createdAt: DateTime.utc(2026, 11, 1),
          lastErrorMessage:
              '[UNVERIFIED_TARGET_MISS:1/3] Target row unverified.',
        );
        expect(cmd1.consecutiveUnverifiedTargetMisses, 1);

        final cmd2 = PendingRewardCommand(
          operation: RewardCommandOperation.fulfillReward,
          commandId: 'c2',
          familyId: 'f1',
          createdAt: DateTime.utc(2026, 11, 1),
          lastErrorMessage: '[UNVERIFIED_TARGET_MISS:2/3] Target row unverified; consecutive miss 2/3.',
        );
        expect(cmd2.consecutiveUnverifiedTargetMisses, 2);

        final cmd3 = PendingRewardCommand(
          operation: RewardCommandOperation.cancelReward,
          commandId: 'c3',
          familyId: 'f1',
          createdAt: DateTime.utc(2026, 11, 1),
          lastErrorMessage: '[UNVERIFIED_TARGET_MISS:3/3] Target remained unverified after 3 misses; quarantined.',
        );
        expect(cmd3.consecutiveUnverifiedTargetMisses, 3);
      });

      test('rejects out-of-range numerator markers', () {
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:0/3] detail',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:4/3] detail',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:9/999] detail',
          ),
          0,
        );
      });

      test('rejects non-canonical denominator markers', () {
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:2/4] detail',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:1/1] detail',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:3/5] detail',
          ),
          0,
        );
      });

      test('rejects truncated and malformed markers', () {
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:1/',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:1/3',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:1/3]',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:1/3] ',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:1/3]   ',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            '[UNVERIFIED_TARGET_MISS:',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            'UNVERIFIED_TARGET_MISS:1/3 detail',
          ),
          0,
        );
      });

      test('rejects unrelated error messages and null', () {
        expect(PendingRewardCommand.parseUnverifiedTargetMisses(null), 0);
        expect(PendingRewardCommand.parseUnverifiedTargetMisses(''), 0);
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            'SocketException: Connection timed out',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            'PostgrestException: 42501 permission denied',
          ),
          0,
        );
        expect(
          PendingRewardCommand.parseUnverifiedTargetMisses(
            'Temporary target verification failure (network/timeout); retry scheduled.',
          ),
          0,
        );
      });

      test('formatUnverifiedTargetMissMessage generates canonical format', () {
        final msg1 = PendingRewardCommand.formatUnverifiedTargetMissMessage(
          consecutiveMisses: 1,
          detail: 'detail 1',
        );
        expect(msg1, '[UNVERIFIED_TARGET_MISS:1/3] detail 1');
        expect(PendingRewardCommand.parseUnverifiedTargetMisses(msg1), 1);

        final msg2 = PendingRewardCommand.formatUnverifiedTargetMissMessage(
          consecutiveMisses: 2,
          detail: 'detail 2',
        );
        expect(msg2, '[UNVERIFIED_TARGET_MISS:2/3] detail 2');
        expect(PendingRewardCommand.parseUnverifiedTargetMisses(msg2), 2);

        final msg3 = PendingRewardCommand.formatUnverifiedTargetMissMessage(
          consecutiveMisses: 3,
          detail: 'detail 3',
        );
        expect(msg3, '[UNVERIFIED_TARGET_MISS:3/3] detail 3');
        expect(PendingRewardCommand.parseUnverifiedTargetMisses(msg3), 3);
      });

      test('formatUnverifiedTargetMissMessage validates inputs', () {
        expect(
          () => PendingRewardCommand.formatUnverifiedTargetMissMessage(
            consecutiveMisses: 0,
            detail: 'valid',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => PendingRewardCommand.formatUnverifiedTargetMissMessage(
            consecutiveMisses: 4,
            detail: 'valid',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => PendingRewardCommand.formatUnverifiedTargetMissMessage(
            consecutiveMisses: 2,
            detail: '   ',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => PendingRewardCommand.formatUnverifiedTargetMissMessage(
            consecutiveMisses: 2,
            detail: 'valid',
            maxMisses: 5,
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    },
  );
}
