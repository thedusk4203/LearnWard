import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/assessments/presentation/add_assessment_screen.dart';
import '../../features/assessments/presentation/review_assessment_screen.dart';
import '../../features/assessments/presentation/verified_history_screen.dart';
import '../../features/auth/presentation/auth_screen.dart';
import '../../features/child/presentation/child_mode_screen.dart';
import '../../features/child/presentation/create_child_screen.dart';
import '../../features/family/presentation/create_family_screen.dart';
import '../../features/family/presentation/family_home_screen.dart';
import '../../features/foundation/presentation/foundation_screen.dart';
import '../../features/learning/presentation/child_mastery_screen.dart';
import '../../features/learning/presentation/learning_overview_screen.dart';
import '../../features/learning/presentation/node_learning_detail_screen.dart';
import '../../features/rewards/presentation/child_redemption_history_screen.dart';
import '../../features/rewards/presentation/child_store_screen.dart';
import '../../features/rewards/presentation/child_wheel_screen.dart';
import '../../features/rewards/presentation/parent_fulfillment_inbox_screen.dart';
import '../../features/rewards/presentation/parent_reward_catalog_screen.dart';
import '../../features/rewards/presentation/parent_reward_form_screen.dart';
import '../../features/rewards/presentation/parent_wheel_settings_screen.dart';
import '../bootstrap/app_providers.dart';
import '../bootstrap/cold_start_containment_bootstrap.dart';
import 'app_routes.dart';

/// Strict segment match for active Child Mode content routes (`D3`).
///
/// Explicitly excludes restricted child containment shells (`/child/revoked`,
/// `/child/unverified`, `/child/containment-locked`) so active child redirects
/// never confuse restricted shells with Child Mode content.
bool isActiveChildContentPath(String path) =>
    path == AppRoutes.childMode ||
    (path.startsWith('${AppRoutes.childMode}/') &&
        path != AppRoutes.childRevoked &&
        path != AppRoutes.childUnverified &&
        path != AppRoutes.childContainmentLocked);

/// Listenable that notifies GoRouter on containment, auth session, and child
/// mode changes, honoring Riverpod disposal lifecycle (`D3`).
class RouterListenable extends ChangeNotifier {
  RouterListenable(Ref ref) {
    void safeNotify() {
      if (!_isDisposed) {
        notifyListeners();
      }
    }

    ref.listen<ColdStartContainmentState>(
      coldStartContainmentProvider,
      (_, _) => safeNotify(),
    );
    ref.listen<AuthSessionState>(
      authSessionStateProvider,
      (_, _) => safeNotify(),
    );
    ref.listen<AsyncValue<AuthState>>(
      authStateProvider,
      (_, _) => safeNotify(),
    );
    ref.listen<ChildProfile?>(activeChildModeProvider, (_, _) => safeNotify());
  }

  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}

final routerListenableProvider = Provider<RouterListenable>((ref) {
  final listenable = RouterListenable(ref);
  ref.onDispose(listenable.dispose);
  return listenable;
});

String _scopeKeyPrefix(
  ColdStartContainmentState containment,
  ChildProfile? activeChild,
) {
  final actor = containment.actorContext?.userId ?? 'none';
  final family =
      containment.verifiedFamily?.id.value ??
      activeChild?.familyId.value ??
      'none';
  final child =
      containment.verifiedChild?.id.value ?? activeChild?.id.value ?? 'none';
  return '${actor}_${family}_${child}_${containment.status.name}_${containment.sessionScopeEpoch}';
}

/// Central GoRouter provider enforcing the 10-step auth-first & containment
/// precedence table (`D3`, `C0-I01`, `LW-AUD-03`).
final routerProvider = Provider<GoRouter>((ref) {
  final listenable = ref.watch(routerListenableProvider);
  String? lastNoFamilyScopeKey;

  Widget buildRestrictedShell() {
    return Consumer(
      builder: (context, widgetRef, _) {
        final containment = widgetRef.watch(coldStartContainmentProvider);
        final notifier = widgetRef.read(coldStartContainmentProvider.notifier);
        return ColdStartRestrictedShell(
          key: ValueKey('restricted_${_scopeKeyPrefix(containment, null)}'),
          containmentState: containment,
          onRetry: notifier.rehydrate,
          onSignOut: notifier.signOutFromRestrictedShell,
          onAttemptExitPathAPin: notifier.submitParentGateUnlock,
          onSubmitManualUnboundRecovery:
              ({required newPin, required targetFamilyId}) =>
                  notifier.submitManualUnboundLegacyRecovery(
                    newPin: newPin,
                    targetFamilyId: targetFamilyId,
                  ),
        );
      },
    );
  }

  final router = GoRouter(
    initialLocation: AppRoutes.containmentLoading,
    refreshListenable: listenable,
    redirect: (BuildContext context, GoRouterState state) {
      final config = ref.read(appConfigProvider);
      final authState = ref.read(authStateProvider);
      final auth = ref.read(authSessionStateProvider);
      final containment = ref.read(coldStartContainmentProvider);
      final location = state.uri.path;

      // In local demo mode with an explicit AuthState stream (e.g. auth_routing_test),
      // treat an explicitly signed-out / expired / errored AuthState as unauthenticated
      // while still allowing tests overriding `authSessionPortProvider` directly.
      final explicitDemoSignedOut =
          !config.isSupabaseConfigured &&
          (authState.hasError ||
              (authState.hasValue &&
                  (authState.value!.event == AuthChangeEvent.signedOut ||
                      authState.value!.session == null ||
                      authState.value!.session!.isExpired)));

      // 1. Unauthenticated outranks Child Mode & every restricted/protected state.
      final isUnauthenticated =
          (config.isSupabaseConfigured && !auth.isAuthenticated) ||
          containment.status == ColdStartContainmentStatus.unauthenticated ||
          explicitDemoSignedOut;
      if (isUnauthenticated) {
        return location == AppRoutes.auth ? null : AppRoutes.auth;
      }

      // 2. Hydrating: fail-closed loading gate until verifier resolves.
      if (containment.isHydrating) {
        return location == AppRoutes.containmentLoading
            ? null
            : AppRoutes.containmentLoading;
      }

      // 3-8. Restricted non-parent, non-active-child shells.
      switch (containment.status) {
        case ColdStartContainmentStatus.pairedChildRevoked:
          return location == AppRoutes.childRevoked
              ? null
              : AppRoutes.childRevoked;

        case ColdStartContainmentStatus.pairedChildUnverified:
          return location == AppRoutes.childUnverified
              ? null
              : AppRoutes.childUnverified;

        case ColdStartContainmentStatus.containmentLocked:
          return location == AppRoutes.childContainmentLocked
              ? null
              : AppRoutes.childContainmentLocked;

        case ColdStartContainmentStatus.authorizationUnverified:
          return location == AppRoutes.accountUnverified
              ? null
              : AppRoutes.accountUnverified;

        case ColdStartContainmentStatus.adultAccessRestricted:
          return location == AppRoutes.accountAccessRestricted
              ? null
              : AppRoutes.accountAccessRestricted;

        case ColdStartContainmentStatus.noActiveFamilyMembership:
          final scopeKey =
              '${containment.actorContext?.userId ?? 'none'}_${containment.sessionScopeEpoch}';
          final sameOnboardingScope = lastNoFamilyScopeKey == scopeKey;
          lastNoFamilyScopeKey = scopeKey;
          if (location == AppRoutes.familyOnboarding) {
            return null;
          }
          if (location == AppRoutes.createFamily && sameOnboardingScope) {
            return null;
          }
          return AppRoutes.familyOnboarding;

        case ColdStartContainmentStatus.verifiedChildMode:
        case ColdStartContainmentStatus.offlineContainedChildMode:
          // 9. Active Contained Child Mode strictly limited to active child content paths.
          return isActiveChildContentPath(location)
              ? null
              : AppRoutes.childMode;

        case ColdStartContainmentStatus.verifiedParentMode:
          // 10. Verified Active Adult ONLY: redirect away from auth/loading/child/restricted shells.
          if (location == AppRoutes.home ||
              location == AppRoutes.auth ||
              location == AppRoutes.containmentLoading ||
              location == AppRoutes.familyOnboarding ||
              location == AppRoutes.accountUnverified ||
              location == AppRoutes.accountAccessRestricted ||
              location == AppRoutes.childMode ||
              location.startsWith('${AppRoutes.childMode}/')) {
            return AppRoutes.parentHome;
          }
          return null;

        case ColdStartContainmentStatus.hydrating:
          return AppRoutes.containmentLoading;

        case ColdStartContainmentStatus.unauthenticated:
          return AppRoutes.auth;
      }
    },
    routes: [
      GoRoute(
        path: AppRoutes.home,
        name: AppRoutes.homeName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return FamilyHomeScreen(
              key: ValueKey(
                'parent_home_${_scopeKeyPrefix(containment, null)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.foundation,
        name: AppRoutes.foundationName,
        builder: (context, state) => const FoundationScreen(),
      ),
      GoRoute(
        path: AppRoutes.containmentLoading,
        name: AppRoutes.containmentLoadingName,
        builder: (context, state) => const ContainmentHydratingScreen(),
      ),
      GoRoute(
        path: AppRoutes.auth,
        name: AppRoutes.authName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return AuthScreen(
              key: ValueKey('auth_${containment.sessionScopeEpoch}'),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.childRevoked,
        name: AppRoutes.childRevokedName,
        builder: (context, state) => buildRestrictedShell(),
      ),
      GoRoute(
        path: AppRoutes.childUnverified,
        name: AppRoutes.childUnverifiedName,
        builder: (context, state) => buildRestrictedShell(),
      ),
      GoRoute(
        path: AppRoutes.childContainmentLocked,
        name: AppRoutes.childContainmentLockedName,
        builder: (context, state) => buildRestrictedShell(),
      ),
      GoRoute(
        path: AppRoutes.accountUnverified,
        name: AppRoutes.accountUnverifiedName,
        builder: (context, state) => buildRestrictedShell(),
      ),
      GoRoute(
        path: AppRoutes.accountAccessRestricted,
        name: AppRoutes.accountAccessRestrictedName,
        builder: (context, state) => buildRestrictedShell(),
      ),
      GoRoute(
        path: AppRoutes.familyOnboarding,
        name: AppRoutes.familyOnboardingName,
        builder: (context, state) => buildRestrictedShell(),
      ),
      GoRoute(
        path: AppRoutes.createFamily,
        name: AppRoutes.createFamilyName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return CreateFamilyScreen(
              key: ValueKey(
                'create_family_${_scopeKeyPrefix(containment, null)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.parentHome,
        name: AppRoutes.parentHomeName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return FamilyHomeScreen(
              key: ValueKey(
                'parent_home_${_scopeKeyPrefix(containment, null)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.createChild,
        name: AppRoutes.createChildName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return CreateChildScreen(
              key: ValueKey(
                'create_child_${_scopeKeyPrefix(containment, null)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.parentRewards,
        name: AppRoutes.parentRewardsName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return ParentRewardCatalogScreen(
              key: ValueKey(
                'parent_rewards_${_scopeKeyPrefix(containment, null)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.parentCreateReward,
        name: AppRoutes.parentCreateRewardName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return ParentRewardFormScreen(
              key: ValueKey(
                'parent_reward_form_${_scopeKeyPrefix(containment, null)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.parentEditReward,
        name: AppRoutes.parentEditRewardName,
        builder: (context, state) {
          final reward = state.extra as Reward?;
          return Consumer(
            builder: (context, widgetRef, _) {
              final containment = widgetRef.watch(coldStartContainmentProvider);
              return ParentRewardFormScreen(
                key: ValueKey(
                  'parent_reward_edit_${reward?.id.value ?? 'none'}_${_scopeKeyPrefix(containment, null)}',
                ),
                rewardToEdit: reward,
              );
            },
          );
        },
      ),
      GoRoute(
        path: AppRoutes.parentFulfillmentInbox,
        name: AppRoutes.parentFulfillmentInboxName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return ParentFulfillmentInboxScreen(
              key: ValueKey(
                'parent_inbox_${_scopeKeyPrefix(containment, null)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.parentWheelSettings,
        name: AppRoutes.parentWheelSettingsName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            return ParentWheelSettingsScreen(
              key: ValueKey(
                'parent_wheel_${_scopeKeyPrefix(containment, null)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.childMode,
        name: AppRoutes.childModeName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            final activeChild = widgetRef.watch(activeChildModeProvider);
            return ChildModeScreen(
              key: ValueKey(
                'child_mode_${_scopeKeyPrefix(containment, activeChild)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.childStore,
        name: AppRoutes.childStoreName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            final activeChild = widgetRef.watch(activeChildModeProvider);
            return ChildStoreScreen(
              key: ValueKey(
                'child_store_${_scopeKeyPrefix(containment, activeChild)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.childRedemptions,
        name: AppRoutes.childRedemptionsName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            final activeChild = widgetRef.watch(activeChildModeProvider);
            return ChildRedemptionHistoryScreen(
              key: ValueKey(
                'child_redemptions_${_scopeKeyPrefix(containment, activeChild)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.childMastery,
        name: AppRoutes.childMasteryName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            final activeChild = widgetRef.watch(activeChildModeProvider);
            if (activeChild == null) {
              return const Scaffold(
                body: Center(child: Text('No active child')),
              );
            }
            return ChildMasteryScreen(
              key: ValueKey(
                'child_mastery_${_scopeKeyPrefix(containment, activeChild)}',
              ),
              childId: activeChild.id,
              childDisplayName: activeChild.displayName,
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.childNodeDetail,
        name: AppRoutes.childNodeDetailName,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          final nodeId = extra?['learningNodeId'] as String? ?? '';
          return Consumer(
            builder: (context, widgetRef, _) {
              final containment = widgetRef.watch(coldStartContainmentProvider);
              final activeChild = widgetRef.watch(activeChildModeProvider);
              if (activeChild == null || nodeId.isEmpty) {
                return const Scaffold(
                  body: Center(child: Text('No active child')),
                );
              }
              return NodeLearningDetailScreen(
                key: ValueKey(
                  'child_node_${nodeId}_${_scopeKeyPrefix(containment, activeChild)}',
                ),
                childId: activeChild.id,
                learningNodeId: nodeId,
                childDisplayName: activeChild.displayName,
              );
            },
          );
        },
      ),
      GoRoute(
        path: AppRoutes.childWheel,
        name: AppRoutes.childWheelName,
        builder: (context, state) => Consumer(
          builder: (context, widgetRef, _) {
            final containment = widgetRef.watch(coldStartContainmentProvider);
            final activeChild = widgetRef.watch(activeChildModeProvider);
            return ChildWheelScreen(
              key: ValueKey(
                'child_wheel_${_scopeKeyPrefix(containment, activeChild)}',
              ),
            );
          },
        ),
      ),
      GoRoute(
        path: AppRoutes.childAddAssessment,
        name: AppRoutes.childAddAssessmentName,
        builder: (context, state) {
          final draft = state.extra as LocalAssessmentDraft?;
          return Consumer(
            builder: (context, widgetRef, _) {
              final containment = widgetRef.watch(coldStartContainmentProvider);
              final activeChild = widgetRef.watch(activeChildModeProvider);
              return AddAssessmentScreen(
                key: ValueKey(
                  'child_add_assessment_${draft?.localDraftId ?? 'new'}_${_scopeKeyPrefix(containment, activeChild)}',
                ),
                initialDraft: draft,
              );
            },
          );
        },
      ),
      GoRoute(
        path: AppRoutes.parentReviewAssessment,
        name: AppRoutes.parentReviewAssessmentName,
        builder: (context, state) {
          final assessment = state.extra as Assessment;
          return Consumer(
            builder: (context, widgetRef, _) {
              final containment = widgetRef.watch(coldStartContainmentProvider);
              return ReviewAssessmentScreen(
                key: ValueKey(
                  'parent_review_${assessment.id.value}_${_scopeKeyPrefix(containment, null)}',
                ),
                assessment: assessment,
              );
            },
          );
        },
      ),
      GoRoute(
        path: AppRoutes.parentVerifiedHistory,
        name: AppRoutes.parentVerifiedHistoryName,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return Consumer(
            builder: (context, widgetRef, _) {
              final containment = widgetRef.watch(coldStartContainmentProvider);
              return VerifiedHistoryScreen(
                key: ValueKey(
                  'parent_history_${_scopeKeyPrefix(containment, null)}',
                ),
                childId: extra['childId'] as ChildId,
                childDisplayName: extra['childDisplayName'] as String,
              );
            },
          );
        },
      ),
      GoRoute(
        path: AppRoutes.parentLearningOverview,
        name: AppRoutes.parentLearningOverviewName,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return Consumer(
            builder: (context, widgetRef, _) {
              final containment = widgetRef.watch(coldStartContainmentProvider);
              return LearningOverviewScreen(
                key: ValueKey(
                  'parent_overview_${_scopeKeyPrefix(containment, null)}',
                ),
                childId: extra['childId'] as ChildId,
                childDisplayName:
                    extra['childDisplayName'] as String? ?? 'Learner',
              );
            },
          );
        },
      ),
      GoRoute(
        path: AppRoutes.parentNodeDetail,
        name: AppRoutes.parentNodeDetailName,
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>;
          return Consumer(
            builder: (context, widgetRef, _) {
              final containment = widgetRef.watch(coldStartContainmentProvider);
              return NodeLearningDetailScreen(
                key: ValueKey(
                  'parent_node_${_scopeKeyPrefix(containment, null)}',
                ),
                childId: extra['childId'] as ChildId,
                learningNodeId: extra['learningNodeId'] as String,
                childDisplayName:
                    extra['childDisplayName'] as String? ?? 'Learner',
              );
            },
          );
        },
      ),
    ],
  );

  ref.onDispose(router.dispose);
  return router;
});
