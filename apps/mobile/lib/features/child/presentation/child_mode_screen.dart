import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';
import '../../shared_device/presentation/parent_gate_dialog.dart';

/// Screen displayed when the app is in Child Mode on a shared family device.
///
/// Features a restricted child UI that hides adult family configuration,
/// child profile management, and billing settings.
class ChildModeScreen extends ConsumerWidget {
  const ChildModeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeChild = ref.watch(activeChildModeProvider);
    final theme = Theme.of(context);

    final displayName = activeChild?.displayName ?? 'Learner';

    return Scaffold(
      appBar: AppBar(
        title: Text('Hi, $displayName!'),
        automaticallyImplyLeading: false,
        actions: [
          TextButton.icon(
            key: const Key('exit_child_mode_button'),
            icon: const Icon(Icons.lock_outline, size: 18),
            label: const Text('Exit Child Mode'),
            onPressed: () {
              ParentGateDialog.show(
                context,
                onGatePassed: () async {
                  await ref
                      .read(activeChildModeProvider.notifier)
                      .exitChildMode();
                  if (context.mounted) {
                    context.go(AppRoutes.parentHome);
                  }
                },
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  CircleAvatar(
                    radius: 48,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(
                      Icons.school,
                      size: 48,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    'Welcome to LearnWard, $displayName!',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Your learning journey and verified accomplishments will show up here.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Icon(Icons.info_outline, size: 20),
                              SizedBox(width: AppSpacing.sm),
                              Text(
                                'Shared-Device Child Mode',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          SizedBox(height: AppSpacing.xs),
                          Text(
                            'You are in protected child mode on this shared device. '
                            'Parent configuration and admin settings are locked behind the parent gate.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
