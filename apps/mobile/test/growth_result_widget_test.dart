import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/assessments/presentation/growth_result_screen.dart';
import 'package:learnward/features/child/presentation/child_mode_screen.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

class _PresetChildModeNotifier extends ActiveChildModeNotifier {
  _PresetChildModeNotifier(this._preset);
  final ChildProfile? _preset;

  @override
  ChildProfile? build() => _preset;
}

class _FakeGrowthRepository implements GrowthRepository {
  ChildBalance? balance;
  GrowthEvent? latest;
  List<GrowthEvent> history = [];

  @override
  Future<ChildBalance> getChildBalance(ChildId childId) async {
    return balance ??
        ChildBalance(
          childId: childId,
          familyId: FamilyId('fam-1'),
          xpTotal: const XpAmount(50),
          rpBalanceMinor: const RpMinor(1250),
          updatedAt: DateTime.utc(2026, 11, 1),
        );
  }

  @override
  Future<GrowthEvent?> getLatestGrowthEvent(ChildId childId) async {
    return latest;
  }

  @override
  Future<List<GrowthEvent>> listGrowthEvents(
    ChildId childId, {
    int limit = 20,
  }) async {
    return history;
  }

  @override
  Future<GrowthEvent?> getGrowthEventByAssessmentId(
    AssessmentId assessmentId,
  ) async {
    return latest;
  }

  @override
  Future<GrowthEvent> processVerifiedLearningEvent({
    required String verifiedLearningEventId,
    String? commandId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<VerifiedLearningEvent>> getUnprocessedVerifiedEvents(
    FamilyId familyId,
  ) async {
    return const [];
  }

  @override
  Future<int> catchUpUnprocessedGrowth(FamilyId familyId) async {
    return 0;
  }
}

GrowthEvent _createEvent({
  String id = 'growth-1',
  String verifiedLearningEventId = 'vle-1',
  ChildId? childId,
  FamilyId? familyId,
  AssessmentId? assessmentId,
  String engineVersion = 'growth-v0.1',
  double normalizedScore = 8.5,
  double? baselineScore = 7.0,
  int baselineSampleCount = 3,
  double? growthDelta = 1.5,
  double? historicalBest,
  RpMinor scoreRpMinor = const RpMinor(500),
  RpMinor growthRpMinor = const RpMinor(150),
  RpMinor highPerformerRpMinor = const RpMinor(50),
  RpMinor goalRpMinor = const RpMinor(0),
  RpMinor personalBestRpMinor = const RpMinor(100),
  RpMinor difficultyRpMinor = const RpMinor(100),
  RpMinor recoveryRpMinor = const RpMinor(0),
  bool belowLevelAdjustment = false,
  RpMinor totalRpMinor = const RpMinor(900),
  XpAmount xpAwarded = const XpAmount(28),
  Map<String, dynamic> inputsSnapshot = const {
    'explanation': 'Standard growth evaluation',
  },
  DateTime? createdAt,
}) {
  return GrowthEvent(
    id: id,
    familyId: familyId ?? FamilyId('fam-1'),
    childId: childId ?? ChildId('child-1'),
    verifiedLearningEventId: verifiedLearningEventId,
    assessmentId: assessmentId ?? AssessmentId('asm-1'),
    engineVersion: engineVersion,
    normalizedScore: normalizedScore,
    baselineScore: baselineScore,
    baselineSampleCount: baselineSampleCount,
    growthDelta: growthDelta,
    historicalBest: historicalBest,
    scoreRpMinor: scoreRpMinor,
    growthRpMinor: growthRpMinor,
    highPerformerRpMinor: highPerformerRpMinor,
    goalRpMinor: goalRpMinor,
    personalBestRpMinor: personalBestRpMinor,
    difficultyRpMinor: difficultyRpMinor,
    recoveryRpMinor: recoveryRpMinor,
    belowLevelAdjustment: belowLevelAdjustment,
    totalRpMinor: totalRpMinor,
    xpAwarded: xpAwarded,
    inputsSnapshot: inputsSnapshot,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 1, 10, 0),
  );
}

void main() {
  group('GrowthResultScreen Widget Tests', () {
    testWidgets('renders standard assessment growth breakdown with bonuses', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final event = _createEvent();

      await tester.pumpWidget(
        MaterialApp(home: GrowthResultScreen(growthEvent: event)),
      );
      await tester.pumpAndSettle();

      // Verify Score and Baseline
      expect(find.text('Score: 8.50 / 10'), findsOneWidget);
      expect(find.text('Baseline: 7.00'), findsOneWidget);
      expect(find.text('Improvement: +1.50'), findsOneWidget);

      // Verify RP Breakdown
      expect(find.text('Reward Points (RP)'), findsOneWidget);
      expect(find.text('+5.00'), findsOneWidget); // Score
      expect(find.text('+1.50'), findsOneWidget); // Growth
      expect(find.text('+0.50'), findsOneWidget); // Mastery
      expect(find.text('+1.00'), findsNWidgets(2)); // PB and Challenge
      expect(find.text('+9.00 RP'), findsOneWidget); // Total RP

      // Verify Study XP
      expect(find.text('Study XP'), findsOneWidget);
      expect(find.text('+28 XP'), findsOneWidget);

      // Verify Educational explanation
      expect(find.text('Why did I get this amount?'), findsOneWidget);
      expect(
        find.textContaining(
          'Direct reward proportional to verified test score',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'renders below-level anti-farming notice when belowLevelAdjustment is true',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final event = _createEvent(
          id: 'growth-below',
          verifiedLearningEventId: 'vle-below',
          normalizedScore: 10.0,
          baselineScore: 6.0,
          baselineSampleCount: 3,
          growthDelta: null,
          scoreRpMinor: const RpMinor(250),
          growthRpMinor: const RpMinor(0),
          highPerformerRpMinor: const RpMinor(0),
          personalBestRpMinor: const RpMinor(0),
          difficultyRpMinor: const RpMinor(0),
          totalRpMinor: const RpMinor(250),
          xpAwarded: const XpAmount(15),
          belowLevelAdjustment: true,
        );

        await tester.pumpWidget(
          MaterialApp(home: GrowthResultScreen(growthEvent: event)),
        );
        await tester.pumpAndSettle();

        expect(find.text('Below-level activity (25% base RP)'), findsOneWidget);
        expect(find.text('+2.50 RP'), findsOneWidget);
        expect(find.text('+15 XP'), findsOneWidget);
        expect(
          find.textContaining(
            'This activity is below current level',
            findRichText: true,
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('shows as dialog and closes via close button', (tester) async {
      final event = _createEvent(
        normalizedScore: 7.0,
        baselineScore: null,
        baselineSampleCount: 0,
        growthDelta: null,
        scoreRpMinor: const RpMinor(400),
        growthRpMinor: const RpMinor(0),
        highPerformerRpMinor: const RpMinor(0),
        personalBestRpMinor: const RpMinor(0),
        difficultyRpMinor: const RpMinor(0),
        totalRpMinor: const RpMinor(400),
        xpAwarded: const XpAmount(18),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () =>
                  GrowthResultScreen.show(context, growthEvent: event),
              child: const Text('Show Dialog'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show Dialog'));
      await tester.pumpAndSettle();

      expect(find.text('Score: 7.00 / 10'), findsOneWidget);
      expect(
        find.text('Building Baseline (0 / 3 comparable tests)'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('close_growth_result_button')));
      await tester.pumpAndSettle();

      expect(find.text('Score: 7.00 / 10'), findsNothing);
    });
  });

  group('ChildModeScreen Economy Integration Tests', () {
    testWidgets('displays balance card and latest growth event', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeGrowthRepo = _FakeGrowthRepository();
      final child = ChildProfile(
        id: ChildId('child-1'),
        familyId: FamilyId('fam-1'),
        displayName: 'Sam',
        schoolGrade: 4,
        createdAt: DateTime.utc(2026, 11, 1),
      );

      final latestEvent = _createEvent(
        id: 'growth-latest',
        verifiedLearningEventId: 'vle-latest',
        normalizedScore: 9.0,
        baselineScore: 8.0,
        baselineSampleCount: 3,
        growthDelta: 1.0,
        scoreRpMinor: const RpMinor(500),
        growthRpMinor: const RpMinor(100),
        highPerformerRpMinor: const RpMinor(50),
        personalBestRpMinor: const RpMinor(0),
        difficultyRpMinor: const RpMinor(0),
        totalRpMinor: const RpMinor(650),
        xpAwarded: const XpAmount(23),
      );

      fakeGrowthRepo.latest = latestEvent;
      fakeGrowthRepo.history = [latestEvent];
      fakeGrowthRepo.balance = ChildBalance(
        childId: child.id,
        familyId: child.familyId,
        xpTotal: const XpAmount(150),
        rpBalanceMinor: const RpMinor(2450),
        updatedAt: DateTime.utc(2026, 11, 1),
      );

      final metadataStore = InMemoryLocalMetadataStore();
      final draftStore = InMemoryLocalDraftStore();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeChildModeProvider.overrideWith(
              () => _PresetChildModeNotifier(child),
            ),
            growthRepositoryProvider.overrideWithValue(fakeGrowthRepo),
            localMetadataStoreProvider.overrideWithValue(metadataStore),
            localDraftStoreProvider.overrideWithValue(draftStore),
          ],
          child: const MaterialApp(home: ChildModeScreen()),
        ),
      );

      await tester.pumpAndSettle();

      // Check authoritative balance card
      expect(find.byKey(const Key('child_balances_card')), findsOneWidget);
      expect(find.byKey(const Key('child_xp_total')), findsOneWidget);
      expect(find.text('150 XP'), findsOneWidget);
      expect(find.byKey(const Key('child_rp_balance')), findsOneWidget);
      expect(find.text('24.50 RP'), findsOneWidget);

      // Check latest growth highlight card
      expect(find.byKey(const Key('latest_growth_card')), findsOneWidget);
      expect(find.text('Latest Verified Result'), findsOneWidget);
      expect(find.text('+6.50 RP'), findsOneWidget);

      // Check history item
      expect(
        find.byKey(Key('growth_history_item_${latestEvent.id}')),
        findsOneWidget,
      );

      // Tap history item to open dialog
      await tester.tap(
        find.byKey(Key('growth_history_item_${latestEvent.id}')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Score: 9.00 / 10'), findsOneWidget);
      expect(find.text('+6.50 RP'), findsNWidgets(2));
    });
  });
}
