import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/utils/uuid_generator.dart';
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
  String? _errorMessage;
  double? _liveNormalizedScore;

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
      _occurredAt = draft.occurredAt;
      if (draft.localPhotoPath != null) {
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
      _occurredAt = DateTime.now();
      _restorationStatus = ExistingEvidenceRestorationStatus.none;
    }

    _rawScoreController.addListener(_updateScorePreview);
    _maxScoreController.addListener(_updateScorePreview);
    _updateScorePreview();
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

  Future<void> _pickEvidence() async {
    final picker = ref.read(evidencePickerServiceProvider);
    final file = await picker.pickEvidencePhoto();
    if (file == null) return;

    if (file.bytes.length > 10 * 1024 * 1024) {
      setState(() {
        _errorMessage =
            'The selected photo exceeds the 10 MB limit (${(file.bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB). Please choose a smaller photo.';
      });
      return;
    }

    if (file.mediaType != 'image/jpeg' && file.mediaType != 'image/png') {
      setState(() {
        _errorMessage = 'Only JPEG and PNG photos are supported.';
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
      resolvedActorUserId =
          prior?.actorUserId ?? ref.read(currentUserIdProvider);
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

    final raw = double.tryParse(_rawScoreController.text.trim()) ?? 0.0;
    final max = double.tryParse(_maxScoreController.text.trim()) ?? 10.0;

    final draft = LocalAssessmentDraft(
      localDraftId: _localDraftId,
      familyId: activeChild.familyId.value,
      childId: activeChild.id.value,
      createCommandId: resolvedCreateCommandId,
      submitCommandId: resolvedSubmitCommandId,
      evidenceId: resolvedEvidenceId,
      serverAssessmentId: resolvedServerAssessmentId,
      subjectKey: _selectedSubjectKey,
      subject: _subjectController.text.trim().isEmpty
          ? _selectedSubjectKey.displayLabel
          : _subjectController.text.trim(),
      title: _titleController.text.trim().isEmpty
          ? 'Draft Assessment'
          : _titleController.text.trim(),
      assessmentType: _selectedType.value,
      difficulty: _selectedDifficulty.value,
      rawScore: raw,
      maxScore: max,
      localPhotoPath: resolvedPhotoPath,
      occurredAt: _occurredAt,
      updatedAt: DateTime.now().toUtc(),
      entryContext: EntryContext.sharedChild,
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
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not save draft locally. Please check storage space and try again.';
        });
      }
    }
  }

  Future<void> _submitAssessment() async {
    final store = ref.read(localDraftStoreProvider);
    final existingFromStore = await store.getLocalDraft(_localDraftId);
    final prior = existingFromStore ?? widget.initialDraft;

    final isQuarantined = (prior?.isLegacyUnknown ?? false) || _isQuarantined;
    if (isQuarantined) {
      setState(() {
        _isQuarantined = true;
        _errorMessage = 'Cannot submit a quarantined legacy draft. Recovery reconciliation is required.';
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
        _errorMessage =
            'Cannot submit assessment: existing evidence is missing or unreadable. '
            'Please attach a replacement photo or explicitly remove the attachment.';
      });
      return;
    }

    // R26-5-01: Do not begin a remote submission involving a newly selected attachment whose durable persistence failed.
    if (_evidenceSaveFailed) {
      setState(() {
        _errorMessage = 'Cannot submit assessment: the selected photo could not be saved locally. Please re-select a photo or remove it.';
      });
      return;
    }

    if (!_evidenceRemoved && _selectedEvidence != null) {
      final fileStore = ref.read(localEvidenceFileStoreProvider);
      final verifiedBytes = _selectedEvidence!.localPath != null
          ? await fileStore.readEvidenceBytes(_selectedEvidence!.localPath!)
          : null;
      if (verifiedBytes == null) {
        setState(() {
          _errorMessage = 'Cannot submit assessment: the selected photo could not be verified in local storage. Please re-select a photo or remove it.';
        });
        return;
      }
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

      if (_selectedEvidence != null && _evidenceId == null) {
        _evidenceId = prior?.evidenceId ?? generateUuid();
      }

      _createCommandId ??= prior?.createCommandId ?? generateUuid();
      _submitCommandId ??= prior?.submitCommandId ?? generateUuid();
      _serverAssessmentId ??= prior?.serverAssessmentId;

      final resolvedPhotoPath = _evidenceRemoved
          ? null
          : (_selectedEvidence?.localPath ?? prior?.localPhotoPath);
      final resolvedEvidenceId = _evidenceRemoved
          ? null
          : (_evidenceId ?? prior?.evidenceId);

      // Persist local draft state before submitting so that any crash/drop
      // during or before submit preserves the stable command and evidence IDs.
      final localDraft = LocalAssessmentDraft(
        localDraftId: _localDraftId,
        familyId: activeChild.familyId.value,
        childId: activeChild.id.value,
        createCommandId: _createCommandId,
        submitCommandId: _submitCommandId,
        evidenceId: resolvedEvidenceId,
        serverAssessmentId: _serverAssessmentId,
        subjectKey: _selectedSubjectKey,
        subject: _subjectController.text.trim().isEmpty
            ? _selectedSubjectKey.displayLabel
            : _subjectController.text.trim(),
        title: _titleController.text.trim().isEmpty
            ? 'Draft Assessment'
            : _titleController.text.trim(),
        assessmentType: _selectedType.value,
        difficulty: _selectedDifficulty.value,
        rawScore: raw,
        maxScore: max,
        localPhotoPath: resolvedPhotoPath,
        occurredAt: _occurredAt,
        updatedAt: DateTime.now().toUtc(),
        entryContext: EntryContext.sharedChild,
        serverEvidenceId: prior?.serverEvidenceId,
        sha256Checksum: prior?.sha256Checksum,
        localCompressedPhotoPath: prior?.localCompressedPhotoPath,
        submissionStatus: DraftSubmissionStatus.submittingAssessment,
        retryCount: prior?.retryCount ?? 0,
        dispatchState: CommandDispatchState.possiblyDispatched,
        lastErrorMessage: null,
        actorUserId: prior?.actorUserId ?? ref.read(currentUserIdProvider),
        actorRole: prior?.actorRole,
      );
      await store.saveLocalDraft(localDraft);

      final submitUseCase = SubmitAssessmentDraft(
        repository: repo,
        storage: storage,
        localDraftStore: store,
        authSessionPort: ref.read(authSessionPortProvider),
      );

      final evidenceIdObj = resolvedEvidenceId != null
          ? EvidenceId(resolvedEvidenceId)
          : null;

      await submitUseCase(
        createCommandId: _createCommandId!,
        submitCommandId: _submitCommandId!,
        familyId: activeChild.familyId,
        childId: activeChild.id,
        subjectKey: _selectedSubjectKey,
        subject: _subjectController.text.trim(),
        title: _titleController.text.trim(),
        type: _selectedType,
        difficulty: _selectedDifficulty,
        score: AssessmentScore(rawScore: raw, maxScore: max),
        occurredAt: _occurredAt,
        entryContext: EntryContext.sharedChild,
        evidenceBytes: _evidenceRemoved ? null : _selectedEvidence?.bytes,
        evidenceMediaType: _evidenceRemoved
            ? null
            : _selectedEvidence?.mediaType,
        evidenceId: evidenceIdObj,
        localDraftId: _localDraftId,
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
      setState(() {
        _errorMessage = _mapFriendlyError(e);
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  String _mapFriendlyError(Object error) {
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
                                      'Path: ${_unrestoredPhotoPath ?? 'unknown'}\n'
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
                                    key: const Key('change_evidence_button'),
                                    tooltip: 'Change Photo',
                                    icon: const Icon(Icons.edit, size: 18),
                                    onPressed: _pickEvidence,
                                  ),
                                  IconButton(
                                    key: const Key('remove_evidence_button'),
                                    tooltip: 'Remove Photo',
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: _removeEvidence,
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
