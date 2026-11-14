import 'dart:convert';

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
import 'in_memory_repositories.dart';
import 'supabase_auth_session_adapter.dart';
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
  return ref.watch(databaseProvider);
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
  return ref.watch(databaseProvider);
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

/// Parent Gate service provider.
final parentGateServiceProvider = Provider<ParentGateService>((ref) {
  final store = ref.watch(localMetadataStoreProvider);
  return ParentGateService(store);
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

/// Provider for the current user's ID, or null.
///
/// Reactively watches [authStateProvider] and updates dynamically
/// whenever an auth event occurs (sign in, sign out, token refresh).
final currentUserIdProvider = Provider<String?>((ref) {
  final authState = ref.watch(authStateProvider);
  final client = ref.watch(supabaseClientProvider);
  return authState.value?.session?.user.id ?? client?.auth.currentUser?.id;
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
    return InMemoryAssessmentRepository();
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
final authSessionPortProvider = Provider<AuthSessionPort>((ref) {
  final config = ref.watch(appConfigProvider);
  final client = ref.watch(supabaseClientProvider);
  if (client != null) {
    return SupabaseAuthSessionAdapter(client);
  }
  if (config.canUseLocalDemoRepositories) {
    final currentUserId = ref.watch(currentUserIdProvider);
    return InMemoryAuthSessionPort(activeUserId: currentUserId);
  }
  throw MissingSupabaseConfigurationException(config.environment);
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

/// Initial child mode session provider loaded synchronously from local storage during bootstrap.
final initialChildModeSessionProvider = Provider<ChildProfile?>((ref) => null);

/// Notifier managing the active child mode state with persistent storage.
///
/// Child Mode lock survives app kill / restart until Parent Gate is solved.
class ActiveChildModeNotifier extends Notifier<ChildProfile?> {
  static const activeSessionKey = 'active_child_session';

  @override
  ChildProfile? build() {
    final initial = ref.watch(initialChildModeSessionProvider);
    if (initial != null) {
      return initial;
    }
    // Asynchronously verify local store in case session was restored after build
    _restorePersistedSession();
    return null;
  }

  Future<void> _restorePersistedSession() async {
    final store = ref.read(localMetadataStoreProvider);
    final rawSession = await store.readMetadata(activeSessionKey);
    if (rawSession != null && rawSession.isNotEmpty && state == null) {
      try {
        final map = jsonDecode(rawSession) as Map<String, dynamic>;
        state = ChildProfile(
          id: ChildId(map['id'] as String),
          familyId: FamilyId(map['family_id'] as String),
          displayName: map['display_name'] as String,
          schoolGrade: map['school_grade'] as int?,
          birthYear: map['birth_year'] as int?,
          avatarKey:
              map['avatar_key'] as String? ?? map['avatarKey'] as String?,
          status: ChildProfileStatus.parse(map['status'] as String),
          createdAt: DateTime.parse(map['created_at'] as String),
        );
      } catch (_) {}
    }
  }

  Future<void> selectChild(ChildProfile child) async {
    state = child;
    final store = ref.read(localMetadataStoreProvider);
    final jsonStr = jsonEncode({
      'id': child.id.value,
      'family_id': child.familyId.value,
      'display_name': child.displayName,
      'school_grade': child.schoolGrade,
      'birth_year': child.birthYear,
      'avatar_key': child.avatarKey,
      'avatarKey': child.avatarKey,
      'status': child.status.name,
      'created_at': child.createdAt.toIso8601String(),
    });
    await store.writeMetadata(
      key: activeSessionKey,
      value: jsonStr,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  Future<void> exitChildMode() async {
    state = null;
    final store = ref.read(localMetadataStoreProvider);
    await store.writeMetadata(
      key: activeSessionKey,
      value: '',
      updatedAt: DateTime.now().toUtc(),
    );
  }
}

/// Provider for the active child mode state.
///
/// When non-null, the application UI is locked in Child Mode for this profile.
final activeChildModeProvider =
    NotifierProvider<ActiveChildModeNotifier, ChildProfile?>(
      ActiveChildModeNotifier.new,
    );
