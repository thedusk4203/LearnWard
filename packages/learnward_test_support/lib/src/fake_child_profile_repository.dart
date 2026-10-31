import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// In-memory fake implementation of [ChildProfileRepository] for deterministic testing.
final class FakeChildProfileRepository implements ChildProfileRepository {
  FakeChildProfileRepository({List<ChildProfile>? children})
    : children = children ?? [];

  final List<ChildProfile> children;
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
      id: ChildId('fake-child-${_nextId++}'),
      familyId: familyId,
      displayName: displayName,
      schoolGrade: schoolGrade,
      birthYear: birthYear,
      avatarKey: avatarKey,
      createdAt: DateTime.now().toUtc(),
    );
    children.add(child);
    return child;
  }

  @override
  Future<List<ChildProfile>> listChildren(FamilyId familyId) async {
    return children.where((c) => c.familyId == familyId).toList();
  }

  @override
  Future<void> archiveChildProfile({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    final index = children.indexWhere(
      (c) => c.familyId == familyId && c.id == childId,
    );
    if (index != -1) {
      final existing = children[index];
      children[index] = ChildProfile(
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
