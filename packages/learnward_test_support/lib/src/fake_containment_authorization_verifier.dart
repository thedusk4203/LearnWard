import 'dart:async';

import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_domain/learnward_domain.dart';

/// Recorded invocation passed to [FakeContainmentAuthorizationVerifier].
final class ContainmentVerificationCall {
  const ContainmentVerificationCall({
    required this.context,
    this.persistedChildSession,
    this.preferredFamilyId,
    this.targetChildId,
    this.targetFamilyId,
  });

  final ValidatedActorContext context;
  final PersistedChildModeSession? persistedChildSession;
  final FamilyId? preferredFamilyId;
  final ChildId? targetChildId;
  final FamilyId? targetFamilyId;
}

/// Deterministic in-memory fake for [ContainmentAuthorizationVerifier].
final class FakeContainmentAuthorizationVerifier
    implements ContainmentAuthorizationVerifier {
  FakeContainmentAuthorizationVerifier({
    this.defaultOutcome = const SessionAuthorizationUnverified(
      reason: 'fake_verifier_unconfigured',
    ),
    this.onVerify,
    this.barrier,
  });

  ContainmentVerificationOutcome defaultOutcome;
  Future<ContainmentVerificationOutcome> Function(
    ContainmentVerificationCall call,
  )?
  onVerify;
  Completer<void>? barrier;
  final List<ContainmentVerificationCall> calls = [];

  @override
  Future<ContainmentVerificationOutcome> verifySession({
    required ValidatedActorContext context,
    PersistedChildModeSession? persistedChildSession,
    FamilyId? preferredFamilyId,
    ChildId? targetChildId,
    FamilyId? targetFamilyId,
  }) async {
    final call = ContainmentVerificationCall(
      context: context,
      persistedChildSession: persistedChildSession,
      preferredFamilyId: preferredFamilyId,
      targetChildId: targetChildId,
      targetFamilyId: targetFamilyId,
    );
    calls.add(call);
    if (barrier != null) {
      await barrier!.future;
    }
    if (onVerify != null) {
      return onVerify!(call);
    }
    return defaultOutcome;
  }
}
