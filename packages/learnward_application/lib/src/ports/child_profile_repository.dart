import 'package:learnward_domain/learnward_domain.dart';

/// Repository port for child profile management.
abstract interface class ChildProfileRepository {
  /// Creates a child profile under a family.
  ///
  /// Notice: child profile creation does NOT create an auth user or require
  /// email/phone/password credentials.
  Future<ChildProfile> createChildProfile({
    required FamilyId familyId,
    required String displayName,
    int? schoolGrade,
    int? birthYear,
    String? avatarKey,
  });

  /// Lists all active and archived child profiles for an authorized family.
  Future<List<ChildProfile>> listChildren(FamilyId familyId);

  /// Archives a child profile.
  Future<void> archiveChildProfile({
    required FamilyId familyId,
    required ChildId childId,
  });
}
