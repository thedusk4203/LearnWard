import '../exceptions/domain_exceptions.dart';
import '../value_objects/identifiers.dart';

/// Status of a child profile.
enum ChildProfileStatus {
  active('active'),
  archived('archived');

  const ChildProfileStatus(this.wireName);
  final String wireName;

  static ChildProfileStatus parse(String value) {
    for (final status in values) {
      if (status.wireName == value) return status;
    }
    throw InvalidChildProfileException('Unknown child profile status: $value');
  }
}

/// A family-owned child profile.
///
/// Notice: a child profile is NOT an auth.users identity and does NOT require
/// an email, phone number or password.
final class ChildProfile {
  ChildProfile({
    required this.id,
    required this.familyId,
    required this.displayName,
    this.schoolGrade,
    this.birthYear,
    this.avatarKey,
    this.status = ChildProfileStatus.active,
    required this.createdAt,
    this.archivedAt,
  }) {
    final trimmedName = displayName.trim();
    if (trimmedName.isEmpty) {
      throw const InvalidChildProfileException(
        'Child display name cannot be empty.',
      );
    }
    if (trimmedName.length > 50) {
      throw const InvalidChildProfileException(
        'Child display name exceeds 50 characters.',
      );
    }
    if (schoolGrade != null && (schoolGrade! < 1 || schoolGrade! > 12)) {
      throw const InvalidChildProfileException(
        'School grade must be between 1 and 12.',
      );
    }
    if (birthYear != null && (birthYear! < 1990 || birthYear! > 2035)) {
      throw const InvalidChildProfileException(
        'Birth year must be a plausible year.',
      );
    }
  }

  final ChildId id;
  final FamilyId familyId;
  final String displayName;
  final int? schoolGrade;
  final int? birthYear;
  final String? avatarKey;
  final ChildProfileStatus status;
  final DateTime createdAt;
  final DateTime? archivedAt;

  bool get isActive => status == ChildProfileStatus.active;
  bool get isArchived =>
      archivedAt != null || status == ChildProfileStatus.archived;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChildProfile &&
          other.id == id &&
          other.familyId == familyId &&
          other.displayName == displayName &&
          other.schoolGrade == schoolGrade &&
          other.birthYear == birthYear &&
          other.avatarKey == avatarKey &&
          other.status == status &&
          other.createdAt == createdAt &&
          other.archivedAt == archivedAt;

  @override
  int get hashCode => Object.hash(
    id,
    familyId,
    displayName,
    schoolGrade,
    birthYear,
    avatarKey,
    status,
    createdAt,
    archivedAt,
  );
}
