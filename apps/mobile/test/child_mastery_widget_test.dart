import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/features/learning/presentation/child_mastery_screen.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void main() {
  group('ChildMasteryScreen Widget Tests', () {
    final childId = ChildId('c5000000-0000-0000-0000-000000000001');
    final familyId = FamilyId('f5000000-0000-0000-0000-000000000001');

    testWidgets('renders empty state when no evidence exists', (tester) async {
      final fakeRepo = FakeLearningRepository();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [learningRepositoryProvider.overrideWithValue(fakeRepo)],
          child: MaterialApp(
            home: ChildMasteryScreen(
              childId: childId,
              childDisplayName: 'Alex',
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text("Alex's Mastery"), findsOneWidget);
      expect(find.text('No Verified Learning Yet'), findsOneWidget);
    });

    testWidgets(
      'renders mastery projection cards with correct bands and confidence',
      (tester) async {
        final fakeRepo = FakeLearningRepository();
        final now = DateTime.utc(2026, 11, 2, 10, 0);

        // Add two evidence events for Single Digit Addition
        final nodeId = LearningNodeId('b0000003-0000-0000-0000-000000000001');

        fakeRepo.addEvidence(
          LearningEvidenceEvent(
            id: 'ev-1',
            familyId: familyId,
            childId: childId,
            verifiedLearningEventId: 'vle-1',
            learningNodeId: nodeId,
            nodeType: LearningNodeType.skill,
            subjectKey: 'math',
            scoreSource: ScoreSource.componentScore,
            performancePct: 90.0,
            specificityWeight: 1.0,
            levelWeight: 1.0,
            effectiveOccurredAt: now.subtract(const Duration(days: 10)),
            verifiedAt: now.subtract(const Duration(days: 10)),
          ),
        );

        fakeRepo.addEvidence(
          LearningEvidenceEvent(
            id: 'ev-2',
            familyId: familyId,
            childId: childId,
            verifiedLearningEventId: 'vle-2',
            learningNodeId: nodeId,
            nodeType: LearningNodeType.skill,
            subjectKey: 'math',
            scoreSource: ScoreSource.componentScore,
            performancePct: 90.0,
            specificityWeight: 1.0,
            levelWeight: 1.0,
            effectiveOccurredAt: now.subtract(const Duration(days: 5)),
            verifiedAt: now.subtract(const Duration(days: 5)),
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [learningRepositoryProvider.overrideWithValue(fakeRepo)],
            child: MaterialApp(
              home: ChildMasteryScreen(
                childId: childId,
                childDisplayName: 'Alex',
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();

        expect(find.text('Single Digit Addition'), findsOneWidget);
        expect(find.text('90.0%'), findsOneWidget);
        expect(find.text('Mastery Candidate'), findsOneWidget);
        expect(find.text('Medium Confidence'), findsOneWidget);
        expect(find.text('2 verified assessments'), findsOneWidget);
      },
    );
  });
}
