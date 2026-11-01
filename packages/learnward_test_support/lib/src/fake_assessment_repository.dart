import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

final class FakeAssessmentRepository implements AssessmentRepository {
  final Map<String, Assessment> assessments = {};
  final Map<String, AssessmentEvidence> evidence = {};
  final List<VerifiedLearningEvent> verifiedEvents = [];
  final Set<String> processedCommandIds = {};

  int _assessmentIdCounter = 1;
  int _evidenceIdCounter = 1;

  @override
  Future<Assessment> createDraft({
    required FamilyId familyId,
    required ChildId childId,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
  }) async {
    final id = AssessmentId('fake-assessment-${_assessmentIdCounter++}');
    final now = DateTime.now().toUtc();
    final assessment = Assessment(
      id: id,
      familyId: familyId,
      childId: childId,
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      status: AssessmentStatus.draft,
      occurredAt: occurredAt ?? now,
      version: 1,
      createdByUserId: 'fake-user-id',
      createdAt: now,
      updatedAt: now,
    );
    assessments[id.value] = assessment;
    return assessment;
  }

  @override
  Future<Assessment> updateDraft({
    required AssessmentId assessmentId,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    required int expectedVersion,
  }) async {
    final existing = assessments[assessmentId.value];
    if (existing == null) {
      throw StateError('Assessment not found');
    }
    if (existing.status != AssessmentStatus.draft) {
      throw StateError('Only draft assessments can be updated');
    }
    if (existing.version != expectedVersion) {
      throw StateError('Stale assessment version');
    }

    final updated = existing.copyWith(
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      occurredAt: occurredAt,
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    assessments[assessmentId.value] = updated;
    return updated;
  }

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
    final existing = assessments[assessmentId.value];
    if (existing == null) {
      throw StateError('Assessment not found');
    }
    if (processedCommandIds.contains(commandId)) {
      return existing;
    }
    if (existing.status != AssessmentStatus.draft) {
      throw StateError('Only draft assessments can be submitted');
    }
    if (existing.version != expectedVersion) {
      throw StateError('Stale assessment version');
    }

    processedCommandIds.add(commandId);
    final submitted = existing.copyWith(
      status: AssessmentStatus.pendingReview,
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    assessments[assessmentId.value] = submitted;
    return submitted;
  }

  @override
  Future<Assessment> verifyAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    String? notes,
  }) async {
    final existing = assessments[assessmentId.value];
    if (existing == null) {
      throw StateError('Assessment not found');
    }
    if (processedCommandIds.contains(commandId)) {
      return existing;
    }
    if (existing.status != AssessmentStatus.pendingReview) {
      throw StateError('Assessment is not pending review');
    }
    if (existing.version != expectedVersion) {
      throw StateError('Stale assessment version');
    }

    processedCommandIds.add(commandId);
    final now = DateTime.now().toUtc();
    final verified = existing.copyWith(
      status: AssessmentStatus.verified,
      version: existing.version + 1,
      updatedAt: now,
    );
    assessments[assessmentId.value] = verified;

    verifiedEvents.add(
      VerifiedLearningEvent(
        id: 'fake-event-${verifiedEvents.length + 1}',
        familyId: verified.familyId,
        childId: verified.childId,
        assessmentId: verified.id,
        subject: verified.subject,
        title: verified.title,
        type: verified.type,
        difficulty: verified.difficulty,
        score: verified.score,
        occurredAt: verified.occurredAt,
        verifiedAt: now,
        verifiedByUserId: 'fake-verifier',
        reviewEventId: 'fake-review-event-$commandId',
      ),
    );

    return verified;
  }

  @override
  Future<Assessment> rejectAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    String? reason,
  }) async {
    final existing = assessments[assessmentId.value];
    if (existing == null) {
      throw StateError('Assessment not found');
    }
    if (processedCommandIds.contains(commandId)) {
      return existing;
    }
    if (existing.status != AssessmentStatus.pendingReview) {
      throw StateError('Assessment is not pending review');
    }
    if (existing.version != expectedVersion) {
      throw StateError('Stale assessment version');
    }

    processedCommandIds.add(commandId);
    final rejected = existing.copyWith(
      status: AssessmentStatus.rejected,
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    assessments[assessmentId.value] = rejected;
    return rejected;
  }

  @override
  Future<Assessment?> getAssessment(AssessmentId id) async {
    return assessments[id.value];
  }

  @override
  Future<List<Assessment>> listAssessmentsByFamily(
    FamilyId familyId, {
    AssessmentStatus? status,
  }) async {
    return assessments.values
        .where(
          (a) =>
              a.familyId == familyId && (status == null || a.status == status),
        )
        .toList();
  }

  @override
  Future<List<Assessment>> listAssessmentsByChild(
    ChildId childId, {
    AssessmentStatus? status,
  }) async {
    return assessments.values
        .where(
          (a) => a.childId == childId && (status == null || a.status == status),
        )
        .toList();
  }

  @override
  Future<List<VerifiedLearningEvent>> listVerifiedLearningEvents(
    ChildId childId,
  ) async {
    return verifiedEvents.where((e) => e.childId == childId).toList();
  }

  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) async {
    final assessment = assessments[assessmentId.value];
    if (assessment == null) {
      throw StateError('Assessment not found');
    }
    final id = EvidenceId('fake-evidence-${_evidenceIdCounter++}');
    final ev = AssessmentEvidence(
      id: id,
      familyId: assessment.familyId,
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: fileSizeBytes,
      uploadedByUserId: 'fake-user-id',
      createdAt: DateTime.now().toUtc(),
    );
    evidence[id.value] = ev;
    return ev;
  }

  @override
  Future<void> removeDraftEvidence(EvidenceId evidenceId) async {
    evidence.remove(evidenceId.value);
  }

  @override
  Future<List<AssessmentEvidence>> listEvidenceForAssessment(
    AssessmentId assessmentId,
  ) async {
    return evidence.values
        .where((e) => e.assessmentId == assessmentId)
        .toList();
  }
}
