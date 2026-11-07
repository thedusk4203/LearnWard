import 'package:learnward_application/learnward_application.dart';

/// A mutable [Clock] for testing time progression and retry backoff.
final class TestClock implements Clock {
  TestClock(DateTime initialTime) : _current = initialTime;

  DateTime _current;

  @override
  DateTime now() => _current;

  void advance(Duration duration) {
    _current = _current.add(duration);
  }

  void setTime(DateTime time) {
    _current = time;
  }
}
