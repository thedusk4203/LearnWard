import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Supabase Repository Data Mapping', () {
    test('SupabaseFamilyRepository maps JSON rows to domain Family entity', () {
      final Map<String, dynamic> familyJson = {
        'id': '00000000-0000-0000-0000-000000000001',
        'name': 'The Jackson Family',
        'timezone': 'America/New_York',
        'locale': 'en_US',
        'created_by_user_id': '11111111-1111-1111-1111-111111111111',
        'created_at': '2026-10-31T12:00:00Z',
        'archived_at': null,
      };

      final family = Family(
        id: FamilyId(familyJson['id'] as String),
        name: familyJson['name'] as String,
        timezone: familyJson['timezone'] as String,
        locale: familyJson['locale'] as String,
        createdByUserId: familyJson['created_by_user_id'] as String,
        createdAt: DateTime.parse(familyJson['created_at'] as String),
      );

      expect(family.name, equals('The Jackson Family'));
      expect(family.timezone, equals('America/New_York'));
      expect(
        family.createdByUserId,
        equals('11111111-1111-1111-1111-111111111111'),
      );
      expect(family.isArchived, isFalse);
    });

    test('ChildProfile maps JSON rows to domain ChildProfile entity', () {
      final Map<String, dynamic> childJson = {
        'id': '22222222-2222-2222-2222-222222222222',
        'family_id': '00000000-0000-0000-0000-000000000001',
        'display_name': 'Sophie',
        'school_grade': 7,
        'birth_year': 2013,
        'avatar_key': 'avatar_cat',
        'status': 'active',
        'created_at': '2026-10-31T12:00:00Z',
        'archived_at': null,
      };

      final child = ChildProfile(
        id: ChildId(childJson['id'] as String),
        familyId: FamilyId(childJson['family_id'] as String),
        displayName: childJson['display_name'] as String,
        schoolGrade: childJson['school_grade'] as int?,
        birthYear: childJson['birth_year'] as int?,
        avatarKey: childJson['avatar_key'] as String?,
        status: ChildProfileStatus.parse(childJson['status'] as String),
        createdAt: DateTime.parse(childJson['created_at'] as String),
      );

      expect(child.displayName, equals('Sophie'));
      expect(child.schoolGrade, equals(7));
      expect(child.avatarKey, equals('avatar_cat'));
      expect(child.isActive, isTrue);
    });
  });
}
