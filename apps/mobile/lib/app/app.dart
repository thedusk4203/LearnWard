import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../features/auth/presentation/auth_screen.dart';
import 'bootstrap/app_active_recovery_service.dart';
import 'bootstrap/app_config.dart';
import 'bootstrap/app_providers.dart';
import 'bootstrap/cold_start_containment_bootstrap.dart';
import 'routing/app_router.dart';

/// Root widget for LearnWard.
///
/// Boots fail-closed through `Hydrating` until [coldStartContainmentProvider]
/// validates identity and server authorization, deferring protected UI until
/// containment status is established (`WP2`).
class LearnWardApp extends ConsumerWidget {
  const LearnWardApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coldStart = ref.watch(coldStartContainmentProvider);

    if (coldStart.isHydrating) {
      return MaterialApp(
        key: const ValueKey('hydrating_app'),
        title: 'LearnWard',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.system,
        home: const ContainmentHydratingScreen(),
      );
    }

    if (coldStart.status == ColdStartContainmentStatus.unauthenticated) {
      return MaterialApp(
        key: const ValueKey('unauthenticated_app'),
        title: 'LearnWard',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.system,
        home: const AuthScreen(),
      );
    }

    if (!coldStart.allowsProtectedUi) {
      return MaterialApp(
        key: ValueKey('restricted_${coldStart.status.name}'),
        title: 'LearnWard',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.system,
        home: ColdStartRestrictedShell(
          containmentState: coldStart,
          onRetry: () =>
              ref.read(coldStartContainmentProvider.notifier).rehydrate(),
          onSignOut: () => ref
              .read(coldStartContainmentProvider.notifier)
              .signOutFromRestrictedShell(),
        ),
      );
    }

    // Eagerly instantiate app-active recovery lifecycle when feature flag is enabled
    if (AppConfig.recoveryDispatcherEnabled) {
      ref.watch(appActiveRecoveryServiceProvider);
    }

    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      key: const ValueKey('authorized_router_app'),
      title: 'LearnWard',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
