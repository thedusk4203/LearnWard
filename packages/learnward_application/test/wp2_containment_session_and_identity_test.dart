import 'dart:convert';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  final nowUtc = DateTime.utc(2026, 11, 25, 12, 0);
  final sampleFamilyId = FamilyId('fam-1');
  final sampleChild = ChildProfile(
    id: ChildId('child-1'),
    familyId: sampleFamilyId,
    displayName: 'Mia Secret Name',
    schoolGrade: 4,
    birthYear: 2016,
    avatarKey: 'avatar-owl',
    createdAt: nowUtc,
  );

  group('ValidatedActorContext isAnonymous propagation', () {
    test('defaults isAnonymous to false for backward compatibility', () {
      final ctx = ValidatedActorContext(
        userId: 'actor-1',
        sessionGeneration: 'gen-1',
        observedAt: nowUtc,
        role: 'owner',
      );
      expect(ctx.isAnonymous, isFalse);
      expect(ctx.role, 'owner');
    });

    test('supports explicit isAnonymous in equality and hashCode', () {
      final nonAnon = ValidatedActorContext(
        userId: 'actor-1',
        sessionGeneration: 'gen-1',
        observedAt: nowUtc,
      );
      final anon = ValidatedActorContext(
        userId: 'actor-1',
        sessionGeneration: 'gen-1',
        observedAt: nowUtc,
        isAnonymous: true,
      );
      expect(anon.isAnonymous, isTrue);
      expect(nonAnon, isNot(equals(anon)));
      expect(nonAnon.toString(), contains('isAnonymous: false'));
      expect(anon.toString(), contains('isAnonymous: true'));
    });
  });

  group('PersistedChildModeSession v2 strict parser', () {
    test('classifies null, empty, and whitespace as absent', () {
      expect(
        PersistedChildModeSession.tryParse(null),
        isA<AbsentPersistedChildModeSession>(),
      );
      expect(
        PersistedChildModeSession.tryParse(''),
        isA<AbsentPersistedChildModeSession>(),
      );
      expect(
        PersistedChildModeSession.tryParse('   \n  '),
        isA<AbsentPersistedChildModeSession>(),
      );
    });

    test('round-trips valid v2 envelopes and redacts PII in toString', () {
      for (final mode in PersistedChildModeKind.values) {
        final session = PersistedChildModeSession(
          modeKind: mode,
          actorUserId: 'actor-1',
          familyId: sampleFamilyId,
          childId: sampleChild.id,
          childProfileSnapshot: sampleChild,
          persistedAtUtc: nowUtc,
        );
        final raw = session.toJsonString();
        final parsed = PersistedChildModeSession.tryParse(raw);
        expect(parsed, isA<ValidPersistedChildModeSessionV2>());
        final valid = parsed as ValidPersistedChildModeSessionV2;
        expect(valid.session, equals(session));
        expect(valid.session.childProfileSnapshot.avatarKey, 'avatar-owl');
        expect(valid.toString(), isNot(contains('Mia Secret Name')));
        expect(session.toString(), isNot(contains('Mia Secret Name')));
      }
    });

    test('classifies Phase 1 legacy v1 JSON as legacyV1OrMalformed with unverified hint only', () {
      final legacyJson = jsonEncode({
        'id': 'child-legacy-1',
        'family_id': 'fam-legacy-1',
        'display_name': 'Hidden Legacy Child',
        'status': 'active',
        'created_at': '2026-10-31T00:00:00.000Z',
      });

      final parsed = PersistedChildModeSession.tryParse(legacyJson);
      expect(parsed, isA<LegacyV1OrMalformedChildModeSession>());
      final legacy = parsed as LegacyV1OrMalformedChildModeSession;
      expect(legacy.status, PersistedChildModeParseStatus.legacyV1OrMalformed);
      expect(legacy.isWellFormedLegacyV1, isTrue);
      expect(legacy.unverifiedLegacyHintFamilyId, 'fam-legacy-1');
      expect(legacy.unverifiedLegacyHintChildId, 'child-legacy-1');
      expect(legacy.toString(), isNot(contains('Hidden Legacy Child')));
      expect(legacy.toString(), isNot(contains('fam-legacy-1')));
    });

    test('fails closed as legacyV1OrMalformed for corrupt JSON, bad version, missing actor, or archived/mismatched snapshot', () {
      final validMap = PersistedChildModeSession(
        modeKind: PersistedChildModeKind.sharedDeviceAdult,
        actorUserId: 'actor-1',
        familyId: sampleFamilyId,
        childId: sampleChild.id,
        childProfileSnapshot: sampleChild,
        persistedAtUtc: nowUtc,
      ).toJson();

      final malformedInputs = <String>[
        '{corrupt-json',
        '["not-a-map"]',
        jsonEncode({...validMap, 'version': 1}),
        jsonEncode({...validMap, 'version': 3}),
        jsonEncode({...validMap, 'actorUserId': ''}),
        jsonEncode({...validMap, 'modeKind': 'unknown_mode'}),
        jsonEncode({...validMap, 'persistedAtUtc': 'not-a-date'}),
        jsonEncode({...validMap, 'childId': 'different-child'}),
        jsonEncode({...validMap, 'familyId': 'different-family'}),
        jsonEncode({
          ...validMap,
          'childProfileSnapshot': {
            ...(validMap['childProfileSnapshot'] as Map<String, dynamic>),
            'status': 'archived',
          },
        }),
        jsonEncode({
          ...validMap,
          'childProfileSnapshot': {
            ...(validMap['childProfileSnapshot'] as Map<String, dynamic>),
            'archived_at': nowUtc.toIso8601String(),
          },
        }),
      ];

      for (final input in malformedInputs) {
        final parsed = PersistedChildModeSession.tryParse(input);
        expect(parsed, isA<LegacyV1OrMalformedChildModeSession>());
        final malformed = parsed as LegacyV1OrMalformedChildModeSession;
        expect(malformed.isWellFormedLegacyV1, isFalse);
        expect(malformed.unverifiedLegacyHintFamilyId, isNull);
        expect(malformed.unverifiedLegacyHintChildId, isNull);
      }
    });
  });

  group('ContainmentRecoveryLockV1 strict codec', () {
    test('round-trips bound, corroborated, and unresolvable locks', () {
      for (final reason in ContainmentRecoveryReason.values) {
        final bound = ContainmentRecoveryLockV1(
          reason: reason,
          ownershipLevel: ContainmentRecoveryOwnershipLevel.boundV2,
          requiredOwnerFamilyId: 'fam-owner',
          unverifiedLegacyHintFamilyId: 'fam-hint',
          originActorUserId: 'actor-origin',
          initiatedFromSessionGeneration: 'gen-actor-1',
          initiatedAtUtc: nowUtc,
        );
        expect(
          ContainmentRecoveryLockV1.tryParse(bound.toJsonString()),
          equals(bound),
        );
      }

      final unresolvable = ContainmentRecoveryLockV1(
        reason: ContainmentRecoveryReason.legacyOrMalformedSession,
        ownershipLevel: ContainmentRecoveryOwnershipLevel.unresolvable,
        unverifiedLegacyHintFamilyId: 'fam-untrusted-hint',
        initiatedFromSessionGeneration: 'gen-1',
        initiatedAtUtc: nowUtc,
      );
      final parsed = ContainmentRecoveryLockV1.parseStorageValue(
        unresolvable.toJsonString(),
      );
      expect(parsed, isA<ValidContainmentRecoveryLockV1>());
      expect((parsed as ValidContainmentRecoveryLockV1).lock, unresolvable);
    });

    test('distinguishes absent vs malformed locks and enforces ownership invariants', () {
      expect(
        ContainmentRecoveryLockV1.parseStorageValue(null),
        isA<AbsentContainmentRecoveryLock>(),
      );
      expect(
        ContainmentRecoveryLockV1.parseStorageValue('   '),
        isA<AbsentContainmentRecoveryLock>(),
      );

      final malformedPayloads = <String>[
        '{corrupt',
        jsonEncode({
          'version': 1,
          'reason': 'unlisted_reason',
          'ownershipLevel': 'bound_v2',
          'requiredOwnerFamilyId': 'fam-1',
          'initiatedFromSessionGeneration': 'gen-1',
          'initiatedAtUtc': nowUtc.toIso8601String(),
        }),
        jsonEncode({
          'version': 1,
          'reason': 'corrupt_pin',
          'ownershipLevel': 'unresolvable',
          'requiredOwnerFamilyId': 'fam-1', // Forbidden for unresolvable!
          'initiatedFromSessionGeneration': 'gen-1',
          'initiatedAtUtc': nowUtc.toIso8601String(),
        }),
        jsonEncode({
          'version': 1,
          'reason': 'corrupt_pin',
          'ownershipLevel': 'bound_v2',
          'requiredOwnerFamilyId': null, // Forbidden for bound_v2!
          'initiatedFromSessionGeneration': 'gen-1',
          'initiatedAtUtc': nowUtc.toIso8601String(),
        }),
        jsonEncode({
          'version': 1,
          'reason': 'corrupt_pin',
          'ownershipLevel': 'corroborated_legacy',
          'requiredOwnerFamilyId': '   ',
          'initiatedFromSessionGeneration': 'gen-1',
          'initiatedAtUtc': nowUtc.toIso8601String(),
        }),
        jsonEncode({
          'version': 1,
          'reason': 'corrupt_pin',
          'ownershipLevel': 'unresolvable',
          'initiatedFromSessionGeneration': '', // Must not be empty
          'initiatedAtUtc': nowUtc.toIso8601String(),
        }),
      ];

      for (final raw in malformedPayloads) {
        expect(ContainmentRecoveryLockV1.tryParse(raw), isNull);
        expect(
          ContainmentRecoveryLockV1.parseStorageValue(raw),
          isA<MalformedContainmentRecoveryLock>(),
        );
      }
    });
  });
}
