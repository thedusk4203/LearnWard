import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/features/shared_device/domain/parent_gate_service.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void main() {
  group('ParentGateService', () {
    late InMemoryLocalMetadataStore store;
    late ParentGateService service;

    setUp(() {
      store = InMemoryLocalMetadataStore();
      service = ParentGateService(store);
    });

    test('no PIN configured fails closed: reject all PIN attempts', () async {
      expect(await service.hasConfiguredPin(), isFalse);
      expect(await service.hasCustomPin(), isFalse);
      // Fails closed: 1234 or any other PIN must NOT unlock
      expect(await service.verifyPin('1234'), isFalse);
      expect(await service.verifyPin('8392'), isFalse);
      expect(await service.verifyPin('0000'), isFalse);
    });

    test('sets custom 4-digit PIN, hashes it with salt, never persists plaintext, and verifies', () async {
      await service.setPin('8392');

      expect(await service.hasConfiguredPin(), isTrue);

      // Verify that plaintext PIN 8392 is NEVER stored in metadata
      final storedHash = await store.readMetadata(ParentGateService.pinHashKey);
      final storedSalt = await store.readMetadata(ParentGateService.pinSaltKey);

      expect(storedHash, isNotNull);
      expect(storedSalt, isNotNull);
      expect(storedHash, isNot(contains('8392')));
      expect(storedSalt, isNot(contains('8392')));
      expect(storedHash!.length, equals(64)); // SHA-256 hex length

      // Exit with 1234 must FAIL
      expect(await service.verifyPin('1234'), isFalse);
      // Exit with 8392 must PASS
      expect(await service.verifyPin('8392'), isTrue);

      // App restart simulation: new service using same store
      final restartedService = ParentGateService(store);
      expect(await restartedService.hasConfiguredPin(), isTrue);
      expect(await restartedService.verifyPin('1234'), isFalse);
      expect(await restartedService.verifyPin('8392'), isTrue);
    });

    test('rejects PINs that are not exactly 4 digits', () async {
      expect(() => service.setPin('123'), throwsArgumentError);
      expect(() => service.setPin('12345'), throwsArgumentError);
      expect(() => service.setPin('abcd'), throwsArgumentError);
    });
  });
}
