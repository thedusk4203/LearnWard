import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase implementation of [WheelRepository] interacting with
/// `family_wheel_settings`, `wheel_spins`, `rewards` and the `spin_reward_wheel` RPC.
final class SupabaseWheelRepository implements WheelRepository {
  SupabaseWheelRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<WheelSettings> getWheelSettings({required FamilyId familyId}) async {
    final row = await _client
        .from('family_wheel_settings')
        .select()
        .eq('family_id', familyId.value)
        .maybeSingle();

    if (row == null) {
      final now = DateTime.now().toUtc();
      return WheelSettings(familyId: familyId, createdAt: now, updatedAt: now);
    }

    return WheelSettings.fromJson(Map<String, dynamic>.from(row));
  }

  @override
  Future<WheelSettings> updateWheelSettings(WheelSettings settings) async {
    final row = await _client
        .from('family_wheel_settings')
        .update({
          'spin_cost_minor': settings.spinCostMinor,
          'daily_spin_cap': settings.dailySpinCap,
          'is_enabled': settings.isEnabled,
        })
        .eq('family_id', settings.familyId.value)
        .select()
        .single();

    return WheelSettings.fromJson(Map<String, dynamic>.from(row));
  }

  @override
  Future<List<Reward>> listWheelRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) async {
    final rows = await _client
        .from('rewards')
        .select()
        .eq('family_id', familyId.value)
        .eq('is_active', true)
        .eq('wheel_enabled', true)
        .order('id', ascending: true);

    final list = (rows as List<dynamic>)
        .map((r) => _mapReward(Map<String, dynamic>.from(r as Map)))
        .toList();

    if (childId != null) {
      return list.where((r) => r.isEligibleFor(childId)).toList();
    }
    return list;
  }

  @override
  Future<WheelSpinResult> spinRewardWheel({
    required String commandId,
    required ChildId childId,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'spin_reward_wheel',
      params: {'p_command_id': commandId, 'p_child_id': childId.value},
    );

    return WheelSpinResult.fromJson(response);
  }

  @override
  Future<List<WheelSpin>> listWheelSpins({
    required FamilyId familyId,
    ChildId? childId,
    int? limit,
  }) async {
    var query = _client
        .from('wheel_spins')
        .select()
        .eq('family_id', familyId.value);

    if (childId != null) {
      query = query.eq('child_id', childId.value);
    }

    final ordered = query.order('created_at', ascending: false);
    final finalQuery = limit != null ? ordered.limit(limit) : ordered;
    final rows = await finalQuery;

    return (rows as List<dynamic>)
        .map((r) => WheelSpin.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  @override
  Future<int> getTodaySpinCount({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    final rows = await _client
        .from('wheel_spins')
        .select('id, created_at')
        .eq('family_id', familyId.value)
        .eq('child_id', childId.value);

    final spins = rows as List<dynamic>;
    if (spins.isEmpty) return 0;

    // Filter in UTC / local representation
    final now = DateTime.now().toUtc();
    final todayUtcDate = DateTime.utc(now.year, now.month, now.day);
    final tomorrowUtcDate = todayUtcDate.add(const Duration(days: 1));

    return spins.where((s) {
      final map = s as Map<String, dynamic>;
      final createdAt = DateTime.parse(map['created_at'] as String);
      return createdAt.isAfter(
            todayUtcDate.subtract(const Duration(milliseconds: 1)),
          ) &&
          createdAt.isBefore(tomorrowUtcDate);
    }).length;
  }

  Reward _mapReward(Map<String, dynamic> row) {
    return Reward(
      id: RewardId(row['id'] as String),
      familyId: FamilyId(row['family_id'] as String),
      title: row['title'] as String,
      description: row['description'] as String?,
      category: RewardCategory.fromString(row['category'] as String),
      iconKey: row['icon_key'] as String? ?? 'default_star',
      storeEnabled: row['store_enabled'] as bool? ?? true,
      storeCostMinor: row['store_cost_minor'] as int?,
      wheelEnabled: row['wheel_enabled'] as bool? ?? false,
      wheelTier: row['wheel_tier'] != null
          ? WheelTier.fromString(row['wheel_tier'] as String)
          : null,
      targetChildId: row['target_child_id'] != null
          ? ChildId(row['target_child_id'] as String)
          : null,
      isActive: row['is_active'] as bool? ?? true,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}
