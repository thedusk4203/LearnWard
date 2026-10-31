import 'package:learnward_domain/learnward_domain.dart';

/// Application use case for the Growth Engine's score-normalization step.
///
/// Full Growth Engine rules arrive in a later phase. This use case exists in
/// Phase 0 to prove the application -> domain dependency direction and to give
/// future logic a single entry point.
final class NormalizeAssessmentScore {
  const NormalizeAssessmentScore();

  NormalizedScore call({required double rawScore, required double maxScore}) {
    return NormalizedScore.fromRaw(rawScore: rawScore, maxScore: maxScore);
  }
}
