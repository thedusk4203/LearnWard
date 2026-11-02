import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase implementation of [LearningRepository] interacting with
/// `learning_nodes`, `assessment_learning_mappings`, and Learning Engine RPCs.
final class SupabaseLearningRepository implements LearningRepository {
  SupabaseLearningRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<LearningNode>> getCatalogNodes({
    required String catalogVersion,
    String? subjectKey,
  }) async {
    var query = _client
        .from('learning_nodes')
        .select()
        .eq('catalog_version', catalogVersion);

    if (subjectKey != null) {
      query = query.eq('subject_key', subjectKey);
    }

    final rows = await query.order('sort_order', ascending: true);
    final list = rows as List<dynamic>;

    return list.map((r) {
      final map = r as Map<String, dynamic>;
      return LearningNode(
        id: LearningNodeId(map['id'] as String),
        catalogVersion: map['catalog_version'] as String,
        nodeType: LearningNodeType.fromValue(map['node_type'] as String),
        subjectKey: map['subject_key'] as String,
        canonicalKey: map['canonical_key'] as String,
        title: map['title'] as String,
        description: map['description'] as String?,
        parentId: map['parent_id'] != null
            ? LearningNodeId(map['parent_id'] as String)
            : null,
        gradeMin: (map['grade_min'] as num?)?.toInt(),
        gradeMax: (map['grade_max'] as num?)?.toInt(),
        sortOrder: (map['sort_order'] as num?)?.toInt() ?? 0,
        isActive: map['is_active'] as bool? ?? true,
      );
    }).toList();
  }

  @override
  Future<List<AssessmentLearningMapping>> getAssessmentLearningMappings(
    AssessmentId assessmentId,
  ) async {
    final response = await _client.rpc<dynamic>(
      'get_assessment_learning_mappings',
      params: {'p_assessment_id': assessmentId.value},
    );

    final list = response as List<dynamic>;
    return list.map((item) {
      final map = item as Map<String, dynamic>;
      return AssessmentLearningMapping(
        id: map['id'] as String?,
        familyId: FamilyId(map['family_id'] as String? ?? ''),
        assessmentId: assessmentId,
        learningNodeId: LearningNodeId(map['learning_node_id'] as String),
        scoreSource: ScoreSource.fromValue(map['score_source'] as String),
        componentKey: map['component_key'] as String?,
        rawScore: ((map['raw_score'] ?? map['component_raw_score']) as num?)
            ?.toDouble(),
        maxScore: ((map['max_score'] ?? map['component_max_score']) as num?)
            ?.toDouble(),
        itemCount: (map['item_count'] as num?)?.toInt(),
        correctCount: (map['correct_count'] as num?)?.toInt(),
      );
    }).toList();
  }

  @override
  Future<List<AssessmentLearningMapping>> setAssessmentLearningMappings({
    required AssessmentId assessmentId,
    required List<AssessmentLearningMapping> mappings,
  }) async {
    final serialized = mappings.map((m) => m.toJson()).toList();

    final response = await _client.rpc<dynamic>(
      'set_assessment_learning_mappings',
      params: {'p_assessment_id': assessmentId.value, 'p_mappings': serialized},
    );

    final list = response as List<dynamic>;
    return list.map((item) {
      final map = item as Map<String, dynamic>;
      return AssessmentLearningMapping(
        id: map['id'] as String?,
        familyId: FamilyId(map['family_id'] as String? ?? ''),
        assessmentId: assessmentId,
        learningNodeId: LearningNodeId(map['learning_node_id'] as String),
        scoreSource: ScoreSource.fromValue(map['score_source'] as String),
        componentKey: map['component_key'] as String?,
        rawScore: ((map['raw_score'] ?? map['component_raw_score']) as num?)
            ?.toDouble(),
        maxScore: ((map['max_score'] ?? map['component_max_score']) as num?)
            ?.toDouble(),
        itemCount: (map['item_count'] as num?)?.toInt(),
        correctCount: (map['correct_count'] as num?)?.toInt(),
      );
    }).toList();
  }

  @override
  Future<Map<String, dynamic>> processLearningEvent({
    required String commandId,
    required String verifiedLearningEventId,
  }) async {
    final response = await _client.rpc<dynamic>(
      'process_learning_event',
      params: {
        'p_command_id': commandId,
        'p_verified_event_id': verifiedLearningEventId,
      },
    );

    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<Map<String, dynamic>> catchUpUnprocessedLearning(
    FamilyId familyId,
  ) async {
    final response = await _client.rpc<dynamic>(
      'catch_up_unprocessed_learning',
      params: {'p_family_id': familyId.value},
    );

    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<List<ChildMasteryProjection>> getChildMastery({
    required ChildId childId,
    DateTime? asOf,
  }) async {
    final response = await _client.rpc<dynamic>(
      'get_child_mastery',
      params: {
        'p_child_id': childId.value,
        if (asOf != null) 'p_as_of': asOf.toIso8601String(),
      },
    );

    final list = response as List<dynamic>;
    return list
        .map(
          (item) => ChildMasteryProjection.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  @override
  Future<String> promoteLearningCatalogVersion(String targetVersion) async {
    final response = await _client.rpc<String>(
      'promote_learning_catalog_version',
      params: {'p_target_version': targetVersion},
    );

    return response;
  }
}
