import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Modal dialog prompting the parent to configure a 4-digit Parent PIN
/// before entering shared-device Child Mode.
class ParentPinSetupDialog extends ConsumerStatefulWidget {
  const ParentPinSetupDialog({super.key});

  /// Displays the PIN setup dialog.
  ///
  /// Returns `true` if a PIN was successfully saved, or `false` if cancelled.
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ParentPinSetupDialog(),
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
      final gateService = ref.read(parentGateServiceProvider);
      await gateService.setPin(pin);

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
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('parent_pin_setup_field'),
              controller: _pinController,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              autofocus: true,
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
          onPressed: _isSaving ? null : _submitPin,
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
