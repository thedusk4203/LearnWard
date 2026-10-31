import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('ChildProfile', () {
    test('creates a valid child profile without requiring email, phone or password', () {
      final now = DateTime.utc(2026, 10, 31);
      final child = ChildProfile(
        id: ChildId('child-1'),
        familyId: FamilyId('fam-1'),
        displayName: 'Leo',
        schoolGrade: 6,
        birthYear: 2014,
        createdAt: now,
      );

      expect(child.displayName, equals('Leo'));
      expect(child.schoolGrade, equals(6));
      expect(child.isActive, isTrue);
      expect(child.isArchived, isFalse);
    });

    test('rejects empty child display name', () {
      expect(
        () => ChildProfile(
          id: ChildId('child-1'),
          familyId: FamilyId('fam-1'),
          displayName: '  ',
          createdAt: DateTime.now(),
        ),
        throwsA(isA<InvalidChildProfileException>()),
      );
    });

    test('rejects invalid school grade', () {
      expect(
        () => ChildProfile(
          id: ChildId('child-1'),
          familyId: FamilyId('fam-1'),
          displayName: 'Leo',
          schoolGrade: 15,
          createdAt: DateTime.now(),
        ),
        throwsA(isA<InvalidChildProfileException>()),
      );
    });

    test('rejects implausible birth year', () {
      expect(
        () => ChildProfile(
          id: ChildId('child-1'),
          familyId: FamilyId('fam-1'),
          displayName: 'Leo',
          birthYear: 1850,
          createdAt: DateTime.now(),
        ),
        throwsA(isA<InvalidChildProfileException>()),
      );
    });
  });
}
