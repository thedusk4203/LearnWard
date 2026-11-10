// ignore_for_file: prefer_initializing_formals

import 'package:learnward_application/learnward_application.dart';

/// In-memory fake implementation of [RecoveryAuthorizationPort] for deterministic tests.
final class FakeRecoveryAuthorizationPort implements RecoveryAuthorizationPort {
  FakeRecoveryAuthorizationPort({
    TargetAuthorizationStatus defaultStatus =
        TargetAuthorizationStatus.authorized,
    VerifiedAdultRole defaultAdultRole = VerifiedAdultRole.parent,
    AdultTargetAuthorizationResult? defaultAdultResult,
  }) : _defaultStatus = defaultStatus,
       _defaultAdultRole = defaultAdultRole,
       _defaultAdultResult = defaultAdultResult;

  TargetAuthorizationStatus _defaultStatus;
  VerifiedAdultRole _defaultAdultRole;
  AdultTargetAuthorizationResult? _defaultAdultResult;
  final Map<String, TargetAuthorizationStatus> _overrides = {};
  final Map<String, AdultTargetAuthorizationResult> _adultOverrides = {};
  final List<String> callLog = [];

  void setDefaultStatus(TargetAuthorizationStatus status) {
    _defaultStatus = status;
  }

  void setDefaultAdultRole(VerifiedAdultRole role) {
    _defaultAdultRole = role;
    _defaultAdultResult = null;
  }

  void setDefaultAdultResult(AdultTargetAuthorizationResult? result) {
    _defaultAdultResult = result;
  }

  void setTargetStatus({
    required String familyId,
    required String childId,
    required TargetAuthorizationStatus status,
  }) {
    _overrides['$familyId:$childId'] = status;
  }

  void setAdultTargetResult({
    required String familyId,
    required String redemptionId,
    required AdultTargetAuthorizationResult result,
  }) {
    _adultOverrides['$familyId:$redemptionId'] = result;
  }

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) async {
    callLog.add('verifyTarget:$familyId:$childId:$operation');
    final key = '$familyId:$childId';
    return _overrides[key] ?? _defaultStatus;
  }

  @override
  Future<AdultTargetAuthorizationResult> verifyAdultRedemptionTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required String redemptionId,
    required RewardCommandOperation operation,
  }) async {
    callLog.add(
      'verifyAdultRedemptionTarget:$familyId:$childId:$redemptionId:$operation',
    );
    final key = '$familyId:$redemptionId';
    if (_adultOverrides.containsKey(key)) {
      return _adultOverrides[key]!;
    }
    if (_defaultAdultResult != null) {
      return _defaultAdultResult!;
    }
    if (context.role == 'child') {
      return const AdultTargetAuthorizationResult.definitelyDenied(
        reason: AdultTargetVerificationReason.pairedChildSessionDenied,
      );
    }
    if (_defaultStatus == TargetAuthorizationStatus.authorized) {
      return AdultTargetAuthorizationResult.authorized(
        verifiedRole: _defaultAdultRole,
      );
    }
    if (_defaultStatus == TargetAuthorizationStatus.definitelyDenied) {
      return const AdultTargetAuthorizationResult.definitelyDenied(
        reason: AdultTargetVerificationReason.adultMembershipRevokedOrNonAdult,
      );
    }
    if (_defaultStatus == TargetAuthorizationStatus.confirmedRevoked) {
      return const AdultTargetAuthorizationResult.confirmedRevoked();
    }
    return const AdultTargetAuthorizationResult.unverified(
      reason: AdultTargetVerificationReason.rlsFilteredOrMissingTargetRow,
    );
  }
}
