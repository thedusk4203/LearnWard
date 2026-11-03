import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import 'next_challenge_section.dart';
import 'node_learning_detail_screen.dart';

/// Parent Learning Overview Screen (Phase 5.2).
///
/// Displays all 5 canonical Subjects from `getChildLearningOverview`, explicit coverage
/// counts ("Observed X of Y tracked skills" + "Z unseen"), direct Subject-root state
/// when present, `Needs refresh` badge counts without score decay, gentle "Review suggested"
/// recovery badges, and a Parent Preview of Next Challenge candidates.
/// Never displays a naive universal arithmetic percentage average across skills.
class LearningOverviewScreen extends ConsumerStatefulWidget {
  const LearningOverviewScreen({
    super.key,
    required this.childId,
    this.childDisplayName = 'Learner',
  });

  final ChildId childId;
  final String childDisplayName;

  @override
  ConsumerState<LearningOverviewScreen> createState() =>
      _LearningOverviewScreenState();
}

class _LearningOverviewScreenState
    extends ConsumerState<LearningOverviewScreen> {
  bool _isLoading = true;
  String? _errorMessage;
  LearningOverview? _overview;

  @override
  void initState() {
    super.initState();
    _loadOverview();
  }

  Future<void> _loadOverview() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(learningRepositoryProvider);
      final useCase = GetChildLearningOverview(repo);
      final overview = await useCase(childId: widget.childId);
      if (mounted) {
        setState(() {
          _overview = overview;
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

  void _openNodeDetail(String learningNodeId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NodeLearningDetailScreen(
          childId: widget.childId,
          learningNodeId: learningNodeId,
          childDisplayName: widget.childDisplayName,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.childDisplayName}\'s Learning Overview'),
        actions: [
          IconButton(
            key: const Key('learning_overview_refresh_button'),
            icon: const Icon(Icons.refresh),
            onPressed: _loadOverview,
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

    if (_errorMessage != null || _overview == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              Text(
                'Failed to load learning overview',
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
                onPressed: _loadOverview,
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    final overview = _overview!;

    return RefreshIndicator(
      onRefresh: _loadOverview,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildOverallCoverageSummary(theme, overview),
          const SizedBox(height: 16),
          NextChallengeSection(
            childId: widget.childId,
            childDisplayName: widget.childDisplayName,
            isParentPreview: true,
          ),
          const SizedBox(height: 16),
          Text(
            'Curriculum Subjects (${overview.subjects.length})',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          ...overview.subjects.map(
            (subject) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildSubjectCard(theme, subject),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverallCoverageSummary(
    ThemeData theme,
    LearningOverview overview,
  ) {
    final cov = overview.overallCoverage;
    final gradeLabel = overview.schoolGrade != null
        ? 'Grade ${overview.schoolGrade}'
        : 'Grade not set';

    return Card(
      key: const Key('overall_coverage_card'),
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
                  'Catalog Coverage (${overview.activeCatalogVersion})',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Chip(
                  label: Text(gradeLabel),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Observed ${cov.observedSkills} of ${cov.totalSkills} tracked skills • ${cov.unseenSkills} unseen',
              key: const Key('overall_skills_coverage_text'),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Observed ${cov.observedTopics} of ${cov.totalTopics} tracked topics • '
              'Mastered skills: ${cov.masteredSkills}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (cov.needsRefreshCount > 0 || cov.activeRecoveryCount > 0) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (cov.needsRefreshCount > 0)
                    Chip(
                      key: const Key('overall_needs_refresh_badge'),
                      label: Text('${cov.needsRefreshCount} Needs refresh'),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (cov.activeRecoveryCount > 0)
                    Chip(
                      key: const Key('overall_recovery_badge'),
                      label: Text(
                        '${cov.activeRecoveryCount} Review suggested',
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSubjectCard(ThemeData theme, LearningSubjectOverview subject) {
    final cov = subject.coverage;
    final subState = subject.subjectState;

    return Card(
      key: Key('subject_overview_card_${subject.subjectKey}'),
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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        subject.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Observed ${cov.observedSkills} of ${cov.totalSkills} tracked skills (${cov.unseenSkills} unseen)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('subject_detail_button_${subject.subjectKey}'),
                  icon: const Icon(Icons.info_outline, size: 20),
                  tooltip: 'Inspect Subject Node',
                  onPressed: () => _openNodeDetail(subject.subjectNodeId),
                ),
              ],
            ),
            if (subState.isObserved) ...[
              const SizedBox(height: 8),
              Container(
                key: Key('subject_direct_state_${subject.subjectKey}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Direct subject-level evidence: ${subState.masteryScore?.toStringAsFixed(1) ?? '0.0'}% '
                  '(${subState.masteryBand?.value ?? 'no_data'} • ${subState.distinctAssessmentCount} assessments)',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            if (cov.needsRefreshCount > 0 || cov.activeRecoveryCount > 0) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (cov.needsRefreshCount > 0)
                    Chip(
                      label: Text('${cov.needsRefreshCount} Needs refresh'),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (cov.activeRecoveryCount > 0)
                    Chip(
                      label: Text(
                        '${cov.activeRecoveryCount} Review suggested',
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            if (subject.topics.isEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'No granular topics or skills seeded for this subject in the active catalog yet.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 8),
              ...subject.topics.map(
                (topic) => _buildTopicSection(theme, topic),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTopicSection(ThemeData theme, LearningTopicOverview topic) {
    final topicStateText = topic.isObserved
        ? '${topic.masteryScore?.toStringAsFixed(1) ?? '0.0'}% (${topic.masteryBand?.value ?? ''})'
        : 'Topic direct evidence: Unseen';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            key: Key('overview_topic_tile_${topic.learningNodeId}'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${topic.domainTitle} • ${topic.title}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: Text(
              '$topicStateText • Observed ${topic.skillCoverage.observedSkills} of ${topic.skillCoverage.totalSkills} skills',
              style: theme.textTheme.bodySmall,
            ),
            trailing: const Icon(Icons.chevron_right, size: 18),
            onTap: () => _openNodeDetail(topic.learningNodeId),
          ),
          ...topic.skills.map((skill) => _buildSkillRow(theme, skill)),
        ],
      ),
    );
  }

  Widget _buildSkillRow(ThemeData theme, LearningSkillOverviewItem skill) {
    final statusText = skill.isObserved
        ? '${skill.masteryScore?.toStringAsFixed(1) ?? '0.0'}% • ${_formatBandLabel(skill.masteryBand)}'
        : skill.isPrerequisiteSatisfied
        ? 'Unseen • Ready'
        : 'Unseen • Locked (${skill.attainedPrerequisiteCount}/${skill.prerequisiteCount} prerequisites)';

    final badges = <String>[
      if (skill.freshness == MasteryFreshness.needsRefresh) 'Needs refresh',
      if (skill.recoverySignal == RecoverySignal.reviewSuggested)
        'Review suggested',
    ];

    return ListTile(
      key: Key('overview_skill_tile_${skill.learningNodeId}'),
      dense: true,
      contentPadding: const EdgeInsets.only(left: 12),
      leading: Icon(
        skill.masteryBand == MasteryBand.mastered
            ? Icons.verified
            : skill.isObserved
            ? Icons.radio_button_checked
            : skill.isPrerequisiteSatisfied
            ? Icons.radio_button_unchecked
            : Icons.lock_outline,
        size: 18,
        color: skill.masteryBand == MasteryBand.mastered
            ? Colors.green.shade700
            : theme.colorScheme.onSurfaceVariant,
      ),
      title: Text(skill.title),
      subtitle: Text(
        [statusText, ...badges].join(' • '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _openNodeDetail(skill.learningNodeId),
    );
  }

  String _formatBandLabel(MasteryBand? band) {
    return switch (band) {
      MasteryBand.mastered => 'Mastered',
      MasteryBand.masteryCandidate => 'Mastery Candidate',
      MasteryBand.secure => 'Secure',
      MasteryBand.developing => 'Developing',
      MasteryBand.emerging => 'Emerging',
      MasteryBand.noData || null => 'Unseen',
    };
  }
}
