import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase implementation of [GrowthRepository] interacting with server-authoritative
/// Growth Engine RPCs and ledgers.
final class SupabaseGrowthRepository implements GrowthRepository {
  SupabaseGrowthRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<GrowthEvent> processVerifiedLearningEvent({
    required String verifiedLearningEventId,
    String? commandId,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'process_verified_learning_event',
      params: {
        'p_verified_event_id': verifiedLearningEventId,
        'p_command_id': ?commandId,
      },
    );

    return _mapGrowthEvent(response);
  }

  @override
  Future<ChildBalance?> getChildBalance(ChildId childId) async {
    final row = await _client
        .from('child_balances')
        .select()
        .eq('child_id', childId.value)
        .maybeSingle();

    if (row == null) return null;
    return _mapChildBalance(Map<String, dynamic>.from(row));
  }

  @override
  Future<GrowthEvent?> getLatestGrowthEvent(ChildId childId) async {
    final row = await _client
        .from('growth_events')
        .select()
        .eq('child_id', childId.value)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (row == null) return null;
    return _mapGrowthEvent(Map<String, dynamic>.from(row));
  }

  @override
  Future<List<GrowthEvent>> listGrowthEvents(ChildId childId) async {
    final rows = await _client
        .from('growth_events')
        .select()
        .eq('child_id', childId.value)
        .order('created_at', ascending: false);

    return (rows as List)
        .map((r) => _mapGrowthEvent(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  @override
  Future<GrowthEvent?> getGrowthEventByAssessmentId(
    AssessmentId assessmentId,
  ) async {
    final row = await _client
        .from('growth_events')
        .select()
        .eq('assessment_id', assessmentId.value)
        .maybeSingle();

    if (row == null) return null;
    return _mapGrowthEvent(Map<String, dynamic>.from(row));
  }

  static GrowthEvent _mapGrowthEvent(Map<String, dynamic> row) {
    return GrowthEvent(
      id: row['id'] as String,
      familyId: FamilyId(row['family_id'] as String),
      childId: ChildId(row['child_id'] as String),
      verifiedLearningEventId: row['verified_learning_event_id'] as String,
      assessmentId: AssessmentId(row['assessment_id'] as String),
      engineVersion: row['engine_version'] as String,
      normalizedScore: (row['normalized_score'] as num).toDouble(),
      baselineScore: (row['baseline_score'] as num?)?.toDouble(),
      baselineSampleCount: (row['baseline_sample_count'] as num).toInt(),
      growthDelta: (row['growth_delta'] as num?)?.toDouble(),
      historicalBest: (row['historical_best'] as num?)?.toDouble(),
      scoreRpMinor: RpMinor((row['score_rp_minor'] as num).toInt()),
      growthRpMinor: RpMinor((row['growth_rp_minor'] as num).toInt()),
      highPerformerRpMinor:
          RpMinor((row['high_performer_rp_minor'] as num).toInt()),
      goalRpMinor: RpMinor((row['goal_rp_minor'] as num).toInt()),
      personalBestRpMinor:
          RpMinor((row['personal_best_rp_minor'] as num).toInt()),
      difficultyRpMinor: RpMinor((row['difficulty_rp_minor'] as num).toInt()),
      recoveryRpMinor: RpMinor((row['recovery_rp_minor'] as num).toInt()),
      belowLevelAdjustment: row['below_level_adjustment'] as bool? ?? false,
      totalRpMinor: RpMinor((row['total_rp_minor'] as num).toInt()),
      xpAwarded: XpAmount((row['xp_awarded'] as num).toInt()),
      inputsSnapshot: row['inputs_snapshot'] is Map
          ? Map<String, dynamic>.from(row['inputs_snapshot'] as Map)
          : const {},
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  static ChildBalance _mapChildBalance(Map<String, dynamic> row) {
    return ChildBalance(
      familyId: FamilyId(row['family_id'] as String),
      childId: ChildId(row['child_id'] as String),
      xpTotal: XpAmount((row['xp_total'] as num).toInt()),
      rpBalanceMinor: RpMinor((row['rp_balance_minor'] as num).toInt()),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}
