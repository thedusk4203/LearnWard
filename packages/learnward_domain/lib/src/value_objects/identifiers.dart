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
