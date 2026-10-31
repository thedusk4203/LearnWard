import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Family', () {
    test('creates a valid family and validates equality', () {
      final now = DateTime.utc(2026, 10, 31);
      final family1 = Family(
        id: FamilyId('fam-1'),
        name: 'The Smiths',
        timezone: 'UTC',
        locale: 'en_US',
        createdByUserId: 'user-1',
        createdAt: now,
      );
      final family2 = Family(
        id: FamilyId('fam-1'),
        name: 'The Smiths',
        timezone: 'UTC',
        locale: 'en_US',
        createdByUserId: 'user-1',
        createdAt: now,
      );

      expect(family1, equals(family2));
      expect(family1.isArchived, isFalse);
    });

    test('rejects empty or whitespace-only name', () {
      expect(
        () => Family(
          id: FamilyId('fam-1'),
          name: '   ',
          timezone: 'UTC',
          locale: 'en_US',
          createdByUserId: 'user-1',
          createdAt: DateTime.now(),
        ),
        throwsA(isA<InvalidFamilyException>()),
      );
    });

    test('rejects empty timezone or locale', () {
      expect(
        () => Family(
          id: FamilyId('fam-1'),
          name: 'The Smiths',
          timezone: '',
          locale: 'en_US',
          createdByUserId: 'user-1',
          createdAt: DateTime.now(),
        ),
        throwsA(isA<InvalidFamilyException>()),
      );
      expect(
        () => Family(
          id: FamilyId('fam-1'),
          name: 'The Smiths',
          timezone: 'UTC',
          locale: '',
          createdByUserId: 'user-1',
          createdAt: DateTime.now(),
        ),
        throwsA(isA<InvalidFamilyException>()),
      );
    });
  });

  group('FamilyMembership', () {
    test('resolves active and role properties correctly', () {
      final now = DateTime.utc(2026, 10, 31);
      final owner = FamilyMembership(
        familyId: FamilyId('fam-1'),
        authUserId: 'user-1',
        role: FamilyRole.owner,
        status: MembershipStatus.active,
        joinedAt: now,
      );
      expect(owner.isActive, isTrue);
      expect(owner.isOwner, isTrue);
      expect(owner.isParent, isTrue);

      final revokedParent = FamilyMembership(
        familyId: FamilyId('fam-1'),
        authUserId: 'user-2',
        role: FamilyRole.parent,
        status: MembershipStatus.revoked,
        joinedAt: now,
        revokedAt: now,
      );
      expect(revokedParent.isActive, isFalse);
      expect(revokedParent.isParent, isFalse);
    });
  });
}
