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
