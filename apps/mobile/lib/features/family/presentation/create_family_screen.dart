import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../app/bootstrap/cold_start_containment_bootstrap.dart';
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
  PendingCreatedFamilyRecord? _pendingRecord;
  String? _errorMessage;
  String? _verificationNotice;
  StreamSubscription<String?>? _sessionGenSub;

  @override
  void initState() {
    super.initState();
    final authPort = ref.read(authSessionPortProvider);
    _sessionGenSub = authPort.sessionGenerationStream.listen((nextGeneration) {
      final pending = _pendingRecord;
      if (pending == null) return;
      if (nextGeneration == null ||
          nextGeneration.trim() != pending.createdInSessionGeneration.trim()) {
        if (mounted) {
          setState(_clearPendingState);
        } else {
          _clearPendingState();
        }
      }
    });

    final coldStart = ref.read(coldStartContainmentProvider);
    final actor = coldStart.actorContext;
    final liveGen = authPort.currentSessionGeneration;
    final nowUtc = ref.read(appClockProvider)();
    if (actor != null &&
        !actor.isAnonymous &&
        actor.role != 'child' &&
        actor.isValidAt(nowUtc) &&
        liveGen != null &&
        actor.sessionGeneration == liveGen) {
      final pendingRecord = ref
          .read(coldStartContainmentProvider.notifier)
          .pendingCreatedFamilyFor(
            actorUserId: actor.userId,
            sessionGeneration: liveGen,
          );
      if (pendingRecord != null) {
        _pendingRecord = pendingRecord;
        _nameController.text = pendingRecord.family.name;
        _timezoneController.text = pendingRecord.family.timezone;
        _localeController.text = pendingRecord.family.locale;
        _verificationNotice =
            'Family "${pendingRecord.family.name}" was already created. Tap Retry Verification to check active membership without recreating it.';
        Future.microtask(_revalidateMountedPendingActor);
      }
    }
  }

  void _clearPendingState() {
    _pendingRecord = null;
    _nameController.clear();
    _timezoneController.text = 'UTC';
    _localeController.text = 'en_US';
    _errorMessage = null;
    _verificationNotice = null;
  }

  Future<void> _revalidateMountedPendingActor() async {
    final pending = _pendingRecord;
    if (!mounted || pending == null) return;
    final authPort = ref.read(authSessionPortProvider);
    final liveActor = await authPort.validateForMutation();
    if (!mounted) return;
    final nowUtc = ref.read(appClockProvider)();
    if (liveActor == null ||
        !liveActor.isValidAt(nowUtc) ||
        liveActor.isAnonymous ||
        liveActor.role == 'child' ||
        authPort.currentSessionGeneration !=
            pending.createdInSessionGeneration ||
        !pending.matchesActor(
          actorUserId: liveActor.userId,
          sessionGeneration: liveActor.sessionGeneration,
        )) {
      setState(_clearPendingState);
    }
  }

  @override
  void dispose() {
    _sessionGenSub?.cancel();
    _sessionGenSub = null;
    _nameController.dispose();
    _timezoneController.dispose();
    _localeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isLoading) return;

    final authPort = ref.read(authSessionPortProvider);
    final liveActor = await authPort.validateForMutation();
    if (!mounted) return;
    final nowUtc = ref.read(appClockProvider)();
    if (liveActor == null ||
        !liveActor.isValidAt(nowUtc) ||
        liveActor.isAnonymous ||
        liveActor.role == 'child' ||
        liveActor.userId.trim().isEmpty ||
        liveActor.sessionGeneration.trim().isEmpty ||
        authPort.currentSessionGeneration != liveActor.sessionGeneration) {
      setState(() {
        _clearPendingState();
        _errorMessage = 'Your session is no longer active. Please sign in again to create a family.';
      });
      return;
    }

    if (_pendingRecord != null &&
        !_pendingRecord!.matchesActor(
          actorUserId: liveActor.userId,
          sessionGeneration: liveActor.sessionGeneration,
        )) {
      setState(_clearPendingState);
    }

    if (_pendingRecord == null && !_formKey.currentState!.validate()) return;

    final capturedActorId = liveActor.userId.trim();
    final capturedGeneration = liveActor.sessionGeneration;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _verificationNotice = null;
    });

    try {
      var record = _pendingRecord;
      if (record == null) {
        try {
          final repo = ref.read(familyRepositoryProvider);
          final createFamily = CreateFamily(repo);

          final createdFamily = await createFamily(
            name: _nameController.text.trim(),
            timezone: _timezoneController.text.trim(),
            locale: _localeController.text.trim(),
          );

          final postRpcActor = await authPort.validateForMutation();
          final postRpcUtc = ref.read(appClockProvider)();
          if (!mounted ||
              authPort.currentSessionGeneration != capturedGeneration ||
              postRpcActor == null ||
              !postRpcActor.isValidAt(postRpcUtc) ||
              postRpcActor.isAnonymous ||
              postRpcActor.role == 'child' ||
              postRpcActor.userId.trim() != capturedActorId ||
              postRpcActor.sessionGeneration != capturedGeneration ||
              createdFamily.createdByUserId.trim() != capturedActorId) {
            if (mounted) {
              setState(_clearPendingState);
            }
            return;
          }

          record = PendingCreatedFamilyRecord(
            family: createdFamily,
            creatorActorUserId: capturedActorId,
            createdInSessionGeneration: capturedGeneration,
            createdAtUtc: postRpcUtc,
          );
          if (mounted) {
            setState(() {
              _pendingRecord = record;
            });
          } else {
            _pendingRecord = record;
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
            .confirmCreatedFamily(
              record.family,
              creatorActorUserId: record.creatorActorUserId,
              sessionGeneration: record.createdInSessionGeneration,
            );
      } catch (_) {
        if (!mounted) return;
        final currentActor = ref
            .read(coldStartContainmentProvider)
            .actorContext;
        if (authPort.currentSessionGeneration !=
                record.createdInSessionGeneration ||
            currentActor == null ||
            !record.matchesActor(
              actorUserId: currentActor.userId,
              sessionGeneration: currentActor.sessionGeneration,
            )) {
          setState(_clearPendingState);
          return;
        }
        setState(() {
          _verificationNotice =
              'Family "${record!.family.name}" was created, but membership verification did not complete right now. Tap Retry Verification to continue without recreating the family.';
        });
        return;
      }

      if (!mounted) return;
      final currentActor = ref.read(coldStartContainmentProvider).actorContext;
      if (authPort.currentSessionGeneration !=
              record.createdInSessionGeneration ||
          currentActor == null ||
          !record.matchesActor(
            actorUserId: currentActor.userId,
            sessionGeneration: currentActor.sessionGeneration,
          )) {
        setState(_clearPendingState);
        return;
      }

      if (!verified) {
        setState(() {
          _verificationNotice =
              'Family "${record!.family.name}" was created, but active membership verification has not confirmed Parent Mode yet. Tap Retry Verification to check access again.';
        });
        return;
      }

      final router = GoRouter.maybeOf(context);
      if (router != null) {
        router.go(AppRoutes.parentHome);
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
    ref.listen<ColdStartContainmentState>(coldStartContainmentProvider, (
      previous,
      next,
    ) {
      final pending = _pendingRecord;
      if (pending == null) return;
      final nextActor = next.actorContext;
      if (nextActor == null ||
          nextActor.isAnonymous ||
          nextActor.role == 'child' ||
          !pending.matchesActor(
            actorUserId: nextActor.userId,
            sessionGeneration: nextActor.sessionGeneration,
          )) {
        setState(_clearPendingState);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Family'),
        leading: Navigator.of(context).canPop()
            ? null
            : (GoRouter.maybeOf(context) != null
                  ? BackButton(
                      onPressed: () {
                        final status = ref
                            .read(coldStartContainmentProvider)
                            .status;
                        GoRouter.of(context).go(
                          status ==
                                  ColdStartContainmentStatus
                                      .noActiveFamilyMembership
                              ? AppRoutes.familyOnboarding
                              : AppRoutes.parentHome,
                        );
                      },
                    )
                  : null),
      ),
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
                      enabled: !_isLoading && _pendingRecord == null,
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
                      enabled: !_isLoading && _pendingRecord == null,
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
                      enabled: !_isLoading && _pendingRecord == null,
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
                              _pendingRecord == null
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
