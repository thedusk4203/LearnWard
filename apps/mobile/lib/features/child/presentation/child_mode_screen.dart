import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';
import '../../shared_device/presentation/parent_gate_dialog.dart';

/// Screen displayed when the app is in Child Mode on a shared family device.
///
/// Features a restricted child UI that hides adult family configuration,
/// child profile management, and billing settings.
class ChildModeScreen extends ConsumerStatefulWidget {
  const ChildModeScreen({super.key});

  @override
  ConsumerState<ChildModeScreen> createState() => _ChildModeScreenState();
}

class _ChildModeScreenState extends ConsumerState<ChildModeScreen> {
  List<LocalAssessmentDraft> _localDrafts = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLocalDrafts());
  }

  Future<void> _loadLocalDrafts() async {
    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) return;
    try {
      final store = ref.read(localDraftStoreProvider);
      final drafts = await store.listLocalDrafts(activeChild.id);
      if (mounted) {
        setState(() => _localDrafts = drafts);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(
                      Icons.school,
                      size: 40,
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
                    'Capture your scores, test papers, and learning accomplishments.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  FilledButton.icon(
                    key: const Key('child_add_assessment_button'),
                    icon: const Icon(Icons.add_task),
                    label: const Text('Add Academic Result'),
                    onPressed: () async {
                      final result = await context.push<bool>(
                        AppRoutes.childAddAssessment,
                      );
                      if (result == true) {
                        unawaited(_loadLocalDrafts());
                      }
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_localDrafts.isNotEmpty) ...[
                    Text(
                      'Unsubmitted Local Drafts (${_localDrafts.length})',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _localDrafts.length,
                      itemBuilder: (ctx, i) {
                        final draft = _localDrafts[i];
                        return Card(
                          elevation: 0,
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: ListTile(
                            leading: const Icon(Icons.edit_note),
                            title: Text(draft.title),
                            subtitle: Text(
                              '${draft.subject} • ${draft.rawScore} / ${draft.maxScore}',
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () async {
                                final store = ref.read(localDraftStoreProvider);
                                await store.deleteLocalDraft(
                                  draft.localDraftId,
                                );
                                unawaited(_loadLocalDrafts());
                              },
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
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
