import 'dart:async';
import 'dart:io';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

/// Simulates a PostgrestException from Supabase client carrying typed properties.
final class _FakePostgrestException implements Exception {
  const _FakePostgrestException({required this.message, required this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'PostgrestException(message: $message, code: $code)';
}

void main() {
  group('RecoveryErrorClassifier Typed Backend Error Evidence (R24-2-02)', () {
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

    test('genuine typed PostgrestException with LW201 is classified as terminalWhitelisted', () {
      final err = const _FakePostgrestException(
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
        final err = _FakePostgrestException(
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

    test('domain exceptions implementing BackendRpcError classify as terminalWhitelisted when whitelisted', () {
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
        final err = _FakePostgrestException(
          message: 'Domain error',
          code: code,
        );
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
        final err = const _FakePostgrestException(
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
