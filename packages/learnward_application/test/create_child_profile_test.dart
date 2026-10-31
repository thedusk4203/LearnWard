import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  group('CreateChildProfile, ListFamilyChildren and ArchiveChildProfile', () {
    test('creates child profile under family without auth account', () async {
      final fakeRepo = FakeChildProfileRepository();
      final createChild = CreateChildProfile(fakeRepo);
      final listChildren = ListFamilyChildren(fakeRepo);
      final archiveChild = ArchiveChildProfile(fakeRepo);

      final familyId = FamilyId('fam-alpha');
      final child = await createChild(
        familyId: familyId,
        displayName: 'Maya',
        schoolGrade: 5,
        birthYear: 2015,
      );

      expect(child.displayName, equals('Maya'));
      expect(child.schoolGrade, equals(5));

      final children = await listChildren(familyId);
      expect(children.length, equals(1));
      expect(children.first.displayName, equals('Maya'));

      await archiveChild(familyId: familyId, childId: child.id);
      final updatedList = await listChildren(familyId);
      expect(updatedList.first.isArchived, isTrue);
    });
  });
}
