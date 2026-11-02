import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('SupabaseLearningRepository Data Mapping', () {
    test(
      'AssessmentLearningMapping.fromJson strictly parses all 16 fields',
      () {
        final Map<String, dynamic> row = {
          'id': 'm0000000-0000-0000-0000-000000000001',
          'family_id': 'f0000000-0000-0000-0000-000000000001',
          'child_id': 'c0000000-0000-0000-0000-000000000001',
          'assessment_id': 'a0000000-0000-0000-0000-000000000001',
          'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
          'node_title': 'Single Digit Addition',
          'node_type': 'skill',
          'score_source': 'component_score',
          'component_key': 'addition_q1',
          'component_raw_score': 9.50,
          'component_max_score': 10.00,
          'item_count': null,
          'correct_count': null,
          'confirmed_by_user_id': 'u0000000-0000-0000-0000-000000000001',
          'created_at': '2026-11-02T10:00:00Z',
          'updated_at': '2026-11-02T10:05:00Z',
        };

        final mapping = AssessmentLearningMapping.fromJson(row);

        expect(mapping.id, equals('m0000000-0000-0000-0000-000000000001'));
        expect(
          mapping.familyId,
          equals(FamilyId('f0000000-0000-0000-0000-000000000001')),
        );
        expect(
          mapping.childId,
          equals(ChildId('c0000000-0000-0000-0000-000000000001')),
        );
        expect(
          mapping.assessmentId,
          equals(AssessmentId('a0000000-0000-0000-0000-000000000001')),
        );
        expect(
          mapping.learningNodeId,
          equals(LearningNodeId('n0000000-0000-0000-0000-000000000001')),
        );
        expect(mapping.nodeTitle, equals('Single Digit Addition'));
        expect(mapping.nodeType, equals(LearningNodeType.skill));
        expect(mapping.scoreSource, equals(ScoreSource.componentScore));
        expect(mapping.componentKey, equals('addition_q1'));
        expect(mapping.componentRawScore, equals(9.50));
        expect(mapping.componentMaxScore, equals(10.00));
        expect(mapping.rawScore, equals(9.50));
        expect(mapping.maxScore, equals(10.00));
        expect(mapping.itemCount, isNull);
        expect(mapping.correctCount, isNull);
        expect(
          mapping.confirmedByUserId,
          equals('u0000000-0000-0000-0000-000000000001'),
        );
        expect(mapping.createdAt, equals(DateTime.utc(2026, 11, 2, 10, 0, 0)));
        expect(mapping.updatedAt, equals(DateTime.utc(2026, 11, 2, 10, 5, 0)));
      },
    );

    test('AssessmentLearningMapping.fromJson strictly rejects missing id', () {
      final Map<String, dynamic> row = {
        'family_id': 'f0000000-0000-0000-0000-000000000001',
        'child_id': 'c0000000-0000-0000-0000-000000000001',
        'assessment_id': 'a0000000-0000-0000-0000-000000000001',
        'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
        'score_source': 'component_score',
        'component_key': 'q1',
        'confirmed_by_user_id': 'u0000000-0000-0000-0000-000000000001',
        'created_at': '2026-11-02T10:00:00Z',
        'updated_at': '2026-11-02T10:05:00Z',
      };

      expect(
        () => AssessmentLearningMapping.fromJson(row),
        throwsA(isA<FormatException>()),
      );
    });

    test('AssessmentLearningMapping.fromJson strictly rejects missing confirmed_by_user_id', () {
      final Map<String, dynamic> row = {
        'id': 'm0000000-0000-0000-0000-000000000001',
        'family_id': 'f0000000-0000-0000-0000-000000000001',
        'child_id': 'c0000000-0000-0000-0000-000000000001',
        'assessment_id': 'a0000000-0000-0000-0000-000000000001',
        'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
        'score_source': 'component_score',
        'component_key': 'q1',
        'created_at': '2026-11-02T10:00:00Z',
        'updated_at': '2026-11-02T10:05:00Z',
      };

      expect(
        () => AssessmentLearningMapping.fromJson(row),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'AssessmentLearningMapping.fromJson strictly rejects missing created_at',
      () {
        final Map<String, dynamic> row = {
          'id': 'm0000000-0000-0000-0000-000000000001',
          'family_id': 'f0000000-0000-0000-0000-000000000001',
          'child_id': 'c0000000-0000-0000-0000-000000000001',
          'assessment_id': 'a0000000-0000-0000-0000-000000000001',
          'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
          'score_source': 'component_score',
          'component_key': 'q1',
          'confirmed_by_user_id': 'u0000000-0000-0000-0000-000000000001',
          'updated_at': '2026-11-02T10:05:00Z',
        };

        expect(
          () => AssessmentLearningMapping.fromJson(row),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'AssessmentLearningMapping.fromJson strictly rejects missing updated_at',
      () {
        final Map<String, dynamic> row = {
          'id': 'm0000000-0000-0000-0000-000000000001',
          'family_id': 'f0000000-0000-0000-0000-000000000001',
          'child_id': 'c0000000-0000-0000-0000-000000000001',
          'assessment_id': 'a0000000-0000-0000-0000-000000000001',
          'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
          'score_source': 'component_score',
          'component_key': 'q1',
          'confirmed_by_user_id': 'u0000000-0000-0000-0000-000000000001',
          'created_at': '2026-11-02T10:00:00Z',
        };

        expect(
          () => AssessmentLearningMapping.fromJson(row),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'AssessmentLearningMapping.fromJson strictly rejects missing family_id',
      () {
        final Map<String, dynamic> row = {
          'id': 'm0000000-0000-0000-0000-000000000001',
          'child_id': 'c0000000-0000-0000-0000-000000000001',
          'assessment_id': 'a0000000-0000-0000-0000-000000000001',
          'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
          'score_source': 'component_score',
          'component_key': 'q1',
          'confirmed_by_user_id': 'u0000000-0000-0000-0000-000000000001',
          'created_at': '2026-11-02T10:00:00Z',
          'updated_at': '2026-11-02T10:05:00Z',
        };

        expect(
          () => AssessmentLearningMapping.fromJson(row),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'AssessmentLearningMapping.fromJson strictly rejects missing child_id',
      () {
        final Map<String, dynamic> row = {
          'id': 'm0000000-0000-0000-0000-000000000001',
          'family_id': 'f0000000-0000-0000-0000-000000000001',
          'assessment_id': 'a0000000-0000-0000-0000-000000000001',
          'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
          'score_source': 'component_score',
          'component_key': 'q1',
          'confirmed_by_user_id': 'u0000000-0000-0000-0000-000000000001',
          'created_at': '2026-11-02T10:00:00Z',
          'updated_at': '2026-11-02T10:05:00Z',
        };

        expect(
          () => AssessmentLearningMapping.fromJson(row),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('ChildMasteryProjection.fromJson strictly parses server-authoritative as_of', () {
      final Map<String, dynamic> row = {
        'child_id': 'c0000000-0000-0000-0000-000000000001',
        'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
        'node_canonical_key': 'pilot-v0.1:math:addition',
        'node_title': 'Addition',
        'node_type': 'skill',
        'subject_key': 'math',
        'mastery_score': 88.5,
        'distinct_assessment_count': 3,
        'last_evidence_occurred_at': '2026-11-02T08:00:00Z',
        'confidence_band': 'high',
        'confidence_units': 4.25,
        'mastery_band': 'mastered',
        'mastery_attained_at': '2026-11-01T15:00:00Z',
        'as_of': '2026-11-02T12:00:00Z',
        'updated_at': '2026-11-02T09:00:00Z',
      };

      final projection = ChildMasteryProjection.fromJson(row);

      expect(
        projection.childId,
        equals(ChildId('c0000000-0000-0000-0000-000000000001')),
      );
      expect(
        projection.learningNodeId,
        equals(LearningNodeId('n0000000-0000-0000-0000-000000000001')),
      );
      expect(projection.masteryScore, equals(88.5));
      expect(projection.confidenceBand, equals(ConfidenceBand.high));
      expect(projection.confidenceUnits, equals(4.25));
      expect(projection.masteryBand, equals(MasteryBand.mastered));
      expect(
        projection.masteryAttainedAt,
        equals(DateTime.utc(2026, 11, 1, 15, 0, 0)),
      );
      expect(projection.asOf, equals(DateTime.utc(2026, 11, 2, 12, 0, 0)));
      expect(projection.updatedAt, equals(DateTime.utc(2026, 11, 2, 9, 0, 0)));
    });

    test('ChildMasteryProjection.fromJson strictly rejects missing as_of', () {
      final Map<String, dynamic> row = {
        'child_id': 'c0000000-0000-0000-0000-000000000001',
        'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
        'node_canonical_key': 'pilot-v0.1:math:addition',
        'node_title': 'Addition',
        'node_type': 'skill',
        'subject_key': 'math',
        'mastery_score': 88.5,
        'distinct_assessment_count': 3,
        'last_evidence_occurred_at': '2026-11-02T08:00:00Z',
        'confidence_band': 'high',
        'confidence_units': 4.25,
        'mastery_band': 'mastered',
        'updated_at': '2026-11-02T09:00:00Z',
      };

      expect(
        () => ChildMasteryProjection.fromJson(row),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'ChildMasteryProjection.fromJson strictly rejects missing updated_at',
      () {
        final Map<String, dynamic> row = {
          'child_id': 'c0000000-0000-0000-0000-000000000001',
          'learning_node_id': 'n0000000-0000-0000-0000-000000000001',
          'node_canonical_key': 'pilot-v0.1:math:addition',
          'node_title': 'Addition',
          'node_type': 'skill',
          'subject_key': 'math',
          'mastery_score': 88.5,
          'distinct_assessment_count': 3,
          'last_evidence_occurred_at': '2026-11-02T08:00:00Z',
          'confidence_band': 'high',
          'confidence_units': 4.25,
          'mastery_band': 'mastered',
          'as_of': '2026-11-02T12:00:00Z',
        };

        expect(
          () => ChildMasteryProjection.fromJson(row),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });
}
