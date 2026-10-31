/// Application use cases and ports for LearnWard.
///
/// This package orchestrates domain rules and declares the interfaces that
/// infrastructure adapters implement. It must not depend on Flutter, Supabase,
/// Drift or Riverpod.
library;

export 'src/ports/clock.dart';
export 'src/use_cases/normalize_assessment_score.dart';
