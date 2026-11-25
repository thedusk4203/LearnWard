import 'dart:convert';

import 'package:learnward_application/learnward_application.dart';

import 'parent_gate_crypto.dart';

/// Persisted `parent_gate_credential_v2` JSON payload.
final class ParentGateCredentialV2 {
  const ParentGateCredentialV2({
    required this.version,
    required this.kdf,
    required this.iterations,
    required this.keyLengthBytes,
    required this.saltHex,
    required this.hashHex,
    required this.credentialRevision,
    required this.updatedAtUtc,
    this.ownerFamilyId,
    this.configuredByActorUserId,
  });

  final int version;
  final String kdf;
  final int iterations;
  final int keyLengthBytes;
  final String saltHex;
  final String hashHex;
  final String? ownerFamilyId;
  final String? configuredByActorUserId;
  final int credentialRevision;
  final DateTime updatedAtUtc;

  /// Strictly decodes [raw] JSON, returning `null` if malformed or structurally invalid.
  static ParentGateCredentialV2? tryParse(
    String? raw, {
    int minIterations = ParentGateCrypto.productionMinIterations,
  }) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final version = decoded['version'];
      final kdf = decoded['kdf'];
      final iterations = decoded['iterations'];
      final keyLengthBytes = decoded['keyLengthBytes'];
      final saltHex = decoded['saltHex'];
      final hashHex = decoded['hashHex'];
      final ownerFamilyId = decoded['ownerFamilyId'];
      final configuredByActorUserId = decoded['configuredByActorUserId'];
      final credentialRevision = decoded['credentialRevision'];
      final updatedAtRaw = decoded['updatedAtUtc'];

      if (version != 2 || kdf != ParentGateCrypto.kdfAlgorithmId) {
        return null;
      }
      if (iterations is! int || iterations < minIterations) {
        return null;
      }
      if (keyLengthBytes is! int ||
          keyLengthBytes != ParentGateCrypto.defaultKeyLengthBytes) {
        return null;
      }
      if (saltHex is! String || hashHex is! String) {
        return null;
      }
      final saltBytes = ParentGateCrypto.tryHexToBytes(saltHex);
      final hashBytes = ParentGateCrypto.tryHexToBytes(hashHex);
      if (saltBytes == null ||
          saltBytes.length < ParentGateCrypto.defaultSaltLengthBytes ||
          hashBytes == null ||
          hashBytes.length != keyLengthBytes) {
        return null;
      }
      if (ownerFamilyId != null &&
          (ownerFamilyId is! String || ownerFamilyId.trim().isEmpty)) {
        return null;
      }
      if (configuredByActorUserId != null &&
          (configuredByActorUserId is! String ||
              configuredByActorUserId.trim().isEmpty)) {
        return null;
      }
      if (credentialRevision is! int || credentialRevision < 1) {
        return null;
      }
      if (updatedAtRaw is! String) {
        return null;
      }
      final updatedAtUtc = DateTime.tryParse(updatedAtRaw)?.toUtc();
      if (updatedAtUtc == null) {
        return null;
      }

      return ParentGateCredentialV2(
        version: version as int,
        kdf: kdf as String,
        iterations: iterations,
        keyLengthBytes: keyLengthBytes,
        saltHex: saltHex.toLowerCase(),
        hashHex: hashHex.toLowerCase(),
        ownerFamilyId: ownerFamilyId as String?,
        configuredByActorUserId: configuredByActorUserId as String?,
        credentialRevision: credentialRevision,
        updatedAtUtc: updatedAtUtc,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'kdf': kdf,
    'iterations': iterations,
    'keyLengthBytes': keyLengthBytes,
    'saltHex': saltHex,
    'hashHex': hashHex,
    'ownerFamilyId': ownerFamilyId,
    'configuredByActorUserId': configuredByActorUserId,
    'credentialRevision': credentialRevision,
    'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
  };

  String toJsonString() => jsonEncode(toJson());
}

/// Active in-flight attempt reservation inside `parent_gate_lockout_v1`.
final class InFlightPinReservation {
  const InFlightPinReservation({
    required this.attemptId,
    required this.reservedAtUtc,
    required this.expiresAtUtc,
  });

  final String attemptId;
  final DateTime reservedAtUtc;
  final DateTime expiresAtUtc;

  static InFlightPinReservation? tryParse(Object? decoded) {
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final attemptId = decoded['attemptId'];
    final reservedRaw = decoded['reservedAtUtc'];
    final expiresRaw = decoded['expiresAtUtc'];
    if (attemptId is! String || attemptId.isEmpty) {
      return null;
    }
    if (reservedRaw is! String || expiresRaw is! String) {
      return null;
    }
    final reservedAtUtc = DateTime.tryParse(reservedRaw)?.toUtc();
    final expiresAtUtc = DateTime.tryParse(expiresRaw)?.toUtc();
    if (reservedAtUtc == null || expiresAtUtc == null) {
      return null;
    }
    return InFlightPinReservation(
      attemptId: attemptId,
      reservedAtUtc: reservedAtUtc,
      expiresAtUtc: expiresAtUtc,
    );
  }

  Map<String, dynamic> toJson() => {
    'attemptId': attemptId,
    'reservedAtUtc': reservedAtUtc.toUtc().toIso8601String(),
    'expiresAtUtc': expiresAtUtc.toUtc().toIso8601String(),
  };
}

/// Persisted `parent_gate_lockout_v1` JSON payload.
final class ParentGateLockoutV1 {
  const ParentGateLockoutV1({
    required this.version,
    required this.revision,
    required this.failedAttempts,
    required this.lockoutDurationSeconds,
    required this.credentialRevision,
    required this.inFlightReservations,
    this.lockoutUntilUtc,
    this.lockoutOwnerAttemptId,
    this.lastAttemptAtUtc,
  });

  const ParentGateLockoutV1.initial({this.credentialRevision = 0})
    : version = 1,
      revision = 0,
      failedAttempts = 0,
      lockoutUntilUtc = null,
      lockoutDurationSeconds = 0,
      lockoutOwnerAttemptId = null,
      lastAttemptAtUtc = null,
      inFlightReservations = const [];

  final int version;
  final int revision;
  final int failedAttempts;
  final DateTime? lockoutUntilUtc;
  final int lockoutDurationSeconds;
  final String? lockoutOwnerAttemptId;
  final DateTime? lastAttemptAtUtc;
  final int credentialRevision;
  final List<InFlightPinReservation> inFlightReservations;

  static ParentGateLockoutV1? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final version = decoded['version'];
      final revision = decoded['revision'];
      final failedAttempts = decoded['failedAttempts'];
      final lockoutUntilRaw = decoded['lockoutUntilUtc'];
      final lockoutDurationSeconds = decoded['lockoutDurationSeconds'];
      final lockoutOwnerAttemptId = decoded['lockoutOwnerAttemptId'];
      final lastAttemptRaw = decoded['lastAttemptAtUtc'];
      final credentialRevision = decoded['credentialRevision'];
      final reservationsRaw = decoded['inFlightReservations'];

      if (version != 1 ||
          revision is! int ||
          revision < 0 ||
          failedAttempts is! int ||
          failedAttempts < 0 ||
          lockoutDurationSeconds is! int ||
          lockoutDurationSeconds < 0 ||
          credentialRevision is! int ||
          credentialRevision < 0) {
        return null;
      }

      DateTime? lockoutUntilUtc;
      if (lockoutUntilRaw != null) {
        if (lockoutUntilRaw is! String) return null;
        lockoutUntilUtc = DateTime.tryParse(lockoutUntilRaw)?.toUtc();
        if (lockoutUntilUtc == null) return null;
      }

      DateTime? lastAttemptAtUtc;
      if (lastAttemptRaw != null) {
        if (lastAttemptRaw is! String) return null;
        lastAttemptAtUtc = DateTime.tryParse(lastAttemptRaw)?.toUtc();
        if (lastAttemptAtUtc == null) return null;
      }

      if (lockoutOwnerAttemptId != null && lockoutOwnerAttemptId is! String) {
        return null;
      }

      final reservations = <InFlightPinReservation>[];
      if (reservationsRaw != null) {
        if (reservationsRaw is! List) return null;
        for (final entry in reservationsRaw) {
          final parsed = InFlightPinReservation.tryParse(entry);
          if (parsed == null) return null;
          reservations.add(parsed);
        }
      }

      return ParentGateLockoutV1(
        version: version as int,
        revision: revision,
        failedAttempts: failedAttempts,
        lockoutUntilUtc: lockoutUntilUtc,
        lockoutDurationSeconds: lockoutDurationSeconds,
        lockoutOwnerAttemptId: lockoutOwnerAttemptId as String?,
        lastAttemptAtUtc: lastAttemptAtUtc,
        credentialRevision: credentialRevision,
        inFlightReservations: List.unmodifiable(reservations),
      );
    } catch (_) {
      return null;
    }
  }

  ParentGateLockoutV1 copyWith({
    int? revision,
    int? failedAttempts,
    DateTime? Function()? lockoutUntilUtc,
    int? lockoutDurationSeconds,
    String? Function()? lockoutOwnerAttemptId,
    DateTime? Function()? lastAttemptAtUtc,
    int? credentialRevision,
    List<InFlightPinReservation>? inFlightReservations,
  }) {
    return ParentGateLockoutV1(
      version: version,
      revision: revision ?? this.revision,
      failedAttempts: failedAttempts ?? this.failedAttempts,
      lockoutUntilUtc: lockoutUntilUtc != null
          ? lockoutUntilUtc()
          : this.lockoutUntilUtc,
      lockoutDurationSeconds:
          lockoutDurationSeconds ?? this.lockoutDurationSeconds,
      lockoutOwnerAttemptId: lockoutOwnerAttemptId != null
          ? lockoutOwnerAttemptId()
          : this.lockoutOwnerAttemptId,
      lastAttemptAtUtc: lastAttemptAtUtc != null
          ? lastAttemptAtUtc()
          : this.lastAttemptAtUtc,
      credentialRevision: credentialRevision ?? this.credentialRevision,
      inFlightReservations: inFlightReservations ?? this.inFlightReservations,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'revision': revision,
    'failedAttempts': failedAttempts,
    'lockoutUntilUtc': lockoutUntilUtc?.toUtc().toIso8601String(),
    'lockoutDurationSeconds': lockoutDurationSeconds,
    'lockoutOwnerAttemptId': lockoutOwnerAttemptId,
    'lastAttemptAtUtc': lastAttemptAtUtc?.toUtc().toIso8601String(),
    'credentialRevision': credentialRevision,
    'inFlightReservations': inFlightReservations
        .map((r) => r.toJson())
        .toList(growable: false),
  };

  String toJsonString() => jsonEncode(toJson());
}

/// Persisted containment lock state stored in `containment_fence_v1`.
enum ContainmentFenceLockState {
  none('none'),
  activeChild('active_child'),
  containmentLocked('containment_locked'),
  recoveryReauthPending('recovery_reauth_pending');

  const ContainmentFenceLockState(this.wireValue);
  final String wireValue;

  static ContainmentFenceLockState? tryFromWire(String? raw) {
    for (final value in ContainmentFenceLockState.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Persisted `containment_fence_v1` JSON payload for local CAS linearization (`R38-07`).
final class ContainmentFenceV1 {
  const ContainmentFenceV1({
    required this.version,
    required this.fenceEpoch,
    required this.sessionGeneration,
    required this.lockState,
    required this.updatedAtUtc,
    this.actorUserId,
  });

  final int version;
  final int fenceEpoch;
  final String? actorUserId;
  final int sessionGeneration;
  final ContainmentFenceLockState lockState;
  final DateTime updatedAtUtc;

  static ContainmentFenceV1? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final version = decoded['version'];
      final fenceEpoch = decoded['fenceEpoch'];
      final actorUserId = decoded['actorUserId'];
      final sessionGeneration = decoded['sessionGeneration'];
      final lockStateRaw = decoded['lockState'];
      final updatedAtRaw = decoded['updatedAtUtc'];

      if (version != 1 ||
          fenceEpoch is! int ||
          fenceEpoch < 0 ||
          sessionGeneration is! int ||
          sessionGeneration < 0 ||
          lockStateRaw is! String ||
          updatedAtRaw is! String) {
        return null;
      }
      if (actorUserId != null && actorUserId is! String) {
        return null;
      }
      final lockState = ContainmentFenceLockState.tryFromWire(lockStateRaw);
      final updatedAtUtc = DateTime.tryParse(updatedAtRaw)?.toUtc();
      if (lockState == null || updatedAtUtc == null) {
        return null;
      }
      return ContainmentFenceV1(
        version: version as int,
        fenceEpoch: fenceEpoch,
        actorUserId: actorUserId as String?,
        sessionGeneration: sessionGeneration,
        lockState: lockState,
        updatedAtUtc: updatedAtUtc,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'fenceEpoch': fenceEpoch,
    'actorUserId': actorUserId,
    'sessionGeneration': sessionGeneration,
    'lockState': lockState.wireValue,
    'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
  };

  String toJsonString() => jsonEncode(toJson());
}

/// Ownership classification recorded in `containment_recovery_lock_v1`.
enum ContainmentRecoveryOwnershipLevel {
  boundV2('bound_v2'),
  corroboratedLegacy('corroborated_legacy'),
  unresolvable('unresolvable');

  const ContainmentRecoveryOwnershipLevel(this.wireValue);
  final String wireValue;

  static ContainmentRecoveryOwnershipLevel? tryFromWire(String? raw) {
    for (final value in ContainmentRecoveryOwnershipLevel.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Persisted `containment_recovery_lock_v1` payload (`D1.6`, `R38-08`, `R38-09`).
final class ContainmentRecoveryLockV1 {
  const ContainmentRecoveryLockV1({
    required this.version,
    required this.reason,
    required this.ownershipLevel,
    required this.initiatedFromSessionGeneration,
    required this.initiatedAtUtc,
    this.requiredOwnerFamilyId,
    this.unverifiedLegacyHintFamilyId,
    this.originActorUserId,
  });

  final int version;
  final String reason;
  final ContainmentRecoveryOwnershipLevel ownershipLevel;
  final String? requiredOwnerFamilyId;
  final String? unverifiedLegacyHintFamilyId;
  final String? originActorUserId;
  final int initiatedFromSessionGeneration;
  final DateTime initiatedAtUtc;

  static ContainmentRecoveryLockV1? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final version = decoded['version'];
      final reason = decoded['reason'];
      final ownershipRaw = decoded['ownershipLevel'];
      final requiredOwnerFamilyId = decoded['requiredOwnerFamilyId'];
      final unverifiedLegacyHintFamilyId =
          decoded['unverifiedLegacyHintFamilyId'];
      final originActorUserId = decoded['originActorUserId'];
      final sessionGen = decoded['initiatedFromSessionGeneration'];
      final initiatedAtRaw = decoded['initiatedAtUtc'];

      if (version != 1 ||
          reason is! String ||
          reason.isEmpty ||
          ownershipRaw is! String ||
          sessionGen is! int ||
          sessionGen < 0 ||
          initiatedAtRaw is! String) {
        return null;
      }
      final ownershipLevel = ContainmentRecoveryOwnershipLevel.tryFromWire(
        ownershipRaw,
      );
      final initiatedAtUtc = DateTime.tryParse(initiatedAtRaw)?.toUtc();
      if (ownershipLevel == null || initiatedAtUtc == null) {
        return null;
      }
      return ContainmentRecoveryLockV1(
        version: version as int,
        reason: reason,
        ownershipLevel: ownershipLevel,
        requiredOwnerFamilyId: requiredOwnerFamilyId as String?,
        unverifiedLegacyHintFamilyId: unverifiedLegacyHintFamilyId as String?,
        originActorUserId: originActorUserId as String?,
        initiatedFromSessionGeneration: sessionGen,
        initiatedAtUtc: initiatedAtUtc,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'reason': reason,
    'ownershipLevel': ownershipLevel.wireValue,
    'requiredOwnerFamilyId': requiredOwnerFamilyId,
    'unverifiedLegacyHintFamilyId': unverifiedLegacyHintFamilyId,
    'originActorUserId': originActorUserId,
    'initiatedFromSessionGeneration': initiatedFromSessionGeneration,
    'initiatedAtUtc': initiatedAtUtc.toUtc().toIso8601String(),
  };

  String toJsonString() => jsonEncode(toJson());
}

/// Redacted persisted audit marker written on explicit manual unbound recovery (`D1.6`).
final class LastContainmentRecoveryAuditV1 {
  const LastContainmentRecoveryAuditV1({
    required this.version,
    required this.reason,
    required this.targetFamilyId,
    required this.actorUserId,
    required this.recoveredAtUtc,
  });

  static const String manualUnboundLegacyRecoveryReason =
      'manual_unbound_legacy_recovery';

  final int version;
  final String reason;
  final String targetFamilyId;
  final String actorUserId;
  final DateTime recoveredAtUtc;

  static LastContainmentRecoveryAuditV1? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final version = decoded['version'];
      final reason = decoded['reason'];
      final targetFamilyId = decoded['targetFamilyId'];
      final actorUserId = decoded['actorUserId'];
      final recoveredAtRaw = decoded['recoveredAtUtc'];
      if (version != 1 ||
          reason is! String ||
          reason.isEmpty ||
          targetFamilyId is! String ||
          targetFamilyId.trim().isEmpty ||
          actorUserId is! String ||
          actorUserId.trim().isEmpty ||
          recoveredAtRaw is! String) {
        return null;
      }
      final recoveredAtUtc = DateTime.tryParse(recoveredAtRaw)?.toUtc();
      if (recoveredAtUtc == null) {
        return null;
      }
      return LastContainmentRecoveryAuditV1(
        version: version as int,
        reason: reason,
        targetFamilyId: targetFamilyId,
        actorUserId: actorUserId,
        recoveredAtUtc: recoveredAtUtc,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'reason': reason,
    'targetFamilyId': targetFamilyId,
    'actorUserId': actorUserId,
    'recoveredAtUtc': recoveredAtUtc.toUtc().toIso8601String(),
  };

  String toJsonString() => jsonEncode(toJson());
}

/// Fenced operation snapshot captured when starting an authorized Parent Gate operation (`R38-05`, `R38-07`).
final class ParentGateOperationFence {
  const ParentGateOperationFence({
    required this.actorUserId,
    required this.sessionGeneration,
    required this.containmentEpoch,
    required this.expectedContainmentStatus,
    this.verifiedFamilyId,
    this.expectedChildId,
    this.expectedChildSessionRaw,
    this.expectedContainmentFenceRaw,
    this.expectedCredentialRevision,
  });

  final String actorUserId;
  final int sessionGeneration;
  final int containmentEpoch;
  final String expectedContainmentStatus;
  final String? verifiedFamilyId;
  final String? expectedChildId;
  final String? expectedChildSessionRaw;
  final String? expectedContainmentFenceRaw;
  final int? expectedCredentialRevision;

  /// Checks whether this fence still matches a live [other] snapshot.
  bool matchesLiveSnapshot(ParentGateOperationFence other) {
    return actorUserId == other.actorUserId &&
        sessionGeneration == other.sessionGeneration &&
        containmentEpoch == other.containmentEpoch &&
        expectedContainmentStatus == other.expectedContainmentStatus &&
        verifiedFamilyId == other.verifiedFamilyId &&
        expectedChildId == other.expectedChildId;
  }
}

/// Structural status of persisted Parent PIN credentials.
enum ParentGateCredentialStatus { missing, validV2, legacyV1, corrupt }

/// Outcome of a verification attempt returned by [ParentGateService].
enum PinVerificationOutcome {
  /// Cryptographic PIN matched AND positive adult/actor/family/fence authorization succeeded.
  verified,

  /// Cryptographic PIN matched, but adult/actor/family/session fence authorization was absent (`R39-05`).
  pinMatchedAuthorizationRequired,
  incorrectPin,
  lockedOut,
  credentialMissing,
  corruptCredential,
  invalidFormat,
  wrongFamilyOwner,
  staleFence,
  staleCredentialRevision,
  concurrencyRetryExhausted,
}

/// Structured result of [ParentGateService.verifyPinDetailed] and staged completion.
final class PinVerificationResult {
  const PinVerificationResult({
    required this.outcome,
    required this.failedAttempts,
    this.attemptId,
    this.remainingLockout = Duration.zero,
    this.remainingAttemptsBeforeLockout,
    this.upgradedFromV1 = false,
    this.message,
  });

  final PinVerificationOutcome outcome;
  final int failedAttempts;
  final String? attemptId;
  final Duration remainingLockout;
  final int? remainingAttemptsBeforeLockout;
  final bool upgradedFromV1;
  final String? message;

  /// True ONLY when cryptographic match AND full adult/session fence authorization succeeded.
  bool get isVerified => outcome == PinVerificationOutcome.verified;

  /// Explicit alias separating Parent Mode exit authorization from pure PIN matching (`R39-05`).
  bool get isAuthorizedToExitChildMode =>
      outcome == PinVerificationOutcome.verified;

  /// Whether the PIN digest matched cryptographically (even if Parent Mode exit authorization was denied).
  bool get isPinCryptographicallyMatched =>
      outcome == PinVerificationOutcome.verified ||
      outcome == PinVerificationOutcome.pinMatchedAuthorizationRequired;

  bool get isLockedOut => outcome == PinVerificationOutcome.lockedOut;
}

/// Handle returned by [ParentGateService.beginStagedVerification] before/after KDF.
final class StagedPinVerificationAttempt {
  const StagedPinVerificationAttempt({
    required this.attemptId,
    required this.pinMatched,
    required this.hasAuthorizedExitContext,
    required this.credentialStatus,
    required this.reservedCredentialRevision,
    required this.reservedLockoutRevision,
    required this.reservedLockoutRaw,
    this.upgradedV2Credential,
    this.legacyV1HashRaw,
    this.legacyV1SaltRaw,
    this.fence,
  });

  final String attemptId;
  final bool pinMatched;
  final bool hasAuthorizedExitContext;
  final ParentGateCredentialStatus credentialStatus;
  final int reservedCredentialRevision;
  final int reservedLockoutRevision;
  final String reservedLockoutRaw;
  final ParentGateCredentialV2? upgradedV2Credential;
  final String? legacyV1HashRaw;
  final String? legacyV1SaltRaw;
  final ParentGateOperationFence? fence;
}

/// Result of attempting to begin a staged PIN verification.
final class StagedPinReservationResult {
  const StagedPinReservationResult.reserved(this.attempt)
    : immediateFailure = null;

  const StagedPinReservationResult.rejected(this.immediateFailure)
    : attempt = null;

  final StagedPinVerificationAttempt? attempt;
  final PinVerificationResult? immediateFailure;

  bool get isReserved => attempt != null;
}

/// Well-formed legacy `(familyId, childId)` hint parsed strictly from `active_child_session`.
final class LegacyChildHint {
  const LegacyChildHint({required this.familyId, required this.childId});

  final String familyId;
  final String childId;

  /// Strictly extracts `{family_id, id}` from JSON, returning `null` if missing or malformed.
  static LegacyChildHint? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final familyId = decoded['family_id'];
      final childId = decoded['id'];
      if (familyId is! String ||
          familyId.trim().isEmpty ||
          childId is! String ||
          childId.trim().isEmpty) {
        return null;
      }
      return LegacyChildHint(
        familyId: familyId.trim(),
        childId: childId.trim(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 3-level legacy Child Mode / PIN ownership resolution result (`D1.6`, `R38-10`).
sealed class LegacyOwnershipResolution {
  const LegacyOwnershipResolution({required this.ownershipLevel});

  final ContainmentRecoveryOwnershipLevel ownershipLevel;

  /// Whether Exit Path B post-sign-out adult verification may auto-clear this lock
  /// for [verifiedFamilyId].
  bool allowsExitPathBAutoUnlockForFamily(String verifiedFamilyId);
}

/// Explicit v2 credential ownership (`ownerFamilyId != null`).
final class BoundOwnerResolution extends LegacyOwnershipResolution {
  const BoundOwnerResolution({
    required this.ownerFamilyId,
    this.legacyChildHint,
  }) : super(ownershipLevel: ContainmentRecoveryOwnershipLevel.boundV2);

  final String ownerFamilyId;
  final LegacyChildHint? legacyChildHint;

  @override
  bool allowsExitPathBAutoUnlockForFamily(String verifiedFamilyId) =>
      ownerFamilyId == verifiedFamilyId;
}

/// Strict 4-conjunct corroborated legacy ownership (`R38-10`).
final class CorroboratedLegacyOwnerResolution
    extends LegacyOwnershipResolution {
  const CorroboratedLegacyOwnerResolution({
    required this.familyId,
    required this.childId,
    required this.corroboratingRecords,
  }) : super(
         ownershipLevel: ContainmentRecoveryOwnershipLevel.corroboratedLegacy,
       );

  final String familyId;
  final String childId;
  final List<ActorBoundOutboxRecord> corroboratingRecords;

  @override
  bool allowsExitPathBAutoUnlockForFamily(String verifiedFamilyId) =>
      familyId == verifiedFamilyId;
}

/// Unresolvable ownership requiring PIN + positive adult check (if v1) or
/// Restricted Manual Unbound Recovery (`D1.6`).
final class UnresolvableLegacyOwnershipResolution
    extends LegacyOwnershipResolution {
  const UnresolvableLegacyOwnershipResolution({
    required this.reason,
    this.legacyChildHint,
  }) : super(ownershipLevel: ContainmentRecoveryOwnershipLevel.unresolvable);

  final String reason;
  final LegacyChildHint? legacyChildHint;

  @override
  bool allowsExitPathBAutoUnlockForFamily(String verifiedFamilyId) => false;
}

/// Thrown when `setPin` is called while a valid Parent PIN already exists (`R39-03`).
final class ParentGatePinAlreadyConfiguredException implements Exception {
  ParentGatePinAlreadyConfiguredException(this.message);
  final String message;

  @override
  String toString() => 'ParentGatePinAlreadyConfiguredException: $message';
}

/// Thrown when `setPin` would overwrite an existing v2 credential owned by a different family (`C0-27`).
final class ParentGateOwnershipConflictException implements Exception {
  ParentGateOwnershipConflictException(this.message);
  final String message;

  @override
  String toString() => 'ParentGateOwnershipConflictException: $message';
}

/// Thrown when persisted credential metadata is corrupted and silent overwrite is forbidden.
final class ParentGatePinCorruptException implements Exception {
  ParentGatePinCorruptException(this.message);
  final String message;

  @override
  String toString() => 'ParentGatePinCorruptException: $message';
}

/// Thrown when an operation fails a fenced pre-commit/CAS check or adult authorization guard.
final class ParentGateFencedOperationException implements Exception {
  ParentGateFencedOperationException(this.message);
  final String message;

  @override
  String toString() => 'ParentGateFencedOperationException: $message';
}
