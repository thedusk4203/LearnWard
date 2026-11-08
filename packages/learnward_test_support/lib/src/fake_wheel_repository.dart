import 'dart:math';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Test double for [WheelRepository] with deterministic control, replay idempotency,
/// and simulated network failure modes.
final class FakeWheelRepository implements WheelRepository {
  FakeWheelRepository({
    Map<String, WheelSettings>? initialSettings,
    List<Reward>? initialRewards,
    this.randomSeed,
  }) {
    if (initialSettings != null) {
      _settings.addAll(initialSettings);
    }
    if (initialRewards != null) {
      _rewards.addAll(initialRewards);
    }
    _rng = randomSeed != null ? Random(randomSeed) : Random();
  }

  final int? randomSeed;
  final Map<String, WheelSettings> _settings = {};
  final List<Reward> _rewards = [];
  final List<WheelSpin> _spins = [];
  final Map<String, WheelSpinResult> _receipts = {};

  WheelSpinResult? get lastCommittedResult =>
      _receipts.values.isEmpty ? null : _receipts.values.last;

  int spinCallCount = 0;

  late final Random _rng;

  /// Simulated failure modes for durability & recovery tests.
  bool failNextWithNetwork = false;
  bool failAfterCommitResponseLost = false;
  bool failNextWithPermissionError = false;
  bool failWithInvalidWheel = false;

  void addReward(Reward reward) => _rewards.add(reward);

  void setSettings(String familyId, WheelSettings settings) =>
      _settings[familyId] = settings;

  @override
  Future<WheelSettings> getWheelSettings({required FamilyId familyId}) async {
    final existing = _settings[familyId.value];
    if (existing != null) return existing;

    final defaultSettings = WheelSettings(
      familyId: familyId,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    _settings[familyId.value] = defaultSettings;
    return defaultSettings;
  }

  @override
  Future<WheelSettings> updateWheelSettings(WheelSettings settings) async {
    _settings[settings.familyId.value] = settings;
    return settings;
  }

  @override
  Future<List<Reward>> listWheelRewards({
    required FamilyId familyId,
    ChildId? childId,
  }) async {
    return _rewards.where((r) {
      if (r.familyId != familyId) return false;
      if (!r.isActive || !r.wheelEnabled || r.wheelTier == null) return false;
      if (childId != null && !r.isEligibleFor(childId)) return false;
      return true;
    }).toList();
  }

  @override
  Future<int> getTodaySpinCount({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    final now = DateTime.now().toUtc();
    final todayStart = DateTime.utc(now.year, now.month, now.day);
    final tomorrowStart = todayStart.add(const Duration(days: 1));

    return _spins.where((s) {
      return s.familyId == familyId &&
          s.childId == childId &&
          s.createdAt.isAfter(
            todayStart.subtract(const Duration(milliseconds: 1)),
          ) &&
          s.createdAt.isBefore(tomorrowStart);
    }).length;
  }

  @override
  Future<WheelStatus> getWheelStatus({
    required FamilyId familyId,
    required ChildId childId,
  }) async {
    final settings = await getWheelSettings(familyId: familyId);
    final spinsToday = await getTodaySpinCount(
      familyId: familyId,
      childId: childId,
    );
    final eligibleRewards = await listWheelRewards(
      familyId: familyId,
      childId: childId,
    );
    final now = DateTime.now().toUtc();
    final todayStart = DateTime.utc(now.year, now.month, now.day);
    final todayEnd = todayStart.add(const Duration(days: 1));

    return WheelStatus(
      familyId: familyId,
      childId: childId,
      spinCostMinor: settings.spinCostMinor,
      dailySpinCap: settings.dailySpinCap,
      isEnabled: settings.isEnabled,
      spinsToday: spinsToday,
      spinsRemaining: max(0, settings.dailySpinCap - spinsToday),
      eligibleRewardCount: eligibleRewards.length,
      localDayStart: todayStart,
      localDayEnd: todayEnd,
    );
  }

  @override
  Future<List<WheelSpin>> listWheelSpins({
    required FamilyId familyId,
    ChildId? childId,
    int? limit,
  }) async {
    final list = _spins.where((s) {
      if (s.familyId != familyId) return false;
      if (childId != null && s.childId != childId) return false;
      return true;
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    if (limit != null && list.length > limit) {
      return list.sublist(0, limit);
    }
    return list;
  }

  @override
  Future<WheelSpinResult> spinRewardWheel({
    required String commandId,
    required ChildId childId,
  }) async {
    // 1. Replay check
    final existingResult = _receipts[commandId];
    if (existingResult != null) {
      return existingResult;
    }

    spinCallCount++;

    // 2. Simulated network failure before server execution
    if (failNextWithNetwork) {
      failNextWithNetwork = false;
      throw Exception(
        'NetworkException: Connection timeout before reaching server',
      );
    }

    if (failNextWithPermissionError) {
      failNextWithPermissionError = false;
      throw Exception('PostgreSQL error 42501: permission denied');
    }

    if (failWithInvalidWheel) {
      failWithInvalidWheel = false;
      throw const InvalidWheelException('Wheel is disabled (LW206)');
    }

    // 3. Resolve family & settings
    final eligibleRewards = _rewards
        .where(
          (r) =>
              r.isActive &&
              r.wheelEnabled &&
              r.wheelTier != null &&
              r.isEligibleFor(childId),
        )
        .toList();

    if (eligibleRewards.isEmpty) {
      throw const InvalidWheelException('No rewards found for child profile');
    }

    final familyId = eligibleRewards.first.familyId;
    final settings = await getWheelSettings(familyId: familyId);

    if (!settings.isEnabled) {
      throw const InvalidWheelException(
        'Wheel is currently disabled for this family (LW206)',
      );
    }

    if (eligibleRewards.length < 3) {
      throw InvalidWheelException(
        'Wheel requires at least 3 active eligible rewards (LW203). Found: ${eligibleRewards.length}',
      );
    }

    final todaySpins = await getTodaySpinCount(
      familyId: familyId,
      childId: childId,
    );
    if (todaySpins >= settings.dailySpinCap) {
      throw InvalidWheelException(
        'Daily spin limit reached ($todaySpins/${settings.dailySpinCap}) (LW202)',
      );
    }

    // 4. Calculate deterministic intervals & draw winner
    eligibleRewards.sort((a, b) => a.id.value.compareTo(b.id.value));
    final totalWeight = eligibleRewards.fold<int>(
      0,
      (sum, r) => sum + r.wheelTier!.relativeWeight,
    );

    final randomDraw = _rng.nextInt(totalWeight);
    int cumulative = 0;
    Reward? winningReward;
    final List<WheelPoolItem> poolItems = [];

    for (final reward in eligibleRewards) {
      final weight = reward.wheelTier!.relativeWeight;
      final start = cumulative;
      final end = cumulative + weight;
      final probPct = double.parse(
        ((weight / totalWeight) * 100.0).toStringAsFixed(2),
      );

      poolItems.add(
        WheelPoolItem(
          rewardId: reward.id,
          title: reward.title,
          category: reward.category,
          iconKey: reward.iconKey,
          tier: reward.wheelTier!,
          weight: weight,
          intervalStart: start,
          intervalEnd: end,
          probabilityPct: probPct,
        ),
      );

      if (randomDraw >= start && randomDraw < end) {
        winningReward = reward;
      }
      cumulative = end;
    }

    final now = DateTime.now().toUtc();
    final spinId = WheelSpinId('spin-${_spins.length + 1}');
    final redemptionId = RewardRedemptionId('redemp-${_spins.length + 1}');

    final snapshot = WheelSelectionSnapshot(
      wheelConfigVersion: 'wheel-v0.1',
      spinCostMinor: settings.spinCostMinor,
      deterministicOrdering: 'reward_id_asc',
      totalWeight: totalWeight,
      randomDraw: randomDraw,
      winningRewardId: winningReward!.id,
      orderedPool: poolItems,
    );

    final spin = WheelSpin(
      id: spinId,
      familyId: familyId,
      childId: childId,
      rewardId: winningReward.id,
      redemptionId: redemptionId,
      origin: RewardOrigin.wheel,
      spinCostMinor: settings.spinCostMinor,
      selectionSnapshot: snapshot,
      createdAt: now,
    );
    _spins.add(spin);

    final result = WheelSpinResult(
      spinId: spinId,
      redemptionId: redemptionId,
      familyId: familyId,
      childId: childId,
      rewardId: winningReward.id,
      rewardTitle: winningReward.title,
      rewardCategory: winningReward.category,
      rewardIconKey: winningReward.iconKey,
      wheelTier: winningReward.wheelTier!,
      spinCostMinor: settings.spinCostMinor,
      newBalanceMinor: 3000, // simulated updated balance
      selectionSnapshot: snapshot,
      createdAt: now,
    );

    _receipts[commandId] = result;

    // 5. Simulated commit-response lost failure
    if (failAfterCommitResponseLost) {
      failAfterCommitResponseLost = false;
      throw Exception(
        'SocketException: Connection lost while reading response after commit',
      );
    }

    return result;
  }
}
