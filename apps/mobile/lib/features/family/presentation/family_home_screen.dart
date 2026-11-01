import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';
import '../../shared_device/presentation/parent_pin_setup_dialog.dart';

/// Parent/Guardian home dashboard.
///
/// Displays family overview, pending assessment review queue,
/// registered children, and access to verified accomplishments.
class FamilyHomeScreen extends ConsumerStatefulWidget {
  const FamilyHomeScreen({super.key});

  @override
  ConsumerState<FamilyHomeScreen> createState() => _FamilyHomeScreenState();
}

class _FamilyHomeScreenState extends ConsumerState<FamilyHomeScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  List<ChildProfile> _children = [];
  List<Assessment> _pendingAssessments = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final familyRepo = ref.read(familyRepositoryProvider);
      final listFamilies = ListMyFamilies(familyRepo);
      final families = await listFamilies();

      if (families.isEmpty) {
        ref.read(activeFamilyProvider.notifier).selectFamily(null);
        setState(() {
          _children = [];
          _pendingAssessments = [];
          _isLoading = false;
        });
        return;
      }

      final currentActive = ref.read(activeFamilyProvider) ?? families.first;
      ref.read(activeFamilyProvider.notifier).selectFamily(currentActive);

      final childRepo = ref.read(childProfileRepositoryProvider);
      final listChildren = ListFamilyChildren(childRepo);
      final children = await listChildren(currentActive.id);

      final assessmentRepo = ref.read(assessmentRepositoryProvider);
      final pendingUseCase = ListPendingAssessments(assessmentRepo);
      final pending = await pendingUseCase.forFamily(currentActive.id);

      setState(() {
        _children = children;
        _pendingAssessments = pending;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load family data: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeFamily = ref.watch(activeFamilyProvider);
    final theme = Theme.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Family Dashboard')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Family Dashboard')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(_errorMessage!, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.md),
                FilledButton(onPressed: _loadData, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }

    // No family created yet
    if (activeFamily == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('LearnWard'),
          actions: [
            IconButton(
              icon: const Icon(Icons.login),
              tooltip: 'Sign In',
              onPressed: () => context.go(AppRoutes.auth),
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.family_restroom,
                      size: 64,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text('No Family Found', style: theme.textTheme.titleLarge),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'You must create a family household before creating child profiles and tracking learning results.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    FilledButton(
                      key: const Key('create_family_button'),
                      onPressed: () => context.go(AppRoutes.createFamily),
                      child: const Text('Create Family'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(activeFamily.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add Child',
            onPressed: () => context.go(AppRoutes.createChild),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle_outlined),
            tooltip: 'Adult Auth',
            onPressed: () => context.go(AppRoutes.auth),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Card(
                elevation: 0,
                color: theme.colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    children: [
                      const Icon(Icons.shield_outlined),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Parent Mode',
                              style: theme.textTheme.titleMedium,
                            ),
                            Text(
                              'Timezone: ${activeFamily.timezone} • Locale: ${activeFamily.locale}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // Pending Reviews Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text(
                        'Pending Reviews',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      if (_pendingAssessments.isNotEmpty)
                        Badge.count(
                          count: _pendingAssessments.length,
                          backgroundColor: theme.colorScheme.error,
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              if (_pendingAssessments.isEmpty)
                Card(
                  elevation: 0,
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(AppSpacing.md),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline, color: Colors.green),
                        SizedBox(width: AppSpacing.sm),
                        Text('All caught up! No pending submissions.'),
                      ],
                    ),
                  ),
                )
              else
                ..._pendingAssessments.map(
                  (assessment) => Card(
                    key: Key('pending_card_${assessment.id.value}'),
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.rate_review_outlined),
                      ),
                      title: Text(assessment.title),
                      subtitle: Text(
                        '${assessment.subject} • Score: ${assessment.score.rawScore} / ${assessment.score.maxScore} (${assessment.score.serverNormalizedScore}/10)',
                      ),
                      trailing: FilledButton(
                        key: Key('review_button_${assessment.id.value}'),
                        onPressed: () async {
                          final result = await context.push<bool>(
                            AppRoutes.parentReviewAssessment,
                            extra: assessment,
                          );
                          if (result == true) {
                            unawaited(_loadData());
                          }
                        },
                        child: const Text('Review'),
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: AppSpacing.lg),

              // Child Profiles Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Child Profiles', style: theme.textTheme.titleLarge),
                  TextButton.icon(
                    key: const Key('add_child_button'),
                    icon: const Icon(Icons.add),
                    label: const Text('Add Child'),
                    onPressed: () => context.go(AppRoutes.createChild),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_children.isEmpty)
                Card(
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Column(
                      children: [
                        const Icon(Icons.child_care, size: 48),
                        const SizedBox(height: AppSpacing.sm),
                        const Text('No child profiles yet.'),
                        const SizedBox(height: AppSpacing.xs),
                        const Text(
                          'Add a child profile to enable shared-device child mode and track learning progress.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        FilledButton(
                          onPressed: () => context.go(AppRoutes.createChild),
                          child: const Text('Add First Child'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ..._children.map(
                  (child) => Card(
                    key: Key('child_card_${child.id.value}'),
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Column(
                      children: [
                        ListTile(
                          leading: CircleAvatar(
                            child: Text(
                              child.displayName.isNotEmpty
                                  ? child.displayName[0].toUpperCase()
                                  : 'C',
                            ),
                          ),
                          title: Text(child.displayName),
                          subtitle: Text(
                            [
                              if (child.schoolGrade != null)
                                'Grade ${child.schoolGrade}',
                              if (child.birthYear != null)
                                'Born ${child.birthYear}',
                              'Status: ${child.status.wireName}',
                            ].join(' • '),
                          ),
                          trailing: FilledButton.tonal(
                            key: Key('enter_child_mode_${child.id.value}'),
                            onPressed: () async {
                              final gateService = ref.read(
                                parentGateServiceProvider,
                              );
                              final hasPin = await gateService
                                  .hasConfiguredPin();
                              if (!context.mounted) return;

                              if (!hasPin) {
                                final pinConfigured =
                                    await ParentPinSetupDialog.show(context);
                                if (!pinConfigured || !context.mounted) {
                                  return;
                                }
                              }

                              await ref
                                  .read(activeChildModeProvider.notifier)
                                  .selectChild(child);
                              if (context.mounted) {
                                context.go(AppRoutes.childMode);
                              }
                            },
                            child: const Text('Child Mode'),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(
                            left: AppSpacing.md,
                            right: AppSpacing.md,
                            bottom: AppSpacing.sm,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton.icon(
                                key: Key('view_history_${child.id.value}'),
                                icon: const Icon(Icons.history, size: 18),
                                label: const Text('Verified History'),
                                onPressed: () {
                                  context.push(
                                    AppRoutes.parentVerifiedHistory,
                                    extra: {
                                      'childId': child.id,
                                      'childDisplayName': child.displayName,
                                    },
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
