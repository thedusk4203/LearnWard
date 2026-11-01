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
  List<ChildProfile> get children => _children;
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
  Future<LocalAssessmentDraft?> getLocalDraft(String localDraftId) async {
    return _drafts[localDraftId];
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

  final Map<String, String> _commandToAssessmentId = {};

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
    if (_commandToAssessmentId.containsKey(commandId)) {
      return _assessments[_commandToAssessmentId[commandId]]!;
    }
    final id = AssessmentId('local-assessment-${_assessmentCounter++}');
    final now = DateTime.now().toUtc();
    final assessment = Assessment(
      id: id,
      familyId: familyId,
      childId: childId,
      subjectKey: subjectKey,
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      entryContext: entryContext,
      status: AssessmentStatus.draft,
      occurredAt: occurredAt ?? now,
      version: 1,
      createdByUserId: 'local-user',
      createdAt: now,
      updatedAt: now,
    );
    _assessments[id.value] = assessment;
    _commandToAssessmentId[commandId] = id.value;
    return assessment;
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
    final existing = _assessments[assessmentId.value];
    if (existing == null) throw StateError('Assessment not found');
    if (existing.status != AssessmentStatus.draft) {
      throw StateError('Only draft assessments can be updated');
    }
    if (existing.version != expectedVersion) {
      throw StateError('Stale assessment version');
    }

    final updated = existing.copyWith(
      subjectKey: subjectKey,
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

    final evidenceCount = _evidence.values
        .where((e) => e.assessmentId == assessmentId)
        .length;

    _verifiedEvents.add(
      VerifiedLearningEvent(
        id: 'local-event-${_verifiedEvents.length + 1}',
        familyId: verified.familyId,
        childId: verified.childId,
        assessmentId: verified.id,
        subjectKey: verified.subjectKey,
        subject: verified.subject,
        title: verified.title,
        type: verified.type,
        difficulty: verified.difficulty,
        score: verified.score,
        evidenceCount: evidenceCount,
        entryContext: verified.entryContext,
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
    required String reason,
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
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
  }) async {
    final ext = mediaType == 'image/png' ? 'png' : 'jpg';
    final path =
        '${familyId.value}/${childId.value}/${assessmentId.value}/${evidenceId.value}.$ext';
    _storage[path] = bytes;
    return path;
  }

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
  }) async {
    return 'https://local-demo-storage.learnward.internal/$storagePath';
  }

  @override
  Future<void> deleteEvidence(String storagePath) async {
    _storage.remove(storagePath);
  }
}

/// Lightweight in-memory fallback for [GrowthRepository] in local demo mode and widget tests.
final class InMemoryGrowthRepository implements GrowthRepository {
  InMemoryGrowthRepository({this.assessmentRepository});

  final InMemoryAssessmentRepository? assessmentRepository;

  final Map<String, GrowthEvent> _growthEventsByVle = {};
  final Map<String, GrowthEvent> _growthEventsByAssessment = {};
  final Map<String, ChildBalance> _balancesByChild = {};
  Map<String, ChildBalance> get balancesByChild => _balancesByChild;
  final List<XpLedgerEntry> _xpLedger = [];
  final List<RpLedgerEntry> _rpLedger = [];

  @override
  Future<GrowthEvent> processVerifiedLearningEvent({
    required String verifiedLearningEventId,
    String? commandId,
  }) async {
    if (_growthEventsByVle.containsKey(verifiedLearningEventId)) {
      return _growthEventsByVle[verifiedLearningEventId]!;
    }

    VerifiedLearningEvent? vle;
    if (assessmentRepository != null) {
      for (final event in assessmentRepository!._verifiedEvents) {
        if (event.id == verifiedLearningEventId) {
          vle = event;
          break;
        }
      }
    }

    final familyId = vle?.familyId ?? FamilyId('demo-fam');
    final childId = vle?.childId ?? ChildId('demo-child');
    final assessmentId = vle?.assessmentId ?? AssessmentId('demo-assessment');
    final subjectKey = vle?.subjectKey ?? SubjectKey.math;
    final diff = vle?.difficulty ?? AssessmentDifficulty.normal;
    final normScore = vle?.score.serverNormalizedScore ?? 7.50;

    final history = <ComparableResult>[];
    if (assessmentRepository != null) {
      for (final event in assessmentRepository!._verifiedEvents) {
        if (event.id != verifiedLearningEventId &&
            event.childId == childId &&
            event.subjectKey == subjectKey) {
          history.add(
            ComparableResult(
              id: event.id,
              subjectKey: event.subjectKey,
              normalizedScore: event.score.serverNormalizedScore,
              difficulty: event.difficulty,
              assessmentType: event.type,
              gradeLevel: event.gradeLevelSnapshot,
              occurredAt: event.occurredAt,
              verifiedAt: event.verifiedAt,
            ),
          );
        }
      }
    }

    final input = GrowthInput(
      currentEventId: verifiedLearningEventId,
      subjectKey: subjectKey,
      currentScore: NormalizedScore.fromRaw(
        rawScore: normScore,
        maxScore: 10.0,
      ),
      difficulty: diff,
      assessmentType: vle?.type ?? AssessmentType.quiz,
      gradeLevel: vle?.gradeLevelSnapshot,
      occurredAt: vle?.occurredAt ?? DateTime.now().toUtc(),
      verifiedAt: vle?.verifiedAt ?? DateTime.now().toUtc(),
      comparableHistory: history,
    );

    final growthResult = GrowthEngine.calculate(input);
    final breakdown = growthResult.breakdown;

    final growthEvent = GrowthEvent(
      id: 'local-ge-',
      familyId: familyId,
      childId: childId,
      verifiedLearningEventId: verifiedLearningEventId,
      assessmentId: assessmentId,
      engineVersion: GrowthEngine.engineVersion,
      normalizedScore: breakdown.normalizedScore,
      baselineScore: breakdown.baselineScore,
      baselineSampleCount: breakdown.baselineSampleCount,
      growthDelta: breakdown.growthDelta,
      historicalBest: breakdown.historicalBest,
      scoreRpMinor: breakdown.scoreRpMinor,
      growthRpMinor: breakdown.growthRpMinor,
      highPerformerRpMinor: breakdown.highPerformerRpMinor,
      goalRpMinor: breakdown.goalRpMinor,
      personalBestRpMinor: breakdown.personalBestRpMinor,
      difficultyRpMinor: breakdown.difficultyRpMinor,
      recoveryRpMinor: breakdown.recoveryRpMinor,
      belowLevelAdjustment: breakdown.belowLevelAdjustment,
      totalRpMinor: breakdown.totalRpMinor,
      xpAwarded: breakdown.xpAwarded,
      inputsSnapshot: growthResult.inputsSnapshot,
      createdAt: DateTime.now().toUtc(),
    );

    _growthEventsByVle[verifiedLearningEventId] = growthEvent;
    _growthEventsByAssessment[assessmentId.value] = growthEvent;

    _xpLedger.add(
      XpLedgerEntry(
        id: 'local-xp-',
        familyId: familyId,
        childId: childId,
        amount: growthEvent.xpAwarded,
        reasonCode: 'growth_award',
        sourceType: 'growth_event',
        sourceId: growthEvent.id,
        idempotencyKey: 'xp:ge:',
        createdAt: growthEvent.createdAt,
      ),
    );

    _rpLedger.add(
      RpLedgerEntry(
        id: 'local-rp-',
        familyId: familyId,
        childId: childId,
        amountMinor: growthEvent.totalRpMinor,
        reasonCode: 'growth_award',
        sourceType: 'growth_event',
        sourceId: growthEvent.id,
        idempotencyKey: 'rp:ge:',
        createdAt: growthEvent.createdAt,
      ),
    );

    final currentBal = _balancesByChild[childId.value];
    final newXp =
        (currentBal?.xpTotal ?? XpAmount.zero) + growthEvent.xpAwarded;
    final newRp =
        (currentBal?.rpBalanceMinor ?? RpMinor.zero) + growthEvent.totalRpMinor;

    _balancesByChild[childId.value] = ChildBalance(
      familyId: familyId,
      childId: childId,
      xpTotal: newXp,
      rpBalanceMinor: newRp,
      updatedAt: growthEvent.createdAt,
    );

    return growthEvent;
  }

  @override
  Future<ChildBalance?> getChildBalance(ChildId childId) async {
    return _balancesByChild[childId.value];
  }

  @override
  Future<GrowthEvent?> getLatestGrowthEvent(ChildId childId) async {
    final list = await listGrowthEvents(childId);
    return list.isEmpty ? null : list.first;
  }

  @override
  Future<List<GrowthEvent>> listGrowthEvents(ChildId childId) async {
    final events = _growthEventsByVle.values
        .where((e) => e.childId == childId)
        .toList();
    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return events;
  }

  @override
  Future<GrowthEvent?> getGrowthEventByAssessmentId(
    AssessmentId assessmentId,
  ) async {
    return _growthEventsByAssessment[assessmentId.value];
  }

  @override
  Future<List<VerifiedLearningEvent>> getUnprocessedVerifiedEvents(
    FamilyId familyId,
  ) async {
    if (assessmentRepository == null) return const [];
    return assessmentRepository!._verifiedEvents.where((vle) {
      return vle.familyId == familyId &&
          !_growthEventsByVle.containsKey(vle.id);
    }).toList();
  }

  @override
  Future<int> catchUpUnprocessedGrowth(FamilyId familyId) async {
    final pending = await getUnprocessedVerifiedEvents(familyId);
    for (final event in pending) {
      await processVerifiedLearningEvent(verifiedLearningEventId: event.id);
    }
    return pending.length;
  }
}

/// Lightweight in-memory fallback for [RewardRepository] when Supabase credentials
/// are not configured in local development.
final class InMemoryRewardRepository implements RewardRepository {
  InMemoryRewardRepository({this.growthRepository});

  final InMemoryGrowthRepository? growthRepository;
  final Map<String, Reward> _rewards = {};
  final Map<String, RewardRedemption> _redemptions = {};
  final Map<String, dynamic> _commandReceipts = {};
  int _nextRewardId = 1;
  int _nextRedemptionId = 1;

  @override
  Future<Reward> createReward({
    required FamilyId familyId,
    required String title,
    String? description,
    required RewardCategory category,
    String iconKey = 'default_star',
    bool storeEnabled = true,
    int? storeCostMinor,
    bool wheelEnabled = false,
    WheelTier? wheelTier,
    ChildId? targetChildId,
  }) async {
    final id = RewardId('local-rew-${_nextRewardId++}');
    final now = DateTime.now().toUtc();
    final reward = Reward(
      id: id,
      familyId: familyId,
      title: title,
      description: description,
      category: category,
      iconKey: iconKey,
      storeEnabled: storeEnabled,
      storeCostMinor: storeCostMinor,
      wheelEnabled: wheelEnabled,
      wheelTier: wheelTier,
      targetChildId: targetChildId,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    );
    _rewards[id.value] = reward;
    return reward;
  }

  @override
  Future<Reward> updateReward(Reward reward) async {
    _rewards[reward.id.value] = reward.copyWith(
      updatedAt: DateTime.now().toUtc(),
    );
    return _rewards[reward.id.value]!;
  }

  @override
  Future<void> deleteReward({
    required FamilyId familyId,
    required RewardId rewardId,
  }) async {
    _rewards.remove(rewardId.value);
  }

  @override
  Future<Reward?> getReward({
    required FamilyId familyId,
    required RewardId rewardId,
  }) async {
    final reward = _rewards[rewardId.value];
    if (reward != null && reward.familyId == familyId) {
      return reward;
    }
    return null;
  }

  @override
  Future<List<Reward>> listFamilyRewards({
    required FamilyId familyId,
    bool? activeOnly,
  }) async {
    return _rewards.values.where((r) {
      if (r.familyId != familyId) return false;
      if (activeOnly == true && !r.isActive) return false;
      return true;
    }).toList();
  }

  @override
  Future<List<Reward>> listStoreRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) async {
    final list = _rewards.values.where((r) {
      if (r.familyId != familyId) return false;
      if (!r.storeEnabled || !r.isActive) return false;
      if (childId != null && !r.isEligibleFor(childId)) return false;
      return true;
    }).toList();
    list.sort(
      (a, b) => (a.storeCostMinor ?? 0).compareTo(b.storeCostMinor ?? 0),
    );
    return list;
  }

  @override
  Future<RewardRedemption> redeemStoreReward({
    required String commandId,
    required RewardId rewardId,
    required ChildId childId,
  }) async {
    if (_commandReceipts.containsKey(commandId)) {
      final receipt = _commandReceipts[commandId] as Map<String, dynamic>;
      final existingId = receipt['resource_id'] as String;
      return _redemptions[existingId]!;
    }

    final reward = _rewards[rewardId.value];
    if (reward == null || !reward.isActive || !reward.storeEnabled) {
      throw const InvalidRewardException('Reward no longer available.');
    }

    final cost = reward.storeCostMinor ?? 0;
    if (growthRepository != null) {
      final balance = await growthRepository!.getChildBalance(childId);
      final currentBalance = balance?.rpBalanceMinor.value ?? 0;
      if (currentBalance < cost) {
        throw const InvalidRewardException('Insufficient RP balance.');
      }
      growthRepository!._balancesByChild[childId.value] = ChildBalance(
        familyId: reward.familyId,
        childId: childId,
        xpTotal: balance?.xpTotal ?? const XpAmount(0),
        rpBalanceMinor: RpMinor(currentBalance - cost),
        updatedAt: DateTime.now().toUtc(),
      );
    }

    final now = DateTime.now().toUtc();
    final redemptionId = RewardRedemptionId('local-red-${_nextRedemptionId++}');
    final redemption = RewardRedemption(
      id: redemptionId,
      familyId: reward.familyId,
      childId: childId,
      rewardId: reward.id,
      origin: RewardOrigin.store,
      rpCostMinor: cost,
      status: RewardRedemptionStatus.pendingFulfillment,
      rewardSnapshot: {
        'reward_id': reward.id.value,
        'title': reward.title,
        'description': reward.description,
        'category': reward.category.value,
        'icon_key': reward.iconKey,
        'store_cost_minor': cost,
        'redeemed_at': now.toIso8601String(),
      },
      createdAt: now,
      updatedAt: now,
    );

    _redemptions[redemptionId.value] = redemption;
    _commandReceipts[commandId] = {
      'operation': 'redeem_reward',
      'resource_id': redemptionId.value,
    };
    return redemption;
  }

  @override
  Future<RewardRedemption> fulfillRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
  }) async {
    if (_commandReceipts.containsKey(commandId)) {
      final receipt = _commandReceipts[commandId] as Map<String, dynamic>;
      final existingId = receipt['resource_id'] as String;
      return _redemptions[existingId]!;
    }

    final existing = _redemptions[redemptionId.value];
    if (existing == null) {
      throw const InvalidRedemptionException('Reward redemption not found.');
    }
    if (existing.status != RewardRedemptionStatus.pendingFulfillment) {
      throw InvalidRedemptionException(
        'Reward redemption is already in a terminal state: ${existing.status.value}',
      );
    }

    final now = DateTime.now().toUtc();
    final updated = existing.copyWith(
      status: RewardRedemptionStatus.fulfilled,
      fulfilledAt: now,
      fulfilledByUserId: 'local-parent-user',
      updatedAt: now,
    );
    _redemptions[redemptionId.value] = updated;
    _commandReceipts[commandId] = {
      'operation': 'fulfill_reward',
      'resource_id': redemptionId.value,
    };
    return updated;
  }

  @override
  Future<RewardRedemption> cancelRewardRedemption({
    required String commandId,
    required RewardRedemptionId redemptionId,
    required String cancellationReason,
  }) async {
    if (_commandReceipts.containsKey(commandId)) {
      final receipt = _commandReceipts[commandId] as Map<String, dynamic>;
      final existingId = receipt['resource_id'] as String;
      return _redemptions[existingId]!;
    }

    final existing = _redemptions[redemptionId.value];
    if (existing == null) {
      throw const InvalidRedemptionException('Reward redemption not found.');
    }
    if (existing.status != RewardRedemptionStatus.pendingFulfillment) {
      throw InvalidRedemptionException(
        'Reward redemption is already in a terminal state: ${existing.status.value}',
      );
    }

    final now = DateTime.now().toUtc();
    final updated = existing.copyWith(
      status: RewardRedemptionStatus.cancelled,
      cancellationReason: cancellationReason,
      updatedAt: now,
    );

    if (growthRepository != null) {
      final balance = await growthRepository!.getChildBalance(existing.childId);
      final currentBalance = balance?.rpBalanceMinor.value ?? 0;
      growthRepository!._balancesByChild[existing.childId.value] = ChildBalance(
        familyId: existing.familyId,
        childId: existing.childId,
        xpTotal: balance?.xpTotal ?? const XpAmount(0),
        rpBalanceMinor: RpMinor(currentBalance + existing.rpCostMinor),
        updatedAt: now,
      );
    }

    _redemptions[redemptionId.value] = updated;
    _commandReceipts[commandId] = {
      'operation': 'cancel_reward',
      'resource_id': redemptionId.value,
    };
    return updated;
  }

  @override
  Future<List<RewardRedemption>> listRedemptions({
    required FamilyId familyId,
    ChildId? childId,
    RewardRedemptionStatus? status,
  }) async {
    final list = _redemptions.values.where((r) {
      if (r.familyId != familyId) return false;
      if (childId != null && r.childId != childId) return false;
      if (status != null && r.status != status) return false;
      return true;
    }).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }
}
