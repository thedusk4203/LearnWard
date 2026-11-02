import '../exceptions/domain_exceptions.dart';

/// Strongly-typed identifier for a [Family].
final class FamilyId {
  FamilyId(this.value) {
    if (value.trim().isEmpty) {
      throw const InvalidFamilyException('FamilyId cannot be empty.');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FamilyId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Strongly-typed identifier for a [ChildProfile].
final class ChildId {
  ChildId(this.value) {
    if (value.trim().isEmpty) {
      throw const InvalidChildProfileException('ChildId cannot be empty.');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ChildId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Strongly-typed identifier for an [Assessment].
final class AssessmentId {
  AssessmentId(this.value) {
    if (value.trim().isEmpty) {
      throw const InvalidAssessmentException('AssessmentId cannot be empty.');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AssessmentId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Strongly-typed identifier for an [AssessmentEvidence].
final class EvidenceId {
  EvidenceId(this.value) {
    if (value.trim().isEmpty) {
      throw const InvalidAssessmentException('EvidenceId cannot be empty.');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is EvidenceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Strongly-typed identifier for a [Reward].
final class RewardId {
  RewardId(this.value) {
    if (value.trim().isEmpty) {
      throw const InvalidRewardException('RewardId cannot be empty.');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is RewardId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Strongly-typed identifier for a [RewardRedemption].
final class RewardRedemptionId {
  RewardRedemptionId(this.value) {
    if (value.trim().isEmpty) {
      throw const InvalidRedemptionException(
        'RewardRedemptionId cannot be empty.',
      );
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RewardRedemptionId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Strongly-typed identifier for a [WheelSpin].
final class WheelSpinId {
  WheelSpinId(this.value) {
    if (value.trim().isEmpty) {
      throw const InvalidWheelException('WheelSpinId cannot be empty.');
    }
  }

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is WheelSpinId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
