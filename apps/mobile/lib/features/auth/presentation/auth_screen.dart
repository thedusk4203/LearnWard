import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';

/// Adult authentication screen using Supabase Magic Link / OTP.
///
/// Password-based sign-in is intentionally avoided in Phase 1 to minimize
/// credential overhead and support low-friction family onboarding.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendMagicLink() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final client = ref.read(supabaseClientProvider);
      if (client != null) {
        await client.auth.signInWithOtp(email: _emailController.text.trim());
        setState(() {
          _successMessage =
              'Magic link sent to ${_emailController.text.trim()}. Check your inbox!';
        });
      } else {
        // Mock fallback for offline / test environments
        setState(() {
          _successMessage =
              'Development mode: Sign-in link simulated for ${_emailController.text.trim()}.';
        });
        if (mounted) {
          context.go(AppRoutes.parentHome);
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Authentication error: ${e.toString()}';
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
      appBar: AppBar(title: const Text('Adult Sign In')),
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
                    Text('LearnWard', style: theme.textTheme.displaySmall),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Parent & Guardian Access',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      'Sign in with your email address. We will send a secure magic link to confirm your adult identity.',
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('email_field'),
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Email Address',
                        hintText: 'parent@example.com',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Please enter your email address.';
                        }
                        if (!value.contains('@')) {
                          return 'Please enter a valid email address.';
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
                    if (_successMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: Text(
                          _successMessage!,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    FilledButton(
                      key: const Key('send_magic_link_button'),
                      onPressed: _isLoading ? null : _sendMagicLink,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Send Magic Link'),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextButton(
                      key: const Key('continue_as_guest_button'),
                      onPressed: () => context.go(AppRoutes.parentHome),
                      child: const Text('Continue to Family Dashboard'),
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
