import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_config.dart';
import 'app_providers.dart';

/// App-active recovery trigger manager.
///
/// Feature-gated by [AppConfig.recoveryDispatcherEnabled].
/// When disabled (default), all background triggers remain strictly dormant.
/// When enabled, listens to auth session changes and active family selection
/// to safely schedule bounded outbox recovery drains.
final class AppActiveRecoveryService {
  AppActiveRecoveryService(this._ref) {
    _init();
  }

  final Ref _ref;
  StreamSubscription<String?>? _authSub;
  Timer? _periodicTimer;

  void _init() {
    // Strictly gate on feature flag; remain completely dormant when flag is OFF.
    if (!AppConfig.recoveryDispatcherEnabled) return;

    final authPort = _ref.read(authSessionPortProvider);
    _authSub = authPort.sessionGenerationStream.listen((generation) {
      if (generation != null) {
        _triggerDrain();
      }
    });

    // Bounded periodic recovery poll while app is active (with 1s flood guard)
    _periodicTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _triggerDrain();
    });
  }

  Future<void> _triggerDrain() async {
    if (!AppConfig.recoveryDispatcherEnabled) return;

    final authPort = _ref.read(authSessionPortProvider);
    final context = await authPort.validateForMutation();
    if (context == null) return;

    final activeFamily = _ref.read(activeFamilyProvider);
    if (activeFamily == null) return;

    final dispatcher = _ref.read(outboxRecoveryDispatcherProvider);
    await dispatcher.drainOnce(
      validatedContext: context,
      activeFamilyId: activeFamily.id.value,
    );
  }

  void dispose() {
    _authSub?.cancel();
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
