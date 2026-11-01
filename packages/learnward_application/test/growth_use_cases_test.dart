import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

class FakeGrowthRepository implements GrowthRepository {
  final Map<String, GrowthEvent> growthEventsByVle = {};
  final Map<String, GrowthEvent> growthEventsByAssessment = {};
  final Map<String, ChildBalance> balancesByChild = {};
  final List<XpLedgerEntry> xpLedger = [];
  final List<RpLedgerEntry> rpLedger = [];
  final Set<String> processedCommandIds = {};

  int processCallCount = 0;

  @override
  Future<GrowthEvent> processVerifiedLearningEvent({
    required String verifiedLearningEventId,
    String? commandId,
  }) async {
    processCallCount++;

    // Idempotency: return existing event if already calculated
    if (growthEventsByVle.containsKey(verifiedLearningEventId)) {
      return growthEventsByVle[verifiedLearningEventId]!;
    }

    if (commandId != null && processedCommandIds.contains(commandId)) {
      return growthEventsByVle[verifiedLearningEventId]!;
    }

    final familyId = FamilyId('fam_1');
    final childId = ChildId('child_1');
    final assessmentId = AssessmentId('assess_1');

    final growthEvent = GrowthEvent(
      id: 'ge_${growthEventsByVle.length + 1}',
      familyId: familyId,
      childId: childId,
      verifiedLearningEventId: verifiedLearningEventId,
      assessmentId: assessmentId,
      engineVersion: GrowthEngine.engineVersion,
      normalizedScore: 7.50,
      baselineScore: 6.43,
      baselineSampleCount: 3,
      growthDelta: 1.07,
      historicalBest: 6.80,
      scoreRpMinor: const RpMinor(750),
      growthRpMinor: const RpMinor(200),
      highPerformerRpMinor: RpMinor.zero,
      goalRpMinor: RpMinor.zero,
      personalBestRpMinor: const RpMinor(100),
      difficultyRpMinor: const RpMinor(100),
      recoveryRpMinor: RpMinor.zero,
      belowLevelAdjustment: false,
      totalRpMinor: const RpMinor(1150),
      xpAwarded: const XpAmount(33),
      inputsSnapshot: {'version': GrowthEngine.engineVersion},
      createdAt: DateTime.utc(2026, 11, 1),
    );

    growthEventsByVle[verifiedLearningEventId] = growthEvent;
    growthEventsByAssessment[assessmentId.value] = growthEvent;
    if (commandId != null) processedCommandIds.add(commandId);

    // Append to ledgers
    xpLedger.add(
      XpLedgerEntry(
        id: 'xp_${xpLedger.length + 1}',
        familyId: familyId,
        childId: childId,
        amount: growthEvent.xpAwarded,
        reasonCode: 'growth_award',
        sourceType: 'growth_event',
        sourceId: growthEvent.id,
        idempotencyKey: 'xp:ge:${growthEvent.id}',
        createdAt: growthEvent.createdAt,
      ),
    );

    rpLedger.add(
      RpLedgerEntry(
        id: 'rp_${rpLedger.length + 1}',
        familyId: familyId,
        childId: childId,
        amountMinor: growthEvent.totalRpMinor,
        reasonCode: 'growth_award',
        sourceType: 'growth_event',
        sourceId: growthEvent.id,
        idempotencyKey: 'rp:ge:${growthEvent.id}',
        createdAt: growthEvent.createdAt,
      ),
    );

    // Update balance projection
    final currentBal = balancesByChild[childId.value];
    final newXp =
        (currentBal?.xpTotal ?? XpAmount.zero) + growthEvent.xpAwarded;
    final newRp =
        (currentBal?.rpBalanceMinor ?? RpMinor.zero) + growthEvent.totalRpMinor;

    balancesByChild[childId.value] = ChildBalance(
      familyId: familyId,
      childId: childId,
      xpTotal: newXp,
      rpBalanceMinor: newRp,
      updatedAt: growthEvent.createdAt,
    );

    return growthEvent;
  }

  @override
  Future<ChildBalance?> getChildBalance(ChildId childId) async {
    return balancesByChild[childId.value];
  }

  @override
  Future<GrowthEvent?> getLatestGrowthEvent(ChildId childId) async {
    final list = await listGrowthEvents(childId);
    return list.isEmpty ? null : list.first;
  }

  @override
  Future<List<GrowthEvent>> listGrowthEvents(ChildId childId) async {
    return growthEventsByVle.values.where((e) => e.childId == childId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<GrowthEvent?> getGrowthEventByAssessmentId(
    AssessmentId assessmentId,
  ) async {
    return growthEventsByAssessment[assessmentId.value];
  }

  final List<VerifiedLearningEvent> unprocessedEvents = [];

  @override
  Future<List<VerifiedLearningEvent>> getUnprocessedVerifiedEvents(
    FamilyId familyId,
  ) async {
    return unprocessedEvents.where((e) => e.familyId == familyId).toList();
  }

  @override
  Future<int> catchUpUnprocessedGrowth(FamilyId familyId) async {
    final toProcess = await getUnprocessedVerifiedEvents(familyId);
    for (final event in toProcess) {
      await processVerifiedLearningEvent(verifiedLearningEventId: event.id);
    }
    unprocessedEvents.removeWhere((e) => e.familyId == familyId);
    return toProcess.length;
  }
}

void main() {
  group('Growth Engine Application Use Cases', () {
    late FakeGrowthRepository repository;
    late ProcessVerifiedLearningEvent processUseCase;
    late GetChildBalance getBalanceUseCase;
    late GetLatestGrowthEvent getLatestUseCase;
    late ListGrowthEvents listGrowthUseCase;

    setUp(() {
      repository = FakeGrowthRepository();
      processUseCase = ProcessVerifiedLearningEvent(repository);
      getBalanceUseCase = GetChildBalance(repository);
      getLatestUseCase = GetLatestGrowthEvent(repository);
      listGrowthUseCase = ListGrowthEvents(repository);
    });

    test('ProcessVerifiedLearningEvent creates growth result, appends to ledgers and projects balance', () async {
      final childId = ChildId('child_1');

      // Before processing, balance is null
      expect(await getBalanceUseCase(childId), isNull);

      final event = await processUseCase(
        verifiedLearningEventId: 'vle_1',
        commandId: 'cmd_1',
      );

      // Verify calculation breakdown
      expect(event.normalizedScore, equals(7.50));
      expect(event.baselineScore, equals(6.43));
      expect(event.growthDelta, equals(1.07));
      expect(event.totalRpMinor.value, equals(1150));
      expect(event.totalRpMinor.formatRp(), equals('11.50'));
      expect(event.xpAwarded.value, equals(33));

      // Verify authoritative ledgers appended exactly once
      expect(repository.xpLedger.length, equals(1));
      expect(repository.xpLedger.first.amount.value, equals(33));
      expect(repository.rpLedger.length, equals(1));
      expect(repository.rpLedger.first.amountMinor.value, equals(1150));

      // Verify balance projection updated
      final balance = await getBalanceUseCase(childId);
      expect(balance, isNotNull);
      expect(balance!.xpTotal.value, equals(33));
      expect(balance.rpBalanceMinor.value, equals(1150));
    });

    test('ProcessVerifiedLearningEvent is idempotent on retry with same command or event ID', () async {
      final childId = ChildId('child_1');

      final event1 = await processUseCase(
        verifiedLearningEventId: 'vle_1',
        commandId: 'cmd_1',
      );

      final event2 = await processUseCase(
        verifiedLearningEventId: 'vle_1',
        commandId: 'cmd_1',
      );

      // Same instance / ID returned
      expect(event2.id, equals(event1.id));

      // Ledgers still have exactly 1 row
      expect(repository.xpLedger.length, equals(1));
      expect(repository.rpLedger.length, equals(1));

      // Balances did not double
      final balance = await getBalanceUseCase(childId);
      expect(balance!.xpTotal.value, equals(33));
      expect(balance.rpBalanceMinor.value, equals(1150));
    });

    test(
      'GetLatestGrowthEvent and ListGrowthEvents return chronological history',
      () async {
        final childId = ChildId('child_1');

        expect(await getLatestUseCase(childId), isNull);
        expect(await listGrowthUseCase(childId), isEmpty);

        final event = await processUseCase(verifiedLearningEventId: 'vle_1');

        final latest = await getLatestUseCase(childId);
        expect(latest, isNotNull);
        expect(latest!.id, equals(event.id));

        final list = await listGrowthUseCase(childId);
        expect(list.length, equals(1));
        expect(list.first.id, equals(event.id));
      },
    );

    test(
      'CatchUpUnprocessedGrowth processes all pending verified events',
      () async {
        final familyId = FamilyId('fam_1');
        final childId = ChildId('child_1');

        final catchUpUseCase = CatchUpUnprocessedGrowth(repository);

        // No events initially
        expect(await catchUpUseCase.execute(familyId), equals(0));

        // Add 2 unprocessed verified events
        repository.unprocessedEvents.addAll([
          VerifiedLearningEvent(
            id: 'vle_pending_1',
            familyId: familyId,
            childId: childId,
            assessmentId: AssessmentId('a1'),
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Quiz 1',
            type: AssessmentType.quiz,
            difficulty: AssessmentDifficulty.normal,
            score: AssessmentScore(rawScore: 8, maxScore: 10),
            evidenceCount: 1,
            entryContext: EntryContext.adult,
            occurredAt: DateTime.utc(2026, 11, 1),
            verifiedAt: DateTime.utc(2026, 11, 1),
            verifiedByUserId: 'user_1',
            reviewEventId: 'rev_1',
          ),
          VerifiedLearningEvent(
            id: 'vle_pending_2',
            familyId: familyId,
            childId: childId,
            assessmentId: AssessmentId('a2'),
            subjectKey: SubjectKey.math,
            subject: 'Math',
            title: 'Quiz 2',
            type: AssessmentType.quiz,
            difficulty: AssessmentDifficulty.normal,
            score: AssessmentScore(rawScore: 9, maxScore: 10),
            evidenceCount: 1,
            entryContext: EntryContext.adult,
            occurredAt: DateTime.utc(2026, 11, 1),
            verifiedAt: DateTime.utc(2026, 11, 1),
            verifiedByUserId: 'user_1',
            reviewEventId: 'rev_2',
          ),
        ]);

        // Catches up both
        final count = await catchUpUseCase.execute(familyId);
        expect(count, equals(2));

        // Subsequent catch-up has nothing left
        expect(await catchUpUseCase.execute(familyId), equals(0));
        expect(repository.growthEventsByVle.length, equals(2));
      },
    );
  });
}
