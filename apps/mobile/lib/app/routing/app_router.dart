import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/presentation/auth_screen.dart';
import '../../features/child/presentation/child_mode_screen.dart';
import '../../features/child/presentation/create_child_screen.dart';
import '../../features/family/presentation/create_family_screen.dart';
import '../../features/family/presentation/family_home_screen.dart';
import '../../features/foundation/presentation/foundation_screen.dart';
import '../bootstrap/app_providers.dart';
import 'app_routes.dart';

/// Listenable that notifies GoRouter on auth state changes and child mode changes.
class RouterListenable extends ChangeNotifier {
  RouterListenable(Ref ref) {
    ref.listen<AsyncValue<AuthState>>(authStateProvider, (_, _) {
      notifyListeners();
    });
    ref.listen<ChildProfile?>(activeChildModeProvider, (_, _) {
      notifyListeners();
    });
  }
}

final routerListenableProvider = Provider<RouterListenable>((ref) {
  return RouterListenable(ref);
});

/// Application router.
///
/// Route guards ensure:
/// - Child Mode containment: locked in /child until Parent Gate succeeds.
/// - Auth guard: unauthenticated users redirect to /auth when Supabase is configured.
final routerProvider = Provider<GoRouter>((ref) {
  final listenable = ref.watch(routerListenableProvider);

  final router = GoRouter(
    initialLocation: AppRoutes.parentHome,
    refreshListenable: listenable,
    redirect: (BuildContext context, GoRouterState state) {
      final activeChild = ref.read(activeChildModeProvider);
      final location = state.uri.path;

      // 1. Shared-device Child Mode containment:
      // While in Child Mode, protected parent routes and auth cannot be accessed.
      if (activeChild != null) {
        if (location != AppRoutes.childMode) {
          return AppRoutes.childMode;
        }
        return null;
      }

      // If on /child route without an active child profile, return to parent home
      if (location == AppRoutes.childMode && activeChild == null) {
        return AppRoutes.parentHome;
      }

      // 2. Auth state guard when Supabase is configured
      final config = ref.read(appConfigProvider);
      if (config.isSupabaseConfigured) {
        final currentUserId = ref.read(currentUserIdProvider);
        final isAuthRoute = location == AppRoutes.auth;

        if (currentUserId == null && !isAuthRoute) {
          return AppRoutes.auth;
        }
        if (currentUserId != null && isAuthRoute) {
          return AppRoutes.parentHome;
        }
      }

      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.home,
        name: AppRoutes.homeName,
        builder: (context, state) => const FamilyHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.foundation,
        name: AppRoutes.foundationName,
        builder: (context, state) => const FoundationScreen(),
      ),
      GoRoute(
        path: AppRoutes.auth,
        name: AppRoutes.authName,
        builder: (context, state) => const AuthScreen(),
      ),
      GoRoute(
        path: AppRoutes.createFamily,
        name: AppRoutes.createFamilyName,
        builder: (context, state) => const CreateFamilyScreen(),
      ),
      GoRoute(
        path: AppRoutes.parentHome,
        name: AppRoutes.parentHomeName,
        builder: (context, state) => const FamilyHomeScreen(),
      ),
      GoRoute(
        path: AppRoutes.createChild,
        name: AppRoutes.createChildName,
        builder: (context, state) => const CreateChildScreen(),
      ),
      GoRoute(
        path: AppRoutes.childMode,
        name: AppRoutes.childModeName,
        builder: (context, state) => const ChildModeScreen(),
      ),
    ],
  );

  ref.onDispose(router.dispose);
  return router;
});
