import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import 'bootstrap/app_active_recovery_service.dart';
import 'bootstrap/app_config.dart';
import 'routing/app_router.dart';

/// Root widget for LearnWard.
class LearnWardApp extends ConsumerWidget {
  const LearnWardApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly instantiate app-active recovery lifecycle when feature flag is enabled
    if (AppConfig.recoveryDispatcherEnabled) {
      ref.watch(appActiveRecoveryServiceProvider);
    }

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'LearnWard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
