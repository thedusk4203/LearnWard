import 'package:learnward_application/learnward_application.dart';

/// Mutable [MonotonicClock] for deterministic elapsed-time tests.
final class TestMonotonicClock implements MonotonicClock {
  TestMonotonicClock([Duration initialElapsed = Duration.zero])
    : _elapsed = initialElapsed;

  Duration _elapsed;

  @override
  Duration elapsed() => _elapsed;

  /// Advances monotonic elapsed time by [delta] (negative values clamp to zero).
  void advance(Duration delta) {
    if (delta.isNegative) {
      return;
    }
    _elapsed += delta;
  }

  /// Sets monotonic elapsed time explicitly (never moves backwards).
  void setElapsed(Duration elapsed) {
    if (elapsed > _elapsed) {
      _elapsed = elapsed;
    }
  }
}
