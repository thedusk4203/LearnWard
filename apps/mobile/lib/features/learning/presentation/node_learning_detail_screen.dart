import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Screen presenting the Phase 5.2 detailed learning state for a single active-catalog node.
///
/// Displays Mastery band & score (or "Not yet observed"), Confidence band & units,
/// Freshness badge, gentle Recovery notice, Recommended difficulty chip (hidden when null),
/// Latest verified evidence summary, Prerequisite checklist, and Outgoing Dependents list.
class NodeLearningDetailScreen extends ConsumerStatefulWidget {
  const NodeLearningDetailScreen({
    super.key,
    required this.childId,
    required this.learningNodeId,
    this.childDisplayName = 'Learner',
  });

  final ChildId childId;
  final String learningNodeId;
  final String childDisplayName;

  @override
  ConsumerState<NodeLearningDetailScreen> createState() =>
      _NodeLearningDetailScreenState();
}

class _NodeLearningDetailScreenState
    extends ConsumerState<NodeLearningDetailScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  LearningNodeState? _nodeState;

  @override
  void initState() {
    super.initState();
    _loadNodeState();
  }

  Future<void> _loadNodeState() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(learningRepositoryProvider);
      final useCase = GetNodeLearningState(repo);
      final state = await useCase(
        childId: widget.childId,
        learningNodeId: widget.learningNodeId,
      );
      if (mounted) {
        setState(() {
          _nodeState = state;
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
    final title = _nodeState?.node.title ?? 'Skill Details';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            key: const Key('node_detail_refresh_button'),
            icon: const Icon(Icons.refresh),
            onPressed: _loadNodeState,
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

    if (_errorMessage != null || _nodeState == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                'Failed to load learning node details',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loadNodeState,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    final detail = _nodeState!;
    final node = detail.node;
    final state = detail.state;
    final prereq = detail.prerequisiteState;

    return RefreshIndicator(
      onRefresh: _loadNodeState,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildHeaderCard(theme, node, state),
          const SizedBox(height: 12),
          if (state.recoverySignal == RecoverySignal.reviewSuggested) ...[
            _buildRecoveryBanner(theme, state),
            const SizedBox(height: 12),
          ],
          _buildMasteryAndConfidenceCard(theme, state),
          const SizedBox(height: 12),
          if (detail.latestEvidence != null) ...[
            _buildLatestEvidenceCard(theme, detail.latestEvidence!),
            const SizedBox(height: 12),
          ],
          if (prereq.applicable) ...[
            _buildPrerequisitesCard(theme, prereq),
            const SizedBox(height: 12),
            _buildDependentsCard(theme, prereq),
          ],
        ],
      ),
    );
  }

  Widget _buildHeaderCard(
    ThemeData theme,
    LearningNodeSummary node,
    LearningNodeStateDetail state,
  ) {
    final breadcrumbParts = <String>[
      node.subjectKey.toUpperCase(),
      if (node.parentDomainTitle != null) node.parentDomainTitle!,
      if (node.parentTopicTitle != null) node.parentTopicTitle!,
    ];

    final gradeText = (node.gradeMin != null || node.gradeMax != null)
        ? 'Grades ${node.gradeMin ?? 1}–${node.gradeMax ?? 12}'
        : 'All Grades';

    return Card(
      key: const Key('node_detail_header_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              breadcrumbParts.join(' • '),
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              node.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text('Type: ${node.nodeType.value.toUpperCase()}'),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  label: Text(gradeText),
                  visualDensity: VisualDensity.compact,
                ),
                _buildFreshnessChip(state.freshness),
                if (state.recommendedDifficulty != null)
                  _buildDifficultyChip(state.recommendedDifficulty!),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecoveryBanner(ThemeData theme, LearningNodeStateDetail state) {
    return Card(
      key: const Key('node_detail_recovery_banner'),
      elevation: 0,
      color: Colors.amber.shade50,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.amber.shade400),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.lightbulb_outline, color: Colors.amber.shade900),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Review suggested',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: Colors.amber.shade900,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Recent errors suggest a short review at a comfortable step-down pace.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.amber.shade900,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMasteryAndConfidenceCard(
    ThemeData theme,
    LearningNodeStateDetail state,
  ) {
    if (!state.isObserved) {
      return Card(
        key: const Key('node_detail_unobserved_card'),
        elevation: 0,
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
                  Icon(
                    Icons.explore_outlined,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Not yet observed',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'No verified assessment evidence has been recorded for this node yet. '
                'Unseen skills are treated as unknown rather than 0%.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final band = state.masteryBand ?? MasteryBand.emerging;
    final (bandLabel, bandColor, bandBgColor) = switch (band) {
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

    final confLabel = switch (state.confidenceBand) {
      ConfidenceBand.high => 'High Confidence',
      ConfidenceBand.medium => 'Medium Confidence',
      ConfidenceBand.low || null => 'Low Confidence',
    };

    final score = state.masteryScore ?? 0.0;

    return Card(
      key: const Key('node_detail_mastery_card'),
      elevation: 0,
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Mastery & Confidence',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Container(
                  key: const Key('node_detail_mastery_band_badge'),
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
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '${score.toStringAsFixed(1)}%',
                  key: const Key('node_detail_mastery_score'),
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
                      value: (score / 100.0).clamp(0.0, 1.0),
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
            Text(
              '$confLabel (${state.confidenceUnits.toStringAsFixed(2)} units • '
              '${state.distinctRecentVleCount} recent verified ${state.distinctRecentVleCount == 1 ? 'assessment' : 'assessments'} in 60d)',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (state.daysSinceLastEvidence != null) ...[
              const SizedBox(height: 4),
              Text(
                'Last practiced ${state.daysSinceLastEvidence} ${state.daysSinceLastEvidence == 1 ? 'day' : 'days'} ago '
                '(${state.distinctAssessmentCount} total verified ${state.distinctAssessmentCount == 1 ? 'assessment' : 'assessments'})',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLatestEvidenceCard(
    ThemeData theme,
    LatestLearningEvidenceSummary latest,
  ) {
    final sourceLabel = switch (latest.scoreSource) {
      ScoreSource.itemGroup => 'Item Group',
      ScoreSource.componentScore => 'Component Score',
      ScoreSource.assessmentTotal => 'Assessment Total',
    };

    return Card(
      key: const Key('node_detail_latest_evidence_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Latest Verified Evidence',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Performance: ${latest.performancePct.toStringAsFixed(1)}% • Source: $sourceLabel',
              style: theme.textTheme.bodyMedium,
            ),
            if (latest.itemCount != null && latest.correctCount != null) ...[
              const SizedBox(height: 4),
              Text(
                'Questions: ${latest.correctCount} / ${latest.itemCount} correct',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPrerequisitesCard(
    ThemeData theme,
    NodePrerequisiteState prereq,
  ) {
    return Card(
      key: const Key('node_detail_prerequisites_card'),
      elevation: 0,
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
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Skill Prerequisites (${prereq.attainedPrerequisiteCount}/${prereq.prerequisiteCount})',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Icon(
                  prereq.isSatisfied
                      ? Icons.check_circle
                      : Icons.lock_clock_outlined,
                  size: 18,
                  color: prereq.isSatisfied
                      ? Colors.green.shade700
                      : Colors.orange.shade800,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (prereq.prerequisites.isEmpty)
              Text(
                'Entry skill — no prior skill prerequisites required.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ...prereq.prerequisites.map(
                (item) => ListTile(
                  key: Key('prereq_item_${item.learningNodeId}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    item.isAttained ? Icons.check_circle : Icons.lock_outline,
                    color: item.isAttained
                        ? Colors.green.shade700
                        : Colors.orange.shade800,
                  ),
                  title: Text(item.title),
                  subtitle: Text(
                    item.isAttained
                        ? 'Mastered'
                        : 'Locked — master ${item.title} first',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NodeLearningDetailScreen(
                          childId: widget.childId,
                          learningNodeId: item.learningNodeId,
                          childDisplayName: widget.childDisplayName,
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDependentsCard(ThemeData theme, NodePrerequisiteState prereq) {
    return Card(
      key: const Key('node_detail_dependents_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Outgoing Dependents (${prereq.dependents.length})',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (prereq.dependents.isEmpty)
              Text(
                'No downstream skills in the active catalog depend directly on this skill.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              ...prereq.dependents.map(
                (dep) => ListTile(
                  key: Key('dependent_item_${dep.learningNodeId}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    dep.isUnlocked
                        ? Icons.lock_open
                        : dep.isObserved
                        ? Icons.check_circle_outline
                        : Icons.lock_outline,
                    color: dep.isUnlocked
                        ? Colors.teal.shade700
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text('Unlocks: ${dep.title}'),
                  subtitle: Text(
                    dep.isObserved
                        ? 'Already practiced (${dep.attainedPrerequisiteCount}/${dep.prerequisiteCount} prerequisites mastered)'
                        : dep.isUnlocked
                        ? 'Unlocked and ready for next challenge!'
                        : 'Requires ${dep.attainedPrerequisiteCount}/${dep.prerequisiteCount} prerequisites mastered',
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NodeLearningDetailScreen(
                          childId: widget.childId,
                          learningNodeId: dep.learningNodeId,
                          childDisplayName: widget.childDisplayName,
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFreshnessChip(MasteryFreshness freshness) {
    final (label, color) = switch (freshness) {
      MasteryFreshness.recent => ('Fresh: Recent', Colors.green.shade700),
      MasteryFreshness.aging => ('Freshness: Aging', Colors.orange.shade800),
      MasteryFreshness.needsRefresh => (
        'Needs refresh',
        Colors.deepOrange.shade800,
      ),
      MasteryFreshness.unknown => ('Unseen', Colors.grey.shade700),
    };
    return Chip(
      key: const Key('node_detail_freshness_chip'),
      label: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildDifficultyChip(RecommendedDifficulty difficulty) {
    final label = switch (difficulty) {
      RecommendedDifficulty.belowLevel => 'Recommended: Below Level',
      RecommendedDifficulty.normal => 'Recommended: Normal',
      RecommendedDifficulty.hard => 'Recommended: Hard',
      RecommendedDifficulty.challenge => 'Recommended: Challenge',
    };
    return Chip(
      key: const Key('node_detail_difficulty_chip'),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      visualDensity: VisualDensity.compact,
    );
  }
}
