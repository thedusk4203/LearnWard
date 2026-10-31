import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase implementation of [ChildProfileRepository].
///
/// Encapsulates all interactions with the `child_profiles` table.
final class SupabaseChildProfileRepository implements ChildProfileRepository {
  SupabaseChildProfileRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<ChildProfile> createChildProfile({
    required FamilyId familyId,
    required String displayName,
    int? schoolGrade,
    int? birthYear,
    String? avatarKey,
  }) async {
    final response = await _client
        .from('child_profiles')
        .insert({
          'family_id': familyId.value,
          'display_name': displayName,
          'school_grade': schoolGrade,
          'birth_year': birthYear,
          'avatar_key': avatarKey,
          'status': 'active',
        })
        .select()
        .single();

    return _mapChildProfile(Map<String, dynamic>.from(response));
  }

  @override
  Future<List<ChildProfile>> listChildren(FamilyId familyId) async {
    final response = await _client
        .from('child_profiles')
        .select()
        .eq('family_id', familyId.value)
        .order('created_at', ascending: true);

    final list = response as List<dynamic>;
    return list
        .map((row) => _mapChildProfile(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  @override
  Future<void> archiveChildProfile({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    await _client
        .from('child_profiles')
        .update({
          'status': 'archived',
          'archived_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('family_id', familyId.value)
        .eq('id', childId.value);
  }

  static ChildProfile _mapChildProfile(Map<String, dynamic> row) {
    return ChildProfile(
      id: ChildId(row['id'] as String),
      familyId: FamilyId(row['family_id'] as String),
      displayName: row['display_name'] as String,
      schoolGrade: row['school_grade'] as int?,
      birthYear: row['birth_year'] as int?,
      avatarKey: row['avatar_key'] as String?,
      status: ChildProfileStatus.parse(row['status'] as String),
      createdAt: DateTime.parse(row['created_at'] as String),
      archivedAt: row['archived_at'] != null
          ? DateTime.parse(row['archived_at'] as String)
          : null,
    );
  }
}
