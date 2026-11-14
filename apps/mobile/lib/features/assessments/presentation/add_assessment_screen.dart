import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/utils/uuid_generator.dart';
import '../services/local_evidence_file_store.dart';
import 'evidence_picker_service.dart';

/// Screen where a learner captures an academic result, attaches evidence,
/// and either saves a local draft or submits for parent review.
enum ExistingEvidenceRestorationStatus {
  /// Draft had no evidence attachment initially.
  none,

  /// File loading/verification from disk is in progress.
  loading,

  /// File was verified and loaded into memory successfully.
  restored,

  /// Referenced file is missing or unreadable on local disk.
  missingOrUnreadable,

  /// User explicitly requested removal of the attachment.
  removed,
}

class AddAssessmentScreen extends ConsumerStatefulWidget {
  const AddAssessmentScreen({super.key, this.initialDraft});

  final LocalAssessmentDraft? initialDraft;

  @override
  ConsumerState<AddAssessmentScreen> createState() =>
      _AddAssessmentScreenState();
}

class _AddAssessmentScreenState extends ConsumerState<AddAssessmentScreen> {
  final _formKey = GlobalKey<FormState>();

  late String _localDraftId;
  String? _createCommandId;
  String? _submitCommandId;
  String? _evidenceId;
  String? _serverAssessmentId;

  late SubjectKey _selectedSubjectKey;
  late TextEditingController _subjectController;
  late TextEditingController _titleController;
  late TextEditingController _rawScoreController;
  late TextEditingController _maxScoreController;

  late AssessmentType _selectedType;
  late AssessmentDifficulty _selectedDifficulty;
  late DateTime _occurredAt;
  SelectedEvidenceFile? _selectedEvidence;

  bool _isSubmitting = false;
  bool _isQuarantined = false;
  bool _evidenceRemoved = false;
  bool _evidenceSaveFailed = false;
  ExistingEvidenceRestorationStatus _restorationStatus =
      ExistingEvidenceRestorationStatus.none;
  int _restorationGeneration = 0;
  String? _unrestoredPhotoPath;
  String? _frozenEvidenceSha256;
  String? _frozenCanonicalPath;
  String? _errorMessage;
  double? _liveNormalizedScore;

  bool get _isEvidenceLocked =>
      _frozenEvidenceSha256 != null ||
      _frozenCanonicalPath != null ||
      (widget.initialDraft?.hasVerifiedEvidenceSnapshot ?? false) ||
      widget.initialDraft?.dispatchState ==
          CommandDispatchState.possiblyDispatched ||
      widget.initialDraft?.dispatchState ==
          CommandDispatchState.confirmedCommitted;

  @override
  void initState() {
    super.initState();
    _evidenceRemoved = false;
    final draft = widget.initialDraft;
    if (draft != null) {
      _localDraftId = draft.localDraftId;
      _createCommandId = draft.createCommandId;
      _submitCommandId = draft.submitCommandId;
      _evidenceId = draft.evidenceId;
      _serverAssessmentId = draft.serverAssessmentId;
      _isQuarantined = draft.isLegacyUnknown;
      _selectedSubjectKey = draft.subjectKey;
      _subjectController = TextEditingController(text: draft.subject);
      _titleController = TextEditingController(text: draft.title);
      _rawScoreController = TextEditingController(
        text: draft.rawScore > 0 ? draft.rawScore.toString() : '',
      );
      _maxScoreController = TextEditingController(
        text: draft.maxScore.toString(),
      );
      _selectedType = AssessmentType.fromValue(draft.assessmentType);
      _selectedDifficulty = AssessmentDifficulty.fromValue(draft.difficulty);
      _occurredAt = normalizeAssessmentOccurredAt(draft.occurredAt);
      if (draft.hasVerifiedEvidenceSnapshot) {
        _frozenEvidenceSha256 = draft.sha256Checksum;
        _frozenCanonicalPath = draft.localCompressedPhotoPath;
        _unrestoredPhotoPath =
            draft.localPhotoPath ?? draft.localCompressedPhotoPath;
        _restorationStatus = ExistingEvidenceRestorationStatus.loading;
        _restoreCanonicalEvidenceSnapshot(draft);
      } else if (draft.localPhotoPath != null) {
        _unrestoredPhotoPath = draft.localPhotoPath;
        _restorationStatus = ExistingEvidenceRestorationStatus.loading;
        _restoreEvidenceFile(draft.localPhotoPath!);
      } else {
        _restorationStatus = ExistingEvidenceRestorationStatus.none;
      }
    } else {
      _localDraftId = generateUuid();
      _createCommandId = generateUuid();
      _submitCommandId = generateUuid();
      _evidenceId = null;
      _serverAssessmentId = null;
      _isQuarantined = false;
      _selectedSubjectKey = SubjectKey.math;
      _subjectController = TextEditingController(
        text: SubjectKey.math.displayLabel,
      );
      _titleController = TextEditingController();
      _rawScoreController = TextEditingController();
      _maxScoreController = TextEditingController(text: '10');
      _selectedType = AssessmentType.quiz;
      _selectedDifficulty = AssessmentDifficulty.normal;
      _occurredAt = normalizeAssessmentOccurredAt(DateTime.now());
      _restorationStatus = ExistingEvidenceRestorationStatus.none;
    }

    _rawScoreController.addListener(_updateScorePreview);
    _maxScoreController.addListener(_updateScorePreview);
    _updateScorePreview();
  }

  Future<void> _restoreCanonicalEvidenceSnapshot(
    LocalAssessmentDraft draft,
  ) async {
    final generation = ++_restorationGeneration;
    try {
      final store = ref.read(localEvidenceFileStoreProvider);
      final verified = await store.readVerifiedCanonicalSnapshot(draft: draft);
      if (!mounted || generation != _restorationGeneration) return;

      final sourcePath =
          draft.localCompressedPhotoPath ?? draft.localPhotoPath ?? '';
      final fileName = sourcePath.isNotEmpty
          ? sourcePath.split(RegExp(r'[/\\]')).last
          : 'evidence_${draft.localDraftId}.${verified.mediaType == 'image/png' ? 'png' : 'jpg'}';
      setState(() {
        _restorationStatus = ExistingEvidenceRestorationStatus.restored;
        _unrestoredPhotoPath = null;
        _selectedEvidence = SelectedEvidenceFile(
          bytes: verified.bytes,
          fileName: fileName,
          mediaType: verified.mediaType,
          localPath: draft.localPhotoPath ?? draft.localCompressedPhotoPath,
        );
      });
    } catch (_) {
      if (!mounted || generation != _restorationGeneration) return;
      setState(() {
        _restorationStatus =
            ExistingEvidenceRestorationStatus.missingOrUnreadable;
        _errorMessage =
            'Existing evidence snapshot could not be verified on this device. '
            'The draft cannot be submitted without valid evidence.';
      });
    }
  }

  Future<void> _restoreEvidenceFile(String path) async {
    final generation = ++_restorationGeneration;
    try {
      final store = ref.read(localEvidenceFileStoreProvider);
      final bytes = await store.loadEvidence(path);
      if (!mounted || generation != _restorationGeneration) return;

      if (bytes != null) {
        final fileName = path.split(RegExp(r'[/\\]')).last;
        final mediaType = fileName.toLowerCase().endsWith('.png')
            ? 'image/png'
            : 'image/jpeg';
        setState(() {
          _restorationStatus = ExistingEvidenceRestorationStatus.restored;
          _unrestoredPhotoPath = null;
          _selectedEvidence = SelectedEvidenceFile(
            bytes: bytes,
            fileName: fileName,
            mediaType: mediaType,
            localPath: path,
          );
        });
      } else {
        setState(() {
          _restorationStatus =
              ExistingEvidenceRestorationStatus.missingOrUnreadable;
          _errorMessage =
              'Existing evidence file is missing or unreadable (${path.split(RegExp(r"[/\\]")).last}). '
              'The draft cannot be saved or submitted without evidence. '
              'Please attach a replacement photo or explicitly remove the attachment.';
        });
      }
    } catch (e) {
      if (!mounted || generation != _restorationGeneration) return;
      setState(() {
        _restorationStatus =
            ExistingEvidenceRestorationStatus.missingOrUnreadable;
        _errorMessage =
            'Failed to read existing evidence file: $e. '
            'The draft cannot be saved or submitted without evidence. '
            'Please attach a replacement photo or explicitly remove the attachment.';
      });
    }
  }

  @override
  void dispose() {
    _rawScoreController.dispose();
    _maxScoreController.dispose();
    _subjectController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _updateScorePreview() {
    final raw = double.tryParse(_rawScoreController.text.trim());
    final max = double.tryParse(_maxScoreController.text.trim());
    if (raw != null && max != null && max > 0 && raw >= 0 && raw <= max) {
      setState(() {
        _liveNormalizedScore = ((raw / max * 10.0) * 100).round() / 100.0;
      });
    } else {
      setState(() {
        _liveNormalizedScore = null;
      });
    }
  }

  static const String _frozenEvidenceLockedReplaceMessage =
      'Evidence photo is already locked for this draft and cannot be replaced or removed. Start a new assessment draft to attach a different photo.';

  static const String _frozenEvidenceLockedRemoveMessage =
      'Evidence photo is already locked for this draft and cannot be removed or replaced. Start a new assessment draft to submit without this photo.';

  Future<LocalAssessmentDraft?> _loadLatestKnownDraft() async {
    final persisted = await ref
        .read(localDraftStoreProvider)
        .getLocalDraft(_localDraftId);
    final latest = persisted ?? widget.initialDraft;
    if (latest != null && latest.hasVerifiedEvidenceSnapshot) {
      _frozenEvidenceSha256 ??= latest.sha256Checksum;
      _frozenCanonicalPath ??= latest.localCompressedPhotoPath;
    }
    return latest;
  }

  Future<void> _pickEvidence() async {
    final picker = ref.read(evidencePickerServiceProvider);
    final file = await picker.pickEvidencePhoto();
    if (file == null) return;

    if (file.bytes.isEmpty) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'The selected photo is empty. Please choose a valid JPEG or PNG photo.';
      });
      return;
    }

    if (file.bytes.length > 10 * 1024 * 1024) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'The selected photo exceeds the 10 MB limit (${(file.bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB). Please choose a smaller photo.';
      });
      return;
    }

    if (file.mediaType != 'image/jpeg' && file.mediaType != 'image/png') {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Only JPEG and PNG photos are supported.';
      });
      return;
    }

    // R33-08: Reject replacement once a canonical snapshot has been frozen or dispatch started.
    // Preserve both the original canonical file and newly selected file on disk without deletion.
    final latestDraft = await _loadLatestKnownDraft();
    final frozenSha256 =
        _frozenEvidenceSha256 ??
        ((latestDraft?.hasVerifiedEvidenceSnapshot ?? false)
            ? latestDraft?.sha256Checksum
            : null);
    final isDispatchedOrCommitted =
        latestDraft != null &&
        (latestDraft.dispatchState == CommandDispatchState.possiblyDispatched ||
            latestDraft.dispatchState ==
                CommandDispatchState.confirmedCommitted);
    if (frozenSha256 != null || isDispatchedOrCommitted) {
      final pickedSha256 = computeSha256Hex(file.bytes);
      final currentBytes = _selectedEvidence?.bytes;
      final matchesFrozenDigest =
          frozenSha256 != null &&
          pickedSha256 == frozenSha256 &&
          (currentBytes == null || currentBytes.length == file.bytes.length);
      if (!matchesFrozenDigest) {
        if (!mounted) return;
        setState(() {
          _errorMessage = _frozenEvidenceLockedReplaceMessage;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _errorMessage = null;
      });
      return;
    }

    try {
      final fileStore = ref.read(localEvidenceFileStoreProvider);
      final savedPath = await fileStore.saveEvidence(
        fileName: file.fileName,
        bytes: file.bytes,
      );
      _restorationGeneration++;
      if (!mounted) return;
      setState(() {
        _evidenceSaveFailed = false;
        _evidenceRemoved = false;
        _unrestoredPhotoPath = null;
        _restorationStatus = ExistingEvidenceRestorationStatus.restored;
        _evidenceId ??= widget.initialDraft?.evidenceId ?? generateUuid();
        _selectedEvidence = SelectedEvidenceFile(
          bytes: file.bytes,
          fileName: file.fileName,
          mediaType: file.mediaType,
          localPath: savedPath,
        );
        _errorMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // R26-5-01: Evidence persistence failure must not be treated as success.
        // Do NOT silently accept an unsaved picked file as durable evidence.
        // Preserve any previously attached photo and display an actionable error.
        _evidenceSaveFailed = true;
        _errorMessage = 'Could not save evidence photo locally. Please check device storage and try again.';
      });
    }
  }

  Future<void> _removeEvidence() async {
    // R33-08: Once a canonical snapshot is frozen or dispatch has started, removal
    // must fail closed without clearing displayed evidence, rotating IDs, or deleting files.
    final latestDraft = await _loadLatestKnownDraft();
    final isFrozenOrDispatched =
        _frozenEvidenceSha256 != null ||
        _frozenCanonicalPath != null ||
        (latestDraft?.hasVerifiedEvidenceSnapshot ?? false) ||
        latestDraft?.dispatchState == CommandDispatchState.possiblyDispatched ||
        latestDraft?.dispatchState == CommandDispatchState.confirmedCommitted;
    if (isFrozenOrDispatched) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _frozenEvidenceLockedRemoveMessage;
      });
      return;
    }

    // B01: Do NOT physically delete the file here!
    // Removing an image from the UI must not immediately unlink its physical file.
    // Keep original evidence available on disk until a new draft state is durably
    // committed and a safe cleanup decision is authorized.
    _restorationGeneration++;
    setState(() {
      _evidenceRemoved = true;
      _restorationStatus = ExistingEvidenceRestorationStatus.removed;
      _unrestoredPhotoPath = null;
      _selectedEvidence = null;
      _evidenceId = null;
      _evidenceSaveFailed = false;
      _errorMessage = null;
    });
  }

  static CommandDispatchState _resolveSafeDispatchState(
    LocalAssessmentDraft? prior,
  ) {
    if (prior == null) {
      return CommandDispatchState.neverDispatched;
    }
    if (prior.dispatchState == CommandDispatchState.unknownLegacy) {
      return CommandDispatchState.unknownLegacy;
    }
    if (prior.dispatchState == CommandDispatchState.possiblyDispatched) {
      return CommandDispatchState.possiblyDispatched;
    }
    if (prior.dispatchState == CommandDispatchState.confirmedCommitted) {
      return CommandDispatchState.confirmedCommitted;
    }
    return CommandDispatchState.neverDispatched;
  }

  Future<void> _saveLocalDraft() async {
    // R26-6-01: Evidence restoration in progress or missing/unreadable must fail closed.
    if (_restorationStatus == ExistingEvidenceRestorationStatus.loading) {
      setState(() {
        _errorMessage = 'Evidence restoration is in progress. Please wait a moment before saving.';
      });
      return;
    }
    if (_restorationStatus ==
        ExistingEvidenceRestorationStatus.missingOrUnreadable) {
      setState(() {
        _errorMessage =
            'Cannot save draft: existing evidence is missing or unreadable. '
            'Please attach a replacement photo or explicitly remove the attachment.';
      });
      return;
    }

    // R26-5-01: If newly selected evidence persistence failed, do not report draft saved locally.
    if (_evidenceSaveFailed) {
      setState(() {
        _errorMessage = 'Cannot save draft: the selected photo could not be saved locally. Please re-select a photo or remove it.';
      });
      return;
    }

    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) return;

    final store = ref.read(localDraftStoreProvider);
    final existingFromStore = await store.getLocalDraft(_localDraftId);
    final prior = existingFromStore ?? widget.initialDraft;

    final isLegacy =
        (prior?.isLegacyUnknown ?? false) ||
        _isQuarantined ||
        (widget.initialDraft?.isLegacyUnknown ?? false);

    if (isLegacy) {
      _isQuarantined = true;
    }

    final String? resolvedCreateCommandId;
    final String? resolvedSubmitCommandId;
    final String? resolvedActorUserId;
    final String? resolvedActorRole;
    final CommandDispatchState resolvedDispatchState;

    if (isLegacy) {
      // For unknown_legacy drafts, preserve all existing command IDs, actor identity,
      // and dispatchState exactly as stored. Preserve NULL as NULL.
      // Never generate replacement command IDs or backfill actorUserId from the current user during ordinary local editing.
      resolvedCreateCommandId = prior?.createCommandId;
      resolvedSubmitCommandId = prior?.submitCommandId;
      resolvedActorUserId = prior?.actorUserId;
      resolvedActorRole = prior?.actorRole;
      resolvedDispatchState = CommandDispatchState.unknownLegacy;
    } else {
      // Fresh v5 drafts generate and preserve stable command IDs for genuinely new operations.
      _createCommandId ??= prior?.createCommandId ?? generateUuid();
      _submitCommandId ??= prior?.submitCommandId ?? generateUuid();
      resolvedCreateCommandId = _createCommandId;
      resolvedSubmitCommandId = _submitCommandId;
      if (prior != null) {
        // Never adopt or backfill actorUserId onto an existing draft row (R33-01).
        resolvedActorUserId = prior.actorUserId;
      } else {
        var freshActorId = ref.read(currentUserIdProvider);
        if (freshActorId == null) {
          try {
            freshActorId =
                (await ref.read(authSessionPortProvider).validateForMutation())
                    ?.userId;
          } catch (_) {}
        }
        resolvedActorUserId = freshActorId;
      }
      resolvedActorRole = prior?.actorRole;
      resolvedDispatchState = _resolveSafeDispatchState(prior);
    }

    final resolvedEvidenceId = _evidenceRemoved
        ? null
        : (_evidenceId ?? prior?.evidenceId);
    final resolvedServerAssessmentId =
        _serverAssessmentId ?? prior?.serverAssessmentId;
    final resolvedPhotoPath = _evidenceRemoved
        ? null
        : (_selectedEvidence?.localPath ?? prior?.localPhotoPath);

    if (!_evidenceRemoved && _selectedEvidence != null) {
      final fileStore = ref.read(localEvidenceFileStoreProvider);
      final verifiedBytes = _selectedEvidence!.localPath != null
          ? await fileStore.readEvidenceBytes(_selectedEvidence!.localPath!)
          : null;
      if (verifiedBytes == null) {
        setState(() {
          _errorMessage = 'Cannot save draft: the selected photo could not be verified in local storage. Please re-select a photo or remove it.';
        });
        return;
      }
    }

    final isLockedForSave =
        _frozenEvidenceSha256 != null ||
        _frozenCanonicalPath != null ||
        (prior?.hasVerifiedEvidenceSnapshot ?? false) ||
        prior?.dispatchState == CommandDispatchState.possiblyDispatched ||
        prior?.dispatchState == CommandDispatchState.confirmedCommitted;
    if (isLockedForSave) {
      final frozenSha = _frozenEvidenceSha256 ?? prior?.sha256Checksum;
      final selectedMismatch =
          _evidenceRemoved ||
          (frozenSha != null &&
              _selectedEvidence != null &&
              computeSha256Hex(_selectedEvidence!.bytes) != frozenSha);
      if (selectedMismatch) {
        setState(() {
          _errorMessage = _evidenceRemoved
              ? _frozenEvidenceLockedRemoveMessage
              : _frozenEvidenceLockedReplaceMessage;
        });
        return;
      }
    }

    final raw = double.tryParse(_rawScoreController.text.trim()) ?? 0.0;
    final max = double.tryParse(_maxScoreController.text.trim()) ?? 10.0;
    final normalizedSubject = normalizeAssessmentSubject(
      _subjectController.text,
      fallbackSubjectKey: _selectedSubjectKey,
    );
    final normalizedTitle = normalizeAssessmentTitle(
      _titleController.text,
      fallbackTitle: 'Draft Assessment',
    );
    final normalizedOccurredAt = normalizeAssessmentOccurredAt(_occurredAt);
    final resolvedEntryContext =
        prior?.entryContext ?? EntryContext.sharedChild;

    final draft = LocalAssessmentDraft(
      localDraftId: _localDraftId,
      familyId: activeChild.familyId.value,
      childId: activeChild.id.value,
      createCommandId: resolvedCreateCommandId,
      submitCommandId: resolvedSubmitCommandId,
      evidenceId: resolvedEvidenceId,
      serverAssessmentId: resolvedServerAssessmentId,
      subjectKey: _selectedSubjectKey,
      subject: normalizedSubject,
      title: normalizedTitle,
      assessmentType: _selectedType.value,
      difficulty: _selectedDifficulty.value,
      rawScore: raw,
      maxScore: max,
      localPhotoPath: resolvedPhotoPath,
      occurredAt: normalizedOccurredAt,
      updatedAt: DateTime.now().toUtc(),
      entryContext: resolvedEntryContext,
      serverEvidenceId: prior?.serverEvidenceId,
      sha256Checksum: prior?.sha256Checksum,
      localCompressedPhotoPath: prior?.localCompressedPhotoPath,
      submissionStatus: prior?.submissionStatus ?? DraftSubmissionStatus.draft,
      retryCount: prior?.retryCount ?? 0,
      dispatchState: resolvedDispatchState,
      lastErrorMessage: prior?.lastErrorMessage,
      actorUserId: resolvedActorUserId,
      actorRole: resolvedActorRole,
    );

    try {
      await store.saveLocalDraft(draft);

      // Phase 6 Slice 4B-0 (R26-3-02):
      // Conservative evidence retention: when replacing a photo on a draft,
      // the prior physical evidence file is intentionally retained on disk
      // to guarantee zero unverified data loss across concurrent drafts and recovery.

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Draft saved locally.')));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e is DraftWriteConflictException
              ? 'Cannot save changes: this draft is locked or requires recovery reconciliation.'
              : 'Could not save draft locally. Please check storage space and try again.';
        });
      }
    }
  }

  Future<void> _submitAssessment() async {
    final store = ref.read(localDraftStoreProvider);
    final existingFromStore = await store.getLocalDraft(_localDraftId);
    if (widget.initialDraft != null && existingFromStore == null) {
      setState(() {
        _errorMessage = 'Local draft record is missing from storage. Reopen drafts before submitting.';
      });
      return;
    }
    final prior = existingFromStore ?? widget.initialDraft;

    final isQuarantined =
        (prior?.isLegacyUnknown ?? false) ||
        (prior?.hasUnboundActor ?? false) ||
        (prior?.isReadOnlyQuarantined ?? false) ||
        (prior?.hasMalformedLease ?? false) ||
        _isQuarantined;
    if (isQuarantined) {
      setState(() {
        _isQuarantined = true;
        _errorMessage = 'Cannot submit a quarantined legacy draft. Recovery reconciliation is required.';
      });
      return;
    }
    if (prior != null &&
        (prior.dispatchState == CommandDispatchState.confirmedCommitted ||
            prior.hasWaitingOriginalActorMarker ||
            prior.submissionStatus == DraftSubmissionStatus.terminalError ||
            (prior.hasRecoveryMarker &&
                prior.recoveryCode != DraftRecoveryCode.retryScheduled) ||
            prior.leaseToken != null ||
            prior.leaseExpiresAt != null)) {
      setState(() {
        _errorMessage = 'Cannot submit this draft directly while recovery reconciliation or active lease processing is pending.';
      });
      return;
    }

    // R26-6-01: Evidence restoration in progress or missing/unreadable must fail closed.
    if (_restorationStatus == ExistingEvidenceRestorationStatus.loading) {
      setState(() {
        _errorMessage = 'Evidence restoration is in progress. Please wait a moment before submitting.';
      });
      return;
    }
    if (_restorationStatus ==
        ExistingEvidenceRestorationStatus.missingOrUnreadable) {
      setState(() {
        _errorMessage = _isEvidenceLocked
            ? 'Cannot submit assessment: the locked evidence photo snapshot is missing or corrupted on disk and cannot be replaced.'
            : 'Cannot submit assessment: existing evidence is missing or unreadable. '
                  'Please attach a replacement photo or explicitly remove the attachment.';
      });
      return;
    }

    // R33-08: Fail closed in UI boundary if frozen snapshot was marked removed or diverged.
    if ((prior?.hasVerifiedEvidenceSnapshot ?? false) ||
        _frozenEvidenceSha256 != null) {
      if (_evidenceRemoved) {
        setState(() {
          _errorMessage = _frozenEvidenceLockedRemoveMessage;
        });
        return;
      }
      final expectedSha = _frozenEvidenceSha256 ?? prior?.sha256Checksum;
      final displayed = _selectedEvidence;
      if (displayed != null &&
          expectedSha != null &&
          computeSha256Hex(displayed.bytes) != expectedSha) {
        setState(() {
          _errorMessage = _frozenEvidenceLockedReplaceMessage;
        });
        return;
      }
    }

    // R26-5-01: Do not begin a remote submission involving a newly selected attachment whose durable persistence failed.
    if (_evidenceSaveFailed) {
      setState(() {
        _errorMessage = 'Cannot submit assessment: the selected photo could not be saved locally. Please re-select a photo or remove it.';
      });
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) {
      setState(() => _errorMessage = 'No active child session');
      return;
    }

    final raw = double.parse(_rawScoreController.text.trim());
    final max = double.parse(_maxScoreController.text.trim());

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(assessmentRepositoryProvider);
      final storage = ref.read(assessmentEvidenceStorageProvider);
      final fileStore = ref.read(localEvidenceFileStoreProvider);
      final authPort = ref.read(authSessionPortProvider);

      // R31-08: Authoritative live session validation before staging/dispatch.
      final validatedActor = await assertValidStorageAuthSession(
        authSessionPort: authPort,
        storagePath: '',
        stage: 'assessment UI preflight',
      );
      if (!validatedActor.isValidAt(DateTime.now().toUtc())) {
        throw EvidenceStorageAuthException(
          const AuthFailureOutcome(
            storagePath: '',
            reason: 'Session expired before assessment submission.',
          ),
        );
      }
      if (prior != null) {
        if (prior.actorUserId == null ||
            prior.actorUserId!.trim().isEmpty ||
            prior.actorUserId != validatedActor.userId) {
          throw EvidenceStorageAuthException(
            const AuthFailureOutcome(
              storagePath: '',
              reason: 'Authenticated actor does not match the original local draft author.',
            ),
          );
        }
        if (prior.familyId != activeChild.familyId.value ||
            prior.childId != activeChild.id.value) {
          throw const InvalidAssessmentException(
            'Active child selection does not match the original draft scope.',
          );
        }
      }

      if (!_evidenceRemoved &&
          _selectedEvidence != null &&
          _evidenceId == null) {
        _evidenceId = prior?.evidenceId ?? generateUuid();
      }

      _createCommandId ??= prior?.createCommandId ?? generateUuid();
      _submitCommandId ??= prior?.submitCommandId ?? generateUuid();
      _serverAssessmentId ??= prior?.serverAssessmentId;

      final isDispatchedRetry =
          prior != null &&
          prior.dispatchState == CommandDispatchState.possiblyDispatched;

      final normalizedSubject = isDispatchedRetry
          ? normalizeAssessmentSubject(prior.subject)
          : normalizeAssessmentSubject(
              _subjectController.text,
              fallbackSubjectKey: _selectedSubjectKey,
            );
      final normalizedTitle = isDispatchedRetry
          ? normalizeAssessmentTitle(prior.title)
          : normalizeAssessmentTitle(
              _titleController.text,
              fallbackTitle: 'Draft Assessment',
            );
      final normalizedOccurredAt = normalizeAssessmentOccurredAt(
        isDispatchedRetry ? prior.occurredAt : _occurredAt,
      );
      final resolvedEntryContext =
          prior?.entryContext ?? EntryContext.sharedChild;

      void assertDisplayedSelectionMatchesFrozen(
        VerifiedCanonicalEvidence verified,
        String? boundEvidenceId,
      ) {
        if (_evidenceRemoved) {
          throw const CanonicalEvidenceValidationException(
            CanonicalEvidenceValidationCode.sha256Mismatch,
            'Locked evidence photo cannot be removed from this draft.',
          );
        }
        final displayed = _selectedEvidence;
        if (displayed == null ||
            displayed.bytes.length != verified.bytes.length ||
            computeSha256Hex(displayed.bytes) != verified.sha256Checksum ||
            displayed.mediaType != verified.mediaType) {
          throw const CanonicalEvidenceValidationException(
            CanonicalEvidenceValidationCode.sha256Mismatch,
            'Displayed evidence photo does not match this draft\'s locked canonical snapshot.',
          );
        }
        if (boundEvidenceId != null &&
            _evidenceId != null &&
            _evidenceId != boundEvidenceId) {
          throw DraftSubmissionCasException(
            stage: DraftCasFailureStage.registerPreDispatchDraft,
            localDraftId: _localDraftId,
            casStatus: DraftCasStatus.casConflict,
            message: 'Displayed evidenceId does not match the bound canonical draft evidenceId.',
          );
        }
      }

      List<int>? dispatchEvidenceBytes;
      String? dispatchEvidenceMediaType;
      String? dispatchEvidenceIdStr;

      if (isDispatchedRetry) {
        if (prior.hasVerifiedEvidenceSnapshot) {
          final verified = await fileStore.readVerifiedCanonicalSnapshot(
            draft: prior,
          );
          assertDisplayedSelectionMatchesFrozen(verified, prior.evidenceId);
          dispatchEvidenceBytes = verified.bytes;
          dispatchEvidenceMediaType = verified.mediaType;
          dispatchEvidenceIdStr = prior.evidenceId;
        } else if ((prior.evidenceId?.isNotEmpty ?? false) ||
            (prior.localPhotoPath?.isNotEmpty ?? false)) {
          throw MissingCanonicalEvidenceSnapshotException(
            localDraftId: prior.localDraftId,
            message: 'Cannot resume evidence draft without a verified canonical snapshot.',
          );
        }
      } else {
        final resolvedPhotoPath = _evidenceRemoved
            ? null
            : (_selectedEvidence?.localPath ?? prior?.localPhotoPath);
        var resolvedEvidenceId = _evidenceRemoved
            ? null
            : (_evidenceId ?? prior?.evidenceId);
        var resolvedCompressedPath = prior?.localCompressedPhotoPath;
        var resolvedSha256 = prior?.sha256Checksum;

        final hasAttachedEvidence =
            !_evidenceRemoved &&
            (_selectedEvidence != null ||
                (resolvedPhotoPath?.isNotEmpty ?? false) ||
                (prior?.hasVerifiedEvidenceSnapshot ?? false));

        if (hasAttachedEvidence) {
          if (prior != null && prior.hasVerifiedEvidenceSnapshot) {
            final verified = await fileStore.readVerifiedCanonicalSnapshot(
              draft: prior,
            );
            assertDisplayedSelectionMatchesFrozen(verified, prior.evidenceId);
            dispatchEvidenceBytes = verified.bytes;
            dispatchEvidenceMediaType = verified.mediaType;
            dispatchEvidenceIdStr = prior.evidenceId;
            resolvedEvidenceId = prior.evidenceId;
            resolvedCompressedPath = prior.localCompressedPhotoPath;
            resolvedSha256 = prior.sha256Checksum;
          } else {
            final diskBytes = resolvedPhotoPath != null
                ? await fileStore.readEvidenceBytes(resolvedPhotoPath)
                : null;
            if (diskBytes == null || diskBytes.isEmpty) {
              throw const InvalidAssessmentException(
                'Cannot submit assessment: attached evidence bytes are missing or empty.',
              );
            }
            resolvedEvidenceId ??= generateUuid();
            _evidenceId = resolvedEvidenceId;
            final snapshot = await fileStore.saveCanonicalEvidenceSnapshot(
              localDraftId: _localDraftId,
              bytes: diskBytes,
            );
            resolvedCompressedPath = snapshot.filePath;
            resolvedSha256 = snapshot.sha256Checksum;
            dispatchEvidenceBytes = diskBytes;
            dispatchEvidenceMediaType = snapshot.mediaType;
            dispatchEvidenceIdStr = resolvedEvidenceId;

            // Revalidate session generation across canonical snapshot write.
            await assertValidStorageAuthSession(
              authSessionPort: authPort,
              storagePath: '',
              context: validatedActor,
              expectedSessionGeneration: validatedActor.sessionGeneration,
              stage: 'assessment canonical evidence staging',
            );
          }
        }

        final nowUtc = DateTime.now().toUtc();
        final localDraft = LocalAssessmentDraft(
          localDraftId: _localDraftId,
          familyId: activeChild.familyId.value,
          childId: activeChild.id.value,
          createCommandId: _createCommandId,
          submitCommandId: _submitCommandId,
          evidenceId: resolvedEvidenceId,
          serverAssessmentId: _serverAssessmentId,
          subjectKey: _selectedSubjectKey,
          subject: normalizedSubject,
          title: normalizedTitle,
          assessmentType: _selectedType.value,
          difficulty: _selectedDifficulty.value,
          rawScore: raw,
          maxScore: max,
          localPhotoPath: resolvedPhotoPath,
          occurredAt: normalizedOccurredAt,
          updatedAt: nowUtc,
          entryContext: resolvedEntryContext,
          serverEvidenceId: prior?.serverEvidenceId,
          sha256Checksum: resolvedSha256,
          localCompressedPhotoPath: resolvedCompressedPath,
          submissionStatus:
              prior?.submissionStatus ?? DraftSubmissionStatus.draft,
          retryCount: prior?.retryCount ?? 0,
          dispatchState: CommandDispatchState.neverDispatched,
          lastErrorMessage: null,
          actorUserId: prior?.actorUserId ?? validatedActor.userId,
          actorRole: prior?.actorRole ?? validatedActor.role,
        );

        final regResult = await store.registerOrUpdateDraftIfUnchanged(
          expected: existingFromStore,
          desired: localDraft,
          now: nowUtc,
        );
        if (!regResult.isSuccess) {
          throw DraftSubmissionCasException(
            stage: DraftCasFailureStage.registerPreDispatchDraft,
            localDraftId: _localDraftId,
            casStatus: regResult.status,
            serverAssessmentId: _serverAssessmentId,
            message:
                'Failed to persist pre-dispatch local draft journal (${regResult.status.name}).',
          );
        }
        if (resolvedSha256 != null && resolvedCompressedPath != null) {
          _frozenEvidenceSha256 = resolvedSha256;
          _frozenCanonicalPath = resolvedCompressedPath;
        }
      }

      final submitUseCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        localDraftStore: store,
        canonicalSnapshotStore: fileStore,
        authSessionPort: authPort,
      );

      final evidenceIdObj = dispatchEvidenceIdStr != null
          ? EvidenceId(dispatchEvidenceIdStr)
          : null;

      await submitUseCase(
        createCommandId: isDispatchedRetry
            ? (prior.createCommandId ?? _createCommandId!)
            : _createCommandId!,
        submitCommandId: isDispatchedRetry
            ? (prior.submitCommandId ?? _submitCommandId!)
            : _submitCommandId!,
        familyId: activeChild.familyId,
        childId: activeChild.id,
        subjectKey: isDispatchedRetry ? prior.subjectKey : _selectedSubjectKey,
        subject: normalizedSubject,
        title: normalizedTitle,
        type: isDispatchedRetry
            ? AssessmentType.values.firstWhere(
                (t) => t.value == prior.assessmentType,
                orElse: () => _selectedType,
              )
            : _selectedType,
        difficulty: isDispatchedRetry
            ? AssessmentDifficulty.values.firstWhere(
                (d) => d.value == prior.difficulty,
                orElse: () => _selectedDifficulty,
              )
            : _selectedDifficulty,
        score: isDispatchedRetry
            ? AssessmentScore(
                rawScore: prior.rawScore,
                maxScore: prior.maxScore,
              )
            : AssessmentScore(rawScore: raw, maxScore: max),
        occurredAt: normalizedOccurredAt,
        entryContext: resolvedEntryContext,
        evidenceBytes: dispatchEvidenceBytes,
        evidenceMediaType: dispatchEvidenceMediaType,
        evidenceId: evidenceIdObj,
        localDraftId: _localDraftId,
        context: validatedActor,
        expectedSessionGeneration: validatedActor.sessionGeneration,
      );

      // B03: Do NOT delete physical evidence solely because submission returned.
      // Local evidence bytes are preserved on disk for durability and future reconciliation.

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Assessment submitted for review!'),
            backgroundColor: Colors.green,
          ),
        );
        context.pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = _mapFriendlyError(e);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  String _mapFriendlyError(Object error) {
    if (error is AssessmentReconciliationPendingException) {
      return 'Assessment was submitted to the server, and this device preserved your draft and photo pending local sync confirmation.';
    }
    if (error is DraftSubmissionCasException) {
      return 'Could not safely update your local draft state before syncing. Your draft and photo remain preserved on this device.';
    }
    if (error is MissingLocalDraftJournalException ||
        error is MissingCanonicalEvidenceSnapshotException) {
      return 'Could not verify your local draft journal or photo snapshot before submitting. Your data has not been submitted.';
    }
    if (error is CanonicalEvidenceValidationException) {
      return switch (error.code) {
        CanonicalEvidenceValidationCode.emptyBytes =>
          'Attached photo cannot be empty. Please select another file.',
        CanonicalEvidenceValidationCode.oversizedBytes =>
          'Attached photo exceeds the allowed size limit (10 MiB).',
        CanonicalEvidenceValidationCode.unsupportedMagicBytes =>
          'Unsupported photo format. Please attach a JPEG or PNG image.',
        CanonicalEvidenceValidationCode.sha256Mismatch ||
        CanonicalEvidenceValidationCode.lengthMismatch ||
        CanonicalEvidenceValidationCode.mediaTypeMismatch => 'The selected photo does not match this draft\'s locked evidence snapshot and cannot replace it. Start a new assessment draft to use a different photo.',
        _ => 'Attached photo failed local integrity verification and cannot be submitted.',
      };
    }
    if (error is EvidenceStorageException) {
      return 'Could not read or save the attached photo safely on this device.';
    }
    if (error is EvidenceStorageAuthException) {
      return 'Your session is no longer valid. Please sign in again to continue.';
    }
    if (error is EvidenceStorageConflictException) {
      return 'Attached photo could not be reconciled safely with remote storage. Your draft is saved on this device.';
    }
    if (error is EvidenceStorageUnknownOutcomeException) {
      return 'Could not verify photo upload status. Your draft is saved on this device. Please try again.';
    }
    if (error is InvalidAssessmentException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('empty')) {
        return 'Attached photo cannot be empty. Please select another file.';
      }
      if (msg.contains('10 mib') || msg.contains('size')) {
        return 'Attached photo exceeds the allowed size limit (10 MiB).';
      }
      if (msg.contains('media type')) {
        return 'Unsupported photo format. Please attach a JPEG or PNG image.';
      }
      return 'Please check the assessment details and try again.';
    }
    final str = error.toString().toLowerCase();
    if (str.contains('socketexception') ||
        str.contains('clientexception') ||
        str.contains('network') ||
        str.contains('connection') ||
        str.contains('timed out')) {
      return 'Could not connect to the server. Your work is saved on this device. Please try again when online.';
    }
    if (str.contains('42501') || str.contains('permission denied')) {
      return 'You do not have permission to submit assessments for this family.';
    }
    if (str.contains('lw101') || str.contains('version')) {
      return 'This assessment was updated elsewhere. Please refresh.';
    }
    if (str.contains('maximum size') || str.contains('exceeds')) {
      return 'Attached photo exceeds the allowed size limit (10 MB).';
    }
    return 'Failed to submit assessment. Please check your connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initialDraft != null
              ? 'Edit Assessment Draft'
              : 'Add Assessment Result',
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_isQuarantined ||
                        (widget.initialDraft?.isLegacyUnknown ?? false)) ...[
                      Card(
                        key: const Key('legacy_draft_quarantine_banner'),
                        color: theme.colorScheme.tertiaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Row(
                            children: [
                              Icon(
                                Icons.warning_amber_rounded,
                                color: theme.colorScheme.onTertiaryContainer,
                              ),
                              const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: Text(
                                  'This draft was preserved from an earlier app version with unverified sync state. '
                                  'It has been quarantined for data safety and cannot be submitted directly. '
                                  'You may review or edit its contents and save locally.',
                                  style: TextStyle(
                                    color:
                                        theme.colorScheme.onTertiaryContainer,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (_errorMessage != null) ...[
                      Card(
                        color: theme.colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(
                                    color: theme.colorScheme.onErrorContainer,
                                  ),
                                ),
                              ),
                              if (_evidenceSaveFailed ||
                                  _restorationStatus ==
                                      ExistingEvidenceRestorationStatus
                                          .missingOrUnreadable)
                                TextButton(
                                  key: const Key(
                                    'dismiss_evidence_error_button',
                                  ),
                                  onPressed: () => setState(() {
                                    _errorMessage = null;
                                    _evidenceSaveFailed = false;
                                  }),
                                  child: const Text('Dismiss'),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    DropdownButtonFormField<SubjectKey>(
                      key: const Key('assessment_subject_key_dropdown'),
                      initialValue: _selectedSubjectKey,
                      decoration: const InputDecoration(
                        labelText: 'Academic Subject Area *',
                        prefixIcon: Icon(Icons.category),
                        border: OutlineInputBorder(),
                      ),
                      items: SubjectKey.values
                          .map(
                            (k) => DropdownMenuItem(
                              value: k,
                              child: Text(k.displayLabel),
                            ),
                          )
                          .toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _selectedSubjectKey = val;
                            if (_subjectController.text.isEmpty ||
                                SubjectKey.values.any(
                                  (s) =>
                                      s.displayLabel == _subjectController.text,
                                )) {
                              _subjectController.text = val.displayLabel;
                            }
                          });
                        }
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('assessment_subject_field'),
                      controller: _subjectController,
                      decoration: const InputDecoration(
                        labelText: 'Subject Detail *',
                        hintText: 'e.g. Mathematics, Algebra I, Biology',
                        prefixIcon: Icon(Icons.menu_book),
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) => (val == null || val.trim().isEmpty)
                          ? 'Subject is required'
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('assessment_title_field'),
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: 'Assessment Title *',
                        hintText: 'e.g. Fractions Chapter Quiz, Essay 1',
                        prefixIcon: Icon(Icons.assignment),
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) => (val == null || val.trim().isEmpty)
                          ? 'Title is required'
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<AssessmentType>(
                            key: const Key('assessment_type_dropdown'),
                            initialValue: _selectedType,
                            decoration: const InputDecoration(
                              labelText: 'Type',
                              border: OutlineInputBorder(),
                            ),
                            items: AssessmentType.values
                                .map(
                                  (t) => DropdownMenuItem(
                                    value: t,
                                    child: Text(t.name.toUpperCase()),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedType = val);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: DropdownButtonFormField<AssessmentDifficulty>(
                            key: const Key('assessment_difficulty_dropdown'),
                            initialValue: _selectedDifficulty,
                            decoration: const InputDecoration(
                              labelText: 'Difficulty',
                              border: OutlineInputBorder(),
                            ),
                            items: AssessmentDifficulty.values
                                .map(
                                  (d) => DropdownMenuItem(
                                    value: d,
                                    child: Text(d.name),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedDifficulty = val);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            key: const Key('assessment_raw_score_field'),
                            controller: _rawScoreController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Score *',
                              hintText: 'e.g. 8.5',
                              border: OutlineInputBorder(),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Required';
                              }
                              final numVal = double.tryParse(val.trim());
                              if (numVal == null || numVal < 0) {
                                return 'Invalid score';
                              }
                              final maxVal = double.tryParse(
                                _maxScoreController.text.trim(),
                              );
                              if (maxVal != null && numVal > maxVal) {
                                return 'Score > Max';
                              }
                              return null;
                            },
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                          ),
                          child: Text('/', style: TextStyle(fontSize: 24)),
                        ),
                        Expanded(
                          child: TextFormField(
                            key: const Key('assessment_max_score_field'),
                            controller: _maxScoreController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Out Of *',
                              hintText: 'e.g. 10',
                              border: OutlineInputBorder(),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Required';
                              }
                              final numVal = double.tryParse(val.trim());
                              if (numVal == null || numVal <= 0) {
                                return 'Must be > 0';
                              }
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    if (_liveNormalizedScore != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.trending_up,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              'Normalized Score: ${_liveNormalizedScore!.toStringAsFixed(2)} / 10.0',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    // Evidence Photo Attachment Section
                    Card(
                      elevation: 0,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.camera_alt_outlined, size: 20),
                                SizedBox(width: AppSpacing.sm),
                                Text(
                                  'Photo Evidence (Optional)',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            const Text(
                              'Attach a clear photo or worksheet scan for parent verification (max 10 MB, JPEG or PNG).',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            if (_restorationStatus ==
                                ExistingEvidenceRestorationStatus.loading)
                              Row(
                                children: [
                                  const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      'Verifying existing evidence photo...',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                                  TextButton.icon(
                                    key: const Key('attach_evidence_button'),
                                    icon: const Icon(
                                      Icons.add_a_photo,
                                      size: 16,
                                    ),
                                    label: const Text('Change Photo'),
                                    onPressed: _pickEvidence,
                                  ),
                                ],
                              )
                            else if (_restorationStatus ==
                                ExistingEvidenceRestorationStatus
                                    .missingOrUnreadable)
                              Container(
                                padding: const EdgeInsets.all(AppSpacing.sm),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.errorContainer
                                      .withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: theme.colorScheme.error,
                                    width: 1,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(
                                          Icons.broken_image_outlined,
                                          color: theme.colorScheme.error,
                                          size: 20,
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        Expanded(
                                          child: Text(
                                            'Attached photo is missing or unreadable on disk',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: theme.colorScheme.error,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: AppSpacing.xs),
                                    Text(
                                      _isEvidenceLocked
                                          ? 'Path: ${_unrestoredPhotoPath ?? 'unknown'}\n'
                                                'This draft\'s locked evidence snapshot is missing or corrupted on disk and cannot be replaced or removed.'
                                          : 'Path: ${_unrestoredPhotoPath ?? 'unknown'}\n'
                                                'To protect against data loss, you cannot save or submit until you attach a replacement photo or explicitly remove this attachment.',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color:
                                            theme.colorScheme.onErrorContainer,
                                      ),
                                    ),
                                    const SizedBox(height: AppSpacing.sm),
                                    Wrap(
                                      spacing: AppSpacing.sm,
                                      runSpacing: AppSpacing.xs,
                                      children: [
                                        OutlinedButton.icon(
                                          key: const Key(
                                            'attach_evidence_button',
                                          ),
                                          icon: const Icon(
                                            Icons.add_a_photo,
                                            size: 16,
                                          ),
                                          label: const Text(
                                            'Attach Replacement',
                                          ),
                                          onPressed: _pickEvidence,
                                        ),
                                        TextButton.icon(
                                          key: const Key(
                                            'remove_evidence_button',
                                          ),
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: 16,
                                          ),
                                          label: const Text(
                                            'Remove Attachment',
                                          ),
                                          onPressed: _removeEvidence,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              )
                            else if (_selectedEvidence != null)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(
                                        Icons.check_circle,
                                        color: Colors.green,
                                        size: 18,
                                      ),
                                      const SizedBox(width: AppSpacing.xs),
                                      Expanded(
                                        child: Text(
                                          '${_selectedEvidence!.fileName} (${(_selectedEvidence!.bytes.length / 1024).toStringAsFixed(1)} KB)',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      IconButton(
                                        key: const Key(
                                          'change_evidence_button',
                                        ),
                                        tooltip: _isEvidenceLocked
                                            ? 'Photo locked for this draft'
                                            : 'Change Photo',
                                        icon: const Icon(Icons.edit, size: 18),
                                        onPressed: _pickEvidence,
                                      ),
                                      IconButton(
                                        key: const Key(
                                          'remove_evidence_button',
                                        ),
                                        tooltip: _isEvidenceLocked
                                            ? 'Photo locked for this draft'
                                            : 'Remove Photo',
                                        icon: const Icon(Icons.close, size: 18),
                                        onPressed: _removeEvidence,
                                      ),
                                    ],
                                  ),
                                  if (_isEvidenceLocked)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        'Evidence photo locked for this draft. Start a new assessment draft to attach a different photo.',
                                        key: const Key(
                                          'frozen_evidence_locked_hint',
                                        ),
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                ],
                              )
                            else
                              OutlinedButton.icon(
                                key: const Key('attach_evidence_button'),
                                icon: const Icon(Icons.add_a_photo),
                                label: const Text('Attach Photo'),
                                onPressed: _pickEvidence,
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('save_draft_button'),
                            onPressed: _isSubmitting ? null : _saveLocalDraft,
                            child: const Text('Save Local Draft'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: FilledButton(
                            key: const Key('submit_assessment_button'),
                            onPressed:
                                (_isSubmitting ||
                                    _isQuarantined ||
                                    (widget.initialDraft?.isLegacyUnknown ??
                                        false))
                                ? null
                                : _submitAssessment,
                            child: _isSubmitting
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Submit for Review'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
