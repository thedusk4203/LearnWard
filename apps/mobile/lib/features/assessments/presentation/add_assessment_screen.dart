import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/utils/uuid_generator.dart';
import '../services/local_evidence_file_store.dart';
import 'assessment_recovery_presentation.dart';
import 'evidence_picker_service.dart';

final class _ProviderClock implements Clock {
  const _ProviderClock(this._now);

  final DateTime Function() _now;

  @override
  DateTime now() => _now();
}

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

class _AddAssessmentScreenState extends ConsumerState<AddAssessmentScreen>
    with WidgetsBindingObserver {
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

  LocalAssessmentDraft? _authoritativeDraft;
  bool _staleLockedDraftRejection = false;
  int _dropdownEpoch = 0;

  ValidatedActorContext? _liveActor;
  bool _liveAuthChecked = false;
  bool _liveAuthInvalid = false;
  AdultTargetAuthorizationResult? _liveTargetAuthorization;
  bool _isRefreshingRecovery = false;
  bool _isLoadingConfirmedStatus = false;
  Assessment? _confirmedServerAssessment;
  List<AssessmentEvidence>? _confirmedServerEvidence;
  String? _confirmedServerStatusError;
  String? _confirmedResultActorUserId;
  String? _confirmedResultSessionGeneration;
  String? _activeConfirmedReadSessionGeneration;
  int _authContextSyncGeneration = 0;
  int _confirmedReadGeneration = 0;
  StreamSubscription<String?>? _authGenerationSubscription;

  static const String _payloadLockedEditRejectedMessage =
      'Original submitted or quarantined assessment payload, IDs, and evidence are locked and preserved on this device and cannot be edited.';
  static const String _staleScreenPayloadDivergedMessage =
      'This draft is already locked in local storage; the original submitted payload is preserved. Edits made on this screen cannot be submitted—reopen the draft from Drafts to review or retry the original payload.';

  LocalAssessmentDraft? get _effectiveKnownDraft =>
      _authoritativeDraft ?? widget.initialDraft;

  bool get _hasActorMismatchOnKnownDraft {
    final draft = _effectiveKnownDraft;
    if (draft == null || !_liveAuthChecked || _liveAuthInvalid) {
      return false;
    }
    final actor = _liveActor;
    if (actor == null) {
      return false;
    }
    final storedActor = draft.actorUserId;
    return storedActor != null &&
        storedActor.trim().isNotEmpty &&
        storedActor != actor.userId;
  }

  bool get _isPayloadLocked {
    if (_isQuarantined) {
      return true;
    }
    final draft = _effectiveKnownDraft;
    if (draft == null) {
      return false;
    }
    if (_hasActorMismatchOnKnownDraft) {
      return true;
    }
    if (isTargetAuthorizationDenied(_liveTargetAuthorization)) {
      return true;
    }
    return isDraftPayloadLocked(draft);
  }

  bool get _isDirectRetryAllowed {
    if (_isQuarantined) {
      return false;
    }
    final draft = _effectiveKnownDraft;
    if (draft == null) {
      return true;
    }
    if (isTargetAuthorizationDenied(_liveTargetAuthorization)) {
      return false;
    }
    return isDraftDirectRetryAllowed(
      draft,
      now: ref.read(appClockProvider)().toUtc(),
    );
  }

  bool get _isEvidenceLocked =>
      _isPayloadLocked ||
      _frozenEvidenceSha256 != null ||
      _frozenCanonicalPath != null ||
      (_effectiveKnownDraft?.hasVerifiedEvidenceSnapshot ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _evidenceRemoved = false;
    final draft = widget.initialDraft;
    _authoritativeDraft = draft;
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
        text: (draft.rawScore > 0 || isDraftPayloadLocked(draft))
            ? draft.rawScore.toString()
            : '',
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
      _syncAuthoritativeDraftFromStore(refreshAuthContext: true);
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
    _authGenerationSubscription = ref
        .read(authSessionPortProvider)
        .sessionGenerationStream
        .listen(_handleAuthSessionGenerationEvent, onError: (_) {});
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
    } catch (_) {
      if (!mounted || generation != _restorationGeneration) return;
      setState(() {
        _restorationStatus =
            ExistingEvidenceRestorationStatus.missingOrUnreadable;
        _errorMessage =
            'Failed to read existing evidence file (${sanitizeDiagnosticBasename(path)}). '
            'The draft cannot be saved or submitted without evidence. '
            'Please attach a replacement photo or explicitly remove the attachment.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _effectiveKnownDraft != null) {
      _syncAuthoritativeDraftFromStore(refreshAuthContext: true);
    }
  }

  @override
  void dispose() {
    _authGenerationSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
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

  void _handleAuthSessionGenerationEvent(String? generation) {
    if (!mounted) {
      return;
    }
    final liveChanged =
        _liveAuthChecked && generation != _liveActor?.sessionGeneration;
    final activeReadChanged =
        _isLoadingConfirmedStatus &&
        _activeConfirmedReadSessionGeneration != null &&
        generation != _activeConfirmedReadSessionGeneration;
    final confirmedCacheStale =
        _confirmedResultSessionGeneration != null &&
        generation != _confirmedResultSessionGeneration;
    final confirmedPresent =
        _confirmedServerAssessment != null || _confirmedServerEvidence != null;
    if (!liveChanged &&
        !activeReadChanged &&
        !confirmedCacheStale &&
        !confirmedPresent) {
      return;
    }
    if (activeReadChanged) {
      _confirmedReadGeneration++;
    }
    setState(() {
      if (confirmedCacheStale ||
          activeReadChanged ||
          liveChanged ||
          confirmedPresent) {
        _confirmedServerAssessment = null;
        _confirmedServerEvidence = null;
        _confirmedResultActorUserId = null;
        _confirmedResultSessionGeneration = null;
        _confirmedServerStatusError = null;
      }
      if (liveChanged) {
        _liveTargetAuthorization = null;
        _liveAuthInvalid = true;
      }
    });
  }

  void _clearConfirmedServerCache({
    bool bumpReadGeneration = false,
    bool clearError = true,
  }) {
    if (bumpReadGeneration) {
      _confirmedReadGeneration++;
    }
    _confirmedServerAssessment = null;
    _confirmedServerEvidence = null;
    _confirmedResultActorUserId = null;
    _confirmedResultSessionGeneration = null;
    if (clearError) {
      _confirmedServerStatusError = null;
    }
  }

  Future<ValidatedActorContext?> _validateMatchingLiveSession({
    required AuthSessionPort authPort,
    required DateTime nowUtc,
    ValidatedActorContext? anchoredActor,
    String? anchoredGeneration,
  }) async {
    final fresh = await authPort.validateForMutation();
    if (fresh == null || !fresh.isValidAt(nowUtc)) {
      return null;
    }
    if (anchoredActor != null && fresh.userId != anchoredActor.userId) {
      return null;
    }
    if (anchoredGeneration != null &&
        fresh.sessionGeneration != anchoredGeneration) {
      return null;
    }
    return fresh;
  }

  Future<LocalAssessmentDraft?> _syncAuthoritativeDraftFromStore({
    bool updateUiState = true,
    bool refreshAuthContext = false,
  }) async {
    final generation = refreshAuthContext ? ++_authContextSyncGeneration : null;
    final persisted = await ref
        .read(localDraftStoreProvider)
        .getLocalDraft(_localDraftId);
    final latest = persisted ?? widget.initialDraft;
    if (!mounted) {
      return latest;
    }
    if (refreshAuthContext && generation != _authContextSyncGeneration) {
      return latest;
    }

    ValidatedActorContext? verifiedActor = _liveActor;
    bool nextAuthChecked = _liveAuthChecked;
    bool nextAuthInvalid = _liveAuthInvalid;
    AdultTargetAuthorizationResult? nextTargetAuthorization =
        _liveTargetAuthorization;

    if (refreshAuthContext && latest != null) {
      final authPort = ref.read(authSessionPortProvider);
      final nowUtc = ref.read(appClockProvider)().toUtc();
      try {
        final actor = await authPort.validateForMutation();
        if (!mounted || generation != _authContextSyncGeneration) {
          return latest;
        }
        if (actor != null && actor.isValidAt(nowUtc)) {
          verifiedActor = actor;
          nextAuthChecked = true;
          nextAuthInvalid = false;
          final actorMatches =
              latest.actorUserId != null &&
              latest.actorUserId!.trim().isNotEmpty &&
              latest.actorUserId == actor.userId;
          final needsTargetCheck =
              !latest.isLegacyUnknown &&
              !latest.hasUnboundActor &&
              !latest.hasMalformedLease &&
              (latest.dispatchState ==
                      CommandDispatchState.confirmedCommitted ||
                  (actorMatches &&
                      (latest.dispatchState ==
                              CommandDispatchState.possiblyDispatched ||
                          latest.submissionStatus !=
                              DraftSubmissionStatus.draft ||
                          latest.hasRecoveryMarker)));
          if (needsTargetCheck) {
            final anchoredActor = actor;
            final anchoredGeneration = actor.sessionGeneration;
            AdultTargetAuthorizationResult candidateTargetAuth;
            try {
              candidateTargetAuth = await ref
                  .read(recoveryAuthorizationPortProvider)
                  .verifyAssessmentTarget(
                    context: actor,
                    familyId: latest.familyId,
                    childId: latest.childId,
                  );
            } catch (_) {
              candidateTargetAuth =
                  const AdultTargetAuthorizationResult.unverified(
                    reason: AdultTargetVerificationReason
                        .transientVerificationFailure,
                  );
            }
            if (!mounted || generation != _authContextSyncGeneration) {
              return latest;
            }
            final postCheckActor = await _validateMatchingLiveSession(
              authPort: authPort,
              nowUtc: ref.read(appClockProvider)().toUtc(),
              anchoredActor: anchoredActor,
              anchoredGeneration: anchoredGeneration,
            );
            if (!mounted || generation != _authContextSyncGeneration) {
              return latest;
            }
            if (postCheckActor == null) {
              final freshAfterSwitch = await authPort.validateForMutation();
              if (!mounted || generation != _authContextSyncGeneration) {
                return latest;
              }
              final freshValid =
                  freshAfterSwitch != null &&
                  freshAfterSwitch.isValidAt(
                    ref.read(appClockProvider)().toUtc(),
                  );
              verifiedActor = freshValid ? freshAfterSwitch : null;
              nextAuthChecked = true;
              nextAuthInvalid = !freshValid;
              nextTargetAuthorization = null;
            } else {
              verifiedActor = postCheckActor;
              nextTargetAuthorization = candidateTargetAuth;
            }
          } else {
            nextTargetAuthorization = null;
          }
        } else {
          verifiedActor = null;
          nextAuthChecked = true;
          nextAuthInvalid = true;
          nextTargetAuthorization = null;
        }
      } catch (_) {
        verifiedActor = null;
        nextAuthChecked = true;
        nextAuthInvalid = true;
        nextTargetAuthorization = null;
      }
    }

    if (!mounted) {
      return latest;
    }
    if (refreshAuthContext && generation != _authContextSyncGeneration) {
      return latest;
    }
    if (latest != null) {
      if (latest.hasVerifiedEvidenceSnapshot) {
        _frozenEvidenceSha256 ??= latest.sha256Checksum;
        _frozenCanonicalPath ??= latest.localCompressedPhotoPath;
      }
      final latestQuarantined =
          latest.isLegacyUnknown ||
          latest.hasUnboundActor ||
          latest.isReadOnlyQuarantined ||
          latest.hasMalformedLease;
      final sessionIdentityChanged =
          refreshAuthContext &&
          ((_liveActor != null &&
                  (_liveActor?.userId != verifiedActor?.userId ||
                      _liveActor?.sessionGeneration !=
                          verifiedActor?.sessionGeneration ||
                      nextAuthInvalid)) ||
              (_confirmedResultActorUserId != null &&
                  (_confirmedResultActorUserId != verifiedActor?.userId ||
                      _confirmedResultSessionGeneration !=
                          verifiedActor?.sessionGeneration ||
                      nextAuthInvalid ||
                      nextTargetAuthorization?.status !=
                          TargetAuthorizationStatus.authorized)));
      final confirmedShouldClear =
          refreshAuthContext &&
          (nextAuthInvalid ||
              nextTargetAuthorization?.status !=
                  TargetAuthorizationStatus.authorized ||
              (_confirmedResultActorUserId != null &&
                  _confirmedResultActorUserId != verifiedActor?.userId) ||
              (_confirmedResultSessionGeneration != null &&
                  _confirmedResultSessionGeneration !=
                      verifiedActor?.sessionGeneration));
      final authChanged =
          refreshAuthContext &&
          (_liveActor != verifiedActor ||
              _liveAuthChecked != nextAuthChecked ||
              _liveAuthInvalid != nextAuthInvalid ||
              _liveTargetAuthorization != nextTargetAuthorization ||
              (confirmedShouldClear &&
                  (_confirmedServerAssessment != null ||
                      _confirmedServerEvidence != null)));
      if (updateUiState &&
          (_authoritativeDraft != latest ||
              (latestQuarantined && !_isQuarantined) ||
              authChanged)) {
        setState(() {
          _authoritativeDraft = latest;
          if (latestQuarantined) {
            _isQuarantined = true;
          }
          if (refreshAuthContext) {
            _liveActor = verifiedActor;
            _liveAuthChecked = nextAuthChecked;
            _liveAuthInvalid = nextAuthInvalid;
            _liveTargetAuthorization = nextTargetAuthorization;
            if (confirmedShouldClear) {
              _clearConfirmedServerCache(
                bumpReadGeneration: sessionIdentityChanged,
              );
            }
          }
        });
      } else {
        _authoritativeDraft = latest;
        if (latestQuarantined) {
          _isQuarantined = true;
        }
        if (refreshAuthContext) {
          _liveActor = verifiedActor;
          _liveAuthChecked = nextAuthChecked;
          _liveAuthInvalid = nextAuthInvalid;
          _liveTargetAuthorization = nextTargetAuthorization;
          if (confirmedShouldClear) {
            _clearConfirmedServerCache(
              bumpReadGeneration: sessionIdentityChanged,
            );
          }
        }
      }
    }
    return latest;
  }

  Future<void> _refreshRecoveryStatus() async {
    if (_isRefreshingRecovery) {
      return;
    }
    setState(() {
      _isRefreshingRecovery = true;
    });
    try {
      await _syncAuthoritativeDraftFromStore(refreshAuthContext: true);
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshingRecovery = false;
        });
      }
    }
  }

  Future<void> _reviewConfirmedServerResult() async {
    if (_isLoadingConfirmedStatus) {
      return;
    }
    final readGeneration = ++_confirmedReadGeneration;
    setState(() {
      _isLoadingConfirmedStatus = true;
      _confirmedServerStatusError = null;
    });

    try {
      final store = ref.read(localDraftStoreProvider);
      final persisted = await store.getLocalDraft(_localDraftId);
      final latest = persisted ?? widget.initialDraft;
      if (!mounted || readGeneration != _confirmedReadGeneration) {
        return;
      }
      final serverAssessmentId = latest?.serverAssessmentId;
      if (latest == null ||
          latest.localDraftId != _localDraftId ||
          latest.dispatchState != CommandDispatchState.confirmedCommitted ||
          serverAssessmentId == null ||
          serverAssessmentId.trim().isEmpty) {
        setState(() {
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError =
              'Confirmed server assessment identifier is unavailable locally.';
        });
        return;
      }

      final authPort = ref.read(authSessionPortProvider);
      final authzPort = ref.read(recoveryAuthorizationPortProvider);
      final anchoredActor = await _validateMatchingLiveSession(
        authPort: authPort,
        nowUtc: ref.read(appClockProvider)().toUtc(),
      );
      if (!mounted || readGeneration != _confirmedReadGeneration) {
        return;
      }
      if (anchoredActor == null) {
        setState(() {
          _liveActor = null;
          _liveAuthChecked = true;
          _liveAuthInvalid = true;
          _liveTargetAuthorization = null;
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError = 'Your session is no longer valid. Sign in again to inspect confirmed server status.';
        });
        return;
      }
      final anchoredGeneration = anchoredActor.sessionGeneration;
      _activeConfirmedReadSessionGeneration = anchoredGeneration;

      AdultTargetAuthorizationResult targetAuth;
      try {
        targetAuth = await authzPort.verifyAssessmentTarget(
          context: anchoredActor,
          familyId: latest.familyId,
          childId: latest.childId,
        );
      } catch (_) {
        targetAuth = const AdultTargetAuthorizationResult.unverified(
          reason: AdultTargetVerificationReason.transientVerificationFailure,
        );
      }
      if (!mounted || readGeneration != _confirmedReadGeneration) {
        return;
      }

      final postAuthzActor = await _validateMatchingLiveSession(
        authPort: authPort,
        nowUtc: ref.read(appClockProvider)().toUtc(),
        anchoredActor: anchoredActor,
        anchoredGeneration: anchoredGeneration,
      );
      if (!mounted || readGeneration != _confirmedReadGeneration) {
        return;
      }
      if (postAuthzActor == null) {
        setState(() {
          _liveTargetAuthorization = null;
          _liveAuthInvalid = true;
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError = 'Your active session changed while verifying permissions. Refresh and try again.';
        });
        return;
      }

      if (targetAuth.status != TargetAuthorizationStatus.authorized) {
        setState(() {
          _liveActor = postAuthzActor;
          _liveAuthChecked = true;
          _liveAuthInvalid = false;
          _liveTargetAuthorization = targetAuth;
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError = isTargetAuthorizationDenied(targetAuth)
              ? 'Target family or child authorization does not permit reading this server assessment.'
              : 'Could not verify confirmed status permissions offline. Try again when connected.';
        });
        return;
      }

      final repo = ref.read(assessmentRepositoryProvider);
      final assessmentId = AssessmentId(serverAssessmentId);
      final serverAssessment = await repo.getAssessment(assessmentId);
      if (!mounted || readGeneration != _confirmedReadGeneration) {
        return;
      }

      final postAssessmentActor = await _validateMatchingLiveSession(
        authPort: authPort,
        nowUtc: ref.read(appClockProvider)().toUtc(),
        anchoredActor: anchoredActor,
        anchoredGeneration: anchoredGeneration,
      );
      if (!mounted || readGeneration != _confirmedReadGeneration) {
        return;
      }
      if (postAssessmentActor == null) {
        setState(() {
          _liveTargetAuthorization = null;
          _liveAuthInvalid = true;
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError = 'Your active session changed before reading server evidence. Refresh and try again.';
        });
        return;
      }

      if (serverAssessment == null) {
        setState(() {
          _liveActor = postAssessmentActor;
          _liveAuthChecked = true;
          _liveAuthInvalid = false;
          _liveTargetAuthorization = targetAuth;
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError = 'Server record was not found or is not currently accessible for your account.';
        });
        return;
      }
      if (serverAssessment.id.value != serverAssessmentId ||
          serverAssessment.familyId.value != latest.familyId ||
          serverAssessment.childId.value != latest.childId) {
        setState(() {
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError =
              'Server record scope did not match this draft family or child.';
        });
        return;
      }

      final serverEvidence = await repo.listEvidenceForAssessment(assessmentId);
      if (!mounted || readGeneration != _confirmedReadGeneration) {
        return;
      }

      final prePublishActor = await _validateMatchingLiveSession(
        authPort: authPort,
        nowUtc: ref.read(appClockProvider)().toUtc(),
        anchoredActor: anchoredActor,
        anchoredGeneration: anchoredGeneration,
      );
      if (!mounted || readGeneration != _confirmedReadGeneration) {
        return;
      }
      if (prePublishActor == null) {
        setState(() {
          _liveTargetAuthorization = null;
          _liveAuthInvalid = true;
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError = 'Your active session changed before confirmed results could be displayed. Refresh and try again.';
        });
        return;
      }
      if (serverEvidence.any(
        (evidence) => evidence.assessmentId.value != serverAssessmentId,
      )) {
        setState(() {
          _clearConfirmedServerCache(clearError: false);
          _confirmedServerStatusError =
              'Server evidence scope did not match the confirmed assessment.';
        });
        return;
      }

      setState(() {
        _authoritativeDraft = latest;
        _liveActor = prePublishActor;
        _liveAuthChecked = true;
        _liveAuthInvalid = false;
        _liveTargetAuthorization = targetAuth;
        _confirmedResultActorUserId = prePublishActor.userId;
        _confirmedResultSessionGeneration = prePublishActor.sessionGeneration;
        _confirmedServerAssessment = serverAssessment;
        _confirmedServerEvidence = serverEvidence;
        _confirmedServerStatusError = null;
      });
    } catch (e) {
      if (mounted && readGeneration == _confirmedReadGeneration) {
        setState(() {
          _confirmedServerStatusError = _mapFriendlyError(e);
        });
      }
    } finally {
      if (mounted && readGeneration == _confirmedReadGeneration) {
        _activeConfirmedReadSessionGeneration = null;
        setState(() {
          _isLoadingConfirmedStatus = false;
        });
      }
    }
  }

  String? _findFormPayloadDivergence(LocalAssessmentDraft prior) {
    if (_selectedSubjectKey != prior.subjectKey) {
      return 'subjectKey';
    }
    final normalizedFormSubject = normalizeAssessmentSubject(
      _subjectController.text,
      fallbackSubjectKey: _selectedSubjectKey,
    );
    final normalizedPriorSubject = normalizeAssessmentSubject(
      prior.subject,
      fallbackSubjectKey: prior.subjectKey,
    );
    if (normalizedFormSubject != normalizedPriorSubject ||
        _subjectController.text.trim() != prior.subject.trim()) {
      return 'subject';
    }
    final normalizedFormTitle = normalizeAssessmentTitle(
      _titleController.text,
      fallbackTitle: 'Draft Assessment',
    );
    final normalizedPriorTitle = normalizeAssessmentTitle(
      prior.title,
      fallbackTitle: 'Draft Assessment',
    );
    if (normalizedFormTitle != normalizedPriorTitle ||
        _titleController.text.trim() != prior.title.trim()) {
      return 'title';
    }
    if (_selectedType.value != prior.assessmentType) {
      return 'assessmentType';
    }
    if (_selectedDifficulty.value != prior.difficulty) {
      return 'difficulty';
    }
    final parsedRaw = double.tryParse(_rawScoreController.text.trim());
    final parsedMax = double.tryParse(_maxScoreController.text.trim());
    if (parsedRaw == null || parsedRaw != prior.rawScore) {
      return 'rawScore';
    }
    if (parsedMax == null || parsedMax != prior.maxScore) {
      return 'maxScore';
    }
    if (normalizeAssessmentOccurredAt(_occurredAt) !=
        normalizeAssessmentOccurredAt(prior.occurredAt)) {
      return 'occurredAt';
    }
    if (widget.initialDraft != null &&
        prior.entryContext != widget.initialDraft!.entryContext) {
      return 'entryContext';
    }
    if (prior.createCommandId != null &&
        _createCommandId != null &&
        _createCommandId != prior.createCommandId) {
      return 'createCommandId';
    }
    if (prior.submitCommandId != null &&
        _submitCommandId != null &&
        _submitCommandId != prior.submitCommandId) {
      return 'submitCommandId';
    }
    final priorHasEvidence =
        prior.hasVerifiedEvidenceSnapshot ||
        (prior.evidenceId?.isNotEmpty ?? false) ||
        (prior.localPhotoPath?.isNotEmpty ?? false);
    if (_evidenceRemoved && priorHasEvidence) {
      return 'evidence';
    }
    if (!priorHasEvidence &&
        (_selectedEvidence != null || _evidenceId != null)) {
      return 'evidence';
    }
    if (prior.hasVerifiedEvidenceSnapshot &&
        _restorationStatus != ExistingEvidenceRestorationStatus.loading) {
      final displayed = _selectedEvidence;
      if (displayed == null &&
          _restorationStatus !=
              ExistingEvidenceRestorationStatus.missingOrUnreadable) {
        return 'evidence';
      }
      if (displayed != null &&
          computeSha256Hex(displayed.bytes) != prior.sha256Checksum) {
        return 'evidence';
      }
    }
    if (prior.evidenceId != null &&
        _evidenceId != null &&
        _evidenceId != prior.evidenceId) {
      return 'evidence';
    }
    return null;
  }

  Future<void> _handlePayloadTextEdited() async {
    final latest = await _syncAuthoritativeDraftFromStore(updateUiState: false);
    if (!mounted || latest == null) {
      return;
    }
    if (isDraftPayloadLocked(latest)) {
      final diverged = _findFormPayloadDivergence(latest) != null;
      setState(() {
        _authoritativeDraft = latest;
        if (latest.isLegacyUnknown ||
            latest.hasUnboundActor ||
            latest.isReadOnlyQuarantined ||
            latest.hasMalformedLease) {
          _isQuarantined = true;
        }
        if (diverged) {
          _staleLockedDraftRejection = true;
        }
        _errorMessage = diverged
            ? _staleScreenPayloadDivergedMessage
            : _payloadLockedEditRejectedMessage;
      });
    }
  }

  Future<bool> _rejectLockedDropdownAttempt({
    required LocalAssessmentDraft? latest,
    required bool changed,
  }) async {
    if (!mounted) {
      return true;
    }
    if (latest != null && isDraftPayloadLocked(latest)) {
      setState(() {
        _authoritativeDraft = latest;
        if (latest.isLegacyUnknown ||
            latest.hasUnboundActor ||
            latest.isReadOnlyQuarantined ||
            latest.hasMalformedLease) {
          _isQuarantined = true;
        }
        if (changed) {
          _staleLockedDraftRejection = true;
        }
        _dropdownEpoch++;
        _errorMessage = _staleScreenPayloadDivergedMessage;
      });
      return true;
    }
    return false;
  }

  Future<void> _onSubjectKeyChanged(SubjectKey? val) async {
    if (val == null) return;
    if (_isPayloadLocked) {
      setState(() {
        _dropdownEpoch++;
        _errorMessage = _payloadLockedEditRejectedMessage;
      });
      return;
    }
    final latest = await _syncAuthoritativeDraftFromStore(updateUiState: false);
    if (await _rejectLockedDropdownAttempt(
      latest: latest,
      changed: latest != null && val != latest.subjectKey,
    )) {
      return;
    }
    setState(() {
      _selectedSubjectKey = val;
      if (_subjectController.text.isEmpty ||
          SubjectKey.values.any(
            (s) => s.displayLabel == _subjectController.text,
          )) {
        _subjectController.text = val.displayLabel;
      }
    });
  }

  Future<void> _onAssessmentTypeChanged(AssessmentType? val) async {
    if (val == null) return;
    if (_isPayloadLocked) {
      setState(() {
        _dropdownEpoch++;
        _errorMessage = _payloadLockedEditRejectedMessage;
      });
      return;
    }
    final latest = await _syncAuthoritativeDraftFromStore(updateUiState: false);
    if (await _rejectLockedDropdownAttempt(
      latest: latest,
      changed: latest != null && val.value != latest.assessmentType,
    )) {
      return;
    }
    setState(() => _selectedType = val);
  }

  Future<void> _onDifficultyChanged(AssessmentDifficulty? val) async {
    if (val == null) return;
    if (_isPayloadLocked) {
      setState(() {
        _dropdownEpoch++;
        _errorMessage = _payloadLockedEditRejectedMessage;
      });
      return;
    }
    final latest = await _syncAuthoritativeDraftFromStore(updateUiState: false);
    if (await _rejectLockedDropdownAttempt(
      latest: latest,
      changed: latest != null && val.value != latest.difficulty,
    )) {
      return;
    }
    setState(() => _selectedDifficulty = val);
  }

  Future<void> _pickEvidence() async {
    final prePickDraft = await _syncAuthoritativeDraftFromStore();
    if (!mounted) return;
    if (_isQuarantined ||
        (prePickDraft != null && isDraftPayloadLocked(prePickDraft))) {
      setState(() {
        _errorMessage = _payloadLockedEditRejectedMessage;
      });
      return;
    }

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

    // R33-08 & R33-09: Reject replacement once payload is locked or canonical snapshot has been frozen.
    // Preserve both the original canonical file and newly selected file on disk without deletion.
    final latestDraft = await _syncAuthoritativeDraftFromStore();
    if (!mounted) return;
    if (_isQuarantined ||
        (latestDraft != null && isDraftPayloadLocked(latestDraft))) {
      setState(() {
        _errorMessage = _staleScreenPayloadDivergedMessage;
      });
      return;
    }
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
    // R33-08 & R33-09: Once payload is locked or a canonical snapshot is frozen, removal
    // must fail closed without clearing displayed evidence, rotating IDs, or deleting files.
    final latestDraft = await _syncAuthoritativeDraftFromStore();
    if (!mounted) return;
    if (_isQuarantined ||
        (latestDraft != null && isDraftPayloadLocked(latestDraft))) {
      setState(() {
        _errorMessage = _payloadLockedEditRejectedMessage;
      });
      return;
    }
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
    final authPort = ref.read(authSessionPortProvider);
    final authzPort = ref.read(recoveryAuthorizationPortProvider);
    final existingFromStore = await store.getLocalDraft(_localDraftId);
    final prior = existingFromStore ?? widget.initialDraft;

    if (prior != null && isDraftPayloadLocked(prior)) {
      if (mounted) {
        setState(() {
          _authoritativeDraft = prior;
          if (prior.isLegacyUnknown ||
              prior.hasUnboundActor ||
              prior.isReadOnlyQuarantined ||
              prior.hasMalformedLease) {
            _isQuarantined = true;
          }
          _errorMessage = _payloadLockedEditRejectedMessage;
        });
      }
      return;
    }

    final isLegacy =
        (prior?.isLegacyUnknown ?? false) ||
        _isQuarantined ||
        (widget.initialDraft?.isLegacyUnknown ?? false);

    if (isLegacy) {
      if (mounted) {
        setState(() {
          _isQuarantined = true;
          _errorMessage = _payloadLockedEditRejectedMessage;
        });
      }
      return;
    }

    late final ValidatedActorContext validatedActor;
    try {
      validatedActor = await assertValidStorageAuthSession(
        authSessionPort: authPort,
        storagePath: 'assessment-draft/$_localDraftId',
        stage: 'assessment local save',
      );
      if (!validatedActor.isValidAt(DateTime.now().toUtc())) {
        throw EvidenceStorageAuthException(
          const AuthFailureOutcome(
            storagePath: '',
            reason: 'Session expired before saving draft.',
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = _mapFriendlyError(e);
        });
      }
      return;
    }
    if (!mounted) return;

    if (prior != null) {
      if (prior.actorUserId == null || prior.actorUserId!.trim().isEmpty) {
        setState(() {
          _authoritativeDraft = prior;
          _isQuarantined = true;
          _errorMessage = _payloadLockedEditRejectedMessage;
        });
        return;
      }
      if (prior.actorUserId != validatedActor.userId) {
        setState(() {
          _errorMessage = 'Your session is no longer valid. Only the original draft author can modify this draft.';
        });
        return;
      }
      if (prior.familyId != activeChild.familyId.value ||
          prior.childId != activeChild.id.value) {
        setState(() {
          _errorMessage =
              'Active child selection does not match the original draft scope.';
        });
        return;
      }
    }

    final authzResult = await authzPort.verifyAssessmentTarget(
      context: validatedActor,
      familyId: activeChild.familyId.value,
      childId: activeChild.id.value,
    );
    if (!mounted) return;
    final isAllowedTargetForLocalSave =
        authzResult.status == TargetAuthorizationStatus.authorized ||
        (authzResult.status == TargetAuthorizationStatus.unverified &&
            authzResult.reason ==
                AdultTargetVerificationReason.transientVerificationFailure);
    if (!isAllowedTargetForLocalSave) {
      setState(() {
        if (isTargetAuthorizationDenied(authzResult)) {
          _liveTargetAuthorization = authzResult;
        }
        _errorMessage = 'You do not have permission to save drafts for this family or child.';
      });
      return;
    }

    // Fresh v5 drafts generate and preserve stable command IDs for genuinely new operations.
    _createCommandId ??= prior?.createCommandId ?? generateUuid();
    _submitCommandId ??= prior?.submitCommandId ?? generateUuid();
    final resolvedCreateCommandId = _createCommandId;
    final resolvedSubmitCommandId = _submitCommandId;
    final resolvedActorUserId = prior?.actorUserId ?? validatedActor.userId;
    final resolvedActorRole = prior?.actorRole ?? validatedActor.role;
    final resolvedDispatchState = _resolveSafeDispatchState(prior);

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
      if (!mounted) return;
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
    final nowUtc = DateTime.now().toUtc();

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
      updatedAt: nowUtc,
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
      await assertValidStorageAuthSession(
        authSessionPort: authPort,
        storagePath: 'assessment-draft/$_localDraftId',
        context: validatedActor,
        expectedSessionGeneration: validatedActor.sessionGeneration,
        stage: 'assessment local save commit',
      );
      final saveCas = await store.registerOrUpdateDraftIfUnchanged(
        expected: existingFromStore,
        desired: draft,
        now: nowUtc,
      );
      if (!saveCas.isSuccess) {
        if (saveCas.draft != null && mounted) {
          setState(() {
            _authoritativeDraft = saveCas.draft;
          });
        }
        throw DraftSubmissionCasException(
          stage: DraftCasFailureStage.registerPreDispatchDraft,
          localDraftId: _localDraftId,
          casStatus: saveCas.status,
          serverAssessmentId: resolvedServerAssessmentId,
          message:
              'Could not save draft changes because local storage state changed (${saveCas.status.name}).',
        );
      }
      _authoritativeDraft = saveCas.draft ?? draft;

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
          if (e is EvidenceStorageException ||
              e is DraftSubmissionCasException ||
              e is CanonicalEvidenceValidationException) {
            _errorMessage = _mapFriendlyError(e);
          } else if (e is DraftWriteConflictException) {
            _errorMessage = 'Cannot save changes: this draft is locked or requires recovery reconciliation.';
          } else {
            _errorMessage = 'Could not save draft locally. Please check storage space and try again.';
          }
        });
      }
    }
  }

  Future<void> _submitAssessment() =>
      _executeSubmissionOrRecovery(allowWaitingOriginalActorResume: false);

  Future<void> _resumeOriginalActorAndSubmit() =>
      _executeSubmissionOrRecovery(allowWaitingOriginalActorResume: true);

  Future<void> _executeSubmissionOrRecovery({
    required bool allowWaitingOriginalActorResume,
  }) async {
    if (_isSubmitting) {
      return;
    }
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final nowClock = ref.read(appClockProvider);
      final nowUtc = nowClock().toUtc();
      final store = ref.read(localDraftStoreProvider);
      final existingFromStore = await store.getLocalDraft(_localDraftId);
      if (widget.initialDraft != null && existingFromStore == null) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Local draft record is missing from storage. Reopen drafts before submitting.';
          });
        }
        return;
      }
      final prior = existingFromStore ?? widget.initialDraft;
      if (prior != null && mounted) {
        setState(() {
          _authoritativeDraft = prior;
          if (prior.hasVerifiedEvidenceSnapshot) {
            _frozenEvidenceSha256 ??= prior.sha256Checksum;
            _frozenCanonicalPath ??= prior.localCompressedPhotoPath;
          }
        });
      }

      final isQuarantined =
          (prior?.isLegacyUnknown ?? false) ||
          (prior?.hasUnboundActor ?? false) ||
          (prior?.isReadOnlyQuarantined ?? false) ||
          (prior?.hasMalformedLease ?? false) ||
          _isQuarantined;
      if (isQuarantined) {
        if (mounted) {
          setState(() {
            _authoritativeDraft = prior;
            _isQuarantined = true;
            _errorMessage = 'Cannot submit a quarantined draft. Recovery reconciliation is required.';
          });
        }
        return;
      }
      final waitingActorResumeAllowed =
          allowWaitingOriginalActorResume &&
          prior != null &&
          prior.hasWaitingOriginalActorMarker &&
          !prior.hasActiveLease(now: nowUtc) &&
          !prior.hasMalformedLease &&
          !prior.isReadOnlyQuarantined &&
          !prior.isLegacyUnknown &&
          !prior.hasUnboundActor &&
          prior.dispatchState != CommandDispatchState.confirmedCommitted;
      if (prior != null &&
          isTargetAuthorizationDenied(_liveTargetAuthorization)) {
        if (mounted) {
          setState(() {
            _authoritativeDraft = prior;
            _errorMessage = 'Target permissions for this family or child do not allow submitting this draft.';
          });
        }
        return;
      }
      if (prior != null &&
          !waitingActorResumeAllowed &&
          !isDraftDirectRetryAllowed(prior, now: nowUtc)) {
        if (mounted) {
          setState(() {
            _authoritativeDraft = prior;
            _errorMessage = 'Cannot submit this draft directly while recovery reconciliation or active lease processing is pending.';
          });
        }
        return;
      }
      if (prior != null && isDraftPayloadLocked(prior)) {
        if (_staleLockedDraftRejection ||
            _findFormPayloadDivergence(prior) != null) {
          if (mounted) {
            setState(() {
              _authoritativeDraft = prior;
              _staleLockedDraftRejection = true;
              _errorMessage = _staleScreenPayloadDivergedMessage;
            });
          }
          return;
        }
      }

      final isDispatchedRetry =
          prior != null &&
          prior.dispatchState == CommandDispatchState.possiblyDispatched;
      final isExistingRecoveryRetry =
          prior != null &&
          (isDispatchedRetry ||
              prior.submissionStatus != DraftSubmissionStatus.draft ||
              prior.hasRecoveryMarker);

      // R26-6-01: Evidence restoration in progress or missing/unreadable must fail closed.
      if (_restorationStatus == ExistingEvidenceRestorationStatus.loading) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Evidence restoration is in progress. Please wait a moment before submitting.';
          });
        }
        return;
      }
      if (_restorationStatus ==
              ExistingEvidenceRestorationStatus.missingOrUnreadable &&
          !(isExistingRecoveryRetry && prior.hasVerifiedEvidenceSnapshot)) {
        if (mounted) {
          setState(() {
            _errorMessage = _isEvidenceLocked
                ? 'Cannot submit assessment: the locked evidence photo snapshot is missing or corrupted on disk and cannot be replaced.'
                : 'Cannot submit assessment: existing evidence is missing or unreadable. '
                      'Please attach a replacement photo or explicitly remove the attachment.';
          });
        }
        return;
      }

      // R33-08: Fail closed in UI boundary if frozen snapshot was marked removed or diverged.
      if ((prior?.hasVerifiedEvidenceSnapshot ?? false) ||
          _frozenEvidenceSha256 != null) {
        if (_evidenceRemoved) {
          if (mounted) {
            setState(() {
              _errorMessage = _frozenEvidenceLockedRemoveMessage;
            });
          }
          return;
        }
        final expectedSha = _frozenEvidenceSha256 ?? prior?.sha256Checksum;
        final displayed = _selectedEvidence;
        if (displayed != null &&
            expectedSha != null &&
            computeSha256Hex(displayed.bytes) != expectedSha) {
          if (mounted) {
            setState(() {
              _errorMessage = _frozenEvidenceLockedReplaceMessage;
            });
          }
          return;
        }
      }

      // R26-5-01: Do not begin a remote submission involving a newly selected attachment whose durable persistence failed.
      if (_evidenceSaveFailed) {
        if (mounted) {
          setState(() {
            _errorMessage = 'Cannot submit assessment: the selected photo could not be saved locally. Please re-select a photo or remove it.';
          });
        }
        return;
      }

      if (!_formKey.currentState!.validate()) {
        return;
      }

      final activeChild = ref.read(activeChildModeProvider);
      if (activeChild == null) {
        if (mounted) {
          setState(() => _errorMessage = 'No active child session');
        }
        return;
      }

      final raw = double.parse(_rawScoreController.text.trim());
      final max = double.parse(_maxScoreController.text.trim());

      final repo = ref.read(assessmentRepositoryProvider);
      final storage = ref.read(assessmentEvidenceStorageProvider);
      final fileStore = ref.read(localEvidenceFileStoreProvider);
      final authPort = ref.read(authSessionPortProvider);
      final authzPort = ref.read(recoveryAuthorizationPortProvider);
      final config = ref.read(appConfigProvider);

      // R31-08: Authoritative live session validation before staging/dispatch.
      final validatedActor = await assertValidStorageAuthSession(
        authSessionPort: authPort,
        storagePath: '',
        stage: 'assessment UI preflight',
      );
      if (!validatedActor.isValidAt(nowClock().toUtc())) {
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

      if (prior != null && isDraftPayloadLocked(prior)) {
        final divergedField = _findFormPayloadDivergence(prior);
        if (_staleLockedDraftRejection || divergedField != null) {
          throw DraftSubmissionCasException(
            stage: DraftCasFailureStage.registerPreDispatchDraft,
            localDraftId: _localDraftId,
            casStatus: DraftCasStatus.casConflict,
            serverAssessmentId: prior.serverAssessmentId,
            message:
                'Displayed form payload diverges from locked local draft ($divergedField).',
          );
        }
      }

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

      if (isExistingRecoveryRetry) {
        if (prior.hasVerifiedEvidenceSnapshot) {
          VerifiedCanonicalEvidence? verified;
          try {
            verified = await fileStore.readVerifiedCanonicalSnapshot(
              draft: prior,
            );
          } on MissingCanonicalEvidenceSnapshotException {
            verified = null;
          } on CanonicalEvidenceValidationException {
            verified = null;
          } on EvidenceStorageException {
            verified = null;
          }
          if (verified != null) {
            assertDisplayedSelectionMatchesFrozen(verified, prior.evidenceId);
            dispatchEvidenceBytes = verified.bytes;
            dispatchEvidenceMediaType = verified.mediaType;
            dispatchEvidenceIdStr = prior.evidenceId;
          } else {
            // Defer missing/corrupted canonical snapshot handling to WP3 under lease
            // so durable quarantine state is recorded safely.
            dispatchEvidenceBytes = null;
            dispatchEvidenceMediaType = null;
            dispatchEvidenceIdStr = prior.evidenceId;
          }
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
        recoveryAuthorizationPort: authzPort,
        clock: _ProviderClock(nowClock),
        jitterSource: config.canUseLocalDemoRepositories
            ? const DeterministicJitterSource(0.0)
            : const RandomJitterSource(),
      );

      final trigger = isExistingRecoveryRetry
          ? CommandExecutionTrigger.foregroundRetry
          : CommandExecutionTrigger.foreground;

      final evidenceIdObj = dispatchEvidenceIdStr != null
          ? EvidenceId(dispatchEvidenceIdStr)
          : null;

      final outcome = await submitUseCase.execute(
        createCommandId: isExistingRecoveryRetry
            ? (prior.createCommandId ?? _createCommandId!)
            : _createCommandId!,
        submitCommandId: isExistingRecoveryRetry
            ? (prior.submitCommandId ?? _submitCommandId!)
            : _submitCommandId!,
        familyId: activeChild.familyId,
        childId: activeChild.id,
        subjectKey: _selectedSubjectKey,
        subject: normalizedSubject,
        title: normalizedTitle,
        type: _selectedType,
        difficulty: _selectedDifficulty,
        score: AssessmentScore(rawScore: raw, maxScore: max),
        occurredAt: normalizedOccurredAt,
        entryContext: resolvedEntryContext,
        evidenceBytes: dispatchEvidenceBytes,
        evidenceMediaType: dispatchEvidenceMediaType,
        evidenceId: evidenceIdObj,
        localDraftId: _localDraftId,
        context: validatedActor,
        expectedSessionGeneration: validatedActor.sessionGeneration,
        trigger: trigger,
      );

      // B03: Do NOT delete physical evidence solely because submission returned.
      // Local evidence bytes are preserved on disk for durability and future reconciliation.

      if (!mounted) return;
      _applySubmissionOutcome(outcome);
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = _mapFriendlyError(e);
        });
      }
    } finally {
      await _syncAuthoritativeDraftFromStore(
        updateUiState: false,
        refreshAuthContext: true,
      );
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _applySubmissionOutcome(AssessmentSubmissionOutcome outcome) {
    switch (outcome) {
      case AssessmentSubmissionConfirmed():
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Assessment submitted for review!'),
            backgroundColor: Colors.green,
          ),
        );
        context.pop(true);
      case AssessmentSubmissionPausedActorMismatch(:final draft):
        setState(() {
          _authoritativeDraft = draft ?? _authoritativeDraft;
          _errorMessage = 'Your session is no longer valid. Original draft author session is required to continue.';
        });
      case AssessmentSubmissionPausedSessionInvalid(:final draft):
        setState(() {
          _authoritativeDraft = draft ?? _authoritativeDraft;
          _errorMessage = 'Your session is no longer valid. Please sign in again to continue.';
        });
      case AssessmentSubmissionRetryScheduled(:final draft, :final cause):
        setState(() {
          _authoritativeDraft = draft ?? _authoritativeDraft;
          _errorMessage = cause != null ? _mapFriendlyError(cause) : 'Could not connect to the server. Your work is saved on this device. Please try again when online.';
        });
      case AssessmentSubmissionQuarantined(
        :final draft,
        :final recoveryCode,
        :final cause,
      ):
        setState(() {
          _authoritativeDraft = draft ?? _authoritativeDraft;
          _isQuarantined =
              (draft?.isReadOnlyQuarantined ?? false) || _isQuarantined;
          final useSpecificRecoveryCopy =
              DraftRecoveryCode.quarantineCodes.contains(recoveryCode) &&
              recoveryCode != DraftRecoveryCode.quarantinedUnknownOutcome;
          _errorMessage = useSpecificRecoveryCopy || cause == null
              ? _mapRecoveryCodeFriendlyError(recoveryCode)
              : _mapFriendlyError(cause);
        });
      case AssessmentSubmissionPolicyDenied(:final draft):
        setState(() {
          _authoritativeDraft = draft ?? _authoritativeDraft;
          _isQuarantined =
              (draft?.isReadOnlyQuarantined ?? false) || _isQuarantined;
          _errorMessage = 'You do not have permission to submit assessments for this family.';
        });
      case AssessmentSubmissionLeaseConflict(:final draft, :final cause):
        setState(() {
          _authoritativeDraft = draft ?? _authoritativeDraft;
          _errorMessage = cause != null ? _mapFriendlyError(cause) : 'Could not safely update your local draft state before syncing. Your draft and photo remain preserved on this device.';
        });
    }
  }

  String _mapRecoveryCodeFriendlyError(String recoveryCode) {
    switch (recoveryCode) {
      case DraftRecoveryCode.storageContentConflict:
      case DraftRecoveryCode.evidenceIdMismatch:
        return 'Attached photo could not be reconciled safely with remote storage. Your draft is saved on this device.';
      case DraftRecoveryCode.registrationUnresolvedRemoteRetained:
      case DraftRecoveryCode.ambiguousSubmitOutcome:
      case DraftRecoveryCode.ambiguous42501Outcome:
      case DraftRecoveryCode.unreconstructableExpectedVersion:
        return 'Submission status requires manual verification. Your draft and photo remain safely preserved on this device.';
      case DraftRecoveryCode.versionConflict:
        return 'This assessment was updated elsewhere. Please refresh.';
      default:
        return 'Cannot submit a quarantined draft. Recovery reconciliation is required.';
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
    if (error is EvidenceStorageConflictException ||
        error is EvidenceIdMismatchException) {
      return 'Attached photo could not be reconciled safely with remote storage. Your draft is saved on this device.';
    }
    if (error is EvidenceStorageUnknownOutcomeException ||
        error is EvidenceRegistrationUnresolvedRemoteRetainedException) {
      return 'Could not verify photo upload status. Your draft is saved on this device. Please try again.';
    }
    if (error is AssessmentPolicyDeniedException) {
      return 'You do not have permission to submit assessments for this family.';
    }
    if (error is AssessmentQuarantinedException) {
      return _mapRecoveryCodeFriendlyError(error.recoveryCode);
    }
    if (error is AssessmentRetryScheduledException) {
      return error.cause != null
          ? _mapFriendlyError(error.cause!)
          : 'Could not connect to the server. Your work is saved on this device. Please try again when online.';
    }
    if (error is BackendRpcException) {
      final code = error.code?.toUpperCase();
      if (code == '42501') {
        return 'You do not have permission to submit assessments for this family.';
      }
      if (code == 'LW101') {
        return 'This assessment was updated elsewhere. Please refresh.';
      }
      if (code == 'LW107') {
        return 'Submission status requires manual verification. Your draft and photo remain safely preserved on this device.';
      }
      return 'Failed to submit assessment. Please check your connection and try again.';
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

  String _buildPayloadLockedExplanation(LocalAssessmentDraft? draft) {
    if (_isQuarantined ||
        (draft?.isLegacyUnknown ?? false) ||
        (draft?.hasUnboundActor ?? false) ||
        (draft?.isReadOnlyQuarantined ?? false) ||
        (draft?.hasMalformedLease ?? false)) {
      return 'This draft is quarantined for data safety. Its original submitted payload, IDs, and evidence are locked read-only and preserved on this device.';
    }
    if (draft?.dispatchState == CommandDispatchState.confirmedCommitted) {
      return 'This assessment has already been committed. Its original submitted payload, IDs, and evidence are locked and preserved on this device.';
    }
    if (_hasActorMismatchOnKnownDraft ||
        (draft?.hasWaitingOriginalActorMarker ?? false)) {
      return 'This draft belongs to the original author account. Its original submitted payload, IDs, and evidence are locked and cannot be altered or reassigned.';
    }
    if (isTargetAuthorizationDenied(_liveTargetAuthorization)) {
      return 'Permissions for this child or family do not permit edits or submission. Its original submitted payload, IDs, and evidence are locked read-only on this device.';
    }
    if (draft != null &&
        !isDraftDirectRetryAllowed(
          draft,
          now: ref.read(appClockProvider)().toUtc(),
        )) {
      return 'Editing is locked for this draft while recovery reconciliation or active sync processing is pending. Its original submitted payload, IDs, and evidence remain preserved on this device.';
    }
    return 'This draft has already entered submission. Editing is locked so its original submitted payload, command IDs, score, and evidence remain preserved while retrying.';
  }

  Widget _buildRecoveryStatusCard(
    ThemeData theme,
    AssessmentRecoveryPresentation presentation,
  ) {
    final (
      containerColor,
      foregroundColor,
      icon,
    ) = switch (presentation.severity) {
      RecoveryBannerSeverity.success => (
        Colors.green.shade50,
        Colors.green.shade900,
        Icons.verified_outlined,
      ),
      RecoveryBannerSeverity.error => (
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
        Icons.error_outline,
      ),
      RecoveryBannerSeverity.warning => (
        theme.colorScheme.tertiaryContainer,
        theme.colorScheme.onTertiaryContainer,
        Icons.warning_amber_rounded,
      ),
      RecoveryBannerSeverity.info => (
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
        Icons.sync,
      ),
      RecoveryBannerSeverity.neutral => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurface,
        Icons.edit_note,
      ),
    };

    return Card(
      key: const Key('recovery_status_card'),
      color: containerColor,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: foregroundColor),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    presentation.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: foregroundColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  key: const Key('recovery_disposition_badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: foregroundColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    presentation.badgeLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foregroundColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              presentation.explanation,
              style: theme.textTheme.bodySmall?.copyWith(
                color: foregroundColor,
              ),
            ),
            if (presentation.safeRecoveryCode != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Recovery code: ${presentation.safeRecoveryCode}',
                key: const Key('recovery_code_label'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (presentation.scheduleDetail != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                presentation.scheduleDetail!,
                key: const Key('recovery_schedule_detail'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: foregroundColor,
                ),
              ),
            ],
            if (presentation.leaseDetail != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                presentation.leaseDetail!,
                key: const Key('recovery_lease_detail'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: foregroundColor,
                ),
              ),
            ],
            if (presentation.signInGuidance != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                presentation.signInGuidance!,
                key: const Key('recovery_sign_in_guidance'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (presentation.manualReviewNotice != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                presentation.manualReviewNotice!,
                key: const Key('recovery_manual_review_notice'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (presentation.canResumeOriginalActor ||
                presentation.canReviewConfirmed ||
                presentation.canRefreshStatus) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  if (presentation.canResumeOriginalActor)
                    FilledButton.icon(
                      key: const Key('resume_original_actor_button'),
                      onPressed: _isSubmitting
                          ? null
                          : _resumeOriginalActorAndSubmit,
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('Resume Submission'),
                    ),
                  if (presentation.canReviewConfirmed)
                    FilledButton.tonalIcon(
                      key: const Key('review_confirmed_result_button'),
                      onPressed: _isLoadingConfirmedStatus
                          ? null
                          : _reviewConfirmedServerResult,
                      icon: _isLoadingConfirmedStatus
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fact_check_outlined, size: 18),
                      label: const Text('Review Confirmed Result'),
                    ),
                  if (presentation.canRefreshStatus)
                    OutlinedButton.icon(
                      key: const Key('refresh_recovery_inline_button'),
                      onPressed: _isRefreshingRecovery
                          ? null
                          : _refreshRecoveryStatus,
                      icon: _isRefreshingRecovery
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: const Text('Refresh Status'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmedServerStatusCard(ThemeData theme) {
    final assessment = _confirmedServerAssessment;
    final evidenceList = _confirmedServerEvidence;
    final error = _confirmedServerStatusError;
    return Card(
      key: const Key('confirmed_server_status_card'),
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Confirmed Server Status (Read-Only)',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (error != null)
              Text(error, style: TextStyle(color: theme.colorScheme.error))
            else if (assessment != null) ...[
              Text('Title: ${assessment.title}'),
              Text('Status: ${assessment.status.name}'),
              Text(
                'Score: ${assessment.score.rawScore} / ${assessment.score.maxScore}',
              ),
              Text('Registered evidence files: ${evidenceList?.length ?? 0}'),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payloadLocked = _isPayloadLocked;
    final directRetryAllowed = _isDirectRetryAllowed;
    final knownDraft = _effectiveKnownDraft;
    final isLegacyQuarantined =
        (knownDraft?.isLegacyUnknown ?? false) ||
        (widget.initialDraft?.isLegacyUnknown ?? false);
    final recoveryPresentation = knownDraft != null
        ? buildAssessmentRecoveryPresentation(
            draft: knownDraft,
            now: ref.read(appClockProvider)().toUtc(),
            liveActor: _liveActor,
            liveAuthChecked: _liveAuthChecked,
            liveAuthInvalid: _liveAuthInvalid,
            liveTargetAuthorization: _liveTargetAuthorization,
          )
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.initialDraft != null
              ? 'Edit Assessment Draft'
              : 'Add Assessment Result',
        ),
        actions: [
          if (knownDraft != null)
            IconButton(
              key: const Key('refresh_recovery_status_button'),
              tooltip: 'Refresh Recovery Status',
              onPressed: _isRefreshingRecovery ? null : _refreshRecoveryStatus,
              icon: const Icon(Icons.refresh),
            ),
        ],
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
                    if (isLegacyQuarantined) ...[
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
                                  'It has been quarantined for data safety: its original submitted payload, IDs, and evidence are preserved read-only, '
                                  'and it cannot be edited or submitted directly.',
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
                    ] else if (payloadLocked) ...[
                      Card(
                        key: const Key('payload_locked_banner'),
                        color: theme.colorScheme.secondaryContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_outline,
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                              const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: Text(
                                  _buildPayloadLockedExplanation(knownDraft),
                                  style: TextStyle(
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
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
                    if (recoveryPresentation != null) ...[
                      _buildRecoveryStatusCard(theme, recoveryPresentation),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (_confirmedServerAssessment != null ||
                        _confirmedServerStatusError != null) ...[
                      _buildConfirmedServerStatusCard(theme),
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
                    KeyedSubtree(
                      key: ValueKey(
                        'subject_key_dropdown_epoch_$_dropdownEpoch',
                      ),
                      child: DropdownButtonFormField<SubjectKey>(
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
                        onChanged: payloadLocked ? null : _onSubjectKeyChanged,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('assessment_subject_field'),
                      controller: _subjectController,
                      enabled: !payloadLocked,
                      readOnly: payloadLocked,
                      onChanged: (_) => _handlePayloadTextEdited(),
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
                      enabled: !payloadLocked,
                      readOnly: payloadLocked,
                      onChanged: (_) => _handlePayloadTextEdited(),
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
                          child: KeyedSubtree(
                            key: ValueKey(
                              'type_dropdown_epoch_$_dropdownEpoch',
                            ),
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
                              onChanged: payloadLocked
                                  ? null
                                  : _onAssessmentTypeChanged,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: KeyedSubtree(
                            key: ValueKey(
                              'difficulty_dropdown_epoch_$_dropdownEpoch',
                            ),
                            child:
                                DropdownButtonFormField<AssessmentDifficulty>(
                                  key: const Key(
                                    'assessment_difficulty_dropdown',
                                  ),
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
                                  onChanged: payloadLocked
                                      ? null
                                      : _onDifficultyChanged,
                                ),
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
                            enabled: !payloadLocked,
                            readOnly: payloadLocked,
                            onChanged: (_) => _handlePayloadTextEdited(),
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
                            enabled: !payloadLocked,
                            readOnly: payloadLocked,
                            onChanged: (_) => _handlePayloadTextEdited(),
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
                                    onPressed: (_isSubmitting || payloadLocked)
                                        ? null
                                        : _pickEvidence,
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
                                          ? 'File: ${sanitizeDiagnosticBasename(_unrestoredPhotoPath)}\n'
                                                'This draft\'s locked evidence snapshot is missing or corrupted on disk and cannot be replaced or removed.'
                                          : 'File: ${sanitizeDiagnosticBasename(_unrestoredPhotoPath)}\n'
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
                                          onPressed:
                                              (_isSubmitting || payloadLocked)
                                              ? null
                                              : _pickEvidence,
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
                                          onPressed:
                                              (_isSubmitting || payloadLocked)
                                              ? null
                                              : _removeEvidence,
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
                                        onPressed:
                                            (_isSubmitting || payloadLocked)
                                            ? null
                                            : _pickEvidence,
                                      ),
                                      IconButton(
                                        key: const Key(
                                          'remove_evidence_button',
                                        ),
                                        tooltip: _isEvidenceLocked
                                            ? 'Photo locked for this draft'
                                            : 'Remove Photo',
                                        icon: const Icon(Icons.close, size: 18),
                                        onPressed:
                                            (_isSubmitting || payloadLocked)
                                            ? null
                                            : _removeEvidence,
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
                                onPressed: (_isSubmitting || payloadLocked)
                                    ? null
                                    : _pickEvidence,
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
                            onPressed: (_isSubmitting || payloadLocked)
                                ? null
                                : _saveLocalDraft,
                            child: const Text('Save Local Draft'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: FilledButton(
                            key: const Key('submit_assessment_button'),
                            onPressed: (_isSubmitting || !directRetryAllowed)
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
                                : Text(
                                    recoveryPresentation?.actionKind ==
                                            AssessmentRecoveryUiActionKind
                                                .retryNow
                                        ? 'Retry Now'
                                        : 'Submit for Review',
                                  ),
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
