import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/routing/app_routes.dart';

/// Adult authentication screen supporting email Magic Link sign in.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  bool _linkSent = false;
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

    final email = _emailController.text.trim();

    try {
      final client = ref.read(supabaseClientProvider);
      if (client != null) {
        await client.auth.signInWithOtp(
          email: email,
          emailRedirectTo: 'com.learnward.app://auth-callback',
        );
        setState(() {
          _linkSent = true;
          _successMessage =
              'Check your email! A magic sign-in link has been sent to $email. Open the link on this device to complete sign in.';
        });
      } else {
        // Only reached in development demo mode
        setState(() {
          _successMessage = 'Development mode: Simulated sign-in for $email.';
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
    final config = ref.watch(appConfigProvider);

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
                      'Sign in with your email address to access your family dashboard.',
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('email_field'),
                      controller: _emailController,
                      enabled: !_linkSent,
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
                    if (_errorMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
                        child: Text(
                          _errorMessage!,
                          key: const Key('auth_error_message'),
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    if (_successMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
                        child: Text(
                          _successMessage!,
                          key: const Key('auth_success_message'),
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: AppSpacing.md),
                    FilledButton(
                      key: const Key('send_magic_link_button'),
                      onPressed: _isLoading ? null : _sendMagicLink,
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _linkSent
                                  ? 'Resend Magic Link'
                                  : 'Send Magic Link',
                            ),
                    ),
                    // Development demo bypass is ONLY visible in development demo mode.
                    // Staging and production strictly require real authenticated sessions.
                    if (config.canUseLocalDemoRepositories) ...[
                      const SizedBox(height: AppSpacing.md),
                      OutlinedButton(
                        key: const Key('demo_bypass_button'),
                        onPressed: () => context.go(AppRoutes.parentHome),
                        child: const Text('Development Demo Bypass'),
                      ),
                    ],
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
