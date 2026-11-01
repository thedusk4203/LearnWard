import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Parent inbox for managing and fulfilling pending child reward claims
/// with durable restart-safe idempotency.
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
  List<PendingRewardCommand> _pendingUpdates = [];
  final Set<String> _inFlightRedemptionIds = {};

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

      final commandStore = ref.read(pendingRewardCommandStoreProvider);
      final pendingCommands = await commandStore.listPendingCommands(
        familyId: family.id.value,
      );
      final pendingUpdates = pendingCommands
          .where(
            (cmd) =>
                cmd.operation == RewardCommandOperation.fulfillReward ||
                cmd.operation == RewardCommandOperation.cancelReward,
          )
          .toList();

      if (mounted) {
        setState(() {
          _redemptions = redemptions;
          _childNames = names;
          _pendingUpdates = pendingUpdates;
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
    final family = ref.read(activeFamilyProvider);
    if (family == null) return;

    if (_inFlightRedemptionIds.contains(redemption.id.value) ||
        _pendingUpdates.any((p) => p.redemptionId == redemption.id.value)) {
      return;
    }

    setState(() => _inFlightRedemptionIds.add(redemption.id.value));
    try {
      final commandStore = ref.read(pendingRewardCommandStoreProvider);
      final fulfillUseCase = FulfillRewardRedemption(
        ref.read(rewardRepositoryProvider),
        commandStore: commandStore,
      );
      await fulfillUseCase(familyId: family.id, redemptionId: redemption.id);
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
      await _loadData();
      if (mounted) {
        final isTerminal =
            e.toString().contains('LW204') ||
            e.toString().contains('LW004') ||
            e.toString().contains('InvalidRedemptionException');
        final msg = isTerminal
            ? 'Failed to fulfill reward: ${e.toString()}'
            : "We're checking whether the delivery was saved. Tap retry if needed.";
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) {
        setState(() => _inFlightRedemptionIds.remove(redemption.id.value));
      }
    }
  }

  Future<void> _cancelAndRefund(RewardRedemption redemption) async {
    final family = ref.read(activeFamilyProvider);
    if (family == null) return;

    if (_inFlightRedemptionIds.contains(redemption.id.value) ||
        _pendingUpdates.any((p) => p.redemptionId == redemption.id.value)) {
      return;
    }

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
      setState(() => _inFlightRedemptionIds.add(redemption.id.value));
      try {
        final commandStore = ref.read(pendingRewardCommandStoreProvider);
        final cancelUseCase = CancelRewardRedemption(
          ref.read(rewardRepositoryProvider),
          commandStore: commandStore,
        );
        await cancelUseCase(
          familyId: family.id,
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
        await _loadData();
        if (mounted) {
          final isTerminal =
              e.toString().contains('LW204') ||
              e.toString().contains('LW004') ||
              e.toString().contains('InvalidRedemptionException');
          final msg = isTerminal
              ? 'Failed to cancel reward: ${e.toString()}'
              : "We're checking whether the cancellation was processed. Tap retry if needed.";
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
      } finally {
        if (mounted) {
          setState(() => _inFlightRedemptionIds.remove(redemption.id.value));
        }
      }
    }
  }

  Future<void> _resolvePendingUpdate(PendingRewardCommand pending) async {
    final family = ref.read(activeFamilyProvider);
    if (family == null || pending.redemptionId == null) return;

    setState(() => _inFlightRedemptionIds.add(pending.redemptionId!));
    try {
      final commandStore = ref.read(pendingRewardCommandStoreProvider);
      if (pending.operation == RewardCommandOperation.fulfillReward) {
        final fulfillUseCase = FulfillRewardRedemption(
          ref.read(rewardRepositoryProvider),
          commandStore: commandStore,
        );
        await fulfillUseCase(
          commandId: pending.commandId,
          familyId: family.id,
          redemptionId: RewardRedemptionId(pending.redemptionId!),
        );
      } else if (pending.operation == RewardCommandOperation.cancelReward) {
        final cancelUseCase = CancelRewardRedemption(
          ref.read(rewardRepositoryProvider),
          commandStore: commandStore,
        );
        await cancelUseCase(
          commandId: pending.commandId,
          familyId: family.id,
          redemptionId: RewardRedemptionId(pending.redemptionId!),
          cancellationReason:
              pending.cancellationReason ?? 'Cancelled by parent',
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pending reward update verified!')),
        );
      }
      await _loadData();
    } catch (e) {
      await _loadData();
      if (mounted) {
        final isTerminal =
            e.toString().contains('LW204') ||
            e.toString().contains('LW004') ||
            e.toString().contains('InvalidRedemptionException');
        final msg = isTerminal
            ? 'Update failed: ${e.toString()}'
            : "We're checking whether the update was processed. Tap retry to verify.";
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) {
        setState(() => _inFlightRedemptionIds.remove(pending.redemptionId!));
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

            // Pending Update Recovery Banner
            if (_pendingUpdates.isNotEmpty)
              Container(
                key: const Key('pending_fulfillment_recovery_banner'),
                width: double.infinity,
                margin: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: theme.colorScheme.tertiary),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.hourglass_top,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        "We're checking whether a reward update was completed.",
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    FilledButton.tonal(
                      key: const Key('retry_pending_fulfillment_button'),
                      onPressed: _inFlightRedemptionIds.isNotEmpty
                          ? null
                          : () => _resolvePendingUpdate(_pendingUpdates.first),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),

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
    final isPendingUpdate = _pendingUpdates.any(
      (p) => p.redemptionId == item.id.value,
    );
    final isInFlight = _inFlightRedemptionIds.contains(item.id.value);

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
                      const SizedBox(height: 4),
                      Text(
                        'Date: ${item.createdAt.toLocal().toString().split('.').first}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusChip(theme, item.status),
              ],
            ),
            if (item.status == RewardRedemptionStatus.cancelled &&
                item.cancellationReason != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.3,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Cancellation Reason: ${item.cancellationReason}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
            if (item.status == RewardRedemptionStatus.pendingFulfillment) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    key: Key('cancel_button_${item.id.value}'),
                    onPressed: isInFlight || isPendingUpdate
                        ? null
                        : () => _cancelAndRefund(item),
                    child: const Text('Cancel & Refund'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    key: Key('fulfill_button_${item.id.value}'),
                    onPressed: isInFlight || isPendingUpdate
                        ? null
                        : () => _fulfill(item),
                    child: Text(
                      isInFlight || isPendingUpdate
                          ? 'Checking...'
                          : 'Mark as Delivered',
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(ThemeData theme, RewardRedemptionStatus status) {
    Color bg;
    Color fg;
    String label;

    switch (status) {
      case RewardRedemptionStatus.pendingFulfillment:
        bg = theme.colorScheme.tertiaryContainer;
        fg = theme.colorScheme.onTertiaryContainer;
        label = 'Pending';
        break;
      case RewardRedemptionStatus.fulfilled:
        bg = theme.colorScheme.primaryContainer;
        fg = theme.colorScheme.onPrimaryContainer;
        label = 'Fulfilled';
        break;
      case RewardRedemptionStatus.cancelled:
        bg = theme.colorScheme.errorContainer;
        fg = theme.colorScheme.onErrorContainer;
        label = 'Cancelled';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.bold),
      ),
    );
  }
}
