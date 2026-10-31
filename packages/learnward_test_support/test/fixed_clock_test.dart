import 'package:learnward_test_support/learnward_test_support.dart';
import 'package:test/test.dart';

void main() {
  test('FixedClock always returns the supplied instant', () {
    final instant = DateTime.utc(2026, 10, 31, 12);
    final clock = FixedClock(instant);

    expect(clock.now(), instant);
    expect(clock.now(), same(instant));
  });
}
