/// A score normalized to LearnWard's 0–10 scale.
///
/// The original raw score and maximum score remain available to callers; this
/// value object only represents the derived, comparable score defined by the
/// Growth Engine v0.1 (`raw / max * 10`).
final class NormalizedScore {
  const NormalizedScore._(this.value);

  /// Creates a normalized score from a raw score and its maximum.
  ///
  /// Throws [InvalidScoreException] when the inputs are not finite, when the
  /// maximum is not positive, or when the raw score falls outside `0..max`.
  factory NormalizedScore.fromRaw({
    required double rawScore,
    required double maxScore,
  }) {
    if (!rawScore.isFinite || !maxScore.isFinite) {
      throw const InvalidScoreException('Scores must be finite numbers.');
    }
    if (maxScore <= 0) {
      throw const InvalidScoreException(
        'Maximum score must be greater than zero.',
      );
    }
    if (rawScore < 0 || rawScore > maxScore) {
      throw const InvalidScoreException(
        'Raw score must be between zero and the maximum score.',
      );
    }

    return NormalizedScore._(rawScore / maxScore * maximum);
  }

  /// The upper bound of the normalized scale.
  static const double maximum = 10;

  /// The lower bound of the normalized scale.
  static const double minimum = 0;

  /// The normalized value in the inclusive range [minimum]..[maximum].
  final double value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NormalizedScore && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'NormalizedScore(${value.toStringAsFixed(2)}/10)';
}

/// Raised when score input violates LearnWard's domain invariants.
final class InvalidScoreException implements Exception {
  const InvalidScoreException(this.message);

  final String message;

  @override
  String toString() => 'InvalidScoreException: $message';
}
