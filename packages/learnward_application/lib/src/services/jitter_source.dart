import 'dart:math';

/// Supplies uniform pseudorandom fractions [0.0, 1.0) for full-jitter backoff calculation.
abstract interface class JitterSource {
  double sampleUniform();
}

/// Production [JitterSource] backed by [Random].
final class RandomJitterSource implements JitterSource {
  const RandomJitterSource([Random? random]) : _random = random;
  final Random? _random;

  static final Random _defaultRandom = Random();

  @override
  double sampleUniform() => (_random ?? _defaultRandom).nextDouble();
}

/// Deterministic [JitterSource] for reproducible tests.
final class DeterministicJitterSource implements JitterSource {
  const DeterministicJitterSource([this.fraction = 0.0]);
  final double fraction;

  @override
  double sampleUniform() => fraction.clamp(0.0, 1.0);
}

/// Computes bounded exponential backoff with full jitter for 1-based retry [attempt].
///
/// Shared between recovery and assessment submission retry scheduling so
/// injected [JitterSource] instances produce deterministic `nextAttemptAt`
/// timestamps.
Duration calculateJitteredBackoff(
  int attempt, {
  required JitterSource jitterSource,
  double baseSeconds = 2.0,
  double capSeconds = 60.0,
  double minFloorSeconds = 1.0,
}) {
  final effectiveAttempt = attempt < 1 ? 1 : attempt;
  final boundedCap = min(
    capSeconds,
    baseSeconds * pow(2.0, effectiveAttempt - 1),
  );
  var waitSeconds = jitterSource.sampleUniform() * boundedCap;

  if (jitterSource is! DeterministicJitterSource &&
      waitSeconds < minFloorSeconds) {
    waitSeconds = minFloorSeconds;
  }

  return Duration(milliseconds: (waitSeconds * 1000).toInt());
}
