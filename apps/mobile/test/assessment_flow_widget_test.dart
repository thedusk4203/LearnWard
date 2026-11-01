import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/app.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/features/assessments/presentation/evidence_picker_service.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

class _PresetActiveChildNotifier extends ActiveChildModeNotifier {
  _PresetActiveChildNotifier(this._preset);
  final ChildProfile? _preset;

  @override
  ChildProfile? build() => _preset;
}

class _PresetFamilyNotifier extends ActiveFamilyNotifier {
  _PresetFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

void main() {
  late FakeFamilyRepository fakeFamilyRepo;
  late FakeChildProfileRepository fakeChildRepo;
  late FakeAssessmentRepository fakeAssessmentRepo;
  late FakeAssessmentEvidenceStorage fakeStorage;
  late InMemoryLocalMetadataStore fakeMetadataStore;

  final now = DateTime.utc(2026, 11, 1);
  final testFamily = Family(
    id: FamilyId('fam-test-1'),
    name: 'Test Family',
    timezone: 'UTC',
    locale: 'en_US',
    createdByUserId: 'parent-1',
    createdAt: now,
  );

  final testChild = ChildProfile(
    id: ChildId('child-test-1'),
    familyId: testFamily.id,
    displayName: 'Lucas',
    schoolGrade: 5,
    birthYear: 2015,
    createdAt: now,
  );

  setUp(() {
    fakeFamilyRepo = FakeFamilyRepository();
    fakeChildRepo = FakeChildProfileRepository();
    fakeAssessmentRepo = FakeAssessmentRepository();
    fakeStorage = FakeAssessmentEvidenceStorage();
    fakeMetadataStore = InMemoryLocalMetadataStore();

    fakeFamilyRepo.createFamily(
      name: testFamily.name,
      timezone: testFamily.timezone,
      locale: testFamily.locale,
    );
  });

  testWidgets(
    'Child Mode: captures assessment, calculates normalized score, attaches evidence and submits',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
            activeChildModeProvider.overrideWith(
              () => _PresetActiveChildNotifier(testChild),
            ),
            evidencePickerServiceProvider.overrideWithValue(
              SimulatedEvidencePickerService(
                stubFile: const SelectedEvidenceFile(
                  fileName: 'math_quiz.jpg',
                  bytes: [1, 2, 3],
                  mediaType: 'image/jpeg',
                  localPath: '/tmp/math_quiz.jpg',
                ),
              ),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      await tester.pumpAndSettle();

      // In Child Mode
      expect(find.text('Hi, Lucas!'), findsOneWidget);
      expect(
        find.byKey(const Key('child_add_assessment_button')),
        findsOneWidget,
      );

      // Tap Add Academic Result
      await tester.tap(find.byKey(const Key('child_add_assessment_button')));
      await tester.pumpAndSettle();

      expect(find.text('Add Assessment Result'), findsOneWidget);

      // Enter Title
      await tester.enterText(
        find.byKey(const Key('assessment_title_field')),
        'Fractions Mastery Quiz',
      );

      // Enter Raw Score 8.5 and Max Score 10
      await tester.enterText(
        find.byKey(const Key('assessment_raw_score_field')),
        '8.5',
      );
      await tester.pumpAndSettle();

      // Check live normalized score preview
      expect(find.text('Normalized Score: 8.50 / 10.0'), findsOneWidget);

      // Attach evidence photo
      await tester.tap(find.byKey(const Key('attach_evidence_button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('math_quiz.jpg'), findsOneWidget);

      // Submit for review
      await tester.ensureVisible(
        find.byKey(const Key('submit_assessment_button')),
      );
      await tester.tap(find.byKey(const Key('submit_assessment_button')));
      await tester.pumpAndSettle();

      // Should return to Child Mode
      expect(find.text('Hi, Lucas!'), findsOneWidget);

      // Repository state assertion: exactly 1 pending assessment exists
      expect(fakeAssessmentRepo.assessments.length, equals(1));
      final submitted = fakeAssessmentRepo.assessments.values.first;
      expect(submitted.status, equals(AssessmentStatus.pendingReview));
      expect(submitted.title, equals('Fractions Mastery Quiz'));
      expect(submitted.score.rawScore, equals(8.5));
      expect(submitted.score.maxScore, equals(10.0));
      expect(submitted.score.serverNormalizedScore, equals(8.50));
    },
  );

  testWidgets(
    'Parent Mode: reviews pending assessment and verifies it into immutable learning event',
    (tester) async {
      // Pre-seed a submitted pending assessment
      final draft = await fakeAssessmentRepo.createDraft(
        familyId: testFamily.id,
        childId: testChild.id,
        subject: 'Mathematics',
        title: 'Weekly Test 1',
        type: AssessmentType.quiz,
        difficulty: AssessmentDifficulty.normal,
        score: AssessmentScore(rawScore: 9.0, maxScore: 10.0),
      );
      final submitted = await fakeAssessmentRepo.submitAssessment(
        assessmentId: draft.id,
        expectedVersion: 1,
        commandId: 'cmd-sub-test',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
            familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
            childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
            assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
            assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
            activeFamilyProvider.overrideWith(
              () => _PresetFamilyNotifier(testFamily),
            ),
          ],
          child: const LearnWardApp(),
        ),
      );
      await tester.pumpAndSettle();

      // On Family Home Screen
      expect(find.text('Pending Reviews'), findsOneWidget);
      expect(
        find.byKey(Key('pending_card_${submitted.id.value}')),
        findsOneWidget,
      );

      // Tap Review
      await tester.tap(find.byKey(Key('review_button_${submitted.id.value}')));
      await tester.pumpAndSettle();

      expect(find.text('Review Assessment'), findsOneWidget);
      expect(find.text('9.0 / 10.0'), findsOneWidget);
      expect(find.text('9.0 / 10'), findsOneWidget);

      // Tap Verify Result
      await tester.tap(find.byKey(const Key('verify_assessment_button')));
      await tester.pumpAndSettle();

      // Confirmation dialog
      expect(find.text('Confirm Verify'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('verification_notes_field')),
        'Verified correctly solved steps',
      );
      await tester.tap(find.byKey(const Key('confirm_verify_button')));
      await tester.pumpAndSettle();

      // Back on Family Home Screen: pending section now empty
      expect(
        find.text('All caught up! No pending submissions.'),
        findsOneWidget,
      );

      // Assert verified learning event was generated
      expect(fakeAssessmentRepo.verifiedEvents.length, equals(1));
      final event = fakeAssessmentRepo.verifiedEvents.first;
      expect(event.title, equals('Weekly Test 1'));
      expect(event.score.rawScore, equals(9.0));
      expect(event.score.serverNormalizedScore, equals(9.0));
    },
  );

  testWidgets('Parent Mode: rejects a submitted assessment with reason note', (
    tester,
  ) async {
    final draft = await fakeAssessmentRepo.createDraft(
      familyId: testFamily.id,
      childId: testChild.id,
      subject: 'English',
      title: 'Vocabulary Quiz',
      type: AssessmentType.quiz,
      difficulty: AssessmentDifficulty.normal,
      score: AssessmentScore(rawScore: 5.0, maxScore: 10.0),
    );
    final submitted = await fakeAssessmentRepo.submitAssessment(
      assessmentId: draft.id,
      expectedVersion: 1,
      commandId: 'cmd-sub-vocab',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMetadataStoreProvider.overrideWithValue(fakeMetadataStore),
          familyRepositoryProvider.overrideWithValue(fakeFamilyRepo),
          childProfileRepositoryProvider.overrideWithValue(fakeChildRepo),
          assessmentRepositoryProvider.overrideWithValue(fakeAssessmentRepo),
          assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
          activeFamilyProvider.overrideWith(
            () => _PresetFamilyNotifier(testFamily),
          ),
        ],
        child: const LearnWardApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Review
    await tester.tap(find.byKey(Key('review_button_${submitted.id.value}')));
    await tester.pumpAndSettle();

    // Tap Reject
    await tester.tap(find.byKey(const Key('reject_assessment_button')));
    await tester.pumpAndSettle();

    // Enter rejection reason
    await tester.enterText(
      find.byKey(const Key('rejection_reason_field')),
      'Incomplete page 2',
    );
    await tester.tap(find.byKey(const Key('confirm_reject_button')));
    await tester.pumpAndSettle();

    // Verified events should still be 0
    expect(fakeAssessmentRepo.verifiedEvents.isEmpty, isTrue);
    // Status in repo must be rejected
    expect(
      fakeAssessmentRepo.assessments[submitted.id.value]?.status,
      equals(AssessmentStatus.rejected),
    );
  });
}
