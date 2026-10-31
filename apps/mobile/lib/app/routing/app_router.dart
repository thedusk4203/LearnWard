import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/auth_screen.dart';
import '../../features/child/presentation/child_mode_screen.dart';
import '../../features/child/presentation/create_child_screen.dart';
import '../../features/family/presentation/create_family_screen.dart';
import '../../features/family/presentation/family_home_screen.dart';
import '../../features/foundation/presentation/foundation_screen.dart';
import 'app_routes.dart';

/// Application router.
///
/// Route guards added later are UX guards only. Backend authorization and RLS
/// remain the security boundary.
final routerProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: AppRoutes.home,
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
