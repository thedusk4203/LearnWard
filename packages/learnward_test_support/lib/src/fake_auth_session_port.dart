// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:learnward_application/learnward_application.dart';

/// In-memory fake implementation of [AuthSessionPort] for deterministic tests.
final class FakeAuthSessionPort implements AuthSessionPort {
  FakeAuthSessionPort({
    ValidatedActorContext? initialContext,
    String? activeUserId,
    String? sessionGeneration,
    Clock clock = const SystemClock(),
    String? role,
  }) : _currentContext =
           initialContext ??
           (activeUserId != null
               ? ValidatedActorContext(
                   userId: activeUserId,
                   sessionGeneration: sessionGeneration ?? 'gen-$activeUserId',
                   observedAt: clock.now().toUtc(),
                   role: role,
                 )
               : null) {
    _sessionGeneration = _currentContext?.sessionGeneration;
  }

  ValidatedActorContext? _currentContext;
  String? _sessionGeneration;
  final _controller = StreamController<String?>.broadcast();

  ValidatedActorContext? get currentContext => _currentContext;

  void setContext(ValidatedActorContext? context) {
    _currentContext = context;
    _sessionGeneration = context?.sessionGeneration;
    _controller.add(_sessionGeneration);
  }

  void invalidateSession() {
    _currentContext = null;
    _sessionGeneration = null;
    _controller.add(null);
  }

  void signOut() => invalidateSession();

  void setSession({
    required String userId,
    String? role,
    String? sessionGeneration,
  }) {
    setContext(
      ValidatedActorContext(
        userId: userId,
        sessionGeneration: sessionGeneration ?? 'gen-$userId',
        observedAt: DateTime.now().toUtc(),
        role: role,
      ),
    );
  }

  void setSessionGeneration(String gen) {
    _sessionGeneration = gen;
    if (_currentContext != null) {
      _currentContext = ValidatedActorContext(
        userId: _currentContext!.userId,
        sessionGeneration: gen,
        observedAt: _currentContext!.observedAt,
        role: _currentContext!.role,
      );
    }
    _controller.add(gen);
  }

  void emitStreamError(Object error) {
    _controller.addError(error);
  }

  void switchActor(String userId, {String? role}) {
    final nextGen = 'gen-${DateTime.now().microsecondsSinceEpoch}';
    final context = ValidatedActorContext(
      userId: userId,
      sessionGeneration: nextGen,
      observedAt: DateTime.now().toUtc(),
      role: role,
    );
    setContext(context);
  }

  @override
  String? get currentSessionGeneration => _sessionGeneration;

  @override
  Stream<String?> get sessionGenerationStream => _controller.stream;

  @override
  Future<ValidatedActorContext?> validateForMutation() async {
    return _currentContext;
  }

  void dispose() {
    _controller.close();
  }
}
