import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

/// Modal dialog prompting the parent to configure a 4-digit Parent PIN
/// before entering shared-device Child Mode.
///
/// **WP3 Integration Note (`R39-04`):** In WP1, `onSavePin` defaults
/// to `null` and disables Parent PIN setup fail-closed so unowned credentials
/// cannot be written from UI state. WP3 will wire `onSavePin` through
/// `SessionLifecycleController` to supply verified `ownerFamilyId`,
/// `configuredByActorUserId`, positive adult verification, and
/// `ParentGateOperationFence`.
class ParentPinSetupDialog extends ConsumerStatefulWidget {
  const ParentPinSetupDialog({this.onSavePin, super.key});

  /// Arbiter-fenced save delegate supplied by WP3 (`SessionLifecycleController`).
  final Future<void> Function(String pin)? onSavePin;

  /// Displays the PIN setup dialog.
  ///
  /// Returns `true` if a PIN was successfully saved, or `false` if cancelled.
  static Future<bool> show(
    BuildContext context, {
    Future<void> Function(String pin)? onSavePin,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ParentPinSetupDialog(onSavePin: onSavePin),
    );
    return result ?? false;
  }

  @override
  ConsumerState<ParentPinSetupDialog> createState() =>
      _ParentPinSetupDialogState();
}

class _ParentPinSetupDialogState extends ConsumerState<ParentPinSetupDialog> {
  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submitPin() async {
    if (widget.onSavePin == null) {
      setState(() {
        _errorMessage = 'Adult session authorization is required before saving a Parent PIN.';
      });
      return;
    }

    final pin = _pinController.text.trim();
    final confirm = _confirmController.text.trim();

    if (pin.length != 4 || int.tryParse(pin) == null) {
      setState(() {
        _errorMessage = 'PIN must be exactly 4 digits.';
      });
      return;
    }

    if (pin != confirm) {
      setState(() {
        _errorMessage = 'PINs do not match. Please verify and re-enter.';
        _confirmController.clear();
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      await widget.onSavePin!(pin);

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to save PIN: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAuthorizedDelegateAvailable = widget.onSavePin != null;

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.shield_outlined),
          SizedBox(width: AppSpacing.sm),
          Text('Set Parent PIN'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Before entering Child Mode, configure a 4-digit PIN to protect '
              'your family settings and prevent unauthorized exit from Child Mode.',
            ),
            if (!isAuthorizedDelegateAvailable) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Parent PIN setup is unavailable until verified adult session lifecycle authorization is active.',
                key: const Key('parent_pin_setup_restricted_notice'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('parent_pin_setup_field'),
              controller: _pinController,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              autofocus: true,
              enabled: isAuthorizedDelegateAvailable,
              decoration: const InputDecoration(
                labelText: 'New 4-Digit PIN',
                hintText: '••••',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const Key('parent_pin_confirm_field'),
              controller: _confirmController,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              enabled: isAuthorizedDelegateAvailable,
              decoration: const InputDecoration(
                labelText: 'Confirm PIN',
                hintText: '••••',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.check_circle_outline),
              ),
              onSubmitted: (_) => _submitPin(),
            ),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  _errorMessage!,
                  key: const Key('parent_pin_setup_error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('parent_pin_setup_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('parent_pin_setup_submit'),
          onPressed: (!isAuthorizedDelegateAvailable || _isSaving)
              ? null
              : _submitPin,
          child: _isSaving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save PIN & Enter'),
        ),
      ],
    );
  }
}
