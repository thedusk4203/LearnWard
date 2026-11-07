import 'dart:math';

/// Supplies uniform pseudorandom fractions [0.0, 1.0) for full-jitter backoff calculation.
abstract interface class JitterSource {
  double sampleUniform();
}

/// Production [JitterSource] backed by [Random].
final class RandomJitterSource implements JitterSource {
  RandomJitterSource([Random? random]) : _random = random ?? Random();
  final Random _random;

  @override
  double sampleUniform() => _random.nextDouble();
}

/// Deterministic [JitterSource] for reproducible tests.
final class DeterministicJitterSource implements JitterSource {
  const DeterministicJitterSource([this.fraction = 0.0]);
  final double fraction;

  @override
  double sampleUniform() => fraction.clamp(0.0, 1.0);
}
