import 'package:learnward_domain/learnward_domain.dart';

/// Application port for Celebration Wheel operations, configuration and spin history.
abstract interface class WheelRepository {
  /// Retrieves parental wheel settings for the given family.
  Future<WheelSettings> getWheelSettings({required FamilyId familyId});

  /// Updates parental wheel settings (spin cost, daily cap, enabled toggle).
  Future<WheelSettings> updateWheelSettings(WheelSettings settings);

  /// Lists active eligible Wheel rewards for a given child within a family.
  Future<List<Reward>> listWheelRewards({
    required FamilyId familyId,
    ChildId? childId,
  });

  /// Server-authoritatively spins the wheel for a child with durable command idempotency.
  Future<WheelSpinResult> spinRewardWheel({
    required String commandId,
    required ChildId childId,
  });

  /// Lists past wheel spins for a child or whole family.
  Future<List<WheelSpin>> listWheelSpins({
    required FamilyId familyId,
    ChildId? childId,
    int? limit,
  });

  /// Returns the number of spins already performed by the child in today's local calendar day.
  Future<int> getTodaySpinCount({
    required FamilyId familyId,
    required ChildId childId,
  });

  /// Returns server-authoritative Wheel status (daily cap, spins today, spins remaining, is_enabled)
  /// calculated based on the family's authoritative timezone.
  Future<WheelStatus> getWheelStatus({
    required FamilyId familyId,
    required ChildId childId,
  });
}
