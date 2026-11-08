// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:learnward_application/learnward_application.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase-backed adapter for [AuthSessionPort].
///
/// Observes auth lifecycle and maintains an explicit monotonic session generation
/// that invalidates on sign out, user switch, token expiration, or stream error.
/// Enforces sticky fail-closed semantics upon stream disruption or refresh error.
final class SupabaseAuthSessionAdapter implements AuthSessionPort {
  SupabaseAuthSessionAdapter(
    this._client, {
    Clock clock = const SystemClock(),
    Stream<AuthState>? authStateStream,
    Session? Function()? currentSessionProvider,
  }) : _clock = clock,
       _authStateStream = authStateStream,
       _currentSessionProvider = currentSessionProvider {
    _init();
  }

  final SupabaseClient _client;
  final Clock _clock;
  final Stream<AuthState>? _authStateStream;
  final Session? Function()? _currentSessionProvider;
  final _controller = StreamController<String?>.broadcast();
  StreamSubscription<AuthState>? _sub;

  String? _currentGeneration;
  int _epoch = 0;
  bool _isStickyInvalid = false;

  void _init() {
    final currentSession = _currentSessionProvider != null
        ? _currentSessionProvider()
        : _client.auth.currentSession;

    if (currentSession != null && !currentSession.isExpired) {
      _epoch++;
      _currentGeneration = _buildGeneration(currentSession.user.id, _epoch);
      _isStickyInvalid = false;
    } else {
      _isStickyInvalid = true;
      _currentGeneration = null;
    }

    final stream = _authStateStream ?? _client.auth.onAuthStateChange;
    _sub = stream.listen(
      (data) {
        final session = data.session;
        if (session == null ||
            data.event == AuthChangeEvent.signedOut ||
            session.isExpired) {
          _isStickyInvalid = true;
          _currentGeneration = null;
        } else {
          _isStickyInvalid = false;
          _epoch++;
          _currentGeneration = _buildGeneration(session.user.id, _epoch);
        }
        _controller.add(_currentGeneration);
      },
      onError: (Object _) {
        // Sticky fail-closed on auth stream errors, token refresh failures, or stream disruption:
        _isStickyInvalid = true;
        _currentGeneration = null;
        _controller.add(null);
      },
    );
  }

  static String _buildGeneration(String userId, int epoch) {
    return 'gen-$userId-$epoch';
  }

  @override
  String? get currentSessionGeneration => _currentGeneration;

  @override
  Stream<String?> get sessionGenerationStream => _controller.stream;

  @override
  Future<ValidatedActorContext?> validateForMutation() async {
    // If in a sticky invalid/uncertain state (auth stream error, sign out, or refresh failure),
    // strictly fail closed. Never resurrect an invalidated session from cached memory.
    if (_isStickyInvalid || _currentGeneration == null) {
      return null;
    }

    final session = _currentSessionProvider != null
        ? _currentSessionProvider()
        : _client.auth.currentSession;

    if (session == null || session.isExpired) {
      _isStickyInvalid = true;
      _currentGeneration = null;
      _controller.add(null);
      return null;
    }

    final user = session.user;
    return ValidatedActorContext(
      userId: user.id,
      sessionGeneration: _currentGeneration!,
      observedAt: _clock.now().toUtc(),
      role: user.appMetadata['role'] as String?,
    );
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
