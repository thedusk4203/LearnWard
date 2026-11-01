import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Screen allowing parents to review pending reward claims, deliver them,
/// or cancel with a compensating RP refund.
class ParentFulfillmentInboxScreen extends ConsumerStatefulWidget {
  const ParentFulfillmentInboxScreen({super.key});

  @override
  ConsumerState<ParentFulfillmentInboxScreen> createState() =>
      _ParentFulfillmentInboxScreenState();
}

class _ParentFulfillmentInboxScreenState
    extends ConsumerState<ParentFulfillmentInboxScreen> {
  bool _isLoading = false;
  String? _errorMessage;
  List<RewardRedemption> _redemptions = [];
  Map<String, String> _childNames = {};
  RewardRedemptionStatus? _statusFilter =
      RewardRedemptionStatus.pendingFulfillment;

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
    final family = ref.read(activeFamilyProvider);
    if (family == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final childRepo = ref.read(childProfileRepositoryProvider);
      final listChildren = ListFamilyChildren(childRepo);
      final children = await listChildren(family.id);
      final names = {for (final c in children) c.id.value: c.displayName};

      final rewardRepo = ref.read(rewardRepositoryProvider);
      final listRedemptions = ListRewardRedemptions(rewardRepo);
      final redemptions = await listRedemptions(
        familyId: family.id,
        status: _statusFilter,
      );

      if (mounted) {
        setState(() {
          _redemptions = redemptions;
          _childNames = names;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load redemptions: ${e.toString()}';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _fulfill(RewardRedemption redemption) async {
    final commandId = _generateCommandId();
    try {
      final fulfillUseCase = FulfillRewardRedemption(
        ref.read(rewardRepositoryProvider),
      );
      await fulfillUseCase(commandId: commandId, redemptionId: redemption.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Delivered "${redemption.rewardTitle}" to ${_childNames[redemption.childId.value] ?? 'child'}!',
            ),
          ),
        );
      }
      await _loadData();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to fulfill reward: ${e.toString()}')),
        );
      }
    }
  }

  Future<void> _cancelAndRefund(RewardRedemption redemption) async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Cancel & Refund Reward'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cancel "${redemption.rewardTitle}" for ${_childNames[redemption.childId.value] ?? 'child'}?',
              ),
              const SizedBox(height: 8),
              Text(
                '${redemption.rpCost.toStringAsFixed(redemption.rpCost.truncateToDouble() == redemption.rpCost ? 0 : 2)} RP will be immediately refunded to their balance.',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('cancellation_reason_input'),
                controller: reasonController,
                decoration: const InputDecoration(
                  labelText: 'Cancellation reason *',
                  hintText: 'e.g. Activity unavailable this weekend',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Back'),
            ),
            FilledButton(
              key: const Key('confirm_cancel_button'),
              onPressed: () {
                if (reasonController.text.trim().length >= 2) {
                  Navigator.of(ctx).pop(true);
                }
              },
              child: const Text('Cancel & Refund'),
            ),
          ],
        );
      },
    );

    if (confirmed == true && reasonController.text.trim().isNotEmpty) {
      final commandId = _generateCommandId();
      try {
        final cancelUseCase = CancelRewardRedemption(
          ref.read(rewardRepositoryProvider),
        );
        await cancelUseCase(
          commandId: commandId,
          redemptionId: redemption.id,
          cancellationReason: reasonController.text.trim(),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Cancelled. ${redemption.rpCost.toStringAsFixed(0)} RP refunded to balance.',
              ),
            ),
          );
        }
        await _loadData();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to cancel reward: ${e.toString()}')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Fulfillment Inbox')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: SegmentedButton<RewardRedemptionStatus?>(
                segments: const [
                  ButtonSegment(
                    value: RewardRedemptionStatus.pendingFulfillment,
                    label: Text('Pending'),
                  ),
                  ButtonSegment(
                    value: RewardRedemptionStatus.fulfilled,
                    label: Text('Fulfilled'),
                  ),
                  ButtonSegment(
                    value: RewardRedemptionStatus.cancelled,
                    label: Text('Cancelled'),
                  ),
                  ButtonSegment(value: null, label: Text('All')),
                ],
                selected: {_statusFilter},
                onSelectionChanged: (set) {
                  setState(() {
                    _statusFilter = set.first;
                  });
                  _loadData();
                },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadData,
                child: _buildList(theme),
              ),
            ),
          ],
        ),
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
              Icon(Icons.inbox, size: 64, color: theme.colorScheme.outline),
              const SizedBox(height: AppSpacing.md),
              Text(
                _statusFilter == RewardRedemptionStatus.pendingFulfillment
                    ? 'No pending reward claims'
                    : 'No redemptions found',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'When children spend their Reward Points, their claims appear here for delivery.',
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
        final childName = _childNames[item.childId.value] ?? 'Child';
        return _buildRedemptionCard(theme, item, childName);
      },
    );
  }

  Widget _buildRedemptionCard(
    ThemeData theme,
    RewardRedemption item,
    String childName,
  ) {
    final costRp = item.rpCost;

    return Card(
      key: Key('redemption_card_${item.id.value}'),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Icon(
                    Icons.card_giftcard,
                    color: theme.colorScheme.onPrimaryContainer,
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
                        'Claimed by $childName • ${costRp.toStringAsFixed(costRp.truncateToDouble() == costRp ? 0 : 2)} RP',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusBadge(theme, item.status),
              ],
            ),
            if (item.cancellationReason != null) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Reason: ${item.cancellationReason!}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
            if (item.isPending) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    key: Key('cancel_button_${item.id.value}'),
                    onPressed: () => _cancelAndRefund(item),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    child: const Text('Cancel & Refund'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: Key('fulfill_button_${item.id.value}'),
                    onPressed: () => _fulfill(item),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Deliver Reward'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(ThemeData theme, RewardRedemptionStatus status) {
    Color bg;
    Color fg;
    final label = status.displayName;

    switch (status) {
      case RewardRedemptionStatus.pendingFulfillment:
        bg = Colors.amber.withValues(alpha: 0.2);
        fg = Colors.amber.shade900;
        break;
      case RewardRedemptionStatus.fulfilled:
        bg = Colors.green.withValues(alpha: 0.2);
        fg = Colors.green.shade800;
        break;
      case RewardRedemptionStatus.cancelled:
        bg = Colors.grey.withValues(alpha: 0.2);
        fg = Colors.grey.shade800;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}
