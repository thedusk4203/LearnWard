import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/assessments/presentation/add_assessment_screen.dart';
import 'package:learnward/features/assessments/presentation/evidence_picker_service.dart';
import 'package:learnward/features/assessments/services/local_evidence_file_store.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

class _TestFamilyNotifier extends ActiveFamilyNotifier {
  _TestFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

class _TestChildNotifier extends ActiveChildModeNotifier {
  _TestChildNotifier(this._preset);
  final ChildProfile? _preset;

  @override
  ChildProfile? build() => _preset;
}

class _StubEvidenceFileStore implements LocalEvidenceFileStore {
  @override
  Future<String> saveDurableEvidence({
    required String localDraftId,
    required List<int> bytes,
    required String mediaType,
  }) async => '/mock/evidence/$localDraftId.jpg';

  @override
  Future<String> saveEvidence({
    required String fileName,
    required List<int> bytes,
  }) async => '/mock/evidence/$fileName';

  @override
  Future<List<int>?> readEvidenceBytes(String filePath) async => [1, 2, 3];

  @override
  Future<List<int>?> loadEvidence(String filePath) async => [1, 2, 3];

  @override
  Future<void> deleteDurableEvidence(String filePath) async {}

  @override
  Future<void> deleteEvidence(String filePath) async {}

  @override
  Future<EvidenceFileDeletionResult> deleteEvidenceIfUnreferenced({
    required String filePath,
    required LocalDraftStore draftStore,
  }) async => EvidenceFileDeletionResult(
    status: EvidenceFileDeletionStatus.preservedConservative,
    filePath: filePath,
  );
}

void main() {
  final familyId = FamilyId('10000000-0000-0000-0000-000000000001');
  final childId = ChildId('20000000-0000-0000-0000-000000000002');
  final assessmentId = AssessmentId('30000000-0000-0000-0000-000000000003');
  final evidenceId = EvidenceId('40000000-0000-0000-0000-000000000004');
  const expectedPath =
      '10000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000002/30000000-0000-0000-0000-000000000003/40000000-0000-0000-0000-000000000004.jpg';

  group('InMemoryAssessmentEvidenceStorage (R32-06 / R32-07 / R32-08)', () {
    test('R32-06: fails closed without AuthSessionPort unless unauthenticatedDemo is explicitly used', () async {
      final unconfigured = InMemoryAssessmentEvidenceStorage();

      await expectLater(
        () => unconfigured.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3],
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      await expectLater(
        () => unconfigured.downloadEvidence(storagePath: expectedPath),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      final reconcile = await unconfigured.reconcileEvidence(
        storagePath: expectedPath,
        localBytes: [1, 2, 3],
      );
      expect(reconcile, isA<AuthFailureOutcome>());
      await expectLater(
        () => unconfigured.getEvidenceSignedUrl(storagePath: expectedPath),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
      await expectLater(
        () => unconfigured.deleteEvidence(expectedPath),
        throwsA(isA<EvidenceStorageAuthException>()),
      );

      // Explicitly configured demo constructor preserves opt-in behavior
      final demoStorage =
          InMemoryAssessmentEvidenceStorage.unauthenticatedDemo();
      final uploaded = await demoStorage.uploadEvidence(
        familyId: familyId,
        childId: childId,
        assessmentId: assessmentId,
        evidenceId: evidenceId,
        bytes: [1, 2, 3],
        mediaType: 'image/jpeg',
      );
      expect(uploaded, equals(expectedPath));
    });

    test('R32-06 / R32-07 / R32-08: enforces auth, size bounds, and path redaction when wired with AuthSessionPort', () async {
      final authPort = FakeAuthSessionPort(
        activeUserId: 'demo-parent-1',
        sessionGeneration: 'demo-gen-1',
      );
      final storage = InMemoryAssessmentEvidenceStorage(
        authSessionPort: authPort,
      );

      // Reject 0-byte upload
      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: const [],
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );

      // Reject > 10 MiB upload
      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: Uint8List(10 * 1024 * 1024 + 1),
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<InvalidAssessmentException>()),
      );

      // Missing object throws typed sanitized exception without full tenant path
      try {
        await storage.downloadEvidence(storagePath: expectedPath);
        fail('Expected EvidenceStorageUnknownOutcomeException');
      } on EvidenceStorageUnknownOutcomeException catch (e) {
        expect(
          e.message,
          isNot(contains('10000000-0000-0000-0000-000000000001')),
        );
        expect(
          e.toString(),
          isNot(contains('20000000-0000-0000-0000-000000000002')),
        );
      }

      // Sign out -> all operations fail closed with EvidenceStorageAuthException
      authPort.signOut();
      await expectLater(
        () => storage.uploadEvidence(
          familyId: familyId,
          childId: childId,
          assessmentId: assessmentId,
          evidenceId: evidenceId,
          bytes: [1, 2, 3],
          mediaType: 'image/jpeg',
        ),
        throwsA(isA<EvidenceStorageAuthException>()),
      );
    });
  });

  group('AddAssessmentScreen error redaction (R32-07)', () {
    testWidgets(
      'never displays tokens, URLs, or full Storage paths in user-facing UI errors',
      (tester) async {
        const secretBearer = 'bearerSecretUi999';
        const secretJwt =
            'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1MSJ9.uiSecretSig888';
        const secretSignedToken = 'signedUiSecret777';
        const secretPath =
            '10000000-0000-0000-0000-000000000001/20000000-0000-0000-0000-000000000002/30000000-0000-0000-0000-000000000003/40000000-0000-0000-0000-000000000004.jpg';

        final fakeAuth = FakeAuthSessionPort(activeUserId: 'local-parent-user');
        final fakeStorage = FakeAssessmentEvidenceStorage(
          authSessionPort: fakeAuth,
        );
        fakeStorage.throwOnUpload = EvidenceStorageUnknownOutcomeException(
          UnknownOutcome(
            storagePath: secretPath,
            reason:
                'Bearer $secretBearer jwt=$secretJwt https://secret.supabase.co/storage/v1/object/sign/assessment-evidence/$secretPath?token=$secretSignedToken',
          ),
        );

        final now = DateTime.utc(2026, 11, 1);
        final testFamily = Family(
          id: familyId,
          name: 'UI Redaction Family',
          timezone: 'UTC',
          locale: 'en_US',
          createdByUserId: 'local-parent-user',
          createdAt: now,
        );
        final testChild = ChildProfile(
          id: childId,
          familyId: familyId,
          displayName: 'Sam',
          schoolGrade: 5,
          birthYear: 2015,
          createdAt: now,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              familyRepositoryProvider.overrideWithValue(
                FakeFamilyRepository(),
              ),
              childProfileRepositoryProvider.overrideWithValue(
                FakeChildProfileRepository(),
              ),
              assessmentRepositoryProvider.overrideWithValue(
                FakeAssessmentRepository(),
              ),
              assessmentEvidenceStorageProvider.overrideWithValue(fakeStorage),
              authSessionPortProvider.overrideWithValue(fakeAuth),
              localEvidenceFileStoreProvider.overrideWithValue(
                _StubEvidenceFileStore(),
              ),
              localDraftStoreProvider.overrideWithValue(
                InMemoryLocalDraftStore(),
              ),
              activeFamilyProvider.overrideWith(
                () => _TestFamilyNotifier(testFamily),
              ),
              activeChildModeProvider.overrideWith(
                () => _TestChildNotifier(testChild),
              ),
              evidencePickerServiceProvider.overrideWithValue(
                SimulatedEvidencePickerService(
                  stubFile: const SelectedEvidenceFile(
                    fileName: 'quiz.jpg',
                    bytes: [1, 2, 3, 4],
                    mediaType: 'image/jpeg',
                    localPath: '/tmp/quiz.jpg',
                  ),
                ),
              ),
            ],
            child: const MaterialApp(home: AddAssessmentScreen()),
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('assessment_title_field')),
          'UI Safety Quiz',
        );
        await tester.enterText(
          find.byKey(const Key('assessment_raw_score_field')),
          '9',
        );

        // Attach evidence photo
        final attachBtn = find.byKey(const Key('attach_evidence_button'));
        if (attachBtn.evaluate().isNotEmpty) {
          await tester.ensureVisible(attachBtn);
          await tester.tap(attachBtn);
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.textContaining('Attach'));
          await tester.pumpAndSettle();
        }

        final submitBtn = find.byKey(const Key('submit_assessment_button'));
        await tester.ensureVisible(submitBtn);
        await tester.tap(submitBtn);
        await tester.pumpAndSettle();

        expect(
          find.text(
            'Could not verify photo upload status. Your draft is saved on this device. Please try again.',
          ),
          findsOneWidget,
        );

        // Assert none of the sensitive substrings appear anywhere in the widget tree
        expect(find.textContaining(secretBearer), findsNothing);
        expect(find.textContaining('eyJhbGci'), findsNothing);
        expect(find.textContaining(secretSignedToken), findsNothing);
        expect(find.textContaining('secret.supabase.co'), findsNothing);
        expect(
          find.textContaining('10000000-0000-0000-0000-000000000001'),
          findsNothing,
        );
      },
    );
  });
}
