import '../exceptions/domain_exceptions.dart';
import '../value_objects/identifiers.dart';

/// Role of an adult within a family.
enum FamilyRole {
  owner('owner'),
  parent('parent');

  const FamilyRole(this.wireName);
  final String wireName;

  static FamilyRole parse(String value) {
    for (final role in values) {
      if (role.wireName == value) return role;
    }
    throw InvalidFamilyException('Unknown family role: $value');
  }
}

/// Status of an adult's membership in a family.
enum MembershipStatus {
  active('active'),
  invited('invited'),
  revoked('revoked');

  const MembershipStatus(this.wireName);
  final String wireName;

  static MembershipStatus parse(String value) {
    for (final status in values) {
      if (status.wireName == value) return status;
    }
    throw InvalidFamilyException('Unknown membership status: $value');
  }
}

/// A household account that defines the tenancy and security boundary.
final class Family {
  Family({
    required this.id,
    required this.name,
    required this.timezone,
    required this.locale,
    required this.createdByUserId,
    required this.createdAt,
    this.archivedAt,
  }) {
    if (name.trim().isEmpty) {
      throw const InvalidFamilyException('Family name cannot be empty.');
    }
    if (name.length > 100) {
      throw const InvalidFamilyException('Family name exceeds 100 characters.');
    }
    if (timezone.trim().isEmpty) {
      throw const InvalidFamilyException('Family timezone cannot be empty.');
    }
    if (locale.trim().isEmpty) {
      throw const InvalidFamilyException('Family locale cannot be empty.');
    }
    if (createdByUserId.trim().isEmpty) {
      throw const InvalidFamilyException('Creator user id cannot be empty.');
    }
  }

  final FamilyId id;
  final String name;
  final String timezone;
  final String locale;
  final String createdByUserId;
  final DateTime createdAt;
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Family &&
          other.id == id &&
          other.name == name &&
          other.timezone == timezone &&
          other.locale == locale &&
          other.createdByUserId == createdByUserId &&
          other.createdAt == createdAt &&
          other.archivedAt == archivedAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    timezone,
    locale,
    createdByUserId,
    createdAt,
    archivedAt,
  );
}

/// Association between an authenticated adult identity and a family.
final class FamilyMembership {
  FamilyMembership({
    required this.familyId,
    required this.authUserId,
    required this.role,
    required this.status,
    required this.joinedAt,
    this.revokedAt,
  }) {
    if (authUserId.trim().isEmpty) {
      throw const InvalidFamilyException('Auth user id cannot be empty.');
    }
  }

  final FamilyId familyId;
  final String authUserId;
  final FamilyRole role;
  final MembershipStatus status;
  final DateTime joinedAt;
  final DateTime? revokedAt;

  bool get isActive => status == MembershipStatus.active;
  bool get isOwner => role == FamilyRole.owner && isActive;
  bool get isParent =>
      (role == FamilyRole.owner || role == FamilyRole.parent) && isActive;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FamilyMembership &&
          other.familyId == familyId &&
          other.authUserId == authUserId &&
          other.role == role &&
          other.status == status &&
          other.joinedAt == joinedAt &&
          other.revokedAt == revokedAt;

  @override
  int get hashCode =>
      Object.hash(familyId, authUserId, role, status, joinedAt, revokedAt);
}
