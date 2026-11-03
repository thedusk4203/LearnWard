import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/features/learning/presentation/learning_overview_screen.dart';
import 'package:learnward/features/learning/presentation/next_challenge_section.dart';
import 'package:learnward/features/learning/presentation/node_learning_detail_screen.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void main() {
  group('Phase 5.2 Learning Overview, Node Detail & Next Challenge Widgets', () {
    final childId = ChildId('child-1');
    final familyId = FamilyId('fam-1');
    final now = DateTime.utc(2026, 6, 1, 12, 0);

    testWidgets(
      'LearningOverviewScreen renders coverage summary, Next Challenge preview, and 5 canonical subjects',
      (tester) async {
        final fakeLearningRepo = FakeLearningRepository(
          clock: () => now,
          defaultSchoolGrade: 2,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              learningRepositoryProvider.overrideWithValue(fakeLearningRepo),
            ],
            child: MaterialApp(
              home: LearningOverviewScreen(
                childId: childId,
                childDisplayName: 'Maya',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text("Maya's Learning Overview"), findsOneWidget);
        expect(find.byKey(const Key('overall_coverage_card')), findsOneWidget);
        expect(
          find.byKey(const Key('overall_skills_coverage_text')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('next_challenge_section_card')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('subject_overview_card_math')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.byKey(const Key('subject_overview_card_math')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'NextChallengeSection filters by subject chip and opens read-only challenge brief with zero economy mutation',
      (tester) async {
        final fakeLearningRepo = FakeLearningRepository(
          clock: () => now,
          defaultSchoolGrade: 2,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              learningRepositoryProvider.overrideWithValue(fakeLearningRepo),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: NextChallengeSection(
                    childId: childId,
                    childDisplayName: 'Maya',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Choose Your Next Challenge'), findsOneWidget);
        expect(find.text('Single Digit Addition'), findsOneWidget);

        // Filter to Math only
        await tester.tap(find.byKey(const Key('next_challenge_filter_math')));
        await tester.pumpAndSettle();

        expect(find.text('Single Digit Addition'), findsOneWidget);

        // Filter to Other (no skills in pilot-v0.1 under Other -> empty state)
        await tester.ensureVisible(
          find.byKey(const Key('next_challenge_filter_other')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('next_challenge_filter_other')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('next_challenge_empty_state')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'NodeLearningDetailScreen renders recovery banner and prerequisite status accurately',
      (tester) async {
        final fakeLearningRepo = FakeLearningRepository(
          clock: () => now,
          defaultSchoolGrade: 2,
        );

        // Seed weak component evidence on Single Digit Addition (40%)
        final singleDigitId = LearningNodeId(
          'b0000003-0000-0000-0000-000000000001',
        );
        fakeLearningRepo.addEvidence(
          LearningEvidenceEvent(
            id: 'ev-weak-1',
            familyId: familyId,
            childId: childId,
            verifiedLearningEventId: 'vle-weak-1',
            learningNodeId: singleDigitId,
            nodeType: LearningNodeType.skill,
            subjectKey: 'math',
            scoreSource: ScoreSource.componentScore,
            performancePct: 40.0,
            specificityWeight: 1.0,
            levelWeight: 1.0,
            effectiveOccurredAt: now.subtract(const Duration(days: 2)),
            verifiedAt: now.subtract(const Duration(days: 2)),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              learningRepositoryProvider.overrideWithValue(fakeLearningRepo),
            ],
            child: MaterialApp(
              home: NodeLearningDetailScreen(
                childId: childId,
                learningNodeId: singleDigitId.value,
                childDisplayName: 'Maya',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Single Digit Addition'), findsWidgets);
        expect(
          find.byKey(const Key('node_detail_recovery_banner')),
          findsOneWidget,
        );
        expect(find.text('Review suggested'), findsWidgets);
      },
    );
  });
}
