import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_domain/learnward_domain.dart';

import 'app_config.dart';
import 'app_providers.dart';

/// App-active recovery trigger manager.
///
/// Feature-gated by [AppConfig.recoveryDispatcherEnabled].
/// When disabled (default), all background triggers remain strictly dormant.
/// When enabled, listens to auth session changes, active family selection,
/// and app lifecycle foreground resume events to safely schedule bounded
/// outbox recovery drains.
final class AppActiveRecoveryService with WidgetsBindingObserver {
  AppActiveRecoveryService(this._ref, {this._enabledOverride}) {
    _init();
  }

  final Ref _ref;
  final bool? _enabledOverride;
  StreamSubscription<String?>? _authSub;
  ProviderSubscription<Family?>? _familySub;
  ProviderSubscription<ChildProfile?>? _childModeSub;
  Timer? _periodicTimer;
  bool _isDisposed = false;

  bool get _isEnabled =>
      _enabledOverride ?? AppConfig.recoveryDispatcherEnabled;

  void _init() {
    // Strictly gate on feature flag; remain completely dormant when flag is OFF.
    if (!_isEnabled) return;

    WidgetsBinding.instance.addObserver(this);

    final authPort = _ref.read(authSessionPortProvider);
    _authSub = authPort.sessionGenerationStream.listen((generation) {
      if (generation != null) {
        _triggerDrain();
      }
    });

    _familySub = _ref.listen<Family?>(activeFamilyProvider, (previous, next) {
      if (next != null && next.id != previous?.id) {
        _triggerDrain();
      }
    });

    _childModeSub = _ref.listen<ChildProfile?>(activeChildModeProvider, (
      previous,
      next,
    ) {
      if (next != null && next.familyId != previous?.familyId) {
        _triggerDrain();
      }
    });

    // Bounded periodic recovery poll while app is active (with 1s flood guard)
    _periodicTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _triggerDrain();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isEnabled || _isDisposed) return;
    if (state == AppLifecycleState.resumed) {
      _triggerDrain();
    }
  }

  /// Triggers a recovery drain pass if auth and active family preconditions hold.
  Future<void> _triggerDrain() async {
    if (_isDisposed || !_isEnabled) return;

    final authPort = _ref.read(authSessionPortProvider);
    final context = await authPort.validateForMutation();
    if (context == null) return;

    final activeFamilyId =
        _ref.read(activeFamilyProvider)?.id.value ??
        _ref.read(activeChildModeProvider)?.familyId.value;
    if (activeFamilyId == null) return;

    final dispatcher = _ref.read(outboxRecoveryDispatcherProvider);
    await dispatcher.drainOnce(
      validatedContext: context,
      activeFamilyId: activeFamilyId,
    );
  }

  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _authSub?.cancel();
    _familySub?.close();
    _childModeSub?.close();
    _periodicTimer?.cancel();
  }
}

/// Provider managing the app-active recovery lifecycle.
final appActiveRecoveryServiceProvider = Provider<AppActiveRecoveryService>((
  ref,
) {
  final service = AppActiveRecoveryService(ref);
  ref.onDispose(service.dispose);
  return service;
});
