import 'package:flutter/material.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

/// Lightweight parent gate challenge dialog for shared devices.
///
/// Notice: As documented in the architecture specification, this local gate
/// prevents casual accidental access on shared devices. It is a UX boundary,
/// while database Row Level Security remains the real security boundary.
class ParentGateDialog extends StatefulWidget {
  const ParentGateDialog({super.key});

  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ParentGateDialog(),
    );
    return result ?? false;
  }

  @override
  State<ParentGateDialog> createState() => _ParentGateDialogState();
}

class _ParentGateDialogState extends State<ParentGateDialog> {
  final _answerController = TextEditingController();
  final int _a = 7;
  final int _b = 8;
  int get _expected => _a * _b; // 56

  String? _error;

  @override
  void dispose() {
    _answerController.dispose();
    super.dispose();
  }

  void _verify() {
    final input = int.tryParse(_answerController.text.trim());
    if (input == _expected) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = 'Incorrect answer. Parent access only.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Parent Gate'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Please solve this challenge to exit Child Mode:'),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '$_a × $_b = ?',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const Key('parent_gate_input'),
            controller: _answerController,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(hintText: 'Answer', errorText: _error),
            onSubmitted: (_) => _verify(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Stay in Child Mode'),
        ),
        FilledButton(
          key: const Key('parent_gate_confirm_button'),
          onPressed: _verify,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
