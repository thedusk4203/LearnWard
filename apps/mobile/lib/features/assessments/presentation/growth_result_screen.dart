import 'package:flutter/material.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Screen or dialog presenting the deterministic, explainable Growth breakdown.
///
/// Ensures both parents and learners clearly understand: "Why did I get this amount?"
class GrowthResultScreen extends StatelessWidget {
  const GrowthResultScreen({
    super.key,
    required this.growthEvent,
    this.title = 'Verified Result',
  });

  final GrowthEvent growthEvent;
  final String title;

  static Future<void> show(
    BuildContext context, {
    required GrowthEvent growthEvent,
    String title = 'Verified Result',
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: GrowthResultScreen(growthEvent: growthEvent, title: title),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasBaseline = growthEvent.baselineScore != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          key: const Key('close_growth_result_button'),
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header Summary Card
              Card(
                elevation: 0,
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    children: [
                      Text(
                        'Score: ${growthEvent.normalizedScore.toStringAsFixed(2)} / 10',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      if (hasBaseline) ...[
                        Text(
                          'Baseline: ${growthEvent.baselineScore!.toStringAsFixed(2)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (growthEvent.growthDelta != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            growthEvent.growthDelta! >= 0
                                ? 'Improvement: +${growthEvent.growthDelta!.toStringAsFixed(2)}'
                                : 'Improvement: ${growthEvent.growthDelta!.toStringAsFixed(2)}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: growthEvent.growthDelta! >= 0
                                  ? Colors.green.shade700
                                  : theme.colorScheme.error,
                            ),
                          ),
                        ],
                      ] else ...[
                        Text(
                          'Building Baseline (${growthEvent.baselineSampleCount} / 3 comparable tests)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontStyle: FontStyle.italic,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.lg),

              // RP Breakdown Card
              Text(
                'Reward Points (RP)',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Card(
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    children: [
                      _buildBreakdownRow(
                        label: 'Score',
                        amount: '+${growthEvent.scoreRpMinor.formatRp()}',
                        theme: theme,
                      ),
                      if (growthEvent.belowLevelAdjustment) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.shield_outlined, size: 16, color: Colors.amber.shade800),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Below-level activity (25% base RP)',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.amber.shade900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (growthEvent.growthRpMinor.value > 0) ...[
                        const SizedBox(height: AppSpacing.sm),
                        _buildBreakdownRow(
                          label: 'Growth',
                          amount: '+${growthEvent.growthRpMinor.formatRp()}',
                          theme: theme,
                        ),
                      ],
                      if (growthEvent.highPerformerRpMinor.value > 0) ...[
                        const SizedBox(height: AppSpacing.sm),
                        _buildBreakdownRow(
                          label: 'Mastery Maintenance',
                          amount: '+${growthEvent.highPerformerRpMinor.formatRp()}',
                          theme: theme,
                        ),
                      ],
                      if (growthEvent.personalBestRpMinor.value > 0) ...[
                        const SizedBox(height: AppSpacing.sm),
                        _buildBreakdownRow(
                          label: 'Personal Best',
                          amount: '+${growthEvent.personalBestRpMinor.formatRp()}',
                          theme: theme,
                        ),
                      ],
                      if (growthEvent.difficultyRpMinor.value > 0) ...[
                        const SizedBox(height: AppSpacing.sm),
                        _buildBreakdownRow(
                          label: 'Challenge Bonus',
                          amount: '+${growthEvent.difficultyRpMinor.formatRp()}',
                          theme: theme,
                        ),
                      ],
                      const Divider(height: AppSpacing.lg),
                      _buildBreakdownRow(
                        label: 'Total RP',
                        amount: '+${growthEvent.totalRpMinor.formatRp()} RP',
                        isTotal: true,
                        theme: theme,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.lg),

              // Study XP Card
              Text(
                'Study Progression',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Card(
                elevation: 0,
                color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: theme.colorScheme.secondary.withValues(alpha: 0.3),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.bolt, color: theme.colorScheme.secondary),
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            'Study XP',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '+${growthEvent.xpAwarded.value} XP',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: AppSpacing.lg),

              // "Why did I get this amount?" Educational Card
              ExpansionTile(
                initiallyExpanded: true,
                title: Text(
                  'Why did I get this amount?',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildExplanationBullet(
                          title: 'Base Score (+${growthEvent.scoreRpMinor.formatRp()} RP)',
                          description: growthEvent.belowLevelAdjustment
                              ? 'Good practice! This activity is below current level, earning 25% base reward value.'
                              : 'Direct reward proportional to verified test score (${growthEvent.normalizedScore.toStringAsFixed(2)} / 10).',
                          theme: theme,
                        ),
                        if (growthEvent.growthRpMinor.value > 0)
                          _buildExplanationBullet(
                            title: 'Growth Bonus (+${growthEvent.growthRpMinor.formatRp()} RP)',
                            description: 'Score exceeded recent 3-assessment baseline (${growthEvent.baselineScore!.toStringAsFixed(2)}) by +${growthEvent.growthDelta!.toStringAsFixed(2)}.',
                            theme: theme,
                          ),
                        if (growthEvent.highPerformerRpMinor.value > 0)
                          _buildExplanationBullet(
                            title: 'Mastery Maintenance (+${growthEvent.highPerformerRpMinor.formatRp()} RP)',
                            description: 'Maintained strong high performance at or above 8.5.',
                            theme: theme,
                          ),
                        if (growthEvent.personalBestRpMinor.value > 0)
                          _buildExplanationBullet(
                            title: 'Personal Best (+${growthEvent.personalBestRpMinor.formatRp()} RP)',
                            description: 'Established a new personal record in this subject.',
                            theme: theme,
                          ),
                        if (growthEvent.difficultyRpMinor.value > 0)
                          _buildExplanationBullet(
                            title: 'Challenge Bonus (+${growthEvent.difficultyRpMinor.formatRp()} RP)',
                            description: 'Earned bonus for completing a harder challenge assessment.',
                            theme: theme,
                          ),
                        _buildExplanationBullet(
                          title: 'Study XP (+${growthEvent.xpAwarded.value} XP)',
                          description: 'Permanent progression points for cumulative learning effort. Never spent or deducted.',
                          theme: theme,
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: AppSpacing.xl),
              FilledButton(
                key: const Key('done_growth_result_button'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBreakdownRow({
    required String label,
    required String amount,
    required ThemeData theme,
    bool isTotal = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: isTotal
              ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)
              : theme.textTheme.bodyMedium,
        ),
        Text(
          amount,
          style: isTotal
              ? theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                )
              : theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildExplanationBullet({
    required String title,
    required String description,
    required ThemeData theme,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontWeight: FontWeight.bold)),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall,
                children: [
                  TextSpan(
                    text: '$title: ',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(text: description),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
