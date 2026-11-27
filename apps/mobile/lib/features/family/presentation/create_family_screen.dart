import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';

/// Screen for creating a household family tenancy unit.
///
/// Triggers the atomic `create_family` RPC which creates the family record and
/// registers the creator as the active owner in a single database transaction.
class CreateFamilyScreen extends ConsumerStatefulWidget {
  const CreateFamilyScreen({super.key});

  @override
  ConsumerState<CreateFamilyScreen> createState() => _CreateFamilyScreenState();
}

class _CreateFamilyScreenState extends ConsumerState<CreateFamilyScreen> {
  final _nameController = TextEditingController();
  final _timezoneController = TextEditingController(text: 'UTC');
  final _localeController = TextEditingController(text: 'en_US');
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  Family? _createdFamily;
  String? _errorMessage;
  String? _verificationNotice;

  @override
  void initState() {
    super.initState();
    final pendingFamily = ref
        .read(coldStartContainmentProvider.notifier)
        .pendingCreatedFamily;
    if (pendingFamily != null) {
      _createdFamily = pendingFamily;
      _nameController.text = pendingFamily.name;
      _timezoneController.text = pendingFamily.timezone;
      _localeController.text = pendingFamily.locale;
      _verificationNotice =
          'Family "${pendingFamily.name}" was already created. Tap Retry Verification to check active membership without recreating it.';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _timezoneController.dispose();
    _localeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isLoading) return;
    if (_createdFamily == null && !_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _verificationNotice = null;
    });

    try {
      var family = _createdFamily;
      if (family == null) {
        try {
          final repo = ref.read(familyRepositoryProvider);
          final createFamily = CreateFamily(repo);

          family = await createFamily(
            name: _nameController.text.trim(),
            timezone: _timezoneController.text.trim(),
            locale: _localeController.text.trim(),
          );
          if (mounted) {
            setState(() {
              _createdFamily = family;
            });
          } else {
            _createdFamily = family;
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _errorMessage = 'Failed to create family: ${e.toString()}';
            });
          }
          return;
        }
      }

      // Trigger fresh membership verification via ContainmentAuthorizationVerifier
      // before allowing entry into ParentMode. Never assign activeFamilyProvider
      // until positive active adult membership for the created family is confirmed.
      bool verified = false;
      try {
        verified = await ref
            .read(coldStartContainmentProvider.notifier)
            .confirmCreatedFamily(family);
      } catch (_) {
        if (mounted) {
          setState(() {
            _verificationNotice =
                'Family "${family!.name}" was created, but membership verification did not complete right now. Tap Retry Verification to continue without recreating the family.';
          });
        }
        return;
      }

      if (!verified) {
        if (mounted) {
          setState(() {
            _verificationNotice =
                'Family "${family!.name}" was created, but active membership verification has not confirmed Parent Mode yet. Tap Retry Verification to check access again.';
          });
        }
        return;
      }

      if (mounted) {
        final router = GoRouter.maybeOf(context);
        if (router != null) {
          router.go(AppRoutes.parentHome);
        }
      }
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
      appBar: AppBar(title: const Text('Create Family')),
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
                      'Create Your Household',
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Your family represents the security boundary for your children, records and reward configuration.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextFormField(
                      key: const Key('family_name_field'),
                      controller: _nameController,
                      enabled: !_isLoading && _createdFamily == null,
                      decoration: const InputDecoration(
                        labelText: 'Family Name',
                        hintText: 'e.g. The Miller Family',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a family name.';
                        }
                        if (value.trim().length > 100) {
                          return 'Name cannot exceed 100 characters.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('family_timezone_field'),
                      controller: _timezoneController,
                      enabled: !_isLoading && _createdFamily == null,
                      decoration: const InputDecoration(
                        labelText: 'Timezone',
                        hintText: 'UTC',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a timezone.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('family_locale_field'),
                      controller: _localeController,
                      enabled: !_isLoading && _createdFamily == null,
                      decoration: const InputDecoration(
                        labelText: 'Locale',
                        hintText: 'en_US',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter a locale.';
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
                    if (_verificationNotice != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: Text(
                          _verificationNotice!,
                          key: const Key(
                            'create_family_verification_pending_notice',
                          ),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.secondary,
                          ),
                        ),
                      ),
                    FilledButton(
                      key: const Key('save_family_button'),
                      onPressed: _isLoading ? null : _submit,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _createdFamily == null
                                  ? 'Create Family'
                                  : 'Retry Verification',
                            ),
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
