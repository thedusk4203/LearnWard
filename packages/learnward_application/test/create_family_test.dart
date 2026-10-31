import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  group('CreateFamily and ListMyFamilies', () {
    test(
      'creates family atomically and lists families for active member',
      () async {
        final fakeRepo = FakeFamilyRepository(currentUserId: 'parent-1');
        final createFamily = CreateFamily(fakeRepo);
        final listFamilies = ListMyFamilies(fakeRepo);

        final family = await createFamily(
          name: 'The Millers',
          timezone: 'UTC',
          locale: 'en_US',
        );

        expect(family.name, equals('The Millers'));
        expect(family.createdByUserId, equals('parent-1'));

        final list = await listFamilies();
        expect(list.length, equals(1));
        expect(list.first.id, equals(family.id));

        final membership = await fakeRepo.getMyMembership(family.id);
        expect(membership, isNotNull);
        expect(membership!.isOwner, isTrue);
      },
    );
  });
}
