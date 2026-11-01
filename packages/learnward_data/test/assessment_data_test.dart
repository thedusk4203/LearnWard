import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('Assessment Data Mapping', () {
    test('round-trip mapping correctly parses database response types', () {
      final now = DateTime.now().toUtc();
      final row = <String, dynamic>{
        'id': 'a1000000-0000-0000-0000-000000000001',
        'family_id': 'f1000000-0000-0000-0000-000000000001',
        'child_id': 'c1000000-0000-0000-0000-000000000001',
        'subject_key': 'math',
        'subject': 'Mathematics',
        'title': 'Midterm Exam',
        'assessment_type': 'exam',
        'difficulty': 'hard',
        'raw_score': 85.5,
        'max_score': 100.0,
        'normalized_score': 8.55,
        'status': 'verified',
        'version': 3,
        'entry_context': 'adult',
        'occurred_at': now.toIso8601String(),
        'created_by_user_id': 'u1000000-0000-0000-0000-000000000001',
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      };

      final rawScore = (row['raw_score'] as num).toDouble();
      final maxScore = (row['max_score'] as num).toDouble();

      final assessment = Assessment(
        id: AssessmentId(row['id'] as String),
        familyId: FamilyId(row['family_id'] as String),
        childId: ChildId(row['child_id'] as String),
        subjectKey: SubjectKey.parse(row['subject_key'] as String),
        subject: row['subject'] as String,
        title: row['title'] as String,
        type: AssessmentType.fromValue(row['assessment_type'] as String),
        difficulty: AssessmentDifficulty.fromValue(row['difficulty'] as String),
        score: AssessmentScore(rawScore: rawScore, maxScore: maxScore),
        entryContext: EntryContext.parse(row['entry_context'] as String),
        status: AssessmentStatus.fromValue(row['status'] as String),
        occurredAt: DateTime.parse(row['occurred_at'] as String),
        version: row['version'] as int,
        createdByUserId: row['created_by_user_id'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

      expect(
        assessment.id.value,
        equals('a1000000-0000-0000-0000-000000000001'),
      );
      expect(assessment.subjectKey, equals(SubjectKey.math));
      expect(assessment.type, equals(AssessmentType.exam));
      expect(assessment.difficulty, equals(AssessmentDifficulty.hard));
      expect(assessment.status, equals(AssessmentStatus.verified));
      expect(assessment.score.rawScore, equals(85.5));
      expect(assessment.score.serverNormalizedScore, equals(8.55));
    });

    test('evidence mapping parses size and paths properly', () {
      final now = DateTime.now().toUtc();
      final row = <String, dynamic>{
        'id': 'e1000000-0000-0000-0000-000000000001',
        'family_id': 'f1000000-0000-0000-0000-000000000001',
        'assessment_id': 'a1000000-0000-0000-0000-000000000001',
        'storage_path': 'f1/c1/a1/page.jpg',
        'media_type': 'image/jpeg',
        'file_size_bytes': 10240,
        'uploaded_by_user_id': 'u1000000-0000-0000-0000-000000000001',
        'created_at': now.toIso8601String(),
      };

      final evidence = AssessmentEvidence(
        id: EvidenceId(row['id'] as String),
        familyId: FamilyId(row['family_id'] as String),
        assessmentId: AssessmentId(row['assessment_id'] as String),
        storagePath: row['storage_path'] as String,
        mediaType: row['media_type'] as String,
        fileSizeBytes: row['file_size_bytes'] as int,
        uploadedByUserId: row['uploaded_by_user_id'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
      );

      expect(evidence.storagePath, equals('f1/c1/a1/page.jpg'));
      expect(evidence.fileSizeBytes, equals(10240));
    });
  });
}
