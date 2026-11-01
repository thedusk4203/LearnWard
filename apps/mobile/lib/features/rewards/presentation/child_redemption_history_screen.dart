import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Screen allowing children to view their historical reward redemptions and pending claims.
class ChildRedemptionHistoryScreen extends ConsumerStatefulWidget {
  const ChildRedemptionHistoryScreen({super.key});

  @override
  ConsumerState<ChildRedemptionHistoryScreen> createState() =>
      _ChildRedemptionHistoryScreenState();
}

class _ChildRedemptionHistoryScreenState
    extends ConsumerState<ChildRedemptionHistoryScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  List<RewardRedemption> _redemptions = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
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
      final rewardRepo = ref.read(rewardRepositoryProvider);
      final listRedemptions = ListRewardRedemptions(rewardRepo);
      final redemptions = await listRedemptions(
        familyId: family.id,
        childId: activeChild.id,
      );

      if (mounted) {
        setState(() {
          _redemptions = redemptions;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load claims: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('My Claimed Rewards')),
      body: SafeArea(
        child: RefreshIndicator(onRefresh: _loadData, child: _buildList(theme)),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
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

    if (_redemptions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.history, size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: AppSpacing.md),
              Text('No reward claims yet', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'When you choose rewards in the Store, they will appear here.',
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
      itemCount: _redemptions.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final item = _redemptions[index];
        return _buildItemCard(theme, item);
      },
    );
  }

  Widget _buildItemCard(ThemeData theme, RewardRedemption item) {
    final costRp = item.rpCost;

    return Card(
      key: Key('child_claim_${item.id.value}'),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: _getStatusColor(item.status)
                  .withValues(alpha: 0.15),
              child: Icon(
                _getStatusIcon(item.status),
                color: _getStatusColor(item.status),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.rewardTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${costRp.toStringAsFixed(costRp.truncateToDouble() == costRp ? 0 : 2)} RP • ${_getStatusLabel(item.status)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _getStatusColor(item.status),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.cancellationReason != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Refunded: ${item.cancellationReason!}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(RewardRedemptionStatus status) {
    switch (status) {
      case RewardRedemptionStatus.pendingFulfillment:
        return Colors.amber.shade800;
      case RewardRedemptionStatus.fulfilled:
        return Colors.green.shade700;
      case RewardRedemptionStatus.cancelled:
        return Colors.grey.shade600;
    }
  }

  IconData _getStatusIcon(RewardRedemptionStatus status) {
    switch (status) {
      case RewardRedemptionStatus.pendingFulfillment:
        return Icons.hourglass_top;
      case RewardRedemptionStatus.fulfilled:
        return Icons.check_circle_outline;
      case RewardRedemptionStatus.cancelled:
        return Icons.cancel_outlined;
    }
  }

  String _getStatusLabel(RewardRedemptionStatus status) {
    switch (status) {
      case RewardRedemptionStatus.pendingFulfillment:
        return 'Waiting for parent';
      case RewardRedemptionStatus.fulfilled:
        return 'Delivered / Fulfilled';
      case RewardRedemptionStatus.cancelled:
        return 'Cancelled & Refunded';
    }
  }
}
