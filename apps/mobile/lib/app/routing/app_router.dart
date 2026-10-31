import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
        builder: (context, state) => const FoundationScreen(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
