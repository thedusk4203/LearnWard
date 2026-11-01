import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase/supabase.dart';

/// Supabase implementation of [AssessmentRepository] enforcing server-authoritative
/// workflow transitions via trusted SECURITY DEFINER RPCs.
final class SupabaseAssessmentRepository implements AssessmentRepository {
  SupabaseAssessmentRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Assessment> createDraft({
    required String commandId,
    required FamilyId familyId,
    required ChildId childId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    EntryContext entryContext = EntryContext.adult,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'create_assessment_draft',
      params: {
        'p_command_id': commandId,
        'p_family_id': familyId.value,
        'p_child_id': childId.value,
        'p_subject_key': subjectKey.value,
        'p_subject': subject,
        'p_title': title,
        'p_assessment_type': type.value,
        'p_difficulty': difficulty.value,
        'p_raw_score': score.rawScore,
        'p_max_score': score.maxScore,
        'p_occurred_at': (occurredAt ?? DateTime.now().toUtc())
            .toIso8601String(),
        'p_entry_context': entryContext.value,
      },
    );

    return _mapAssessment(response);
  }

  @override
  Future<Assessment> updateDraft({
    required AssessmentId assessmentId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    required int expectedVersion,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'update_assessment_draft',
      params: {
        'p_assessment_id': assessmentId.value,
        'p_subject_key': subjectKey.value,
        'p_subject': subject,
        'p_title': title,
        'p_assessment_type': type.value,
        'p_difficulty': difficulty.value,
        'p_raw_score': score.rawScore,
        'p_max_score': score.maxScore,
        'p_occurred_at': occurredAt?.toIso8601String(),
        'p_expected_version': expectedVersion,
      },
    );

    return _mapAssessment(response);
  }

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'submit_assessment',
      params: {
        'p_assessment_id': assessmentId.value,
        'p_expected_version': expectedVersion,
        'p_command_id': commandId,
      },
    );

    return _mapAssessment(response);
  }

  @override
  Future<Assessment> verifyAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    String? notes,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'verify_assessment',
      params: {
        'p_assessment_id': assessmentId.value,
        'p_expected_version': expectedVersion,
        'p_command_id': commandId,
        'p_notes': notes,
      },
    );

    return _mapAssessment(response);
  }

  @override
  Future<Assessment> rejectAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    required String reason,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'reject_assessment',
      params: {
        'p_assessment_id': assessmentId.value,
        'p_expected_version': expectedVersion,
        'p_command_id': commandId,
        'p_rejection_reason': reason,
      },
    );

    return _mapAssessment(response);
  }

  @override
  Future<Assessment?> getAssessment(AssessmentId id) async {
    final response = await _client
        .from('assessments')
        .select()
        .eq('id', id.value)
        .maybeSingle();

    if (response == null) return null;
    return _mapAssessment(Map<String, dynamic>.from(response));
  }

  @override
  Future<List<Assessment>> listAssessmentsByFamily(
    FamilyId familyId, {
    AssessmentStatus? status,
  }) async {
    var query = _client
        .from('assessments')
        .select()
        .eq('family_id', familyId.value);
    if (status != null) {
      query = query.eq('status', status.value);
    }
    final response = await query.order('occurred_at', ascending: false);

    final list = response as List<dynamic>;
    return list
        .map((row) => _mapAssessment(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  @override
  Future<List<Assessment>> listAssessmentsByChild(
    ChildId childId, {
    AssessmentStatus? status,
  }) async {
    var query = _client
        .from('assessments')
        .select()
        .eq('child_id', childId.value);
    if (status != null) {
      query = query.eq('status', status.value);
    }
    final response = await query.order('occurred_at', ascending: false);

    final list = response as List<dynamic>;
    return list
        .map((row) => _mapAssessment(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  @override
  Future<List<VerifiedLearningEvent>> listVerifiedLearningEvents(
    ChildId childId,
  ) async {
    final response = await _client
        .from('verified_learning_events')
        .select()
        .eq('child_id', childId.value)
        .order('occurred_at', ascending: false);

    final list = response as List<dynamic>;
    return list
        .map(
          (row) =>
              _mapVerifiedLearningEvent(Map<String, dynamic>.from(row as Map)),
        )
        .toList();
  }

  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) async {
    final response = await _client.rpc<Map<String, dynamic>>(
      'register_assessment_evidence',
      params: {
        'p_assessment_id': assessmentId.value,
        'p_storage_path': storagePath,
        'p_media_type': mediaType,
        'p_file_size_bytes': fileSizeBytes,
      },
    );

    return _mapEvidence(response);
  }

  @override
  Future<void> removeDraftEvidence(EvidenceId evidenceId) async {
    await _client.rpc<void>(
      'remove_draft_assessment_evidence',
      params: {'p_evidence_id': evidenceId.value},
    );
  }

  @override
  Future<List<AssessmentEvidence>> listEvidenceForAssessment(
    AssessmentId assessmentId,
  ) async {
    final response = await _client
        .from('assessment_evidence')
        .select()
        .eq('assessment_id', assessmentId.value)
        .order('created_at', ascending: true);

    final list = response as List<dynamic>;
    return list
        .map((row) => _mapEvidence(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  static Assessment _mapAssessment(Map<String, dynamic> row) {
    final rawScore = (row['raw_score'] as num).toDouble();
    final maxScore = (row['max_score'] as num).toDouble();

    SubjectKey subjectKey;
    try {
      subjectKey = SubjectKey.parse(row['subject_key'] as String? ?? 'math');
    } catch (_) {
      subjectKey = SubjectKey.math;
    }

    EntryContext entryContext;
    try {
      entryContext = EntryContext.parse(
        row['entry_context'] as String? ?? 'adult',
      );
    } catch (_) {
      entryContext = EntryContext.adult;
    }

    return Assessment(
      id: AssessmentId(row['id'] as String),
      familyId: FamilyId(row['family_id'] as String),
      childId: ChildId(row['child_id'] as String),
      subjectKey: subjectKey,
      subject: row['subject'] as String,
      title: row['title'] as String,
      type: AssessmentType.fromValue(row['assessment_type'] as String),
      difficulty: AssessmentDifficulty.fromValue(row['difficulty'] as String),
      score: AssessmentScore(rawScore: rawScore, maxScore: maxScore),
      entryContext: entryContext,
      status: AssessmentStatus.fromValue(row['status'] as String),
      occurredAt: DateTime.parse(row['occurred_at'] as String),
      version: row['version'] as int,
      createdByUserId: row['created_by_user_id'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }

  static AssessmentEvidence _mapEvidence(Map<String, dynamic> row) {
    return AssessmentEvidence(
      id: EvidenceId(row['id'] as String),
      familyId: FamilyId(row['family_id'] as String),
      assessmentId: AssessmentId(row['assessment_id'] as String),
      storagePath: row['storage_path'] as String,
      mediaType: row['media_type'] as String,
      fileSizeBytes: row['file_size_bytes'] as int,
      uploadedByUserId: row['uploaded_by_user_id'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  static VerifiedLearningEvent _mapVerifiedLearningEvent(
    Map<String, dynamic> row,
  ) {
    final rawScore = (row['raw_score'] as num).toDouble();
    final maxScore = (row['max_score'] as num).toDouble();

    SubjectKey subjectKey;
    try {
      subjectKey = SubjectKey.parse(row['subject_key'] as String? ?? 'math');
    } catch (_) {
      subjectKey = SubjectKey.math;
    }

    EntryContext entryContext;
    try {
      entryContext = EntryContext.parse(
        row['entry_context'] as String? ?? 'adult',
      );
    } catch (_) {
      entryContext = EntryContext.adult;
    }

    return VerifiedLearningEvent(
      id: row['id'] as String,
      familyId: FamilyId(row['family_id'] as String),
      childId: ChildId(row['child_id'] as String),
      assessmentId: AssessmentId(row['assessment_id'] as String),
      subjectKey: subjectKey,
      subject: row['subject'] as String,
      title: row['title'] as String,
      type: AssessmentType.fromValue(row['assessment_type'] as String),
      difficulty: AssessmentDifficulty.fromValue(row['difficulty'] as String),
      score: AssessmentScore(rawScore: rawScore, maxScore: maxScore),
      evidenceCount: (row['evidence_count'] as num?)?.toInt() ?? 0,
      entryContext: entryContext,
      occurredAt: DateTime.parse(row['occurred_at'] as String),
      verifiedAt: DateTime.parse(row['verified_at'] as String),
      verifiedByUserId: row['verified_by_user_id'] as String,
      reviewEventId: row['review_event_id'] as String,
    );
  }
}
