// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

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
  String? _boundUserId;
  String? _boundAccessToken;
  int _epoch = 0;
  bool _isStickyInvalid = false;
  bool _isDisposed = false;

  void _emitGeneration(String? generation) {
    if (_isDisposed || _controller.isClosed) {
      return;
    }
    _controller.add(generation);
  }

  void _init() {
    final currentSession = _currentSessionProvider != null
        ? _currentSessionProvider()
        : _client.auth.currentSession;

    if (currentSession != null && !currentSession.isExpired) {
      _epoch++;
      _boundUserId = currentSession.user.id;
      _boundAccessToken = currentSession.accessToken;
      _currentGeneration = _buildGeneration(_boundUserId!, _epoch);
      _isStickyInvalid = false;
    } else {
      _isStickyInvalid = true;
      _boundUserId = null;
      _boundAccessToken = null;
      _currentGeneration = null;
    }

    final stream = _authStateStream ?? _client.auth.onAuthStateChange;
    _sub = stream.listen(
      (data) {
        if (_isDisposed) {
          return;
        }
        final session = data.session;
        if (session == null ||
            data.event == AuthChangeEvent.signedOut ||
            session.isExpired) {
          _isStickyInvalid = true;
          _boundUserId = null;
          _boundAccessToken = null;
          _currentGeneration = null;
        } else {
          _isStickyInvalid = false;
          _epoch++;
          _boundUserId = session.user.id;
          _boundAccessToken = session.accessToken;
          _currentGeneration = _buildGeneration(session.user.id, _epoch);
        }
        _emitGeneration(_currentGeneration);
      },
      onError: (Object _) {
        if (_isDisposed) {
          return;
        }
        // Sticky fail-closed on auth stream errors, token refresh failures, or stream disruption:
        _isStickyInvalid = true;
        _boundUserId = null;
        _boundAccessToken = null;
        _currentGeneration = null;
        _emitGeneration(null);
      },
    );
  }

  static String _buildGeneration(String userId, int epoch) {
    return 'gen-$userId-$epoch';
  }

  @override
  String? get currentSessionGeneration =>
      _isDisposed ? null : _currentGeneration;

  /// Bound user ID matching [currentSessionGeneration], or null when invalidated (`WP3`).
  String? get currentBoundUserId =>
      (_isDisposed || _isStickyInvalid || _currentGeneration == null)
      ? null
      : _boundUserId;

  @override
  Stream<String?> get sessionGenerationStream => _controller.stream;

  @override
  Future<ValidatedActorContext?> validateForMutation() async {
    // If disposed or in a sticky invalid/uncertain state, strictly fail closed.
    // Never resurrect an invalidated session from cached memory or emit into a closed controller.
    if (_isDisposed || _isStickyInvalid || _currentGeneration == null) {
      return null;
    }

    final session = _currentSessionProvider != null
        ? _currentSessionProvider()
        : _client.auth.currentSession;

    if (_isDisposed) {
      return null;
    }

    if (session == null || session.isExpired) {
      _isStickyInvalid = true;
      _boundUserId = null;
      _boundAccessToken = null;
      _currentGeneration = null;
      _emitGeneration(null);
      return null;
    }

    // R24-3-07: Live session must match the generation-bound credentials
    if (session.user.id != _boundUserId ||
        session.accessToken != _boundAccessToken) {
      _isStickyInvalid = true;
      _boundUserId = null;
      _boundAccessToken = null;
      _currentGeneration = null;
      _emitGeneration(null);
      return null;
    }

    final user = session.user;
    final isAnonymous =
        user.isAnonymous || _extractJwtIsAnonymousClaim(session.accessToken);
    return ValidatedActorContext(
      userId: user.id,
      sessionGeneration: _currentGeneration!,
      observedAt: _clock.now().toUtc(),
      role: user.appMetadata['role'] as String?,
      isAnonymous: isAnonymous,
    );
  }

  static bool _extractJwtIsAnonymousClaim(String accessToken) {
    final parts = accessToken.split('.');
    if (parts.length != 3) {
      return false;
    }
    try {
      final normalized = base64Url.normalize(parts[1]);
      final payloadJson = utf8.decode(base64Url.decode(normalized));
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map<String, dynamic>) {
        return false;
      }
      final claim = decoded['is_anonymous'];
      if (claim is bool) {
        return claim;
      }
      if (claim is String) {
        return claim.trim().toLowerCase() == 'true';
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _isStickyInvalid = true;
    _boundUserId = null;
    _boundAccessToken = null;
    _currentGeneration = null;
    final sub = _sub;
    _sub = null;
    sub?.cancel();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}
