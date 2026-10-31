import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';

/// Parent/Guardian home dashboard.
///
/// Displays family overview, adult role status, and the registered children.
/// Allows adding child profiles or entering shared-device Child Mode.
class FamilyHomeScreen extends ConsumerStatefulWidget {
  const FamilyHomeScreen({super.key});

  @override
  ConsumerState<FamilyHomeScreen> createState() => _FamilyHomeScreenState();
}

class _FamilyHomeScreenState extends ConsumerState<FamilyHomeScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  List<ChildProfile> _children = [];

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
          _isLoading = false;
        });
        return;
      }

      final currentActive = ref.read(activeFamilyProvider) ?? families.first;
      ref.read(activeFamilyProvider.notifier).selectFamily(currentActive);

      final childRepo = ref.read(childProfileRepositoryProvider);
      final listChildren = ListFamilyChildren(childRepo);
      final children = await listChildren(currentActive.id);

      setState(() {
        _children = children;
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
                    child: ListTile(
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
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
