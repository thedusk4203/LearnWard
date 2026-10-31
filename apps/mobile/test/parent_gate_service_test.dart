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

    test('accepts default PIN 1234 before custom PIN is configured', () async {
      expect(await service.hasCustomPin(), isFalse);
      expect(await service.verifyPin('1234'), isTrue);
      expect(await service.verifyPin('0000'), isFalse);
      expect(await service.verifyPin('9999'), isFalse);
    });

    test(
      'sets custom 4-digit PIN, hashes it with salt, and verifies correctly',
      () async {
        await service.setPin('8392');

        expect(await service.hasCustomPin(), isTrue);
        expect(await service.verifyPin('8392'), isTrue);
        expect(await service.verifyPin('1234'), isFalse);
        expect(await service.verifyPin('0000'), isFalse);

        // Verify that plaintext PIN is NEVER stored in database
        final storedHash = await store.readMetadata('parent_gate_pin_hash');
        final storedSalt = await store.readMetadata('parent_gate_pin_salt');

        expect(storedHash, isNotNull);
        expect(storedSalt, isNotNull);
        expect(storedHash, isNot(contains('8392')));
        expect(storedHash!.length, equals(64)); // SHA-256 hex length
      },
    );

    test('rejects PINs that are not exactly 4 digits', () async {
      expect(() => service.setPin('123'), throwsArgumentError);
      expect(() => service.setPin('12345'), throwsArgumentError);
      expect(() => service.setPin('abcd'), throwsArgumentError);
    });
  });
}
