// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:learnward_application/learnward_application.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase-backed adapter for [AuthSessionPort].
///
/// Observes auth lifecycle and maintains an explicit session epoch/generation
/// that invalidates on sign out, user switch, or token expiration.
final class SupabaseAuthSessionAdapter implements AuthSessionPort {
  SupabaseAuthSessionAdapter(this._client, {Clock clock = const SystemClock()})
    : _clock = clock {
    _init();
  }

  final SupabaseClient _client;
  final Clock _clock;
  final _controller = StreamController<String?>.broadcast();
  StreamSubscription<AuthState>? _sub;
  String? _currentGeneration;

  void _init() {
    final currentSession = _client.auth.currentSession;
    if (currentSession != null && !currentSession.isExpired) {
      _currentGeneration = _buildGeneration(
        currentSession.user.id,
        currentSession.accessToken,
      );
    }

    _sub = _client.auth.onAuthStateChange.listen(
      (data) {
        final session = data.session;
        if (session == null || data.event == AuthChangeEvent.signedOut) {
          _currentGeneration = null;
        } else {
          _currentGeneration = _buildGeneration(
            session.user.id,
            session.accessToken,
          );
        }
        _controller.add(_currentGeneration);
      },
      onError: (Object _) {
        // Fail-closed on offline refresh errors or network disruption:
        // Do not advance generation; leave current state unchanged
      },
    );
  }

  static String _buildGeneration(String userId, String token) {
    return 'gen-$userId-${token.hashCode}';
  }

  @override
  String? get currentSessionGeneration => _currentGeneration;

  @override
  Stream<String?> get sessionGenerationStream => _controller.stream;

  @override
  Future<ValidatedActorContext?> validateForMutation() async {
    final session = _client.auth.currentSession;
    if (session == null || session.isExpired) {
      return null;
    }

    final user = session.user;
    final generation = _buildGeneration(user.id, session.accessToken);
    _currentGeneration = generation;

    return ValidatedActorContext(
      userId: user.id,
      sessionGeneration: generation,
      observedAt: _clock.now().toUtc(),
      role: user.appMetadata['role'] as String?,
    );
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
