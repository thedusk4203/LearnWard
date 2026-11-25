/// Supplies the current time to application use cases.
///
/// Injecting time keeps use cases deterministic in tests and allows later
/// economy records to be reproducible.
abstract interface class Clock {
  DateTime now();
}

/// Monotonic elapsed-time source immune to wall-clock adjustments.
abstract interface class MonotonicClock {
  /// Returns a monotonically non-decreasing elapsed duration.
  Duration elapsed();
}

/// Production [MonotonicClock] backed by a running Dart [Stopwatch].
final class StopwatchMonotonicClock implements MonotonicClock {
  StopwatchMonotonicClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration elapsed() => _stopwatch.elapsed;
}

/// Production [Clock] backed by the system clock.
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}
