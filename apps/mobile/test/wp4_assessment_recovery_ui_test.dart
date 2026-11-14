import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward/app/bootstrap/app_config.dart';
import 'package:learnward/app/bootstrap/app_providers.dart';
import 'package:learnward/app/bootstrap/in_memory_repositories.dart';
import 'package:learnward/features/assessments/presentation/add_assessment_screen.dart';
import 'package:learnward/features/assessments/presentation/assessment_recovery_presentation.dart';
import 'package:learnward/features/assessments/services/local_evidence_file_store.dart';
import 'package:learnward/features/child/presentation/child_mode_screen.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_data/learnward_data.dart';
import 'package:learnward_domain/learnward_domain.dart';
import 'package:learnward_test_support/learnward_test_support.dart';

void _ensureSqliteInitialized() {
  if (Platform.isWindows) {
    try {
      DynamicLibrary.open('sqlite3.dll');
    } catch (_) {}
  } else if (Platform.isLinux) {
    try {
      DynamicLibrary.open('libsqlite3.so');
    } catch (_) {
      try {
        DynamicLibrary.open('libsqlite3.so.0');
      } catch (_) {}
    }
  }
}

final List<int> _validPngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG header
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
  0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
  0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x03, 0x01, 0x01, 0x00,
  0x18, 0xDD, 0x8D, 0xB0,
  0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

class _PresetActiveChildNotifier extends ActiveChildModeNotifier {
  _PresetActiveChildNotifier(this._preset);
  final ChildProfile? _preset;

  @override
  ChildProfile? build() => _preset;
}

class _PresetFamilyNotifier extends ActiveFamilyNotifier {
  _PresetFamilyNotifier(this._preset);
  final Family? _preset;

  @override
  Family? build() => _preset;
}

final class _SpyAssessmentRepository extends FakeAssessmentRepository {
  _SpyAssessmentRepository({super.activeActorIdProvider});

  int createDraftCalls = 0;
  int submitAssessmentCalls = 0;
  int registerEvidenceCalls = 0;
  int getAssessmentCalls = 0;
  int listEvidenceCalls = 0;

  Object? nextCreateError;
  Object? nextSubmitError;

  @override
  Future<Assessment> createDraft({
    required String commandId,
    required FamilyId familyId,
    required ChildId childId,
    required SubjectKey subjectKey,
    required String subject,
    required String title,
    required AssessmentType type,
    required AssessmentDifficulty difficulty,
    required AssessmentScore score,
    DateTime? occurredAt,
    EntryContext entryContext = EntryContext.adult,
  }) async {
    createDraftCalls++;
    final error = nextCreateError;
    if (error != null) {
      nextCreateError = null;
      throw error;
    }
    return super.createDraft(
      commandId: commandId,
      familyId: familyId,
      childId: childId,
      subjectKey: subjectKey,
      subject: subject,
      title: title,
      type: type,
      difficulty: difficulty,
      score: score,
      occurredAt: occurredAt,
      entryContext: entryContext,
    );
  }

  @override
  Future<AssessmentEvidence> registerEvidence({
    required AssessmentId assessmentId,
    required String storagePath,
    required String mediaType,
    required int fileSizeBytes,
  }) async {
    registerEvidenceCalls++;
    return super.registerEvidence(
      assessmentId: assessmentId,
      storagePath: storagePath,
      mediaType: mediaType,
      fileSizeBytes: fileSizeBytes,
    );
  }

  @override
  Future<Assessment> submitAssessment({
    required AssessmentId assessmentId,
    required String commandId,
    required int expectedVersion,
  }) async {
    submitAssessmentCalls++;
    final error = nextSubmitError;
    if (error != null) {
      nextSubmitError = null;
      throw error;
    }
    return super.submitAssessment(
      assessmentId: assessmentId,
      commandId: commandId,
      expectedVersion: expectedVersion,
    );
  }

  Future<void> Function()? onBeforeGetAssessment;
  Future<void> Function()? onBeforeListEvidence;

  @override
  Future<Assessment?> getAssessment(AssessmentId id) async {
    getAssessmentCalls++;
    if (onBeforeGetAssessment != null) {
      await onBeforeGetAssessment!();
    }
    return super.getAssessment(id);
  }

  @override
  Future<List<AssessmentEvidence>> listEvidenceForAssessment(
    AssessmentId assessmentId,
  ) async {
    listEvidenceCalls++;
    if (onBeforeListEvidence != null) {
      await onBeforeListEvidence!();
    }
    return super.listEvidenceForAssessment(assessmentId);
  }
}

final class _ScriptedRecoveryAuthzPort implements RecoveryAuthorizationPort {
  _ScriptedRecoveryAuthzPort(this.inner);

  final FakeRecoveryAuthorizationPort inner;
  Future<AdultTargetAuthorizationResult> Function(
    ValidatedActorContext context,
    String familyId,
    String childId,
  )?
  onVerifyAssessmentTarget;

  @override
  Future<AdultTargetAuthorizationResult> verifyAdultRedemptionTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required String redemptionId,
    required RewardCommandOperation operation,
  }) => inner.verifyAdultRedemptionTarget(
    context: context,
    familyId: familyId,
    childId: childId,
    redemptionId: redemptionId,
    operation: operation,
  );

  @override
  Future<AdultTargetAuthorizationResult> verifyAssessmentTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
  }) {
    if (onVerifyAssessmentTarget != null) {
      return onVerifyAssessmentTarget!(context, familyId, childId);
    }
    return inner.verifyAssessmentTarget(
      context: context,
      familyId: familyId,
      childId: childId,
    );
  }

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) => inner.verifyTarget(
    context: context,
    familyId: familyId,
    childId: childId,
    operation: operation,
  );
}

final class _GatedEvidenceStorage implements AssessmentEvidenceStorage {
  _GatedEvidenceStorage(this.inner);

  final FakeAssessmentEvidenceStorage inner;
  Completer<void>? uploadGate;
  int attemptedUploadCount = 0;

  int get uploadCallCount => inner.uploadCallCount;
  List<String> get deleteCalls => inner.deleteCalls;

  @override
  Future<String> uploadEvidence({
    required FamilyId familyId,
    required ChildId childId,
    required AssessmentId assessmentId,
    required EvidenceId evidenceId,
    required List<int> bytes,
    required String mediaType,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) async {
    attemptedUploadCount++;
    if (uploadGate != null) {
      await uploadGate!.future;
    }
    return inner.uploadEvidence(
      familyId: familyId,
      childId: childId,
      assessmentId: assessmentId,
      evidenceId: evidenceId,
      bytes: bytes,
      mediaType: mediaType,
      context: context,
      expectedSessionGeneration: expectedSessionGeneration,
    );
  }

  @override
  Future<List<int>> downloadEvidence({
    required String storagePath,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) => inner.downloadEvidence(
    storagePath: storagePath,
    context: context,
    expectedSessionGeneration: expectedSessionGeneration,
  );

  @override
  Future<EvidenceStorageReconciliationResult> reconcileEvidence({
    required String storagePath,
    required List<int> localBytes,
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) => inner.reconcileEvidence(
    storagePath: storagePath,
    localBytes: localBytes,
    context: context,
    expectedSessionGeneration: expectedSessionGeneration,
  );

  @override
  Future<void> deleteEvidence(
    String storagePath, {
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) => inner.deleteEvidence(
    storagePath,
    context: context,
    expectedSessionGeneration: expectedSessionGeneration,
  );

  @override
  Future<String> getEvidenceSignedUrl({
    required String storagePath,
    Duration expiresIn = const Duration(minutes: 10),
    ValidatedActorContext? context,
    String? expectedSessionGeneration,
  }) => inner.getEvidenceSignedUrl(
    storagePath: storagePath,
    expiresIn: expiresIn,
    context: context,
    expectedSessionGeneration: expectedSessionGeneration,
  );
}

LocalAssessmentDraft _buildDraft({
  required String localDraftId,
  String familyId = 'fam-1',
  String childId = 'child-1',
  String? actorUserId = 'parent-a',
  String? actorRole = 'parent',
  String title = 'Fractions Quiz',
  CommandDispatchState dispatchState = CommandDispatchState.neverDispatched,
  DraftSubmissionStatus submissionStatus = DraftSubmissionStatus.draft,
  String? leaseToken,
  DateTime? leaseExpiresAt,
  DateTime? nextAttemptAt,
  int retryCount = 0,
  String? lastErrorMessage,
  String? createCommandId = 'cmd-create-1',
  String? submitCommandId = 'cmd-submit-1',
  String? evidenceId,
  String? serverAssessmentId,
  String? serverEvidenceId,
  String? localPhotoPath,
  String? localCompressedPhotoPath,
  String? sha256Checksum,
}) {
  final now = DateTime.utc(2026, 11, 14, 12, 0, 0);
  return LocalAssessmentDraft(
    localDraftId: localDraftId,
    familyId: familyId,
    childId: childId,
    createCommandId: createCommandId,
    submitCommandId: submitCommandId,
    evidenceId: evidenceId,
    serverAssessmentId: serverAssessmentId,
    serverEvidenceId: serverEvidenceId,
    subjectKey: SubjectKey.math,
    subject: 'Mathematics',
    title: title,
    assessmentType: 'quiz',
    difficulty: 'normal',
    rawScore: 9,
    maxScore: 10,
    localPhotoPath: localPhotoPath,
    localCompressedPhotoPath: localCompressedPhotoPath,
    sha256Checksum: sha256Checksum,
    occurredAt: now,
    updatedAt: now,
    entryContext: EntryContext.sharedChild,
    submissionStatus: submissionStatus,
    retryCount: retryCount,
    dispatchState: dispatchState,
    leaseToken: leaseToken,
    leaseExpiresAt: leaseExpiresAt,
    nextAttemptAt: nextAttemptAt,
    lastErrorMessage: lastErrorMessage,
    actorUserId: actorUserId,
    actorRole: actorRole,
  );
}

Future<void> _tapButton(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  _ensureSqliteInitialized();

  final baseNow = DateTime.utc(2026, 11, 14, 12, 0, 0);
  final validSha = computeSha256Hex(_validPngBytes);

  final family = Family(
    id: FamilyId('fam-1'),
    name: 'Test Family',
    timezone: 'UTC',
    locale: 'en-US',
    createdByUserId: 'parent-a',
    createdAt: baseNow,
  );
  final child = ChildProfile(
    id: ChildId('child-1'),
    familyId: FamilyId('fam-1'),
    displayName: 'Alex',
    schoolGrade: 4,
    birthYear: 2016,
    createdAt: baseNow,
  );

  group(
    'WP4 Pure Presentation Mapping (all dispositions & recovery codes)',
    () {
      test('maps every WP3 DraftRecoveryDisposition and code distinctly without leaks', () {
        final actorA = ValidatedActorContext(
          userId: 'parent-a',
          sessionGeneration: 'gen-a',
          observedAt: baseNow,
          role: 'parent',
        );
        final actorB = ValidatedActorContext(
          userId: 'parent-b',
          sessionGeneration: 'gen-b',
          observedAt: baseNow,
          role: 'parent',
        );

        // 1. editableDraft (authorized actor A)
        final editable = buildAssessmentRecoveryPresentation(
          draft: _buildDraft(localDraftId: 'd-editable'),
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: true,
        );
        expect(editable.disposition, DraftRecoveryDisposition.editableDraft);
        expect(
          editable.actionKind,
          AssessmentRecoveryUiActionKind.submitEditable,
        );
        expect(editable.canEditDraft, isTrue);

        // 2. editableDraft opened by actor B -> locked signInAsOriginalActor
        final editableMismatch = buildAssessmentRecoveryPresentation(
          draft: _buildDraft(localDraftId: 'd-editable-b'),
          now: baseNow,
          liveActor: actorB,
          liveAuthChecked: true,
        );
        expect(
          editableMismatch.actionKind,
          AssessmentRecoveryUiActionKind.signInAsOriginalActor,
        );
        expect(editableMismatch.canEditDraft, isFalse);

        // 3. inProgressSameSession (active lease even while status is draft)
        final inProgress = buildAssessmentRecoveryPresentation(
          draft: _buildDraft(
            localDraftId: 'd-leased',
            leaseToken: 'lease-1',
            leaseExpiresAt: baseNow.add(const Duration(minutes: 4)),
          ),
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: true,
        );
        expect(
          inProgress.disposition,
          DraftRecoveryDisposition.inProgressSameSession,
        );
        expect(
          inProgress.actionKind,
          AssessmentRecoveryUiActionKind.inProgressWait,
        );
        expect(inProgress.canRetryNow, isFalse);
        expect(inProgress.leaseDetail, isNotNull);

        // 4. retryScheduled with future nextAttemptAt -> explicit Retry Now + schedule detail
        final retryScheduled = buildAssessmentRecoveryPresentation(
          draft: _buildDraft(
            localDraftId: 'd-retry',
            submissionStatus: DraftSubmissionStatus.failedRetryable,
            retryCount: 2,
            nextAttemptAt: baseNow.add(const Duration(minutes: 3)),
            lastErrorMessage: DraftRecoveryCode.format(
              DraftRecoveryCode.retryScheduled,
              'Temporary outage',
            ),
          ),
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: true,
          liveTargetAuthorization:
              const AdultTargetAuthorizationResult.authorized(
                verifiedRole: VerifiedAdultRole.parent,
              ),
        );
        expect(
          retryScheduled.disposition,
          DraftRecoveryDisposition.retryScheduled,
        );
        expect(
          retryScheduled.actionKind,
          AssessmentRecoveryUiActionKind.retryNow,
        );
        expect(retryScheduled.canRetryNow, isTrue);
        expect(retryScheduled.scheduleDetail, contains('attempt #2'));
        expect(
          retryScheduled.scheduleDetail!.toLowerCase(),
          isNot(contains('automatic')),
        );
        expect(
          retryScheduled.scheduleDetail!.toLowerCase(),
          contains('retry available after'),
        );
        expect(
          retryScheduled.scheduleDetail!.toLowerCase(),
          contains('retry manually when connected'),
        );

        // 5. waitingOriginalActor: actor B cannot resume; actor A can resume; confirmedRevoked & definitelyDenied block
        final waitingDraft = _buildDraft(
          localDraftId: 'd-waiting',
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.waitingOriginalActor,
            'Sign in as original author.',
          ),
        );
        final waitingAsB = buildAssessmentRecoveryPresentation(
          draft: waitingDraft,
          now: baseNow,
          liveActor: actorB,
          liveAuthChecked: true,
        );
        expect(
          waitingAsB.disposition,
          DraftRecoveryDisposition.waitingOriginalActor,
        );
        expect(
          waitingAsB.actionKind,
          AssessmentRecoveryUiActionKind.signInAsOriginalActor,
        );
        expect(waitingAsB.canResumeOriginalActor, isFalse);

        final waitingAsA = buildAssessmentRecoveryPresentation(
          draft: waitingDraft,
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: true,
          liveTargetAuthorization:
              const AdultTargetAuthorizationResult.authorized(
                verifiedRole: VerifiedAdultRole.parent,
              ),
        );
        expect(waitingAsA.canResumeOriginalActor, isTrue);

        final waitingRevoked = buildAssessmentRecoveryPresentation(
          draft: waitingDraft,
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: true,
          liveTargetAuthorization:
              const AdultTargetAuthorizationResult.confirmedRevoked(),
        );
        expect(waitingRevoked.canResumeOriginalActor, isFalse);
        expect(
          waitingRevoked.actionKind,
          AssessmentRecoveryUiActionKind.manualReviewRequired,
        );

        final waitingDenied = buildAssessmentRecoveryPresentation(
          draft: waitingDraft,
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: true,
          liveTargetAuthorization:
              const AdultTargetAuthorizationResult.definitelyDenied(
                reason: AdultTargetVerificationReason.childConfirmedArchived,
              ),
        );
        expect(waitingDenied.canResumeOriginalActor, isFalse);
        expect(
          waitingDenied.actionKind,
          AssessmentRecoveryUiActionKind.manualReviewRequired,
        );

        // 6. verificationPending with expired lease
        final expiredPending = buildAssessmentRecoveryPresentation(
          draft: _buildDraft(
            localDraftId: 'd-exp-lease',
            dispatchState: CommandDispatchState.possiblyDispatched,
            leaseToken: 'stale-lease',
            leaseExpiresAt: baseNow.subtract(const Duration(seconds: 10)),
          ),
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: true,
          liveTargetAuthorization:
              const AdultTargetAuthorizationResult.authorized(
                verifiedRole: VerifiedAdultRole.parent,
              ),
        );
        expect(
          expiredPending.disposition,
          DraftRecoveryDisposition.verificationPending,
        );
        expect(expiredPending.canRetryNow, isTrue);
        expect(expiredPending.leaseDetail, contains('expired'));

        // 7. Quarantine & terminal dispositions / codes
        final cases =
            <
              ({
                LocalAssessmentDraft draft,
                DraftRecoveryDisposition expectedDisposition,
                String expectedCode,
              })
            >[
              (
                draft: _buildDraft(
                  localDraftId: 'q-missing',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.localSnapshotMissing,
                    'missing',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedMissingSnapshot,
                expectedCode: DraftRecoveryCode.localSnapshotMissing,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-corrupt',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.localSnapshotCorrupted,
                    'checksum mismatch',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedCorruptedSnapshot,
                expectedCode: DraftRecoveryCode.localSnapshotCorrupted,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-storage-conflict',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.storageContentConflict,
                    'conflict',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedConflict,
                expectedCode: DraftRecoveryCode.storageContentConflict,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-ev-mismatch',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.evidenceIdMismatch,
                    'conflict',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedConflict,
                expectedCode: DraftRecoveryCode.evidenceIdMismatch,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-version-conflict',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.versionConflict,
                    'lw101',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedConflict,
                expectedCode: DraftRecoveryCode.versionConflict,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-reg-unresolved',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.registrationUnresolvedRemoteRetained,
                    'retain',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedUnknownOutcome,
                expectedCode:
                    DraftRecoveryCode.registrationUnresolvedRemoteRetained,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-unrecon-ver',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.unreconstructableExpectedVersion,
                    'ver',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedUnknownOutcome,
                expectedCode:
                    DraftRecoveryCode.unreconstructableExpectedVersion,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-ambig-42501',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.ambiguous42501Outcome,
                    'rls',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedUnknownOutcome,
                expectedCode: DraftRecoveryCode.ambiguous42501Outcome,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-ambig-submit',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.ambiguousSubmitOutcome,
                    'submit',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedUnknownOutcome,
                expectedCode: DraftRecoveryCode.ambiguousSubmitOutcome,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-legacy',
                  dispatchState: CommandDispatchState.unknownLegacy,
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.legacyInFlightUnverifiedBytes,
                    'legacy',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedLegacyUnknown,
                expectedCode: DraftRecoveryCode.legacyInFlightUnverifiedBytes,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-unbound',
                  actorUserId: null,
                  submissionStatus: DraftSubmissionStatus.draft,
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.quarantinedUnknownOutcome,
                expectedCode: DraftRecoveryCode.unboundActorProvenance,
              ),
              (
                draft: _buildDraft(
                  localDraftId: 'q-terminal-policy',
                  submissionStatus: DraftSubmissionStatus.terminalError,
                  lastErrorMessage: DraftRecoveryCode.format(
                    DraftRecoveryCode.terminalPolicyDenial,
                    'revoked',
                  ),
                ),
                expectedDisposition:
                    DraftRecoveryDisposition.terminalPolicyDenial,
                expectedCode: DraftRecoveryCode.terminalPolicyDenial,
              ),
            ];

        for (final c in cases) {
          final p = buildAssessmentRecoveryPresentation(
            draft: c.draft,
            now: baseNow,
            liveActor: actorA,
            liveAuthChecked: true,
          );
          expect(
            p.disposition,
            c.expectedDisposition,
            reason: c.draft.localDraftId,
          );
          expect(
            p.safeRecoveryCode,
            c.expectedCode,
            reason: c.draft.localDraftId,
          );
          expect(
            p.actionKind,
            AssessmentRecoveryUiActionKind.manualReviewRequired,
            reason: c.draft.localDraftId,
          );
          expect(p.canEditDraft, isFalse);
          expect(p.canRetryNow, isFalse);
          expect(p.manualReviewNotice, isNotNull);
        }

        // 8. confirmedSubmitted (requires checked valid session + authorized target)
        final confirmedDraft = _buildDraft(
          localDraftId: 'd-confirmed',
          dispatchState: CommandDispatchState.confirmedCommitted,
          submissionStatus: DraftSubmissionStatus.draft,
          serverAssessmentId: 'srv-1',
        );
        final confirmed = buildAssessmentRecoveryPresentation(
          draft: confirmedDraft,
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: true,
          liveTargetAuthorization:
              const AdultTargetAuthorizationResult.authorized(
                verifiedRole: VerifiedAdultRole.parent,
              ),
        );
        expect(
          confirmed.disposition,
          DraftRecoveryDisposition.confirmedSubmitted,
        );
        expect(
          confirmed.actionKind,
          AssessmentRecoveryUiActionKind.reviewConfirmedResult,
        );
        expect(confirmed.canReviewConfirmed, isTrue);
        expect(confirmed.canEditDraft, isFalse);
        expect(confirmed.canRetryNow, isFalse);

        // Missing, unverified, definitelyDenied, and confirmedRevoked do NOT permit review
        for (final nonAuthTarget in <AdultTargetAuthorizationResult?>[
          null,
          const AdultTargetAuthorizationResult.unverified(
            reason: AdultTargetVerificationReason.transientVerificationFailure,
          ),
          const AdultTargetAuthorizationResult.definitelyDenied(
            reason: AdultTargetVerificationReason.childConfirmedArchived,
          ),
          const AdultTargetAuthorizationResult.confirmedRevoked(),
        ]) {
          final blocked = buildAssessmentRecoveryPresentation(
            draft: confirmedDraft,
            now: baseNow,
            liveActor: actorA,
            liveAuthChecked: true,
            liveTargetAuthorization: nonAuthTarget,
          );
          expect(blocked.canReviewConfirmed, isFalse);
        }
        final uncheckedConfirmed = buildAssessmentRecoveryPresentation(
          draft: confirmedDraft,
          now: baseNow,
          liveActor: actorA,
          liveAuthChecked: false,
          liveTargetAuthorization:
              const AdultTargetAuthorizationResult.authorized(
                verifiedRole: VerifiedAdultRole.parent,
              ),
        );
        expect(uncheckedConfirmed.canReviewConfirmed, isFalse);
      });
    },
  );

  group('WP4 SQLite & Widget Recovery Integration', () {
    late Directory tempDir;
    late AppDatabase db;
    late DefaultLocalEvidenceFileStore fileStore;
    late FakeAuthSessionPort authPort;
    late FakeRecoveryAuthorizationPort authzPort;
    late _ScriptedRecoveryAuthzPort scriptedAuthzPort;
    late _SpyAssessmentRepository repo;
    late _GatedEvidenceStorage storage;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lw_wp4_recovery_test_');
      db = AppDatabase(NativeDatabase.memory());
      fileStore = DefaultLocalEvidenceFileStore(baseDirectory: tempDir);
      authPort = FakeAuthSessionPort(
        activeUserId: 'parent-a',
        role: 'parent',
        sessionGeneration: 'gen-a1',
      );
      authzPort = FakeRecoveryAuthorizationPort();
      scriptedAuthzPort = _ScriptedRecoveryAuthzPort(authzPort);
      repo = _SpyAssessmentRepository(
        activeActorIdProvider: () => authPort.currentContext?.userId,
      );
      storage = _GatedEvidenceStorage(
        FakeAssessmentEvidenceStorage(authSessionPort: authPort),
      );
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<String> writeCanonicalSnapshotFile(String draftId) async {
      final snap = await fileStore.saveCanonicalEvidenceSnapshot(
        localDraftId: draftId,
        bytes: _validPngBytes,
      );
      return snap.filePath;
    }

    Widget buildAddAssessmentApp({
      LocalAssessmentDraft? initialDraft,
      String cachedUserId = 'parent-a',
      DateTime Function()? clock,
    }) {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: Column(
                children: [
                  const Text('HOME_ROUTE'),
                  TextButton(
                    key: const Key('open_draft_btn'),
                    onPressed: () => context.push('/add'),
                    child: const Text('Open Draft'),
                  ),
                ],
              ),
            ),
          ),
          GoRoute(
            path: '/add',
            builder: (_, _) => AddAssessmentScreen(initialDraft: initialDraft),
          ),
        ],
      );
      return ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(
            const AppConfig(
              environment: AppEnvironment.development,
              supabaseUrl: '',
              supabasePublishableKey: '',
              enableLocalDemo: true,
            ),
          ),
          appClockProvider.overrideWithValue(clock ?? () => baseNow),
          activeFamilyProvider.overrideWith(
            () => _PresetFamilyNotifier(family),
          ),
          activeChildModeProvider.overrideWith(
            () => _PresetActiveChildNotifier(child),
          ),
          currentUserIdProvider.overrideWithValue(cachedUserId),
          localDraftStoreProvider.overrideWithValue(db),
          localEvidenceFileStoreProvider.overrideWithValue(fileStore),
          authSessionPortProvider.overrideWithValue(authPort),
          recoveryAuthorizationPortProvider.overrideWithValue(
            scriptedAuthzPort,
          ),
          assessmentRepositoryProvider.overrideWithValue(repo),
          assessmentEvidenceStorageProvider.overrideWithValue(storage),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    Future<void> pumpOpenAddAssessment(
      WidgetTester tester, {
      LocalAssessmentDraft? initialDraft,
      String cachedUserId = 'parent-a',
      DateTime Function()? clock,
    }) async {
      await tester.pumpWidget(
        buildAddAssessmentApp(
          initialDraft: initialDraft,
          cachedUserId: cachedUserId,
          clock: clock,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open_draft_btn')));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'ChildModeScreen lists recovery badges distinctly and separates read-only Confirmed Submissions',
      (tester) async {
        final snapEditable = await writeCanonicalSnapshotFile('cm-edit');
        final snapRetry = await writeCanonicalSnapshotFile('cm-retry');
        final snapConfirmed = await writeCanonicalSnapshotFile('cm-conf');

        await db.saveLocalDraft(
          _buildDraft(
            localDraftId: 'cm-edit',
            title: 'Draft One',
            localPhotoPath: snapEditable,
            localCompressedPhotoPath: snapEditable,
            sha256Checksum: validSha,
            evidenceId: 'ev-edit',
          ),
        );
        await db.saveLocalDraft(
          _buildDraft(
            localDraftId: 'cm-retry',
            title: 'Retry Two',
            submissionStatus: DraftSubmissionStatus.failedRetryable,
            retryCount: 1,
            nextAttemptAt: baseNow.add(const Duration(minutes: 2)),
            localPhotoPath: snapRetry,
            localCompressedPhotoPath: snapRetry,
            sha256Checksum: validSha,
            evidenceId: 'ev-retry',
            lastErrorMessage: DraftRecoveryCode.format(
              DraftRecoveryCode.retryScheduled,
              'network error in C:\\secret\\path\\foo.png',
            ),
          ),
        );
        await db.saveLocalDraft(
          _buildDraft(
            localDraftId: 'cm-wait',
            title: 'Waiting Three',
            submissionStatus: DraftSubmissionStatus.failedRetryable,
            lastErrorMessage: DraftRecoveryCode.format(
              DraftRecoveryCode.waitingOriginalActor,
              'Waiting for author',
            ),
          ),
        );
        await db.saveLocalDraft(
          _buildDraft(
            localDraftId: 'cm-quarantined',
            title: 'Conflict Four',
            submissionStatus: DraftSubmissionStatus.terminalError,
            lastErrorMessage: DraftRecoveryCode.format(
              DraftRecoveryCode.storageContentConflict,
              'sha conflict',
            ),
          ),
        );
        await db.saveLocalDraft(
          _buildDraft(
            localDraftId: 'cm-conf',
            title: 'Confirmed Five',
            dispatchState: CommandDispatchState.confirmedCommitted,
            submissionStatus: DraftSubmissionStatus.draft,
            serverAssessmentId: 'srv-conf-5',
            localPhotoPath: snapConfirmed,
            localCompressedPhotoPath: snapConfirmed,
            sha256Checksum: validSha,
            evidenceId: 'ev-conf',
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appConfigProvider.overrideWithValue(
                const AppConfig(
                  environment: AppEnvironment.development,
                  supabaseUrl: '',
                  supabasePublishableKey: '',
                  enableLocalDemo: true,
                ),
              ),
              appClockProvider.overrideWithValue(() => baseNow),
              activeFamilyProvider.overrideWith(
                () => _PresetFamilyNotifier(family),
              ),
              activeChildModeProvider.overrideWith(
                () => _PresetActiveChildNotifier(child),
              ),
              currentUserIdProvider.overrideWithValue('parent-a'),
              localDraftStoreProvider.overrideWithValue(db),
              localMetadataStoreProvider.overrideWithValue(
                InMemoryMobileMetadataStore(),
              ),
              localEvidenceFileStoreProvider.overrideWithValue(fileStore),
              authSessionPortProvider.overrideWithValue(authPort),
              recoveryAuthorizationPortProvider.overrideWithValue(
                scriptedAuthzPort,
              ),
            ],
            child: MaterialApp(home: Scaffold(body: const ChildModeScreen())),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Unsubmitted Local Drafts (4)'), findsOneWidget);
        expect(
          find.byKey(const Key('draft_disposition_badge_cm-edit')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('draft_disposition_badge_cm-retry')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('draft_disposition_badge_cm-wait')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('draft_disposition_badge_cm-quarantined')),
          findsOneWidget,
        );

        // No raw filesystem path leaked in ChildModeScreen summaries
        expect(find.textContaining('C:\\secret\\path'), findsNothing);

        // Confirmed submission lives in separate read-only Confirmed Submissions section with no delete icon
        expect(
          find.byKey(const Key('confirmed_local_drafts_section')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('confirmed_local_draft_cm-conf')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('delete_draft_cm-conf')), findsNothing);
        // Locked drafts never expose delete icon
        expect(
          find.byKey(const Key('delete_draft_cm-quarantined')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'retryScheduled with future nextAttemptAt shows schedule without auto-dispatch; explicit Retry Now overrides backoff via foregroundRetry',
      (tester) async {
        final snapPath = await writeCanonicalSnapshotFile('draft-sched-1');
        final draft = _buildDraft(
          localDraftId: 'draft-sched-1',
          createCommandId: 'cmd-sched-create',
          submitCommandId: 'cmd-sched-submit',
          evidenceId: 'ev-sched-1',
          localPhotoPath: snapPath,
          localCompressedPhotoPath: snapPath,
          sha256Checksum: validSha,
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          retryCount: 1,
          nextAttemptAt: baseNow.add(const Duration(minutes: 5)),
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.retryScheduled,
            'Temporary server timeout',
          ),
        );
        await db.saveLocalDraft(draft);

        await pumpOpenAddAssessment(tester, initialDraft: draft);

        // No auto-dispatch upon opening
        expect(repo.createDraftCalls, 0);
        expect(repo.submitAssessmentCalls, 0);
        expect(storage.uploadCallCount, 0);
        expect(find.byKey(const Key('recovery_status_card')), findsOneWidget);
        expect(
          find.byKey(const Key('recovery_schedule_detail')),
          findsOneWidget,
        );
        expect(find.text('Retry Now'), findsOneWidget);

        // Explicit foreground retry executes cleanly even before nextAttemptAt
        await _tapButton(tester, 'submit_assessment_button');
        expect(find.text('HOME_ROUTE'), findsOneWidget);
        expect(repo.createDraftCalls, 1);
        expect(repo.submitAssessmentCalls, 1);
        expect(storage.uploadCallCount, 1);
        final confirmed = await db.getLocalDraft('draft-sched-1');
        expect(
          confirmed!.dispatchState,
          CommandDispatchState.confirmedCommitted,
        );
        expect(confirmed.createCommandId, 'cmd-sched-create');
        expect(confirmed.submitCommandId, 'cmd-sched-submit');
        expect(confirmed.evidenceId, 'ev-sched-1');
        expect(File(snapPath).existsSync(), isTrue);
      },
    );

    testWidgets(
      'verificationPending with expired lease reclaims lease idempotently on explicit Retry Now',
      (tester) async {
        final snapPath = await writeCanonicalSnapshotFile('draft-exp-lease');
        final draft = _buildDraft(
          localDraftId: 'draft-exp-lease',
          createCommandId: 'cmd-exp-create',
          submitCommandId: 'cmd-exp-submit',
          evidenceId: 'ev-exp-1',
          localPhotoPath: snapPath,
          localCompressedPhotoPath: snapPath,
          sha256Checksum: validSha,
          dispatchState: CommandDispatchState.possiblyDispatched,
          leaseToken: 'crashed-worker-lease',
          leaseExpiresAt: baseNow.subtract(const Duration(minutes: 1)),
        );
        await db.saveLocalDraft(draft);

        await pumpOpenAddAssessment(tester, initialDraft: draft);

        expect(find.text('Previous Sync Interrupted'), findsOneWidget);
        expect(find.byKey(const Key('recovery_lease_detail')), findsOneWidget);
        expect(find.text('Retry Now'), findsOneWidget);

        await _tapButton(tester, 'submit_assessment_button');
        expect(find.text('HOME_ROUTE'), findsOneWidget);
        final persisted = await db.getLocalDraft('draft-exp-lease');
        expect(
          persisted!.dispatchState,
          CommandDispatchState.confirmedCommitted,
        );
        expect(persisted.leaseToken, isNull);
      },
    );

    testWidgets(
      'Actor A -> B -> A: spoofed cached currentUserIdProvider ignored, ownership preserved, original actor resumes via foregroundRetry',
      (tester) async {
        final snapPath = await writeCanonicalSnapshotFile('draft-actor-switch');
        final waitingDraft = _buildDraft(
          localDraftId: 'draft-actor-switch',
          actorUserId: 'parent-a',
          createCommandId: 'cmd-ab-create',
          submitCommandId: 'cmd-ab-submit',
          evidenceId: 'ev-ab-1',
          localPhotoPath: snapPath,
          localCompressedPhotoPath: snapPath,
          sha256Checksum: validSha,
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.waitingOriginalActor,
            'Waiting for parent-a',
          ),
        );
        await db.saveLocalDraft(waitingDraft);

        // Start session as parent-b while cached currentUserIdProvider spoofs parent-a
        authPort.setSession(
          userId: 'parent-b',
          role: 'parent',
          sessionGeneration: 'gen-b1',
        );

        await pumpOpenAddAssessment(
          tester,
          initialDraft: waitingDraft,
          cachedUserId: 'parent-a',
        );

        expect(find.text('Waiting for Original Author'), findsOneWidget);
        expect(
          find.byKey(const Key('resume_original_actor_button')),
          findsNothing,
        );
        final submitBtn = tester.widget<FilledButton>(
          find.byKey(const Key('submit_assessment_button')),
        );
        expect(submitBtn.onPressed, isNull);
        expect(repo.createDraftCalls, 0);

        // Original author parent-a signs back in and resumes app lifecycle
        authPort.setSession(
          userId: 'parent-a',
          role: 'parent',
          sessionGeneration: 'gen-a2',
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();

        // Ownership remained parent-a and resume button is now enabled
        final beforeResume = await db.getLocalDraft('draft-actor-switch');
        expect(beforeResume!.actorUserId, 'parent-a');
        expect(
          find.byKey(const Key('resume_original_actor_button')),
          findsOneWidget,
        );

        await _tapButton(tester, 'resume_original_actor_button');
        expect(find.text('HOME_ROUTE'), findsOneWidget);
        final afterResume = await db.getLocalDraft('draft-actor-switch');
        expect(
          afterResume!.dispatchState,
          CommandDispatchState.confirmedCommitted,
        );
        expect(afterResume.actorUserId, 'parent-a');
      },
    );

    testWidgets(
      'confirmedRevoked disables retry with zero RPCs, while offline unverified allows safe foreground Retry Now',
      (tester) async {
        // 1. Confirmed revoked disables Retry Now
        final snapRevoked = await writeCanonicalSnapshotFile('draft-revoked');
        final revokedDraft = _buildDraft(
          localDraftId: 'draft-revoked',
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          localPhotoPath: snapRevoked,
          localCompressedPhotoPath: snapRevoked,
          sha256Checksum: validSha,
          evidenceId: 'ev-revoked',
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.retryScheduled,
            'Transient issue',
          ),
        );
        await db.saveLocalDraft(revokedDraft);
        authzPort.setTargetStatus(
          familyId: 'fam-1',
          childId: 'child-1',
          status: TargetAuthorizationStatus.confirmedRevoked,
        );

        await pumpOpenAddAssessment(tester, initialDraft: revokedDraft);

        expect(find.text('Retry Blocked by Permissions'), findsOneWidget);
        final revokedSubmitBtn = tester.widget<FilledButton>(
          find.byKey(const Key('submit_assessment_button')),
        );
        expect(revokedSubmitBtn.onPressed, isNull);
        expect(repo.createDraftCalls, 0);

        // 2. Offline / unverified permits explicit foreground Retry Now and preserves state
        authzPort.setTargetStatus(
          familyId: 'fam-1',
          childId: 'child-1',
          status: TargetAuthorizationStatus.unverified,
        );
        repo.nextCreateError = SocketException('Offline network error');

        final snapOffline = await writeCanonicalSnapshotFile('draft-offline');
        final offlineDraft = _buildDraft(
          localDraftId: 'draft-offline',
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          localPhotoPath: snapOffline,
          localCompressedPhotoPath: snapOffline,
          sha256Checksum: validSha,
          evidenceId: 'ev-offline',
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.retryScheduled,
            'Offline earlier',
          ),
        );
        await db.saveLocalDraft(offlineDraft);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await pumpOpenAddAssessment(tester, initialDraft: offlineDraft);

        final offlineSubmitBtn = tester.widget<FilledButton>(
          find.byKey(const Key('submit_assessment_button')),
        );
        expect(offlineSubmitBtn.onPressed, isNotNull);

        await _tapButton(tester, 'submit_assessment_button');
        expect(find.byType(AddAssessmentScreen), findsOneWidget);
        final afterOfflineRetry = await db.getLocalDraft('draft-offline');
        expect(
          afterOfflineRetry!.submissionStatus,
          DraftSubmissionStatus.failedRetryable,
        );
        expect(File(snapOffline).existsSync(), isTrue);
        expect(storage.deleteCalls.length, 0);
      },
    );

    testWidgets(
      'Active lease disables Retry Now and refreshes to Confirmed when external worker finishes',
      (tester) async {
        final draft = _buildDraft(
          localDraftId: 'draft-active-lease',
          dispatchState: CommandDispatchState.possiblyDispatched,
          leaseToken: 'active-bg-lease',
          leaseExpiresAt: baseNow.add(const Duration(minutes: 5)),
        );
        await db.saveLocalDraft(draft);

        await pumpOpenAddAssessment(tester, initialDraft: draft);

        expect(find.text('Submission Sync In Progress'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('submit_assessment_button')),
              )
              .onPressed,
          isNull,
        );

        // External worker completes commit in SQLite while screen stays open
        await db.completeDraftSubmission(
          localDraftId: 'draft-active-lease',
          leaseToken: 'active-bg-lease',
          authenticatedActorId: 'parent-a',
          serverAssessmentId: 'srv-ext-99',
          now: baseNow.add(const Duration(seconds: 15)),
        );

        await _tapButton(tester, 'refresh_recovery_status_button');
        expect(find.text('Submitted Assessment Confirmed'), findsOneWidget);
        expect(
          find.byKey(const Key('review_confirmed_result_button')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Confirmed submission opens read-only server status without writes or deletions',
      (tester) async {
        final assessment = Assessment(
          id: AssessmentId('srv-read-only-1'),
          familyId: FamilyId('fam-1'),
          childId: ChildId('child-1'),
          subjectKey: SubjectKey.math,
          subject: 'Mathematics',
          title: 'Confirmed Algebra Quiz',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 9, maxScore: 10),
          entryContext: EntryContext.sharedChild,
          status: AssessmentStatus.pendingReview,
          occurredAt: baseNow,
          version: 2,
          createdByUserId: 'parent-a',
          createdAt: baseNow,
          updatedAt: baseNow,
        );
        repo.assessments['srv-read-only-1'] = assessment;

        final draft = _buildDraft(
          localDraftId: 'draft-confirmed-ro',
          title: 'Confirmed Algebra Quiz',
          dispatchState: CommandDispatchState.confirmedCommitted,
          submissionStatus: DraftSubmissionStatus.draft,
          serverAssessmentId: 'srv-read-only-1',
        );
        await db.saveLocalDraft(draft);

        await pumpOpenAddAssessment(tester, initialDraft: draft);

        expect(find.text('Submitted Assessment Confirmed'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('submit_assessment_button')),
              )
              .onPressed,
          isNull,
        );

        await _tapButton(tester, 'review_confirmed_result_button');
        expect(
          find.byKey(const Key('confirmed_server_status_card')),
          findsOneWidget,
        );
        expect(
          find.text('Confirmed Server Status (Read-Only)'),
          findsOneWidget,
        );
        expect(find.text('Status: pendingReview'), findsOneWidget);
        expect(repo.getAssessmentCalls, 1);
        expect(repo.listEvidenceCalls, 1);
        expect(repo.createDraftCalls, 0);
        expect(repo.submitAssessmentCalls, 0);
        expect(storage.deleteCalls.length, 0);
      },
    );

    testWidgets(
      'Missing snapshot on retry transitions cleanly to quarantined LOCAL_SNAPSHOT_MISSING without path leaks',
      timeout: const Timeout(Duration(seconds: 15)),
      (tester) async {
        final missingSnapPath = await writeCanonicalSnapshotFile(
          'draft-missing-snap-retry',
        );
        File(missingSnapPath).deleteSync();
        final draft = _buildDraft(
          localDraftId: 'draft-missing-snap-retry',
          evidenceId: 'ev-missing-snap',
          localPhotoPath: missingSnapPath,
          localCompressedPhotoPath: missingSnapPath,
          sha256Checksum: validSha,
          dispatchState: CommandDispatchState.possiblyDispatched,
        );
        await db.saveLocalDraft(draft);

        await pumpOpenAddAssessment(tester, initialDraft: draft);

        await _tapButton(tester, 'submit_assessment_button');

        final persisted = await db.getLocalDraft('draft-missing-snap-retry');
        expect(
          persisted!.submissionStatus,
          DraftSubmissionStatus.terminalError,
        );
        expect(persisted.recoveryCode, DraftRecoveryCode.localSnapshotMissing);
        expect(find.text('Evidence Snapshot Missing'), findsOneWidget);
        expect(
          find.byKey(const Key('recovery_manual_review_notice')),
          findsOneWidget,
        );
        expect(find.textContaining(tempDir.path), findsNothing);
      },
    );

    testWidgets(
      'Double tapping Retry Now while upload is in flight triggers only one orchestrator attempt and redacts error secrets',
      (tester) async {
        final gate = Completer<void>();
        storage.uploadGate = gate;

        final snapPath = await writeCanonicalSnapshotFile('draft-double-tap');
        final draft = _buildDraft(
          localDraftId: 'draft-double-tap',
          evidenceId: 'ev-double-tap',
          localPhotoPath: snapPath,
          localCompressedPhotoPath: snapPath,
          sha256Checksum: validSha,
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.retryScheduled,
            'Transient upload failure',
          ),
        );
        await db.saveLocalDraft(draft);

        await pumpOpenAddAssessment(tester, initialDraft: draft);

        // First tap starts upload and locks button via _isSubmitting
        await tester.ensureVisible(
          find.byKey(const Key('submit_assessment_button')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('submit_assessment_button')));
        await tester.pump();
        // Second concurrent tap hits disabled button / _isSubmitting guard
        await tester.tap(
          find.byKey(const Key('submit_assessment_button')),
          warnIfMissed: false,
        );
        await tester.pump(const Duration(milliseconds: 50));

        expect(repo.createDraftCalls, 1);
        expect(storage.attemptedUploadCount, 1);

        // Complete upload with a secret-laden error on submitAssessment to test UI redaction
        repo.nextSubmitError = BackendRpcException(
          message:
              'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.secretpayload '
              'https://project.supabase.co/storage/v1/object/sign/ev/foo?token=topsecret '
              '${tempDir.path}/private_evidence.jpg',
          code: 'LW107',
        );
        gate.complete();
        await tester.pumpAndSettle();

        expect(find.textContaining('eyJhbGci'), findsNothing);
        expect(find.textContaining('topsecret'), findsNothing);
        expect(find.textContaining(tempDir.path), findsNothing);
        expect(find.textContaining('manual verification'), findsOneWidget);
      },
    );

    test('Restart persistence: reopening file-backed AppDatabase retains recovery state accurately', () async {
      final dbFile = File(
        '${tempDir.path}${Platform.pathSeparator}restart.sqlite',
      );
      final db1 = AppDatabase(NativeDatabase(dbFile));
      await db1.saveLocalDraft(
        _buildDraft(
          localDraftId: 'restart-wait-1',
          actorUserId: 'parent-a',
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          retryCount: 2,
          nextAttemptAt: baseNow.add(const Duration(minutes: 4)),
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.waitingOriginalActor,
            'Waiting for parent-a',
          ),
        ),
      );
      await db1.close();

      final db2 = AppDatabase(NativeDatabase(dbFile));
      addTearDown(db2.close);
      final restored = await db2.getLocalDraft('restart-wait-1');
      expect(restored, isNotNull);
      expect(restored!.actorUserId, 'parent-a');
      expect(restored.retryCount, 2);
      expect(
        restored.recoveryDispositionAt(now: baseNow),
        DraftRecoveryDisposition.waitingOriginalActor,
      );
    });

    testWidgets(
      'R35-01: definitelyDenied blocks retry, resume, and confirmed server review with zero RPCs',
      (tester) async {
        authzPort.setTargetStatus(
          familyId: 'fam-1',
          childId: 'child-1',
          status: TargetAuthorizationStatus.definitelyDenied,
        );

        // 1. retryScheduled -> Retry Blocked by Permissions, submit disabled, zero RPCs
        final snapRetry = await writeCanonicalSnapshotFile('r35-denied-retry');
        final retryDraft = _buildDraft(
          localDraftId: 'r35-denied-retry',
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          localPhotoPath: snapRetry,
          localCompressedPhotoPath: snapRetry,
          sha256Checksum: validSha,
          evidenceId: 'ev-r35-retry',
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.retryScheduled,
            'Transient error',
          ),
        );
        await db.saveLocalDraft(retryDraft);
        await pumpOpenAddAssessment(tester, initialDraft: retryDraft);

        expect(find.text('Retry Blocked by Permissions'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('submit_assessment_button')),
              )
              .onPressed,
          isNull,
        );
        expect(repo.createDraftCalls, 0);

        // 2. waitingOriginalActor even as original actor -> resume button absent & submit disabled
        final snapWait = await writeCanonicalSnapshotFile('r35-denied-wait');
        final waitDraft = _buildDraft(
          localDraftId: 'r35-denied-wait',
          submissionStatus: DraftSubmissionStatus.failedRetryable,
          localPhotoPath: snapWait,
          localCompressedPhotoPath: snapWait,
          sha256Checksum: validSha,
          evidenceId: 'ev-r35-wait',
          lastErrorMessage: DraftRecoveryCode.format(
            DraftRecoveryCode.waitingOriginalActor,
            'Waiting for author',
          ),
        );
        await db.saveLocalDraft(waitDraft);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await pumpOpenAddAssessment(tester, initialDraft: waitDraft);

        expect(find.text('Authorization Denied'), findsOneWidget);
        expect(
          find.byKey(const Key('resume_original_actor_button')),
          findsNothing,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('submit_assessment_button')),
              )
              .onPressed,
          isNull,
        );

        // 3. confirmedSubmitted -> Review Confirmed Result hidden, zero server reads
        final confirmedDraft = _buildDraft(
          localDraftId: 'r35-denied-confirmed',
          dispatchState: CommandDispatchState.confirmedCommitted,
          submissionStatus: DraftSubmissionStatus.draft,
          serverAssessmentId: 'srv-r35-denied',
        );
        repo.assessments['srv-r35-denied'] = Assessment(
          id: AssessmentId('srv-r35-denied'),
          familyId: FamilyId('fam-1'),
          childId: ChildId('child-1'),
          subjectKey: SubjectKey.math,
          subject: 'Mathematics',
          title: 'Confirmed Quiz',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 8, maxScore: 10),
          entryContext: EntryContext.sharedChild,
          status: AssessmentStatus.verified,
          occurredAt: baseNow,
          version: 2,
          createdByUserId: 'parent-a',
          createdAt: baseNow,
          updatedAt: baseNow,
        );
        await db.saveLocalDraft(confirmedDraft);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await pumpOpenAddAssessment(tester, initialDraft: confirmedDraft);

        expect(find.text('Confirmed Record Access Denied'), findsOneWidget);
        expect(
          find.byKey(const Key('review_confirmed_result_button')),
          findsNothing,
        );
        expect(repo.getAssessmentCalls, 0);
        expect(repo.listEvidenceCalls, 0);
      },
    );

    testWidgets(
      'R35-02: Session fence halts confirmed reads on actor switch, generation rotation, sign-out, and denial across async barriers',
      (tester) async {
        final serverAssessment = Assessment(
          id: AssessmentId('srv-r35-02-1'),
          familyId: FamilyId('fam-1'),
          childId: ChildId('child-1'),
          subjectKey: SubjectKey.math,
          subject: 'Mathematics',
          title: 'Confirmed Fenced Quiz',
          type: AssessmentType.quiz,
          difficulty: AssessmentDifficulty.normal,
          score: AssessmentScore(rawScore: 10, maxScore: 10),
          entryContext: EntryContext.sharedChild,
          status: AssessmentStatus.verified,
          occurredAt: baseNow,
          version: 2,
          createdByUserId: 'parent-a',
          createdAt: baseNow,
          updatedAt: baseNow,
        );
        repo.assessments['srv-r35-02-1'] = serverAssessment;
        final confirmedDraft = _buildDraft(
          localDraftId: 'draft-r35-02-1',
          title: 'Confirmed Fenced Quiz',
          dispatchState: CommandDispatchState.confirmedCommitted,
          submissionStatus: DraftSubmissionStatus.draft,
          serverAssessmentId: 'srv-r35-02-1',
        );
        await db.saveLocalDraft(confirmedDraft);

        Future<void> resetToAuthorizedScreen() async {
          scriptedAuthzPort.onVerifyAssessmentTarget = null;
          repo.onBeforeGetAssessment = null;
          repo.onBeforeListEvidence = null;
          repo.getAssessmentCalls = 0;
          repo.listEvidenceCalls = 0;
          authzPort.setTargetStatus(
            familyId: 'fam-1',
            childId: 'child-1',
            status: TargetAuthorizationStatus.authorized,
          );
          authPort.setSession(
            userId: 'parent-a',
            role: 'parent',
            sessionGeneration: 'gen-a-init',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await pumpOpenAddAssessment(tester, initialDraft: confirmedDraft);
          expect(
            find.byKey(const Key('review_confirmed_result_button')),
            findsOneWidget,
          );
        }

        // Case 1: Actor A -> B while verifyAssessmentTarget is pending -> zero server reads
        await resetToAuthorizedScreen();
        final verifyEntered1 = Completer<void>();
        final verifyRelease1 = Completer<void>();
        scriptedAuthzPort.onVerifyAssessmentTarget = (ctx, fId, cId) async {
          if (!verifyEntered1.isCompleted) {
            verifyEntered1.complete();
          }
          await verifyRelease1.future;
          return const AdultTargetAuthorizationResult.authorized(
            verifiedRole: VerifiedAdultRole.parent,
          );
        };
        await tester.tap(
          find.byKey(const Key('review_confirmed_result_button')),
        );
        await verifyEntered1.future;
        authPort.setSession(
          userId: 'parent-b',
          role: 'parent',
          sessionGeneration: 'gen-b-switch',
        );
        verifyRelease1.complete();
        await tester.pumpAndSettle();
        expect(repo.getAssessmentCalls, 0);
        expect(repo.listEvidenceCalls, 0);
        expect(find.text('Status: verified'), findsNothing);

        // Case 2: Session generation rotation during verification -> zero server reads
        await resetToAuthorizedScreen();
        final verifyEntered2 = Completer<void>();
        final verifyRelease2 = Completer<void>();
        scriptedAuthzPort.onVerifyAssessmentTarget = (ctx, fId, cId) async {
          if (!verifyEntered2.isCompleted) {
            verifyEntered2.complete();
          }
          await verifyRelease2.future;
          return const AdultTargetAuthorizationResult.authorized(
            verifiedRole: VerifiedAdultRole.parent,
          );
        };
        await tester.tap(
          find.byKey(const Key('review_confirmed_result_button')),
        );
        await verifyEntered2.future;
        authPort.setSessionGeneration('gen-a-rotated');
        verifyRelease2.complete();
        await tester.pumpAndSettle();
        expect(repo.getAssessmentCalls, 0);
        expect(repo.listEvidenceCalls, 0);
        expect(find.text('Status: verified'), findsNothing);

        // Case 3: Sign-out during verification -> zero server reads
        await resetToAuthorizedScreen();
        final verifyEntered3 = Completer<void>();
        final verifyRelease3 = Completer<void>();
        scriptedAuthzPort.onVerifyAssessmentTarget = (ctx, fId, cId) async {
          if (!verifyEntered3.isCompleted) {
            verifyEntered3.complete();
          }
          await verifyRelease3.future;
          return const AdultTargetAuthorizationResult.authorized(
            verifiedRole: VerifiedAdultRole.parent,
          );
        };
        await tester.tap(
          find.byKey(const Key('review_confirmed_result_button')),
        );
        await verifyEntered3.future;
        authPort.signOut();
        verifyRelease3.complete();
        await tester.pumpAndSettle();
        expect(repo.getAssessmentCalls, 0);
        expect(repo.listEvidenceCalls, 0);
        expect(find.text('Status: verified'), findsNothing);

        // Case 4: Session switch after getAssessment returns and before listEvidence -> no listEvidence, no mixed presentation
        await resetToAuthorizedScreen();
        final getEntered = Completer<void>();
        final getRelease = Completer<void>();
        repo.onBeforeGetAssessment = () async {
          if (!getEntered.isCompleted) {
            getEntered.complete();
          }
          await getRelease.future;
          authPort.setSessionGeneration('gen-after-get');
        };
        await tester.tap(
          find.byKey(const Key('review_confirmed_result_button')),
        );
        await getEntered.future;
        getRelease.complete();
        await tester.pumpAndSettle();
        expect(repo.getAssessmentCalls, 1);
        expect(repo.listEvidenceCalls, 0);
        expect(find.text('Status: verified'), findsNothing);

        // Case 5: Session switch while listEvidenceForAssessment is pending (before publication) -> stale result not shown
        await resetToAuthorizedScreen();
        final listEntered = Completer<void>();
        final listRelease = Completer<void>();
        repo.onBeforeListEvidence = () async {
          if (!listEntered.isCompleted) {
            listEntered.complete();
          }
          await listRelease.future;
        };
        await tester.tap(
          find.byKey(const Key('review_confirmed_result_button')),
        );
        await listEntered.future;
        authPort.setSession(
          userId: 'parent-b',
          role: 'parent',
          sessionGeneration: 'gen-b-before-publish',
        );
        listRelease.complete();
        await tester.pumpAndSettle();
        expect(repo.getAssessmentCalls, 1);
        expect(repo.listEvidenceCalls, 1);
        expect(find.text('Status: verified'), findsNothing);

        // Case 6: Authorization returns definitelyDenied or unverified on tap -> zero reads
        await resetToAuthorizedScreen();
        scriptedAuthzPort.onVerifyAssessmentTarget = (ctx, fId, cId) async =>
            const AdultTargetAuthorizationResult.definitelyDenied(
              reason: AdultTargetVerificationReason.childConfirmedArchived,
            );
        await tester.tap(
          find.byKey(const Key('review_confirmed_result_button')),
        );
        await tester.pumpAndSettle();
        expect(repo.getAssessmentCalls, 0);
        expect(repo.listEvidenceCalls, 0);
        expect(find.text('Confirmed Record Access Denied'), findsOneWidget);
        expect(find.text('Status: verified'), findsNothing);

        // Case 7: Unchanged authorized session succeeds -> then actor switch clears cached result
        await resetToAuthorizedScreen();
        await tester.tap(
          find.byKey(const Key('review_confirmed_result_button')),
        );
        await tester.pumpAndSettle();
        expect(repo.getAssessmentCalls, 1);
        expect(repo.listEvidenceCalls, 1);
        expect(find.text('Status: verified'), findsOneWidget);

        authPort.setSession(
          userId: 'parent-b',
          role: 'parent',
          sessionGeneration: 'gen-b-clear-cache',
        );
        await tester.pumpAndSettle();
        expect(find.text('Status: verified'), findsNothing);
        expect(
          find.byKey(const Key('confirmed_server_status_card')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'R35-02: Repeated Refresh Status requests prevent slower older request from overwriting newer auth state',
      (tester) async {
        final confirmedDraft = _buildDraft(
          localDraftId: 'draft-r35-02-overlap',
          title: 'Confirmed Overlap Quiz',
          dispatchState: CommandDispatchState.confirmedCommitted,
          submissionStatus: DraftSubmissionStatus.draft,
          serverAssessmentId: 'srv-overlap',
        );
        await db.saveLocalDraft(confirmedDraft);

        await pumpOpenAddAssessment(tester, initialDraft: confirmedDraft);
        expect(
          find.byKey(const Key('review_confirmed_result_button')),
          findsOneWidget,
        );

        var verifyCall = 0;
        final slowAuthEntered = Completer<void>();
        final slowAuthRelease = Completer<void>();
        final fastDenyEntered = Completer<void>();
        final fastDenyRelease = Completer<void>();

        scriptedAuthzPort.onVerifyAssessmentTarget = (ctx, fId, cId) async {
          verifyCall++;
          if (verifyCall == 1) {
            if (!slowAuthEntered.isCompleted) {
              slowAuthEntered.complete();
            }
            await slowAuthRelease.future;
            return const AdultTargetAuthorizationResult.authorized(
              verifiedRole: VerifiedAdultRole.parent,
            );
          }
          if (!fastDenyEntered.isCompleted) {
            fastDenyEntered.complete();
          }
          await fastDenyRelease.future;
          return const AdultTargetAuthorizationResult.definitelyDenied(
            reason: AdultTargetVerificationReason.childConfirmedArchived,
          );
        };

        // Start 1st (slower) Refresh Status returning `authorized`
        await tester.tap(
          find.byKey(const Key('refresh_recovery_status_button')),
        );
        await tester.pump();
        await slowAuthEntered.future;

        // Start 2nd (newer) lifecycle resume returning `definitelyDenied`
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await fastDenyEntered.future;
        fastDenyRelease.complete();
        await tester.pump();

        expect(find.text('Confirmed Record Access Denied'), findsOneWidget);
        expect(
          find.byKey(const Key('review_confirmed_result_button')),
          findsNothing,
        );

        // Now complete slower 1st request; newer definitelyDenied state must remain intact
        slowAuthRelease.complete();
        await tester.pumpAndSettle();

        expect(find.text('Confirmed Record Access Denied'), findsOneWidget);
        expect(
          find.byKey(const Key('review_confirmed_result_button')),
          findsNothing,
        );
        expect(repo.getAssessmentCalls, 0);
        expect(repo.listEvidenceCalls, 0);
      },
    );
  });
}
