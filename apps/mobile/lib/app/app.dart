import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import 'bootstrap/app_active_recovery_service.dart';
import 'bootstrap/app_config.dart';
import 'bootstrap/app_providers.dart';
import 'routing/app_router.dart';

/// Root widget for LearnWard.
///
/// Always mounts a single fail-closed `MaterialApp.router` (`D3`, `WP3`) whose
/// [routerProvider] enforces the 10-level containment precedence across
/// unauthenticated, hydrating, restricted shells, Child Mode, and verified
/// Parent Mode.
class LearnWardApp extends ConsumerWidget {
  const LearnWardApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final containment = ref.watch(coldStartContainmentProvider);

    // Eagerly instantiate app-active recovery lifecycle when feature flag is enabled.
    if (AppConfig.recoveryDispatcherEnabled && containment.allowsProtectedUi) {
      ref.watch(appActiveRecoveryServiceProvider);
    }

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      key: const ValueKey('learnward_router_app'),
      title: 'LearnWard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
