import 'dart:convert';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
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

  // Open local database and load persisted child session before initial UI render
  final database = AppDatabase(driftDatabase(name: 'learnward'));
  ChildProfile? initialChild;
  try {
    final rawSession = await database.readMetadata(
      ActiveChildModeNotifier.activeSessionKey,
    );
    if (rawSession != null && rawSession.isNotEmpty) {
      final map = jsonDecode(rawSession) as Map<String, dynamic>;
      initialChild = ChildProfile(
        id: ChildId(map['id'] as String),
        familyId: FamilyId(map['family_id'] as String),
        displayName: map['display_name'] as String,
        schoolGrade: map['school_grade'] as int?,
        birthYear: map['birth_year'] as int?,
        avatarKey: map['avatar_key'] as String?,
        status: ChildProfileStatus.parse(map['status'] as String),
        createdAt: DateTime.parse(map['created_at'] as String),
      );
    }
  } catch (_) {}

  runApp(
    ProviderScope(
      overrides: [
        appConfigProvider.overrideWithValue(config),
        databaseProvider.overrideWithValue(database),
        if (initialChild != null)
          initialChildModeSessionProvider.overrideWithValue(initialChild),
      ],
      child: const LearnWardApp(),
    ),
  );
}
