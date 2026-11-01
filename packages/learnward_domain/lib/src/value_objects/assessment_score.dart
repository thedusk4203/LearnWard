import '../exceptions/domain_exceptions.dart';
import 'normalized_score.dart';

/// Represents a validated academic score pair (raw score and maximum denominator).
final class AssessmentScore {
  AssessmentScore({required this.rawScore, required this.maxScore}) {
    if (!rawScore.isFinite || !maxScore.isFinite) {
      throw const InvalidAssessmentException('Scores must be finite numbers.');
    }
    if (maxScore <= 0) {
      throw const InvalidAssessmentException(
        'Maximum score must be greater than zero.',
      );
    }
    if (rawScore < 0) {
      throw const InvalidAssessmentException('Raw score cannot be negative.');
    }
    if (rawScore > maxScore) {
      throw const InvalidAssessmentException(
        'Raw score cannot exceed maximum score.',
      );
    }
  }

  final double rawScore;
  final double maxScore;

  /// Returns the score normalized to LearnWard 0–10 scale.
  NormalizedScore get normalized =>
      NormalizedScore.fromRaw(rawScore: rawScore, maxScore: maxScore);

  /// Normalized score rounded to 2 decimal places to match server PostgreSQL precision.
  double get serverNormalizedScore =>
      ((rawScore / maxScore * 10.0) * 100).round() / 100.0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssessmentScore &&
          other.rawScore == rawScore &&
          other.maxScore == maxScore;

  @override
  int get hashCode => Object.hash(rawScore, maxScore);

  @override
  String toString() => '$rawScore / $maxScore ($serverNormalizedScore/10)';
}
