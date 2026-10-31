/// Supplies the current time to application use cases.
///
/// Injecting time keeps use cases deterministic in tests and allows later
/// economy records to be reproducible.
abstract interface class Clock {
  DateTime now();
}

/// Production [Clock] backed by the system clock.
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}
