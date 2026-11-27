import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/assessments/presentation/evidence_picker_service.dart';
import '../../features/assessments/services/local_evidence_file_store.dart';
import '../../features/shared_device/domain/parent_gate_service.dart';
import 'app_config.dart';
import 'cold_start_containment_bootstrap.dart';
import 'in_memory_repositories.dart';
import 'supabase_auth_session_adapter.dart';
import 'supabase_containment_authorization_verifier.dart';
import 'supabase_recovery_authorization_adapter.dart';

/// Build-time application configuration.
final appConfigProvider = Provider<AppConfig>((ref) {
  return AppConfig.fromEnvironment();
});

/// System clock provider for testability and time-dependent logic.
final appClockProvider = Provider<DateTime Function()>((ref) {
  return () => DateTime.now().toUtc();
});

/// Recovery dispatcher enabled status provider.
final recoveryDispatcherEnabledProvider = Provider<bool>((ref) {
  return AppConfig.recoveryDispatcherEnabled;
});

/// Local Drift database provider.
final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase(driftDatabase(name: 'learnward'));
  ref.onDispose(database.close);
  return database;
});

/// In-memory local metadata store provider for testing/local demo.
final inMemoryLocalMetadataStoreProvider = Provider<LocalMetadataStore>((ref) {
  return InMemoryMobileMetadataStore();
});

/// Local metadata store provider (defaults to SQLite database in production).
final localMetadataStoreProvider = Provider<LocalMetadataStore>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config.canUseLocalDemoRepositories) {
    return ref.watch(inMemoryLocalMetadataStoreProvider);
  }
  return ref.watch(databaseProvider);
});

/// In-memory local draft store provider for testing/local demo.
final inMemoryLocalDraftStoreProvider = Provider<LocalDraftStore>((ref) {
  return InMemoryLocalDraftStore();
});

/// Local draft store provider.
final localDraftStoreProvider = Provider<LocalDraftStore>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config.canUseLocalDemoRepositories) {
    return ref.watch(inMemoryLocalDraftStoreProvider);
  }
  final metadataStore = ref.watch(localMetadataStoreProvider);
  if (metadataStore is AppDatabase) {
    return metadataStore;
  }
  return ref.watch(inMemoryLocalDraftStoreProvider);
});

/// In-memory pending reward command store provider for testing/local demo.
final inMemoryPendingRewardCommandStoreProvider =
    Provider<PendingRewardCommandStore>((ref) {
      return InMemoryPendingRewardCommandStore();
    });

/// Pending reward command store provider.
final pendingRewardCommandStoreProvider = Provider<PendingRewardCommandStore>((
  ref,
) {
  final config = ref.watch(appConfigProvider);
  if (config.canUseLocalDemoRepositories) {
    return ref.watch(inMemoryPendingRewardCommandStoreProvider);
  }
  final metadataStore = ref.watch(localMetadataStoreProvider);
  if (metadataStore is AppDatabase) {
    return metadataStore;
  }
  return ref.watch(inMemoryPendingRewardCommandStoreProvider);
});

final class _CombinedOutboxProvenanceSource
    implements LegacyOutboxProvenanceSource {
  const _CombinedOutboxProvenanceSource({this.draftSource, this.commandSource});

  final LegacyOutboxProvenanceSource? draftSource;
  final LegacyOutboxProvenanceSource? commandSource;

  @override
  Future<List<ActorBoundOutboxRecord>> listActorBoundRecords() async {
    final records = <ActorBoundOutboxRecord>[];
    if (draftSource != null) {
      records.addAll(await draftSource!.listActorBoundRecords());
    }
    if (commandSource != null) {
      records.addAll(await commandSource!.listActorBoundRecords());
    }
    return records;
  }
}

/// Read-only local outbox provenance source for legacy Child Mode ownership
/// resolution (`D1.6`, `WP3`).
final legacyOutboxProvenanceSourceProvider =
    Provider<LegacyOutboxProvenanceSource>((ref) {
      final config = ref.watch(appConfigProvider);
      if (!config.canUseLocalDemoRepositories) {
        final metadataStore = ref.watch(localMetadataStoreProvider);
        if (metadataStore is AppDatabase) {
          return metadataStore;
        }
      }
      final draftStore = ref.watch(localDraftStoreProvider);
      final commandStore = ref.watch(pendingRewardCommandStoreProvider);
      if (draftStore is LegacyOutboxProvenanceSource &&
          commandStore is LegacyOutboxProvenanceSource &&
          identical(draftStore, commandStore)) {
        return draftStore as LegacyOutboxProvenanceSource;
      }
      if (draftStore is InMemoryLocalDraftStore &&
          commandStore is InMemoryPendingRewardCommandStore) {
        return CombinedInMemoryLegacyOutboxProvenanceSource(
          draftStore: draftStore,
          commandStore: commandStore,
        );
      }
      return _CombinedOutboxProvenanceSource(
        draftSource: draftStore is LegacyOutboxProvenanceSource
            ? draftStore as LegacyOutboxProvenanceSource
            : null,
        commandSource: commandStore is LegacyOutboxProvenanceSource
            ? commandStore as LegacyOutboxProvenanceSource
            : null,
      );
    });

/// Evidence picker service provider. Defaults to production native image_picker.
final evidencePickerServiceProvider = Provider<EvidencePickerService>((ref) {
  final config = ref.watch(appConfigProvider);
  if (config.canUseLocalDemoRepositories) {
    return SimulatedEvidencePickerService();
  }
  return NativeEvidencePickerService();
});

/// App-private durable evidence file storage provider.
final localEvidenceFileStoreProvider = Provider<LocalEvidenceFileStore>((ref) {
  return DefaultLocalEvidenceFileStore();
});

/// Parent Gate service provider (production hardened PBKDF2-HMAC-SHA-256).
final parentGateServiceProvider = Provider<ParentGateService>((ref) {
  final store = ref.watch(localMetadataStoreProvider);
  return ParentGateService(
    store,
    clock: const SystemClock(),
    monotonicClock: StopwatchMonotonicClock(),
    minIterations: ParentGateCrypto.productionMinIterations,
    configuredIterations: ParentGateCrypto.productionMinIterations,
    runInIsolate: true,
  );
});

/// Supabase client provider.
///
/// In production, uses [Supabase.instance.client]. Overridden in tests.
final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (!config.isSupabaseConfigured) return null;
  try {
    return Supabase.instance.client;
  } catch (_) {
    return null;
  }
});

/// Stream provider for current Supabase auth state.
final authStateProvider = StreamProvider<AuthState>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    return const Stream.empty();
  }
  return client.auth.onAuthStateChange;
});

/// Fail-closed snapshot combining live generation validation with bound actor identity (`WP3`).
final class AuthSessionState {
  const AuthSessionState({
    this.actorUserId,
    this.sessionGeneration,
    this.isFailClosedInvalidated = false,
  });

  static const unauthenticated = AuthSessionState();

  final String? actorUserId;
  final String? sessionGeneration;
  final bool isFailClosedInvalidated;

  bool get isAuthenticated =>
      !isFailClosedInvalidated &&
      actorUserId != null &&
      actorUserId!.trim().isNotEmpty &&
      sessionGeneration != null &&
      sessionGeneration!.trim().isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuthSessionState &&
          actorUserId == other.actorUserId &&
          sessionGeneration == other.sessionGeneration &&
          isFailClosedInvalidated == other.isFailClosedInvalidated;

  @override
  int get hashCode =>
      Object.hash(actorUserId, sessionGeneration, isFailClosedInvalidated);
}

/// Stream provider mirroring [AuthSessionPort.sessionGenerationStream] (`WP3`).
final StreamProvider<String?> authSessionGenerationProvider =
    StreamProvider<String?>((ref) {
      final port = ref.watch(authSessionPortProvider);
      return port.sessionGenerationStream;
    });

/// Authoritative fail-closed auth session state (`WP3`).
///
/// Derives actor identity solely from validated live session state (never
/// falling back to stale `client.auth.currentUser` after sign-out, expiry,
/// or stream disruption).
final Provider<AuthSessionState> authSessionStateProvider =
    Provider<AuthSessionState>((ref) {
      final client = ref.watch(supabaseClientProvider);
      final authState = ref.watch(authStateProvider);
      final authPort = ref.watch(authSessionPortProvider);
      final genStream = ref.watch(authSessionGenerationProvider);

      if (client != null) {
        if (authState.hasError || genStream.hasError) {
          return const AuthSessionState(isFailClosedInvalidated: true);
        }
        final data = authState.value;
        if (data != null &&
            (data.event == AuthChangeEvent.signedOut ||
                data.session == null ||
                data.session!.isExpired)) {
          return const AuthSessionState(isFailClosedInvalidated: true);
        }

        final liveGeneration = authPort.currentSessionGeneration;
        if (liveGeneration == null || liveGeneration.trim().isEmpty) {
          return const AuthSessionState(isFailClosedInvalidated: true);
        }

        if (authPort is SupabaseAuthSessionAdapter) {
          final boundUserId = authPort.currentBoundUserId;
          if (boundUserId == null || boundUserId.trim().isEmpty) {
            return const AuthSessionState(isFailClosedInvalidated: true);
          }
          if (data?.session != null && data!.session!.user.id != boundUserId) {
            return const AuthSessionState(isFailClosedInvalidated: true);
          }
          return AuthSessionState(
            actorUserId: boundUserId.trim(),
            sessionGeneration: liveGeneration.trim(),
          );
        }

        final streamUserId = data?.session?.user.id.trim();
        if (streamUserId == null || streamUserId.isEmpty) {
          return const AuthSessionState(isFailClosedInvalidated: true);
        }
        return AuthSessionState(
          actorUserId: streamUserId,
          sessionGeneration: liveGeneration.trim(),
        );
      }

      if (authState.hasError || genStream.hasError) {
        return const AuthSessionState(isFailClosedInvalidated: true);
      }
      final data = authState.value;
      if (data != null &&
          (data.event == AuthChangeEvent.signedOut ||
              data.session == null ||
              data.session!.isExpired)) {
        return const AuthSessionState(isFailClosedInvalidated: true);
      }
      final liveGeneration =
          genStream.value?.trim() ?? authPort.currentSessionGeneration?.trim();
      final sessionUserId = data?.session?.user.id.trim();
      if (liveGeneration == null ||
          liveGeneration.isEmpty ||
          sessionUserId == null ||
          sessionUserId.isEmpty) {
        return AuthSessionState(
          isFailClosedInvalidated: genStream.hasError || authState.hasError,
        );
      }
      return AuthSessionState(
        actorUserId: sessionUserId,
        sessionGeneration: liveGeneration,
      );
    });

/// Provider for the current user's ID, or null (`WP3` fail-closed).
///
/// When Supabase is configured, derives exclusively from [authSessionStateProvider]
/// (never reading unverified `client.auth.currentUser`). In local demo mode,
/// derives from valid non-expired [authStateProvider] events only.
final Provider<String?> currentUserIdProvider = Provider<String?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return ref.watch(authSessionStateProvider).actorUserId;
  }
  final authState = ref.watch(authStateProvider);
  if (authState.hasError) {
    return null;
  }
  final data = authState.value;
  if (data == null || data.event == AuthChangeEvent.signedOut) {
    return null;
  }
  final session = data.session;
  if (session == null || session.isExpired) {
    return null;
  }
  final uid = session.user.id.trim();
  return uid.isEmpty ? null : uid;
});

/// Repository for family operations.
///
/// Fails closed in staging and production if Supabase credentials are missing.
final familyRepositoryProvider = Provider<FamilyRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseFamilyRepository(client);
  }
  if (config.canUseLocalDemoRepositories) {
    return InMemoryFamilyRepository();
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Repository for child profile operations.
///
/// Fails closed in staging and production if Supabase credentials are missing.
final childProfileRepositoryProvider = Provider<ChildProfileRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseChildProfileRepository(client);
  }
  if (config.canUseLocalDemoRepositories) {
    return InMemoryChildProfileRepository();
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Repository for assessment operations.
final assessmentRepositoryProvider = Provider<AssessmentRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseAssessmentRepository(client);
  }
  if (config.canUseLocalDemoRepositories) {
    return InMemoryAssessmentRepository(
      activeActorIdProvider: () => ref.read(currentUserIdProvider),
    );
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Storage for assessment evidence assets.
final assessmentEvidenceStorageProvider = Provider<AssessmentEvidenceStorage>((
  ref,
) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    final authPort = ref.watch(authSessionPortProvider);
    return SupabaseAssessmentEvidenceStorage(client, authSessionPort: authPort);
  }
  if (config.canUseLocalDemoRepositories) {
    final authPort = ref.watch(authSessionPortProvider);
    return InMemoryAssessmentEvidenceStorage(authSessionPort: authPort);
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Repository for Growth Engine calculations, ledgers and balances.
final growthRepositoryProvider = Provider<GrowthRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseGrowthRepository(client);
  }
  if (config.canUseLocalDemoRepositories) {
    final assessmentRepo = ref.watch(assessmentRepositoryProvider);
    return InMemoryGrowthRepository(
      assessmentRepository: assessmentRepo is InMemoryAssessmentRepository
          ? assessmentRepo
          : null,
    );
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Repository for reward catalog, store redemptions and fulfillment.
final rewardRepositoryProvider = Provider<RewardRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseRewardRepository(client);
  }
  if (config.canUseLocalDemoRepositories) {
    final growthRepo = ref.watch(growthRepositoryProvider);
    return InMemoryRewardRepository(
      growthRepository: growthRepo is InMemoryGrowthRepository
          ? growthRepo
          : null,
    );
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Repository for Celebration Wheel operations, configuration and spin history.
final wheelRepositoryProvider = Provider<WheelRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseWheelRepository(client);
  }
  if (config.canUseLocalDemoRepositories) {
    final rewardRepo = ref.watch(rewardRepositoryProvider);
    final growthRepo = ref.watch(growthRepositoryProvider);
    return InMemoryWheelRepository(
      rewardRepository: rewardRepo is InMemoryRewardRepository
          ? rewardRepo
          : null,
      growthRepository: growthRepo is InMemoryGrowthRepository
          ? growthRepo
          : null,
    );
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Repository for learning nodes, mappings, and mastery states.
final learningRepositoryProvider = Provider<LearningRepository>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseLearningRepository(client);
  }
  if (config.canUseLocalDemoRepositories) {
    final childRepo = ref.watch(childProfileRepositoryProvider);
    return InMemoryLearningRepository(
      childProfileRepository: childRepo is InMemoryChildProfileRepository
          ? childRepo
          : null,
    );
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Auth session port provider.
final Provider<AuthSessionPort> authSessionPortProvider =
    Provider<AuthSessionPort>((ref) {
      final config = ref.watch(appConfigProvider);
      final client = ref.watch(supabaseClientProvider);
      if (client != null) {
        final adapter = SupabaseAuthSessionAdapter(client);
        ref.onDispose(adapter.dispose);
        return adapter;
      }
      if (config.canUseLocalDemoRepositories) {
        final currentUserId = ref.watch(currentUserIdProvider);
        final port = InMemoryAuthSessionPort(activeUserId: currentUserId);
        ref.onDispose(port.dispose);
        return port;
      }
      throw MissingSupabaseConfigurationException(config.environment);
    });

/// Restricted shell sign-out handler (`R40-03`).
///
/// Invokes Supabase Auth sign-out (or local demo sign-out) without deleting
/// unresolved local containment locks, sessions, PIN metadata, or queued work.
final restrictedShellSignOutProvider = Provider<Future<void> Function()>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final authPort = ref.watch(authSessionPortProvider);
  return () async {
    if (client != null) {
      try {
        await client.auth.signOut();
      } catch (_) {
        // Offline Supabase signOut clears local session state first before
        // attempting server revocation. Allow only if local session is cleared.
        final remainingActor = await authPort.validateForMutation();
        if (remainingActor != null || client.auth.currentSession != null) {
          rethrow;
        }
      }
      return;
    }
    if (authPort is InMemoryAuthSessionPort) {
      authPort.signOut();
      return;
    }
    throw StateError(
      'Cannot sign out from restricted shell without an active Supabase client or local auth session port.',
    );
  };
});

/// Recovery authorization port provider.
final recoveryAuthorizationPortProvider = Provider<RecoveryAuthorizationPort>((
  ref,
) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseRecoveryAuthorizationAdapter(client);
  }
  if (config.canUseLocalDemoRepositories) {
    return const InMemoryRecoveryAuthorizationPort();
  }
  throw MissingSupabaseConfigurationException(config.environment);
});

/// Containment authorization verifier provider separating identity hints from
/// authoritative DB grants/memberships/child profiles (`WP2`).
final containmentAuthorizationVerifierProvider =
    Provider<ContainmentAuthorizationVerifier>((ref) {
      final config = ref.watch(appConfigProvider);
      final client = ref.watch(supabaseClientProvider);
      if (client != null) {
        return SupabaseContainmentAuthorizationVerifier(client);
      }
      if (config.canUseLocalDemoRepositories) {
        return InMemoryContainmentAuthorizationVerifier(
          familyRepository: ref.watch(familyRepositoryProvider),
          childProfileRepository: ref.watch(childProfileRepositoryProvider),
        );
      }
      throw MissingSupabaseConfigurationException(config.environment);
    });

/// Fail-closed cold-start containment state provider (`WP2`).
final coldStartContainmentProvider =
    NotifierProvider<ColdStartContainmentNotifier, ColdStartContainmentState>(
      ColdStartContainmentNotifier.new,
    );

/// Canonical WP3 alias referencing the single lifecycle controller [coldStartContainmentProvider].
final sessionContainmentProvider = coldStartContainmentProvider;

/// Shared recovery coordinator provider for Spin and Redeem operations.
final recoveryCoordinatorProvider = Provider<RecoveryCoordinator>((ref) {
  final commandStore = ref.watch(pendingRewardCommandStoreProvider);
  final wheelRepo = ref.watch(wheelRepositoryProvider);
  final rewardRepo = ref.watch(rewardRepositoryProvider);
  final authPort = ref.watch(authSessionPortProvider);
  final authzPort = ref.watch(recoveryAuthorizationPortProvider);
  final config = ref.watch(appConfigProvider);

  return RecoveryCoordinator(
    commandStore: commandStore,
    wheelRepository: wheelRepo,
    rewardRepository: rewardRepo,
    authSessionPort: authPort,
    authorizationPort: authzPort,
    activeFamilyIdProvider: () =>
        ref.read(activeFamilyProvider)?.id.value ??
        ref.read(activeChildModeProvider)?.familyId.value,
    jitterSource: config.canUseLocalDemoRepositories
        ? const DeterministicJitterSource(0.0)
        : const RandomJitterSource(),
  );
});

/// Outbox recovery dispatcher provider.
final outboxRecoveryDispatcherProvider = Provider<OutboxRecoveryDispatcher>((
  ref,
) {
  final commandStore = ref.watch(pendingRewardCommandStoreProvider);
  final coordinator = ref.watch(recoveryCoordinatorProvider);
  final authPort = ref.watch(authSessionPortProvider);

  return OutboxRecoveryDispatcher(
    commandStore: commandStore,
    coordinator: coordinator,
    authSessionPort: authPort,
    activeFamilyIdProvider: () =>
        ref.read(activeFamilyProvider)?.id.value ??
        ref.read(activeChildModeProvider)?.familyId.value,
  );
});

/// Notifier managing the currently selected family.
class ActiveFamilyNotifier extends Notifier<Family?> {
  @override
  Family? build() => null;

  void selectFamily(Family? family) {
    state = family;
  }
}

/// Provider for the active family.
final activeFamilyProvider = NotifierProvider<ActiveFamilyNotifier, Family?>(
  ActiveFamilyNotifier.new,
);

/// Notifier managing verified active child mode state and v2 persistence.
///
/// Cold start NEVER blindly restores unverified persisted child sessions;
/// [ColdStartContainmentNotifier] hydrates verified sessions asynchronously.
class ActiveChildModeNotifier extends Notifier<ChildProfile?> {
  static const activeSessionKey = 'active_child_session';

  @override
  ChildProfile? build() => null;

  /// Populates in-memory Child Mode state only after verified cold-start checks.
  void restoreVerifiedChild(ChildProfile? child) {
    state = child;
  }

  Future<void> selectChild(
    ChildProfile child, {
    String? actorUserId,
    PersistedChildModeKind modeKind = PersistedChildModeKind.sharedDeviceAdult,
  }) async {
    if (modeKind != PersistedChildModeKind.sharedDeviceAdult) {
      throw StateError(
        'Cannot enter Child Mode with modeKind=${modeKind.name}: interactive selection requires shared_device_adult.',
      );
    }

    final authPort = ref.read(authSessionPortProvider);
    final actor = await authPort.validateForMutation();
    final nowUtc = ref.read(appClockProvider)();
    if (actor == null ||
        !actor.isValidAt(nowUtc) ||
        actor.userId.trim().isEmpty ||
        actor.sessionGeneration.trim().isEmpty) {
      throw StateError(
        'Cannot enter Child Mode without a validated authenticated actor.',
      );
    }
    if (actor.isAnonymous || actor.role == 'child') {
      throw StateError(
        'Cannot enter Child Mode from an anonymous or paired-child session.',
      );
    }

    final resolvedActorId = actor.userId.trim();
    if (actorUserId != null && actorUserId.trim() != resolvedActorId) {
      throw StateError(
        'Cannot enter Child Mode: supplied actorUserId does not match the validated session.',
      );
    }

    final capturedGeneration = actor.sessionGeneration;
    if (authPort.currentSessionGeneration != capturedGeneration) {
      throw StateError(
        'Cannot enter Child Mode: auth session generation changed.',
      );
    }

    final store = ref.read(localMetadataStoreProvider);
    final existingLock = await store.readMetadata(
      ColdStartContainmentNotifier.containmentRecoveryLockV1Key,
    );
    if (existingLock != null) {
      throw StateError(
        'Cannot enter Child Mode while containment_recovery_lock_v1 is active.',
      );
    }
    final existingSession = await store.readMetadata(activeSessionKey);
    if (existingSession != null) {
      throw StateError(
        'Cannot enter Child Mode while active_child_session already exists.',
      );
    }

    final verifier = ref.read(containmentAuthorizationVerifierProvider);
    final outcome = await verifier.verifySession(
      context: actor,
      preferredFamilyId: child.familyId,
      targetFamilyId: child.familyId,
      targetChildId: child.id,
    );

    if (authPort.currentSessionGeneration != capturedGeneration) {
      throw StateError(
        'Cannot enter Child Mode: auth session generation changed during verification.',
      );
    }

    final revalidatedActor = await authPort.validateForMutation();
    final postVerifyUtc = ref.read(appClockProvider)();
    if (revalidatedActor == null ||
        !revalidatedActor.isValidAt(postVerifyUtc) ||
        revalidatedActor.userId.trim() != resolvedActorId ||
        revalidatedActor.sessionGeneration != capturedGeneration ||
        revalidatedActor.isAnonymous ||
        revalidatedActor.role == 'child') {
      throw StateError(
        'Cannot enter Child Mode: validated actor context is no longer active.',
      );
    }

    if (outcome is! AuthorizedActiveAdult ||
        !outcome.verifiedRolesByFamilyId.containsKey(child.familyId.value) ||
        outcome.verifiedFamily.id != child.familyId ||
        outcome.verifiedChild?.id != child.id ||
        outcome.verifiedChild?.familyId != child.familyId) {
      throw StateError(
        'Cannot enter Child Mode without positive active adult authorization ($outcome).',
      );
    }

    final verifiedChild = outcome.verifiedChild!;
    final persistedAtUtc = ref.read(appClockProvider)();
    final envelope = PersistedChildModeSession(
      modeKind: modeKind,
      actorUserId: resolvedActorId,
      familyId: child.familyId,
      childId: child.id,
      childProfileSnapshot: verifiedChild,
      persistedAtUtc: persistedAtUtc,
    );

    final committed = await store.compareAndSwapMetadataBatch(
      expectedValues: const {
        activeSessionKey: null,
        ColdStartContainmentNotifier.containmentRecoveryLockV1Key: null,
      },
      mutations: [
        MetadataMutation.upsert(
          key: activeSessionKey,
          value: envelope.toJsonString(),
          updatedAt: persistedAtUtc,
        ),
      ],
      preCommitGuard: () {
        if (!ref.mounted) {
          return false;
        }
        if (authPort.currentSessionGeneration != capturedGeneration) {
          return false;
        }
        return actor.isValidAt(ref.read(appClockProvider)());
      },
    );
    if (!committed) {
      throw StateError(
        'Cannot enter Child Mode: session fence invalidated or containment lock/session mutated before commit.',
      );
    }
    if (!ref.mounted ||
        authPort.currentSessionGeneration != capturedGeneration) {
      throw StateError(
        'Cannot enter Child Mode: session invalidated around commit.',
      );
    }

    state = verifiedChild;
  }

  Future<void> exitChildMode() async {
    state = null;
    final store = ref.read(localMetadataStoreProvider);
    await store.applyMetadataBatch([
      const MetadataMutation.delete(key: activeSessionKey),
    ]);
  }
}

/// Provider for the active child mode state.
///
/// When non-null, the application UI is locked in Child Mode for this profile.
final activeChildModeProvider =
    NotifierProvider<ActiveChildModeNotifier, ChildProfile?>(
      ActiveChildModeNotifier.new,
    );
