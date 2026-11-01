import '../exceptions/domain_exceptions.dart';
import '../value_objects/identifiers.dart';

/// Pure domain entity representing parental wheel configurations for a family.
final class WheelSettings {
  WheelSettings({
    required this.familyId,
    this.spinCostMinor = defaultSpinCostMinor,
    this.dailySpinCap = defaultDailySpinCap,
    this.isEnabled = true,
    required this.createdAt,
    required this.updatedAt,
  }) {
    if (spinCostMinor < minSpinCostMinor || spinCostMinor > maxSpinCostMinor) {
      throw const InvalidWheelException(
        'Spin cost must be between 500 and 5000 minor RP units (5 to 50 RP).',
      );
    }
    if (dailySpinCap < minDailySpinCap || dailySpinCap > maxDailySpinCap) {
      throw const InvalidWheelException(
        'Daily spin cap must be between 1 and 5 spins per child.',
      );
    }
  }

  static const int defaultSpinCostMinor = 1000;
  static const int minSpinCostMinor = 500;
  static const int maxSpinCostMinor = 5000;

  static const int defaultDailySpinCap = 3;
  static const int minDailySpinCap = 1;
  static const int maxDailySpinCap = 5;

  final FamilyId familyId;
  final int spinCostMinor;
  final int dailySpinCap;
  final bool isEnabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Spin cost in whole RP units (e.g. 10.0 RP).
  double get spinCostRp => spinCostMinor / 100.0;

  WheelSettings copyWith({
    int? spinCostMinor,
    int? dailySpinCap,
    bool? isEnabled,
    DateTime? updatedAt,
  }) {
    return WheelSettings(
      familyId: familyId,
      spinCostMinor: spinCostMinor ?? this.spinCostMinor,
      dailySpinCap: dailySpinCap ?? this.dailySpinCap,
      isEnabled: isEnabled ?? this.isEnabled,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory WheelSettings.fromJson(Map<String, dynamic> json) {
    return WheelSettings(
      familyId: FamilyId(json['family_id'] as String),
      spinCostMinor: json['spin_cost_minor'] as int? ?? defaultSpinCostMinor,
      dailySpinCap: json['daily_spin_cap'] as int? ?? defaultDailySpinCap,
      isEnabled: json['is_enabled'] as bool? ?? true,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'family_id': familyId.value,
      'spin_cost_minor': spinCostMinor,
      'daily_spin_cap': dailySpinCap,
      'is_enabled': isEnabled,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WheelSettings &&
          other.familyId == familyId &&
          other.spinCostMinor == spinCostMinor &&
          other.dailySpinCap == dailySpinCap &&
          other.isEnabled == isEnabled;

  @override
  int get hashCode =>
      Object.hash(familyId, spinCostMinor, dailySpinCap, isEnabled);
}
