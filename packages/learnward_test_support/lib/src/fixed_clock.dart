import 'package:learnward_application/learnward_application.dart';

/// A [Clock] that always returns a fixed instant.
///
/// Use this in use-case tests so timestamps, idempotency and ledger ordering
/// stay deterministic.
final class FixedClock implements Clock {
  FixedClock(this.instant);

  final DateTime instant;

  @override
  DateTime now() => instant;
}
