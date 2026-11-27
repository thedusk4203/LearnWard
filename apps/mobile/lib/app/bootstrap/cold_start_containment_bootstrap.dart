import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/family/presentation/create_family_screen.dart';
import '../../features/shared_device/domain/parent_gate_service.dart';
import '../../features/shared_device/presentation/parent_gate_dialog.dart';
import '../routing/app_routes.dart';
import 'app_providers.dart';

/// Legacy compatibility alias while all callers reference [SessionLifecycleController].
typedef ColdStartContainmentNotifier = SessionLifecycleController;

/// Strict FIFO async mutex protecting local SQLite containment & PIN CAS
/// operations (`D4` `_ContainmentArbiter`).
///
/// Heavy PBKDF2 derivation and remote Supabase verification MUST execute
/// OUTSIDE [_ContainmentArbiter] so auth transitions never queue behind KDF.
final class ContainmentArbiter {
  Completer<void>? _tail;

  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final next = Completer<void>();
    _tail = next;
    if (previous != null) {
      await previous.future;
    }
    try {
      return await action();
    } finally {
      if (identical(_tail, next)) {
        _tail = null;
      }
      if (!next.isCompleted) {
        next.complete();
      }
    }
  }
}

/// Actor-bound in-memory record for a newly created family awaiting positive
/// active adult verification (`R40-05`).
///
/// Bound strictly to the validated creator `actorUserId` and auth
/// `sessionGeneration`. Never persisted into cross-account local metadata, and
/// redacted in [toString] so `family.name` never leaks to logs.
final class PendingCreatedFamilyRecord {
  const PendingCreatedFamilyRecord({
    required this.family,
    required this.creatorActorUserId,
    required this.createdInSessionGeneration,
    required this.createdAtUtc,
  });

  final Family family;
  final String creatorActorUserId;
  final String createdInSessionGeneration;
  final DateTime createdAtUtc;

  bool matchesActor({
    required String? actorUserId,
    required String? sessionGeneration,
  }) {
    final trimmedActor = actorUserId?.trim();
    final trimmedGeneration = sessionGeneration?.trim();
    final boundCreator = creatorActorUserId.trim();
    final boundGeneration = createdInSessionGeneration.trim();
    if (trimmedActor == null ||
        trimmedActor.isEmpty ||
        trimmedGeneration == null ||
        trimmedGeneration.isEmpty ||
        boundCreator.isEmpty ||
        boundGeneration.isEmpty) {
      return false;
    }
    return trimmedActor == boundCreator &&
        trimmedGeneration == boundGeneration &&
        family.createdByUserId.trim() == boundCreator;
  }

  @override
  String toString() =>
      'PendingCreatedFamilyRecord(familyId: ${family.id.value}, '
      'creatorActorUserId: $creatorActorUserId, '
      'createdInSessionGeneration: $createdInSessionGeneration)';
}

/// Fail-closed containment state resolved before mounting protected routes.
enum ColdStartContainmentStatus {
  hydrating,
  unauthenticated,
  verifiedParentMode,
  verifiedChildMode,
  offlineContainedChildMode,
  containmentLocked,
  pairedChildRevoked,
  pairedChildUnverified,
  authorizationUnverified,
  adultAccessRestricted,
  noActiveFamilyMembership,
}

/// Immutable containment and lifecycle verification snapshot.
final class ColdStartContainmentState {
  const ColdStartContainmentState({
    required this.status,
    this.actorContext,
    this.verificationOutcome,
    this.persistedSessionResult,
    this.recoveryLockResult,
    this.verifiedFamily,
    this.verifiedChild,
    this.verifiedFamilies = const [],
    this.verifiedRolesByFamilyId = const {},
    this.parentGateCredentialStatus,
    this.pinOwnerFamilyId,
    this.legacyOwnershipResolution,
    this.containmentFence,
    this.lastRecoveryAudit,
    this.sessionScopeEpoch = 0,
    this.isPostSignOutFreshAdultAuth = false,
    this.needsPinReconfigurationAfterRecovery = false,
    this.diagnosticReason,
  });

  final ColdStartContainmentStatus status;
  final ValidatedActorContext? actorContext;
  final ContainmentVerificationOutcome? verificationOutcome;
  final PersistedChildModeParseResult? persistedSessionResult;
  final ContainmentRecoveryLockParseResult? recoveryLockResult;
  final Family? verifiedFamily;
  final ChildProfile? verifiedChild;
  final List<Family> verifiedFamilies;
  final Map<String, VerifiedAdultRole> verifiedRolesByFamilyId;
  final ParentGateCredentialStatus? parentGateCredentialStatus;
  final String? pinOwnerFamilyId;
  final LegacyOwnershipResolution? legacyOwnershipResolution;
  final ContainmentFenceV1? containmentFence;
  final LastContainmentRecoveryAuditV1? lastRecoveryAudit;
  final int sessionScopeEpoch;
  final bool isPostSignOutFreshAdultAuth;
  final bool needsPinReconfigurationAfterRecovery;
  final String? diagnosticReason;

  bool get isHydrating => status == ColdStartContainmentStatus.hydrating;

  bool get isActiveChildMode =>
      status == ColdStartContainmentStatus.verifiedChildMode ||
      status == ColdStartContainmentStatus.offlineContainedChildMode;

  bool get isPairedChildMode {
    final v2 = persistedSessionResult is ValidPersistedChildModeSessionV2
        ? (persistedSessionResult as ValidPersistedChildModeSessionV2).session
        : null;
    if (status == ColdStartContainmentStatus.verifiedChildMode &&
        verificationOutcome is AuthorizedPairedChild) {
      return true;
    }
    return v2?.modeKind == PersistedChildModeKind.pairedChildDevice;
  }

  bool get allowsProtectedUi =>
      status == ColdStartContainmentStatus.verifiedParentMode ||
      status == ColdStartContainmentStatus.verifiedChildMode ||
      status == ColdStartContainmentStatus.offlineContainedChildMode;

  bool get hasPositiveActiveAdultMembership =>
      verificationOutcome is AuthorizedActiveAdult ||
      verificationOutcome is AuthorizedAdultChildUnavailable;

  bool get allowsExitPathAPinAttempt {
    if (status == ColdStartContainmentStatus.verifiedChildMode) {
      return !isPairedChildMode &&
          (parentGateCredentialStatus == ParentGateCredentialStatus.validV2 ||
              parentGateCredentialStatus ==
                  ParentGateCredentialStatus.legacyV1);
    }
    if (status != ColdStartContainmentStatus.containmentLocked) {
      return false;
    }
    if (!hasPositiveActiveAdultMembership) {
      return false;
    }
    if (parentGateCredentialStatus == ParentGateCredentialStatus.validV2) {
      if (pinOwnerFamilyId != null) {
        return verifiedFamilies.any((f) => f.id.value == pinOwnerFamilyId);
      }
      final validV2 = persistedSessionResult is ValidPersistedChildModeSessionV2
          ? (persistedSessionResult as ValidPersistedChildModeSessionV2).session
          : null;
      if (validV2 != null) {
        return verifiedFamilies.any((f) => f.id == validV2.familyId);
      }
      final resolution = legacyOwnershipResolution;
      if (resolution is BoundOwnerResolution) {
        return verifiedFamilies.any(
          (f) => f.id.value == resolution.ownerFamilyId,
        );
      }
      if (resolution is CorroboratedLegacyOwnerResolution) {
        return verifiedFamilies.any((f) => f.id.value == resolution.familyId);
      }
      if (resolution is UnresolvableLegacyOwnershipResolution) {
        final hintedFamilyId = resolution.legacyChildHint?.familyId;
        return hintedFamilyId != null &&
            verifiedFamilies.any((f) => f.id.value == hintedFamilyId);
      }
      return false;
    }
    if (parentGateCredentialStatus == ParentGateCredentialStatus.legacyV1) {
      final resolution = legacyOwnershipResolution;
      if (resolution is BoundOwnerResolution) {
        return verifiedFamilies.any(
          (f) => f.id.value == resolution.ownerFamilyId,
        );
      }
      if (resolution is CorroboratedLegacyOwnerResolution) {
        return verifiedFamilies.any((f) => f.id.value == resolution.familyId);
      }
      if (resolution is UnresolvableLegacyOwnershipResolution) {
        final hintedFamilyId = resolution.legacyChildHint?.familyId;
        return hintedFamilyId != null &&
            verifiedFamilies.any((f) => f.id.value == hintedFamilyId);
      }
      return false;
    }
    return false;
  }

  bool get allowsManualUnboundLegacyRecovery {
    if (status != ColdStartContainmentStatus.containmentLocked) {
      return false;
    }
    if (!isPostSignOutFreshAdultAuth || !hasPositiveActiveAdultMembership) {
      return false;
    }
    if (verifiedFamilies.isEmpty) {
      return false;
    }
    if (parentGateCredentialStatus == ParentGateCredentialStatus.validV2 &&
        pinOwnerFamilyId != null) {
      return false;
    }
    final lock = recoveryLockResult is ValidContainmentRecoveryLockV1
        ? (recoveryLockResult as ValidContainmentRecoveryLockV1).lock
        : null;
    if (lock != null) {
      return lock.ownershipLevel ==
              ContainmentRecoveryOwnershipLevel.unresolvable &&
          legacyOwnershipResolution is UnresolvableLegacyOwnershipResolution;
    }
    return legacyOwnershipResolution is UnresolvableLegacyOwnershipResolution;
  }

  ColdStartContainmentState copyWith({
    ColdStartContainmentStatus? status,
    ValidatedActorContext? actorContext,
    ContainmentVerificationOutcome? verificationOutcome,
    PersistedChildModeParseResult? persistedSessionResult,
    ContainmentRecoveryLockParseResult? recoveryLockResult,
    Family? verifiedFamily,
    ChildProfile? verifiedChild,
    List<Family>? verifiedFamilies,
    Map<String, VerifiedAdultRole>? verifiedRolesByFamilyId,
    ParentGateCredentialStatus? parentGateCredentialStatus,
    String? pinOwnerFamilyId,
    LegacyOwnershipResolution? legacyOwnershipResolution,
    ContainmentFenceV1? containmentFence,
    LastContainmentRecoveryAuditV1? lastRecoveryAudit,
    int? sessionScopeEpoch,
    bool? isPostSignOutFreshAdultAuth,
    bool? needsPinReconfigurationAfterRecovery,
    String? diagnosticReason,
  }) {
    return ColdStartContainmentState(
      status: status ?? this.status,
      actorContext: actorContext ?? this.actorContext,
      verificationOutcome: verificationOutcome ?? this.verificationOutcome,
      persistedSessionResult:
          persistedSessionResult ?? this.persistedSessionResult,
      recoveryLockResult: recoveryLockResult ?? this.recoveryLockResult,
      verifiedFamily: verifiedFamily ?? this.verifiedFamily,
      verifiedChild: verifiedChild ?? this.verifiedChild,
      verifiedFamilies: verifiedFamilies ?? this.verifiedFamilies,
      verifiedRolesByFamilyId:
          verifiedRolesByFamilyId ?? this.verifiedRolesByFamilyId,
      parentGateCredentialStatus:
          parentGateCredentialStatus ?? this.parentGateCredentialStatus,
      pinOwnerFamilyId: pinOwnerFamilyId ?? this.pinOwnerFamilyId,
      legacyOwnershipResolution:
          legacyOwnershipResolution ?? this.legacyOwnershipResolution,
      containmentFence: containmentFence ?? this.containmentFence,
      lastRecoveryAudit: lastRecoveryAudit ?? this.lastRecoveryAudit,
      sessionScopeEpoch: sessionScopeEpoch ?? this.sessionScopeEpoch,
      isPostSignOutFreshAdultAuth:
          isPostSignOutFreshAdultAuth ?? this.isPostSignOutFreshAdultAuth,
      needsPinReconfigurationAfterRecovery:
          needsPinReconfigurationAfterRecovery ??
          this.needsPinReconfigurationAfterRecovery,
      diagnosticReason: diagnosticReason ?? this.diagnosticReason,
    );
  }

  @override
  String toString() =>
      'ColdStartContainmentState(status: ${status.name}, '
      'epoch: $sessionScopeEpoch, '
      'hasActor: ${actorContext != null}, '
      'hasVerifiedFamily: ${verifiedFamily != null}, '
      'hasVerifiedChild: ${verifiedChild != null}'
      '${diagnosticReason != null ? ', reason: $diagnosticReason' : ''})';
}

/// Evaluates whether an active persisted recovery lock qualifies for Exit Path B
/// automatic unlock (`D1.6`, `D4`, `R38-08`, `R38-09`, `R38-10`).
String? resolveAutoUnlockOwnerFamilyId({
  required ValidatedActorContext actorContext,
  required ContainmentRecoveryLockParseResult recoveryLockResult,
  required ContainmentVerificationOutcome verificationOutcome,
  required ParentGateCredentialStatus? parentGateCredentialStatus,
  required String? pinOwnerFamilyId,
}) {
  if (recoveryLockResult is! ValidContainmentRecoveryLockV1) {
    return null;
  }
  final lock = recoveryLockResult.lock;
  if (actorContext.isAnonymous || actorContext.role == 'child') {
    return null;
  }
  if (actorContext.sessionGeneration == lock.initiatedFromSessionGeneration) {
    return null;
  }
  if (lock.ownershipLevel != ContainmentRecoveryOwnershipLevel.boundV2 &&
      lock.ownershipLevel !=
          ContainmentRecoveryOwnershipLevel.corroboratedLegacy) {
    return null;
  }
  final requiredFamilyId = lock.requiredOwnerFamilyId?.trim();
  if (requiredFamilyId == null || requiredFamilyId.isEmpty) {
    return null;
  }
  if (parentGateCredentialStatus == ParentGateCredentialStatus.validV2 &&
      pinOwnerFamilyId != null &&
      pinOwnerFamilyId != requiredFamilyId) {
    return null;
  }
  final verifiedFamilies = switch (verificationOutcome) {
    AuthorizedActiveAdult(:final verifiedFamilies) => verifiedFamilies,
    AuthorizedAdultChildUnavailable(:final verifiedFamilies) =>
      verifiedFamilies,
    _ => const <Family>[],
  };
  if (!verifiedFamilies.any((f) => f.id.value == requiredFamilyId)) {
    return null;
  }
  return requiredFamilyId;
}

/// Pure deterministic resolution of cold-start containment from parsed local lock
/// metadata, validated live actor identity, PIN credential status, and the
/// authoritative 8-way [ContainmentVerificationOutcome] (`D2.4`, `R38-01`–`R38-09`).
ColdStartContainmentState resolveColdStartContainmentState({
  required ValidatedActorContext actorContext,
  required PersistedChildModeParseResult persistedSessionResult,
  required ContainmentRecoveryLockParseResult recoveryLockResult,
  required ContainmentVerificationOutcome verificationOutcome,
  ParentGateCredentialStatus? parentGateCredentialStatus,
  String? pinOwnerFamilyId,
  LegacyOwnershipResolution? legacyOwnershipResolution,
  ContainmentFenceV1? containmentFence,
  LastContainmentRecoveryAuditV1? lastRecoveryAudit,
  int sessionScopeEpoch = 0,
  bool isPostSignOutFreshAdultAuth = false,
  bool needsPinReconfigurationAfterRecovery = false,
}) {
  final validV2 = persistedSessionResult is ValidPersistedChildModeSessionV2
      ? persistedSessionResult.session
      : null;
  final hasRecoveryLock = recoveryLockResult is! AbsentContainmentRecoveryLock;
  final hasLegacyOrMalformed =
      persistedSessionResult is LegacyV1OrMalformedChildModeSession;
  final hasActorMismatch =
      validV2 != null && validV2.actorUserId != actorContext.userId;

  final verifiedFamilies = switch (verificationOutcome) {
    AuthorizedActiveAdult(:final verifiedFamilies) => verifiedFamilies,
    AuthorizedAdultChildUnavailable(:final verifiedFamilies) =>
      verifiedFamilies,
    _ => const <Family>[],
  };
  final verifiedRolesByFamilyId = switch (verificationOutcome) {
    AuthorizedActiveAdult(:final verifiedRolesByFamilyId) =>
      verifiedRolesByFamilyId,
    AuthorizedAdultChildUnavailable(:final verifiedRolesByFamilyId) =>
      verifiedRolesByFamilyId,
    _ => const <String, VerifiedAdultRole>{},
  };

  if (hasRecoveryLock || hasLegacyOrMalformed || hasActorMismatch) {
    // Paired child explicit grant revocation must surface /child/revoked when
    // there is no shared/adult lock, while NEVER clearing any adult recovery lock.
    if (verificationOutcome is ConfirmedPairedChildGrantRevoked &&
        !hasRecoveryLock &&
        validV2 != null &&
        validV2.modeKind == PersistedChildModeKind.pairedChildDevice) {
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.pairedChildRevoked,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        legacyOwnershipResolution: legacyOwnershipResolution,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        diagnosticReason: 'paired_child_grant_revoked',
      );
    }

    final reason = hasRecoveryLock
        ? 'unresolved_recovery_lock'
        : (hasLegacyOrMalformed
              ? 'legacy_or_malformed_child_session'
              : 'actor_mismatch_persisted_child_session');
    return ColdStartContainmentState(
      status: ColdStartContainmentStatus.containmentLocked,
      actorContext: actorContext,
      verificationOutcome: verificationOutcome,
      persistedSessionResult: persistedSessionResult,
      recoveryLockResult: recoveryLockResult,
      verifiedFamilies: verifiedFamilies,
      verifiedRolesByFamilyId: verifiedRolesByFamilyId,
      parentGateCredentialStatus: parentGateCredentialStatus,
      pinOwnerFamilyId: pinOwnerFamilyId,
      legacyOwnershipResolution: legacyOwnershipResolution,
      containmentFence: containmentFence,
      lastRecoveryAudit: lastRecoveryAudit,
      sessionScopeEpoch: sessionScopeEpoch,
      isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
      diagnosticReason: reason,
    );
  }

  final hasValidPinCredential =
      parentGateCredentialStatus == ParentGateCredentialStatus.validV2 ||
      parentGateCredentialStatus == ParentGateCredentialStatus.legacyV1;

  switch (verificationOutcome) {
    case AuthorizedActiveAdult(:final verifiedFamily, :final verifiedChild):
      if (validV2 != null) {
        final pinMatchesFamily =
            parentGateCredentialStatus != ParentGateCredentialStatus.validV2 ||
            pinOwnerFamilyId == null ||
            pinOwnerFamilyId == validV2.familyId.value;
        final childMatches =
            validV2.modeKind == PersistedChildModeKind.sharedDeviceAdult &&
            hasValidPinCredential &&
            pinMatchesFamily &&
            verifiedChild != null &&
            verifiedChild.id == validV2.childId &&
            verifiedChild.familyId == validV2.familyId &&
            verifiedChild.isActive &&
            !verifiedChild.isArchived;
        if (childMatches) {
          return ColdStartContainmentState(
            status: ColdStartContainmentStatus.verifiedChildMode,
            actorContext: actorContext,
            verificationOutcome: verificationOutcome,
            persistedSessionResult: persistedSessionResult,
            recoveryLockResult: recoveryLockResult,
            verifiedFamily: verifiedFamily,
            verifiedChild: verifiedChild,
            verifiedFamilies: verifiedFamilies,
            verifiedRolesByFamilyId: verifiedRolesByFamilyId,
            parentGateCredentialStatus: parentGateCredentialStatus,
            pinOwnerFamilyId: pinOwnerFamilyId,
            containmentFence: containmentFence,
            lastRecoveryAudit: lastRecoveryAudit,
            sessionScopeEpoch: sessionScopeEpoch,
            isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          );
        }
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.containmentLocked,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          verifiedFamilies: verifiedFamilies,
          verifiedRolesByFamilyId: verifiedRolesByFamilyId,
          parentGateCredentialStatus: parentGateCredentialStatus,
          pinOwnerFamilyId: pinOwnerFamilyId,
          containmentFence: containmentFence,
          lastRecoveryAudit: lastRecoveryAudit,
          sessionScopeEpoch: sessionScopeEpoch,
          isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          diagnosticReason: 'shared_child_mode_pin_or_target_invalid',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.verifiedParentMode,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        verifiedFamily: verifiedFamily,
        verifiedFamilies: verifiedFamilies,
        verifiedRolesByFamilyId: verifiedRolesByFamilyId,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        needsPinReconfigurationAfterRecovery:
            needsPinReconfigurationAfterRecovery,
      );

    case AuthorizedAdultChildUnavailable(:final reason):
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.containmentLocked,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        verifiedFamilies: verifiedFamilies,
        verifiedRolesByFamilyId: verifiedRolesByFamilyId,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        diagnosticReason: 'target_child_unavailable_${reason.name}',
      );

    case NoActiveFamilyMembershipObserved():
      if (validV2 != null) {
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.containmentLocked,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          parentGateCredentialStatus: parentGateCredentialStatus,
          pinOwnerFamilyId: pinOwnerFamilyId,
          containmentFence: containmentFence,
          lastRecoveryAudit: lastRecoveryAudit,
          sessionScopeEpoch: sessionScopeEpoch,
          isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          diagnosticReason: 'no_active_family_while_child_session_persisted',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.noActiveFamilyMembership,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        diagnosticReason: 'no_active_family_membership_observed',
      );

    case AuthorizedPairedChild(:final verifiedChild, :final verifiedFamily):
      if (validV2 != null &&
          (validV2.modeKind != PersistedChildModeKind.pairedChildDevice ||
              validV2.childId != verifiedChild.id ||
              validV2.familyId != verifiedFamily.id)) {
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.containmentLocked,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          parentGateCredentialStatus: parentGateCredentialStatus,
          pinOwnerFamilyId: pinOwnerFamilyId,
          containmentFence: containmentFence,
          lastRecoveryAudit: lastRecoveryAudit,
          sessionScopeEpoch: sessionScopeEpoch,
          isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          diagnosticReason: 'paired_child_envelope_mismatch',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.verifiedChildMode,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        verifiedFamily: verifiedFamily,
        verifiedChild: verifiedChild,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
      );

    case ConfirmedPairedChildGrantRevoked():
      if (validV2 != null &&
          validV2.modeKind == PersistedChildModeKind.sharedDeviceAdult) {
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.containmentLocked,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          parentGateCredentialStatus: parentGateCredentialStatus,
          pinOwnerFamilyId: pinOwnerFamilyId,
          containmentFence: containmentFence,
          lastRecoveryAudit: lastRecoveryAudit,
          sessionScopeEpoch: sessionScopeEpoch,
          isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          diagnosticReason: 'shared_child_lock_preserved_over_revoked_grant',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.pairedChildRevoked,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        diagnosticReason: 'paired_child_grant_revoked',
      );

    case PairedChildUnverified(:final reason):
      if (validV2 != null &&
          validV2.modeKind == PersistedChildModeKind.sharedDeviceAdult) {
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.containmentLocked,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          parentGateCredentialStatus: parentGateCredentialStatus,
          pinOwnerFamilyId: pinOwnerFamilyId,
          containmentFence: containmentFence,
          lastRecoveryAudit: lastRecoveryAudit,
          sessionScopeEpoch: sessionScopeEpoch,
          isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          diagnosticReason: 'shared_child_lock_preserved_over_unverified_grant',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.pairedChildUnverified,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        diagnosticReason: 'paired_child_unverified_${reason.name}',
      );

    case ConfirmedAdultMembershipRevoked(:final reason):
      if (validV2 != null) {
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.containmentLocked,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          parentGateCredentialStatus: parentGateCredentialStatus,
          pinOwnerFamilyId: pinOwnerFamilyId,
          containmentFence: containmentFence,
          lastRecoveryAudit: lastRecoveryAudit,
          sessionScopeEpoch: sessionScopeEpoch,
          isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          diagnosticReason:
              'adult_membership_revoked_while_child_session_persisted',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.adultAccessRestricted,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        diagnosticReason: reason,
      );

    case SessionAuthorizationUnverified(
      :final reason,
      :final allowsOfflineChildContainment,
    ):
      final pinMatchesFamily =
          parentGateCredentialStatus != ParentGateCredentialStatus.validV2 ||
          pinOwnerFamilyId == null ||
          (validV2 != null && pinOwnerFamilyId == validV2.familyId.value);
      if (allowsOfflineChildContainment &&
          validV2 != null &&
          validV2.modeKind == PersistedChildModeKind.sharedDeviceAdult &&
          hasValidPinCredential &&
          pinMatchesFamily) {
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.offlineContainedChildMode,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          verifiedChild: validV2.childProfileSnapshot,
          parentGateCredentialStatus: parentGateCredentialStatus,
          pinOwnerFamilyId: pinOwnerFamilyId,
          containmentFence: containmentFence,
          lastRecoveryAudit: lastRecoveryAudit,
          sessionScopeEpoch: sessionScopeEpoch,
          isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          diagnosticReason: 'offline_same_actor_contained',
        );
      }
      if (validV2 != null) {
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.containmentLocked,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          parentGateCredentialStatus: parentGateCredentialStatus,
          pinOwnerFamilyId: pinOwnerFamilyId,
          containmentFence: containmentFence,
          lastRecoveryAudit: lastRecoveryAudit,
          sessionScopeEpoch: sessionScopeEpoch,
          isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
          diagnosticReason: allowsOfflineChildContainment
              ? 'unverified_session_with_child_envelope_invalid_pin'
              : 'non_active_or_malformed_membership_with_child_session',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.authorizationUnverified,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        parentGateCredentialStatus: parentGateCredentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        containmentFence: containmentFence,
        lastRecoveryAudit: lastRecoveryAudit,
        sessionScopeEpoch: sessionScopeEpoch,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        diagnosticReason: reason,
      );
  }
}

/// Authoritative session lifecycle coordinator owning [_ContainmentArbiter],
/// synchronous containment fences, fail-closed auth invalidation, Exit Path A/B
/// containment exits, mismatched-actor pause sweeps, and family/PIN operations (`WP3`).
class SessionLifecycleController extends Notifier<ColdStartContainmentState> {
  static const String containmentRecoveryLockV1Key =
      'containment_recovery_lock_v1';

  final ContainmentArbiter _arbiter = ContainmentArbiter();

  int _containmentEpoch = 0;
  int _sessionScopeEpoch = 0;
  int _sessionGenerationOrdinal = 0;
  bool _isFailClosedMasked = false;
  bool _rehydratePending = false;
  bool _rehydrateRunning = false;
  bool _rehydrateNeedsRerun = false;
  bool _pendingHideHydrating = false;
  PendingCreatedFamilyRecord? _pendingCreatedFamily;
  String? _lastVerifiedActorUserId;
  String? _lastVerifiedSessionGeneration;
  String? _lastSignedOutSessionGeneration;
  Completer<void>? _rehydrateDoneCompleter;
  bool _restoredFromPersistedBootstrap = false;
  StreamSubscription<String?>? _sessionGenSub;
  Family? _preferredFamilyOverride;

  /// Exposed monotonically incrementing epoch for deterministic race/barrier tests.
  int get containmentEpoch => _containmentEpoch;

  /// Exposed UI isolation epoch incremented on actor/family/containment transitions.
  int get sessionScopeEpoch => _sessionScopeEpoch;

  /// Whether synchronous fail-closed mask is currently engaged.
  bool get isFailClosedMasked => _isFailClosedMasked;

  /// Runs a test/diagnostic SQLite operation serialized through [_arbiter] if needed.
  Future<T> runSerializedForTest<T>(Future<T> Function() action) =>
      _arbiter.run(action);

  /// Returns the pending created family record ONLY when [actorUserId] and
  /// [sessionGeneration] match both the bound record and live session generation.
  PendingCreatedFamilyRecord? pendingCreatedFamilyFor({
    required String? actorUserId,
    required String? sessionGeneration,
  }) {
    final pending = _pendingCreatedFamily;
    if (pending == null) {
      return null;
    }
    final liveGen = ref.read(authSessionPortProvider).currentSessionGeneration;
    if (liveGen == null || liveGen.trim() != sessionGeneration?.trim()) {
      return null;
    }
    if (!pending.matchesActor(
      actorUserId: actorUserId,
      sessionGeneration: sessionGeneration,
    )) {
      return null;
    }
    return pending;
  }

  bool _isFenceStillValid({
    required int capturedEpoch,
    required String capturedGeneration,
    required String capturedActorId,
  }) {
    if (!ref.mounted ||
        _isFailClosedMasked ||
        _containmentEpoch != capturedEpoch) {
      return false;
    }
    final authPort = ref.read(authSessionPortProvider);
    if (authPort.currentSessionGeneration != capturedGeneration) {
      return false;
    }
    final config = ref.read(appConfigProvider);
    final client = ref.read(supabaseClientProvider);
    if (config.isSupabaseConfigured || client != null) {
      final authState = ref.read(authSessionStateProvider);
      if (!authState.isAuthenticated ||
          authState.actorUserId != capturedActorId ||
          authState.sessionGeneration != capturedGeneration) {
        return false;
      }
      return true;
    }

    // Demo / unit-test mode (`client == null` and `!isSupabaseConfigured`):
    // permit tests overriding only `authSessionPortProvider` while still
    // failing closed on explicit `authStateProvider` or `currentUserIdProvider`
    // invalidation or actor mismatch.
    final rawAuthState = ref.read(authStateProvider);
    if (rawAuthState.hasError) {
      return false;
    }
    if (rawAuthState.hasValue) {
      final data = rawAuthState.value!;
      final session = data.session;
      if (data.event == AuthChangeEvent.signedOut ||
          session == null ||
          session.isExpired ||
          session.user.id.trim() != capturedActorId) {
        return false;
      }
    }
    final currentUid = ref.read(currentUserIdProvider)?.trim();
    if (currentUid != null &&
        currentUid.isNotEmpty &&
        currentUid != capturedActorId) {
      return false;
    }
    return true;
  }

  Future<void> _persistFenceTransition() async {
    try {
      await _arbiter.run(() async {
        if (!ref.mounted) return;
        final store = ref.read(localMetadataStoreProvider);
        final rawChild = await store.readMetadata(
          ActiveChildModeNotifier.activeSessionKey,
        );
        final rawLock = await store.readMetadata(containmentRecoveryLockV1Key);
        final rawFence = await store.readMetadata(
          ParentGateService.containmentFenceV1Key,
        );
        final parsedFence = ContainmentFenceV1.tryParse(rawFence);
        final lockState = rawLock != null
            ? ContainmentFenceLockState.recoveryReauthPending
            : (rawChild != null
                  ? ContainmentFenceLockState.containmentLocked
                  : ContainmentFenceLockState.none);
        final nowUtc = ref.read(appClockProvider)();
        final nextFence = ContainmentFenceV1(
          version: 1,
          fenceEpoch: (parsedFence?.fenceEpoch ?? 0) + 1,
          actorUserId: null,
          sessionGeneration:
              (parsedFence?.sessionGeneration ?? 0) > _sessionGenerationOrdinal
              ? parsedFence!.sessionGeneration
              : _sessionGenerationOrdinal,
          lockState: lockState,
          updatedAtUtc: nowUtc,
        );
        await store.compareAndSwapMetadataBatch(
          expectedValues: {ParentGateService.containmentFenceV1Key: rawFence},
          mutations: [
            MetadataMutation.upsert(
              key: ParentGateService.containmentFenceV1Key,
              value: nextFence.toJsonString(),
              updatedAt: nowUtc,
            ),
          ],
        );
      });
    } catch (_) {
      // Ignore disposal or closed-database teardown errors.
    }
  }

  /// Synchronous (`0 await`) fail-closed mask triggered immediately upon sign-out,
  /// expiry, stream error, or actor/generation change (`D1.3`, `R38-07` Barrier 2).
  void _engageSyncFailClosedMask({
    required bool toUnauthenticated,
    required String reason,
    bool persistFence = true,
  }) {
    _containmentEpoch++;
    _sessionScopeEpoch++;
    _sessionGenerationOrdinal++;
    _isFailClosedMasked = true;
    _pendingCreatedFamily = null;
    _preferredFamilyOverride = null;
    _lastVerifiedActorUserId = null;
    _lastVerifiedSessionGeneration = null;
    _clearInMemoryProtectedState();
    state = ColdStartContainmentState(
      status: toUnauthenticated
          ? ColdStartContainmentStatus.unauthenticated
          : ColdStartContainmentStatus.hydrating,
      sessionScopeEpoch: _sessionScopeEpoch,
      diagnosticReason: reason,
    );
    if (persistFence) {
      unawaited(_persistFenceTransition());
    }
  }

  void _invalidatePendingOnGenerationChange(String? nextGeneration) {
    final pending = _pendingCreatedFamily;
    if (pending != null &&
        (nextGeneration == null ||
            nextGeneration.trim() !=
                pending.createdInSessionGeneration.trim())) {
      _pendingCreatedFamily = null;
    }
    final normalizedNext = nextGeneration?.trim();
    if (normalizedNext == null || normalizedNext.isEmpty) {
      if (_lastVerifiedSessionGeneration != null || state.allowsProtectedUi) {
        _lastSignedOutSessionGeneration ??= _lastVerifiedSessionGeneration;
        _engageSyncFailClosedMask(
          toUnauthenticated: true,
          reason: 'sync_session_generation_invalidated',
        );
      } else {
        _containmentEpoch++;
        _isFailClosedMasked = true;
      }
      return;
    }
    if (_lastVerifiedSessionGeneration != null &&
        normalizedNext != _lastVerifiedSessionGeneration) {
      _engageSyncFailClosedMask(
        toUnauthenticated: false,
        reason: 'sync_session_generation_rotated',
      );
    }
  }

  void _invalidatePendingOnAuthStateChange(AuthState? authState) {
    final pending = _pendingCreatedFamily;
    final nextUserId = authState?.session?.user.id.trim();
    final isInvalid =
        authState == null ||
        authState.event == AuthChangeEvent.signedOut ||
        authState.session == null ||
        authState.session!.isExpired ||
        nextUserId == null ||
        nextUserId.isEmpty;
    if (pending != null &&
        (isInvalid || nextUserId != pending.creatorActorUserId.trim())) {
      _pendingCreatedFamily = null;
    }
    if (isInvalid) {
      _lastSignedOutSessionGeneration ??= _lastVerifiedSessionGeneration;
      if (_lastVerifiedActorUserId != null || state.allowsProtectedUi) {
        _engageSyncFailClosedMask(
          toUnauthenticated: true,
          reason: 'sync_auth_signed_out_or_expired',
        );
      } else {
        _containmentEpoch++;
        _isFailClosedMasked = true;
      }
      return;
    }
    if (_lastVerifiedActorUserId != null &&
        nextUserId != _lastVerifiedActorUserId) {
      _engageSyncFailClosedMask(
        toUnauthenticated: false,
        reason: 'sync_actor_switched',
      );
    }
  }

  @override
  ColdStartContainmentState build() {
    final authPort = ref.watch(authSessionPortProvider);
    _sessionGenSub?.cancel();
    _sessionGenSub = authPort.sessionGenerationStream.listen(
      (nextGeneration) {
        _invalidatePendingOnGenerationChange(nextGeneration);
        _scheduleRehydrate();
      },
      onError: (_) {
        _engageSyncFailClosedMask(
          toUnauthenticated: true,
          reason: 'sync_generation_stream_error',
        );
        _scheduleRehydrate();
      },
    );
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (_, next) {
      if (next.hasValue) {
        _invalidatePendingOnAuthStateChange(next.value);
      } else if (next.hasError) {
        _engageSyncFailClosedMask(
          toUnauthenticated: true,
          reason: 'sync_auth_stream_error',
        );
      }
      _scheduleRehydrate();
    });
    ref.onDispose(() {
      _rehydratePending = false;
      _rehydrateNeedsRerun = false;
      _pendingHideHydrating = false;
      _pendingCreatedFamily = null;
      _preferredFamilyOverride = null;
      _lastVerifiedActorUserId = null;
      _lastVerifiedSessionGeneration = null;
      final pendingCompleter = _rehydrateDoneCompleter;
      _rehydrateDoneCompleter = null;
      if (pendingCompleter != null && !pendingCompleter.isCompleted) {
        pendingCompleter.complete();
      }
      _sessionGenSub?.cancel();
      _sessionGenSub = null;
    });

    _scheduleRehydrate();
    return ColdStartContainmentState(
      status: ColdStartContainmentStatus.hydrating,
      sessionScopeEpoch: _sessionScopeEpoch,
    );
  }

  void _scheduleRehydrate() {
    if (!ref.mounted || _rehydratePending) return;
    _rehydratePending = true;
    Future.microtask(() {
      if (!ref.mounted || !_rehydratePending) return;
      _rehydratePending = false;
      rehydrate();
    });
  }

  Future<void> rehydrate() async {
    await _runRehydrate(showHydrating: true);
  }

  /// Verifies newly created family membership with [ContainmentAuthorizationVerifier]
  /// before allowing entry into `ParentMode` (`R40-01`, `R40-05`).
  Future<bool> confirmCreatedFamily(
    Family createdFamily, {
    required String creatorActorUserId,
    required String sessionGeneration,
  }) async {
    if (!ref.mounted) return false;
    final trimmedActor = creatorActorUserId.trim();
    final trimmedGeneration = sessionGeneration.trim();
    if (trimmedActor.isEmpty ||
        trimmedGeneration.isEmpty ||
        createdFamily.createdByUserId.trim() != trimmedActor) {
      return false;
    }

    final authPort = ref.read(authSessionPortProvider);
    if (authPort.currentSessionGeneration != trimmedGeneration) {
      _invalidatePendingOnGenerationChange(authPort.currentSessionGeneration);
      return false;
    }

    final liveActor = await authPort.validateForMutation();
    if (!ref.mounted) return false;
    final nowUtc = ref.read(appClockProvider)();
    if (liveActor == null ||
        !liveActor.isValidAt(nowUtc) ||
        liveActor.isAnonymous ||
        liveActor.role == 'child' ||
        liveActor.userId.trim() != trimmedActor ||
        liveActor.sessionGeneration != trimmedGeneration ||
        authPort.currentSessionGeneration != trimmedGeneration) {
      _pendingCreatedFamily = null;
      return false;
    }

    _pendingCreatedFamily = PendingCreatedFamilyRecord(
      family: createdFamily,
      creatorActorUserId: trimmedActor,
      createdInSessionGeneration: trimmedGeneration,
      createdAtUtc: nowUtc,
    );
    await _runRehydrate(showHydrating: false);
    if (!ref.mounted) return false;

    return authPort.currentSessionGeneration == trimmedGeneration &&
        state.actorContext?.userId.trim() == trimmedActor &&
        state.actorContext?.sessionGeneration == trimmedGeneration &&
        state.status == ColdStartContainmentStatus.verifiedParentMode &&
        state.verifiedFamily?.id == createdFamily.id;
  }

  /// Enters shared-device Child Mode via `_ContainmentArbiter` CAS persistence (`D1.3`).
  Future<void> enterChildMode(
    ChildProfile child, {
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) async {
    if (!ref.mounted) {
      throw StateError('Lifecycle controller is disposed.');
    }
    final authPort = ref.read(authSessionPortProvider);
    final actor = await authPort.validateForMutation();
    final nowUtc = ref.read(appClockProvider)();
    if (actor == null ||
        !actor.isValidAt(nowUtc) ||
        actor.userId.trim().isEmpty ||
        actor.sessionGeneration.trim().isEmpty ||
        actor.isAnonymous ||
        actor.role == 'child') {
      throw StateError(
        'Cannot enter Child Mode without a validated adult session.',
      );
    }

    final capturedGeneration = actor.sessionGeneration;
    final capturedActorId = actor.userId;

    // Step 2: Authoritative DB verification OUTSIDE _ContainmentArbiter.
    final verifier = ref.read(containmentAuthorizationVerifierProvider);
    final outcome = await verifier.verifySession(
      context: actor,
      targetChildId: child.id,
      targetFamilyId: child.familyId,
      preferredFamilyId: child.familyId,
    );
    if (!ref.mounted ||
        authPort.currentSessionGeneration != capturedGeneration) {
      throw StateError(
        'Cannot enter Child Mode: session invalidated during verification.',
      );
    }

    final postVerifyActor = await authPort.validateForMutation();
    final postVerifyUtc = ref.read(appClockProvider)();
    if (postVerifyActor == null ||
        !postVerifyActor.isValidAt(postVerifyUtc) ||
        postVerifyActor.userId != capturedActorId ||
        postVerifyActor.sessionGeneration != capturedGeneration ||
        postVerifyActor.isAnonymous ||
        postVerifyActor.role == 'child') {
      throw StateError(
        'Cannot enter Child Mode: actor validation changed before entry.',
      );
    }

    if (outcome is! AuthorizedActiveAdult ||
        !outcome.verifiedRolesByFamilyId.containsKey(child.familyId.value) ||
        outcome.verifiedFamily.id != child.familyId ||
        outcome.verifiedChild?.id != child.id ||
        outcome.verifiedChild?.familyId != child.familyId) {
      throw StateError(
        'Cannot enter Child Mode without positive active adult authorization.',
      );
    }

    final verifiedChild = outcome.verifiedChild!;

    // Step 3: Serialize local credential check & durable lock persistence via _arbiter.
    late int capturedEpoch;
    late ContainmentFenceV1 committedFence;
    late PersistedChildModeSession envelope;

    await _arbiter.run(() async {
      if (_isFailClosedMasked) {
        throw StateError(
          'Cannot enter Child Mode while fail-closed mask is active.',
        );
      }
      final gateService = ref.read(parentGateServiceProvider);
      final credInspection = await gateService.inspectCredential();
      if (credInspection.status != ParentGateCredentialStatus.validV2 &&
          credInspection.status != ParentGateCredentialStatus.legacyV1) {
        throw StateError(
          'Cannot enter Child Mode without a valid configured Parent PIN.',
        );
      }
      if (credInspection.v2?.ownerFamilyId != null &&
          credInspection.v2!.ownerFamilyId != child.familyId.value) {
        throw ParentGateOwnershipConflictException(
          'Parent PIN belongs to a different household; reassign before entering Child Mode.',
        );
      }

      capturedEpoch = _containmentEpoch;
      if (!_isFenceStillValid(
        capturedEpoch: capturedEpoch,
        capturedGeneration: capturedGeneration,
        capturedActorId: capturedActorId,
      )) {
        throw StateError(
          'Session generation invalidated before Child Mode entry.',
        );
      }

      final store = ref.read(localMetadataStoreProvider);
      final rawFence = await store.readMetadata(
        ParentGateService.containmentFenceV1Key,
      );
      final parsedFence = ContainmentFenceV1.tryParse(rawFence);
      final persistUtc = ref.read(appClockProvider)();

      committedFence = ContainmentFenceV1(
        version: 1,
        fenceEpoch: (parsedFence?.fenceEpoch ?? 0) + 1,
        actorUserId: capturedActorId,
        sessionGeneration: _sessionGenerationOrdinal,
        lockState: ContainmentFenceLockState.activeChild,
        updatedAtUtc: persistUtc,
      );

      envelope = PersistedChildModeSession(
        modeKind: PersistedChildModeKind.sharedDeviceAdult,
        actorUserId: capturedActorId,
        familyId: child.familyId,
        childId: child.id,
        childProfileSnapshot: verifiedChild,
        persistedAtUtc: persistUtc,
      );

      final committed = await store.compareAndSwapMetadataBatch(
        expectedValues: {
          ActiveChildModeNotifier.activeSessionKey: null,
          containmentRecoveryLockV1Key: null,
          ParentGateService.containmentFenceV1Key: rawFence,
        },
        mutations: [
          MetadataMutation.upsert(
            key: ActiveChildModeNotifier.activeSessionKey,
            value: envelope.toJsonString(),
            updatedAt: persistUtc,
          ),
          MetadataMutation.upsert(
            key: ParentGateService.containmentFenceV1Key,
            value: committedFence.toJsonString(),
            updatedAt: persistUtc,
          ),
        ],
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: capturedEpoch,
          capturedGeneration: capturedGeneration,
          capturedActorId: capturedActorId,
        ),
        onBeforePreCommitGuard: onBeforePreCommitGuard,
        onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
      );

      if (!committed ||
          !_isFenceStillValid(
            capturedEpoch: capturedEpoch,
            capturedGeneration: capturedGeneration,
            capturedActorId: capturedActorId,
          )) {
        throw StateError(
          'Cannot enter Child Mode: pre-commit guard or CAS fence rejected commit.',
        );
      }

      _containmentEpoch++;
    });

    if (!_isFenceStillValid(
      capturedEpoch: _containmentEpoch,
      capturedGeneration: capturedGeneration,
      capturedActorId: capturedActorId,
    )) {
      throw StateError('Child Mode entry masked by concurrent session change.');
    }

    _restoredFromPersistedBootstrap = true;
    _lastVerifiedActorUserId = capturedActorId;
    _lastVerifiedSessionGeneration = capturedGeneration;
    _preferredFamilyOverride = outcome.verifiedFamily;
    _sessionScopeEpoch++;

    ref
        .read(activeFamilyProvider.notifier)
        .selectFamily(outcome.verifiedFamily);
    ref
        .read(activeChildModeProvider.notifier)
        .restoreVerifiedChild(verifiedChild);

    state = ColdStartContainmentState(
      status: ColdStartContainmentStatus.verifiedChildMode,
      actorContext: postVerifyActor,
      verificationOutcome: outcome,
      persistedSessionResult: ValidPersistedChildModeSessionV2(
        session: envelope,
        rawJson: envelope.toJsonString(),
      ),
      recoveryLockResult: const AbsentContainmentRecoveryLock(),
      verifiedFamily: outcome.verifiedFamily,
      verifiedChild: verifiedChild,
      verifiedFamilies: outcome.verifiedFamilies,
      verifiedRolesByFamilyId: outcome.verifiedRolesByFamilyId,
      parentGateCredentialStatus: state.parentGateCredentialStatus,
      pinOwnerFamilyId: outcome.verifiedFamily.id.value,
      containmentFence: committedFence,
      sessionScopeEpoch: _sessionScopeEpoch,
      isPostSignOutFreshAdultAuth: state.isPostSignOutFreshAdultAuth,
    );
  }

  /// Executes Exit Path A fenced Parent PIN unlock (`D1.3` 5-step arbiter order).
  ///
  /// PBKDF2 executes OUTSIDE [_arbiter]; remote verifier re-checks OUTSIDE
  /// [_arbiter]; Barrier 1 `preCommitGuard` and Barrier 2 post-commit fence check
  /// guarantee zero unauthorized or post-sign-out ParentMode leakage.
  Future<PinVerificationResult> submitParentGateUnlock(
    String enteredPin, {
    Future<void> Function()? onBeforePhase1PreCommitGuard,
    Future<void> Function()? onAfterPhase1GuardBeforeCommit,
    Future<void> Function(StagedPinVerificationAttempt attempt)?
    onAfterKdfBeforeFinalize,
    Future<void> Function()? onBeforeFinalizePreCommitGuard,
    Future<void> Function()? onAfterFinalizeGuardBeforeCommit,
  }) async {
    if (!ref.mounted || state.isPairedChildMode) {
      return const PinVerificationResult(
        outcome: PinVerificationOutcome.staleFence,
        failedAttempts: 0,
        message: 'Parent Gate exit is unavailable in this mode.',
      );
    }

    final authPort = ref.read(authSessionPortProvider);
    final initialActor = await authPort.validateForMutation();
    if (initialActor == null ||
        initialActor.isAnonymous ||
        initialActor.role == 'child') {
      return const PinVerificationResult(
        outcome: PinVerificationOutcome.pinMatchedAuthorizationRequired,
        failedAttempts: 0,
        message: 'An authenticated parent account is required to exit.',
      );
    }

    final capturedGeneration = initialActor.sessionGeneration;
    final capturedActorId = initialActor.userId;
    final gateService = ref.read(parentGateServiceProvider);

    // Step 1/2: Inspect fence & resolve candidate target family OUTSIDE heavy KDF.
    final initialStore = ref.read(localMetadataStoreProvider);
    final rawChildInitial = await initialStore.readMetadata(
      ActiveChildModeNotifier.activeSessionKey,
    );
    final parsedChildInitial = PersistedChildModeSession.tryParse(
      rawChildInitial,
    );
    final rawLockInitial = await initialStore.readMetadata(
      containmentRecoveryLockV1Key,
    );
    final rawFenceInitial = await initialStore.readMetadata(
      ParentGateService.containmentFenceV1Key,
    );
    final initialCred = await gateService.inspectCredential();

    final validChildV2 = parsedChildInitial is ValidPersistedChildModeSessionV2
        ? parsedChildInitial.session
        : null;
    final legacyHint = LegacyChildHint.tryParse(rawChildInitial);
    final targetFamilyId =
        initialCred.v2?.ownerFamilyId ??
        validChildV2?.familyId.value ??
        legacyHint?.familyId ??
        state.verifiedFamily?.id.value;

    if (_isFailClosedMasked) {
      return const PinVerificationResult(
        outcome: PinVerificationOutcome.staleFence,
        failedAttempts: 0,
        message: 'Session changed before verification started.',
      );
    }
    final capturedEpoch = _containmentEpoch;

    final operationFence = ParentGateOperationFence(
      actorUserId: capturedActorId,
      sessionGeneration: _sessionGenerationOrdinal,
      containmentEpoch: capturedEpoch,
      expectedContainmentStatus: state.status.name,
      verifiedFamilyId: targetFamilyId,
      expectedChildId: validChildV2?.childId.value,
      expectedCredentialRevision: initialCred.v2?.credentialRevision,
      expectedChildSessionRaw: rawChildInitial,
      expectedContainmentFenceRaw: rawFenceInitial,
    );

    // Step 2: Phase 1 fast lockout reservation inside _arbiter (zero KDF).
    late PinAttemptReservationResult reservationResult;

    await _arbiter.run(() async {
      if (!_isFenceStillValid(
        capturedEpoch: capturedEpoch,
        capturedGeneration: capturedGeneration,
        capturedActorId: capturedActorId,
      )) {
        reservationResult = const PinAttemptReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.staleFence,
            failedAttempts: 0,
            message: 'Session changed before verification started.',
          ),
        );
        return;
      }

      reservationResult = await gateService.reserveVerificationAttempt(
        enteredPin: enteredPin,
        actorFamilyId: targetFamilyId,
        actorUserId: capturedActorId,
        fence: operationFence,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: capturedEpoch,
          capturedGeneration: capturedGeneration,
          capturedActorId: capturedActorId,
        ),
        onBeforePreCommitGuard: onBeforePhase1PreCommitGuard,
        onAfterGuardBeforeCommit: onAfterPhase1GuardBeforeCommit,
      );
    });

    if (!reservationResult.isReserved) {
      return reservationResult.immediateFailure!;
    }

    final initialAdultFamilies = state.verifiedFamilies
        .map((f) => f.id.value)
        .toList(growable: false);

    // Step 3: PBKDF2 digest comparison OUTSIDE _arbiter.
    var stagedAttempt = await gateService.evaluateReservedAttempt(
      enteredPin: enteredPin,
      reserved: reservationResult.reservation!,
      hasPositiveServerAdultVerification:
          state.hasPositiveActiveAdultMembership,
      verifiedActiveAdultFamilyIds: initialAdultFamilies,
      onAfterKdfBeforeFinalize: onAfterKdfBeforeFinalize,
    );

    // Step 4: Live adult authorization re-verification OUTSIDE _arbiter.
    var liveHasAuthorizedExitContext = false;
    var shouldScheduleRevokedRefresh = false;
    AuthorizedActiveAdult? liveAdultOutcome;

    if (stagedAttempt.pinMatched &&
        _isFenceStillValid(
          capturedEpoch: capturedEpoch,
          capturedGeneration: capturedGeneration,
          capturedActorId: capturedActorId,
        )) {
      final liveActor = await authPort.validateForMutation();
      final nowUtc = ref.read(appClockProvider)();
      if (liveActor != null &&
          liveActor.isValidAt(nowUtc) &&
          !liveActor.isAnonymous &&
          liveActor.role != 'child' &&
          liveActor.userId == capturedActorId &&
          liveActor.sessionGeneration == capturedGeneration) {
        final verifier = ref.read(containmentAuthorizationVerifierProvider);
        final outcome = await verifier.verifySession(
          context: liveActor,
          persistedChildSession: validChildV2,
          preferredFamilyId: targetFamilyId != null
              ? FamilyId(targetFamilyId)
              : state.verifiedFamily?.id,
        );
        if (_isFenceStillValid(
          capturedEpoch: capturedEpoch,
          capturedGeneration: capturedGeneration,
          capturedActorId: capturedActorId,
        )) {
          if (outcome is AuthorizedActiveAdult) {
            liveAdultOutcome = outcome;
            liveHasAuthorizedExitContext =
                targetFamilyId == null ||
                outcome.verifiedRolesByFamilyId.containsKey(targetFamilyId);
          } else if (outcome is AuthorizedAdultChildUnavailable) {
            final matchingFamily = outcome.verifiedFamilies
                .where((f) => f.id.value == targetFamilyId)
                .firstOrNull;
            if (matchingFamily != null) {
              liveHasAuthorizedExitContext = true;
              liveAdultOutcome = AuthorizedActiveAdult(
                verifiedRole:
                    outcome.verifiedRolesByFamilyId[matchingFamily.id.value]!,
                verifiedFamily: matchingFamily,
                verifiedFamilies: outcome.verifiedFamilies,
                verifiedRolesByFamilyId: outcome.verifiedRolesByFamilyId,
              );
            } else {
              shouldScheduleRevokedRefresh = true;
            }
          } else if (outcome is ConfirmedAdultMembershipRevoked ||
              outcome is NoActiveFamilyMembershipObserved) {
            shouldScheduleRevokedRefresh = true;
          }
        }
      }
    }

    // Legacy v1 & unbound provenance guard (`D1.6`): fail closed when target
    // ownership is unresolvable without a verified hinted family.
    if (liveHasAuthorizedExitContext &&
        (stagedAttempt.credentialStatus ==
                ParentGateCredentialStatus.legacyV1 ||
            targetFamilyId == null)) {
      final provenance = ref.read(legacyOutboxProvenanceSourceProvider);
      final liveFamilies = liveAdultOutcome!.verifiedFamilies;
      final resolution = await gateService.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: liveFamilies
            .map((f) => f.id.value)
            .toList(growable: false),
        legacyChildSessionRaw: rawChildInitial,
      );
      if (resolution is BoundOwnerResolution) {
        liveHasAuthorizedExitContext = liveFamilies.any(
          (f) => f.id.value == resolution.ownerFamilyId,
        );
      } else if (resolution is CorroboratedLegacyOwnerResolution) {
        liveHasAuthorizedExitContext = liveFamilies.any(
          (f) => f.id.value == resolution.familyId,
        );
      } else if (resolution is UnresolvableLegacyOwnershipResolution) {
        final hintedFamily = resolution.legacyChildHint?.familyId;
        liveHasAuthorizedExitContext =
            hintedFamily != null &&
            liveFamilies.any((f) => f.id.value == hintedFamily);
      }
    }

    // Derive legacy v1 -> v2 upgrade credential OUTSIDE _arbiter when Step 4 confirms adult access.
    if (liveHasAuthorizedExitContext &&
        stagedAttempt.pinMatched &&
        stagedAttempt.credentialStatus == ParentGateCredentialStatus.legacyV1 &&
        stagedAttempt.upgradedV2Credential == null) {
      final material = await gateService.derivePinMaterial(enteredPin);
      final upgradeFamilyId =
          targetFamilyId ?? liveAdultOutcome!.verifiedFamily.id.value;
      stagedAttempt = StagedPinVerificationAttempt(
        attemptId: stagedAttempt.attemptId,
        pinMatched: stagedAttempt.pinMatched,
        hasAuthorizedExitContext: true,
        credentialStatus: stagedAttempt.credentialStatus,
        reservedCredentialRevision: stagedAttempt.reservedCredentialRevision,
        reservedLockoutRevision: stagedAttempt.reservedLockoutRevision,
        reservedLockoutRaw: stagedAttempt.reservedLockoutRaw,
        upgradedV2Credential: ParentGateCredentialV2(
          version: 2,
          kdf: material.kdf,
          iterations: material.iterations,
          keyLengthBytes: material.keyLengthBytes,
          saltHex: material.saltHex,
          hashHex: material.hashHex,
          ownerFamilyId: upgradeFamilyId,
          configuredByActorUserId: capturedActorId,
          credentialRevision: 1,
          updatedAtUtc: ref.read(appClockProvider)(),
        ),
        legacyV1HashRaw: stagedAttempt.legacyV1HashRaw,
        legacyV1SaltRaw: stagedAttempt.legacyV1SaltRaw,
        fence: stagedAttempt.fence,
      );
    }

    // Step 5: Phase 3 atomic SQLite commit INSIDE _arbiter with two-barrier check.
    late PinVerificationResult finalResult;
    ContainmentFenceV1? committedFence;
    var postCommitEpoch = capturedEpoch;

    await _arbiter.run(() async {
      if (!_isFenceStillValid(
        capturedEpoch: capturedEpoch,
        capturedGeneration: capturedGeneration,
        capturedActorId: capturedActorId,
      )) {
        await gateService.abortFencedAttempt(stagedAttempt.attemptId);
        finalResult = PinVerificationResult(
          outcome: PinVerificationOutcome.staleFence,
          attemptId: stagedAttempt.attemptId,
          failedAttempts: 0,
          message: 'Unlock aborted due to concurrent session transition.',
        );
        return;
      }

      final parsedFenceInitial = ContainmentFenceV1.tryParse(rawFenceInitial);

      finalResult = await gateService.completeStagedVerification(
        attempt: stagedAttempt,
        hasAuthorizedExitContextOverride: liveHasAuthorizedExitContext,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: capturedEpoch,
          capturedGeneration: capturedGeneration,
          capturedActorId: capturedActorId,
        ),
        onBeforePreCommitGuard: onBeforeFinalizePreCommitGuard,
        onAfterGuardBeforeCommit: onAfterFinalizeGuardBeforeCommit,
        additionalExpectedValues: {
          containmentRecoveryLockV1Key: ?rawLockInitial,
        },
        additionalMutationsBuilder: (nowUtc) {
          final nextFence = ContainmentFenceV1(
            version: 1,
            fenceEpoch: (parsedFenceInitial?.fenceEpoch ?? 0) + 1,
            actorUserId: capturedActorId,
            sessionGeneration: _sessionGenerationOrdinal,
            lockState: ContainmentFenceLockState.none,
            updatedAtUtc: nowUtc,
          );
          committedFence = nextFence;
          return [
            if (rawChildInitial != null)
              const MetadataMutation.delete(
                key: ActiveChildModeNotifier.activeSessionKey,
              ),
            if (rawLockInitial != null)
              const MetadataMutation.delete(key: containmentRecoveryLockV1Key),
            MetadataMutation.upsert(
              key: ParentGateService.containmentFenceV1Key,
              value: nextFence.toJsonString(),
              updatedAt: nowUtc,
            ),
          ];
        },
      );

      if (finalResult.outcome == PinVerificationOutcome.staleFence) {
        await gateService.abortFencedAttempt(stagedAttempt.attemptId);
      } else if (finalResult.isAuthorizedToExitChildMode) {
        _containmentEpoch++;
        postCommitEpoch = _containmentEpoch;
      }
    });

    if (shouldScheduleRevokedRefresh) {
      _scheduleRehydrate();
    }

    // Post-commit Barrier 2 verification: if auth invalidated between
    // preCommitGuard() and SQLite COMMIT resolution, NEVER publish ParentMode.
    if (!finalResult.isAuthorizedToExitChildMode) {
      return finalResult;
    }
    if (!_isFenceStillValid(
      capturedEpoch: postCommitEpoch,
      capturedGeneration: capturedGeneration,
      capturedActorId: capturedActorId,
    )) {
      if (!_isFailClosedMasked) {
        _engageSyncFailClosedMask(
          toUnauthenticated: authPort.currentSessionGeneration == null,
          reason: 'barrier2_post_commit_mask',
        );
      }
      return PinVerificationResult(
        outcome: PinVerificationOutcome.staleFence,
        attemptId: stagedAttempt.attemptId,
        failedAttempts: 0,
        message: 'Session invalidated while unlock commit completed.',
      );
    }

    final adultOutcome = liveAdultOutcome!;
    final selectedFamily = targetFamilyId != null
        ? adultOutcome.verifiedFamilies.firstWhere(
            (f) => f.id.value == targetFamilyId,
            orElse: () => adultOutcome.verifiedFamily,
          )
        : adultOutcome.verifiedFamily;

    _restoredFromPersistedBootstrap = false;
    _preferredFamilyOverride = selectedFamily;
    _sessionScopeEpoch++;

    ref.read(activeChildModeProvider.notifier).restoreVerifiedChild(null);
    ref.read(activeFamilyProvider.notifier).selectFamily(selectedFamily);

    final postCred = await gateService.inspectCredential();
    if (!_isFenceStillValid(
      capturedEpoch: postCommitEpoch,
      capturedGeneration: capturedGeneration,
      capturedActorId: capturedActorId,
    )) {
      return PinVerificationResult(
        outcome: PinVerificationOutcome.staleFence,
        attemptId: stagedAttempt.attemptId,
        failedAttempts: 0,
        message: 'Session invalidated after unlock commit.',
      );
    }

    state = ColdStartContainmentState(
      status: ColdStartContainmentStatus.verifiedParentMode,
      actorContext: initialActor,
      verificationOutcome: adultOutcome,
      persistedSessionResult: const AbsentPersistedChildModeSession(),
      recoveryLockResult: const AbsentContainmentRecoveryLock(),
      verifiedFamily: selectedFamily,
      verifiedFamilies: adultOutcome.verifiedFamilies,
      verifiedRolesByFamilyId: adultOutcome.verifiedRolesByFamilyId,
      parentGateCredentialStatus: postCred.status,
      pinOwnerFamilyId: postCred.v2?.ownerFamilyId,
      containmentFence: committedFence,
      lastRecoveryAudit: state.lastRecoveryAudit,
      sessionScopeEpoch: _sessionScopeEpoch,
      isPostSignOutFreshAdultAuth: state.isPostSignOutFreshAdultAuth,
    );
    return finalResult;
  }

  Future<
    ({
      ValidatedActorContext actor,
      AuthorizedActiveAdult adultOutcome,
      String targetFamilyId,
      ParentGateOperationFence fence,
      int capturedEpoch,
      String? rawFence,
    })
  >
  _prepareVerifiedParentAction(ParentGateService gateService) async {
    if (!ref.mounted || state.isActiveChildMode) {
      throw ParentGateFencedOperationException(
        'Parent PIN configuration is unavailable inside Child Mode.',
      );
    }
    final authPort = ref.read(authSessionPortProvider);
    final actor = await authPort.validateForMutation();
    final nowUtc = ref.read(appClockProvider)();
    if (actor == null ||
        !actor.isValidAt(nowUtc) ||
        actor.isAnonymous ||
        actor.role == 'child') {
      throw ParentGateFencedOperationException(
        'Authenticated active adult session is required.',
      );
    }
    final capturedGeneration = actor.sessionGeneration;
    final verifier = ref.read(containmentAuthorizationVerifierProvider);
    final preferredId =
        ref.read(activeFamilyProvider)?.id ?? state.verifiedFamily?.id;
    final outcome = await verifier.verifySession(
      context: actor,
      preferredFamilyId: preferredId,
    );
    if (!ref.mounted ||
        authPort.currentSessionGeneration != capturedGeneration ||
        outcome is! AuthorizedActiveAdult) {
      throw ParentGateFencedOperationException(
        'Positive active adult membership verification is required.',
      );
    }

    final store = ref.read(localMetadataStoreProvider);
    final rawChild = await store.readMetadata(
      ActiveChildModeNotifier.activeSessionKey,
    );
    final rawRecoveryLock = await store.readMetadata(
      containmentRecoveryLockV1Key,
    );
    if (rawChild != null || rawRecoveryLock != null) {
      throw ParentGateFencedOperationException(
        'Cannot reconfigure Parent PIN while an unresolved Child Mode session or recovery lock exists.',
      );
    }

    final credInspection = await gateService.inspectCredential();
    final rawFence = await store.readMetadata(
      ParentGateService.containmentFenceV1Key,
    );
    final targetFamily =
        preferredId != null &&
            outcome.verifiedFamilies.any((f) => f.id == preferredId)
        ? outcome.verifiedFamilies.firstWhere((f) => f.id == preferredId)
        : outcome.verifiedFamily;

    if (_isFailClosedMasked) {
      throw ParentGateFencedOperationException(
        'Operation blocked because fail-closed session mask is active.',
      );
    }
    final capturedEpoch = _containmentEpoch;

    final fence = ParentGateOperationFence(
      actorUserId: actor.userId,
      sessionGeneration: _sessionGenerationOrdinal,
      containmentEpoch: capturedEpoch,
      expectedContainmentStatus: state.status.name,
      verifiedFamilyId: targetFamily.id.value,
      expectedCredentialRevision: credInspection.v2?.credentialRevision,
      expectedContainmentFenceRaw: rawFence,
    );

    return (
      actor: actor,
      adultOutcome: outcome,
      targetFamilyId: targetFamily.id.value,
      fence: fence,
      capturedEpoch: capturedEpoch,
      rawFence: rawFence,
    );
  }

  /// Sets the initial v2 Parent PIN with explicit owner family + arbiter fence (`D1.5`, `R39-04`).
  Future<ParentGateCredentialV2> submitInitialPinSetup(
    String newPin, {
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) async {
    final gateService = ref.read(parentGateServiceProvider);
    final material = await gateService.derivePinMaterial(newPin);
    final prepared = await _prepareVerifiedParentAction(gateService);

    late ParentGateCredentialV2 created;
    await _arbiter.run(() async {
      created = await gateService.setPin(
        newPin,
        ownerFamilyId: prepared.targetFamilyId,
        configuredByActorUserId: prepared.actor.userId,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: prepared.adultOutcome.verifiedFamilies
            .map((f) => f.id.value)
            .toList(growable: false),
        fence: prepared.fence,
        preDerivedMaterial: material,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: prepared.capturedEpoch,
          capturedGeneration: prepared.actor.sessionGeneration,
          capturedActorId: prepared.actor.userId,
        ),
        onBeforePreCommitGuard: onBeforePreCommitGuard,
        onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
      );
    });

    if (_isFenceStillValid(
      capturedEpoch: prepared.capturedEpoch,
      capturedGeneration: prepared.actor.sessionGeneration,
      capturedActorId: prepared.actor.userId,
    )) {
      state = state.copyWith(
        parentGateCredentialStatus: ParentGateCredentialStatus.validV2,
        pinOwnerFamilyId: created.ownerFamilyId,
        needsPinReconfigurationAfterRecovery: false,
      );
    }
    return created;
  }

  /// Authenticated Parent PIN change requiring valid current PIN + active adult check (`D1.5`).
  Future<PinVerificationResult> submitParentPinChange({
    required String currentPin,
    required String newPin,
  }) async {
    final gateService = ref.read(parentGateServiceProvider);
    final newMaterial = await gateService.derivePinMaterial(newPin);
    final prepared = await _prepareVerifiedParentAction(gateService);

    late PinAttemptReservationResult reservation;
    await _arbiter.run(() async {
      reservation = await gateService.reserveVerificationAttempt(
        enteredPin: currentPin,
        actorFamilyId: prepared.targetFamilyId,
        actorUserId: prepared.actor.userId,
        fence: prepared.fence,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: prepared.capturedEpoch,
          capturedGeneration: prepared.actor.sessionGeneration,
          capturedActorId: prepared.actor.userId,
        ),
      );
    });

    if (!reservation.isReserved) {
      return reservation.immediateFailure!;
    }

    final verifiedIds = prepared.adultOutcome.verifiedFamilies
        .map((f) => f.id.value)
        .toList(growable: false);
    final staged = await gateService.evaluateReservedAttempt(
      enteredPin: currentPin,
      reserved: reservation.reservation!,
      hasPositiveServerAdultVerification: true,
      verifiedActiveAdultFamilyIds: verifiedIds,
    );

    final authPort = ref.read(authSessionPortProvider);
    final liveActor = await authPort.validateForMutation();
    final stillAuthorized =
        liveActor != null &&
        liveActor.userId == prepared.actor.userId &&
        liveActor.sessionGeneration == prepared.actor.sessionGeneration &&
        _isFenceStillValid(
          capturedEpoch: prepared.capturedEpoch,
          capturedGeneration: prepared.actor.sessionGeneration,
          capturedActorId: prepared.actor.userId,
        );

    late PinVerificationResult result;
    await _arbiter.run(() async {
      result = await gateService.completeStagedVerification(
        attempt: staged,
        hasAuthorizedExitContextOverride: stillAuthorized,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: prepared.capturedEpoch,
          capturedGeneration: prepared.actor.sessionGeneration,
          capturedActorId: prepared.actor.userId,
        ),
        additionalMutationsBuilder: (nowUtc) {
          final nextRev = staged.reservedCredentialRevision + 1;
          final nextCred = ParentGateCredentialV2(
            version: 2,
            kdf: newMaterial.kdf,
            iterations: newMaterial.iterations,
            keyLengthBytes: newMaterial.keyLengthBytes,
            saltHex: newMaterial.saltHex,
            hashHex: newMaterial.hashHex,
            ownerFamilyId: prepared.targetFamilyId,
            configuredByActorUserId: prepared.actor.userId,
            credentialRevision: nextRev,
            updatedAtUtc: nowUtc,
          );
          return [
            MetadataMutation.upsert(
              key: ParentGateService.credentialV2Key,
              value: nextCred.toJsonString(),
              updatedAt: nowUtc,
            ),
            if (staged.legacyV1HashRaw != null)
              const MetadataMutation.delete(key: ParentGateService.pinHashKey),
            if (staged.legacyV1SaltRaw != null)
              const MetadataMutation.delete(key: ParentGateService.pinSaltKey),
          ];
        },
      );
    });

    if (result.isVerified &&
        _isFenceStillValid(
          capturedEpoch: prepared.capturedEpoch,
          capturedGeneration: prepared.actor.sessionGeneration,
          capturedActorId: prepared.actor.userId,
        )) {
      state = state.copyWith(
        parentGateCredentialStatus: ParentGateCredentialStatus.validV2,
        pinOwnerFamilyId: prepared.targetFamilyId,
        needsPinReconfigurationAfterRecovery: false,
      );
    }
    return result;
  }

  /// Reassigns cross-household Parent PIN after explicit Parent Mode confirmation (`C0-27`, `D1.5`).
  Future<ParentGateCredentialV2> submitCrossFamilyPinReassignment({
    required String newPin,
  }) async {
    final gateService = ref.read(parentGateServiceProvider);
    final material = await gateService.derivePinMaterial(newPin);
    final prepared = await _prepareVerifiedParentAction(gateService);

    late ParentGateCredentialV2 updated;
    await _arbiter.run(() async {
      updated = await gateService.reassignCrossFamilyPin(
        newPin: newPin,
        targetFamilyId: prepared.targetFamilyId,
        actorUserId: prepared.actor.userId,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: prepared.adultOutcome.verifiedFamilies
            .map((f) => f.id.value)
            .toList(growable: false),
        fence: prepared.fence,
        preDerivedMaterial: material,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: prepared.capturedEpoch,
          capturedGeneration: prepared.actor.sessionGeneration,
          capturedActorId: prepared.actor.userId,
        ),
      );
    });

    if (_isFenceStillValid(
      capturedEpoch: prepared.capturedEpoch,
      capturedGeneration: prepared.actor.sessionGeneration,
      capturedActorId: prepared.actor.userId,
    )) {
      state = state.copyWith(
        parentGateCredentialStatus: ParentGateCredentialStatus.validV2,
        pinOwnerFamilyId: updated.ownerFamilyId,
        needsPinReconfigurationAfterRecovery: false,
      );
    }
    return updated;
  }

  /// Recovers a corrupted PIN in verified Parent Mode (`D1.5`).
  Future<ParentGateCredentialV2> submitCorruptPinRecovery({
    required String newPin,
  }) async {
    final gateService = ref.read(parentGateServiceProvider);
    final material = await gateService.derivePinMaterial(newPin);
    final prepared = await _prepareVerifiedParentAction(gateService);

    late ParentGateCredentialV2 recovered;
    await _arbiter.run(() async {
      recovered = await gateService.recoverCorruptCredential(
        newPin: newPin,
        targetFamilyId: prepared.targetFamilyId,
        actorUserId: prepared.actor.userId,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: prepared.adultOutcome.verifiedFamilies
            .map((f) => f.id.value)
            .toList(growable: false),
        fence: prepared.fence,
        preDerivedMaterial: material,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: prepared.capturedEpoch,
          capturedGeneration: prepared.actor.sessionGeneration,
          capturedActorId: prepared.actor.userId,
        ),
      );
    });

    if (_isFenceStillValid(
      capturedEpoch: prepared.capturedEpoch,
      capturedGeneration: prepared.actor.sessionGeneration,
      capturedActorId: prepared.actor.userId,
    )) {
      state = state.copyWith(
        parentGateCredentialStatus: ParentGateCredentialStatus.validV2,
        pinOwnerFamilyId: recovered.ownerFamilyId,
        needsPinReconfigurationAfterRecovery: false,
      );
    }
    return recovered;
  }

  /// Resets a forgotten PIN in Parent Mode ONLY after fresh post-sign-out adult reauth (`C0-18`).
  Future<ParentGateCredentialV2> submitForgottenPinReset({
    required String newPin,
  }) async {
    if (!state.isPostSignOutFreshAdultAuth) {
      throw ParentGateFencedOperationException(
        'Resetting a forgotten PIN requires signing out and re-authenticating first.',
      );
    }
    final gateService = ref.read(parentGateServiceProvider);
    final material = await gateService.derivePinMaterial(newPin);
    final prepared = await _prepareVerifiedParentAction(gateService);

    late ParentGateCredentialV2 resetCred;
    await _arbiter.run(() async {
      resetCred = await gateService.resetPinAfterReauth(
        newPin: newPin,
        targetFamilyId: prepared.targetFamilyId,
        actorUserId: prepared.actor.userId,
        isPostSignOutFreshAdultAuth: state.isPostSignOutFreshAdultAuth,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: prepared.adultOutcome.verifiedFamilies
            .map((f) => f.id.value)
            .toList(growable: false),
        fence: prepared.fence,
        preDerivedMaterial: material,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: prepared.capturedEpoch,
          capturedGeneration: prepared.actor.sessionGeneration,
          capturedActorId: prepared.actor.userId,
        ),
      );
    });

    if (_isFenceStillValid(
      capturedEpoch: prepared.capturedEpoch,
      capturedGeneration: prepared.actor.sessionGeneration,
      capturedActorId: prepared.actor.userId,
    )) {
      state = state.copyWith(
        parentGateCredentialStatus: ParentGateCredentialStatus.validV2,
        pinOwnerFamilyId: resetCred.ownerFamilyId,
        needsPinReconfigurationAfterRecovery: false,
      );
    }
    return resetCred;
  }

  /// High-friction Restricted Manual Unbound Recovery (`D1.6`, `C0-39`).
  ///
  /// Strictly rejects unless `ownershipLevel == unresolvable`, fresh post-sign-out
  /// active adult membership for [targetFamilyId] is positively verified, and
  /// a valid new v2 PIN is committed via `_ContainmentArbiter`. Preserves 100% of
  /// drafts, reward commands, and evidence photos.
  Future<ParentGateCredentialV2> submitManualUnboundLegacyRecovery({
    required String newPin,
    required String targetFamilyId,
  }) async {
    if (state.status != ColdStartContainmentStatus.containmentLocked ||
        !state.isPostSignOutFreshAdultAuth) {
      throw ParentGateFencedOperationException(
        'Manual unbound recovery requires Containment Locked state after fresh post-sign-out adult authentication.',
      );
    }

    final gateService = ref.read(parentGateServiceProvider);
    final material = await gateService.derivePinMaterial(newPin);

    final authPort = ref.read(authSessionPortProvider);
    final actor = await authPort.validateForMutation();
    final nowUtc = ref.read(appClockProvider)();
    if (actor == null ||
        !actor.isValidAt(nowUtc) ||
        actor.isAnonymous ||
        actor.role == 'child') {
      throw ParentGateFencedOperationException(
        'Active verified adult account is required for manual unbound recovery.',
      );
    }

    final capturedGeneration = actor.sessionGeneration;
    final verifier = ref.read(containmentAuthorizationVerifierProvider);
    final outcome = await verifier.verifySession(
      context: actor,
      preferredFamilyId: FamilyId(targetFamilyId),
    );
    if (!ref.mounted ||
        authPort.currentSessionGeneration != capturedGeneration) {
      throw ParentGateFencedOperationException(
        'Session changed during manual unbound recovery verification.',
      );
    }

    final verifiedFamilies = switch (outcome) {
      AuthorizedActiveAdult(:final verifiedFamilies) => verifiedFamilies,
      AuthorizedAdultChildUnavailable(:final verifiedFamilies) =>
        verifiedFamilies,
      _ => const <Family>[],
    };
    if (!verifiedFamilies.any((f) => f.id.value == targetFamilyId)) {
      throw ParentGateFencedOperationException(
        'Selected household was not positively verified for this adult account.',
      );
    }

    final store = ref.read(localMetadataStoreProvider);
    final rawChild = await store.readMetadata(
      ActiveChildModeNotifier.activeSessionKey,
    );
    final rawRecovery = await store.readMetadata(containmentRecoveryLockV1Key);
    final rawFence = await store.readMetadata(
      ParentGateService.containmentFenceV1Key,
    );
    final parsedRecovery = ContainmentRecoveryLockV1.parseStorageValue(
      rawRecovery,
    );
    final provenance = ref.read(legacyOutboxProvenanceSourceProvider);
    final resolution = await gateService.resolveLegacyOwnership(
      provenanceSource: provenance,
      hasPositiveServerAdultVerification: true,
      verifiedActiveAdultFamilyIds: verifiedFamilies
          .map((f) => f.id.value)
          .toList(growable: false),
      legacyChildSessionRaw: rawChild,
    );

    final isUnresolvable = switch (parsedRecovery) {
      ValidContainmentRecoveryLockV1(:final lock) =>
        lock.ownershipLevel == ContainmentRecoveryOwnershipLevel.unresolvable &&
            resolution is UnresolvableLegacyOwnershipResolution,
      AbsentContainmentRecoveryLock() || MalformedContainmentRecoveryLock() =>
        resolution is UnresolvableLegacyOwnershipResolution,
    };
    if (!isUnresolvable) {
      throw ParentGateFencedOperationException(
        'Manual unbound recovery applies strictly to unresolvable legacy containment states.',
      );
    }

    if (_isFailClosedMasked) {
      throw ParentGateFencedOperationException(
        'Operation blocked because fail-closed session mask is active.',
      );
    }
    final capturedEpoch = _containmentEpoch;

    final fence = ParentGateOperationFence(
      actorUserId: actor.userId,
      sessionGeneration: _sessionGenerationOrdinal,
      containmentEpoch: capturedEpoch,
      expectedContainmentStatus: state.status.name,
      verifiedFamilyId: targetFamilyId,
      expectedChildSessionRaw: rawChild,
      expectedContainmentFenceRaw: rawFence,
    );

    late ParentGateCredentialV2 installedCred;
    await _arbiter.run(() async {
      installedCred = await gateService.commitRestrictedManualUnboundRecovery(
        newPin: newPin,
        actorUserId: actor.userId,
        targetFamilyId: targetFamilyId,
        isPostSignOutFreshAdultAuth: state.isPostSignOutFreshAdultAuth,
        hasPositiveServerAdultVerification: true,
        verifiedActiveAdultFamilyIds: verifiedFamilies
            .map((f) => f.id.value)
            .toList(growable: false),
        fence: fence,
        preDerivedMaterial: material,
        preCommitGuard: () => _isFenceStillValid(
          capturedEpoch: capturedEpoch,
          capturedGeneration: capturedGeneration,
          capturedActorId: actor.userId,
        ),
      );
    });

    if (!_isFenceStillValid(
      capturedEpoch: capturedEpoch,
      capturedGeneration: capturedGeneration,
      capturedActorId: actor.userId,
    )) {
      throw ParentGateFencedOperationException(
        'Session invalidated while completing manual unbound recovery.',
      );
    }

    _containmentEpoch++;

    final selectedFamily = verifiedFamilies.firstWhere(
      (f) => f.id.value == targetFamilyId,
    );
    _preferredFamilyOverride = selectedFamily;
    _sessionScopeEpoch++;
    await _runRehydrate(showHydrating: false);
    return installedCred;
  }

  /// Switches the active household among the authenticated adult's verified
  /// families (`ParentMode` ONLY; increments `sessionScopeEpoch` so all screen
  /// caches rebuild cleanly).
  Future<void> switchActiveFamily(Family targetFamily) async {
    if (!ref.mounted ||
        state.status != ColdStartContainmentStatus.verifiedParentMode) {
      throw StateError(
        'Switching families is permitted only in verified Parent Mode.',
      );
    }
    if (!state.verifiedFamilies.any((f) => f.id == targetFamily.id)) {
      throw StateError(
        'Selected family is not among positively verified active adult memberships.',
      );
    }
    final actor = state.actorContext;
    if (actor == null) {
      throw StateError('Missing actor context during family switch.');
    }

    await _arbiter.run(() async {
      final store = ref.read(localMetadataStoreProvider);
      final rawFence = await store.readMetadata(
        ParentGateService.containmentFenceV1Key,
      );
      final parsedFence = ContainmentFenceV1.tryParse(rawFence);
      final nowUtc = ref.read(appClockProvider)();
      final nextFence = ContainmentFenceV1(
        version: 1,
        fenceEpoch: (parsedFence?.fenceEpoch ?? 0) + 1,
        actorUserId: actor.userId,
        sessionGeneration:
            (parsedFence?.sessionGeneration ?? 0) > _sessionGenerationOrdinal
            ? parsedFence!.sessionGeneration
            : _sessionGenerationOrdinal,
        lockState: ContainmentFenceLockState.none,
        updatedAtUtc: nowUtc,
      );
      await store.compareAndSwapMetadataBatch(
        expectedValues: {ParentGateService.containmentFenceV1Key: rawFence},
        mutations: [
          MetadataMutation.upsert(
            key: ParentGateService.containmentFenceV1Key,
            value: nextFence.toJsonString(),
            updatedAt: nowUtc,
          ),
        ],
      );
    });

    if (!ref.mounted) return;
    _preferredFamilyOverride = targetFamily;
    _sessionScopeEpoch++;
    ref.read(activeFamilyProvider.notifier).selectFamily(targetFamily);
    state = state.copyWith(
      verifiedFamily: targetFamily,
      sessionScopeEpoch: _sessionScopeEpoch,
    );
  }

  /// Flow A — Normal Adult Sign Out (`D4`, `R38-08`).
  ///
  /// Strictly blocked inside active Child Mode OR whenever any unresolved
  /// `containment_recovery_lock_v1` / unresolved `active_child_session` lock exists.
  /// Advances `containment_fence_v1`, clears in-memory caches, preserves PIN /
  /// lockout / drafts / reward commands / photos, and signs out cleanly.
  Future<void> signOutNormal() async {
    if (!ref.mounted) return;
    if (state.isActiveChildMode ||
        state.status == ColdStartContainmentStatus.containmentLocked) {
      throw StateError(
        'Normal sign out is forbidden during active Child Mode or locked containment.',
      );
    }

    final currentGen = ref
        .read(authSessionPortProvider)
        .currentSessionGeneration;
    await _arbiter.run(() async {
      final store = ref.read(localMetadataStoreProvider);
      final rawLock = await store.readMetadata(containmentRecoveryLockV1Key);
      final rawChild = await store.readMetadata(
        ActiveChildModeNotifier.activeSessionKey,
      );
      final rawFence = await store.readMetadata(
        ParentGateService.containmentFenceV1Key,
      );
      final parsedFence = ContainmentFenceV1.tryParse(rawFence);

      final isPairedSessionOnly =
          rawLock == null &&
          (state.status == ColdStartContainmentStatus.pairedChildRevoked ||
              state.status == ColdStartContainmentStatus.pairedChildUnverified);
      final parsedChild = PersistedChildModeSession.tryParse(rawChild);
      final hasPairedChildEnvelope =
          parsedChild is ValidPersistedChildModeSessionV2 &&
          parsedChild.session.modeKind ==
              PersistedChildModeKind.pairedChildDevice;

      if (rawLock != null ||
          parsedFence?.lockState ==
              ContainmentFenceLockState.containmentLocked ||
          parsedFence?.lockState ==
              ContainmentFenceLockState.recoveryReauthPending ||
          (rawChild != null &&
              state.status != ColdStartContainmentStatus.verifiedParentMode &&
              !(isPairedSessionOnly && hasPairedChildEnvelope))) {
        throw StateError(
          'Cannot perform normal sign out while an unresolved containment lock exists.',
        );
      }

      final nowUtc = ref.read(appClockProvider)();
      final nextFence = ContainmentFenceV1(
        version: 1,
        fenceEpoch: (parsedFence?.fenceEpoch ?? 0) + 1,
        actorUserId: null,
        sessionGeneration:
            (parsedFence?.sessionGeneration ?? 0) > _sessionGenerationOrdinal
            ? parsedFence!.sessionGeneration
            : _sessionGenerationOrdinal,
        lockState: ContainmentFenceLockState.none,
        updatedAtUtc: nowUtc,
      );

      await store.compareAndSwapMetadataBatch(
        expectedValues: {
          ParentGateService.containmentFenceV1Key: rawFence,
          ActiveChildModeNotifier.activeSessionKey: rawChild,
          containmentRecoveryLockV1Key: null,
        },
        mutations: [
          MetadataMutation.upsert(
            key: ParentGateService.containmentFenceV1Key,
            value: nextFence.toJsonString(),
            updatedAt: nowUtc,
          ),
          if (rawChild != null)
            const MetadataMutation.delete(
              key: ActiveChildModeNotifier.activeSessionKey,
            ),
        ],
      );
    });

    if (!ref.mounted) return;
    _lastSignedOutSessionGeneration =
        currentGen ?? _lastVerifiedSessionGeneration;
    _engageSyncFailClosedMask(
      toUnauthenticated: true,
      reason: 'normal_sign_out',
      persistFence: false,
    );
    await ref.read(restrictedShellSignOutProvider)();
    if (!ref.mounted) return;
    await _runRehydrate(showHydrating: false);
  }

  /// Flow B — `ChildModeContainmentLocked` Recovery Sign Out (`Exit Path B`, `D4`, `R38-08`).
  ///
  /// Evaluates `D1.6` 3-level ownership provenance and durably persists
  /// `containment_recovery_lock_v1` + `containment_fence_v1` BEFORE calling
  /// `auth.signOut()`, retaining `active_child_session`, drafts, commands, and
  /// photos intact on disk.
  Future<void> signOutFromContainmentRecovery({
    ContainmentRecoveryReason? reason,
  }) async {
    if (!ref.mounted) return;
    final gateService = ref.read(parentGateServiceProvider);
    final provenance = ref.read(legacyOutboxProvenanceSourceProvider);
    final currentGen =
        ref.read(authSessionPortProvider).currentSessionGeneration ??
        state.actorContext?.sessionGeneration ??
        _lastVerifiedSessionGeneration;
    final currentActorId =
        state.actorContext?.userId ?? _lastVerifiedActorUserId;

    await _arbiter.run(() async {
      final store = ref.read(localMetadataStoreProvider);
      final rawChild = await store.readMetadata(
        ActiveChildModeNotifier.activeSessionKey,
      );
      final rawLock = await store.readMetadata(containmentRecoveryLockV1Key);
      final rawFence = await store.readMetadata(
        ParentGateService.containmentFenceV1Key,
      );
      final parsedFence = ContainmentFenceV1.tryParse(rawFence);
      final parsedChild = PersistedChildModeSession.tryParse(rawChild);
      final validV2 = parsedChild is ValidPersistedChildModeSessionV2
          ? parsedChild.session
          : null;
      final hint = LegacyChildHint.tryParse(rawChild);

      final existingLock = ContainmentRecoveryLockV1.parseStorageValue(rawLock);
      final resolution = await gateService.resolveLegacyOwnership(
        provenanceSource: provenance,
        hasPositiveServerAdultVerification:
            state.hasPositiveActiveAdultMembership,
        verifiedActiveAdultFamilyIds: state.verifiedFamilies
            .map((f) => f.id.value)
            .toList(growable: false),
        legacyChildSessionRaw: rawChild,
      );
      final cred = await gateService.inspectCredential();
      final nowUtc = ref.read(appClockProvider)();

      final effectiveReason =
          reason ??
          (existingLock is ValidContainmentRecoveryLockV1
              ? existingLock.lock.reason
              : _inferRecoveryReason(
                  parsedChild: parsedChild,
                  credStatus: cred.status,
                  outcome: state.verificationOutcome,
                  actorUserId: currentActorId,
                ));

      late final ContainmentRecoveryOwnershipLevel ownershipLevel;
      String? requiredOwnerFamilyId;
      String? originActorUserId = validV2?.actorUserId ?? currentActorId;

      if (cred.status == ParentGateCredentialStatus.validV2 &&
          cred.v2?.ownerFamilyId != null) {
        ownershipLevel = ContainmentRecoveryOwnershipLevel.boundV2;
        requiredOwnerFamilyId = cred.v2!.ownerFamilyId;
        originActorUserId ??= cred.v2!.configuredByActorUserId;
      } else if (validV2 != null) {
        ownershipLevel = ContainmentRecoveryOwnershipLevel.boundV2;
        requiredOwnerFamilyId = validV2.familyId.value;
      } else if (resolution is BoundOwnerResolution) {
        ownershipLevel = ContainmentRecoveryOwnershipLevel.boundV2;
        requiredOwnerFamilyId = resolution.ownerFamilyId;
      } else if (resolution is CorroboratedLegacyOwnerResolution) {
        ownershipLevel = ContainmentRecoveryOwnershipLevel.corroboratedLegacy;
        requiredOwnerFamilyId = resolution.familyId;
        originActorUserId ??=
            resolution.corroboratingRecords.firstOrNull?.actorUserId;
      } else {
        ownershipLevel = ContainmentRecoveryOwnershipLevel.unresolvable;
        requiredOwnerFamilyId = null;
      }

      final recoveryLock = ContainmentRecoveryLockV1(
        version: 1,
        reason: effectiveReason,
        ownershipLevel: ownershipLevel,
        requiredOwnerFamilyId: requiredOwnerFamilyId,
        unverifiedLegacyHintFamilyId: validV2?.familyId.value ?? hint?.familyId,
        originActorUserId: originActorUserId,
        initiatedFromSessionGeneration:
            (currentGen != null && currentGen.trim().isNotEmpty)
            ? currentGen.trim()
            : 'unverified-session',
        initiatedAtUtc: nowUtc,
      );

      final nextFence = ContainmentFenceV1(
        version: 1,
        fenceEpoch: (parsedFence?.fenceEpoch ?? 0) + 1,
        actorUserId: null,
        sessionGeneration:
            (parsedFence?.sessionGeneration ?? 0) > _sessionGenerationOrdinal
            ? parsedFence!.sessionGeneration
            : _sessionGenerationOrdinal,
        lockState: ContainmentFenceLockState.recoveryReauthPending,
        updatedAtUtc: nowUtc,
      );

      // Preserve any pre-existing persisted recovery lock byte-for-byte (`Fix 4`).
      await store.compareAndSwapMetadataBatch(
        expectedValues: {
          containmentRecoveryLockV1Key: rawLock,
          ParentGateService.containmentFenceV1Key: rawFence,
          ActiveChildModeNotifier.activeSessionKey: rawChild,
        },
        mutations: [
          if (rawLock == null)
            MetadataMutation.upsert(
              key: containmentRecoveryLockV1Key,
              value: recoveryLock.toJsonString(),
              updatedAt: nowUtc,
            ),
          MetadataMutation.upsert(
            key: ParentGateService.containmentFenceV1Key,
            value: nextFence.toJsonString(),
            updatedAt: nowUtc,
          ),
        ],
      );
    });

    if (!ref.mounted) return;
    _lastSignedOutSessionGeneration = currentGen;
    _engageSyncFailClosedMask(
      toUnauthenticated: true,
      reason: 'recovery_sign_out_exit_path_b',
      persistFence: false,
    );
    await ref.read(restrictedShellSignOutProvider)();
    if (!ref.mounted) return;
    await _runRehydrate(showHydrating: false);
  }

  /// Dispatches either Normal Sign Out or Recovery Sign Out depending on the
  /// current restricted/non-child state (`R40-03`, `D4`).
  Future<void> signOutFromRestrictedShell() async {
    if (!ref.mounted) return;
    if (state.status == ColdStartContainmentStatus.containmentLocked) {
      await signOutFromContainmentRecovery();
      return;
    }
    await signOutNormal();
  }

  ContainmentRecoveryReason _inferRecoveryReason({
    required PersistedChildModeParseResult parsedChild,
    required ParentGateCredentialStatus credStatus,
    required ContainmentVerificationOutcome? outcome,
    required String? actorUserId,
  }) {
    if (outcome is AuthorizedAdultChildUnavailable &&
        outcome.reason == TargetChildUnavailabilityReason.confirmedArchived) {
      return ContainmentRecoveryReason.childArchived;
    }
    if (credStatus == ParentGateCredentialStatus.corrupt) {
      return ContainmentRecoveryReason.corruptPin;
    }
    if (parsedChild is LegacyV1OrMalformedChildModeSession) {
      return ContainmentRecoveryReason.legacyOrMalformedSession;
    }
    if (parsedChild is ValidPersistedChildModeSessionV2 &&
        actorUserId != null &&
        parsedChild.session.actorUserId != actorUserId) {
      return ContainmentRecoveryReason.actorMismatch;
    }
    if (outcome is NoActiveFamilyMembershipObserved ||
        outcome is ConfirmedAdultMembershipRevoked ||
        outcome is AuthorizedAdultChildUnavailable) {
      return ContainmentRecoveryReason.adultMembershipAbsentOrRevoked;
    }
    return ContainmentRecoveryReason.forgottenPin;
  }

  Future<void> _runRehydrate({required bool showHydrating}) async {
    if (!ref.mounted) return;
    _rehydratePending = false;
    if (!showHydrating) {
      _pendingHideHydrating = true;
    }
    if (_rehydrateRunning) {
      _rehydrateNeedsRerun = true;
      await _rehydrateDoneCompleter?.future;
      return;
    }

    _rehydrateRunning = true;
    final completer = Completer<void>();
    _rehydrateDoneCompleter = completer;
    try {
      do {
        _rehydrateNeedsRerun = false;
        final suppressHydrating = _pendingHideHydrating;
        _pendingHideHydrating = false;
        await _performRehydratePass(showHydrating: !suppressHydrating);
      } while (ref.mounted && _rehydrateNeedsRerun);
    } finally {
      _rehydrateRunning = false;
      _pendingHideHydrating = false;
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_rehydrateDoneCompleter, completer)) {
        _rehydrateDoneCompleter = null;
      }
    }
  }

  Future<void> _pauseMismatchedActorRewardCommands(
    ValidatedActorContext actor,
  ) async {
    try {
      final commandStore = ref.read(pendingRewardCommandStoreProvider);
      final pending = await commandStore.listPendingCommands(
        recoveryState: CommandRecoveryState.active,
      );
      if (!ref.mounted || pending.isEmpty) {
        return;
      }
      final nowUtc = ref.read(appClockProvider)();
      for (final cmd in pending) {
        final cmdActor = cmd.actorUserId?.trim();
        if (cmdActor != null &&
            cmdActor.isNotEmpty &&
            cmdActor != actor.userId) {
          await commandStore.pauseMismatchedActorCommand(
            commandId: cmd.commandId,
            familyId: cmd.familyId,
            authenticatedActorId: actor.userId,
            mismatchReason: 'Paused automatically because active session switched from another user.',
            now: nowUtc,
          );
        }
      }
    } catch (_) {
      // Non-fatal in recovery/diagnostic edge cases; never blocks containment resolution.
    }
  }

  Future<void> _performRehydratePass({required bool showHydrating}) async {
    if (!ref.mounted) return;
    if (showHydrating &&
        state.status != ColdStartContainmentStatus.unauthenticated) {
      state = ColdStartContainmentState(
        status: ColdStartContainmentStatus.hydrating,
        sessionScopeEpoch: _sessionScopeEpoch,
      );
    }

    final store = ref.read(localMetadataStoreProvider);
    final rawChild = await store.readMetadata(
      ActiveChildModeNotifier.activeSessionKey,
    );
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    final rawLock = await store.readMetadata(containmentRecoveryLockV1Key);
    final rawFence = await store.readMetadata(
      ParentGateService.containmentFenceV1Key,
    );
    final rawAudit = await store.readMetadata(
      ParentGateService.lastContainmentRecoveryAuditV1Key,
    );
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    final parsedSession = PersistedChildModeSession.tryParse(rawChild);
    final parsedLock = ContainmentRecoveryLockV1.parseStorageValue(rawLock);
    final parsedFence = ContainmentFenceV1.tryParse(rawFence);
    final parsedAudit = LastContainmentRecoveryAuditV1.tryParse(rawAudit);

    final authPort = ref.read(authSessionPortProvider);
    final actor = await authPort.validateForMutation();
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    final nowUtc = ref.read(appClockProvider)();
    if (actor == null || !actor.isValidAt(nowUtc)) {
      _pendingCreatedFamily = null;
      _preferredFamilyOverride = null;
      _lastVerifiedActorUserId = null;
      _lastVerifiedSessionGeneration = null;
      _clearInMemoryProtectedState();
      state = ColdStartContainmentState(
        status: ColdStartContainmentStatus.unauthenticated,
        persistedSessionResult: parsedSession,
        recoveryLockResult: parsedLock,
        containmentFence: parsedFence,
        lastRecoveryAudit: parsedAudit,
        sessionScopeEpoch: _sessionScopeEpoch,
        diagnosticReason: 'unauthenticated_or_expired',
      );
      return;
    }

    final actorChanged =
        (_lastVerifiedActorUserId != null &&
            _lastVerifiedActorUserId != actor.userId) ||
        (_lastVerifiedSessionGeneration != null &&
            _lastVerifiedSessionGeneration != actor.sessionGeneration);
    if (actorChanged) {
      _pendingCreatedFamily = null;
      _preferredFamilyOverride = null;
      _sessionScopeEpoch++;
      _clearInMemoryProtectedState();
    }
    if (_pendingCreatedFamily != null &&
        !_pendingCreatedFamily!.matchesActor(
          actorUserId: actor.userId,
          sessionGeneration: actor.sessionGeneration,
        )) {
      _pendingCreatedFamily = null;
    }

    // Pause mismatched-actor active reward commands via non-dispatch SQLite CAS (`C0-34`).
    await _arbiter.run(() async {
      await _pauseMismatchedActorRewardCommands(actor);
    });
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    final validV2 = parsedSession is ValidPersistedChildModeSessionV2
        ? parsedSession.session
        : null;
    final preferredFamilyId =
        _pendingCreatedFamily?.family.id ??
        _preferredFamilyOverride?.id ??
        ref.read(activeFamilyProvider)?.id;
    final verifier = ref.read(containmentAuthorizationVerifierProvider);
    final outcome = await verifier.verifySession(
      context: actor,
      persistedChildSession: validV2,
      preferredFamilyId: preferredFamilyId,
    );
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    // Ensure auth session generation or actor did not rotate/switch mid-verification.
    final postVerifyActor = await authPort.validateForMutation();
    if (!ref.mounted || _rehydrateNeedsRerun) return;
    final postVerifyUtc = ref.read(appClockProvider)();
    if (authPort.currentSessionGeneration != actor.sessionGeneration ||
        postVerifyActor == null ||
        !postVerifyActor.isValidAt(postVerifyUtc) ||
        postVerifyActor.userId != actor.userId ||
        postVerifyActor.sessionGeneration != actor.sessionGeneration) {
      _pendingCreatedFamily = null;
      _preferredFamilyOverride = null;
      _lastVerifiedActorUserId = null;
      _lastVerifiedSessionGeneration = null;
      _clearInMemoryProtectedState();
      state = ColdStartContainmentState(
        status: ColdStartContainmentStatus.unauthenticated,
        persistedSessionResult: parsedSession,
        recoveryLockResult: parsedLock,
        containmentFence: parsedFence,
        lastRecoveryAudit: parsedAudit,
        sessionScopeEpoch: _sessionScopeEpoch,
        diagnosticReason: 'session_generation_rotated_mid_hydration',
      );
      return;
    }

    // Read credential status and legacy provenance whenever child/lock/PIN inspection is needed.
    final gateService = ref.read(parentGateServiceProvider);
    final credInspection = await gateService.inspectCredential();
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    LegacyOwnershipResolution? legacyResolution;
    final needsLegacyProvenance =
        parsedSession is LegacyV1OrMalformedChildModeSession ||
        credInspection.status == ParentGateCredentialStatus.legacyV1 ||
        parsedLock is ValidContainmentRecoveryLockV1;
    if (needsLegacyProvenance) {
      final verifiedAdultIds = switch (outcome) {
        AuthorizedActiveAdult(:final verifiedFamilies) =>
          verifiedFamilies.map((f) => f.id.value).toList(growable: false),
        AuthorizedAdultChildUnavailable(:final verifiedFamilies) =>
          verifiedFamilies.map((f) => f.id.value).toList(growable: false),
        _ => const <String>[],
      };
      legacyResolution = await gateService.resolveLegacyOwnership(
        provenanceSource: ref.read(legacyOutboxProvenanceSourceProvider),
        hasPositiveServerAdultVerification: verifiedAdultIds.isNotEmpty,
        verifiedActiveAdultFamilyIds: verifiedAdultIds,
        legacyChildSessionRaw: rawChild,
      );
      if (!ref.mounted || _rehydrateNeedsRerun) return;
    }

    final isFreshPostSignOutAuth =
        (_lastSignedOutSessionGeneration != null &&
            actor.sessionGeneration != _lastSignedOutSessionGeneration) ||
        (parsedLock is ValidContainmentRecoveryLockV1 &&
            actor.sessionGeneration !=
                parsedLock.lock.initiatedFromSessionGeneration);

    // Clear fail-closed mask now that postVerifyActor has passed live verification
    // cleanly ahead of any Exit Path B auto-unlock CAS commit.
    _isFailClosedMasked = false;

    // Check Exit Path B automatic lock clearance (`D1.6`, `D4`, `R38-08`, `R38-09`, `R38-10`).
    final autoUnlockFamilyId = resolveAutoUnlockOwnerFamilyId(
      actorContext: actor,
      recoveryLockResult: parsedLock,
      verificationOutcome: outcome,
      parentGateCredentialStatus: credInspection.status,
      pinOwnerFamilyId: credInspection.v2?.ownerFamilyId,
    );

    var effectiveSessionResult = parsedSession;
    var effectiveLockResult = parsedLock;
    var effectiveFence = parsedFence;
    var effectiveOutcome = outcome;
    var needsPinReconfig = false;

    if (autoUnlockFamilyId != null) {
      final capturedEpoch = _containmentEpoch;
      var autoUnlocked = false;
      ContainmentFenceV1? nextFence;

      await _arbiter.run(() async {
        final rawLockout = await store.readMetadata(
          ParentGateService.lockoutV1Key,
        );
        final parsedLockout = rawLockout == null
            ? null
            : ParentGateLockoutV1.tryParse(rawLockout);
        final commitUtc = ref.read(appClockProvider)();
        nextFence = ContainmentFenceV1(
          version: 1,
          fenceEpoch: (parsedFence?.fenceEpoch ?? 0) + 1,
          actorUserId: actor.userId,
          sessionGeneration:
              (parsedFence?.sessionGeneration ?? 0) > _sessionGenerationOrdinal
              ? parsedFence!.sessionGeneration
              : _sessionGenerationOrdinal,
          lockState: ContainmentFenceLockState.none,
          updatedAtUtc: commitUtc,
        );

        final mutations = <MetadataMutation>[
          if (rawChild != null)
            const MetadataMutation.delete(
              key: ActiveChildModeNotifier.activeSessionKey,
            ),
          if (rawLock != null)
            const MetadataMutation.delete(key: containmentRecoveryLockV1Key),
          MetadataMutation.upsert(
            key: ParentGateService.containmentFenceV1Key,
            value: nextFence!.toJsonString(),
            updatedAt: commitUtc,
          ),
        ];
        if (parsedLockout != null) {
          final resetLockout = ParentGateLockoutV1(
            version: 1,
            revision: parsedLockout.revision + 1,
            failedAttempts: 0,
            lockoutUntilUtc: null,
            lockoutDurationSeconds: 0,
            lockoutOwnerAttemptId: null,
            lastAttemptAtUtc: parsedLockout.lastAttemptAtUtc,
            credentialRevision: parsedLockout.credentialRevision,
            inFlightReservations: const [],
          );
          mutations.add(
            MetadataMutation.upsert(
              key: ParentGateService.lockoutV1Key,
              value: resetLockout.toJsonString(),
              updatedAt: commitUtc,
            ),
          );
        }

        autoUnlocked = await store.compareAndSwapMetadataBatch(
          expectedValues: {
            ActiveChildModeNotifier.activeSessionKey: rawChild,
            containmentRecoveryLockV1Key: rawLock,
            ParentGateService.containmentFenceV1Key: rawFence,
            ParentGateService.lockoutV1Key: ?rawLockout,
          },
          mutations: mutations,
          preCommitGuard: () =>
              ref.mounted &&
              !_isFailClosedMasked &&
              _containmentEpoch == capturedEpoch &&
              authPort.currentSessionGeneration == actor.sessionGeneration,
        );
      });

      if (!ref.mounted ||
          _rehydrateNeedsRerun ||
          _isFailClosedMasked ||
          _containmentEpoch != capturedEpoch ||
          authPort.currentSessionGeneration != actor.sessionGeneration) {
        return;
      }

      if (autoUnlocked) {
        _containmentEpoch++;
        final lockReason =
            (parsedLock as ValidContainmentRecoveryLockV1).lock.reason;
        needsPinReconfig =
            lockReason == ContainmentRecoveryReason.corruptPin ||
            lockReason == ContainmentRecoveryReason.forgottenPin ||
            credInspection.status != ParentGateCredentialStatus.validV2;
        effectiveSessionResult = const AbsentPersistedChildModeSession();
        effectiveLockResult = const AbsentContainmentRecoveryLock();
        effectiveFence = nextFence;
        _sessionScopeEpoch++;

        if (effectiveOutcome is AuthorizedAdultChildUnavailable) {
          final unavail = effectiveOutcome;
          final targetFamily = unavail.verifiedFamilies.firstWhere(
            (f) => f.id.value == autoUnlockFamilyId,
            orElse: () => unavail.verifiedFamily,
          );
          effectiveOutcome = AuthorizedActiveAdult(
            verifiedRole:
                unavail.verifiedRolesByFamilyId[targetFamily.id.value]!,
            verifiedFamily: targetFamily,
            verifiedFamilies: unavail.verifiedFamilies,
            verifiedRolesByFamilyId: unavail.verifiedRolesByFamilyId,
          );
        } else if (effectiveOutcome is AuthorizedActiveAdult) {
          final active = effectiveOutcome;
          final targetFamily = active.verifiedFamilies.firstWhere(
            (f) => f.id.value == autoUnlockFamilyId,
            orElse: () => active.verifiedFamily,
          );
          effectiveOutcome = AuthorizedActiveAdult(
            verifiedRole:
                active.verifiedRolesByFamilyId[targetFamily.id.value]!,
            verifiedFamily: targetFamily,
            verifiedFamilies: active.verifiedFamilies,
            verifiedRolesByFamilyId: active.verifiedRolesByFamilyId,
          );
        }
      }
    }

    // Confirmed paired-child revocation clears ONLY a `paired_child_device`
    // envelope when NO adult recovery lock exists (`D4`, `C0-35`).
    if (effectiveOutcome is ConfirmedPairedChildGrantRevoked &&
        effectiveLockResult is AbsentContainmentRecoveryLock &&
        effectiveSessionResult is ValidPersistedChildModeSessionV2 &&
        effectiveSessionResult.session.modeKind ==
            PersistedChildModeKind.pairedChildDevice &&
        rawChild != null) {
      await _arbiter.run(() async {
        await store.compareAndSwapMetadataBatch(
          expectedValues: {
            ActiveChildModeNotifier.activeSessionKey: rawChild,
            containmentRecoveryLockV1Key: null,
          },
          mutations: const [
            MetadataMutation.delete(
              key: ActiveChildModeNotifier.activeSessionKey,
            ),
          ],
          preCommitGuard: () =>
              ref.mounted &&
              authPort.currentSessionGeneration == actor.sessionGeneration,
        );
      });
      if (!ref.mounted || _rehydrateNeedsRerun) return;
      effectiveSessionResult = const AbsentPersistedChildModeSession();
    }

    final resolved = resolveColdStartContainmentState(
      actorContext: actor,
      persistedSessionResult: effectiveSessionResult,
      recoveryLockResult: effectiveLockResult,
      verificationOutcome: effectiveOutcome,
      parentGateCredentialStatus: credInspection.status,
      pinOwnerFamilyId: credInspection.v2?.ownerFamilyId,
      legacyOwnershipResolution: legacyResolution,
      containmentFence: effectiveFence,
      lastRecoveryAudit: parsedAudit,
      sessionScopeEpoch: _sessionScopeEpoch,
      isPostSignOutFreshAdultAuth: isFreshPostSignOutAuth,
      needsPinReconfigurationAfterRecovery: needsPinReconfig,
    );

    _lastVerifiedActorUserId = actor.userId;
    _lastVerifiedSessionGeneration = actor.sessionGeneration;

    final confirmedPendingFamily =
        _pendingCreatedFamily != null &&
        _pendingCreatedFamily!.matchesActor(
          actorUserId: actor.userId,
          sessionGeneration: actor.sessionGeneration,
        ) &&
        resolved.status == ColdStartContainmentStatus.verifiedParentMode &&
        resolved.verifiedFamily?.id == _pendingCreatedFamily!.family.id;
    if (confirmedPendingFamily ||
        resolved.status == ColdStartContainmentStatus.adultAccessRestricted ||
        resolved.status == ColdStartContainmentStatus.pairedChildRevoked ||
        resolved.status == ColdStartContainmentStatus.pairedChildUnverified ||
        resolved.status == ColdStartContainmentStatus.containmentLocked ||
        resolved.status == ColdStartContainmentStatus.unauthenticated) {
      _pendingCreatedFamily = null;
    }

    _applyInMemoryState(
      resolved,
      effectiveOutcome,
      forceSelectVerifiedFamily:
          confirmedPendingFamily || autoUnlockFamilyId != null,
    );
    state = resolved;
  }

  void _clearInMemoryProtectedState() {
    _restoredFromPersistedBootstrap = false;
    ref.read(activeFamilyProvider.notifier).selectFamily(null);
    ref.read(activeChildModeProvider.notifier).restoreVerifiedChild(null);
  }

  void _applyInMemoryState(
    ColdStartContainmentState resolved,
    ContainmentVerificationOutcome outcome, {
    bool forceSelectVerifiedFamily = false,
  }) {
    if (!resolved.allowsProtectedUi) {
      _clearInMemoryProtectedState();
      return;
    }

    if (resolved.status == ColdStartContainmentStatus.verifiedParentMode) {
      final currentFamily = ref.read(activeFamilyProvider);
      final verifiedFamilies = switch (outcome) {
        AuthorizedActiveAdult(:final verifiedFamilies) => verifiedFamilies,
        _ => const <Family>[],
      };
      if (forceSelectVerifiedFamily ||
          currentFamily == null ||
          !verifiedFamilies.any((f) => f.id == currentFamily.id)) {
        ref
            .read(activeFamilyProvider.notifier)
            .selectFamily(resolved.verifiedFamily);
      }
      if (_restoredFromPersistedBootstrap) {
        _restoredFromPersistedBootstrap = false;
        ref.read(activeChildModeProvider.notifier).restoreVerifiedChild(null);
      }
      return;
    }

    _restoredFromPersistedBootstrap = true;
    ref
        .read(activeFamilyProvider.notifier)
        .selectFamily(resolved.verifiedFamily);
    ref
        .read(activeChildModeProvider.notifier)
        .restoreVerifiedChild(resolved.verifiedChild);
  }
}

/// Fail-closed hydrating screen shown until identity and server authorization resolve.
class ContainmentHydratingScreen extends StatelessWidget {
  const ContainmentHydratingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: const Key('containment_hydrating_screen'),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: AppSpacing.md),
                Text(
                  'Verifying session...',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Data-free restricted containment shells exposing zero child/family PII (`WP2` + `WP3`).
class ColdStartRestrictedShell extends StatefulWidget {
  const ColdStartRestrictedShell({
    super.key,
    required this.containmentState,
    required this.onRetry,
    required this.onSignOut,
    this.onAttemptExitPathAPin,
    this.onSubmitManualUnboundRecovery,
    this.onOpenCreateFamily,
  });

  final ColdStartContainmentState containmentState;
  final VoidCallback onRetry;
  final Future<void> Function() onSignOut;
  final Future<PinVerificationResult> Function(String pin)?
  onAttemptExitPathAPin;
  final Future<void> Function({
    required String newPin,
    required String targetFamilyId,
  })?
  onSubmitManualUnboundRecovery;
  final VoidCallback? onOpenCreateFamily;

  @override
  State<ColdStartRestrictedShell> createState() =>
      _ColdStartRestrictedShellState();
}

class _ColdStartRestrictedShellState extends State<ColdStartRestrictedShell> {
  bool _isSigningOut = false;
  String? _signOutError;
  bool _isManualRecovering = false;
  String? _manualRecoveryError;
  bool _manualConfirmed = false;
  String? _selectedRecoveryFamilyId;
  final _newPinController = TextEditingController();
  final _confirmPinController = TextEditingController();

  @override
  void dispose() {
    _newPinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _handleSignOut() async {
    if (_isSigningOut) return;
    setState(() {
      _isSigningOut = true;
      _signOutError = null;
    });
    try {
      await widget.onSignOut();
    } catch (_) {
      if (mounted) {
        setState(() {
          _signOutError =
              'Unable to complete sign out right now. Please try again.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSigningOut = false;
        });
      }
    }
  }

  Future<void> _handleManualUnboundRecovery() async {
    if (_isManualRecovering) return;
    final submit = widget.onSubmitManualUnboundRecovery;
    if (submit == null) return;
    final verifiedFamilies = widget.containmentState.verifiedFamilies;
    final selectedFamilyId =
        _selectedRecoveryFamilyId ??
        (verifiedFamilies.isNotEmpty ? verifiedFamilies.first.id.value : null);
    final newPin = _newPinController.text.trim();
    final confirmPin = _confirmPinController.text.trim();

    if (!_manualConfirmed) {
      setState(() {
        _manualRecoveryError = 'Please confirm that local child drafts and evidence will be preserved in quarantine.';
      });
      return;
    }
    if (selectedFamilyId == null || selectedFamilyId.isEmpty) {
      setState(() {
        _manualRecoveryError = 'Select a verified household to continue.';
      });
      return;
    }
    if (!RegExp(r'^\d{4}$').hasMatch(newPin)) {
      setState(() {
        _manualRecoveryError = 'New Parent PIN must be exactly 4 digits.';
      });
      return;
    }
    if (newPin != confirmPin) {
      setState(() {
        _manualRecoveryError = 'Parent PIN entries do not match.';
      });
      return;
    }

    setState(() {
      _isManualRecovering = true;
      _manualRecoveryError = null;
    });
    try {
      await submit(newPin: newPin, targetFamilyId: selectedFamilyId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _manualRecoveryError = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isManualRecovering = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.containmentState.status;

    final ({Key key, IconData icon, String title, String message}) details =
        switch (status) {
          ColdStartContainmentStatus.containmentLocked => (
            key: const Key('cold_start_containment_locked_shell'),
            icon: Icons.lock_outline,
            title: 'Child Mode Containment Locked',
            message: 'This shared device requires parent verification before continuing. Local unsynced work remains safely preserved.',
          ),
          ColdStartContainmentStatus.pairedChildRevoked => (
            key: const Key('cold_start_paired_child_revoked_shell'),
            icon: Icons.phonelink_lock_outlined,
            title: 'Device Access Revoked',
            message: 'Device access has been revoked by a family parent. Local drafts and photos remain preserved on this device.',
          ),
          ColdStartContainmentStatus.pairedChildUnverified => (
            key: const Key('cold_start_paired_child_unverified_shell'),
            icon: Icons.wifi_tethering_error_rounded_outlined,
            title: 'Child Device Verification Unavailable',
            message: 'Unable to verify this device grant right now. Check your connection and retry.',
          ),
          ColdStartContainmentStatus.authorizationUnverified =>
            widget.containmentState.verificationOutcome
                        is SessionAuthorizationUnverified &&
                    (widget.containmentState.verificationOutcome!
                                as SessionAuthorizationUnverified)
                            .diagnosticCode ==
                        'membership_invited'
                ? (
                    key: const Key('cold_start_authorization_unverified_shell'),
                    icon: Icons.mark_email_unread_outlined,
                    title: 'Pending Family Invitation',
                    message: 'Your family invitation is not active yet. Retry verification once it has been activated, or sign out to switch accounts.',
                  )
                : (
                    key: const Key('cold_start_authorization_unverified_shell'),
                    icon: Icons.cloud_off_outlined,
                    title: 'Verification Unavailable',
                    message: 'Unable to verify your family access with the server right now. Check your connection and retry.',
                  ),
          ColdStartContainmentStatus.adultAccessRestricted => (
            key: const Key('cold_start_adult_access_restricted_shell'),
            icon: Icons.gpp_maybe_outlined,
            title: 'Account Access Restricted',
            message: 'No active parent membership is enabled on this account. Retry verification or contact your family owner.',
          ),
          ColdStartContainmentStatus.noActiveFamilyMembership => (
            key: const Key('cold_start_no_active_family_shell'),
            icon: Icons.family_restroom,
            title: 'No Family Found',
            message: 'No active family membership was found for this account. Create a new family or sign in with another parent account.',
          ),
          _ => (
            key: const Key('cold_start_containment_locked_shell'),
            icon: Icons.lock_outline,
            title: 'Verification Required',
            message: 'Session verification is required before continuing.',
          ),
        };

    final allowsExitPathA =
        widget.containmentState.allowsExitPathAPinAttempt &&
        widget.onAttemptExitPathAPin != null;
    final allowsManualRecovery =
        widget.containmentState.allowsManualUnboundLegacyRecovery &&
        widget.onSubmitManualUnboundRecovery != null;
    final verifiedFamilies = widget.containmentState.verifiedFamilies;
    final effectiveSelectedFamilyId =
        _selectedRecoveryFamilyId ??
        (verifiedFamilies.isNotEmpty ? verifiedFamilies.first.id.value : null);

    return Scaffold(
      key: details.key,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    details.icon,
                    size: 64,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    details.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    details.message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (_signOutError != null) ...[
                    Text(
                      _signOutError!,
                      key: const Key('cold_start_sign_out_error'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  if (allowsExitPathA) ...[
                    FilledButton.icon(
                      key: const Key('containment_enter_pin_unlock_button'),
                      onPressed: _isSigningOut || _isManualRecovering
                          ? null
                          : () {
                              ParentGateDialog.show(
                                context,
                                onGatePassed: () {},
                                onSubmitPin: widget.onAttemptExitPathAPin,
                              );
                            },
                      icon: const Icon(Icons.pin_outlined),
                      label: const Text('Unlock with Parent PIN'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (allowsManualRecovery) ...[
                    Card(
                      key: const Key('manual_unbound_recovery_card'),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Restricted Manual Recovery',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              'This device has an unresolved legacy session with unknown household ownership. Confirming creates a new Parent PIN for your selected family while preserving all local drafts and evidence.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            DropdownButtonFormField<String>(
                              key: const Key(
                                'manual_unbound_recovery_family_dropdown',
                              ),
                              initialValue: effectiveSelectedFamilyId,
                              decoration: const InputDecoration(
                                labelText: 'Verified Household',
                                border: OutlineInputBorder(),
                              ),
                              items: verifiedFamilies
                                  .map(
                                    (f) => DropdownMenuItem<String>(
                                      value: f.id.value,
                                      child: Text(f.name),
                                    ),
                                  )
                                  .toList(growable: false),
                              onChanged: _isManualRecovering
                                  ? null
                                  : (value) {
                                      setState(() {
                                        _selectedRecoveryFamilyId = value;
                                      });
                                    },
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextField(
                              key: const Key(
                                'manual_unbound_recovery_pin_field',
                              ),
                              controller: _newPinController,
                              keyboardType: TextInputType.number,
                              obscureText: true,
                              maxLength: 4,
                              decoration: const InputDecoration(
                                labelText: 'New 4-digit Parent PIN',
                                border: OutlineInputBorder(),
                                counterText: '',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            TextField(
                              key: const Key(
                                'manual_unbound_recovery_confirm_pin_field',
                              ),
                              controller: _confirmPinController,
                              keyboardType: TextInputType.number,
                              obscureText: true,
                              maxLength: 4,
                              decoration: const InputDecoration(
                                labelText: 'Confirm Parent PIN',
                                border: OutlineInputBorder(),
                                counterText: '',
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            CheckboxListTile(
                              key: const Key(
                                'manual_unbound_recovery_confirm_checkbox',
                              ),
                              value: _manualConfirmed,
                              contentPadding: EdgeInsets.zero,
                              onChanged: _isManualRecovering
                                  ? null
                                  : (checked) {
                                      setState(() {
                                        _manualConfirmed = checked ?? false;
                                      });
                                    },
                              title: const Text(
                                'I confirm clearing this device lock while preserving local work.',
                              ),
                            ),
                            if (_manualRecoveryError != null) ...[
                              Text(
                                _manualRecoveryError!,
                                key: const Key('manual_unbound_recovery_error'),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                            ],
                            FilledButton(
                              key: const Key(
                                'manual_unbound_recovery_submit_button',
                              ),
                              onPressed: _isManualRecovering
                                  ? null
                                  : _handleManualUnboundRecovery,
                              child: Text(
                                _isManualRecovering
                                    ? 'Recovering...'
                                    : 'Confirm & Set New Parent PIN',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  if (status ==
                      ColdStartContainmentStatus.noActiveFamilyMembership) ...[
                    FilledButton(
                      key: const Key('create_family_button'),
                      onPressed: _isSigningOut
                          ? null
                          : () {
                              if (widget.onOpenCreateFamily != null) {
                                widget.onOpenCreateFamily!();
                                return;
                              }
                              final router = GoRouter.maybeOf(context);
                              if (router != null) {
                                router.go(AppRoutes.createFamily);
                                return;
                              }
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const CreateFamilyScreen(),
                                ),
                              );
                            },
                      child: const Text('Create Family'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  OutlinedButton.icon(
                    key: const Key('cold_start_retry_button'),
                    onPressed: _isSigningOut ? null : widget.onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry Verification'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton.icon(
                    key: const Key('cold_start_sign_out_button'),
                    onPressed: _isSigningOut ? null : _handleSignOut,
                    icon: _isSigningOut
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.logout),
                    label: Text(
                      _isSigningOut
                          ? 'Signing Out...'
                          : (status ==
                                    ColdStartContainmentStatus.containmentLocked
                                ? 'Sign Out & Verify Parent Account'
                                : 'Sign Out'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
