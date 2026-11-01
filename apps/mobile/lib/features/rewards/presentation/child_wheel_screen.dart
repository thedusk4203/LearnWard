import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Screen displaying the Celebration Wheel experience for children.
///
/// Fully server-authoritative: the server determines the outcome, debit, and audit
/// snapshot before client-side celebration animation. No casino graphics or loss states.
class ChildWheelScreen extends ConsumerStatefulWidget {
  const ChildWheelScreen({super.key});

  @override
  ConsumerState<ChildWheelScreen> createState() => _ChildWheelScreenState();
}

class _ChildWheelScreenState extends ConsumerState<ChildWheelScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = false;
  bool _isSpinning = false;
  String? _errorMessage;

  WheelSettings? _settings;
  List<Reward> _eligibleRewards = [];
  ChildBalance? _childBalance;
  int _todaySpinCount = 0;
  List<WheelSpin> _spinHistory = [];

  WheelSpinResult? _lastSpinResult;

  late AnimationController _animController;
  double _currentRotation = 0.0;
  double _targetRotation = 0.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3500),
    );

    _animController.addListener(() {
      setState(() {
        _currentRotation = _animController.value * _targetRotation;
      });
    });

    _animController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _isSpinning = false;
        });
        if (_lastSpinResult != null) {
          _showWinDialog(_lastSpinResult!);
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _loadData());
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final wheelRepo = ref.read(wheelRepositoryProvider);
      final growthRepo = ref.read(growthRepositoryProvider);

      final getSettings = GetWheelSettings(wheelRepo);
      final listRewards = ListWheelRewards(wheelRepo);
      final listSpins = ListWheelSpins(wheelRepo);
      final getBalance = GetChildBalance(growthRepo);

      final settings = await getSettings(familyId: activeChild.familyId);
      final rewards = await listRewards(
        familyId: activeChild.familyId,
        childId: activeChild.id,
      );
      final spins = await listSpins(
        familyId: activeChild.familyId,
        childId: activeChild.id,
        limit: 10,
      );
      final balance = await getBalance(activeChild.id);
      final todayCount = await wheelRepo.getTodaySpinCount(
        familyId: activeChild.familyId,
        childId: activeChild.id,
      );

      if (mounted) {
        setState(() {
          _settings = settings;
          _eligibleRewards = rewards;
          _spinHistory = spins;
          _childBalance = balance;
          _todaySpinCount = todayCount;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _confirmAndSpin() async {
    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null || _settings == null) return;

    final costRp = _settings!.spinCostRp;

    // 1. Mandatory Confirmation Dialog before spending RP
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Spin the Celebration Wheel?'),
        content: Text(
          'Spinning costs ${costRp.toStringAsFixed(0)} RP (\$${costRp.toStringAsFixed(2)}). '
          'Are you sure you want to spin?',
        ),
        actions: [
          TextButton(
            key: const Key('cancel_spin_button'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_spin_button'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Confirm & Spin (${costRp.toStringAsFixed(0)} RP)'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isSpinning = true;
      _errorMessage = null;
    });

    try {
      final wheelRepo = ref.read(wheelRepositoryProvider);
      final commandStore = ref.read(pendingRewardCommandStoreProvider);
      final spinUseCase = SpinRewardWheel(wheelRepo, commandStore);

      // 2. Server-Authoritative RPC invocation with durable idempotency
      final result = await spinUseCase(
        familyId: activeChild.familyId,
        childId: activeChild.id,
      );

      _lastSpinResult = result;

      // 3. Compute target rotation so the wheel lands on the server-decided winner
      _calculateTargetRotation(result.rewardId);

      _animController.reset();
      _animController.forward();

      // Refresh balance and history in background
      unawaited(_loadDataSilently());
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSpinning = false;
          _errorMessage = _friendlyErrorMessage(e.toString());
        });
      }
    }
  }

  void _calculateTargetRotation(RewardId winningRewardId) {
    if (_eligibleRewards.isEmpty) return;

    // Sort rewards deterministically (matches server reward_id_asc)
    final sorted = List<Reward>.from(_eligibleRewards)
      ..sort((a, b) => a.id.value.compareTo(b.id.value));

    final totalWeight = sorted.fold<int>(
      0,
      (sum, r) => sum + (r.wheelTier?.relativeWeight ?? 60),
    );

    int cumulative = 0;
    double winningCenterAngle = 0.0;

    for (final r in sorted) {
      final weight = r.wheelTier?.relativeWeight ?? 60;
      final startAngle = (cumulative / totalWeight) * 2 * pi;
      final endAngle = ((cumulative + weight) / totalWeight) * 2 * pi;
      if (r.id == winningRewardId) {
        winningCenterAngle = (startAngle + endAngle) / 2.0;
        break;
      }
      cumulative += weight;
    }

    // Pointer is at the top (3*pi/2 or -pi/2). Spin 5 full turns + offset to winner
    const fullTurns = 5 * 2 * pi;
    final landingAngle = (1.5 * pi) - winningCenterAngle;
    _targetRotation = fullTurns + landingAngle;
  }

  Future<void> _loadDataSilently() async {
    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) return;
    try {
      final wheelRepo = ref.read(wheelRepositoryProvider);
      final growthRepo = ref.read(growthRepositoryProvider);
      final balance = await GetChildBalance(growthRepo)(activeChild.id);
      final spins = await ListWheelSpins(wheelRepo)(
        familyId: activeChild.familyId,
        childId: activeChild.id,
        limit: 10,
      );
      final todayCount = await wheelRepo.getTodaySpinCount(
        familyId: activeChild.familyId,
        childId: activeChild.id,
      );

      if (mounted) {
        setState(() {
          _childBalance = balance;
          _spinHistory = spins;
          _todaySpinCount = todayCount;
        });
      }
    } catch (_) {}
  }

  void _showWinDialog(WheelSpinResult result) {
    final theme = Theme.of(context);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.celebration, color: Colors.amber, size: 28),
            const SizedBox(width: AppSpacing.xs),
            const Expanded(child: Text('You Won a Prize!')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _tierColor(result.wheelTier).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.star,
                size: 36,
                color: _tierColor(result.wheelTier),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              result.rewardTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.xs),
            Chip(
              label: Text(
                '${result.wheelTier.displayName} Prize',
                style: TextStyle(
                  color: _tierColor(result.wheelTier),
                  fontWeight: FontWeight.bold,
                ),
              ),
              backgroundColor: _tierColor(result.wheelTier)
                  .withValues(alpha: 0.1),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Your prize is saved in My Claims and waiting for parents to fulfill.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
            ),
            const Divider(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('New RP Balance:'),
                Text(
                  '${result.newBalanceRp.toStringAsFixed(0)} RP',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          FilledButton(
            key: const Key('claim_dialog_close_button'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Awesome!'),
          ),
        ],
      ),
    );
  }

  Color _tierColor(WheelTier tier) {
    switch (tier) {
      case WheelTier.common:
        return Colors.teal;
      case WheelTier.special:
        return Colors.purple;
      case WheelTier.rare:
        return Colors.amber.shade800;
    }
  }

  String _friendlyErrorMessage(String error) {
    if (error.contains('LW201') || error.contains('Insufficient RP')) {
      return 'Not enough RP to spin! Complete more study sessions to earn RP.';
    }
    if (error.contains('LW202') || error.contains('Daily spin limit')) {
      return 'Daily spin limit reached! Come back tomorrow for more spins.';
    }
    if (error.contains('LW203') || error.contains('at least 3')) {
      return 'The Celebration Wheel is currently resting (needs at least 3 prizes).';
    }
    if (error.contains('LW206') || error.contains('disabled')) {
      return 'The Celebration Wheel is currently turned off by your parents.';
    }
    return 'Could not spin the wheel: $error';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balanceMinor = _childBalance?.rpBalanceMinor.value ?? 0;
    final balanceRp = balanceMinor / 100.0;
    final costMinor = _settings?.spinCostMinor ?? 1000;
    final costRp = costMinor / 100.0;
    final dailyCap = _settings?.dailySpinCap ?? 3;
    final isEnabled = _settings?.isEnabled ?? true;

    final hasEnoughBalance = balanceMinor >= costMinor;
    final hasSpinsRemaining = _todaySpinCount < dailyCap;
    final hasEnoughPrizes = _eligibleRewards.length >= 3;

    final canSpin =
        isEnabled &&
        hasEnoughBalance &&
        hasSpinsRemaining &&
        hasEnoughPrizes &&
        !_isSpinning;

    return Scaffold(
      appBar: AppBar(title: const Text('Celebration Wheel')),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  children: [
                    // Balance & Daily Quota Card
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'My RP Balance',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                                Text(
                                  '${balanceRp.toStringAsFixed(0)} RP',
                                  key: const Key('child_wheel_balance_text'),
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text(
                                  'Daily Spins',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                                Text(
                                  '$_todaySpinCount / $dailyCap spins',
                                  key: const Key('child_wheel_daily_cap_text'),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: hasSpinsRemaining
                                        ? Colors.green
                                        : Colors.amber.shade800,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    if (_errorMessage != null) ...[
                      Card(
                        color: theme.colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(
                                    color: theme.colorScheme.onErrorContainer,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                    ],

                    // Wheel Visualizer
                    SizedBox(
                      height: 280,
                      width: 280,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Transform.rotate(
                            angle: _currentRotation,
                            child: CustomPaint(
                              size: const Size(260, 260),
                              painter: _WheelPainter(rewards: _eligibleRewards),
                            ),
                          ),
                          // Pointer at the top
                          Positioned(
                            top: 0,
                            child: Icon(
                              Icons.arrow_drop_down,
                              size: 40,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          // Center Hub
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.15),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                            child: Icon(
                              Icons.toll,
                              color: theme.colorScheme.primary,
                              size: 28,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Spin Button
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: FilledButton.icon(
                        key: const Key('spin_wheel_button'),
                        icon: _isSpinning
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.play_arrow),
                        label: Text(
                          _isSpinning
                              ? 'Spinning...'
                              : !isEnabled
                              ? 'Wheel is Resting'
                              : !hasEnoughPrizes
                              ? 'Wheel is Resting (< 3 Prizes)'
                              : !hasSpinsRemaining
                              ? 'Daily Limit Reached ($dailyCap/$dailyCap)'
                              : !hasEnoughBalance
                              ? 'Need ${costRp.toStringAsFixed(0)} RP to Spin'
                              : 'Spin Wheel (${costRp.toStringAsFixed(0)} RP)',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onPressed: canSpin ? _confirmAndSpin : null,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),

                    // Recent Spins History Section
                    if (_spinHistory.isNotEmpty) ...[
                      Row(
                        children: [
                          const Icon(Icons.history, size: 20),
                          const SizedBox(width: AppSpacing.xs),
                          const Text(
                            'Recent Wins',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      ..._spinHistory.map((spin) {
                        return Card(
                          child: ListTile(
                            leading: Icon(
                              Icons.star,
                              color: _tierColor(
                                WheelTier.fromString(
                                  spin.selectionSnapshot.orderedPool
                                      .firstWhere(
                                        (p) => p.rewardId == spin.rewardId,
                                        orElse: () => spin
                                            .selectionSnapshot
                                            .orderedPool
                                            .first,
                                      )
                                      .tier
                                      .value,
                                ),
                              ),
                            ),
                            title: Text(
                              spin.selectionSnapshot.orderedPool
                                  .firstWhere(
                                    (p) => p.rewardId == spin.rewardId,
                                    orElse: () => spin
                                        .selectionSnapshot
                                        .orderedPool
                                        .first,
                                  )
                                  .title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              '${spin.spinCostRp.toStringAsFixed(0)} RP • ${_formatDate(spin.createdAt)}',
                            ),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// Custom painter rendering proportional wheel wedges according to relative weights.
class _WheelPainter extends CustomPainter {
  _WheelPainter({required this.rewards});

  final List<Reward> rewards;

  @override
  void paint(Canvas canvas, Size size) {
    if (rewards.isEmpty) return;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final sorted = List<Reward>.from(rewards)
      ..sort((a, b) => a.id.value.compareTo(b.id.value));

    final totalWeight = sorted.fold<int>(
      0,
      (sum, r) => sum + (r.wheelTier?.relativeWeight ?? 60),
    );

    double currentAngle = 0.0;
    final paint = Paint()..style = PaintingStyle.fill;

    final colors = [
      Colors.teal.shade400,
      Colors.purple.shade400,
      Colors.amber.shade600,
      Colors.cyan.shade600,
      Colors.indigo.shade400,
      Colors.deepOrange.shade400,
    ];

    for (int i = 0; i < sorted.length; i++) {
      final reward = sorted[i];
      final weight = reward.wheelTier?.relativeWeight ?? 60;
      final sweepAngle = (weight / totalWeight) * 2 * pi;

      paint.color = colors[i % colors.length];

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        currentAngle,
        sweepAngle,
        true,
        paint,
      );

      // Wedge boundary line
      final linePaint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        currentAngle,
        sweepAngle,
        true,
        linePaint,
      );

      currentAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _WheelPainter oldDelegate) => true;
}
