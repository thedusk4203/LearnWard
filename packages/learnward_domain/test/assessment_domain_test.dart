import 'package:learnward_domain/learnward_domain.dart';
import 'package:test/test.dart';

void main() {
  group('SubjectKey', () {
    test('parses canonical keys case-insensitively with trim', () {
      expect(SubjectKey.parse('math'), equals(SubjectKey.math));
      expect(SubjectKey.parse('  MATH  '), equals(SubjectKey.math));
      expect(SubjectKey.parse('english'), equals(SubjectKey.english));
      expect(SubjectKey.parse('literature'), equals(SubjectKey.literature));
      expect(SubjectKey.parse('science'), equals(SubjectKey.science));
      expect(SubjectKey.parse('other'), equals(SubjectKey.other));
    });

    test('provides human-friendly default labels', () {
      expect(SubjectKey.math.defaultLabel, equals('Mathematics'));
      expect(SubjectKey.english.defaultLabel, equals('English'));
      expect(SubjectKey.literature.defaultLabel, equals('Literature'));
      expect(SubjectKey.science.defaultLabel, equals('Science'));
      expect(SubjectKey.other.defaultLabel, equals('Other'));
    });

    test('rejects uncanonical subject key', () {
      expect(() => SubjectKey.parse('biology'), throwsArgumentError);
      expect(() => SubjectKey.parse(''), throwsArgumentError);
    });
  });

  group('EntryContext', () {
    test('parses canonical entry contexts', () {
      expect(EntryContext.parse('adult'), equals(EntryContext.adult));
      expect(
        EntryContext.parse('shared_child'),
        equals(EntryContext.sharedChild),
      );
      expect(
        EntryContext.parse('paired_child'),
        equals(EntryContext.pairedChild),
      );
    });

    test('rejects unknown entry context', () {
      expect(() => EntryContext.parse('hacker'), throwsArgumentError);
    });
  });

  group('AssessmentScore', () {
    test('computes normalized score correctly', () {
      final score = AssessmentScore(rawScore: 8.5, maxScore: 10.0);
      expect(score.normalized.value, closeTo(8.5, 0.001));
      expect(score.serverNormalizedScore, equals(8.5));
    });

    test('rounds normalized score to 2 decimal places', () {
      final score = AssessmentScore(rawScore: 7.0, maxScore: 9.0);
      // 7 / 9 * 10 = 7.777777... -> 7.78
      expect(score.serverNormalizedScore, equals(7.78));
    });

    test('rejects negative raw scores', () {
      expect(
        () => AssessmentScore(rawScore: -1, maxScore: 10),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });

    test('rejects maxScore <= 0', () {
      expect(
        () => AssessmentScore(rawScore: 0, maxScore: 0),
        throwsA(isA<InvalidAssessmentException>()),
      );
      expect(
        () => AssessmentScore(rawScore: 0, maxScore: -5),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });

    test('rejects rawScore > maxScore', () {
      expect(
        () => AssessmentScore(rawScore: 11, maxScore: 10),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });

    test('rejects non-finite values', () {
      expect(
        () => AssessmentScore(rawScore: double.nan, maxScore: 10),
        throwsA(isA<InvalidAssessmentException>()),
      );
      expect(
        () => AssessmentScore(rawScore: 5, maxScore: double.infinity),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });
  });

  group('Assessment Entity', () {
    final validAssessment = Assessment(
      id: AssessmentId('a-1'),
      familyId: FamilyId('f-1'),
      childId: ChildId('c-1'),
      subjectKey: SubjectKey.math,
      subject: 'Math',
      title: 'Algebra Quiz',
      type: AssessmentType.quiz,
      score: AssessmentScore(rawScore: 9, maxScore: 10),
      entryContext: EntryContext.adult,
      occurredAt: DateTime.utc(2026, 11, 1),
      createdByUserId: 'u-1',
      createdAt: DateTime.utc(2026, 11, 1),
      updatedAt: DateTime.utc(2026, 11, 1),
    );

    test('creates valid assessment draft', () {
      expect(validAssessment.subjectKey, equals(SubjectKey.math));
      expect(validAssessment.subject, equals('Math'));
      expect(validAssessment.title, equals('Algebra Quiz'));
      expect(validAssessment.entryContext, equals(EntryContext.adult));
      expect(validAssessment.status, equals(AssessmentStatus.draft));
      expect(validAssessment.version, equals(1));
    });

    test('rejects empty or whitespace subject', () {
      expect(
        () => Assessment(
          id: AssessmentId('a-1'),
          familyId: FamilyId('f-1'),
          childId: ChildId('c-1'),
          subjectKey: SubjectKey.math,
          subject: '   ',
          title: 'Title',
          type: AssessmentType.quiz,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          occurredAt: DateTime.utc(2026, 11, 1),
          createdByUserId: 'u-1',
          createdAt: DateTime.utc(2026, 11, 1),
          updatedAt: DateTime.utc(2026, 11, 1),
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });

    test('rejects subject exceeding 100 characters', () {
      expect(
        () => Assessment(
          id: AssessmentId('a-1'),
          familyId: FamilyId('f-1'),
          childId: ChildId('c-1'),
          subjectKey: SubjectKey.math,
          subject: 'A' * 101,
          title: 'Title',
          type: AssessmentType.quiz,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          occurredAt: DateTime.utc(2026, 11, 1),
          createdByUserId: 'u-1',
          createdAt: DateTime.utc(2026, 11, 1),
          updatedAt: DateTime.utc(2026, 11, 1),
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });

    test('rejects modifying terminal verified assessment (status is null)', () {
      final verified = validAssessment.copyWith(
        status: AssessmentStatus.verified,
      );
      expect(
        () => verified.copyWith(title: 'Hacked Title'),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });

    test('rejects modifying terminal verified assessment even if status: verified is re-passed', () {
      final verified = validAssessment.copyWith(
        status: AssessmentStatus.verified,
      );
      expect(
        () => verified.copyWith(
          title: 'Hacked Title',
          status: AssessmentStatus.verified,
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });

    test('rejects modifying terminal rejected assessment', () {
      final rejected = validAssessment.copyWith(
        status: AssessmentStatus.rejected,
      );
      expect(
        () => rejected.copyWith(title: 'Modified Title'),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });
  });

  group('AssessmentEvidence', () {
    test('creates valid evidence metadata', () {
      final evidence = AssessmentEvidence(
        id: EvidenceId('e-1'),
        familyId: FamilyId('f-1'),
        assessmentId: AssessmentId('a-1'),
        storagePath: 'f-1/c-1/a-1/photo.jpg',
        mediaType: 'image/jpeg',
        fileSizeBytes: 2048,
        uploadedByUserId: 'u-1',
        createdAt: DateTime.utc(2026, 11, 1),
      );
      expect(evidence.mediaType, equals('image/jpeg'));
    });

    test('rejects unsupported media type', () {
      expect(
        () => AssessmentEvidence(
          id: EvidenceId('e-1'),
          familyId: FamilyId('f-1'),
          assessmentId: AssessmentId('a-1'),
          storagePath: 'f-1/c-1/a-1/video.mp4',
          mediaType: 'video/mp4',
          fileSizeBytes: 2048,
          uploadedByUserId: 'u-1',
          createdAt: DateTime.utc(2026, 11, 1),
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });

    test('rejects file size > 10 MiB', () {
      expect(
        () => AssessmentEvidence(
          id: EvidenceId('e-1'),
          familyId: FamilyId('f-1'),
          assessmentId: AssessmentId('a-1'),
          storagePath: 'f-1/c-1/a-1/huge.jpg',
          mediaType: 'image/jpeg',
          fileSizeBytes: 10 * 1024 * 1024 + 1,
          uploadedByUserId: 'u-1',
          createdAt: DateTime.utc(2026, 11, 1),
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );
    });
  });

  group('VerifiedLearningEvent', () {
    test('holds immutable snapshot of verified achievement', () {
      final event = VerifiedLearningEvent(
        id: 'vle-1',
        familyId: FamilyId('f-1'),
        childId: ChildId('c-1'),
        assessmentId: AssessmentId('a-1'),
        subjectKey: SubjectKey.science,
        subject: 'Science',
        title: 'Lab Report',
        type: AssessmentType.homework,
        difficulty: AssessmentDifficulty.hard,
        score: AssessmentScore(rawScore: 9.5, maxScore: 10.0),
        evidenceCount: 2,
        entryContext: EntryContext.sharedChild,
        occurredAt: DateTime.utc(2026, 11, 1),
        verifiedAt: DateTime.utc(2026, 11, 1, 12),
        verifiedByUserId: 'p-1',
        reviewEventId: 'rev-1',
      );

      expect(event.subjectKey, equals(SubjectKey.science));
      expect(event.evidenceCount, equals(2));
      expect(event.entryContext, equals(EntryContext.sharedChild));
      expect(event.score.serverNormalizedScore, equals(9.50));
    });
  });
}
