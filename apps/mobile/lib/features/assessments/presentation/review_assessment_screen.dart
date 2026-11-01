import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/utils/uuid_generator.dart';
import 'growth_result_screen.dart';

/// Screen where a parent reviews, verifies or rejects a submitted assessment.
class ReviewAssessmentScreen extends ConsumerStatefulWidget {
  const ReviewAssessmentScreen({super.key, required this.assessment});

  final Assessment assessment;

  @override
  ConsumerState<ReviewAssessmentScreen> createState() =>
      _ReviewAssessmentScreenState();
}

class _ReviewAssessmentScreenState
    extends ConsumerState<ReviewAssessmentScreen> {
  late Assessment _currentAssessment;
  List<AssessmentEvidence> _evidenceList = [];
  bool _isLoadingEvidence = false;
  bool _isProcessing = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _currentAssessment = widget.assessment;
    _loadEvidence();
  }

  Future<void> _loadEvidence() async {
    setState(() => _isLoadingEvidence = true);
    try {
      final repo = ref.read(assessmentRepositoryProvider);
      final evidence = await repo.listEvidenceForAssessment(
        _currentAssessment.id,
      );
      if (mounted) {
        setState(() => _evidenceList = evidence);
      }
    } catch (_) {
      // Ignored non-fatal evidence fetch error
    } finally {
      if (mounted) {
        setState(() => _isLoadingEvidence = false);
      }
    }
  }

  Future<void> _verifyAssessment() async {
    final notesController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify Assessment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to verify this result for "${_currentAssessment.title}"? '
              'This will generate an immutable verified learning record.',
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('verification_notes_field'),
              controller: notesController,
              maxLength: 1000,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Approval Notes (Optional, max 1000 chars)',
                hintText: 'e.g. Verified against test paper',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_verify_button'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm Verify'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(assessmentRepositoryProvider);
      final verifyUseCase = VerifyAssessment(repo);
      final verified = await verifyUseCase(
        assessmentId: _currentAssessment.id,
        expectedVersion: _currentAssessment.version,
        commandId: generateUuid(),
        notes: notesController.text.trim().isEmpty
            ? null
            : notesController.text.trim(),
      );

      setState(() => _currentAssessment = verified);

      GrowthEvent? growthEvent;
      Object? growthError;
      try {
        final vleUseCase = ListVerifiedLearningEvents(repo);
        final vles = await vleUseCase(_currentAssessment.childId);
        final targetVle = vles.cast<VerifiedLearningEvent?>().firstWhere(
          (VerifiedLearningEvent? e) =>
              e?.assessmentId == _currentAssessment.id,
          orElse: () => null,
        );
        if (targetVle != null) {
          final growthRepo = ref.read(growthRepositoryProvider);
          final processGrowth = ProcessVerifiedLearningEvent(growthRepo);
          growthEvent = await processGrowth(
            verifiedLearningEventId: targetVle.id,
            commandId: generateUuid(),
          );
        }
      } catch (err) {
        growthError = err;
      }

      if (mounted) {
        final rpAwarded = growthEvent?.totalRpMinor.formatRp();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              growthEvent != null
                  ? 'Assessment verified successfully! +$rpAwarded RP awarded.'
                  : growthError != null
                  ? 'Assessment verified! Reward calculation is pending catch-up.'
                  : 'Assessment verified successfully!',
            ),
            backgroundColor: growthError != null
                ? Colors.orange.shade800
                : Colors.green,
            action: growthEvent != null
                ? SnackBarAction(
                    label: 'View Details',
                    textColor: Colors.white,
                    onPressed: () {
                      GrowthResultScreen.show(
                        context,
                        growthEvent: growthEvent!,
                      );
                    },
                  )
                : null,
          ),
        );
        context.pop(true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = _mapFriendlyError(e, action: 'verify');
      });
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _rejectAssessment() async {
    final reasonController = TextEditingController();
    String? dialogError;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Reject Assessment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Please provide a feedback note explaining why this submission is being rejected.',
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                key: const Key('rejection_reason_field'),
                controller: reasonController,
                maxLength: 500,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'Reason for rejection * (max 500 chars)',
                  hintText: 'e.g. Score does not match evidence photo',
                  errorText: dialogError,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (dialogError != null) {
                    setDialogState(() => dialogError = null);
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm_reject_button'),
              onPressed: () {
                final text = reasonController.text.trim();
                if (text.isEmpty) {
                  setDialogState(
                    () => dialogError = 'Rejection reason is required.',
                  );
                  return;
                }
                if (text.length > 500) {
                  setDialogState(
                    () =>
                        dialogError = 'Reason must not exceed 500 characters.',
                  );
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Reject'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(assessmentRepositoryProvider);
      final rejectUseCase = RejectAssessment(repo);
      final rejected = await rejectUseCase(
        assessmentId: _currentAssessment.id,
        expectedVersion: _currentAssessment.version,
        commandId: generateUuid(),
        reason: reasonController.text.trim(),
      );

      setState(() => _currentAssessment = rejected);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Assessment was rejected with feedback notes.'),
          ),
        );
        context.pop(true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = _mapFriendlyError(e, action: 'reject');
      });
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  String _mapFriendlyError(Object error, {required String action}) {
    final str = error.toString().toLowerCase();
    if (str.contains('lw101') || str.contains('modified concurrently')) {
      return 'This assessment was updated or already reviewed by another parent. Please reload.';
    }
    if (str.contains('socketexception') ||
        str.contains('clientexception') ||
        str.contains('network') ||
        str.contains('connection')) {
      return 'Network connection issue. Please check your internet connection and try again.';
    }
    if (str.contains('timeout')) {
      return 'The request timed out. Please check your connection and try again.';
    }
    if (str.contains('42501') || str.contains('permission denied')) {
      return 'You do not have permission to review this assessment.';
    }
    if (str.contains('lw106') || str.contains('rejection reason')) {
      return 'A valid rejection reason (up to 500 characters) is required.';
    }
    if (str.contains('lw107') || str.contains('notes')) {
      return 'Verification notes must not exceed 1000 characters.';
    }
    return 'Unable to $action assessment at this time. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = _currentAssessment.score;
    final isPending =
        _currentAssessment.status == AssessmentStatus.pendingReview;

    return Scaffold(
      appBar: AppBar(title: const Text('Review Assessment')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_errorMessage != null) ...[
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Wrap(
                                spacing: AppSpacing.xs,
                                children: [
                                  Chip(
                                    label: Text(
                                      _currentAssessment
                                          .subjectKey
                                          .displayLabel,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  Chip(
                                    label: Text(
                                      _currentAssessment.type.name
                                          .toUpperCase(),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                              Chip(
                                label: Text(
                                  _currentAssessment.status.value.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color:
                                        _currentAssessment.status ==
                                            AssessmentStatus.verified
                                        ? Colors.green
                                        : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            _currentAssessment.title,
                            style: theme.textTheme.headlineSmall,
                          ),
                          Text(
                            _currentAssessment.subject,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                          const Divider(height: AppSpacing.xl),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              Column(
                                children: [
                                  const Text(
                                    'Raw Score',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    '${score.rawScore} / ${score.maxScore}',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              Column(
                                children: [
                                  const Text(
                                    'Normalized Score',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  Text(
                                    '${score.serverNormalizedScore} / 10',
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // Evidence section
                  Card(
                    elevation: 0,
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.photo_library_outlined, size: 20),
                              SizedBox(width: AppSpacing.sm),
                              Text(
                                'Attached Evidence',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          if (_isLoadingEvidence)
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.all(AppSpacing.md),
                                child: CircularProgressIndicator(),
                              ),
                            )
                          else if (_evidenceList.isEmpty)
                            const Text(
                              'No photo evidence attached.',
                              style: TextStyle(fontSize: 13),
                            )
                          else
                            ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _evidenceList.length,
                              itemBuilder: (ctx, i) {
                                final ev = _evidenceList[i];
                                return _EvidencePreviewItem(evidence: ev);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  if (isPending) ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('reject_assessment_button'),
                            onPressed: _isProcessing ? null : _rejectAssessment,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: theme.colorScheme.error,
                            ),
                            child: const Text('Reject'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: FilledButton(
                            key: const Key('verify_assessment_button'),
                            onPressed: _isProcessing ? null : _verifyAssessment,
                            child: _isProcessing
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Verify Result'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvidencePreviewItem extends ConsumerStatefulWidget {
  const _EvidencePreviewItem({required this.evidence});

  final AssessmentEvidence evidence;

  @override
  ConsumerState<_EvidencePreviewItem> createState() =>
      _EvidencePreviewItemState();
}

class _EvidencePreviewItemState extends ConsumerState<_EvidencePreviewItem> {
  String? _signedUrl;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSignedUrl();
  }

  Future<void> _loadSignedUrl() async {
    try {
      final storage = ref.read(assessmentEvidenceStorageProvider);
      final url = await storage.getEvidenceSignedUrl(
        storagePath: widget.evidence.storagePath,
        expiresIn: const Duration(minutes: 10),
      );
      if (mounted) {
        setState(() {
          _signedUrl = url;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileName = widget.evidence.storagePath.split('/').last;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.photo, size: 18),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    fileName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${(widget.evidence.fileSizeBytes / 1024).toStringAsFixed(1)} KB',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            if (_isLoading)
              const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_signedUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  _signedUrl!,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.contain,
                  errorBuilder: (ctx, err, stack) => Container(
                    height: 100,
                    color: theme.colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.image, size: 32, color: Colors.grey),
                        const SizedBox(height: 4),
                        Text(fileName, style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                  loadingBuilder: (ctx, child, progress) {
                    if (progress == null) return child;
                    return const SizedBox(
                      height: 120,
                      child: Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  },
                ),
              )
            else
              Container(
                height: 60,
                color: theme.colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: const Text(
                  'Preview unavailable',
                  style: TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
