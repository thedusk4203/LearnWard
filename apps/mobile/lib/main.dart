import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/bootstrap/app_config.dart';
import 'app/bootstrap/app_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = AppConfig.fromEnvironment();
  // Fail fast immediately on boot if configuration is invalid for current environment
  config.validate();

  if (config.isSupabaseConfigured) {
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabasePublishableKey,
    );
  }

  // Open local database without blindly trusting persisted Child Mode prior to
  // fail-closed identity and server authorization validation (`WP2`).
  final database = AppDatabase(driftDatabase(name: 'learnward'));

  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        databaseProvider.overrideWithValue(database),
      ],
      child: const LearnWardApp(),
    ),
  );
}
