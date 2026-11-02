import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Screen allowing parents to configure Celebration Wheel parameters:
/// - Enabled / Disabled toggle
/// - Spin Cost (5 to 50 RP)
/// - Daily Spin Cap (1 to 5 spins/day)
/// - Active Pool Inspection & Tier Probabilities breakdown
class ParentWheelSettingsScreen extends ConsumerStatefulWidget {
  const ParentWheelSettingsScreen({super.key});

  @override
  ConsumerState<ParentWheelSettingsScreen> createState() =>
      _ParentWheelSettingsScreenState();
}

class _ParentWheelSettingsScreenState
    extends ConsumerState<ParentWheelSettingsScreen> {
  bool _isLoading = false;
  bool _isSaving = false;
  String? _errorMessage;

  WheelSettings? _settings;
  List<Reward> _wheelRewards = [];

  bool _isEnabled = true;
  int _spinCostMinor = 1000; // 10 RP
  int _dailySpinCap = 3;

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
      final wheelRepo = ref.read(wheelRepositoryProvider);
      final getSettings = GetWheelSettings(wheelRepo);
      final listRewards = ListWheelRewards(wheelRepo);

      final settings = await getSettings(familyId: family.id);
      final rewards = await listRewards(familyId: family.id);

      if (mounted) {
        setState(() {
          _settings = settings;
          _wheelRewards = rewards;
          _isEnabled = settings.isEnabled;
          _spinCostMinor = settings.spinCostMinor;
          _dailySpinCap = settings.dailySpinCap;
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

  Future<void> _save() async {
    final family = ref.read(activeFamilyProvider);
    if (family == null || _settings == null) return;

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final wheelRepo = ref.read(wheelRepositoryProvider);
      final updateSettings = UpdateWheelSettings(wheelRepo);

      final updated = await updateSettings(
        _settings!.copyWith(
          isEnabled: _isEnabled,
          spinCostMinor: _spinCostMinor,
          dailySpinCap: _dailySpinCap,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      if (mounted) {
        setState(() {
          _settings = updated;
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wheel settings saved successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Celebration Wheel Settings')),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_errorMessage != null) ...[
                      Card(
                        color: theme.colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],

                    // Wheel Enabled Switch Card
                    Card(
                      child: SwitchListTile(
                        key: const Key('wheel_enabled_switch'),
                        title: const Text(
                          'Enable Celebration Wheel',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: const Text(
                          'Allow children to spin the wheel using their spendable RP balance.',
                        ),
                        value: _isEnabled,
                        onChanged: (val) => setState(() => _isEnabled = val),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Spin Cost Control Card
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Spin Cost',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            const Text(
                              'Configurable between 5 RP and 50 RP (default: 10 RP).',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    IconButton.filledTonal(
                                      key: const Key(
                                        'wheel_spin_cost_stepper_decrease',
                                      ),
                                      icon: const Icon(Icons.remove),
                                      onPressed: _spinCostMinor > 500
                                          ? () => setState(
                                              () => _spinCostMinor =
                                                  (_spinCostMinor - 100).clamp(
                                                    500,
                                                    5000,
                                                  ),
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: AppSpacing.sm),
                                    Text(
                                      '${(_spinCostMinor / 100).toStringAsFixed(0)} RP',
                                      key: const Key('wheel_spin_cost_text'),
                                      style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: AppSpacing.sm),
                                    IconButton.filledTonal(
                                      key: const Key(
                                        'wheel_spin_cost_stepper_increase',
                                      ),
                                      icon: const Icon(Icons.add),
                                      onPressed: _spinCostMinor < 5000
                                          ? () => setState(
                                              () => _spinCostMinor =
                                                  (_spinCostMinor + 100).clamp(
                                                    500,
                                                    5000,
                                                  ),
                                            )
                                          : null,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Daily Spin Cap Control Card
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Daily Spin Cap per Child',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            const Text(
                              'Limits spins per child per local calendar day (1 to 5, default: 3).',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Row(
                              children: [
                                IconButton.filledTonal(
                                  key: const Key('wheel_daily_cap_decrease'),
                                  icon: const Icon(Icons.remove),
                                  onPressed: _dailySpinCap > 1
                                      ? () => setState(() => _dailySpinCap--)
                                      : null,
                                ),
                                const SizedBox(width: AppSpacing.md),
                                Text(
                                  '$_dailySpinCap spins / day',
                                  key: const Key('wheel_daily_cap_text'),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.md),
                                IconButton.filledTonal(
                                  key: const Key('wheel_daily_cap_increase'),
                                  icon: const Icon(Icons.add),
                                  onPressed: _dailySpinCap < 5
                                      ? () => setState(() => _dailySpinCap++)
                                      : null,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),

                    // Active Pool Guardrail Warning or Inspection Card
                    if (_wheelRewards.length < 3) ...[
                      Card(
                        key: const Key('wheel_pool_warning_banner'),
                        color: theme.colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                color: theme.colorScheme.error,
                                size: 32,
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: Text(
                                  'Celebration Wheel requires at least 3 active eligible rewards in the pool (found: ${_wheelRewards.length}). Wheel spins will be blocked until more rewards are enabled in the Catalog.',
                                  style: TextStyle(
                                    color: theme.colorScheme.onErrorContainer,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],

                    Card(
                      key: const Key('wheel_pool_status_card'),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Active Wheel Pool',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Chip(
                                  label: Text('${_wheelRewards.length} items'),
                                  backgroundColor: _wheelRewards.length >= 3
                                      ? Colors.green.withValues(alpha: 0.15)
                                      : Colors.amber.withValues(alpha: 0.2),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            _buildTierProbabilitySummary(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),

                    // Save Button
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const Key('wheel_settings_save_button'),
                        icon: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check),
                        label: Text(_isSaving ? 'Saving...' : 'Save Settings'),
                        onPressed: _isSaving ? null : _save,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildTierProbabilitySummary() {
    if (_wheelRewards.isEmpty) {
      return const Text(
        'No rewards currently enabled for the Celebration Wheel.',
        style: TextStyle(color: Colors.grey),
      );
    }

    final totalWeight = _wheelRewards.fold<int>(
      0,
      (sum, r) => sum + (r.wheelTier?.relativeWeight ?? 60),
    );

    final commonCount = _wheelRewards
        .where((r) => r.wheelTier == WheelTier.common)
        .length;
    final specialCount = _wheelRewards
        .where((r) => r.wheelTier == WheelTier.special)
        .length;
    final rareCount = _wheelRewards
        .where((r) => r.wheelTier == WheelTier.rare)
        .length;

    return Column(
      children: [
        _buildTierRow(
          'Common (weight 60)',
          commonCount,
          60,
          totalWeight,
          Colors.blue,
        ),
        const SizedBox(height: AppSpacing.xs),
        _buildTierRow(
          'Special (weight 30)',
          specialCount,
          30,
          totalWeight,
          Colors.purple,
        ),
        const SizedBox(height: AppSpacing.xs),
        _buildTierRow(
          'Rare (weight 10)',
          rareCount,
          10,
          totalWeight,
          Colors.amber,
        ),
      ],
    );
  }

  Widget _buildTierRow(
    String label,
    int count,
    int weightPerItem,
    int totalWeight,
    Color color,
  ) {
    final tierTotalWeight = count * weightPerItem;
    final pct = totalWeight > 0
        ? ((tierTotalWeight / totalWeight) * 100.0).toStringAsFixed(1)
        : '0.0';

    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            '$label: $count items',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        Text(
          '$pct% chance',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}
