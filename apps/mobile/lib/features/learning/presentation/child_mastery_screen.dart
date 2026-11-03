import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Screen presenting learning mastery projections, bands, and confidence to a child or parent.
class ChildMasteryScreen extends ConsumerStatefulWidget {
  const ChildMasteryScreen({
    super.key,
    required this.childId,
    this.childDisplayName = 'Learner',
  });

  final ChildId childId;
  final String childDisplayName;

  @override
  ConsumerState<ChildMasteryScreen> createState() => _ChildMasteryScreenState();
}

class _ChildMasteryScreenState extends ConsumerState<ChildMasteryScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  List<ChildMasteryProjection> _projections = [];

  @override
  void initState() {
    super.initState();
    _loadMastery();
  }

  Future<void> _loadMastery() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(learningRepositoryProvider);
      final list = await repo.getChildMastery(childId: widget.childId);
      if (mounted) {
        setState(() {
          _projections = list;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.childDisplayName}\'s Mastery'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadMastery,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                'Failed to load mastery',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadMastery,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_projections.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.school_outlined,
                size: 64,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.5,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'No Verified Learning Yet',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'When school results are added and verified, mastery and confidence will appear here.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMastery,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _projections.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final item = _projections[index];
          return _buildMasteryCard(context, item, theme);
        },
      ),
    );
  }

  Widget _buildMasteryCard(
    BuildContext context,
    ChildMasteryProjection item,
    ThemeData theme,
  ) {
    final (bandLabel, bandColor, bandBgColor) = switch (item.masteryBand) {
      MasteryBand.mastered => (
        'Mastered',
        Colors.green.shade800,
        Colors.green.shade100,
      ),
      MasteryBand.masteryCandidate => (
        'Mastery Candidate',
        Colors.teal.shade800,
        Colors.teal.shade100,
      ),
      MasteryBand.secure => (
        'Secure',
        Colors.blue.shade800,
        Colors.blue.shade100,
      ),
      MasteryBand.developing => (
        'Developing',
        Colors.orange.shade900,
        Colors.orange.shade100,
      ),
      MasteryBand.emerging => (
        'Emerging',
        Colors.purple.shade800,
        Colors.purple.shade100,
      ),
      MasteryBand.noData => (
        'No Data',
        Colors.grey.shade700,
        Colors.grey.shade200,
      ),
    };

    final (confLabel, confIcon) = switch (item.confidenceBand) {
      ConfidenceBand.high => ('High Confidence', Icons.verified),
      ConfidenceBand.medium => ('Medium Confidence', Icons.trending_up),
      ConfidenceBand.low => ('Low Confidence', Icons.help_outline),
    };

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.nodeTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: bandBgColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    bandLabel,
                    style: TextStyle(
                      color: bandColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${item.masteryScore.toStringAsFixed(1)}%',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: bandColor,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (item.masteryScore / 100.0).clamp(0.0, 1.0),
                      minHeight: 8,
                      backgroundColor:
                          theme.colorScheme.surfaceContainerHighest,
                      color: bandColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  confIcon,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  confLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  '${item.distinctAssessmentCount} verified ${item.distinctAssessmentCount == 1 ? 'assessment' : 'assessments'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
