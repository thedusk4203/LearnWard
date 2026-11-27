import 'package:flutter/material.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../domain/parent_gate_models.dart';

/// Parent Mode PIN configuration, change, cross-family reassignment, forgotten
/// reset, and corrupt recovery dialog (`D1.5`, `C0-18`, `C0-27`).
class ParentPinSettingsDialog extends StatefulWidget {
  const ParentPinSettingsDialog({
    super.key,
    required this.credentialStatus,
    required this.pinOwnerFamilyId,
    required this.activeFamilyId,
    required this.isPostSignOutFreshAdultAuth,
    this.onInitialSetup,
    this.onChangePin,
    this.onReassignCrossFamily,
    this.onForgottenReset,
    this.onRecoverCorrupt,
  });

  final ParentGateCredentialStatus credentialStatus;
  final String? pinOwnerFamilyId;
  final String activeFamilyId;
  final bool isPostSignOutFreshAdultAuth;
  final Future<void> Function(String newPin)? onInitialSetup;
  final Future<PinVerificationResult> Function(
    String currentPin,
    String newPin,
  )?
  onChangePin;
  final Future<void> Function(String newPin)? onReassignCrossFamily;
  final Future<void> Function(String newPin)? onForgottenReset;
  final Future<void> Function(String newPin)? onRecoverCorrupt;

  static Future<bool> show(
    BuildContext context, {
    required ParentGateCredentialStatus credentialStatus,
    required String? pinOwnerFamilyId,
    required String activeFamilyId,
    required bool isPostSignOutFreshAdultAuth,
    Future<void> Function(String newPin)? onInitialSetup,
    Future<PinVerificationResult> Function(String currentPin, String newPin)?
    onChangePin,
    Future<void> Function(String newPin)? onReassignCrossFamily,
    Future<void> Function(String newPin)? onForgottenReset,
    Future<void> Function(String newPin)? onRecoverCorrupt,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ParentPinSettingsDialog(
        credentialStatus: credentialStatus,
        pinOwnerFamilyId: pinOwnerFamilyId,
        activeFamilyId: activeFamilyId,
        isPostSignOutFreshAdultAuth: isPostSignOutFreshAdultAuth,
        onInitialSetup: onInitialSetup,
        onChangePin: onChangePin,
        onReassignCrossFamily: onReassignCrossFamily,
        onForgottenReset: onForgottenReset,
        onRecoverCorrupt: onRecoverCorrupt,
      ),
    );
    return result ?? false;
  }

  @override
  State<ParentPinSettingsDialog> createState() =>
      _ParentPinSettingsDialogState();
}

enum _PinSettingsAction {
  initialSetup,
  changePin,
  crossFamilyReassign,
  forgottenReset,
  corruptRecover,
}

class _ParentPinSettingsDialogState extends State<ParentPinSettingsDialog> {
  final _currentPinController = TextEditingController();
  final _newPinController = TextEditingController();
  final _confirmPinController = TextEditingController();
  late _PinSettingsAction _selectedAction;
  bool _confirmedReassign = false;
  bool _isSubmitting = false;
  String? _error;

  bool get _hasCrossFamilyOwner =>
      widget.credentialStatus == ParentGateCredentialStatus.validV2 &&
      widget.pinOwnerFamilyId != null &&
      widget.pinOwnerFamilyId != widget.activeFamilyId;

  @override
  void initState() {
    super.initState();
    if (widget.credentialStatus == ParentGateCredentialStatus.missing) {
      _selectedAction = _PinSettingsAction.initialSetup;
    } else if (widget.credentialStatus == ParentGateCredentialStatus.corrupt) {
      _selectedAction = _PinSettingsAction.corruptRecover;
    } else if (_hasCrossFamilyOwner) {
      _selectedAction = _PinSettingsAction.crossFamilyReassign;
    } else {
      _selectedAction = _PinSettingsAction.changePin;
    }
  }

  @override
  void dispose() {
    _currentPinController.dispose();
    _newPinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    final newPin = _newPinController.text.trim();
    final confirmPin = _confirmPinController.text.trim();
    final currentPin = _currentPinController.text.trim();

    if (!RegExp(r'^\d{4}$').hasMatch(newPin)) {
      setState(() => _error = 'New PIN must be exactly 4 digits.');
      return;
    }
    if (newPin != confirmPin) {
      setState(() => _error = 'New PIN entries do not match.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      switch (_selectedAction) {
        case _PinSettingsAction.initialSetup:
          await widget.onInitialSetup!(newPin);
        case _PinSettingsAction.changePin:
          if (!RegExp(r'^\d{4}$').hasMatch(currentPin)) {
            setState(() {
              _error = 'Current PIN must be 4 digits.';
              _isSubmitting = false;
            });
            return;
          }
          final result = await widget.onChangePin!(currentPin, newPin);
          if (!result.isVerified) {
            setState(() {
              _error = result.message ?? 'Current PIN verification failed.';
              _isSubmitting = false;
            });
            return;
          }
        case _PinSettingsAction.crossFamilyReassign:
          if (!_confirmedReassign) {
            setState(() {
              _error = 'Please confirm reassigning this device PIN to the current family.';
              _isSubmitting = false;
            });
            return;
          }
          await widget.onReassignCrossFamily!(newPin);
        case _PinSettingsAction.forgottenReset:
          await widget.onForgottenReset!(newPin);
        case _PinSettingsAction.corruptRecover:
          await widget.onRecoverCorrupt!(newPin);
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canChooseForgottenReset =
        widget.credentialStatus != ParentGateCredentialStatus.missing &&
        !_hasCrossFamilyOwner &&
        widget.isPostSignOutFreshAdultAuth &&
        widget.onForgottenReset != null;

    return AlertDialog(
      key: const Key('parent_pin_settings_dialog'),
      title: const Text('Parent PIN Settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_hasCrossFamilyOwner)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  'Existing PIN is bound to another household on this device. Confirm below to replace it with a PIN for the active household.',
                  key: const Key('parent_pin_cross_family_notice'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ),
            if (widget.credentialStatus == ParentGateCredentialStatus.corrupt)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  'Persisted Parent PIN metadata is corrupted. Set a replacement PIN to restore Parent Gate.',
                  key: const Key('parent_pin_corrupt_notice'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (widget.credentialStatus == ParentGateCredentialStatus.validV2 ||
                widget.credentialStatus ==
                    ParentGateCredentialStatus.legacyV1) ...[
              if (!_hasCrossFamilyOwner && widget.onChangePin != null)
                SegmentedButton<_PinSettingsAction>(
                  segments: [
                    const ButtonSegment(
                      value: _PinSettingsAction.changePin,
                      label: Text('Change PIN'),
                    ),
                    if (canChooseForgottenReset)
                      const ButtonSegment(
                        value: _PinSettingsAction.forgottenReset,
                        label: Text('Reset (Fresh Auth)'),
                      ),
                  ],
                  selected: {_selectedAction},
                  onSelectionChanged: (sel) {
                    setState(() {
                      _selectedAction = sel.first;
                      _error = null;
                    });
                  },
                ),
              if (!_hasCrossFamilyOwner &&
                  !widget.isPostSignOutFreshAdultAuth) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Forgot PIN? Sign out from the parent bar and sign back in cleanly before resetting.',
                  key: const Key('parent_pin_reset_requires_reauth_notice'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
            ],
            if (_selectedAction == _PinSettingsAction.changePin) ...[
              TextField(
                key: const Key('parent_pin_settings_current_field'),
                controller: _currentPinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                decoration: const InputDecoration(
                  labelText: 'Current 4-digit PIN',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            TextField(
              key: const Key('parent_pin_settings_new_field'),
              controller: _newPinController,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              decoration: const InputDecoration(
                labelText: 'New 4-digit PIN',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              key: const Key('parent_pin_settings_confirm_field'),
              controller: _confirmPinController,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 4,
              decoration: const InputDecoration(
                labelText: 'Confirm 4-digit PIN',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            if (_selectedAction == _PinSettingsAction.crossFamilyReassign) ...[
              const SizedBox(height: AppSpacing.xs),
              CheckboxListTile(
                key: const Key('parent_pin_reassign_confirm_checkbox'),
                value: _confirmedReassign,
                contentPadding: EdgeInsets.zero,
                onChanged: _isSubmitting
                    ? null
                    : (v) => setState(() => _confirmedReassign = v ?? false),
                title: const Text(
                  'Confirm replacing cross-household PIN for this device.',
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _error!,
                key: const Key('parent_pin_settings_error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('parent_pin_settings_cancel'),
          onPressed: _isSubmitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('parent_pin_settings_submit'),
          onPressed: _isSubmitting ? null : _submit,
          child: Text(_isSubmitting ? 'Saving...' : 'Save PIN'),
        ),
      ],
    );
  }
}
