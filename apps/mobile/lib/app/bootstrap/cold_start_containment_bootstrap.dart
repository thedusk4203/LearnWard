import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/family/presentation/create_family_screen.dart';
import '../../features/shared_device/domain/parent_gate_models.dart';
import 'app_providers.dart';

/// Fail-closed cold-start containment state resolved before mounting protected routes.
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

/// Immutable cold-start verification snapshot.
final class ColdStartContainmentState {
  const ColdStartContainmentState({
    required this.status,
    this.actorContext,
    this.verificationOutcome,
    this.persistedSessionResult,
    this.recoveryLockResult,
    this.verifiedFamily,
    this.verifiedChild,
    this.diagnosticReason,
  });

  final ColdStartContainmentStatus status;
  final ValidatedActorContext? actorContext;
  final ContainmentVerificationOutcome? verificationOutcome;
  final PersistedChildModeParseResult? persistedSessionResult;
  final ContainmentRecoveryLockParseResult? recoveryLockResult;
  final Family? verifiedFamily;
  final ChildProfile? verifiedChild;
  final String? diagnosticReason;

  bool get isHydrating => status == ColdStartContainmentStatus.hydrating;

  bool get allowsProtectedUi =>
      status == ColdStartContainmentStatus.verifiedParentMode ||
      status == ColdStartContainmentStatus.verifiedChildMode ||
      status == ColdStartContainmentStatus.offlineContainedChildMode;

  @override
  String toString() =>
      'ColdStartContainmentState(status: ${status.name}, '
      'hasActor: ${actorContext != null}, '
      'hasVerifiedFamily: ${verifiedFamily != null}, '
      'hasVerifiedChild: ${verifiedChild != null}'
      '${diagnosticReason != null ? ', reason: $diagnosticReason' : ''})';
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
}) {
  final validV2 = persistedSessionResult is ValidPersistedChildModeSessionV2
      ? persistedSessionResult.session
      : null;
  final hasRecoveryLock = recoveryLockResult is! AbsentContainmentRecoveryLock;
  final hasLegacyOrMalformed =
      persistedSessionResult is LegacyV1OrMalformedChildModeSession;
  final hasActorMismatch =
      validV2 != null && validV2.actorUserId != actorContext.userId;

  if (hasRecoveryLock || hasLegacyOrMalformed || hasActorMismatch) {
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
      diagnosticReason: reason,
    );
  }

  final hasValidPinCredential =
      parentGateCredentialStatus == ParentGateCredentialStatus.validV2 ||
      parentGateCredentialStatus == ParentGateCredentialStatus.legacyV1;

  switch (verificationOutcome) {
    case AuthorizedActiveAdult(:final verifiedFamily, :final verifiedChild):
      if (validV2 != null) {
        final childMatches =
            validV2.modeKind == PersistedChildModeKind.sharedDeviceAdult &&
            hasValidPinCredential &&
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
          );
        }
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.containmentLocked,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
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
      );

    case AuthorizedAdultChildUnavailable(:final reason):
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.containmentLocked,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
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
          diagnosticReason: 'no_active_family_while_child_session_persisted',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.noActiveFamilyMembership,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
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
          diagnosticReason: 'shared_child_lock_preserved_over_revoked_grant',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.pairedChildRevoked,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
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
          diagnosticReason: 'shared_child_lock_preserved_over_unverified_grant',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.pairedChildUnverified,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
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
        diagnosticReason: reason,
      );

    case SessionAuthorizationUnverified(:final reason):
      if (validV2 != null &&
          validV2.modeKind == PersistedChildModeKind.sharedDeviceAdult &&
          hasValidPinCredential) {
        return ColdStartContainmentState(
          status: ColdStartContainmentStatus.offlineContainedChildMode,
          actorContext: actorContext,
          verificationOutcome: verificationOutcome,
          persistedSessionResult: persistedSessionResult,
          recoveryLockResult: recoveryLockResult,
          verifiedChild: validV2.childProfileSnapshot,
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
          diagnosticReason:
              'unverified_session_with_child_envelope_invalid_pin',
        );
      }
      return ColdStartContainmentState(
        status: ColdStartContainmentStatus.authorizationUnverified,
        actorContext: actorContext,
        verificationOutcome: verificationOutcome,
        persistedSessionResult: persistedSessionResult,
        recoveryLockResult: recoveryLockResult,
        diagnosticReason: reason,
      );
  }
}

/// Fail-closed cold-start coordinator gating [LearnWardApp] through `hydrating`
/// until live auth identity, persisted envelope v2, and server authorization are
/// verified (`WP2`; full runtime/arbiter lifecycle follows in `WP3`).
class ColdStartContainmentNotifier extends Notifier<ColdStartContainmentState> {
  static const String containmentRecoveryLockV1Key =
      'containment_recovery_lock_v1';

  bool _rehydratePending = false;
  bool _rehydrateRunning = false;
  bool _rehydrateNeedsRerun = false;
  Completer<void>? _rehydrateDoneCompleter;
  bool _restoredFromPersistedBootstrap = false;
  StreamSubscription<String?>? _sessionGenSub;

  @override
  ColdStartContainmentState build() {
    final authPort = ref.watch(authSessionPortProvider);
    _sessionGenSub?.cancel();
    _sessionGenSub = authPort.sessionGenerationStream.listen(
      (_) => _scheduleRehydrate(),
      onError: (_) => _scheduleRehydrate(),
    );
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (_, _) {
      _scheduleRehydrate();
    });
    ref.onDispose(() {
      _rehydratePending = false;
      _rehydrateNeedsRerun = false;
      final pendingCompleter = _rehydrateDoneCompleter;
      _rehydrateDoneCompleter = null;
      if (pendingCompleter != null && !pendingCompleter.isCompleted) {
        pendingCompleter.complete();
      }
      _sessionGenSub?.cancel();
      _sessionGenSub = null;
    });

    _scheduleRehydrate();
    return const ColdStartContainmentState(
      status: ColdStartContainmentStatus.hydrating,
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
    if (!ref.mounted) return;
    _rehydratePending = false;
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
        await _performRehydratePass();
      } while (ref.mounted && _rehydrateNeedsRerun);
    } finally {
      _rehydrateRunning = false;
      if (!completer.isCompleted) {
        completer.complete();
      }
      if (identical(_rehydrateDoneCompleter, completer)) {
        _rehydrateDoneCompleter = null;
      }
    }
  }

  Future<void> _performRehydratePass() async {
    if (!ref.mounted) return;
    state = const ColdStartContainmentState(
      status: ColdStartContainmentStatus.hydrating,
    );

    final store = ref.read(localMetadataStoreProvider);
    final rawChild = await store.readMetadata(
      ActiveChildModeNotifier.activeSessionKey,
    );
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    final rawLock = await store.readMetadata(containmentRecoveryLockV1Key);
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    final parsedSession = PersistedChildModeSession.tryParse(rawChild);
    final parsedLock = ContainmentRecoveryLockV1.parseStorageValue(rawLock);

    final authPort = ref.read(authSessionPortProvider);
    final actor = await authPort.validateForMutation();
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    final nowUtc = ref.read(appClockProvider)();
    if (actor == null || !actor.isValidAt(nowUtc)) {
      _clearInMemoryProtectedState();
      state = ColdStartContainmentState(
        status: ColdStartContainmentStatus.unauthenticated,
        persistedSessionResult: parsedSession,
        recoveryLockResult: parsedLock,
        diagnosticReason: 'unauthenticated_or_expired',
      );
      return;
    }

    final validV2 = parsedSession is ValidPersistedChildModeSessionV2
        ? parsedSession.session
        : null;
    final verifier = ref.read(containmentAuthorizationVerifierProvider);
    final outcome = await verifier.verifySession(
      context: actor,
      persistedChildSession: validV2,
      preferredFamilyId: ref.read(activeFamilyProvider)?.id,
    );
    if (!ref.mounted || _rehydrateNeedsRerun) return;

    // Ensure auth session generation did not invalidate/rotate mid-verification.
    if (authPort.currentSessionGeneration != actor.sessionGeneration) {
      _clearInMemoryProtectedState();
      state = ColdStartContainmentState(
        status: ColdStartContainmentStatus.unauthenticated,
        persistedSessionResult: parsedSession,
        recoveryLockResult: parsedLock,
        diagnosticReason: 'session_generation_rotated_mid_hydration',
      );
      return;
    }

    ParentGateCredentialStatus? pinStatus;
    if (validV2 != null &&
        validV2.modeKind == PersistedChildModeKind.sharedDeviceAdult &&
        validV2.actorUserId == actor.userId) {
      final inspection = await ref
          .read(parentGateServiceProvider)
          .inspectCredential();
      if (!ref.mounted || _rehydrateNeedsRerun) return;
      pinStatus = inspection.status;
    }

    final resolved = resolveColdStartContainmentState(
      actorContext: actor,
      persistedSessionResult: parsedSession,
      recoveryLockResult: parsedLock,
      verificationOutcome: outcome,
      parentGateCredentialStatus: pinStatus,
    );

    _applyInMemoryState(resolved, outcome);
    state = resolved;
  }

  void _clearInMemoryProtectedState() {
    _restoredFromPersistedBootstrap = false;
    ref.read(activeFamilyProvider.notifier).selectFamily(null);
    ref.read(activeChildModeProvider.notifier).restoreVerifiedChild(null);
  }

  void _applyInMemoryState(
    ColdStartContainmentState resolved,
    ContainmentVerificationOutcome outcome,
  ) {
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
      if (currentFamily == null ||
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

/// Data-free WP2 restricted containment shells exposing zero child/family PII.
class ColdStartRestrictedShell extends StatelessWidget {
  const ColdStartRestrictedShell({
    super.key,
    required this.containmentState,
    required this.onRetry,
  });

  final ColdStartContainmentState containmentState;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = containmentState.status;

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
          ColdStartContainmentStatus.authorizationUnverified => (
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
                  if (status ==
                      ColdStartContainmentStatus.noActiveFamilyMembership) ...[
                    FilledButton(
                      key: const Key('create_family_button'),
                      onPressed: () {
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
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry Verification'),
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
