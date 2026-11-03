import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';
import '../../assessments/presentation/growth_result_screen.dart';
import '../../shared_device/presentation/parent_gate_dialog.dart';

/// Screen displayed when the app is in Child Mode on a shared family device.
///
/// Features a restricted child UI displaying learner balance (Study XP and RP),
/// latest Growth breakdown, verified learning history, and draft capture.
class ChildModeScreen extends ConsumerStatefulWidget {
  const ChildModeScreen({super.key});

  @override
  ConsumerState<ChildModeScreen> createState() => _ChildModeScreenState();
}

class _ChildModeScreenState extends ConsumerState<ChildModeScreen> {
  List<LocalAssessmentDraft> _localDrafts = [];
  ChildBalance? _childBalance;
  GrowthEvent? _latestGrowth;
  List<GrowthEvent> _growthHistory = [];
  bool _isLoadingEconomy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadLocalDrafts();
      _loadEconomyData();
    });
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

  Future<void> _loadEconomyData() async {
    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) return;

    setState(() => _isLoadingEconomy = true);
    try {
      final growthRepo = ref.read(growthRepositoryProvider);
      final getBalance = GetChildBalance(growthRepo);
      final getLatest = GetLatestGrowthEvent(growthRepo);
      final listGrowth = ListGrowthEvents(growthRepo);

      final balance = await getBalance(activeChild.id);
      final latest = await getLatest(activeChild.id);
      final history = await listGrowth(activeChild.id);

      if (mounted) {
        setState(() {
          _childBalance = balance;
          _latestGrowth = latest;
          _growthHistory = history;
        });
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isLoadingEconomy = false);
      }
    }
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
                    radius: 36,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(
                      Icons.school,
                      size: 36,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'Welcome to LearnWard, $displayName!',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.md),

                  if (_isLoadingEconomy)
                    const Padding(
                      padding: EdgeInsets.only(bottom: AppSpacing.xs),
                      child: LinearProgressIndicator(),
                    ),
                  // 1. Authoritative Economic Balances Card (XP & RP)
                  Card(
                    key: const Key('child_balances_card'),
                    elevation: 1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.bolt,
                                      size: 20,
                                      color: theme.colorScheme.secondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Study XP',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  key: const Key('child_xp_total'),
                                  '${_childBalance?.xpTotal.value ?? 0} XP',
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.secondary,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Progression',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            height: 48,
                            width: 1,
                            color: theme.colorScheme.outlineVariant,
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.stars,
                                      size: 20,
                                      color: theme.colorScheme.primary,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Reward Points',
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  key: const Key('child_rp_balance'),
                                  '${_childBalance?.rpBalanceMinor.formatRp() ?? '0.00'} RP',
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.bold,
                                        color: theme.colorScheme.primary,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Family Currency',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: AppSpacing.md),

                  // 2. Latest Growth Breakdown Card
                  if (_latestGrowth != null) ...[
                    Card(
                      key: const Key('latest_growth_card'),
                      elevation: 0,
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.25,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.3,
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Latest Verified Result',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade100,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '+${_latestGrowth!.totalRpMinor.formatRp()} RP',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green.shade800,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              'Score: ${_latestGrowth!.normalizedScore.toStringAsFixed(2)} / 10'
                              '${_latestGrowth!.baselineScore != null ? ' • Baseline: ${_latestGrowth!.baselineScore!.toStringAsFixed(2)}' : ''}'
                              '${_latestGrowth!.growthDelta != null ? ' (Δ ${_latestGrowth!.growthDelta! >= 0 ? '+' : ''}${_latestGrowth!.growthDelta!.toStringAsFixed(2)})' : ''}',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                key: const Key('latest_growth_explain_button'),
                                icon: const Icon(Icons.help_outline, size: 16),
                                label: const Text('Why did I get this amount?'),
                                onPressed: () {
                                  GrowthResultScreen.show(
                                    context,
                                    growthEvent: _latestGrowth!,
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],

                  // 3. Actions: Add Result & View Mastery
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('child_add_assessment_button'),
                          icon: const Icon(Icons.add_task),
                          label: const Text('Add Result'),
                          onPressed: () async {
                            final result = await context.push<bool>(
                              AppRoutes.childAddAssessment,
                            );
                            if (result == true) {
                              unawaited(_loadLocalDrafts());
                              unawaited(_loadEconomyData());
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('child_mastery_button'),
                          icon: const Icon(Icons.school_outlined),
                          label: const Text('My Mastery'),
                          onPressed: () {
                            context.push(AppRoutes.childMastery);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),

                  // 4. Unsubmitted Local Drafts
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
                            key: Key('local_draft_${draft.localDraftId}'),
                            leading: const Icon(Icons.edit_note),
                            title: Text(draft.title),
                            subtitle: Text(
                              '${draft.subject} (${draft.subjectKey.displayLabel}) • ${draft.rawScore} / ${draft.maxScore}',
                            ),
                            onTap: () async {
                              final result = await context.push<bool>(
                                AppRoutes.childAddAssessment,
                                extra: draft,
                              );
                              if (result == true) {
                                unawaited(_loadLocalDrafts());
                                unawaited(_loadEconomyData());
                              }
                            },
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () async {
                                if (draft.localPhotoPath != null) {
                                  try {
                                    await ref
                                        .read(localEvidenceFileStoreProvider)
                                        .deleteEvidence(draft.localPhotoPath!);
                                  } catch (_) {}
                                }
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

                  // Reward Store and Wheel Quick Action Card
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Rewards & Fun',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              TextButton.icon(
                                key: const Key(
                                  'child_redemption_history_button',
                                ),
                                icon: const Icon(Icons.history, size: 16),
                                label: const Text('My Claims'),
                                onPressed: () {
                                  context.push(AppRoutes.childRedemptions);
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  key: const Key('child_reward_store_button'),
                                  icon: const Icon(Icons.storefront, size: 18),
                                  label: const Text('Reward Store'),
                                  onPressed: () async {
                                    await context.push(AppRoutes.childStore);
                                    if (mounted) unawaited(_loadEconomyData());
                                  },
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: OutlinedButton.icon(
                                  key: const Key('child_wheel_button'),
                                  icon: const Icon(
                                    Icons.toll_outlined,
                                    size: 18,
                                  ),
                                  label: const Text('Celebration Wheel'),
                                  onPressed: () async {
                                    await context.push(AppRoutes.childWheel);
                                    if (mounted) unawaited(_loadEconomyData());
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),

                  // 5. Basic Growth History List
                  if (_growthHistory.isNotEmpty) ...[
                    Text(
                      'Recent Growth Awards (${_growthHistory.length})',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _growthHistory.length > 5
                          ? 5
                          : _growthHistory.length,
                      itemBuilder: (ctx, i) {
                        final event = _growthHistory[i];
                        return Card(
                          elevation: 0,
                          margin: const EdgeInsets.only(bottom: AppSpacing.xs),
                          child: ListTile(
                            key: Key('growth_history_item_${event.id}'),
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                              child: Text(
                                event.normalizedScore.toStringAsFixed(1),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            title: Text(
                              '+${event.totalRpMinor.formatRp()} RP • +${event.xpAwarded.value} XP',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              event.growthDelta != null
                                  ? 'Improvement: +${event.growthDelta!.toStringAsFixed(2)} above baseline'
                                  : 'Initial baseline sample',
                            ),
                            trailing: const Icon(Icons.chevron_right, size: 20),
                            onTap: () {
                              GrowthResultScreen.show(
                                context,
                                growthEvent: event,
                              );
                            },
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
