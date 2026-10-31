import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Lightweight in-memory fallback for [FamilyRepository] when Supabase
/// credentials are not configured in local development.
final class InMemoryFamilyRepository implements FamilyRepository {
  final Map<String, Family> _families = {};
  final Map<String, FamilyMembership> _memberships = {};

  @override
  Future<Family> createFamily({
    required String name,
    required String timezone,
    required String locale,
  }) async {
    final id = 'local-fam-${DateTime.now().millisecondsSinceEpoch}';
    final family = Family(
      id: FamilyId(id),
      name: name,
      timezone: timezone,
      locale: locale,
      createdByUserId: 'local-parent-user',
      createdAt: DateTime.now().toUtc(),
    );
    _families[id] = family;
    _memberships[id] = FamilyMembership(
      familyId: family.id,
      authUserId: 'local-parent-user',
      role: FamilyRole.owner,
      status: MembershipStatus.active,
      joinedAt: DateTime.now().toUtc(),
    );
    return family;
  }

  @override
  Future<List<Family>> listMyFamilies() async {
    return _families.values.toList();
  }

  @override
  Future<FamilyMembership?> getMyMembership(FamilyId familyId) async {
    return _memberships[familyId.value];
  }
}

/// Lightweight in-memory fallback for [ChildProfileRepository] when Supabase
/// credentials are not configured in local development.
final class InMemoryChildProfileRepository implements ChildProfileRepository {
  final List<ChildProfile> _children = [];
  int _nextId = 1;

  @override
  Future<ChildProfile> createChildProfile({
    required FamilyId familyId,
    required String displayName,
    int? schoolGrade,
    int? birthYear,
    String? avatarKey,
  }) async {
    final child = ChildProfile(
      id: ChildId('local-child-${_nextId++}'),
      familyId: familyId,
      displayName: displayName,
      schoolGrade: schoolGrade,
      birthYear: birthYear,
      avatarKey: avatarKey,
      status: ChildProfileStatus.active,
      createdAt: DateTime.now().toUtc(),
    );
    _children.add(child);
    return child;
  }

  @override
  Future<List<ChildProfile>> listChildren(FamilyId familyId) async {
    return _children
        .where(
          (c) =>
              c.familyId == familyId && c.status == ChildProfileStatus.active,
        )
        .toList();
  }

  @override
  Future<void> archiveChildProfile({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    final index = _children.indexWhere(
      (c) => c.familyId == familyId && c.id == childId,
    );
    if (index != -1) {
      final existing = _children[index];
      _children[index] = ChildProfile(
        id: existing.id,
        familyId: existing.familyId,
        displayName: existing.displayName,
        schoolGrade: existing.schoolGrade,
        birthYear: existing.birthYear,
        avatarKey: existing.avatarKey,
        status: ChildProfileStatus.archived,
        createdAt: existing.createdAt,
        archivedAt: DateTime.now().toUtc(),
      );
    }
  }
}
