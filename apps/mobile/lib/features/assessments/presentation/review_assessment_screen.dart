import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/utils/uuid_generator.dart';

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
              'This will generate an immutable learning accomplishment record.',
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const Key('verification_notes_field'),
              controller: notesController,
              decoration: const InputDecoration(
                labelText: 'Approval Notes (Optional)',
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

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Assessment verified successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        context.pop(true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to verify: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _rejectAssessment() async {
    final reasonController = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
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
              decoration: const InputDecoration(
                labelText: 'Reason for rejection *',
                hintText: 'e.g. Score does not match evidence photo',
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
            key: const Key('confirm_reject_button'),
            onPressed: () {
              if (reasonController.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            },
            child: const Text('Reject'),
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
        _errorMessage = 'Failed to reject: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
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
                              Chip(
                                label: Text(
                                  _currentAssessment.type.name.toUpperCase(),
                                  style: const TextStyle(fontSize: 12),
                                ),
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
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.image),
                                  title: Text(
                                    ev.storagePath.split('/').last,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${ev.mediaType} • ${(ev.fileSizeBytes / 1024).toStringAsFixed(1)} KB',
                                  ),
                                );
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
