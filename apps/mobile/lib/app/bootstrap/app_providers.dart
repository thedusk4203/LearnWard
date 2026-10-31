import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_data/learnward_data.dart';

import 'app_config.dart';

/// Build-time application configuration.
///
/// `main.dart` overrides this with the resolved value; the default keeps widget
/// tests and tooling usable without extra setup.
final appConfigProvider = Provider<AppConfig>((ref) {
  return AppConfig.fromEnvironment();
});

/// Composition-root provider for the local Drift database.
///
/// Features read this provider instead of constructing databases or global
/// singletons. The database opens lazily on first use.
final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase(driftDatabase(name: 'learnward'));
  ref.onDispose(database.close);
  return database;
});
