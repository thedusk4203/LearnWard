import 'dart:convert';

import 'package:learnward_domain/learnward_domain.dart';

/// Supported shared-device / paired-device modes in `active_child_session` v2.
enum PersistedChildModeKind {
  sharedDeviceAdult('shared_device_adult'),
  pairedChildDevice('paired_child_device');

  const PersistedChildModeKind(this.wireValue);
  final String wireValue;

  static PersistedChildModeKind? tryFromWire(String? raw) {
    for (final kind in PersistedChildModeKind.values) {
      if (kind.wireValue == raw) {
        return kind;
      }
    }
    return null;
  }
}

/// Structural classification of persisted `active_child_session` storage data.
enum PersistedChildModeParseStatus { absent, validV2, legacyV1OrMalformed }

/// Actor-, family-, and child-bound `active_child_session` v2 envelope.
final class PersistedChildModeSession {
  PersistedChildModeSession({
    required this.modeKind,
    required this.actorUserId,
    required this.familyId,
    required this.childId,
    required this.childProfileSnapshot,
    required this.persistedAtUtc,
    this.version = currentVersion,
  }) {
    if (version != currentVersion) {
      throw ArgumentError.value(
        version,
        'version',
        'PersistedChildModeSession requires version $currentVersion.',
      );
    }
    if (actorUserId.trim().isEmpty) {
      throw ArgumentError.value(
        actorUserId,
        'actorUserId',
        'actorUserId must not be empty.',
      );
    }
    if (childProfileSnapshot.id != childId) {
      throw ArgumentError(
        'childProfileSnapshot.id (${childProfileSnapshot.id.value}) must match '
        'childId (${childId.value}).',
      );
    }
    if (childProfileSnapshot.familyId != familyId) {
      throw ArgumentError(
        'childProfileSnapshot.familyId (${childProfileSnapshot.familyId.value}) '
        'must match familyId (${familyId.value}).',
      );
    }
    if (!childProfileSnapshot.isActive || childProfileSnapshot.isArchived) {
      throw ArgumentError(
        'childProfileSnapshot must represent an active non-archived child.',
      );
    }
  }

  static const int currentVersion = 2;

  final int version;
  final PersistedChildModeKind modeKind;
  final String actorUserId;
  final FamilyId familyId;
  final ChildId childId;
  final ChildProfile childProfileSnapshot;
  final DateTime persistedAtUtc;

  /// Strictly parses persisted `active_child_session` storage JSON without ever
  /// adopting legacy v1 or malformed payloads as active Child Mode.
  static PersistedChildModeParseResult tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const AbsentPersistedChildModeSession();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return LegacyV1OrMalformedChildModeSession(
          rawValue: raw,
          isWellFormedLegacyV1: false,
          reason: 'invalid_json_envelope',
        );
      }

      if (decoded['version'] == currentVersion) {
        final modeKindRaw = decoded['modeKind'];
        final actorUserIdRaw = decoded['actorUserId'];
        final familyIdRaw = decoded['familyId'];
        final childIdRaw = decoded['childId'];
        final persistedAtRaw = decoded['persistedAtUtc'];
        final snapshotRaw = decoded['childProfileSnapshot'];

        final modeKind = modeKindRaw is String
            ? PersistedChildModeKind.tryFromWire(modeKindRaw)
            : null;
        if (modeKind == null ||
            actorUserIdRaw is! String ||
            actorUserIdRaw.trim().isEmpty ||
            familyIdRaw is! String ||
            familyIdRaw.trim().isEmpty ||
            childIdRaw is! String ||
            childIdRaw.trim().isEmpty ||
            persistedAtRaw is! String ||
            snapshotRaw is! Map<String, dynamic>) {
          return LegacyV1OrMalformedChildModeSession(
            rawValue: raw,
            isWellFormedLegacyV1: false,
            reason: 'malformed_v2_session',
          );
        }

        final persistedAtUtc = DateTime.tryParse(persistedAtRaw)?.toUtc();
        if (persistedAtUtc == null) {
          return LegacyV1OrMalformedChildModeSession(
            rawValue: raw,
            isWellFormedLegacyV1: false,
            reason: 'malformed_v2_session',
          );
        }

        final snapshotIdRaw = snapshotRaw['id'];
        final snapshotFamilyIdRaw = snapshotRaw['family_id'];
        final snapshotDisplayNameRaw = snapshotRaw['display_name'];
        final snapshotGradeRaw = snapshotRaw['school_grade'];
        final snapshotBirthYearRaw = snapshotRaw['birth_year'];
        final snapshotAvatarRaw =
            snapshotRaw['avatar_key'] ?? snapshotRaw['avatarKey'];
        final snapshotStatusRaw = snapshotRaw['status'];
        final snapshotCreatedAtRaw = snapshotRaw['created_at'];
        final snapshotArchivedAtRaw = snapshotRaw['archived_at'];

        if (snapshotIdRaw is! String ||
            snapshotFamilyIdRaw is! String ||
            snapshotIdRaw.trim() != childIdRaw.trim() ||
            snapshotFamilyIdRaw.trim() != familyIdRaw.trim() ||
            snapshotDisplayNameRaw is! String ||
            snapshotStatusRaw is! String ||
            snapshotCreatedAtRaw is! String ||
            snapshotArchivedAtRaw != null) {
          return LegacyV1OrMalformedChildModeSession(
            rawValue: raw,
            isWellFormedLegacyV1: false,
            reason: 'malformed_v2_session',
          );
        }
        if (snapshotGradeRaw != null && snapshotGradeRaw is! int) {
          return LegacyV1OrMalformedChildModeSession(
            rawValue: raw,
            isWellFormedLegacyV1: false,
            reason: 'malformed_v2_session',
          );
        }
        if (snapshotBirthYearRaw != null && snapshotBirthYearRaw is! int) {
          return LegacyV1OrMalformedChildModeSession(
            rawValue: raw,
            isWellFormedLegacyV1: false,
            reason: 'malformed_v2_session',
          );
        }
        if (snapshotAvatarRaw != null && snapshotAvatarRaw is! String) {
          return LegacyV1OrMalformedChildModeSession(
            rawValue: raw,
            isWellFormedLegacyV1: false,
            reason: 'malformed_v2_session',
          );
        }

        final status = ChildProfileStatus.parse(snapshotStatusRaw);
        final createdAtUtc = DateTime.tryParse(snapshotCreatedAtRaw)?.toUtc();
        if (status != ChildProfileStatus.active || createdAtUtc == null) {
          return LegacyV1OrMalformedChildModeSession(
            rawValue: raw,
            isWellFormedLegacyV1: false,
            reason: 'malformed_v2_session',
          );
        }

        final familyId = FamilyId(familyIdRaw.trim());
        final childId = ChildId(childIdRaw.trim());
        final snapshot = ChildProfile(
          id: childId,
          familyId: familyId,
          displayName: snapshotDisplayNameRaw,
          schoolGrade: snapshotGradeRaw as int?,
          birthYear: snapshotBirthYearRaw as int?,
          avatarKey: snapshotAvatarRaw as String?,
          status: status,
          createdAt: createdAtUtc,
        );

        final session = PersistedChildModeSession(
          modeKind: modeKind,
          actorUserId: actorUserIdRaw.trim(),
          familyId: familyId,
          childId: childId,
          childProfileSnapshot: snapshot,
          persistedAtUtc: persistedAtUtc,
        );
        return ValidPersistedChildModeSessionV2(session: session, rawJson: raw);
      }

      if (decoded['version'] == null) {
        final rawId = decoded['id'];
        final rawFamilyId = decoded['family_id'];
        if (rawId is String &&
            rawId.trim().isNotEmpty &&
            rawFamilyId is String &&
            rawFamilyId.trim().isNotEmpty) {
          return LegacyV1OrMalformedChildModeSession(
            rawValue: raw,
            isWellFormedLegacyV1: true,
            reason: 'legacy_v1_unbound_session',
            unverifiedLegacyHintFamilyId: rawFamilyId.trim(),
            unverifiedLegacyHintChildId: rawId.trim(),
          );
        }
      }

      return LegacyV1OrMalformedChildModeSession(
        rawValue: raw,
        isWellFormedLegacyV1: false,
        reason: 'malformed_session',
      );
    } catch (_) {
      return LegacyV1OrMalformedChildModeSession(
        rawValue: raw,
        isWellFormedLegacyV1: false,
        reason: 'invalid_json_envelope',
      );
    }
  }

  /// Alias for storage-level strict classification.
  static PersistedChildModeParseResult parseStorageValue(String? raw) =>
      tryParse(raw);

  Map<String, dynamic> toJson() => {
    'version': version,
    'modeKind': modeKind.wireValue,
    'actorUserId': actorUserId,
    'familyId': familyId.value,
    'childId': childId.value,
    'persistedAtUtc': persistedAtUtc.toUtc().toIso8601String(),
    'childProfileSnapshot': {
      'id': childProfileSnapshot.id.value,
      'family_id': childProfileSnapshot.familyId.value,
      'display_name': childProfileSnapshot.displayName,
      'school_grade': childProfileSnapshot.schoolGrade,
      'birth_year': childProfileSnapshot.birthYear,
      'avatar_key': childProfileSnapshot.avatarKey,
      'status': childProfileSnapshot.status.wireName,
      'created_at': childProfileSnapshot.createdAt.toUtc().toIso8601String(),
      'archived_at': childProfileSnapshot.archivedAt?.toUtc().toIso8601String(),
    },
  };

  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PersistedChildModeSession &&
          runtimeType == other.runtimeType &&
          version == other.version &&
          modeKind == other.modeKind &&
          actorUserId == other.actorUserId &&
          familyId == other.familyId &&
          childId == other.childId &&
          childProfileSnapshot == other.childProfileSnapshot &&
          persistedAtUtc == other.persistedAtUtc;

  @override
  int get hashCode => Object.hash(
    version,
    modeKind,
    actorUserId,
    familyId,
    childId,
    childProfileSnapshot,
    persistedAtUtc,
  );

  @override
  String toString() =>
      'PersistedChildModeSession(version: $version, modeKind: ${modeKind.wireValue}, '
      'actorUserId: $actorUserId, familyId: ${familyId.value}, childId: ${childId.value}, '
      'persistedAtUtc: ${persistedAtUtc.toUtc().toIso8601String()})';
}

/// Sealed result of parsing `local_metadata_entries['active_child_session']`.
sealed class PersistedChildModeParseResult {
  const PersistedChildModeParseResult();

  PersistedChildModeParseStatus get status;
}

/// Persisted `active_child_session` key is absent or empty.
final class AbsentPersistedChildModeSession
    extends PersistedChildModeParseResult {
  const AbsentPersistedChildModeSession();

  @override
  PersistedChildModeParseStatus get status =>
      PersistedChildModeParseStatus.absent;

  @override
  String toString() => 'AbsentPersistedChildModeSession()';
}

/// Persisted `active_child_session` v2 passed strict structural validation.
final class ValidPersistedChildModeSessionV2
    extends PersistedChildModeParseResult {
  const ValidPersistedChildModeSessionV2({
    required this.session,
    required this.rawJson,
  });

  final PersistedChildModeSession session;
  final String rawJson;

  @override
  PersistedChildModeParseStatus get status =>
      PersistedChildModeParseStatus.validV2;

  @override
  String toString() => 'ValidPersistedChildModeSessionV2($session)';
}

/// Persisted `active_child_session` is legacy v1 or malformed/corrupted JSON.
///
/// Must NEVER be silently adopted as active Child Mode or auto-cleared to ParentMode.
final class LegacyV1OrMalformedChildModeSession
    extends PersistedChildModeParseResult {
  const LegacyV1OrMalformedChildModeSession({
    required this.rawValue,
    required this.isWellFormedLegacyV1,
    required this.reason,
    this.unverifiedLegacyHintFamilyId,
    this.unverifiedLegacyHintChildId,
  });

  final String rawValue;
  final bool isWellFormedLegacyV1;
  final String reason;
  final String? unverifiedLegacyHintFamilyId;
  final String? unverifiedLegacyHintChildId;

  @override
  PersistedChildModeParseStatus get status =>
      PersistedChildModeParseStatus.legacyV1OrMalformed;

  @override
  String toString() =>
      'LegacyV1OrMalformedChildModeSession(isWellFormedLegacyV1: '
      '$isWellFormedLegacyV1, reason: $reason)';
}

/// Canonical reasons recorded in `containment_recovery_lock_v1` (`D4.2`).
enum ContainmentRecoveryReason {
  childArchived('child_archived'),
  legacyOrMalformedSession('legacy_or_malformed_session'),
  corruptPin('corrupt_pin'),
  forgottenPin('forgotten_pin'),
  actorMismatch('actor_mismatch'),
  adultMembershipAbsentOrRevoked('adult_membership_absent_or_revoked');

  const ContainmentRecoveryReason(this.wireValue);
  final String wireValue;

  static ContainmentRecoveryReason? tryFromWire(String? raw) {
    for (final value in ContainmentRecoveryReason.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
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

/// Persisted `containment_recovery_lock_v1` payload (`D1.6`, `D4.2`, `R38-08`, `R38-09`).
final class ContainmentRecoveryLockV1 {
  ContainmentRecoveryLockV1({
    required this.reason,
    required this.ownershipLevel,
    required this.initiatedFromSessionGeneration,
    required this.initiatedAtUtc,
    this.version = 1,
    this.requiredOwnerFamilyId,
    this.unverifiedLegacyHintFamilyId,
    this.originActorUserId,
  }) {
    if (version != 1) {
      throw ArgumentError.value(
        version,
        'version',
        'ContainmentRecoveryLockV1 requires version 1.',
      );
    }
    if (initiatedFromSessionGeneration.trim().isEmpty) {
      throw ArgumentError.value(
        initiatedFromSessionGeneration,
        'initiatedFromSessionGeneration',
        'initiatedFromSessionGeneration must not be empty.',
      );
    }
    if (ownershipLevel == ContainmentRecoveryOwnershipLevel.unresolvable &&
        requiredOwnerFamilyId != null) {
      throw ArgumentError(
        'Unresolvable containment_recovery_lock_v1 must have requiredOwnerFamilyId == null.',
      );
    }
    if (ownershipLevel != ContainmentRecoveryOwnershipLevel.unresolvable &&
        (requiredOwnerFamilyId == null ||
            requiredOwnerFamilyId!.trim().isEmpty)) {
      throw ArgumentError(
        'Bound or corroborated containment_recovery_lock_v1 requires non-empty requiredOwnerFamilyId.',
      );
    }
    if (unverifiedLegacyHintFamilyId != null &&
        unverifiedLegacyHintFamilyId!.trim().isEmpty) {
      throw ArgumentError(
        'unverifiedLegacyHintFamilyId must be null or non-empty.',
      );
    }
    if (originActorUserId != null && originActorUserId!.trim().isEmpty) {
      throw ArgumentError('originActorUserId must be null or non-empty.');
    }
  }

  final int version;
  final ContainmentRecoveryReason reason;
  final ContainmentRecoveryOwnershipLevel ownershipLevel;
  final String? requiredOwnerFamilyId;
  final String? unverifiedLegacyHintFamilyId;
  final String? originActorUserId;
  final String initiatedFromSessionGeneration;
  final DateTime initiatedAtUtc;

  /// Strictly parses raw storage JSON, returning `null` if absent or invalid.
  static ContainmentRecoveryLockV1? tryParse(String? raw) {
    return switch (parseStorageValue(raw)) {
      ValidContainmentRecoveryLockV1(:final lock) => lock,
      AbsentContainmentRecoveryLock() ||
      MalformedContainmentRecoveryLock() => null,
    };
  }

  /// Classifies raw `containment_recovery_lock_v1` storage values while keeping
  /// malformed recovery locks fail-closed as locked rather than absent.
  static ContainmentRecoveryLockParseResult parseStorageValue(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const AbsentContainmentRecoveryLock();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const MalformedContainmentRecoveryLock('invalid_json');
      }
      final version = decoded['version'];
      final reasonRaw = decoded['reason'];
      final ownershipRaw = decoded['ownershipLevel'];
      final requiredOwnerRaw = decoded['requiredOwnerFamilyId'];
      final hintFamilyRaw = decoded['unverifiedLegacyHintFamilyId'];
      final originActorRaw = decoded['originActorUserId'];
      final sessionGenRaw = decoded['initiatedFromSessionGeneration'];
      final initiatedAtRaw = decoded['initiatedAtUtc'];

      final reason = reasonRaw is String
          ? ContainmentRecoveryReason.tryFromWire(reasonRaw)
          : null;
      final ownershipLevel = ownershipRaw is String
          ? ContainmentRecoveryOwnershipLevel.tryFromWire(ownershipRaw)
          : null;

      if (version != 1 ||
          reason == null ||
          ownershipLevel == null ||
          sessionGenRaw is! String ||
          sessionGenRaw.trim().isEmpty ||
          initiatedAtRaw is! String) {
        return const MalformedContainmentRecoveryLock(
          'missing_or_invalid_required_fields',
        );
      }

      if (requiredOwnerRaw != null &&
          (requiredOwnerRaw is! String || requiredOwnerRaw.trim().isEmpty)) {
        return const MalformedContainmentRecoveryLock(
          'invalid_required_owner_family_id',
        );
      }
      if (hintFamilyRaw != null &&
          (hintFamilyRaw is! String || hintFamilyRaw.trim().isEmpty)) {
        return const MalformedContainmentRecoveryLock(
          'invalid_unverified_legacy_hint_family_id',
        );
      }
      if (originActorRaw != null &&
          (originActorRaw is! String || originActorRaw.trim().isEmpty)) {
        return const MalformedContainmentRecoveryLock(
          'invalid_origin_actor_user_id',
        );
      }

      final requiredOwnerFamilyId = (requiredOwnerRaw as String?)?.trim();
      if (ownershipLevel == ContainmentRecoveryOwnershipLevel.unresolvable &&
          requiredOwnerFamilyId != null) {
        return const MalformedContainmentRecoveryLock(
          'unresolvable_lock_cannot_require_owner_family',
        );
      }
      if (ownershipLevel != ContainmentRecoveryOwnershipLevel.unresolvable &&
          requiredOwnerFamilyId == null) {
        return const MalformedContainmentRecoveryLock(
          'resolved_lock_missing_required_owner_family',
        );
      }

      final initiatedAtUtc = DateTime.tryParse(initiatedAtRaw)?.toUtc();
      if (initiatedAtUtc == null) {
        return const MalformedContainmentRecoveryLock('invalid_timestamp');
      }

      final lock = ContainmentRecoveryLockV1(
        version: version as int,
        reason: reason,
        ownershipLevel: ownershipLevel,
        requiredOwnerFamilyId: requiredOwnerFamilyId,
        unverifiedLegacyHintFamilyId: (hintFamilyRaw as String?)?.trim(),
        originActorUserId: (originActorRaw as String?)?.trim(),
        initiatedFromSessionGeneration: sessionGenRaw.trim(),
        initiatedAtUtc: initiatedAtUtc,
      );
      return ValidContainmentRecoveryLockV1(lock: lock, rawJson: raw);
    } catch (_) {
      return const MalformedContainmentRecoveryLock('invalid_json');
    }
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'reason': reason.wireValue,
    'ownershipLevel': ownershipLevel.wireValue,
    'requiredOwnerFamilyId': requiredOwnerFamilyId,
    'unverifiedLegacyHintFamilyId': unverifiedLegacyHintFamilyId,
    'originActorUserId': originActorUserId,
    'initiatedFromSessionGeneration': initiatedFromSessionGeneration,
    'initiatedAtUtc': initiatedAtUtc.toUtc().toIso8601String(),
  };

  String toJsonString() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContainmentRecoveryLockV1 &&
          runtimeType == other.runtimeType &&
          version == other.version &&
          reason == other.reason &&
          ownershipLevel == other.ownershipLevel &&
          requiredOwnerFamilyId == other.requiredOwnerFamilyId &&
          unverifiedLegacyHintFamilyId == other.unverifiedLegacyHintFamilyId &&
          originActorUserId == other.originActorUserId &&
          initiatedFromSessionGeneration ==
              other.initiatedFromSessionGeneration &&
          initiatedAtUtc == other.initiatedAtUtc;

  @override
  int get hashCode => Object.hash(
    version,
    reason,
    ownershipLevel,
    requiredOwnerFamilyId,
    unverifiedLegacyHintFamilyId,
    originActorUserId,
    initiatedFromSessionGeneration,
    initiatedAtUtc,
  );

  @override
  String toString() =>
      'ContainmentRecoveryLockV1(version: $version, reason: ${reason.wireValue}, '
      'ownershipLevel: ${ownershipLevel.wireValue}, '
      'hasRequiredOwnerFamily: ${requiredOwnerFamilyId != null})';
}

/// Sealed parse result for `containment_recovery_lock_v1`.
sealed class ContainmentRecoveryLockParseResult {
  const ContainmentRecoveryLockParseResult();
}

final class AbsentContainmentRecoveryLock
    extends ContainmentRecoveryLockParseResult {
  const AbsentContainmentRecoveryLock();

  @override
  String toString() => 'AbsentContainmentRecoveryLock()';
}

final class ValidContainmentRecoveryLockV1
    extends ContainmentRecoveryLockParseResult {
  const ValidContainmentRecoveryLockV1({
    required this.lock,
    required this.rawJson,
  });

  final ContainmentRecoveryLockV1 lock;
  final String rawJson;

  @override
  String toString() => 'ValidContainmentRecoveryLockV1($lock)';
}

final class MalformedContainmentRecoveryLock
    extends ContainmentRecoveryLockParseResult {
  const MalformedContainmentRecoveryLock(this.reason);

  final String reason;

  @override
  String toString() => 'MalformedContainmentRecoveryLock(reason: $reason)';
}
