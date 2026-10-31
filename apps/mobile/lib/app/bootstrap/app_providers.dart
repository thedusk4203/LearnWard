import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_config.dart';
import 'in_memory_repositories.dart';

/// Build-time application configuration.
final appConfigProvider = Provider<AppConfig>((ref) {
  return AppConfig.fromEnvironment();
});

/// Local Drift database provider.
final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase(driftDatabase(name: 'learnward'));
  ref.onDispose(database.close);
  return database;
});

/// Supabase client provider.
///
/// In production, uses [Supabase.instance.client]. Overridden in tests.
final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (!config.isSupabaseConfigured) return null;
  return Supabase.instance.client;
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
final currentUserIdProvider = Provider<String?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client?.auth.currentUser?.id;
});

/// Repository for family operations.
///
/// Falls back to in-memory fake when Supabase credentials are not configured,
/// ensuring the development app shell can boot out-of-the-box.
final familyRepositoryProvider = Provider<FamilyRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    return InMemoryFamilyRepository();
  }
  return SupabaseFamilyRepository(client);
});

/// Repository for child profile operations.
final childProfileRepositoryProvider = Provider<ChildProfileRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    return InMemoryChildProfileRepository();
  }
  return SupabaseChildProfileRepository(client);
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

/// Notifier managing the active child mode state.
class ActiveChildModeNotifier extends Notifier<ChildProfile?> {
  @override
  ChildProfile? build() => null;

  void selectChild(ChildProfile child) {
    state = child;
  }

  void exitChildMode() {
    state = null;
  }
}

/// Provider for the active child mode state.
///
/// When non-null, the application UI is locked in Child Mode for this profile.
final activeChildModeProvider =
    NotifierProvider<ActiveChildModeNotifier, ChildProfile?>(
      ActiveChildModeNotifier.new,
    );
