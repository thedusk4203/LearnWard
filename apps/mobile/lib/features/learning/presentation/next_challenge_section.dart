import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import 'node_learning_detail_screen.dart';

/// Reusable Phase 5.2 Next Challenge Choice UI section for Child Mode and Parent Preview.
///
/// Displays up to 3 deterministic Next Challenge choice cards with Subject filter chips
/// (`All`, `Math`, `English`, `Literature`, `Science`, `Other`). Selecting a card opens a
/// read-only challenge brief sheet and performs zero server writes or XP/RP awards.
class NextChallengeSection extends ConsumerStatefulWidget {
  const NextChallengeSection({
    super.key,
    required this.childId,
    this.childDisplayName = 'Learner',
    this.isParentPreview = false,
  });

  final ChildId childId;
  final String childDisplayName;
  final bool isParentPreview;

  @override
  ConsumerState<NextChallengeSection> createState() =>
      _NextChallengeSectionState();
}

class _NextChallengeSectionState extends ConsumerState<NextChallengeSection> {
  bool _isLoading = true;
  String? _errorMessage;
  SubjectKey? _selectedSubject;
  NextChallengeRecommendationSet? _recommendationSet;

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  Future<void> _loadCandidates() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(learningRepositoryProvider);
      final useCase = GetNextChallengeCandidates(repo);
      final result = await useCase(
        childId: widget.childId,
        subjectKey: _selectedSubject,
        limit: 3,
      );
      if (mounted) {
        setState(() {
          _recommendationSet = result;
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

  void _onSelectSubject(SubjectKey? subject) {
    if (_selectedSubject == subject) return;
    setState(() {
      _selectedSubject = subject;
    });
    _loadCandidates();
  }

  static String formatCandidateReason(NextChallengeCandidate candidate) {
    switch (candidate.reasonCode) {
      case NextChallengeReason.recoveryRecentErrors:
        return 'Review suggested from recent questions';
      case NextChallengeReason.refreshStaleSecureSkill:
        return 'Keep this strong skill fresh';
      case NextChallengeReason.developingKeepPracticing:
        return 'Keep practicing toward mastery';
      case NextChallengeReason.unlockPrerequisitesMastered:
        final prereqs = candidate.explanation.attainedPrerequisiteTitles;
        if (prereqs.isNotEmpty) {
          return 'Newly unlocked — you mastered ${prereqs.join(', ')}!';
        }
        return 'Newly unlocked — prerequisites mastered!';
      case NextChallengeReason.exploreAvailableSkill:
        return 'Ready to explore';
    }
  }

  static String formatDifficultyLabel(RecommendedDifficulty difficulty) {
    return switch (difficulty) {
      RecommendedDifficulty.belowLevel => 'Below Level',
      RecommendedDifficulty.normal => 'Normal',
      RecommendedDifficulty.hard => 'Hard',
      RecommendedDifficulty.challenge => 'Challenge',
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      key: const Key('next_challenge_section_card'),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.isParentPreview
                            ? 'Next Challenge Preview (Up to 3 Choices)'
                            : 'Choose Your Next Challenge',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Pick 1 of up to 3 personalized external practice goals.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('next_challenge_refresh_button'),
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: 'Refresh choices',
                  onPressed: _loadCandidates,
                ),
              ],
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: const Key('next_challenge_filter_all'),
                      label: const Text('All'),
                      selected: _selectedSubject == null,
                      onSelected: (_) => _onSelectSubject(null),
                    ),
                  ),
                  ...SubjectKey.values.map(
                    (subject) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        key: Key('next_challenge_filter_${subject.value}'),
                        label: Text(subject.displayLabel),
                        selected: _selectedSubject == subject,
                        onSelected: (_) => _onSelectSubject(subject),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  children: [
                    Text(
                      'Could not load Next Challenge suggestions: $_errorMessage',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _loadCandidates,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            else if (_recommendationSet == null ||
                _recommendationSet!.candidates.isEmpty)
              _buildEmptyState(theme)
            else
              ..._recommendationSet!.candidates.map(
                (candidate) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildCandidateCard(context, theme, candidate),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    final missingGrade = _recommendationSet?.schoolGrade == null;
    return Container(
      key: const Key('next_challenge_empty_state'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(
            missingGrade ? Icons.school_outlined : Icons.check_circle_outline,
            size: 36,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 8),
          Text(
            missingGrade
                ? 'School Grade Needed for New Skill Suggestions'
                : 'All Tracked Skills in This View Are Up to Date!',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            missingGrade
                ? 'Ask a parent to set a school grade on this profile to unlock grade-matched new skills, or freely capture any external school work.'
                : 'You can freely practice any external assignment or switch the subject filter above.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildCandidateCard(
    BuildContext context,
    ThemeData theme,
    NextChallengeCandidate candidate,
  ) {
    final reasonText = formatCandidateReason(candidate);
    final difficultyLabel = formatDifficultyLabel(
      candidate.recommendedDifficulty,
    );

    final (
      priorityLabel,
      badgeColor,
      badgeBg,
    ) = switch (candidate.priorityClass) {
      RecommendationPriority.recovery => (
        'Recovery',
        Colors.amber.shade900,
        Colors.amber.shade100,
      ),
      RecommendationPriority.refresh => (
        'Refresh',
        Colors.deepOrange.shade900,
        Colors.deepOrange.shade100,
      ),
      RecommendationPriority.developing => (
        'Keep Going',
        Colors.blue.shade900,
        Colors.blue.shade100,
      ),
      RecommendationPriority.unlock => (
        'Unlocked',
        Colors.teal.shade900,
        Colors.teal.shade100,
      ),
      RecommendationPriority.explore => (
        'Explore',
        Colors.purple.shade900,
        Colors.purple.shade100,
      ),
    };

    final breadcrumb = <String>[
      candidate.subjectKey.toUpperCase(),
      if (candidate.parentDomainTitle != null) candidate.parentDomainTitle!,
      if (candidate.parentTopicTitle != null) candidate.parentTopicTitle!,
    ].join(' • ');

    return InkWell(
      key: Key('next_challenge_card_${candidate.learningNodeId}'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showChallengeBriefSheet(context, candidate),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Choice #${candidate.rank} • $priorityLabel',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: badgeColor,
                    ),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Difficulty: $difficultyLabel',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              breadcrumb,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              candidate.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              reasonText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showChallengeBriefSheet(
    BuildContext context,
    NextChallengeCandidate candidate,
  ) {
    final theme = Theme.of(context);
    final reasonText = formatCandidateReason(candidate);
    final difficultyLabel = formatDifficultyLabel(
      candidate.recommendedDifficulty,
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            key: Key('next_challenge_brief_sheet_${candidate.learningNodeId}'),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Next Challenge Brief',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  candidate.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(reasonText, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Suggested External Practice Difficulty: $difficultyLabel',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Practice this skill on a school worksheet, quiz, or workbook at home. '
                        'Viewing or choosing a challenge does not award XP or RP by itself — '
                        'rewards and mastery update once real work is captured and verified by a parent.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('challenge_brief_view_node_detail'),
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => NodeLearningDetailScreen(
                                childId: widget.childId,
                                learningNodeId: candidate.learningNodeId,
                                childDisplayName: widget.childDisplayName,
                              ),
                            ),
                          );
                        },
                        child: const Text('View Skill Graph Details'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const Key('challenge_brief_close_button'),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        child: const Text('Got It'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
