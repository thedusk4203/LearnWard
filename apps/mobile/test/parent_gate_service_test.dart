import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/features/shared_device/domain/parent_gate_service.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void main() {
  const familyId = 'fam-service-test';
  const actorId = 'actor-service-test';
  const testFence = ParentGateOperationFence(
    actorUserId: actorId,
    sessionGeneration: 1,
    containmentEpoch: 1,
    expectedContainmentStatus: 'parent_mode',
    verifiedFamilyId: familyId,
  );

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
      expect(
        await service.verifyPin(
          '1234',
          actorFamilyId: familyId,
          actorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        isFalse,
      );
      expect(
        await service.verifyPin(
          '8392',
          actorFamilyId: familyId,
          actorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        isFalse,
      );
      expect(await service.verifyPin('0000'), isFalse);
    });

    test('sets owned 4-digit PIN, hashes it with PBKDF2 + salt, never persists plaintext, and verifies only when authorized', () async {
      // Bare unowned setPin rejects cleanly (R39-04)
      await expectLater(
        () => service.setPin('8392'),
        throwsA(isA<ParentGateFencedOperationException>()),
      );
      expect(
        await store.readMetadata(ParentGateService.credentialV2Key),
        isNull,
      );

      await service.setPin(
        '8392',
        ownerFamilyId: familyId,
        configuredByActorUserId: actorId,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: const [familyId],
        fence: testFence,
      );

      expect(await service.hasConfiguredPin(), isTrue);

      // Verify that plaintext PIN 8392 is NEVER stored in metadata and v2 payload is used
      final rawV2 = await store.readMetadata(ParentGateService.credentialV2Key);
      final parsedV2 = ParentGateCredentialV2.tryParse(rawV2);
      expect(parsedV2, isNotNull);
      expect(parsedV2!.kdf, equals('pbkdf2-hmac-sha256'));
      expect(parsedV2.iterations, greaterThanOrEqualTo(100000));
      expect(parsedV2.ownerFamilyId, equals(familyId));
      expect(parsedV2.configuredByActorUserId, equals(actorId));
      expect(parsedV2.hashHex.length, equals(64));
      expect(parsedV2.saltHex.length, equals(32));
      expect(rawV2, isNot(contains('8392')));

      expect(await store.readMetadata(ParentGateService.pinHashKey), isNull);
      expect(await store.readMetadata(ParentGateService.pinSaltKey), isNull);

      // Unfenced/unauthenticated verifyPin rejects authorization (R39-05)
      expect(await service.verifyPin('8392'), isFalse);

      // Exit with wrong PIN 1234 must FAIL
      expect(
        await service.verifyPin(
          '1234',
          actorFamilyId: familyId,
          actorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        isFalse,
      );
      // Exit with 8392 and valid authorization must PASS
      expect(
        await service.verifyPin(
          '8392',
          actorFamilyId: familyId,
          actorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        isTrue,
      );

      // App restart simulation: new service using same store
      final restartedService = ParentGateService(store);
      expect(await restartedService.hasConfiguredPin(), isTrue);
      expect(
        await restartedService.verifyPin(
          '1234',
          actorFamilyId: familyId,
          actorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        isFalse,
      );
      expect(
        await restartedService.verifyPin(
          '8392',
          actorFamilyId: familyId,
          actorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        isTrue,
      );
    });

    test('rejects PINs that are not exactly 4 digits', () async {
      expect(
        () => service.setPin(
          '123',
          ownerFamilyId: familyId,
          configuredByActorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        throwsArgumentError,
      );
      expect(
        () => service.setPin(
          '12345',
          ownerFamilyId: familyId,
          configuredByActorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        throwsArgumentError,
      );
      expect(
        () => service.setPin(
          'abcd',
          ownerFamilyId: familyId,
          configuredByActorUserId: actorId,
          hasPositiveServerAdultVerification: true,
          verifiedActiveAdultFamilyIds: const [familyId],
          fence: testFence,
        ),
        throwsArgumentError,
      );
    });
  });
}
