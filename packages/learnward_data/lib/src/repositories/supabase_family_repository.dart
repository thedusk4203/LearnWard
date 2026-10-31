import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase implementation of [FamilyRepository].
///
/// Encapsulates all table and RPC interactions for families and memberships.
final class SupabaseFamilyRepository implements FamilyRepository {
  SupabaseFamilyRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Family> createFamily({
    required String name,
    required String timezone,
    required String locale,
  }) async {
    // Uses the atomic database function to guarantee owner membership creation
    // alongside family insertion in a single database transaction.
    final response = await _client.rpc<dynamic>(
      'create_family',
      params: {'p_name': name, 'p_timezone': timezone, 'p_locale': locale},
    );

    final map = Map<String, dynamic>.from(response as Map);
    return _mapFamily(map);
  }

  @override
  Future<List<Family>> listMyFamilies() async {
    final response = await _client
        .from('families')
        .select()
        .order('created_at', ascending: false);

    final list = response as List<dynamic>;
    return list
        .map((row) => _mapFamily(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  @override
  Future<FamilyMembership?> getMyMembership(FamilyId familyId) async {
    final currentUserId = _client.auth.currentUser?.id;
    if (currentUserId == null) return null;

    final response = await _client
        .from('family_memberships')
        .select()
        .eq('family_id', familyId.value)
        .eq('auth_user_id', currentUserId)
        .maybeSingle();

    if (response == null) return null;
    return _mapMembership(Map<String, dynamic>.from(response));
  }

  static Family _mapFamily(Map<String, dynamic> row) {
    return Family(
      id: FamilyId(row['id'] as String),
      name: row['name'] as String,
      timezone: row['timezone'] as String,
      locale: row['locale'] as String,
      createdByUserId: row['created_by_user_id'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      archivedAt: row['archived_at'] != null
          ? DateTime.parse(row['archived_at'] as String)
          : null,
    );
  }

  static FamilyMembership _mapMembership(Map<String, dynamic> row) {
    return FamilyMembership(
      familyId: FamilyId(row['family_id'] as String),
      authUserId: row['auth_user_id'] as String,
      role: FamilyRole.parse(row['role'] as String),
      status: MembershipStatus.parse(row['status'] as String),
      joinedAt: DateTime.parse(row['joined_at'] as String),
      revokedAt: row['revoked_at'] != null
          ? DateTime.parse(row['revoked_at'] as String)
          : null,
    );
  }
}
