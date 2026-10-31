import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Parent Gate Challenge Dialog.
///
/// Uses parent-defined 4-digit PIN verification to exit Child Mode.
/// Plaintext PIN is never stored; verified against salted SHA-256 hash.
class ParentGateDialog extends ConsumerStatefulWidget {
  const ParentGateDialog({required this.onGatePassed, super.key});

  final VoidCallback onGatePassed;

  static Future<void> show(
    BuildContext context, {
    required VoidCallback onGatePassed,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ParentGateDialog(onGatePassed: onGatePassed),
    );
  }

  @override
  ConsumerState<ParentGateDialog> createState() => _ParentGateDialogState();
}

class _ParentGateDialogState extends ConsumerState<ParentGateDialog> {
  final _pinController = TextEditingController();
  bool _isChecking = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _verifyPin() async {
    final enteredPin = _pinController.text.trim();
    if (enteredPin.length != 4) {
      setState(() {
        _errorMessage = 'PIN must be 4 digits.';
      });
      return;
    }

    setState(() {
      _isChecking = true;
      _errorMessage = null;
    });

    try {
      final service = ref.read(parentGateServiceProvider);
      final isValid = await service.verifyPin(enteredPin);

      if (!mounted) return;

      if (isValid) {
        Navigator.of(context).pop();
        widget.onGatePassed();
      } else {
        setState(() {
          _errorMessage = 'Incorrect PIN. Try again.';
          _pinController.clear();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isChecking = false;
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
          Icon(Icons.lock_outline),
          SizedBox(width: AppSpacing.sm),
          Text('Parent Gate'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Enter your 4-digit Parent PIN to exit Child Mode.'),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('parent_gate_pin_field'),
              controller: _pinController,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '4-Digit PIN',
                hintText: '••••',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.pin_outlined),
              ),
              onSubmitted: (_) => _verifyPin(),
            ),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  _errorMessage!,
                  key: const Key('parent_gate_error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('parent_gate_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Stay in Child Mode'),
        ),
        FilledButton(
          key: const Key('parent_gate_verify_button'),
          onPressed: _isChecking ? null : _verifyPin,
          child: _isChecking
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Unlock'),
        ),
      ],
    );
  }
}
