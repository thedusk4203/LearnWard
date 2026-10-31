import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';

/// Screen for creating a child profile within the active family.
///
/// Preserves the architectural invariant that child profiles are NOT
/// automatically Supabase Auth accounts and do NOT collect child credentials.
class CreateChildScreen extends ConsumerStatefulWidget {
  const CreateChildScreen({super.key});

  @override
  ConsumerState<CreateChildScreen> createState() => _CreateChildScreenState();
}

class _CreateChildScreenState extends ConsumerState<CreateChildScreen> {
  final _nameController = TextEditingController();
  final _gradeController = TextEditingController();
  final _birthYearController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _gradeController.dispose();
    _birthYearController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    final activeFamily = ref.read(activeFamilyProvider);
    if (activeFamily == null) {
      setState(() {
        _errorMessage = 'No active family selected.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(childProfileRepositoryProvider);
      final createChild = CreateChildProfile(repo);

      int? grade;
      if (_gradeController.text.trim().isNotEmpty) {
        grade = int.tryParse(_gradeController.text.trim());
      }

      int? birthYear;
      if (_birthYearController.text.trim().isNotEmpty) {
        birthYear = int.tryParse(_birthYearController.text.trim());
      }

      await createChild(
        familyId: activeFamily.id,
        displayName: _nameController.text.trim(),
        schoolGrade: grade,
        birthYear: birthYear,
      );

      if (mounted) {
        context.go(AppRoutes.parentHome);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to create child profile: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Add Child Profile')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'New Learner Profile',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Child profiles belong to your family. No email, phone number, or password is required.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      key: const Key('child_name_field'),
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Display Name *',
                        hintText: 'e.g. Leo',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a name for the child.';
                        }
                        if (value.trim().length > 50) {
                          return 'Name cannot exceed 50 characters.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('child_grade_field'),
                      controller: _gradeController,
                      decoration: const InputDecoration(
                        labelText: 'School Grade (Optional)',
                        hintText: 'e.g. 6',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value != null && value.trim().isNotEmpty) {
                          final grade = int.tryParse(value.trim());
                          if (grade == null || grade < 1 || grade > 12) {
                            return 'Grade must be between 1 and 12.';
                          }
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('child_birth_year_field'),
                      controller: _birthYearController,
                      decoration: const InputDecoration(
                        labelText: 'Birth Year (Optional)',
                        hintText: 'e.g. 2014',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      validator: (value) {
                        if (value != null && value.trim().isNotEmpty) {
                          final year = int.tryParse(value.trim());
                          if (year == null || year < 1990 || year > 2035) {
                            return 'Please enter a plausible birth year.';
                          }
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    FilledButton(
                      key: const Key('save_child_button'),
                      onPressed: _isLoading ? null : _submit,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save Child Profile'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
