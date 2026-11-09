import 'dart:math';

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

/// Lightweight in-memory fallback for [LocalMetadataStore] in test and local demo modes.
final class InMemoryMobileMetadataStore implements LocalMetadataStore {
  final Map<String, String> _metadata = {};

  @override
  Future<String?> readMetadata(String key) async => _metadata[key];

  @override
  Future<void> writeMetadata({
    required String key,
    required String value,
    required DateTime updatedAt,
  }) async {
    _metadata[key] = value;
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

  @override
  Future<DraftDeletionOutcome> deleteDraftSafely({
    required String localDraftId,
    required LocalAssessmentDraft expectedDraft,
    DateTime? now,
  }) async {
    final current = _drafts[localDraftId];
    if (current == null) {
      return DraftDeletionOutcome(
        status: DraftDeletionStatus.notFound,
        localDraftId: localDraftId,
        reason: 'Draft not found in local store.',
      );
    }

    if (current.isUnsafeToDelete(now: now)) {
      return DraftDeletionOutcome(
        status: DraftDeletionStatus.blockedUnsafeState,
        localDraftId: localDraftId,
        reason: current.deletionBlockedReason(now: now),
        currentDraft: current,
      );
    }

    if (current.hasConflictWith(expectedDraft)) {
      return DraftDeletionOutcome(
        status: DraftDeletionStatus.concurrencyConflict,
        localDraftId: localDraftId,
        reason: 'Draft was modified while deletion was being confirmed.',
        currentDraft: current,
      );
    }

    _drafts.remove(localDraftId);
    return DraftDeletionOutcome(
      status: DraftDeletionStatus.deleted,
      localDraftId: localDraftId,
    );
  }

  @override
  Future<bool> hasDraftReferenceToFile(String filePath) async {
    return _drafts.values.any(
      (d) =>
          d.localPhotoPath == filePath ||
          d.localCompressedPhotoPath == filePath,
    );
  }

  @override
  Future<int> countDraftReferencesToFile(String filePath) async {
    return _drafts.values
        .where(
          (d) =>
              d.localPhotoPath == filePath ||
              d.localCompressedPhotoPath == filePath,
        )
        .length;
  }
}

/// Lightweight in-memory fallback for [PendingRewardCommandStore] in test and local demo modes.
final class InMemoryPendingRewardCommandStore
    implements PendingRewardCommandStore {
  final Map<String, PendingRewardCommand> _commands = {};

  static String _generateLeaseToken() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  bool _isLeaseAvailable(PendingRewardCommand cmd, DateTime effectiveNow) {
    final isUnclaimed = cmd.leaseToken == null && cmd.leaseExpiresAt == null;
    final isExpired =
        cmd.leaseToken != null &&
        cmd.leaseExpiresAt != null &&
        !cmd.leaseExpiresAt!.isAfter(effectiveNow);
    return isUnclaimed || isExpired;
  }

  /// Injects a raw command directly into the in-memory map for testing malformed records.
  void seedRawCommand(PendingRewardCommand command) {
    _commands[command.commandId] = command;
  }

  @override
  Future<RegisterFreshCommandResult> registerFreshCommand({
    required PendingRewardCommand command,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    for (final existing in _commands.values) {
      final matchesOperation =
          existing.familyId == command.familyId &&
          existing.operation == command.operation &&
          (command.childId == null || existing.childId == command.childId) &&
          (command.operation != RewardCommandOperation.redeemReward ||
              existing.rewardId == command.rewardId);

      if (matchesOperation) {
        if (existing.isUnresolved) {
          return PreexistingCommandFound(existing);
        }
      }
    }

    _commands[command.commandId] = command.copyWith(
      createdAt: effectiveNow,
      nextAttemptAt: command.nextAttemptAt?.toUtc(),
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return FreshCommandRegistered(command);
  }

  @override
  Future<void> savePendingCommand(
    PendingRewardCommand command, {
    DateTime? now,
  }) async {
    final hasPartialLease =
        (command.leaseToken != null && command.leaseExpiresAt == null) ||
        (command.leaseToken == null && command.leaseExpiresAt != null);
    if (hasPartialLease) {
      throw ArgumentError(
        'Cannot save pending command ${command.commandId}: partial lease metadata '
        '(leaseToken=${command.leaseToken}, leaseExpiresAt=${command.leaseExpiresAt})',
      );
    }

    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final existing = _commands[command.commandId];

    if (existing == null) {
      _commands[command.commandId] = command.copyWith(
        createdAt: command.createdAt.toUtc(),
        nextAttemptAt: command.nextAttemptAt?.toUtc(),
        leaseToken: null,
        leaseExpiresAt: null,
      );
      return;
    }

    // HIGH 1: Existing command identity must be immutable
    final isSameIdentity =
        existing.operation == command.operation &&
        existing.familyId == command.familyId &&
        existing.childId == command.childId &&
        existing.rewardId == command.rewardId &&
        existing.redemptionId == command.redemptionId &&
        existing.cancellationReason == command.cancellationReason &&
        existing.actorUserId == command.actorUserId &&
        existing.actorRole == command.actorRole;

    if (!isSameIdentity) {
      throw StateError(
        'Cannot mutate immutable identity fields of existing pending command ${command.commandId}',
      );
    }

    // Active lease protection
    final hasActiveLease =
        existing.leaseToken != null &&
        existing.leaseExpiresAt != null &&
        existing.leaseExpiresAt!.isAfter(effectiveNow);
    if (hasActiveLease) {
      throw StateError(
        'Cannot overwrite pending command ${command.commandId}: held by an active lease',
      );
    }

    // MEDIUM: Malformed lease check (fail closed on malformed existing lease)
    final isMalformedLease =
        (existing.leaseToken != null && existing.leaseExpiresAt == null) ||
        (existing.leaseToken == null && existing.leaseExpiresAt != null);
    if (isMalformedLease) {
      throw StateError(
        'Cannot overwrite pending command ${command.commandId}: existing lease is malformed',
      );
    }

    // HIGH 2: Irreversible dispatch provenance & legacy quarantine checks
    if (existing.dispatchState == CommandDispatchState.unknownLegacy) {
      throw StateError(
        'Cannot overwrite pending command ${command.commandId}: record is quarantined as unknown_legacy',
      );
    }
    if (existing.dispatchState == CommandDispatchState.confirmedCommitted) {
      throw StateError(
        'Cannot overwrite pending command ${command.commandId}: record is already confirmed_committed',
      );
    }
    if (existing.recoveryState ==
        CommandRecoveryState.quarantinedUnknownOutcome) {
      throw StateError(
        'Cannot overwrite pending command ${command.commandId}: record is quarantined',
      );
    }
    if (existing.recoveryState == CommandRecoveryState.pendingOriginalActor) {
      throw StateError(
        'Cannot overwrite pending command ${command.commandId}: record is paused for original actor',
      );
    }
    if (existing.recoveryState == CommandRecoveryState.terminalError) {
      throw StateError(
        'Cannot overwrite pending command ${command.commandId}: record is in terminal_error',
      );
    }

    // Allowed forward transition:
    // If possibly_dispatched, never regress to never_dispatched.
    final updatedDispatchState =
        existing.dispatchState == CommandDispatchState.possiblyDispatched
        ? CommandDispatchState.possiblyDispatched
        : command.dispatchState;

    _commands[command.commandId] = existing.copyWith(
      dispatchState: updatedDispatchState,
      nextAttemptAt: command.nextAttemptAt?.toUtc() ?? existing.nextAttemptAt,
      lastErrorMessage: command.lastErrorMessage ?? existing.lastErrorMessage,
      leaseToken: null,
      leaseExpiresAt: null,
    );
  }

  @override
  Future<PendingRewardCommand?> getPendingCommand(String commandId) async {
    return _commands[commandId];
  }

  @override
  Future<PendingRewardCommand?> findPendingSpinCommand({
    required String familyId,
    required String childId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == RewardCommandOperation.spinWheel &&
          cmd.familyId == familyId &&
          cmd.childId == childId &&
          (recoveryState == null || cmd.recoveryState == recoveryState) &&
          (actorUserId == null || cmd.actorUserId == actorUserId)) {
        return cmd;
      }
    }
    return null;
  }

  @override
  Future<PendingRewardCommand?> findPendingRedeemCommand({
    required String familyId,
    required String childId,
    required String rewardId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == RewardCommandOperation.redeemReward &&
          cmd.familyId == familyId &&
          cmd.childId == childId &&
          cmd.rewardId == rewardId &&
          (recoveryState == null || cmd.recoveryState == recoveryState) &&
          (actorUserId == null || cmd.actorUserId == actorUserId)) {
        return cmd;
      }
    }
    return null;
  }

  @override
  Future<PendingRewardCommand?> findPendingRedemptionCommand({
    required RewardCommandOperation operation,
    required String redemptionId,
    CommandRecoveryState? recoveryState = CommandRecoveryState.active,
    String? actorUserId,
  }) async {
    for (final cmd in _commands.values.toList().reversed) {
      if (cmd.operation == operation &&
          cmd.redemptionId == redemptionId &&
          (recoveryState == null || cmd.recoveryState == recoveryState) &&
          (actorUserId == null || cmd.actorUserId == actorUserId)) {
        return cmd;
      }
    }
    return null;
  }

  @override
  Future<List<PendingRewardCommand>> listPendingCommands({
    String? familyId,
    String? childId,
    CommandRecoveryState? recoveryState,
    CommandDispatchState? dispatchState,
  }) async {
    final list = _commands.values.where((cmd) {
      if (familyId != null && cmd.familyId != familyId) return false;
      if (childId != null && cmd.childId != childId) return false;
      if (recoveryState != null && cmd.recoveryState != recoveryState) {
        return false;
      }
      if (dispatchState != null && cmd.dispatchState != dispatchState) {
        return false;
      }
      return true;
    }).toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<void> deletePendingCommand(String commandId) async {
    final cmd = _commands[commandId];
    if (cmd == null) return;
    if (cmd.leaseToken == null && cmd.leaseExpiresAt == null) {
      _commands.remove(commandId);
    }
  }

  // ---------------------------------------------------------------------------
  // PHASE 6 SLICE 4A-0: ATOMIC CAS STORE OPERATIONS & FENCING
  // ---------------------------------------------------------------------------

  @override
  Future<String?> acquireClaim({
    required String commandId,
    required String actorUserId,
    required Duration leaseDuration,
    DateTime? now,
    String? overrideLeaseToken,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final cmd = _commands[commandId];
    if (cmd == null) return null;

    if (cmd.actorUserId != actorUserId) return null;
    if (cmd.recoveryState != CommandRecoveryState.active) return null;
    if (cmd.operation != RewardCommandOperation.spinWheel &&
        cmd.operation != RewardCommandOperation.redeemReward) {
      return null;
    }
    if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
        cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
      return null;
    }
    if (cmd.nextAttemptAt != null && cmd.nextAttemptAt!.isAfter(effectiveNow)) {
      return null;
    }
    if (!_isLeaseAvailable(cmd, effectiveNow)) {
      return null;
    }

    final newLeaseToken = overrideLeaseToken ?? _generateLeaseToken();
    final leaseExpiresAt = effectiveNow.add(leaseDuration);

    _commands[commandId] = cmd.copyWith(
      leaseToken: newLeaseToken,
      leaseExpiresAt: leaseExpiresAt,
    );
    return newLeaseToken;
  }

  @override
  Future<bool> releaseClaim({
    required String commandId,
    required String leaseToken,
    required DateTime nextAttemptAt,
    String? lastErrorMessage,
  }) async {
    final cmd = _commands[commandId];
    if (cmd == null) return false;
    if (cmd.leaseToken != leaseToken) return false;

    _commands[commandId] = cmd.copyWith(
      retryCount: cmd.retryCount + 1,
      nextAttemptAt: nextAttemptAt.toUtc(),
      lastErrorMessage: lastErrorMessage,
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return true;
  }

  @override
  Future<bool> markPossiblyDispatched({
    required String commandId,
    required String leaseToken,
    required String authenticatedActorId,
    required DateTime now,
  }) async {
    final effectiveNow = now.toUtc();
    final cmd = _commands[commandId];
    if (cmd == null) return false;
    if (cmd.leaseToken != leaseToken) return false;
    if (cmd.leaseExpiresAt == null ||
        !cmd.leaseExpiresAt!.isAfter(effectiveNow)) {
      return false;
    }
    if (cmd.actorUserId != authenticatedActorId) return false;
    if (cmd.recoveryState != CommandRecoveryState.active) return false;
    if (cmd.operation != RewardCommandOperation.spinWheel &&
        cmd.operation != RewardCommandOperation.redeemReward) {
      return false;
    }
    if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
        cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
      return false;
    }

    _commands[commandId] = cmd.copyWith(
      dispatchState: CommandDispatchState.possiblyDispatched,
    );
    return true;
  }

  @override
  Future<bool> completeCommand({
    required String commandId,
    required String leaseToken,
  }) async {
    final cmd = _commands[commandId];
    if (cmd == null) return false;
    if (cmd.leaseToken != leaseToken) return false;

    _commands.remove(commandId);
    return true;
  }

  @override
  Future<bool> transitionRecoveryState({
    required String commandId,
    required String leaseToken,
    required CommandRecoveryState newState,
    String? lastErrorMessage,
  }) async {
    final cmd = _commands[commandId];
    if (cmd == null) return false;
    if (cmd.leaseToken != leaseToken) return false;

    _commands[commandId] = cmd.copyWith(
      recoveryState: newState,
      lastErrorMessage: lastErrorMessage,
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return true;
  }

  @override
  Future<bool> pauseMismatchedActorCommand({
    required String commandId,
    required String familyId,
    required String authenticatedActorId,
    String? mismatchReason,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final cmd = _commands[commandId];
    if (cmd == null) return false;

    if (cmd.familyId != familyId) return false;
    if (cmd.actorUserId == null || cmd.actorUserId == authenticatedActorId) {
      return false;
    }
    if (cmd.recoveryState != CommandRecoveryState.active) return false;
    if (cmd.operation != RewardCommandOperation.spinWheel &&
        cmd.operation != RewardCommandOperation.redeemReward) {
      return false;
    }
    if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
        cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
      return false;
    }
    if (!_isLeaseAvailable(cmd, effectiveNow)) {
      return false;
    }

    _commands[commandId] = cmd.copyWith(
      recoveryState: CommandRecoveryState.pendingOriginalActor,
      lastErrorMessage: mismatchReason,
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return true;
  }

  @override
  Future<bool> resumeOriginalActorCommand({
    required String commandId,
    required String familyId,
    required String authenticatedActorId,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final cmd = _commands[commandId];
    if (cmd == null) return false;

    if (cmd.familyId != familyId) return false;
    if (cmd.actorUserId != authenticatedActorId) return false;
    if (cmd.recoveryState != CommandRecoveryState.pendingOriginalActor) {
      return false;
    }
    if (cmd.operation != RewardCommandOperation.spinWheel &&
        cmd.operation != RewardCommandOperation.redeemReward) {
      return false;
    }
    if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
        cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
      return false;
    }
    if (!_isLeaseAvailable(cmd, effectiveNow)) {
      return false;
    }

    _commands[commandId] = cmd.copyWith(
      recoveryState: CommandRecoveryState.active,
      lastErrorMessage: null,
      leaseToken: null,
      leaseExpiresAt: null,
    );
    return true;
  }

  @override
  Future<List<PendingRewardCommand>> listClaimableCommands({
    required String actorUserId,
    required int limit,
    DateTime? now,
    String? familyId,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final list = _commands.values.where((cmd) {
      if (familyId != null && cmd.familyId != familyId) return false;
      if (cmd.actorUserId != actorUserId) return false;
      if (cmd.recoveryState != CommandRecoveryState.active) return false;
      if (cmd.operation != RewardCommandOperation.spinWheel &&
          cmd.operation != RewardCommandOperation.redeemReward) {
        return false;
      }
      if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
          cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
        return false;
      }
      if (cmd.nextAttemptAt != null &&
          cmd.nextAttemptAt!.isAfter(effectiveNow)) {
        return false;
      }
      if (!_isLeaseAvailable(cmd, effectiveNow)) {
        return false;
      }
      return true;
    }).toList();

    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<PendingRewardCommand>> listMismatchedActiveCommands({
    required String familyId,
    required String authenticatedActorId,
    required int limit,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final list = _commands.values.where((cmd) {
      if (cmd.familyId != familyId) return false;
      if (cmd.actorUserId == null || cmd.actorUserId == authenticatedActorId) {
        return false;
      }
      if (cmd.recoveryState != CommandRecoveryState.active) return false;
      if (cmd.operation != RewardCommandOperation.spinWheel &&
          cmd.operation != RewardCommandOperation.redeemReward) {
        return false;
      }
      if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
          cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
        return false;
      }
      if (!_isLeaseAvailable(cmd, effectiveNow)) {
        return false;
      }
      return true;
    }).toList();

    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list.take(limit).toList();
  }

  @override
  Future<List<PendingRewardCommand>> listPausedOriginalActorCommands({
    required String familyId,
    required String authenticatedActorId,
    required int limit,
    DateTime? now,
  }) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final list = _commands.values.where((cmd) {
      if (cmd.familyId != familyId) return false;
      if (cmd.actorUserId != authenticatedActorId) return false;
      if (cmd.recoveryState != CommandRecoveryState.pendingOriginalActor) {
        return false;
      }
      if (cmd.operation != RewardCommandOperation.spinWheel &&
          cmd.operation != RewardCommandOperation.redeemReward) {
        return false;
      }
      if (cmd.dispatchState != CommandDispatchState.neverDispatched &&
          cmd.dispatchState != CommandDispatchState.possiblyDispatched) {
        return false;
      }
      if (!_isLeaseAvailable(cmd, effectiveNow)) {
        return false;
      }
      return true;
    }).toList();

    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list.take(limit).toList();
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

/// Lightweight in-memory fallback for [WheelRepository] when Supabase
/// credentials are not configured in local development.
final class InMemoryWheelRepository implements WheelRepository {
  InMemoryWheelRepository({this.rewardRepository, this.growthRepository});

  final InMemoryRewardRepository? rewardRepository;
  final InMemoryGrowthRepository? growthRepository;

  final Map<String, WheelSettings> _settings = {};
  final List<WheelSpin> _spins = [];
  final Map<String, WheelSpinResult> _receipts = {};

  @override
  Future<WheelSettings> getWheelSettings({required FamilyId familyId}) async {
    final existing = _settings[familyId.value];
    if (existing != null) return existing;
    final now = DateTime.now().toUtc();
    final defaultSettings = WheelSettings(
      familyId: familyId,
      createdAt: now,
      updatedAt: now,
    );
    _settings[familyId.value] = defaultSettings;
    return defaultSettings;
  }

  @override
  Future<WheelSettings> updateWheelSettings(WheelSettings settings) async {
    _settings[settings.familyId.value] = settings;
    return settings;
  }

  @override
  Future<List<Reward>> listWheelRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) async {
    if (rewardRepository == null) return [];
    final rewards = await rewardRepository!.listFamilyRewards(
      familyId: familyId,
      activeOnly: true,
    );
    return rewards.where((r) {
      if (!r.wheelEnabled || r.wheelTier == null) return false;
      if (childId != null && !r.isEligibleFor(childId)) return false;
      return true;
    }).toList();
  }

  @override
  Future<int> getTodaySpinCount({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    final now = DateTime.now().toUtc();
    final todayStart = DateTime.utc(now.year, now.month, now.day);
    final tomorrowStart = todayStart.add(const Duration(days: 1));

    return _spins.where((s) {
      return s.familyId == familyId &&
          s.childId == childId &&
          s.createdAt.isAfter(
            todayStart.subtract(const Duration(milliseconds: 1)),
          ) &&
          s.createdAt.isBefore(tomorrowStart);
    }).length;
  }

  @override
  Future<WheelStatus> getWheelStatus({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    final settings = await getWheelSettings(familyId: familyId);
    final spinsToday = await getTodaySpinCount(
      familyId: familyId,
      childId: childId,
    );
    final eligibleRewards = await listWheelRewards(
      familyId: familyId,
      childId: childId,
    );
    final now = DateTime.now().toUtc();
    final todayStart = DateTime.utc(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));

    return WheelStatus(
      familyId: familyId,
      childId: childId,
      spinCostMinor: settings.spinCostMinor,
      dailySpinCap: settings.dailySpinCap,
      isEnabled: settings.isEnabled,
      spinsToday: spinsToday,
      spinsRemaining: (settings.dailySpinCap - spinsToday).clamp(0, 5),
      eligibleRewardCount: eligibleRewards.length,
      localDayStart: todayStart,
      localDayEnd: todayEnd,
    );
  }

  @override
  Future<List<WheelSpin>> listWheelSpins({
    required FamilyId familyId,
    ChildId? childId,
    int? limit,
  }) async {
    final list = _spins.where((s) {
      if (s.familyId != familyId) return false;
      if (childId != null && s.childId != childId) return false;
      return true;
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (limit != null && list.length > limit) {
      return list.sublist(0, limit);
    }
    return list;
  }

  @override
  Future<WheelSpinResult> spinRewardWheel({
    required String commandId,
    required ChildId childId,
  }) async {
    final existing = _receipts[commandId];
    if (existing != null) return existing;

    final rewards =
        rewardRepository?._rewards.values
            .where(
              (r) =>
                  r.isActive &&
                  r.wheelEnabled &&
                  r.wheelTier != null &&
                  r.isEligibleFor(childId),
            )
            .toList() ??
        [];

    if (rewards.isEmpty) {
      throw const InvalidWheelException('No rewards available in wheel pool');
    }

    final familyId = rewards.first.familyId;
    final settings = await getWheelSettings(familyId: familyId);

    if (!settings.isEnabled) {
      throw const InvalidWheelException(
        'Wheel is currently disabled for this family (LW206)',
      );
    }

    if (rewards.length < 3) {
      throw InvalidWheelException(
        'Wheel requires at least 3 active eligible rewards (LW203). Found: ${rewards.length}',
      );
    }

    if (growthRepository != null) {
      final balance = await growthRepository!.getChildBalance(childId);
      final currentMinor = balance?.rpBalanceMinor.value ?? 0;
      if (currentMinor < settings.spinCostMinor) {
        throw const InvalidWheelException('Insufficient RP balance (LW201)');
      }
    }

    final todaySpins = await getTodaySpinCount(
      familyId: familyId,
      childId: childId,
    );
    if (todaySpins >= settings.dailySpinCap) {
      throw InvalidWheelException(
        'Daily spin limit reached ($todaySpins/${settings.dailySpinCap}) (LW202)',
      );
    }

    rewards.sort((a, b) => a.id.value.compareTo(b.id.value));
    final totalWeight = rewards.fold<int>(
      0,
      (sum, r) => sum + r.wheelTier!.relativeWeight,
    );
    const draw = 0;
    int cumulative = 0;
    Reward? winner;
    final List<WheelPoolItem> poolItems = [];

    for (final r in rewards) {
      final w = r.wheelTier!.relativeWeight;
      final start = cumulative;
      final end = cumulative + w;
      final pct = double.parse(((w / totalWeight) * 100.0).toStringAsFixed(2));

      poolItems.add(
        WheelPoolItem(
          rewardId: r.id,
          title: r.title,
          category: r.category,
          iconKey: r.iconKey,
          tier: r.wheelTier!,
          weight: w,
          intervalStart: start,
          intervalEnd: end,
          probabilityPct: pct,
        ),
      );

      if (winner == null && draw >= start && draw < end) {
        winner = r;
      }
      cumulative = end;
    }
    winner ??= rewards.first;

    final now = DateTime.now().toUtc();
    final spinId = WheelSpinId('spin-${_spins.length + 1}');
    final redemptionId = RewardRedemptionId('redemp-${_spins.length + 1}');

    final snapshot = WheelSelectionSnapshot(
      wheelConfigVersion: 'wheel-v0.1',
      spinCostMinor: settings.spinCostMinor,
      deterministicOrdering: 'reward_id_asc',
      totalWeight: totalWeight,
      randomDraw: draw,
      winningRewardId: winner.id,
      orderedPool: poolItems,
    );

    final spin = WheelSpin(
      id: spinId,
      familyId: familyId,
      childId: childId,
      rewardId: winner.id,
      redemptionId: redemptionId,
      origin: RewardOrigin.wheel,
      spinCostMinor: settings.spinCostMinor,
      selectionSnapshot: snapshot,
      createdAt: now,
    );
    _spins.add(spin);

    int newBalanceMinor = 0;
    if (growthRepository != null) {
      final balance = await growthRepository!.getChildBalance(childId);
      final currentMinor = balance?.rpBalanceMinor.value ?? 0;
      newBalanceMinor = currentMinor - settings.spinCostMinor;
      growthRepository!._balancesByChild[childId.value] = ChildBalance(
        familyId: familyId,
        childId: childId,
        xpTotal: balance?.xpTotal ?? const XpAmount(0),
        rpBalanceMinor: RpMinor(newBalanceMinor),
        updatedAt: now,
      );
    }

    if (rewardRepository != null) {
      rewardRepository!._redemptions[redemptionId.value] = RewardRedemption(
        id: redemptionId,
        familyId: familyId,
        childId: childId,
        rewardId: winner.id,
        origin: RewardOrigin.wheel,
        rpCostMinor: settings.spinCostMinor,
        status: RewardRedemptionStatus.pendingFulfillment,
        rewardSnapshot: {
          'title': winner.title,
          'category': winner.category.value,
          'icon_key': winner.iconKey,
          'wheel_tier': winner.wheelTier!.value,
        },
        createdAt: now,
        updatedAt: now,
      );
    }

    final result = WheelSpinResult(
      spinId: spinId,
      redemptionId: redemptionId,
      familyId: familyId,
      childId: childId,
      rewardId: winner.id,
      rewardTitle: winner.title,
      rewardCategory: winner.category,
      rewardIconKey: winner.iconKey,
      wheelTier: winner.wheelTier!,
      spinCostMinor: settings.spinCostMinor,
      newBalanceMinor: newBalanceMinor,
      selectionSnapshot: snapshot,
      createdAt: now,
    );

    _receipts[commandId] = result;
    return result;
  }
}

/// Lightweight in-memory fallback for [LearningRepository] when Supabase
/// credentials are not configured in local development.
final class InMemoryLearningRepository implements LearningRepository {
  InMemoryLearningRepository({
    List<LearningNode>? initialNodes,
    List<LearningPrerequisite>? initialPrerequisites,
    this.clock,
    this.childProfileRepository,
    this.defaultSchoolGrade = 2,
  }) {
    if (initialNodes != null) {
      _nodes.addAll(initialNodes);
    } else {
      _seedPilotCatalog();
    }
    if (initialPrerequisites != null) {
      _prerequisites
        ..clear()
        ..addAll(initialPrerequisites);
    }
  }

  final InMemoryChildProfileRepository? childProfileRepository;
  final List<LearningNode> _nodes = [];
  final List<LearningPrerequisite> _prerequisites = [];
  final Map<String, List<AssessmentLearningMapping>> _mappings = {};
  final List<LearningEvidenceEvent> _evidence = [];
  final Map<String, ChildMasteryState> _masteryStates = {};
  final Map<String, int?> _childSchoolGrades = {};
  final Map<String, Map<String, dynamic>> _receipts = {};
  String _activeCatalogVersion = 'pilot-v0.1';
  final DateTime Function()? clock;
  int? defaultSchoolGrade;

  DateTime _nowUtc() => (clock != null ? clock!() : DateTime.now()).toUtc();

  void _seedPilotCatalog() {
    const subjects = <(String, String, int)>[
      ('math', 'Mathematics', 1),
      ('english', 'English Language Arts', 2),
      ('literature', 'Literature & Reading', 3),
      ('science', 'Science', 4),
      ('other', 'Other Subjects', 5),
    ];
    for (final (key, title, sortOrder) in subjects) {
      _nodes.add(
        LearningNode(
          id: LearningNodeId('node-root-$key'),
          catalogVersion: 'pilot-v0.1',
          nodeType: LearningNodeType.subject,
          subjectKey: key,
          canonicalKey: 'pilot-v0.1:subject:$key',
          title: title,
          sortOrder: sortOrder,
        ),
      );
    }

    _nodes.addAll([
      LearningNode(
        id: LearningNodeId('b0000001-0000-0000-0000-000000000001'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.domain,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic',
        title: 'Arithmetic & Numbers',
        parentId: LearningNodeId('node-root-math'),
        gradeMin: 1,
        gradeMax: 6,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.topic,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic:addition',
        title: 'Addition Operations',
        parentId: LearningNodeId('b0000001-0000-0000-0000-000000000001'),
        gradeMin: 1,
        gradeMax: 4,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000003-0000-0000-0000-000000000001'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic:addition:single_digit',
        title: 'Single Digit Addition',
        parentId: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
        gradeMin: 1,
        gradeMax: 2,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000003-0000-0000-0000-000000000002'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.skill,
        subjectKey: 'math',
        canonicalKey: 'pilot-v0.1:math:arithmetic:addition:double_digit',
        title: 'Double Digit Addition',
        parentId: LearningNodeId('b0000002-0000-0000-0000-000000000001'),
        gradeMin: 2,
        gradeMax: 4,
        sortOrder: 2,
      ),
      LearningNode(
        id: LearningNodeId('b0000001-0000-0000-0000-000000000002'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.domain,
        subjectKey: 'english',
        canonicalKey: 'pilot-v0.1:english:grammar',
        title: 'Grammar & Mechanics',
        parentId: LearningNodeId('node-root-english'),
        gradeMin: 1,
        gradeMax: 8,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000002-0000-0000-0000-000000000002'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.topic,
        subjectKey: 'english',
        canonicalKey: 'pilot-v0.1:english:grammar:punctuation',
        title: 'Punctuation',
        parentId: LearningNodeId('b0000001-0000-0000-0000-000000000002'),
        gradeMin: 1,
        gradeMax: 5,
        sortOrder: 1,
      ),
      LearningNode(
        id: LearningNodeId('b0000003-0000-0000-0000-000000000003'),
        catalogVersion: 'pilot-v0.1',
        nodeType: LearningNodeType.skill,
        subjectKey: 'english',
        canonicalKey: 'pilot-v0.1:english:grammar:punctuation:end_marks',
        title: 'End Punctuation Marks',
        parentId: LearningNodeId('b0000002-0000-0000-0000-000000000002'),
        gradeMin: 1,
        gradeMax: 3,
        sortOrder: 1,
      ),
    ]);

    _prerequisites.add(
      LearningPrerequisite(
        catalogVersion: 'pilot-v0.1',
        subjectKey: 'math',
        prerequisiteNodeId: LearningNodeId(
          'b0000003-0000-0000-0000-000000000001',
        ),
        dependentNodeId: LearningNodeId('b0000003-0000-0000-0000-000000000002'),
      ),
    );
  }

  void setActiveCatalogVersion(String version) {
    _activeCatalogVersion = version;
  }

  void addNode(LearningNode node) => _nodes.add(node);
  void addPrerequisite(LearningPrerequisite prerequisite) =>
      _prerequisites.add(prerequisite);
  void addEvidence(LearningEvidenceEvent event) => _evidence.add(event);

  void setMasteryState(ChildMasteryState state) {
    _masteryStates['${state.childId.value}:${state.learningNodeId.value}'] =
        state;
  }

  void setChildSchoolGrade(ChildId childId, int? schoolGrade) {
    _childSchoolGrades[childId.value] = schoolGrade;
  }

  int? _resolveSchoolGrade(ChildId childId) {
    if (_childSchoolGrades.containsKey(childId.value)) {
      return _childSchoolGrades[childId.value];
    }
    if (childProfileRepository != null) {
      for (final child in childProfileRepository!.children) {
        if (child.id == childId) {
          return child.schoolGrade;
        }
      }
    }
    return defaultSchoolGrade;
  }

  List<ChildMasteryState> _resolveMasteryStates(
    ChildId childId,
    DateTime asOf,
  ) {
    final byNodeId = <String, ChildMasteryState>{};
    for (final entry in _masteryStates.entries) {
      if (entry.value.childId == childId) {
        byNodeId[entry.value.learningNodeId.value] = entry.value;
      }
    }

    final childEvidence = _evidence.where((e) => e.childId == childId).toList();
    final evidenceNodeIds = childEvidence.map((e) => e.learningNodeId).toSet();

    for (final nodeId in evidenceNodeIds) {
      if (byNodeId.containsKey(nodeId.value)) continue;
      final nodeEv = childEvidence
          .where((e) => e.learningNodeId == nodeId)
          .toList();
      final rebuild = MasteryEngine.rebuildNodeMastery(nodeEv);
      final conf = ConfidenceEngine.evaluate(
        masteryScore: rebuild.masteryScore,
        evidence: nodeEv,
        asOf: asOf,
      );
      final sorted = MasteryEngine.sortCanonical(nodeEv);
      byNodeId[nodeId.value] = ChildMasteryState(
        familyId: sorted.first.familyId,
        childId: childId,
        learningNodeId: nodeId,
        engineVersion: 'mastery-v0.1',
        masteryScore: rebuild.masteryScore,
        effectiveEvidenceCount: rebuild.effectiveEvidenceCount,
        distinctAssessmentCount: rebuild.distinctAssessmentCount,
        lastEvidenceEventId: sorted.last.id,
        lastEvidenceOccurredAt: sorted.last.effectiveOccurredAt,
        masteryAttainedAt:
            rebuild.masteryScore >= 85.0 &&
                conf.confidenceBand == ConfidenceBand.high
            ? asOf
            : null,
        updatedAt: asOf,
      );
    }

    return byNodeId.values.toList();
  }

  @override
  Future<List<LearningNode>> getCatalogNodes({
    required String catalogVersion,
    String? subjectKey,
  }) async {
    return _nodes.where((n) {
      if (n.catalogVersion != catalogVersion) return false;
      if (subjectKey != null && n.subjectKey != subjectKey) return false;
      return true;
    }).toList();
  }

  @override
  Future<List<AssessmentLearningMapping>> getAssessmentLearningMappings(
    AssessmentId assessmentId,
  ) async {
    return _mappings[assessmentId.value] ?? [];
  }

  @override
  Future<List<AssessmentLearningMapping>> setAssessmentLearningMappings({
    required AssessmentId assessmentId,
    required List<AssessmentLearningMapping> mappings,
  }) async {
    _mappings[assessmentId.value] = List.from(mappings);
    return _mappings[assessmentId.value]!;
  }

  @override
  Future<Map<String, dynamic>> processLearningEvent({
    required String commandId,
    required String verifiedLearningEventId,
  }) async {
    final existing = _receipts[commandId];
    if (existing != null) return existing;

    final result = <String, dynamic>{
      'command_id': commandId,
      'verified_learning_event_id': verifiedLearningEventId,
      'status': 'completed',
    };
    _receipts[commandId] = result;
    return result;
  }

  @override
  Future<Map<String, dynamic>> catchUpUnprocessedLearning(
    FamilyId familyId,
  ) async {
    return {
      'family_id': familyId.value,
      'processed_count': 0,
      'status': 'completed',
    };
  }

  @override
  Future<List<ChildMasteryProjection>> getChildMastery({
    required ChildId childId,
  }) async {
    final effectiveAsOf = _nowUtc();
    final states = _resolveMasteryStates(childId, effectiveAsOf);
    final childEvidence = _evidence.where((e) => e.childId == childId).toList();

    final projections = <ChildMasteryProjection>[];

    for (final state in states) {
      final node = _nodes.firstWhere(
        (n) => n.id == state.learningNodeId,
        orElse: () => LearningNode(
          id: state.learningNodeId,
          catalogVersion: _activeCatalogVersion,
          nodeType: LearningNodeType.skill,
          subjectKey: 'math',
          canonicalKey: 'custom:${state.learningNodeId.value}',
          title: 'Custom Node',
        ),
      );
      if (node.catalogVersion != _activeCatalogVersion || !node.isActive) {
        continue;
      }

      final nodeEv = childEvidence
          .where((e) => e.learningNodeId == state.learningNodeId)
          .toList();
      final conf = ConfidenceEngine.evaluate(
        masteryScore: state.masteryScore,
        evidence: nodeEv,
        asOf: effectiveAsOf,
      );
      final band =
          NextChallengeEngine.evaluateAuthoritativeMasteryBand(
            isObserved: true,
            masteryScore: state.masteryScore,
            masteryAttainedAt: state.masteryAttainedAt,
            asOf: effectiveAsOf,
          ) ??
          MasteryBand.noData;

      projections.add(
        ChildMasteryProjection(
          childId: childId,
          learningNodeId: state.learningNodeId,
          nodeCanonicalKey: node.canonicalKey,
          nodeTitle: node.title,
          nodeType: node.nodeType,
          subjectKey: node.subjectKey,
          masteryScore: state.masteryScore,
          distinctAssessmentCount: state.distinctAssessmentCount,
          lastEvidenceOccurredAt: state.lastEvidenceOccurredAt,
          masteryAttainedAt: state.masteryAttainedAt,
          confidenceBand: conf.confidenceBand,
          confidenceUnits: conf.confidenceUnits,
          masteryBand: band,
          asOf: effectiveAsOf,
          updatedAt: state.updatedAt,
        ),
      );
    }

    return projections;
  }

  @override
  Future<LearningOverview> getChildLearningOverview({
    required ChildId childId,
  }) async {
    final effectiveAsOf = _nowUtc();
    return NextChallengeEngine.buildOverview(
      childId: childId,
      schoolGrade: _resolveSchoolGrade(childId),
      activeCatalogVersion: _activeCatalogVersion,
      catalogNodes: _nodes,
      prerequisites: _prerequisites,
      masteryStates: _resolveMasteryStates(childId, effectiveAsOf),
      evidenceEvents: _evidence.where((e) => e.childId == childId),
      asOf: effectiveAsOf,
    );
  }

  @override
  Future<LearningNodeState> getNodeLearningState({
    required ChildId childId,
    required String learningNodeId,
  }) async {
    final effectiveAsOf = _nowUtc();
    return NextChallengeEngine.buildNodeState(
      childId: childId,
      learningNodeId: learningNodeId,
      schoolGrade: _resolveSchoolGrade(childId),
      activeCatalogVersion: _activeCatalogVersion,
      catalogNodes: _nodes,
      prerequisites: _prerequisites,
      masteryStates: _resolveMasteryStates(childId, effectiveAsOf),
      evidenceEvents: _evidence.where((e) => e.childId == childId),
      asOf: effectiveAsOf,
    );
  }

  @override
  Future<NextChallengeRecommendationSet> getNextChallengeCandidates({
    required ChildId childId,
    SubjectKey? subjectKey,
    int limit = 3,
  }) async {
    final effectiveAsOf = _nowUtc();
    return NextChallengeEngine.getNextChallengeCandidates(
      childId: childId,
      schoolGrade: _resolveSchoolGrade(childId),
      activeCatalogVersion: _activeCatalogVersion,
      catalogNodes: _nodes,
      prerequisites: _prerequisites,
      masteryStates: _resolveMasteryStates(childId, effectiveAsOf),
      evidenceEvents: _evidence.where((e) => e.childId == childId),
      asOf: effectiveAsOf,
      subjectKeyFilter: subjectKey?.value,
      limit: limit,
    );
  }
}

/// Lightweight in-memory fallback for [AuthSessionPort] in local development.
final class InMemoryAuthSessionPort implements AuthSessionPort {
  InMemoryAuthSessionPort({String? activeUserId, String? sessionGeneration})
    : _userId = activeUserId ?? 'local-parent-user',
      _generation = sessionGeneration ?? 'demo-generation-1';

  final String _userId;
  final String _generation;

  @override
  String? get currentSessionGeneration => _generation;

  @override
  Stream<String?> get sessionGenerationStream => Stream.value(_generation);

  @override
  Future<ValidatedActorContext?> validateForMutation() async {
    return ValidatedActorContext(
      userId: _userId,
      sessionGeneration: _generation,
      observedAt: DateTime.now().toUtc(),
      role: 'parent',
    );
  }
}

/// Lightweight in-memory fallback for [RecoveryAuthorizationPort] in local development.
final class InMemoryRecoveryAuthorizationPort
    implements RecoveryAuthorizationPort {
  const InMemoryRecoveryAuthorizationPort({
    this.defaultStatus = TargetAuthorizationStatus.authorized,
  });

  final TargetAuthorizationStatus defaultStatus;

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) async {
    return defaultStatus;
  }
}
