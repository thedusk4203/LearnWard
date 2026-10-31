import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('NormalizeAssessmentScore', () {
    test('orchestrates the domain value object', () {
      const useCase = NormalizeAssessmentScore();

      final score = useCase(rawScore: 15, maxScore: 20);

      expect(score, isA<NormalizedScore>());
      expect(score.value, closeTo(7.5, 1e-9));
    });

    test('propagates domain validation errors', () {
      const useCase = NormalizeAssessmentScore();

      expect(
        () => useCase(rawScore: 20, maxScore: 0),
        throwsA(isA<InvalidScoreException>()),
      );
    });
  });
}
