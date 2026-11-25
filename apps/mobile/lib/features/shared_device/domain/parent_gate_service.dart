import 'dart:convert';
import 'dart:math';

import 'package:learnward_application/learnward_application.dart';

import 'parent_gate_crypto.dart';
import 'parent_gate_models.dart';

export 'parent_gate_crypto.dart';
export 'parent_gate_models.dart';

/// Threat Model & Security Boundary for Shared-Device Parent Gate (v2):
///
/// - **KDF & Comparison:** Uses pure-Dart PBKDF2-HMAC-SHA-256 (`>= 100,000`
///   production iterations) with 16-byte CSPRNG salt, worker-isolate execution,
///   and constant-time comparison. Never persists plaintext PINs.
/// - **Atomic Persistence & Concurrency:** All credential writes, v1->v2 upgrades,
///   lockout attempt tracking, and manual recovery commits use atomic
///   [LocalMetadataStore.compareAndSwapMetadataBatch]. Pessimistic lockout
///   reservation precedes KDF execution so overlapping attempts cannot drop
///   failure counts or evade lockout.
/// - **Dual-Clock Lockout:** Combines UTC [Clock] with in-process [MonotonicClock]
///   so forward/backward wall-clock changes cannot shorten active lockouts, while
///   enforcing an explicit bounded clamp (`min(lockoutDuration, 30m)`) on
///   backward skew across process restarts.
/// - **Fencing & Household Ownership (`D1.3`, `D1.6`, `R38-05`–`R38-10`):**
///   Supports `ParentGateOperationFence` pre-commit/post-commit verification,
///   household `ownerFamilyId` isolation, and strict 4-conjunct legacy outbox
///   provenance resolution without silent cross-family overwrite.
class ParentGateService {
  ParentGateService(
    this._store, {
    Clock? clock,
    MonotonicClock? monotonicClock,
    this.minIterations = ParentGateCrypto.productionMinIterations,
    this.configuredIterations = ParentGateCrypto.productionMinIterations,
    this.runInIsolate = true,
  }) : assert(minIterations >= 1),
       assert(configuredIterations >= minIterations),
       _clock = clock ?? const SystemClock(),
       _monotonicClock = monotonicClock ?? StopwatchMonotonicClock();

  final LocalMetadataStore _store;
  final Clock _clock;
  final MonotonicClock _monotonicClock;
  final int minIterations;
  final int configuredIterations;
  final bool runInIsolate;

  static const int _maxCasRetries = 16;
  static final RegExp _pinRegex = RegExp(r'^\d{4}$');

  /// Reservation TTL for in-flight KDF attempts before automatic expiry pruning.
  static const Duration reservationTtl = Duration(seconds: 15);

  /// Maximum backward wall-clock skew clamp across process restarts (`30` min).
  static const Duration maxRestartBackwardSkewClamp = Duration(minutes: 30);

  /// Current versioned metadata keys.
  static const String credentialV2Key = 'parent_gate_credential_v2';
  static const String lockoutV1Key = 'parent_gate_lockout_v1';
  static const String containmentFenceV1Key = 'containment_fence_v1';
  static const String containmentRecoveryLockV1Key =
      'containment_recovery_lock_v1';
  static const String lastContainmentRecoveryAuditV1Key =
      'last_containment_recovery_audit_v1';
  static const String activeChildSessionKey = 'active_child_session';

  /// Legacy v1 metadata keys retained strictly for v1->v2 verification upgrade
  /// and atomic deletion during credential upgrade or explicit recovery.
  static const String pinHashKey = 'parent_gate_pin_hash';
  static const String pinSaltKey = 'parent_gate_pin_salt';

  _ObservedLockoutDeadline? _observedLockout;

  bool get runsInIsolate => runInIsolate;

  /// Reads and classifies the persisted credential state fail-closed.
  Future<({ParentGateCredentialStatus status, ParentGateCredentialV2? v2})>
  inspectCredential() async {
    final snapshot = await _readCredentialSnapshot();
    return (status: snapshot.status, v2: snapshot.v2);
  }

  /// Returns `true` when a v2, legacy v1, or corrupt PIN credential exists
  /// (failing closed against treating corruption as unconfigured).
  Future<bool> hasConfiguredPin() async {
    final snapshot = await _readCredentialSnapshot();
    return snapshot.status != ParentGateCredentialStatus.missing;
  }

  /// Alias for [hasConfiguredPin].
  Future<bool> hasCustomPin() => hasConfiguredPin();

  /// Returns the persisted `ownerFamilyId` for a valid v2 credential, or `null`.
  Future<String?> readOwnerFamilyId() async {
    final snapshot = await _readCredentialSnapshot();
    return snapshot.v2?.ownerFamilyId;
  }

  /// Configures an initial 4-digit Parent PIN when no credential exists (`D1.5`, `R39-03`, `R39-04`).
  ///
  /// Strictly restricted to initial setup (`ParentGateCredentialStatus.missing`)
  /// with non-empty [ownerFamilyId], non-empty [configuredByActorUserId], a
  /// matching [ParentGateOperationFence], and positive active adult verification
  /// for [ownerFamilyId]. Never writes an unowned `parent_gate_credential_v2`.
  Future<ParentGateCredentialV2> setPin(
    String newPin, {
    String? ownerFamilyId,
    String? configuredByActorUserId,
    bool hasPositiveServerAdultVerification = false,
    List<String> verifiedActiveAdultFamilyIds = const [],
    ParentGateOperationFence? fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) async {
    if (!_pinRegex.hasMatch(newPin)) {
      throw ArgumentError('Parent PIN must be exactly 4 digits');
    }
    _requireAuthorizedAdultFence(
      familyId: ownerFamilyId,
      actorUserId: configuredByActorUserId,
      hasPositiveServerAdultVerification: hasPositiveServerAdultVerification,
      verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
      fence: fence,
      operationName: 'Initial Parent PIN setup',
    );
    return _commitReplacementCredential(
      newPin,
      ownerFamilyId: ownerFamilyId,
      configuredByActorUserId: configuredByActorUserId,
      mode: _CredentialWriteMode.initialSetupOnly,
      fence: fence,
      preCommitGuard: preCommitGuard,
      onBeforePreCommitGuard: onBeforePreCommitGuard,
      onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
    );
  }

  /// Explicitly reassigns a cross-household PIN after confirmation in Parent Mode (`C0-27`, `R39-03`).
  Future<ParentGateCredentialV2> reassignCrossFamilyPin({
    required String newPin,
    required String targetFamilyId,
    required String actorUserId,
    required bool hasPositiveServerAdultVerification,
    required List<String> verifiedActiveAdultFamilyIds,
    ParentGateOperationFence? fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) {
    if (!_pinRegex.hasMatch(newPin)) {
      throw ArgumentError('Parent PIN must be exactly 4 digits');
    }
    _requireAuthorizedAdultFence(
      familyId: targetFamilyId,
      actorUserId: actorUserId,
      hasPositiveServerAdultVerification: hasPositiveServerAdultVerification,
      verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
      fence: fence,
      operationName: 'Cross-family PIN reassignment',
    );
    return _commitReplacementCredential(
      newPin,
      ownerFamilyId: targetFamilyId,
      configuredByActorUserId: actorUserId,
      mode: _CredentialWriteMode.authorizedCrossFamilyReassignment,
      fence: fence,
      preCommitGuard: preCommitGuard,
      onBeforePreCommitGuard: onBeforePreCommitGuard,
      onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
    );
  }

  /// Recovers a corrupted credential by installing a brand-new PIN after adult verification (`R39-03`).
  ///
  /// Refuses to overwrite an intact valid v2 or legacy v1 PIN; use [changePin],
  /// [resetPinAfterReauth], or [reassignCrossFamilyPin] instead.
  Future<ParentGateCredentialV2> recoverCorruptCredential({
    required String newPin,
    required String targetFamilyId,
    required String actorUserId,
    required bool hasPositiveServerAdultVerification,
    required List<String> verifiedActiveAdultFamilyIds,
    ParentGateOperationFence? fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) {
    if (!_pinRegex.hasMatch(newPin)) {
      throw ArgumentError('Parent PIN must be exactly 4 digits');
    }
    _requireAuthorizedAdultFence(
      familyId: targetFamilyId,
      actorUserId: actorUserId,
      hasPositiveServerAdultVerification: hasPositiveServerAdultVerification,
      verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
      fence: fence,
      operationName: 'Corrupt PIN recovery',
    );
    return _commitReplacementCredential(
      newPin,
      ownerFamilyId: targetFamilyId,
      configuredByActorUserId: actorUserId,
      mode: _CredentialWriteMode.authorizedCorruptRecoveryOnly,
      fence: fence,
      preCommitGuard: preCommitGuard,
      onBeforePreCommitGuard: onBeforePreCommitGuard,
      onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
    );
  }

  /// Authenticated PIN change requiring valid [currentPin] verification first (`C0-18`, `R39-03`).
  Future<PinVerificationResult> changePin({
    required String currentPin,
    required String newPin,
    String? actorFamilyId,
    String? actorUserId,
    bool hasPositiveServerAdultVerification = false,
    List<String> verifiedActiveAdultFamilyIds = const [],
    ParentGateOperationFence? fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePhase1PreCommitGuard,
    Future<void> Function()? onAfterPhase1GuardBeforeCommit,
    Future<void> Function(StagedPinVerificationAttempt attempt)?
    onAfterKdfBeforeFinalize,
    Future<void> Function()? onBeforeFinalizePreCommitGuard,
    Future<void> Function()? onAfterFinalizeGuardBeforeCommit,
  }) async {
    if (!_pinRegex.hasMatch(newPin)) {
      throw ArgumentError('Parent PIN must be exactly 4 digits');
    }

    final normalizedFamilyId = _normalizeOptionalId(
      actorFamilyId ?? fence?.verifiedFamilyId,
    );
    final normalizedActorId = _normalizeOptionalId(
      actorUserId ?? fence?.actorUserId,
    );

    final newSaltBytes = ParentGateCrypto.generateRandomBytes();
    final newSaltHex = ParentGateCrypto.bytesToHex(newSaltBytes);
    final newDerived = await ParentGateCrypto.pbkdf2HmacSha256(
      password: utf8.encode(newPin),
      salt: newSaltBytes,
      iterations: configuredIterations,
      keyLengthBytes: ParentGateCrypto.defaultKeyLengthBytes,
      runInIsolate: runInIsolate,
    );
    final newHashHex = ParentGateCrypto.bytesToHex(newDerived);

    final snap = await _readCredentialSnapshot();
    final preservedFamilyId = normalizedFamilyId ?? snap.v2?.ownerFamilyId;

    return verifyPinDetailed(
      currentPin,
      actorFamilyId: normalizedFamilyId,
      actorUserId: normalizedActorId,
      hasPositiveServerAdultVerification: hasPositiveServerAdultVerification,
      verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
      fence: fence,
      preCommitGuard: preCommitGuard,
      onBeforePhase1PreCommitGuard: onBeforePhase1PreCommitGuard,
      onAfterPhase1GuardBeforeCommit: onAfterPhase1GuardBeforeCommit,
      onAfterKdfBeforeFinalize: onAfterKdfBeforeFinalize,
      onBeforeFinalizePreCommitGuard: onBeforeFinalizePreCommitGuard,
      onAfterFinalizeGuardBeforeCommit: onAfterFinalizeGuardBeforeCommit,
      additionalMutationsBuilder: (nowUtc) {
        final nextRevision = (snap.v2?.credentialRevision ?? 1) + 1;
        final replacement = ParentGateCredentialV2(
          version: 2,
          kdf: ParentGateCrypto.kdfAlgorithmId,
          iterations: configuredIterations,
          keyLengthBytes: ParentGateCrypto.defaultKeyLengthBytes,
          saltHex: newSaltHex,
          hashHex: newHashHex,
          ownerFamilyId: preservedFamilyId,
          configuredByActorUserId: normalizedActorId,
          credentialRevision: nextRevision,
          updatedAtUtc: nowUtc,
        );
        return [
          MetadataMutation.upsert(
            key: credentialV2Key,
            value: replacement.toJsonString(),
            updatedAt: nowUtc,
          ),
          if (snap.rawV1Hash != null)
            const MetadataMutation.delete(key: pinHashKey),
          if (snap.rawV1Salt != null)
            const MetadataMutation.delete(key: pinSaltKey),
        ];
      },
    );
  }

  /// Forgotten-PIN reset outside Child Mode after fresh post-sign-out adult reauth (`C0-18`).
  ///
  /// Permits reset only when existing credential ownership is unbound/legacy/corrupt
  /// or matches [targetFamilyId]. Refuses silent cross-family overwrite of another
  /// family's bound v2 credential.
  Future<ParentGateCredentialV2> resetPinAfterReauth({
    required String newPin,
    required String targetFamilyId,
    required String actorUserId,
    required bool isPostSignOutFreshAdultAuth,
    required bool hasPositiveServerAdultVerification,
    required List<String> verifiedActiveAdultFamilyIds,
    ParentGateOperationFence? fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) async {
    if (!_pinRegex.hasMatch(newPin)) {
      throw ArgumentError('Parent PIN must be exactly 4 digits');
    }
    if (!isPostSignOutFreshAdultAuth) {
      throw ParentGateFencedOperationException(
        'PIN reset requires fresh post-sign-out adult reauthentication.',
      );
    }
    _requireAuthorizedAdultFence(
      familyId: targetFamilyId,
      actorUserId: actorUserId,
      hasPositiveServerAdultVerification: hasPositiveServerAdultVerification,
      verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
      fence: fence,
      operationName: 'PIN reset',
    );

    final normalizedFamilyId = _normalizeOptionalId(targetFamilyId)!;
    final normalizedActorId = _normalizeOptionalId(actorUserId)!;

    final snap = await _readCredentialSnapshot();
    if (snap.status == ParentGateCredentialStatus.validV2 &&
        snap.v2!.ownerFamilyId != null &&
        snap.v2!.ownerFamilyId != normalizedFamilyId) {
      throw ParentGateOwnershipConflictException(
        'Cannot reset Parent PIN owned by a different household without explicit cross-family reassignment.',
      );
    }

    return _commitReplacementCredential(
      newPin,
      ownerFamilyId: normalizedFamilyId,
      configuredByActorUserId: normalizedActorId,
      mode: _CredentialWriteMode.authorizedSameHouseholdOrUnownedReset,
      fence: fence,
      preCommitGuard: preCommitGuard,
      onBeforePreCommitGuard: onBeforePreCommitGuard,
      onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
    );
  }

  Future<ParentGateCredentialV2> _commitReplacementCredential(
    String newPin, {
    required _CredentialWriteMode mode,
    String? ownerFamilyId,
    String? configuredByActorUserId,
    ParentGateOperationFence? fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) async {
    if (!_pinRegex.hasMatch(newPin)) {
      throw ArgumentError('Parent PIN must be exactly 4 digits');
    }

    final normalizedFamilyId = _normalizeOptionalId(ownerFamilyId);
    final normalizedActorId = _normalizeOptionalId(configuredByActorUserId);
    final saltBytes = ParentGateCrypto.generateRandomBytes();
    final saltHex = ParentGateCrypto.bytesToHex(saltBytes);
    final derived = await ParentGateCrypto.pbkdf2HmacSha256(
      password: utf8.encode(newPin),
      salt: saltBytes,
      iterations: configuredIterations,
      keyLengthBytes: ParentGateCrypto.defaultKeyLengthBytes,
      runInIsolate: runInIsolate,
    );
    final hashHex = ParentGateCrypto.bytesToHex(derived);

    for (var attempt = 0; attempt < _maxCasRetries; attempt++) {
      final snap = await _readCredentialSnapshot();
      final rawLockout = await _store.readMetadata(lockoutV1Key);
      final parsedLockout = rawLockout == null
          ? null
          : ParentGateLockoutV1.tryParse(rawLockout);
      final rawContainmentFence = await _store.readMetadata(
        containmentFenceV1Key,
      );

      if (preCommitGuard != null && !preCommitGuard()) {
        throw ParentGateFencedOperationException(
          'PIN write aborted by pre-commit guard.',
        );
      }
      if (fence?.expectedContainmentFenceRaw != null &&
          rawContainmentFence != fence!.expectedContainmentFenceRaw) {
        throw ParentGateFencedOperationException(
          'Containment fence mismatch during PIN write.',
        );
      }

      switch (mode) {
        case _CredentialWriteMode.initialSetupOnly:
          if (snap.status == ParentGateCredentialStatus.corrupt) {
            throw ParentGatePinCorruptException(
              'Persisted Parent PIN credential is corrupted; explicit recovery is required.',
            );
          }
          if (snap.status == ParentGateCredentialStatus.validV2) {
            if (snap.v2!.ownerFamilyId != null &&
                (normalizedFamilyId == null ||
                    snap.v2!.ownerFamilyId != normalizedFamilyId)) {
              throw ParentGateOwnershipConflictException(
                'Existing Parent PIN belongs to another household; explicit cross-family reassignment is required.',
              );
            }
            throw ParentGatePinAlreadyConfiguredException(
              'Parent PIN is already configured; use changePin with the current PIN or an authorized recovery flow.',
            );
          }
          if (snap.status == ParentGateCredentialStatus.legacyV1) {
            throw ParentGatePinAlreadyConfiguredException(
              'An existing legacy Parent PIN is configured; verify and upgrade or use changePin / authorized recovery.',
            );
          }
        case _CredentialWriteMode.authorizedCorruptRecoveryOnly:
          if (snap.status == ParentGateCredentialStatus.validV2) {
            if (snap.v2!.ownerFamilyId != null &&
                snap.v2!.ownerFamilyId != normalizedFamilyId) {
              throw ParentGateOwnershipConflictException(
                'Cannot use corrupt recovery against another household\'s intact PIN.',
              );
            }
            throw ParentGatePinAlreadyConfiguredException(
              'Parent PIN is not corrupted; use changePin or resetPinAfterReauth.',
            );
          }
          if (snap.status == ParentGateCredentialStatus.legacyV1) {
            throw ParentGatePinAlreadyConfiguredException(
              'Legacy Parent PIN is intact; corrupt recovery applies only when credential metadata is corrupted or missing.',
            );
          }
        case _CredentialWriteMode.authorizedSameHouseholdOrUnownedReset:
          if (snap.status == ParentGateCredentialStatus.validV2 &&
              snap.v2!.ownerFamilyId != null &&
              snap.v2!.ownerFamilyId != normalizedFamilyId) {
            throw ParentGateOwnershipConflictException(
              'Cannot reset Parent PIN owned by a different household without explicit cross-family reassignment.',
            );
          }
        case _CredentialWriteMode.authorizedCrossFamilyReassignment:
          if (snap.status == ParentGateCredentialStatus.corrupt) {
            throw ParentGatePinCorruptException(
              'Persisted Parent PIN credential is corrupted; use recoverCorruptCredential.',
            );
          }
      }

      final nextCredentialRevision = (snap.v2?.credentialRevision ?? 0) + 1;
      final nowUtc = _clock.now().toUtc();
      final nextCred = ParentGateCredentialV2(
        version: 2,
        kdf: ParentGateCrypto.kdfAlgorithmId,
        iterations: configuredIterations,
        keyLengthBytes: ParentGateCrypto.defaultKeyLengthBytes,
        saltHex: saltHex,
        hashHex: hashHex,
        ownerFamilyId: normalizedFamilyId,
        configuredByActorUserId: normalizedActorId,
        credentialRevision: nextCredentialRevision,
        updatedAtUtc: nowUtc,
      );

      final nextLockout = ParentGateLockoutV1(
        version: 1,
        revision: (parsedLockout?.revision ?? 0) + 1,
        failedAttempts: 0,
        lockoutUntilUtc: null,
        lockoutDurationSeconds: 0,
        lockoutOwnerAttemptId: null,
        lastAttemptAtUtc: parsedLockout?.lastAttemptAtUtc,
        credentialRevision: nextCredentialRevision,
        inFlightReservations: const [],
      );

      final expectedValues = <String, String?>{
        credentialV2Key: snap.rawV2,
        pinHashKey: snap.rawV1Hash,
        pinSaltKey: snap.rawV1Salt,
        lockoutV1Key: rawLockout,
        if (fence?.expectedContainmentFenceRaw != null)
          containmentFenceV1Key: fence!.expectedContainmentFenceRaw,
      };

      final mutations = <MetadataMutation>[
        MetadataMutation.upsert(
          key: credentialV2Key,
          value: nextCred.toJsonString(),
          updatedAt: nowUtc,
        ),
        MetadataMutation.upsert(
          key: lockoutV1Key,
          value: nextLockout.toJsonString(),
          updatedAt: nowUtc,
        ),
        if (snap.rawV1Hash != null)
          const MetadataMutation.delete(key: pinHashKey),
        if (snap.rawV1Salt != null)
          const MetadataMutation.delete(key: pinSaltKey),
      ];

      final committed = await _store.compareAndSwapMetadataBatch(
        expectedValues: expectedValues,
        mutations: mutations,
        preCommitGuard: preCommitGuard,
        onBeforePreCommitGuard: onBeforePreCommitGuard,
        onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
      );

      if (committed) {
        _observedLockout = null;
        return nextCred;
      }

      if (preCommitGuard != null && !preCommitGuard()) {
        throw ParentGateFencedOperationException(
          'PIN write aborted by pre-commit guard before commit.',
        );
      }
    }

    throw ParentGateFencedOperationException(
      'Exceeded CAS retry budget while writing Parent PIN.',
    );
  }

  /// Checks whether cryptographic PIN verification AND full adult/actor/family/fence
  /// Parent Mode authorization succeed (`R39-05`).
  Future<bool> verifyPin(
    String enteredPin, {
    String? actorFamilyId,
    String? actorUserId,
    bool hasPositiveServerAdultVerification = false,
    List<String> verifiedActiveAdultFamilyIds = const [],
    ParentGateOperationFence? fence,
  }) async {
    final result = await verifyPinDetailed(
      enteredPin,
      actorFamilyId: actorFamilyId,
      actorUserId: actorUserId,
      hasPositiveServerAdultVerification: hasPositiveServerAdultVerification,
      verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
      fence: fence,
    );
    return result.isAuthorizedToExitChildMode;
  }

  /// Executes all three verification phases with atomic reservation, KDF, and CAS finalize.
  ///
  /// When the persisted credential is legacy v1 (`pinHashKey` + `pinSaltKey`),
  /// verification only upgrades `v1 -> v2` if explicit actor/family binding,
  /// a matching [fence], AND positive current adult authorization
  /// ([hasPositiveServerAdultVerification] + [verifiedActiveAdultFamilyIds])
  /// are all present (`R39-02`). Otherwise legacy v1 credentials remain intact.
  Future<PinVerificationResult> verifyPinDetailed(
    String enteredPin, {
    String? actorFamilyId,
    String? actorUserId,
    bool hasPositiveServerAdultVerification = false,
    List<String> verifiedActiveAdultFamilyIds = const [],
    ParentGateOperationFence? fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePhase1PreCommitGuard,
    Future<void> Function()? onAfterPhase1GuardBeforeCommit,
    Future<void> Function(StagedPinVerificationAttempt attempt)?
    onAfterKdfBeforeFinalize,
    Future<void> Function()? onBeforeFinalizePreCommitGuard,
    Future<void> Function()? onAfterFinalizeGuardBeforeCommit,
    Map<String, String?>? additionalExpectedValues,
    List<MetadataMutation> Function(DateTime nowUtc)?
    additionalMutationsBuilder,
  }) async {
    final reservation = await beginStagedVerification(
      enteredPin: enteredPin,
      actorFamilyId: actorFamilyId,
      actorUserId: actorUserId,
      hasPositiveServerAdultVerification: hasPositiveServerAdultVerification,
      verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
      fence: fence,
      preCommitGuard: preCommitGuard,
      onBeforePreCommitGuard: onBeforePhase1PreCommitGuard,
      onAfterGuardBeforeCommit: onAfterPhase1GuardBeforeCommit,
      onAfterKdfBeforeFinalize: onAfterKdfBeforeFinalize,
    );

    if (!reservation.isReserved) {
      return reservation.immediateFailure!;
    }

    return completeStagedVerification(
      attempt: reservation.attempt!,
      preCommitGuard: preCommitGuard,
      onBeforePreCommitGuard: onBeforeFinalizePreCommitGuard,
      onAfterGuardBeforeCommit: onAfterFinalizeGuardBeforeCommit,
      additionalExpectedValues: additionalExpectedValues,
      additionalMutationsBuilder: additionalMutationsBuilder,
    );
  }

  /// Phases 1 + 2: Pessimistically reserves the attempt BEFORE KDF execution,
  /// evaluates PBKDF2-HMAC-SHA-256 (or legacy v1 digest + derived v2 upgrade
  /// strictly when adult/actor/family/fence preconditions hold), and returns a
  /// staged handle ready for fenced CAS finalization.
  Future<StagedPinReservationResult> beginStagedVerification({
    required String enteredPin,
    String? actorFamilyId,
    String? actorUserId,
    bool hasPositiveServerAdultVerification = false,
    List<String> verifiedActiveAdultFamilyIds = const [],
    ParentGateOperationFence? fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
    Future<void> Function(StagedPinVerificationAttempt attempt)?
    onAfterKdfBeforeFinalize,
  }) async {
    final effectiveFamilyId = _normalizeOptionalId(
      actorFamilyId ?? fence?.verifiedFamilyId,
    );
    final effectiveActorId = _normalizeOptionalId(
      actorUserId ?? fence?.actorUserId,
    );

    late _CredentialSnapshot credSnapshot;
    late ParentGateLockoutV1 committedLockout;
    late String committedLockoutRaw;
    late String attemptId;
    var reserved = false;

    for (var retry = 0; retry < _maxCasRetries; retry++) {
      if (preCommitGuard != null && !preCommitGuard()) {
        return const StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.staleFence,
            failedAttempts: 0,
            message: 'Verification aborted because session context changed.',
          ),
        );
      }

      credSnapshot = await _readCredentialSnapshot();
      if (credSnapshot.status == ParentGateCredentialStatus.missing) {
        return const StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.credentialMissing,
            failedAttempts: 0,
            message: 'No Parent PIN is configured.',
          ),
        );
      }
      if (credSnapshot.status == ParentGateCredentialStatus.corrupt) {
        return const StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.corruptCredential,
            failedAttempts: 0,
            message: 'Parent PIN credential metadata is corrupted and must be recovered.',
          ),
        );
      }

      final credRevision = credSnapshot.v2?.credentialRevision ?? 1;
      if (fence?.expectedCredentialRevision != null &&
          credRevision != fence!.expectedCredentialRevision) {
        return const StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.staleCredentialRevision,
            failedAttempts: 0,
            message: 'Parent PIN changed during verification.',
          ),
        );
      }

      final ownerFamilyId = credSnapshot.v2?.ownerFamilyId;
      if (ownerFamilyId != null &&
          effectiveFamilyId != null &&
          ownerFamilyId != effectiveFamilyId) {
        return const StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.wrongFamilyOwner,
            failedAttempts: 0,
            message: 'This Parent PIN belongs to a different family.',
          ),
        );
      }

      final rawContainmentFence = await _store.readMetadata(
        containmentFenceV1Key,
      );
      final rawChildSession = await _store.readMetadata(activeChildSessionKey);
      if ((fence?.expectedContainmentFenceRaw != null &&
              rawContainmentFence != fence!.expectedContainmentFenceRaw) ||
          (fence?.expectedChildSessionRaw != null &&
              rawChildSession != fence!.expectedChildSessionRaw)) {
        return const StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.staleFence,
            failedAttempts: 0,
            message: 'Containment state changed before verification started.',
          ),
        );
      }

      final rawLockout = await _store.readMetadata(lockoutV1Key);
      late ParentGateLockoutV1 currentLockout;
      if (rawLockout == null) {
        currentLockout = ParentGateLockoutV1.initial(
          credentialRevision: credRevision,
        );
      } else {
        final parsed = ParentGateLockoutV1.tryParse(rawLockout);
        if (parsed == null) {
          return const StagedPinReservationResult.rejected(
            PinVerificationResult(
              outcome: PinVerificationOutcome.corruptCredential,
              failedAttempts: 0,
              message: 'Parent Gate lockout metadata is corrupted; unlocking blocked.',
            ),
          );
        }
        currentLockout = parsed;
      }

      final nowUtc = _clock.now().toUtc();
      final monoNow = _monotonicClock.elapsed();
      final remaining = _computeRemainingLockout(
        currentLockout,
        nowUtc,
        monoNow,
      );
      if (remaining > Duration.zero) {
        return StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.lockedOut,
            failedAttempts: currentLockout.failedAttempts,
            remainingLockout: remaining,
            message: _formatLockoutMessage(remaining),
          ),
        );
      }

      if (!_pinRegex.hasMatch(enteredPin)) {
        return StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.invalidFormat,
            failedAttempts: currentLockout.failedAttempts,
            message: 'PIN must be 4 digits.',
          ),
        );
      }

      final activeReservations = currentLockout.inFlightReservations
          .where((r) => r.expiresAtUtc.isAfter(nowUtc))
          .toList(growable: false);

      attemptId = ParentGateCrypto.generateRandomHex(16);
      final nextFailures = currentLockout.failedAttempts + 1;
      final nextLockoutSeconds = _lockoutDurationSecondsForFailures(
        nextFailures,
      );
      final nextLockoutUntil = nextLockoutSeconds > 0
          ? nowUtc.add(Duration(seconds: nextLockoutSeconds))
          : null;

      final nextLockout = ParentGateLockoutV1(
        version: 1,
        revision: currentLockout.revision + 1,
        failedAttempts: nextFailures,
        lockoutUntilUtc: nextLockoutUntil,
        lockoutDurationSeconds: nextLockoutSeconds,
        lockoutOwnerAttemptId: nextLockoutSeconds > 0 ? attemptId : null,
        lastAttemptAtUtc: nowUtc,
        credentialRevision: credRevision,
        inFlightReservations: [
          ...activeReservations,
          InFlightPinReservation(
            attemptId: attemptId,
            reservedAtUtc: nowUtc,
            expiresAtUtc: nowUtc.add(reservationTtl),
          ),
        ],
      );
      final nextLockoutRaw = nextLockout.toJsonString();

      final expectedValues = <String, String?>{
        lockoutV1Key: rawLockout,
        credentialV2Key: credSnapshot.rawV2,
        pinHashKey: credSnapshot.rawV1Hash,
        pinSaltKey: credSnapshot.rawV1Salt,
        if (fence?.expectedContainmentFenceRaw != null)
          containmentFenceV1Key: fence!.expectedContainmentFenceRaw,
        if (fence?.expectedChildSessionRaw != null)
          activeChildSessionKey: fence!.expectedChildSessionRaw,
      };

      final committed = await _store.compareAndSwapMetadataBatch(
        expectedValues: expectedValues,
        mutations: [
          MetadataMutation.upsert(
            key: lockoutV1Key,
            value: nextLockoutRaw,
            updatedAt: nowUtc,
          ),
        ],
        preCommitGuard: preCommitGuard,
        onBeforePreCommitGuard: onBeforePreCommitGuard,
        onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
      );

      if (committed) {
        committedLockout = nextLockout;
        committedLockoutRaw = nextLockoutRaw;
        if (nextLockoutSeconds > 0) {
          _recordInProcessLockout(
            nextLockout,
            Duration(seconds: nextLockoutSeconds),
            monoNow,
          );
        }
        reserved = true;
        break;
      }

      if (preCommitGuard != null && !preCommitGuard()) {
        return StagedPinReservationResult.rejected(
          PinVerificationResult(
            outcome: PinVerificationOutcome.staleFence,
            failedAttempts: currentLockout.failedAttempts,
            message: 'Verification aborted because session context changed.',
          ),
        );
      }
    }

    if (!reserved) {
      return const StagedPinReservationResult.rejected(
        PinVerificationResult(
          outcome: PinVerificationOutcome.concurrencyRetryExhausted,
          failedAttempts: 0,
          message: 'Too many simultaneous verification attempts. Try again.',
        ),
      );
    }

    // Phase 2: Derive key / check digest OUTSIDE lock.
    var pinMatched = false;
    ParentGateCredentialV2? upgradedV2;

    if (credSnapshot.status == ParentGateCredentialStatus.validV2) {
      final v2 = credSnapshot.v2!;
      final saltBytes = ParentGateCrypto.tryHexToBytes(v2.saltHex)!;
      final derived = await ParentGateCrypto.pbkdf2HmacSha256(
        password: utf8.encode(enteredPin),
        salt: saltBytes,
        iterations: v2.iterations,
        keyLengthBytes: v2.keyLengthBytes,
        runInIsolate: runInIsolate,
      );
      pinMatched = ParentGateCrypto.constantTimeEqualsHex(
        ParentGateCrypto.bytesToHex(derived),
        v2.hashHex,
      );
    } else if (credSnapshot.status == ParentGateCredentialStatus.legacyV1) {
      final candidateDigest = ParentGateCrypto.sha256V1PinHex(
        pin: enteredPin,
        salt: credSnapshot.rawV1Salt!,
      );
      pinMatched = ParentGateCrypto.constantTimeEqualsHex(
        candidateDigest,
        credSnapshot.rawV1Hash!,
      );
      final canUpgradeLegacyV1 =
          pinMatched &&
          _hasAuthorizedAdultFence(
            familyId: effectiveFamilyId,
            actorUserId: effectiveActorId,
            hasPositiveServerAdultVerification:
                hasPositiveServerAdultVerification,
            verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
            fence: fence,
          );
      if (canUpgradeLegacyV1) {
        final newSaltBytes = ParentGateCrypto.generateRandomBytes();
        final newDerived = await ParentGateCrypto.pbkdf2HmacSha256(
          password: utf8.encode(enteredPin),
          salt: newSaltBytes,
          iterations: configuredIterations,
          keyLengthBytes: ParentGateCrypto.defaultKeyLengthBytes,
          runInIsolate: runInIsolate,
        );
        upgradedV2 = ParentGateCredentialV2(
          version: 2,
          kdf: ParentGateCrypto.kdfAlgorithmId,
          iterations: configuredIterations,
          keyLengthBytes: ParentGateCrypto.defaultKeyLengthBytes,
          saltHex: ParentGateCrypto.bytesToHex(newSaltBytes),
          hashHex: ParentGateCrypto.bytesToHex(newDerived),
          ownerFamilyId: effectiveFamilyId,
          configuredByActorUserId: effectiveActorId,
          credentialRevision: 1,
          updatedAtUtc: _clock.now().toUtc(),
        );
      }
    }

    final hasAuthorizedExitContext = _hasAuthorizedAdultFence(
      familyId: effectiveFamilyId,
      actorUserId: effectiveActorId,
      hasPositiveServerAdultVerification: hasPositiveServerAdultVerification,
      verifiedActiveAdultFamilyIds: verifiedActiveAdultFamilyIds,
      fence: fence,
    );

    final stagedAttempt = StagedPinVerificationAttempt(
      attemptId: attemptId,
      pinMatched: pinMatched,
      hasAuthorizedExitContext: hasAuthorizedExitContext,
      credentialStatus: credSnapshot.status,
      reservedCredentialRevision: credSnapshot.v2?.credentialRevision ?? 1,
      reservedLockoutRevision: committedLockout.revision,
      reservedLockoutRaw: committedLockoutRaw,
      upgradedV2Credential: upgradedV2,
      legacyV1HashRaw: credSnapshot.rawV1Hash,
      legacyV1SaltRaw: credSnapshot.rawV1Salt,
      fence: fence,
    );

    if (onAfterKdfBeforeFinalize != null) {
      await onAfterKdfBeforeFinalize(stagedAttempt);
    }

    return StagedPinReservationResult.reserved(stagedAttempt);
  }

  /// Phase 3: Atomically finalizes a staged verification attempt via CAS.
  Future<PinVerificationResult> completeStagedVerification({
    required StagedPinVerificationAttempt attempt,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
    Map<String, String?>? additionalExpectedValues,
    List<MetadataMutation> Function(DateTime nowUtc)?
    additionalMutationsBuilder,
  }) async {
    final fence = attempt.fence;

    for (var retry = 0; retry < _maxCasRetries; retry++) {
      if (preCommitGuard != null && !preCommitGuard()) {
        return PinVerificationResult(
          outcome: PinVerificationOutcome.staleFence,
          attemptId: attempt.attemptId,
          failedAttempts: 0,
          message: 'Verification result discarded due to session transition.',
        );
      }

      final credSnapshot = await _readCredentialSnapshot();
      final rawLockout = await _store.readMetadata(lockoutV1Key);
      final currentLockout = ParentGateLockoutV1.tryParse(rawLockout);
      if (currentLockout == null) {
        return PinVerificationResult(
          outcome: PinVerificationOutcome.corruptCredential,
          attemptId: attempt.attemptId,
          failedAttempts: 0,
          message: 'Parent Gate lockout state is corrupted.',
        );
      }

      final currentCredRevision = credSnapshot.v2?.credentialRevision ?? 1;
      if (credSnapshot.status != attempt.credentialStatus ||
          currentCredRevision != attempt.reservedCredentialRevision) {
        return PinVerificationResult(
          outcome: PinVerificationOutcome.staleCredentialRevision,
          attemptId: attempt.attemptId,
          failedAttempts: currentLockout.failedAttempts,
          message: 'Parent PIN changed while verification was in progress.',
        );
      }

      final rawContainmentFence = await _store.readMetadata(
        containmentFenceV1Key,
      );
      final rawChildSession = await _store.readMetadata(activeChildSessionKey);
      if ((fence?.expectedContainmentFenceRaw != null &&
              rawContainmentFence != fence!.expectedContainmentFenceRaw) ||
          (fence?.expectedChildSessionRaw != null &&
              rawChildSession != fence!.expectedChildSessionRaw)) {
        return PinVerificationResult(
          outcome: PinVerificationOutcome.staleFence,
          attemptId: attempt.attemptId,
          failedAttempts: currentLockout.failedAttempts,
          message: 'Containment fence changed during verification.',
        );
      }

      final nowUtc = _clock.now().toUtc();
      final monoNow = _monotonicClock.elapsed();
      final activeRemaining = _computeRemainingLockout(
        currentLockout,
        nowUtc,
        monoNow,
      );

      final hasValidSelfReservation = currentLockout.inFlightReservations.any(
        (r) =>
            r.attemptId == attempt.attemptId && r.expiresAtUtc.isAfter(nowUtc),
      );
      final remainingReservations = currentLockout.inFlightReservations
          .where(
            (r) =>
                r.attemptId != attempt.attemptId &&
                r.expiresAtUtc.isAfter(nowUtc),
          )
          .toList(growable: false);

      // Lockout precedence rule (`C0-25(a)`): if another overlapping attempt
      // triggered lockout while our KDF was executing, OR this attempt's
      // reservation expired/was superseded, fail closed without clearing failures.
      final supersededByOtherLockout =
          currentLockout.lockoutOwnerAttemptId != null &&
          currentLockout.lockoutOwnerAttemptId != attempt.attemptId;
      final lockedByAnotherAttempt =
          supersededByOtherLockout && activeRemaining > Duration.zero;
      final expiredOrSupersededSuccess =
          attempt.pinMatched &&
          (!hasValidSelfReservation || supersededByOtherLockout);
      final unauthorizedMatch =
          attempt.pinMatched && !attempt.hasAuthorizedExitContext;

      if (!attempt.pinMatched ||
          expiredOrSupersededSuccess ||
          unauthorizedMatch) {
        var nextFailedAttempts = currentLockout.failedAttempts;
        var nextLockoutUntilUtc = currentLockout.lockoutUntilUtc;
        var nextLockoutDurationSeconds = currentLockout.lockoutDurationSeconds;
        var nextLockoutOwnerAttemptId = currentLockout.lockoutOwnerAttemptId;

        // If PIN matched cryptographically without adult/fence exit authority,
        // revert only this attempt's speculative Phase 1 increment so wrong-PIN
        // accounting stays exact without resetting prior failures or authorizing unlock.
        if (unauthorizedMatch &&
            hasValidSelfReservation &&
            !supersededByOtherLockout &&
            nextFailedAttempts > 0) {
          nextFailedAttempts -= 1;
          if (currentLockout.lockoutOwnerAttemptId == attempt.attemptId) {
            nextLockoutUntilUtc = null;
            nextLockoutDurationSeconds = 0;
            nextLockoutOwnerAttemptId = null;
            _observedLockout = null;
          }
        }

        final nextLockout = currentLockout.copyWith(
          revision: currentLockout.revision + 1,
          failedAttempts: nextFailedAttempts,
          lockoutUntilUtc: () => nextLockoutUntilUtc,
          lockoutDurationSeconds: nextLockoutDurationSeconds,
          lockoutOwnerAttemptId: () => nextLockoutOwnerAttemptId,
          inFlightReservations: remainingReservations,
        );
        final committed = await _store.compareAndSwapMetadataBatch(
          expectedValues: {
            lockoutV1Key: rawLockout,
            credentialV2Key: credSnapshot.rawV2,
            pinHashKey: credSnapshot.rawV1Hash,
            pinSaltKey: credSnapshot.rawV1Salt,
            if (fence?.expectedContainmentFenceRaw != null)
              containmentFenceV1Key: fence!.expectedContainmentFenceRaw,
            if (fence?.expectedChildSessionRaw != null)
              activeChildSessionKey: fence!.expectedChildSessionRaw,
          },
          mutations: [
            MetadataMutation.upsert(
              key: lockoutV1Key,
              value: nextLockout.toJsonString(),
              updatedAt: nowUtc,
            ),
          ],
          preCommitGuard: preCommitGuard,
          onBeforePreCommitGuard: onBeforePreCommitGuard,
          onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
        );
        if (!committed) {
          if (preCommitGuard != null && !preCommitGuard()) {
            return PinVerificationResult(
              outcome: PinVerificationOutcome.staleFence,
              attemptId: attempt.attemptId,
              failedAttempts: currentLockout.failedAttempts,
              message:
                  'Verification result discarded due to session transition.',
            );
          }
          continue;
        }
        if (lockedByAnotherAttempt ||
            (activeRemaining > Duration.zero &&
                (!unauthorizedMatch || supersededByOtherLockout))) {
          return PinVerificationResult(
            outcome: PinVerificationOutcome.lockedOut,
            attemptId: attempt.attemptId,
            failedAttempts: nextLockout.failedAttempts,
            remainingLockout: activeRemaining,
            message: _formatLockoutMessage(activeRemaining),
          );
        }
        if (expiredOrSupersededSuccess) {
          return PinVerificationResult(
            outcome: PinVerificationOutcome.staleFence,
            attemptId: attempt.attemptId,
            failedAttempts: nextLockout.failedAttempts,
            message: 'Verification reservation expired or was superseded before unlock.',
          );
        }
        if (unauthorizedMatch) {
          return PinVerificationResult(
            outcome: PinVerificationOutcome.pinMatchedAuthorizationRequired,
            attemptId: attempt.attemptId,
            failedAttempts: nextLockout.failedAttempts,
            upgradedFromV1: false,
            message: 'Parent PIN matched, but verified adult session authorization is required to leave Child Mode.',
          );
        }
        return PinVerificationResult(
          outcome: PinVerificationOutcome.incorrectPin,
          attemptId: attempt.attemptId,
          failedAttempts: nextLockout.failedAttempts,
          remainingAttemptsBeforeLockout: max(
            0,
            5 - nextLockout.failedAttempts,
          ),
          message: _formatIncorrectPinMessage(nextLockout.failedAttempts),
        );
      }

      // Valid match without competing lockout -> atomically reset lockout,
      // upgrade v1->v2 if applicable, and apply caller's fenced mutations.
      final nextCredRevision =
          attempt.upgradedV2Credential?.credentialRevision ??
          attempt.reservedCredentialRevision;
      final resetLockout = ParentGateLockoutV1(
        version: 1,
        revision: currentLockout.revision + 1,
        failedAttempts: 0,
        lockoutUntilUtc: null,
        lockoutDurationSeconds: 0,
        lockoutOwnerAttemptId: null,
        lastAttemptAtUtc: currentLockout.lastAttemptAtUtc,
        credentialRevision: nextCredRevision,
        inFlightReservations: remainingReservations,
      );

      final expectedValues = <String, String?>{
        lockoutV1Key: rawLockout,
        credentialV2Key: credSnapshot.rawV2,
        pinHashKey: credSnapshot.rawV1Hash,
        pinSaltKey: credSnapshot.rawV1Salt,
        if (fence?.expectedContainmentFenceRaw != null)
          containmentFenceV1Key: fence!.expectedContainmentFenceRaw,
        if (fence?.expectedChildSessionRaw != null)
          activeChildSessionKey: fence!.expectedChildSessionRaw,
        ...?additionalExpectedValues,
      };

      final extraMutations =
          additionalMutationsBuilder?.call(nowUtc) ??
          const <MetadataMutation>[];

      final mutations = <MetadataMutation>[
        MetadataMutation.upsert(
          key: lockoutV1Key,
          value: resetLockout.toJsonString(),
          updatedAt: nowUtc,
        ),
        if (attempt.upgradedV2Credential != null) ...[
          MetadataMutation.upsert(
            key: credentialV2Key,
            value: attempt.upgradedV2Credential!.toJsonString(),
            updatedAt: nowUtc,
          ),
          if (credSnapshot.rawV1Hash != null)
            const MetadataMutation.delete(key: pinHashKey),
          if (credSnapshot.rawV1Salt != null)
            const MetadataMutation.delete(key: pinSaltKey),
        ],
        ...extraMutations,
      ];

      final committed = await _store.compareAndSwapMetadataBatch(
        expectedValues: expectedValues,
        mutations: mutations,
        preCommitGuard: preCommitGuard,
        onBeforePreCommitGuard: onBeforePreCommitGuard,
        onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
      );

      if (committed) {
        _observedLockout = null;
        return PinVerificationResult(
          outcome: PinVerificationOutcome.verified,
          attemptId: attempt.attemptId,
          failedAttempts: 0,
          upgradedFromV1: attempt.upgradedV2Credential != null,
        );
      }

      if (preCommitGuard != null && !preCommitGuard()) {
        return PinVerificationResult(
          outcome: PinVerificationOutcome.staleFence,
          attemptId: attempt.attemptId,
          failedAttempts: currentLockout.failedAttempts,
          message: 'Verification aborted by pre-commit guard.',
        );
      }
    }

    return PinVerificationResult(
      outcome: PinVerificationOutcome.concurrencyRetryExhausted,
      attemptId: attempt.attemptId,
      failedAttempts: 0,
      message: 'Failed to commit verification due to concurrent updates.',
    );
  }

  /// Removes only [attemptId] from `inFlightReservations` without resetting
  /// failure counts, deleting `active_child_session`, or altering another actor's lockout.
  Future<void> abortFencedAttempt(String attemptId) async {
    for (var retry = 0; retry < _maxCasRetries; retry++) {
      final rawLockout = await _store.readMetadata(lockoutV1Key);
      final parsed = ParentGateLockoutV1.tryParse(rawLockout);
      if (parsed == null) {
        return;
      }
      final nowUtc = _clock.now().toUtc();
      final nextReservations = parsed.inFlightReservations
          .where(
            (r) => r.attemptId != attemptId && r.expiresAtUtc.isAfter(nowUtc),
          )
          .toList(growable: false);
      if (nextReservations.length == parsed.inFlightReservations.length &&
          !parsed.inFlightReservations.any((r) => r.attemptId == attemptId)) {
        return;
      }

      final nextLockout = parsed.copyWith(
        revision: parsed.revision + 1,
        inFlightReservations: nextReservations,
      );
      final committed = await _store.compareAndSwapMetadataBatch(
        expectedValues: {lockoutV1Key: rawLockout},
        mutations: [
          MetadataMutation.upsert(
            key: lockoutV1Key,
            value: nextLockout.toJsonString(),
            updatedAt: nowUtc,
          ),
        ],
      );
      if (committed) {
        return;
      }
    }
  }

  /// Resolves 3-level legacy Child Mode / PIN ownership (`D1.6`, `R38-10`).
  Future<LegacyOwnershipResolution> resolveLegacyOwnership({
    required LegacyOutboxProvenanceSource provenanceSource,
    required bool hasPositiveServerAdultVerification,
    required List<String> verifiedActiveAdultFamilyIds,
    String? legacyChildSessionRaw,
  }) async {
    final credSnapshot = await _readCredentialSnapshot();
    final effectiveChildSessionRaw =
        legacyChildSessionRaw ??
        await _store.readMetadata(activeChildSessionKey);
    final childHint = LegacyChildHint.tryParse(effectiveChildSessionRaw);

    if (credSnapshot.status == ParentGateCredentialStatus.validV2 &&
        credSnapshot.v2!.ownerFamilyId != null) {
      return BoundOwnerResolution(
        ownerFamilyId: credSnapshot.v2!.ownerFamilyId!,
        legacyChildHint: childHint,
      );
    }

    // Strict 4-conjunct CorroboratedLegacyOwner predicate (`R38-10`):
    // (i) Well-formed non-empty (familyId, childId) legacy hint
    if (childHint == null) {
      return const UnresolvableLegacyOwnershipResolution(
        reason: 'missing_or_malformed_legacy_child_hint',
      );
    }

    final actorBoundRecords = await provenanceSource.listActorBoundRecords();
    final actorBoundFamilies = actorBoundRecords
        .map((r) => r.familyId.trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    // (ii) Unique non-empty actor-bound family matching legacyChildHint.familyId
    if (actorBoundFamilies.length != 1 ||
        actorBoundFamilies.single != childHint.familyId) {
      return UnresolvableLegacyOwnershipResolution(
        reason: actorBoundFamilies.isEmpty
            ? 'no_actor_bound_outbox_provenance'
            : 'ambiguous_or_contradictory_family_provenance',
        legacyChildHint: childHint,
      );
    }

    // (iii) At least one actor-bound row matching BOTH familyId AND childId
    final matchingRows = actorBoundRecords
        .where(
          (r) =>
              r.familyId.trim() == childHint.familyId &&
              r.childId?.trim() == childHint.childId,
        )
        .toList(growable: false);
    if (matchingRows.isEmpty) {
      return UnresolvableLegacyOwnershipResolution(
        reason: 'missing_child_id_correlation_in_actor_bound_outbox',
        legacyChildHint: childHint,
      );
    }

    // (iv) Positive server-verified active adult membership in legacyChildHint.familyId
    if (!hasPositiveServerAdultVerification ||
        !verifiedActiveAdultFamilyIds.contains(childHint.familyId)) {
      return UnresolvableLegacyOwnershipResolution(
        reason: 'missing_positive_server_adult_verification',
        legacyChildHint: childHint,
      );
    }

    return CorroboratedLegacyOwnerResolution(
      familyId: childHint.familyId,
      childId: childHint.childId,
      corroboratingRecords: matchingRows,
    );
  }

  /// Executes Restricted Manual Unbound Recovery (`D1.6`, `C0-39(g)`) atomically:
  /// requires fresh post-sign-out verified active adult auth + new v2 PIN setup,
  /// clears the containment lock keys via CAS, writes redacted recovery audit,
  /// and preserves 100% of local drafts, reward commands, and evidence photos.
  Future<ParentGateCredentialV2> commitRestrictedManualUnboundRecovery({
    required String newPin,
    required String actorUserId,
    required String targetFamilyId,
    required bool isPostSignOutFreshAdultAuth,
    required bool hasPositiveServerAdultVerification,
    required List<String> verifiedActiveAdultFamilyIds,
    required ParentGateOperationFence fence,
    bool Function()? preCommitGuard,
    Future<void> Function()? onBeforePreCommitGuard,
    Future<void> Function()? onAfterGuardBeforeCommit,
  }) async {
    if (!_pinRegex.hasMatch(newPin)) {
      throw ArgumentError('Parent PIN must be exactly 4 digits');
    }
    final normalizedActorId = _normalizeOptionalId(actorUserId);
    final normalizedFamilyId = _normalizeOptionalId(targetFamilyId);
    if (normalizedActorId == null || normalizedFamilyId == null) {
      throw ParentGateFencedOperationException(
        'Actor ID and target family ID are required for manual unbound recovery.',
      );
    }
    if (!isPostSignOutFreshAdultAuth ||
        !hasPositiveServerAdultVerification ||
        !verifiedActiveAdultFamilyIds.contains(normalizedFamilyId)) {
      throw ParentGateFencedOperationException(
        'Manual unbound recovery requires fresh post-sign-out verified active adult membership.',
      );
    }
    if (fence.actorUserId != normalizedActorId ||
        fence.verifiedFamilyId != normalizedFamilyId) {
      throw ParentGateFencedOperationException(
        'Operation fence does not match authenticated adult or target family.',
      );
    }

    final saltBytes = ParentGateCrypto.generateRandomBytes();
    final saltHex = ParentGateCrypto.bytesToHex(saltBytes);
    final derived = await ParentGateCrypto.pbkdf2HmacSha256(
      password: utf8.encode(newPin),
      salt: saltBytes,
      iterations: configuredIterations,
      keyLengthBytes: ParentGateCrypto.defaultKeyLengthBytes,
      runInIsolate: runInIsolate,
    );
    final hashHex = ParentGateCrypto.bytesToHex(derived);

    for (var retry = 0; retry < _maxCasRetries; retry++) {
      if (preCommitGuard != null && !preCommitGuard()) {
        throw ParentGateFencedOperationException(
          'Manual unbound recovery aborted by pre-commit guard.',
        );
      }

      final credSnapshot = await _readCredentialSnapshot();
      if (credSnapshot.status == ParentGateCredentialStatus.validV2 &&
          credSnapshot.v2!.ownerFamilyId != null &&
          credSnapshot.v2!.ownerFamilyId != normalizedFamilyId) {
        throw ParentGateOwnershipConflictException(
          'Device holds a bound v2 PIN for another household; manual unbound recovery is forbidden.',
        );
      }

      final rawLockout = await _store.readMetadata(lockoutV1Key);
      final parsedLockout = rawLockout == null
          ? null
          : ParentGateLockoutV1.tryParse(rawLockout);
      final rawRecoveryLock = await _store.readMetadata(
        containmentRecoveryLockV1Key,
      );
      final rawChildSession = await _store.readMetadata(activeChildSessionKey);
      final rawContainmentFence = await _store.readMetadata(
        containmentFenceV1Key,
      );
      final parsedContainmentFence = ContainmentFenceV1.tryParse(
        rawContainmentFence,
      );

      if ((fence.expectedChildSessionRaw != null &&
              rawChildSession != fence.expectedChildSessionRaw) ||
          (fence.expectedContainmentFenceRaw != null &&
              rawContainmentFence != fence.expectedContainmentFenceRaw)) {
        throw ParentGateFencedOperationException(
          'Containment state changed before manual recovery commit.',
        );
      }

      final nowUtc = _clock.now().toUtc();
      final nextCredRevision = (credSnapshot.v2?.credentialRevision ?? 0) + 1;
      final nextCredential = ParentGateCredentialV2(
        version: 2,
        kdf: ParentGateCrypto.kdfAlgorithmId,
        iterations: configuredIterations,
        keyLengthBytes: ParentGateCrypto.defaultKeyLengthBytes,
        saltHex: saltHex,
        hashHex: hashHex,
        ownerFamilyId: normalizedFamilyId,
        configuredByActorUserId: normalizedActorId,
        credentialRevision: nextCredRevision,
        updatedAtUtc: nowUtc,
      );

      final resetLockout = ParentGateLockoutV1(
        version: 1,
        revision: (parsedLockout?.revision ?? 0) + 1,
        failedAttempts: 0,
        lockoutUntilUtc: null,
        lockoutDurationSeconds: 0,
        lockoutOwnerAttemptId: null,
        lastAttemptAtUtc: parsedLockout?.lastAttemptAtUtc,
        credentialRevision: nextCredRevision,
        inFlightReservations: const [],
      );

      final nextFence = ContainmentFenceV1(
        version: 1,
        fenceEpoch: (parsedContainmentFence?.fenceEpoch ?? 0) + 1,
        actorUserId: normalizedActorId,
        sessionGeneration: fence.sessionGeneration,
        lockState: ContainmentFenceLockState.none,
        updatedAtUtc: nowUtc,
      );

      final auditMarker = LastContainmentRecoveryAuditV1(
        version: 1,
        reason:
            LastContainmentRecoveryAuditV1.manualUnboundLegacyRecoveryReason,
        targetFamilyId: normalizedFamilyId,
        actorUserId: normalizedActorId,
        recoveredAtUtc: nowUtc,
      );

      final expectedValues = <String, String?>{
        credentialV2Key: credSnapshot.rawV2,
        pinHashKey: credSnapshot.rawV1Hash,
        pinSaltKey: credSnapshot.rawV1Salt,
        lockoutV1Key: rawLockout,
        containmentRecoveryLockV1Key: rawRecoveryLock,
        activeChildSessionKey: rawChildSession,
        containmentFenceV1Key: rawContainmentFence,
      };

      final mutations = <MetadataMutation>[
        MetadataMutation.upsert(
          key: credentialV2Key,
          value: nextCredential.toJsonString(),
          updatedAt: nowUtc,
        ),
        MetadataMutation.upsert(
          key: lockoutV1Key,
          value: resetLockout.toJsonString(),
          updatedAt: nowUtc,
        ),
        MetadataMutation.upsert(
          key: containmentFenceV1Key,
          value: nextFence.toJsonString(),
          updatedAt: nowUtc,
        ),
        MetadataMutation.upsert(
          key: lastContainmentRecoveryAuditV1Key,
          value: auditMarker.toJsonString(),
          updatedAt: nowUtc,
        ),
        if (credSnapshot.rawV1Hash != null)
          const MetadataMutation.delete(key: pinHashKey),
        if (credSnapshot.rawV1Salt != null)
          const MetadataMutation.delete(key: pinSaltKey),
        if (rawChildSession != null)
          const MetadataMutation.delete(key: activeChildSessionKey),
        if (rawRecoveryLock != null)
          const MetadataMutation.delete(key: containmentRecoveryLockV1Key),
      ];

      final committed = await _store.compareAndSwapMetadataBatch(
        expectedValues: expectedValues,
        mutations: mutations,
        preCommitGuard: preCommitGuard,
        onBeforePreCommitGuard: onBeforePreCommitGuard,
        onAfterGuardBeforeCommit: onAfterGuardBeforeCommit,
      );

      if (committed) {
        _observedLockout = null;
        return nextCredential;
      }

      if (preCommitGuard != null && !preCommitGuard()) {
        throw ParentGateFencedOperationException(
          'Manual unbound recovery aborted by pre-commit guard before commit.',
        );
      }
    }

    throw ParentGateFencedOperationException(
      'Exceeded CAS retry budget during manual unbound recovery.',
    );
  }

  Future<_CredentialSnapshot> _readCredentialSnapshot() async {
    final rawV2 = await _store.readMetadata(credentialV2Key);
    final rawV1Hash = await _store.readMetadata(pinHashKey);
    final rawV1Salt = await _store.readMetadata(pinSaltKey);

    if (rawV2 != null) {
      final parsedV2 = ParentGateCredentialV2.tryParse(
        rawV2,
        minIterations: minIterations,
      );
      return _CredentialSnapshot(
        status: parsedV2 == null
            ? ParentGateCredentialStatus.corrupt
            : ParentGateCredentialStatus.validV2,
        v2: parsedV2,
        rawV2: rawV2,
        rawV1Hash: rawV1Hash,
        rawV1Salt: rawV1Salt,
      );
    }

    if (rawV1Hash == null && rawV1Salt == null) {
      return _CredentialSnapshot(
        status: ParentGateCredentialStatus.missing,
        v2: null,
        rawV2: null,
        rawV1Hash: null,
        rawV1Salt: null,
      );
    }

    final validV1HashBytes = rawV1Hash == null
        ? null
        : ParentGateCrypto.tryHexToBytes(rawV1Hash.trim());
    if (rawV1Hash == null ||
        rawV1Salt == null ||
        rawV1Salt.trim().isEmpty ||
        validV1HashBytes == null ||
        validV1HashBytes.length != 32) {
      return _CredentialSnapshot(
        status: ParentGateCredentialStatus.corrupt,
        v2: null,
        rawV2: null,
        rawV1Hash: rawV1Hash,
        rawV1Salt: rawV1Salt,
      );
    }

    return _CredentialSnapshot(
      status: ParentGateCredentialStatus.legacyV1,
      v2: null,
      rawV2: null,
      rawV1Hash: rawV1Hash,
      rawV1Salt: rawV1Salt,
    );
  }

  Duration _computeRemainingLockout(
    ParentGateLockoutV1 lockout,
    DateTime nowUtc,
    Duration monoNow,
  ) {
    final untilUtc = lockout.lockoutUntilUtc;
    if (untilUtc == null || lockout.lockoutDurationSeconds <= 0) {
      return Duration.zero;
    }

    final signature = _lockoutSignature(lockout);
    final observed = _observedLockout;
    if (observed != null && observed.signature == signature) {
      final diff = observed.deadline - monoNow;
      return diff > Duration.zero ? diff : Duration.zero;
    }

    final maxAllowedDuration = Duration(
      seconds: min(
        lockout.lockoutDurationSeconds,
        maxRestartBackwardSkewClamp.inSeconds,
      ),
    );
    final wallRemaining = untilUtc.difference(nowUtc);
    final lastAttempt = lockout.lastAttemptAtUtc ?? untilUtc;

    final Duration effectiveRemaining;
    if (nowUtc.isBefore(lastAttempt) || wallRemaining > maxAllowedDuration) {
      effectiveRemaining = maxAllowedDuration;
    } else if (wallRemaining > Duration.zero) {
      effectiveRemaining = wallRemaining;
    } else {
      effectiveRemaining = Duration.zero;
    }

    _observedLockout = _ObservedLockoutDeadline(
      signature: signature,
      deadline: monoNow + effectiveRemaining,
    );
    return effectiveRemaining;
  }

  void _recordInProcessLockout(
    ParentGateLockoutV1 lockout,
    Duration duration,
    Duration monoNow,
  ) {
    _observedLockout = _ObservedLockoutDeadline(
      signature: _lockoutSignature(lockout),
      deadline: monoNow + duration,
    );
  }

  String _lockoutSignature(ParentGateLockoutV1 lockout) =>
      '${lockout.failedAttempts}|${lockout.lockoutUntilUtc?.toIso8601String()}|${lockout.lockoutDurationSeconds}|${lockout.lockoutOwnerAttemptId}|${lockout.lastAttemptAtUtc?.toIso8601String()}';

  int _lockoutDurationSecondsForFailures(int failedAttempts) {
    if (failedAttempts < 5) return 0;
    return switch (failedAttempts) {
      5 => 30,
      6 => 60,
      7 => 300,
      8 => 900,
      _ => 1800,
    };
  }

  String _formatIncorrectPinMessage(int failedAttempts) {
    if (failedAttempts == 3) {
      return 'Incorrect PIN. 2 attempts remaining before timeout.';
    }
    if (failedAttempts == 4) {
      return 'Incorrect PIN. 1 attempt remaining before timeout.';
    }
    return 'Incorrect PIN. Try again.';
  }

  String _formatLockoutMessage(Duration remaining) {
    final seconds = max(1, (remaining.inMilliseconds / 1000).ceil());
    return 'Too many incorrect attempts. Try again in ${seconds}s.';
  }

  String? _normalizeOptionalId(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  bool _hasAuthorizedAdultFence({
    required String? familyId,
    required String? actorUserId,
    required bool hasPositiveServerAdultVerification,
    required List<String> verifiedActiveAdultFamilyIds,
    required ParentGateOperationFence? fence,
  }) {
    final normalizedFamily = _normalizeOptionalId(familyId);
    final normalizedActor = _normalizeOptionalId(actorUserId);
    if (normalizedFamily == null || normalizedActor == null || fence == null) {
      return false;
    }
    if (fence.actorUserId.trim() != normalizedActor ||
        fence.verifiedFamilyId?.trim() != normalizedFamily) {
      return false;
    }
    return hasPositiveServerAdultVerification &&
        verifiedActiveAdultFamilyIds.contains(normalizedFamily);
  }

  void _requireAuthorizedAdultFence({
    required String? familyId,
    required String? actorUserId,
    required bool hasPositiveServerAdultVerification,
    required List<String> verifiedActiveAdultFamilyIds,
    required ParentGateOperationFence? fence,
    required String operationName,
  }) {
    final normalizedFamily = _normalizeOptionalId(familyId);
    final normalizedActor = _normalizeOptionalId(actorUserId);
    if (normalizedFamily == null || normalizedActor == null) {
      throw ParentGateFencedOperationException(
        '$operationName requires non-empty ownerFamilyId and actorUserId.',
      );
    }
    if (fence == null) {
      throw ParentGateFencedOperationException(
        '$operationName requires an active ParentGateOperationFence.',
      );
    }
    if (fence.actorUserId.trim() != normalizedActor ||
        fence.verifiedFamilyId?.trim() != normalizedFamily) {
      throw ParentGateFencedOperationException(
        '$operationName fence actor/family does not match target ownership.',
      );
    }
    if (!hasPositiveServerAdultVerification ||
        !verifiedActiveAdultFamilyIds.contains(normalizedFamily)) {
      throw ParentGateFencedOperationException(
        '$operationName requires positively verified active adult membership for the target household.',
      );
    }
  }
}

final class _CredentialSnapshot {
  const _CredentialSnapshot({
    required this.status,
    required this.v2,
    required this.rawV2,
    required this.rawV1Hash,
    required this.rawV1Salt,
  });

  final ParentGateCredentialStatus status;
  final ParentGateCredentialV2? v2;
  final String? rawV2;
  final String? rawV1Hash;
  final String? rawV1Salt;
}

final class _ObservedLockoutDeadline {
  const _ObservedLockoutDeadline({
    required this.signature,
    required this.deadline,
  });

  final String signature;
  final Duration deadline;
}

enum _CredentialWriteMode {
  initialSetupOnly,
  authorizedSameHouseholdOrUnownedReset,
  authorizedCorruptRecoveryOnly,
  authorizedCrossFamilyReassignment,
}
