import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';

/// Screen allowing children to view available family rewards and redeem them
/// with explicit balance confirmation safeguards.
class ChildStoreScreen extends ConsumerStatefulWidget {
  const ChildStoreScreen({super.key});

  @override
  ConsumerState<ChildStoreScreen> createState() => _ChildStoreScreenState();
}

class _ChildStoreScreenState extends ConsumerState<ChildStoreScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  List<Reward> _storeRewards = [];
  ChildBalance? _childBalance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  String _generateCommandId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    values[6] = (values[6] & 0x0f) | 0x40;
    values[8] = (values[8] & 0x3f) | 0x80;
    final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }

  Future<void> _loadData() async {
    final activeChild = ref.read(activeChildModeProvider);
    final family = ref.read(activeFamilyProvider);
    if (activeChild == null || family == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final growthRepo = ref.read(growthRepositoryProvider);
      final balance = await growthRepo.getChildBalance(activeChild.id);

      final rewardRepo = ref.read(rewardRepositoryProvider);
      final listStore = ListStoreRewards(rewardRepo);
      final rewards = await listStore(
        familyId: family.id,
        childId: activeChild.id,
      );

      if (mounted) {
        setState(() {
          _childBalance = balance;
          _storeRewards = rewards;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load store: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _confirmAndRedeem(Reward reward) async {
    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) return;

    final costMinor = reward.storeCostMinor ?? 0;
    final costRp = (costMinor / 100.0).toStringAsFixed(
      costMinor % 100 == 0 ? 0 : 2,
    );
    final currentRp = (_childBalance?.rpBalanceMinor.formatRp() ?? '0.00');
    final currentMinor = _childBalance?.rpBalanceMinor.value ?? 0;
    final balanceAfterMinor = currentMinor - costMinor;
    final balanceAfterRp = (balanceAfterMinor / 100.0).toStringAsFixed(
      balanceAfterMinor % 100 == 0 ? 0 : 2,
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Get "${reward.title}" for $costRp RP?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (reward.description != null &&
                  reward.description!.isNotEmpty) ...[
                Text(reward.description!),
                const SizedBox(height: 12),
              ],
              const Text(
                'Balance:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    '$currentRp RP',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    '$balanceAfterRp RP',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm_redeem_button'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Get reward'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      final commandId = _generateCommandId();
      try {
        final redeemUseCase = RedeemStoreReward(
          ref.read(rewardRepositoryProvider),
        );
        await redeemUseCase(
          commandId: commandId,
          rewardId: reward.id,
          childId: activeChild.id,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Claimed "${reward.title}"! Ask your parent to fulfill it.',
              ),
              backgroundColor: Theme.of(context).colorScheme.primary,
            ),
          );
        }
        await _loadData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Redemption failed: ${e.toString()}')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balanceMinor = _childBalance?.rpBalanceMinor.value ?? 0;
    final balanceRp = _childBalance?.rpBalanceMinor.formatRp() ?? '0.00';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reward Store'),
        actions: [
          IconButton(
            key: const Key('my_rewards_history_button'),
            tooltip: 'My Claimed Rewards',
            icon: const Icon(Icons.receipt_long),
            onPressed: () async {
              await context.push(AppRoutes.childRedemptions);
              if (mounted) unawaited(_loadData());
            },
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadData,
          child: Column(
            children: [
              // 1. Authoritative Spendable Balance Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  border: Border(
                    bottom: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: theme.colorScheme.primary,
                      radius: 20,
                      child: Icon(
                        Icons.stars,
                        color: theme.colorScheme.onPrimary,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Your Spendable Balance',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                          Text(
                            key: const Key('store_child_balance'),
                            '$balanceRp RP',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await context.push(AppRoutes.childRedemptions);
                        if (mounted) unawaited(_loadData());
                      },
                      icon: const Icon(Icons.history, size: 16),
                      label: const Text('My Claims'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),

              // 2. Celebration Wheel Banner (Coming Soon in Phase 4.2)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  0,
                ),
                child: Card(
                  elevation: 0,
                  color: theme.colorScheme.secondaryContainer.withValues(
                    alpha: 0.5,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: theme.colorScheme.secondary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: Row(
                      children: [
                        Icon(
                          Icons.album,
                          color: theme.colorScheme.secondary,
                          size: 28,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Celebration Wheel',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                              Text(
                                'Coming in the next Phase! Save your RP or spend in the Store.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 3. Catalog Items List
              Expanded(child: _buildStoreList(theme, balanceMinor)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStoreList(ThemeData theme, int balanceMinor) {
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
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: AppSpacing.md),
              FilledButton(onPressed: _loadData, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_storeRewards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.storefront,
                size: 64,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'No rewards in the Store yet',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Ask your parent to add some rewards to the family catalog!',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: _storeRewards.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final reward = _storeRewards[index];
        final costMinor = reward.storeCostMinor ?? 0;
        final isAffordable = balanceMinor >= costMinor;
        final costRp = (costMinor / 100.0).toStringAsFixed(
          costMinor % 100 == 0 ? 0 : 2,
        );

        return Card(
          key: Key('store_item_${reward.id.value}'),
          elevation: isAffordable ? 2 : 0,
          color: isAffordable
              ? theme.colorScheme.surface
              : theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isAffordable
                  ? theme.colorScheme.outlineVariant
                  : theme.colorScheme.outline.withValues(alpha: 0.2),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: isAffordable
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.star,
                    color: isAffordable
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reward.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: isAffordable
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (reward.description != null &&
                          reward.description!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          reward.description!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isAffordable
                              ? theme.colorScheme.primary.withValues(alpha: 0.1)
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$costRp RP',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: isAffordable
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                isAffordable
                    ? FilledButton(
                        key: Key('redeem_button_${reward.id.value}'),
                        onPressed: () => _confirmAndRedeem(reward),
                        child: const Text('Get reward'),
                      )
                    : OutlinedButton(
                        onPressed: null,
                        child: Text(
                          'Need ${((costMinor - balanceMinor) / 100.0).toStringAsFixed(0)} more',
                        ),
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}
