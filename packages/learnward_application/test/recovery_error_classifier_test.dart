import 'dart:async';
import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

/// Untrusted object simulating an arbitrary exception that happens to have a `code` property.
final class _UntrustedObjectWithCode implements Exception {
  const _UntrustedObjectWithCode({required this.message, required this.code});

  final String message;
  final String code;

  @override
  String toString() =>
      '_UntrustedObjectWithCode(code: $code, message: $message)';
}

void main() {
  group('RecoveryErrorClassifier Typed Backend Error Evidence (R24-2-02 & R24-3-01)', () {
    test('ambiguous transport error containing LW201 substring is transientRetryable, NOT terminal', () {
      final err = Exception('timeout LW201');
      final classified = RecoveryErrorClassifier.classify(err);

      expect(
        classified.action,
        equals(ClassifiedErrorAction.transientRetryable),
      );
      expect(classified.errorCode, equals('TRANSIENT_NETWORK'));
    });

    test('SocketException containing LW205 substring is transientRetryable, NOT terminal', () {
      final err = const SocketException('LW205 connection reset by peer');
      final classified = RecoveryErrorClassifier.classify(err);

      expect(
        classified.action,
        equals(ClassifiedErrorAction.transientRetryable),
      );
      expect(classified.errorCode, equals('TRANSIENT_NETWORK'));
    });

    test('generic untyped Exception with error code string fails closed to quarantineUnknownOutcome', () {
      final err = Exception('LW201: Insufficient balance');
      final classified = RecoveryErrorClassifier.classify(err);

      expect(
        classified.action,
        equals(ClassifiedErrorAction.quarantineUnknownOutcome),
      );
    });

    test('InvalidRewardException with message-embedded LW201 does NOT produce terminal deletion (R24-3-01)', () {
      final err = const InvalidRewardException(
        'ambiguous LW201 text entered by user',
      );
      expect(err.code, isNull);

      final classified = RecoveryErrorClassifier.classify(err);
      expect(
        classified.action,
        equals(ClassifiedErrorAction.quarantineUnknownOutcome),
      );
      expect(classified.errorCode, isNot(equals('LW201')));
    });

    test('InvalidWheelException with message-embedded LW206 does NOT produce terminal deletion (R24-3-01)', () {
      final err = const InvalidWheelException('LW206 in text');
      expect(err.code, isNull);

      final classified = RecoveryErrorClassifier.classify(err);
      expect(
        classified.action,
        equals(ClassifiedErrorAction.quarantineUnknownOutcome),
      );
      expect(classified.errorCode, isNot(equals('LW206')));
    });

    test('untrusted object with code=LW201 not implementing BackendRpcError fails closed (R24-3-01)', () {
      final err = const _UntrustedObjectWithCode(
        message: 'Random failure',
        code: 'LW201',
      );
      final classified = RecoveryErrorClassifier.classify(err);
      expect(
        classified.action,
        equals(ClassifiedErrorAction.quarantineUnknownOutcome),
      );
      expect(classified.errorCode, isNot(equals('LW201')));
    });

    test('adversarial R24-4-04: typed LW201 with message containing 500 must NOT be classified as transient retryable', () {
      final err = const BackendRpcException(
        code: 'LW201',
        message: 'Current points balance 500 is insufficient for cost 1500',
      );
      final classified = RecoveryErrorClassifier.classify(err);
      expect(
        classified.action,
        equals(ClassifiedErrorAction.terminalWhitelisted),
      );
      expect(classified.errorCode, equals('LW201'));
    });

    test('adversarial R24-4-04: typed LW205 with message containing timeout and 504 must be terminalWhitelisted', () {
      final err = const BackendRpcException(
        code: 'LW205',
        message: 'Reward redemption timed out after 504 ms of inactivity',
      );
      final classified = RecoveryErrorClassifier.classify(err);
      expect(
        classified.action,
        equals(ClassifiedErrorAction.terminalWhitelisted),
      );
      expect(classified.errorCode, equals('LW205'));
    });

    test('genuine typed BackendRpcException with LW201 is classified as terminalWhitelisted', () {
      final err = const BackendRpcException(
        message: 'Insufficient RP balance',
        code: 'LW201',
      );
      final classified = RecoveryErrorClassifier.classify(err);

      expect(
        classified.action,
        equals(ClassifiedErrorAction.terminalWhitelisted),
      );
      expect(classified.errorCode, equals('LW201'));
    });

    test('all whitelisted terminal business codes (LW201, LW202, LW203, LW205, LW206) with typed signals classify as terminalWhitelisted', () {
      final codes = ['LW201', 'LW202', 'LW203', 'LW205', 'LW206'];
      for (final code in codes) {
        final err = BackendRpcException(
          message: 'Definitive terminal error',
          code: code,
        );
        final classified = RecoveryErrorClassifier.classify(err);

        expect(
          classified.action,
          equals(ClassifiedErrorAction.terminalWhitelisted),
          reason: 'Code $code must be classified as terminalWhitelisted',
        );
        expect(classified.errorCode, equals(code));
      }
    });

    test('domain exceptions with explicit code parameter classify as terminalWhitelisted when whitelisted', () {
      final rewardErr = const InvalidRewardException(
        'Insufficient RP balance',
        code: 'LW201',
      );
      final classifiedReward = RecoveryErrorClassifier.classify(rewardErr);
      expect(
        classifiedReward.action,
        equals(ClassifiedErrorAction.terminalWhitelisted),
      );
      expect(classifiedReward.errorCode, equals('LW201'));

      final wheelErr = const InvalidWheelException(
        'Wheel is currently disabled',
        code: 'LW206',
      );
      final classifiedWheel = RecoveryErrorClassifier.classify(wheelErr);
      expect(
        classifiedWheel.action,
        equals(ClassifiedErrorAction.terminalWhitelisted),
      );
      expect(classifiedWheel.errorCode, equals('LW206'));
    });

    test('typed non-whitelisted code (LW204, P0002, 22000) classifies as quarantineUnknownOutcome', () {
      final nonWhitelisted = ['LW204', 'P0002', '22000'];
      for (final code in nonWhitelisted) {
        final err = BackendRpcException(message: 'Domain error', code: code);
        final classified = RecoveryErrorClassifier.classify(err);

        expect(
          classified.action,
          equals(ClassifiedErrorAction.quarantineUnknownOutcome),
          reason: 'Code $code must NOT be whitelisted for deletion',
        );
      }
    });

    test(
      'authorization denial (42501) classifies as quarantineUnknownOutcome',
      () {
        final err = const BackendRpcException(
          message: 'permission denied for table child_device_grants',
          code: '42501',
        );
        final classified = RecoveryErrorClassifier.classify(err);

        expect(
          classified.action,
          equals(ClassifiedErrorAction.quarantineUnknownOutcome),
        );
        expect(classified.errorCode, equals('42501'));
      },
    );

    test('transport exceptions (TimeoutException, 503) classify as transientRetryable', () {
      final timeoutErr = TimeoutException('Request timeout');
      expect(
        RecoveryErrorClassifier.classify(timeoutErr).action,
        equals(ClassifiedErrorAction.transientRetryable),
      );

      final httpErr = Exception('503 Service Unavailable');
      expect(
        RecoveryErrorClassifier.classify(httpErr).action,
        equals(ClassifiedErrorAction.transientRetryable),
      );
    });
  });
}
