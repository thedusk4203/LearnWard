import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// In-memory fake implementation of [FamilyRepository] for deterministic testing.
final class FakeFamilyRepository implements FamilyRepository {
  FakeFamilyRepository({
    this.currentUserId = 'user-owner-1',
    List<Family>? families,
    List<FamilyMembership>? memberships,
  }) : families = families ?? [],
       memberships = memberships ?? [];

  String currentUserId;
  final List<Family> families;
  final List<FamilyMembership> memberships;

  int _nextId = 1;

  @override
  Future<Family> createFamily({
    required String name,
    required String timezone,
    required String locale,
  }) async {
    final family = Family(
      id: FamilyId('fake-fam-${_nextId++}'),
      name: name,
      timezone: timezone,
      locale: locale,
      createdByUserId: currentUserId,
      createdAt: DateTime.now().toUtc(),
    );
    families.add(family);

    memberships.add(
      FamilyMembership(
        familyId: family.id,
        authUserId: currentUserId,
        role: FamilyRole.owner,
        status: MembershipStatus.active,
        joinedAt: family.createdAt,
      ),
    );

    return family;
  }

  @override
  Future<List<Family>> listMyFamilies() async {
    final activeFamilyIds = memberships
        .where((m) => m.authUserId == currentUserId && m.isActive)
        .map((m) => m.familyId)
        .toSet();

    return families.where((f) => activeFamilyIds.contains(f.id)).toList();
  }

  @override
  Future<FamilyMembership?> getMyMembership(FamilyId familyId) async {
    return memberships
        .where((m) => m.familyId == familyId && m.authUserId == currentUserId)
        .firstOrNull;
  }
}
