// ignore_for_file: prefer_initializing_formals

import 'package:learnward_application/learnward_application.dart';

/// In-memory fake implementation of [RecoveryAuthorizationPort] for deterministic tests.
final class FakeRecoveryAuthorizationPort implements RecoveryAuthorizationPort {
  FakeRecoveryAuthorizationPort({
    TargetAuthorizationStatus defaultStatus =
        TargetAuthorizationStatus.authorized,
  }) : _defaultStatus = defaultStatus;

  TargetAuthorizationStatus _defaultStatus;
  final Map<String, TargetAuthorizationStatus> _overrides = {};

  void setDefaultStatus(TargetAuthorizationStatus status) {
    _defaultStatus = status;
  }

  void setTargetStatus({
    required String familyId,
    required String childId,
    required TargetAuthorizationStatus status,
  }) {
    _overrides['$familyId:$childId'] = status;
  }

  @override
  Future<TargetAuthorizationStatus> verifyTarget({
    required ValidatedActorContext context,
    required String familyId,
    required String childId,
    required RewardCommandOperation operation,
  }) async {
    final key = '$familyId:$childId';
    return _overrides[key] ?? _defaultStatus;
  }
}
