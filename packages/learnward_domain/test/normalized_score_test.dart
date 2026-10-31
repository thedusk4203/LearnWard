import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('NormalizedScore', () {
    test('normalizes a raw score onto the 0-10 scale', () {
      final score = NormalizedScore.fromRaw(rawScore: 15, maxScore: 20);

      expect(score.value, closeTo(7.5, 1e-9));
      expect(
        score.value,
        inInclusiveRange(NormalizedScore.minimum, NormalizedScore.maximum),
      );
    });

    test('supports the boundaries of the scale', () {
      expect(NormalizedScore.fromRaw(rawScore: 0, maxScore: 20).value, 0);
      expect(NormalizedScore.fromRaw(rawScore: 20, maxScore: 20).value, 10);
    });

    test('rejects non-positive maximum scores', () {
      expect(
        () => NormalizedScore.fromRaw(rawScore: 1, maxScore: 0),
        throwsA(isA<InvalidScoreException>()),
      );
    });

    test('rejects raw scores outside the maximum', () {
      expect(
        () => NormalizedScore.fromRaw(rawScore: 11, maxScore: 10),
        throwsA(isA<InvalidScoreException>()),
      );
      expect(
        () => NormalizedScore.fromRaw(rawScore: -1, maxScore: 10),
        throwsA(isA<InvalidScoreException>()),
      );
    });

    test('rejects non-finite input', () {
      expect(
        () => NormalizedScore.fromRaw(rawScore: double.nan, maxScore: 10),
        throwsA(isA<InvalidScoreException>()),
      );
      expect(
        () => NormalizedScore.fromRaw(rawScore: 5, maxScore: double.infinity),
        throwsA(isA<InvalidScoreException>()),
      );
    });

    test('is a value object', () {
      final first = NormalizedScore.fromRaw(rawScore: 7, maxScore: 10);
      final second = NormalizedScore.fromRaw(rawScore: 14, maxScore: 20);

      expect(first, second);
      expect(first.hashCode, second.hashCode);
    });
  });
}
