import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Lightweight in-memory fallback for [FamilyRepository] when Supabase
/// credentials are not configured in local development.
final class InMemoryFamilyRepository implements FamilyRepository {
  final Map<String, Family> _families = {};
  final Map<String, FamilyMembership> _memberships = {};

  @override
  Future<Family> createFamily({
    required String name,
    required String timezone,
    required String locale,
  }) async {
    final id = 'local-fam-${DateTime.now().millisecondsSinceEpoch}';
    final family = Family(
      id: FamilyId(id),
      name: name,
      timezone: timezone,
      locale: locale,
      createdByUserId: 'local-parent-user',
      createdAt: DateTime.now().toUtc(),
    );
    _families[id] = family;
    _memberships[id] = FamilyMembership(
      familyId: family.id,
      authUserId: 'local-parent-user',
      role: FamilyRole.owner,
      status: MembershipStatus.active,
      joinedAt: DateTime.now().toUtc(),
    );
    return family;
  }

  @override
  Future<List<Family>> listMyFamilies() async {
    return _families.values.toList();
  }

  @override
  Future<FamilyMembership?> getMyMembership(FamilyId familyId) async {
    return _memberships[familyId.value];
  }
}

/// Lightweight in-memory fallback for [ChildProfileRepository] when Supabase
/// credentials are not configured in local development.
final class InMemoryChildProfileRepository implements ChildProfileRepository {
  final List<ChildProfile> _children = [];
  int _nextId = 1;

  @override
  Future<ChildProfile> createChildProfile({
    required FamilyId familyId,
    required String displayName,
    int? schoolGrade,
    int? birthYear,
    String? avatarKey,
  }) async {
    final child = ChildProfile(
      id: ChildId('local-child-${_nextId++}'),
      familyId: familyId,
      displayName: displayName,
      schoolGrade: schoolGrade,
      birthYear: birthYear,
      avatarKey: avatarKey,
      status: ChildProfileStatus.active,
      createdAt: DateTime.now().toUtc(),
    );
    _children.add(child);
    return child;
  }

  @override
  Future<List<ChildProfile>> listChildren(FamilyId familyId) async {
    return _children
        .where(
          (c) =>
              c.familyId == familyId && c.status == ChildProfileStatus.active,
        )
        .toList();
  }

  @override
  Future<void> archiveChildProfile({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    final index = _children.indexWhere(
      (c) => c.familyId == familyId && c.id == childId,
    );
    if (index != -1) {
      final existing = _children[index];
      _children[index] = ChildProfile(
        id: existing.id,
        familyId: existing.familyId,
        displayName: existing.displayName,
        schoolGrade: existing.schoolGrade,
        birthYear: existing.birthYear,
        avatarKey: existing.avatarKey,
        status: ChildProfileStatus.archived,
        createdAt: existing.createdAt,
        archivedAt: DateTime.now().toUtc(),
      );
    }
  }
}

/// Lightweight in-memory fallback for [LocalDraftStore] in test and local demo modes.
final class InMemoryLocalDraftStore implements LocalDraftStore {
  final Map<String, LocalAssessmentDraft> _drafts = {};

  @override
  Future<void> saveLocalDraft(LocalAssessmentDraft draft) async {
    _drafts[draft.localDraftId] = draft;
  }

  @override
  Future<List<LocalAssessmentDraft>> listLocalDrafts(ChildId childId) async {
    return _drafts.values.where((d) => d.childId == childId.value).toList();
  }

  @override
  Future<void> deleteLocalDraft(String localDraftId) async {
    _drafts.remove(localDraftId);
  }
}

/// Lightweight in-memory fallback for [AssessmentRepository] in local demo mode.
final class InMemoryAssessmentRepository implements AssessmentRepository {
  final Map<String, Assessment> _assessments = {};
  final Map<String, AssessmentEvidence> _evidence = {};
  final List<VerifiedLearningEvent> _verifiedEvents = [];
  final Set<String> _processedCommands = {};
  int _assessmentCounter = 1;
  int _evidenceCounter = 1;

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
    final id = AssessmentId('local-assessment-${_assessmentCounter++}');
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
      createdByUserId: 'local-user',
      createdAt: now,
      updatedAt: now,
    );
    _assessments[id.value] = assessment;
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
    final existing = _assessments[assessmentId.value];
    if (existing == null) throw StateError('Assessment not found');
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
    _assessments[assessmentId.value] = updated;
    return updated;
  }

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
  }) async {
    final existing = _assessments[assessmentId.value];
    if (existing == null) throw StateError('Assessment not found');
    if (_processedCommands.contains(commandId)) return existing;
    if (existing.status != AssessmentStatus.draft) {
      throw StateError('Only draft assessments can be submitted');
    }
    if (existing.version != expectedVersion) {
      throw StateError('Stale assessment version');
    }

    _processedCommands.add(commandId);
    final submitted = existing.copyWith(
      status: AssessmentStatus.pendingReview,
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    _assessments[assessmentId.value] = submitted;
    return submitted;
  }

  @override
  Future<Assessment> verifyAssessment({
    required AssessmentId assessmentId,
    required int expectedVersion,
    required String commandId,
    String? notes,
  }) async {
    final existing = _assessments[assessmentId.value];
    if (existing == null) throw StateError('Assessment not found');
    if (_processedCommands.contains(commandId)) return existing;
    if (existing.status != AssessmentStatus.pendingReview) {
      throw StateError('Assessment is not pending review');
    }
    if (existing.version != expectedVersion) {
      throw StateError('Stale assessment version');
    }

    _processedCommands.add(commandId);
    final now = DateTime.now().toUtc();
    final verified = existing.copyWith(
      status: AssessmentStatus.verified,
      version: existing.version + 1,
      updatedAt: now,
    );
    _assessments[assessmentId.value] = verified;

    _verifiedEvents.add(
      VerifiedLearningEvent(
        id: 'local-event-${_verifiedEvents.length + 1}',
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
        verifiedByUserId: 'local-user',
        reviewEventId: 'local-review-$commandId',
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
    final existing = _assessments[assessmentId.value];
    if (existing == null) throw StateError('Assessment not found');
    if (_processedCommands.contains(commandId)) return existing;
    if (existing.status != AssessmentStatus.pendingReview) {
      throw StateError('Assessment is not pending review');
    }
    if (existing.version != expectedVersion) {
      throw StateError('Stale assessment version');
    }

    _processedCommands.add(commandId);
    final rejected = existing.copyWith(
      status: AssessmentStatus.rejected,
      version: existing.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    _assessments[assessmentId.value] = rejected;
    return rejected;
  }

  @override
  Future<Assessment?> getAssessment(AssessmentId id) async {
    return _assessments[id.value];
  }

  @override
  Future<List<Assessment>> listAssessmentsByFamily(
    FamilyId familyId, {
    AssessmentStatus? status,
  }) async {
    return _assessments.values
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
    return _assessments.values
        .where(
          (a) => a.childId == childId && (status == null || a.status == status),
        )
        .toList();
  }

  @override
  Future<List<VerifiedLearningEvent>> listVerifiedLearningEvents(
    ChildId childId,
  ) async {
    return _verifiedEvents.where((e) => e.childId == childId).toList();
  }

  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) async {
    final assessment = _assessments[assessmentId.value];
    if (assessment == null) throw StateError('Assessment not found');
    final id = EvidenceId('local-evidence-${_evidenceCounter++}');
    final ev = AssessmentEvidence(
      id: id,
      familyId: assessment.familyId,
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: fileSizeBytes,
      uploadedByUserId: 'local-user',
      createdAt: DateTime.now().toUtc(),
    );
    _evidence[id.value] = ev;
    return ev;
  }

  @override
  Future<void> removeDraftEvidence(EvidenceId evidenceId) async {
    _evidence.remove(evidenceId.value);
  }

  @override
  Future<List<AssessmentEvidence>> listEvidenceForAssessment(
    AssessmentId assessmentId,
  ) async {
    return _evidence.values
        .where((e) => e.assessmentId == assessmentId)
        .toList();
  }
}

/// Lightweight in-memory fallback for [AssessmentEvidenceStorage] in local demo mode.
final class InMemoryAssessmentEvidenceStorage
    implements AssessmentEvidenceStorage {
  final Map<String, List<int>> _storage = {};

  @override
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required String fileName,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final path =
        '${familyId.value}/${childId.value}/${assessmentId.value}/$fileName';
    _storage[path] = bytes;
    return path;
  }

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 60),
  }) async {
    return 'https://local-demo-storage.learnward.internal/$storagePath';
  }

  @override
  Future<void> deleteEvidence(String storagePath) async {
    _storage.remove(storagePath);
  }
}
