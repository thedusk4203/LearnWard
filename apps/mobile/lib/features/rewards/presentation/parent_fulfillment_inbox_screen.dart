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
  final ScrollController _recoveryScrollController = ScrollController();
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

  @override
  void dispose() {
    _recoveryScrollController.dispose();
    super.dispose();
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
        _pendingUpdates.any(
          (p) => p.redemptionId == redemption.id.value && p.isCommandUnresolved,
        )) {
      return;
    }

    setState(() => _inFlightRedemptionIds.add(redemption.id.value));
    try {
      final commandStore = ref.read(pendingRewardCommandStoreProvider);
      final coordinator = ref.read(recoveryCoordinatorProvider);
      final fulfillUseCase = FulfillRewardRedemption(
        ref.read(rewardRepositoryProvider),
        commandStore,
        coordinator: coordinator,
      );
      final result = await fulfillUseCase.executeResult(
        familyId: family.id,
        redemptionId: redemption.id,
        childId: redemption.childId,
        trigger: CommandExecutionTrigger.foreground,
      );

      if (mounted) {
        if (result is CommandCommittedResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Delivered "${redemption.rewardTitle}" to ${_childNames[redemption.childId.value] ?? 'child'}!',
              ),
            ),
          );
        } else if (result is CommandScheduledResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "We're checking whether the delivery was saved. Tap retry if needed.",
              ),
            ),
          );
        } else if (result is CommandPendingOriginalActorResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Delivery pending confirmation by original parent.',
              ),
            ),
          );
        } else if (result is CommandQuarantinedResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Delivery requires review: ${result.reason}'),
            ),
          );
        } else if (result is CommandTerminalRejectionResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to fulfill reward: ${result.errorMessage}'),
            ),
          );
        } else if (result is CommandAuthUnavailableResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Authentication unavailable: ${result.reason}'),
            ),
          );
        } else if (result is CommandFamilyMismatchResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Family mismatch during fulfillment execution.'),
            ),
          );
        } else if (result is CommandAlreadyInFlightResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Fulfillment is already in progress.'),
            ),
          );
        }
      }
      await _loadData();
    } catch (e) {
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Fulfillment encountered an error: ${e.toString()}'),
          ),
        );
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
        _pendingUpdates.any(
          (p) => p.redemptionId == redemption.id.value && p.isCommandUnresolved,
        )) {
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

    if (confirmed == true && reasonController.text.trim().length >= 2) {
      setState(() => _inFlightRedemptionIds.add(redemption.id.value));
      try {
        final commandStore = ref.read(pendingRewardCommandStoreProvider);
        final coordinator = ref.read(recoveryCoordinatorProvider);
        final cancelUseCase = CancelRewardRedemption(
          ref.read(rewardRepositoryProvider),
          commandStore,
          coordinator: coordinator,
        );
        final result = await cancelUseCase.executeResult(
          familyId: family.id,
          redemptionId: redemption.id,
          childId: redemption.childId,
          cancellationReason: reasonController.text.trim(),
          trigger: CommandExecutionTrigger.foreground,
        );

        if (mounted) {
          if (result is CommandCommittedResult) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Cancelled. ${redemption.rpCost.toStringAsFixed(0)} RP refunded to balance.',
                ),
              ),
            );
          } else if (result is CommandScheduledResult) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  "We're checking whether the cancellation was processed. Tap retry if needed.",
                ),
              ),
            );
          } else if (result is CommandPendingOriginalActorResult) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Cancellation pending confirmation by original parent.',
                ),
              ),
            );
          } else if (result is CommandQuarantinedResult) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cancellation requires review: ${result.reason}'),
              ),
            );
          } else if (result is CommandTerminalRejectionResult) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Failed to cancel reward: ${result.errorMessage}',
                ),
              ),
            );
          } else if (result is CommandAuthUnavailableResult) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Authentication unavailable: ${result.reason}'),
              ),
            );
          } else if (result is CommandFamilyMismatchResult) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Family mismatch during cancellation execution.'),
              ),
            );
          } else if (result is CommandAlreadyInFlightResult) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Cancellation is already in progress.'),
              ),
            );
          }
        }
        await _loadData();
      } catch (e) {
        await _loadData();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Cancellation encountered an error: ${e.toString()}',
              ),
            ),
          );
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

    final currentUserId = ref.read(currentUserIdProvider);
    final hasValidActorId =
        pending.actorUserId != null && pending.actorUserId!.trim().isNotEmpty;
    final isOriginalActorMatch =
        currentUserId != null &&
        currentUserId.trim().isNotEmpty &&
        hasValidActorId &&
        currentUserId == pending.actorUserId;

    final isQuarantined =
        pending.recoveryState == CommandRecoveryState.quarantinedUnknownOutcome;
    final isTerminal =
        pending.recoveryState == CommandRecoveryState.terminalError;
    final isLegacy =
        pending.dispatchState == CommandDispatchState.unknownLegacy;

    final now = DateTime.now().toUtc();
    final isScheduledInFuture =
        pending.nextAttemptAt != null &&
        pending.nextAttemptAt!.toUtc().isAfter(now);

    // Defense-in-depth: Never execute retry for ineligible commands (R29-06)
    if (!isOriginalActorMatch ||
        isQuarantined ||
        isTerminal ||
        isLegacy ||
        isScheduledInFuture) {
      return;
    }

    if (pending.operation == RewardCommandOperation.cancelReward &&
        (pending.cancellationReason == null ||
            pending.cancellationReason!.trim().length < 2)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cannot retry cancellation: missing cancellation reason.',
            ),
          ),
        );
      }
      return;
    }

    final ChildId childId;
    if (pending.childId != null && pending.childId!.isNotEmpty) {
      childId = ChildId(pending.childId!);
    } else {
      final matching = _redemptions
          .where((r) => r.id.value == pending.redemptionId)
          .firstOrNull;
      if (matching != null) {
        childId = matching.childId;
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Cannot resolve pending update: child identity unknown.',
              ),
            ),
          );
        }
        return;
      }
    }

    final inFlightKey = pending.redemptionId ?? pending.commandId;
    if (_inFlightRedemptionIds.contains(inFlightKey)) {
      return;
    }

    setState(() => _inFlightRedemptionIds.add(inFlightKey));
    try {
      final commandStore = ref.read(pendingRewardCommandStoreProvider);
      final coordinator = ref.read(recoveryCoordinatorProvider);
      final CommandExecutionResult result;

      if (pending.operation == RewardCommandOperation.fulfillReward) {
        final fulfillUseCase = FulfillRewardRedemption(
          ref.read(rewardRepositoryProvider),
          commandStore,
          coordinator: coordinator,
        );
        result = await fulfillUseCase.executeResult(
          commandId: pending.commandId,
          familyId: family.id,
          redemptionId: RewardRedemptionId(pending.redemptionId!),
          childId: childId,
          trigger: CommandExecutionTrigger.foregroundRetry,
        );
      } else {
        final cancelUseCase = CancelRewardRedemption(
          ref.read(rewardRepositoryProvider),
          commandStore,
          coordinator: coordinator,
        );
        result = await cancelUseCase.executeResult(
          commandId: pending.commandId,
          familyId: family.id,
          redemptionId: RewardRedemptionId(pending.redemptionId!),
          childId: childId,
          cancellationReason: pending.cancellationReason!,
          trigger: CommandExecutionTrigger.foregroundRetry,
        );
      }

      if (mounted) {
        if (result is CommandCommittedResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Pending reward update verified!')),
          );
        } else if (result is CommandScheduledResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                "We're checking whether the update was processed. Tap retry to verify.",
              ),
            ),
          );
        } else if (result is CommandPendingOriginalActorResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Pending confirmation by original parent.'),
            ),
          );
        } else if (result is CommandQuarantinedResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Pending update requires manual review: ${result.reason}',
              ),
            ),
          );
        } else if (result is CommandTerminalRejectionResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Update failed: ${result.errorMessage}')),
          );
        } else if (result is CommandAuthUnavailableResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Authentication unavailable: ${result.reason}'),
            ),
          );
        } else if (result is CommandFamilyMismatchResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Family mismatch during pending update verification.',
              ),
            ),
          );
        } else if (result is CommandAlreadyInFlightResult) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Update is already being processed.')),
          );
        }
      }
      await _loadData();
    } catch (e) {
      await _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _inFlightRedemptionIds.remove(inFlightKey));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unresolvedUpdates = _pendingUpdates
        .where((p) => p.isCommandUnresolved)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Fulfillment Inbox')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxRecoveryHeight = (constraints.maxHeight * 0.40).clamp(
              0.0,
              220.0,
            );

            return Column(
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
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
                ),
                const Divider(height: 1),

                // Pending Update Recovery Banners (R29-05: Bounded, scrollable region)
                if (unresolvedUpdates.isNotEmpty)
                  KeyedSubtree(
                    key: const Key('pending_fulfillment_recovery_banner'),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: maxRecoveryHeight),
                      child: Scrollbar(
                        controller: _recoveryScrollController,
                        child: ListView.builder(
                          key: const Key(
                            'pending_recovery_banners_scroll_view',
                          ),
                          controller: _recoveryScrollController,
                          shrinkWrap: true,
                          itemCount: unresolvedUpdates.length,
                          itemBuilder: (context, index) {
                            final pending = unresolvedUpdates[index];
                            return _buildRecoveryBanner(theme, pending);
                          },
                        ),
                      ),
                    ),
                  ),

                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadData,
                    child: _buildList(theme),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildRecoveryBanner(ThemeData theme, PendingRewardCommand pending) {
    final currentUserId = ref.read(currentUserIdProvider);
    final hasValidActorId =
        pending.actorUserId != null && pending.actorUserId!.trim().isNotEmpty;
    final isOriginalActorMatch =
        currentUserId != null &&
        currentUserId.trim().isNotEmpty &&
        hasValidActorId &&
        currentUserId == pending.actorUserId;

    final inFlightKey = pending.redemptionId ?? pending.commandId;
    final isInFlight = _inFlightRedemptionIds.contains(inFlightKey);

    final isQuarantined =
        pending.recoveryState == CommandRecoveryState.quarantinedUnknownOutcome;
    final isTerminal =
        pending.recoveryState == CommandRecoveryState.terminalError;
    final isLegacy =
        pending.dispatchState == CommandDispatchState.unknownLegacy;

    final now = DateTime.now().toUtc();
    final isScheduledInFuture =
        pending.nextAttemptAt != null &&
        pending.nextAttemptAt!.toUtc().isAfter(now);

    final IconData icon;
    final String message;
    final bool canRetry;

    if (isQuarantined || isTerminal || isLegacy || !hasValidActorId) {
      icon = Icons.warning_amber_rounded;
      message = 'Pending update requires manual review.';
      canRetry = false;
    } else if (!isOriginalActorMatch) {
      icon = Icons.pause_circle_outline;
      message = 'Pending confirmation by original parent.';
      canRetry = false;
    } else if (pending.recoveryState ==
        CommandRecoveryState.pendingOriginalActor) {
      icon = Icons.pause_circle_outline;
      message = 'Pending confirmation by original parent.';
      canRetry = !isInFlight;
    } else if (isScheduledInFuture) {
      icon = Icons.schedule;
      message = 'Automatic retry scheduled. Waiting before next attempt.';
      canRetry = false;
    } else {
      icon = Icons.hourglass_top;
      message = "We're checking whether a reward update was completed.";
      canRetry = !isInFlight;
    }

    return Container(
      key: Key('pending_fulfillment_recovery_banner_${pending.commandId}'),
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
          Icon(icon, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (canRetry)
            KeyedSubtree(
              key: Key('retry_pending_fulfillment_button_${pending.commandId}'),
              child: FilledButton.tonal(
                key: const Key('retry_pending_fulfillment_button'),
                onPressed: isInFlight
                    ? null
                    : () => _resolvePendingUpdate(pending),
                child: const Text('Retry'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: SingleChildScrollView(
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
        child: SingleChildScrollView(
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
    final matchingPending = _pendingUpdates
        .where((p) => p.redemptionId == item.id.value)
        .firstOrNull;
    final isPendingUpdate =
        matchingPending != null && matchingPending.isCommandUnresolved;
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
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    OutlinedButton(
                      key: Key('cancel_button_${item.id.value}'),
                      onPressed: isInFlight || isPendingUpdate
                          ? null
                          : () => _cancelAndRefund(item),
                      child: const Text('Cancel & Refund'),
                    ),
                    FilledButton(
                      key: Key('fulfill_button_${item.id.value}'),
                      onPressed: isInFlight || isPendingUpdate
                          ? null
                          : () => _fulfill(item),
                      child: Text(
                        isInFlight
                            ? 'Checking...'
                            : isPendingUpdate
                            ? 'Pending...'
                            : 'Mark as Delivered',
                      ),
                    ),
                  ],
                ),
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
