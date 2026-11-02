import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';

/// Screen allowing parents to view, toggle, and manage the family reward catalog.
class ParentRewardCatalogScreen extends ConsumerStatefulWidget {
  const ParentRewardCatalogScreen({super.key});

  @override
  ConsumerState<ParentRewardCatalogScreen> createState() =>
      _ParentRewardCatalogScreenState();
}

class _ParentRewardCatalogScreenState
    extends ConsumerState<ParentRewardCatalogScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  List<Reward> _rewards = [];
  int _pendingFulfillmentsCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  Future<void> _loadData() async {
    final family = ref.read(activeFamilyProvider);
    if (family == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final rewardRepo = ref.read(rewardRepositoryProvider);
      final listRewards = ListFamilyRewards(rewardRepo);
      final rewards = await listRewards(familyId: family.id);

      final listRedemptions = ListRewardRedemptions(rewardRepo);
      final pending = await listRedemptions(
        familyId: family.id,
        status: RewardRedemptionStatus.pendingFulfillment,
      );

      if (mounted) {
        setState(() {
          _rewards = rewards;
          _pendingFulfillmentsCount = pending.length;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load rewards: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _toggleActive(Reward reward, bool value) async {
    try {
      final updated = reward.copyWith(isActive: value);
      final updateUseCase = UpdateReward(ref.read(rewardRepositoryProvider));
      await updateUseCase(updated);
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update reward: ${e.toString()}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reward Catalog'),
        actions: [
          IconButton(
            key: const Key('inbox_button'),
            tooltip: 'Fulfillment Inbox',
            icon: Badge(
              isLabelVisible: _pendingFulfillmentsCount > 0,
              label: Text('$_pendingFulfillmentsCount'),
              child: const Icon(Icons.inbox),
            ),
            onPressed: () async {
              await context.push(AppRoutes.parentFulfillmentInbox);
              if (mounted) unawaited(_loadData());
            },
          ),
          IconButton(
            key: const Key('add_reward_button'),
            tooltip: 'Create Reward',
            icon: const Icon(Icons.add),
            onPressed: () async {
              await context.push(AppRoutes.parentCreateReward);
              if (mounted) unawaited(_loadData());
            },
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(onRefresh: _loadData, child: _buildBody(theme)),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create_reward_fab'),
        onPressed: () async {
          await context.push(AppRoutes.parentCreateReward);
          if (mounted) unawaited(_loadData());
        },
        icon: const Icon(Icons.add),
        label: const Text('Add Reward'),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.md),
              FilledButton(onPressed: _loadData, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_rewards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.redeem, size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: AppSpacing.md),
              Text(
                'No rewards configured yet',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Add privileges, treats, or experiences that your children can earn with their Reward Points.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: () async {
                  await context.push(AppRoutes.parentCreateReward);
                  if (mounted) unawaited(_loadData());
                },
                icon: const Icon(Icons.add),
                label: const Text('Create First Reward'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        top: AppSpacing.md,
        bottom: 80, // FAB clearance
      ),
      itemCount: _rewards.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final reward = _rewards[index];
        return _buildRewardCard(theme, reward);
      },
    );
  }

  Widget _buildRewardCard(ThemeData theme, Reward reward) {
    final costRp = reward.storeCostRp;
    return Card(
      key: Key('reward_card_${reward.id.value}'),
      elevation: reward.isActive ? 1 : 0,
      color: reward.isActive
          ? theme.colorScheme.surface
          : theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: reward.isActive
              ? theme.colorScheme.outlineVariant
              : theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: reward.isActive
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHighest,
              child: Icon(
                _getCategoryIcon(reward.category),
                color: reward.isActive
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          reward.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            decoration: reward.isActive
                                ? null
                                : TextDecoration.lineThrough,
                            color: reward.isActive
                                ? theme.colorScheme.onSurface
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (costRp != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${costRp.toStringAsFixed(costRp.truncateToDouble() == costRp ? 0 : 2)} RP',
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (reward.description != null &&
                      reward.description!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      reward.description!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Chip(
                        label: Text(reward.category.displayName),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        labelStyle: theme.textTheme.labelSmall,
                      ),
                      if (reward.wheelEnabled && reward.wheelTier != null) ...[
                        const SizedBox(width: 4),
                        Chip(
                          avatar: const Icon(Icons.toll, size: 14),
                          label: Text(reward.wheelTier!.displayName),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          labelStyle: theme.textTheme.labelSmall,
                        ),
                      ],
                      const Spacer(),
                      Text(
                        reward.isActive ? 'Active' : 'Paused',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: reward.isActive
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Switch(
                        key: Key('toggle_active_${reward.id.value}'),
                        value: reward.isActive,
                        onChanged: (val) => _toggleActive(reward, val),
                      ),
                      IconButton(
                        key: Key('edit_reward_${reward.id.value}'),
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        tooltip: 'Edit',
                        onPressed: () async {
                          await context.push(
                            AppRoutes.parentEditReward,
                            extra: reward,
                          );
                          if (mounted) unawaited(_loadData());
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getCategoryIcon(RewardCategory category) {
    switch (category) {
      case RewardCategory.privilege:
        return Icons.star_outline;
      case RewardCategory.experience:
        return Icons.celebration_outlined;
      case RewardCategory.treat:
        return Icons.cake_outlined;
      case RewardCategory.item:
        return Icons.inventory_2_outlined;
      case RewardCategory.choice:
        return Icons.how_to_vote_outlined;
      case RewardCategory.custom:
        return Icons.auto_awesome_outlined;
    }
  }
}
