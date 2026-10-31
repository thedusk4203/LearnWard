import 'package:learnward_domain/learnward_domain.dart';

/// Repository port for family operations.
///
/// Implementations must enforce atomicity and security invariants in the
/// infrastructure layer. Application use cases depend only on this abstraction.
abstract interface class FamilyRepository {
  /// Atomically creates a family and registers the current authenticated adult
  /// as the active owner.
  Future<Family> createFamily({
    required String name,
    required String timezone,
    required String locale,
  });

  /// Lists all families in which the current user holds an active adult
  /// membership.
  Future<List<Family>> listMyFamilies();

  /// Retrieves the current user's membership for a specific family, or `null`.
  Future<FamilyMembership?> getMyMembership(FamilyId familyId);
}
