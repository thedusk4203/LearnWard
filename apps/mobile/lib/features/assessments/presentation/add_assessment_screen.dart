import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/utils/uuid_generator.dart';
import 'evidence_picker_service.dart';

/// Screen where a learner captures an academic result, attaches evidence,
/// and either saves a local draft or submits for parent review.
class AddAssessmentScreen extends ConsumerStatefulWidget {
  const AddAssessmentScreen({super.key});

  @override
  ConsumerState<AddAssessmentScreen> createState() =>
      _AddAssessmentScreenState();
}

class _AddAssessmentScreenState extends ConsumerState<AddAssessmentScreen> {
  final _formKey = GlobalKey<FormState>();

  final _subjectController = TextEditingController(text: 'Mathematics');
  final _titleController = TextEditingController();
  final _rawScoreController = TextEditingController();
  final _maxScoreController = TextEditingController(text: '10');

  AssessmentType _selectedType = AssessmentType.quiz;
  AssessmentDifficulty _selectedDifficulty = AssessmentDifficulty.normal;
  final DateTime _occurredAt = DateTime.now();
  SelectedEvidenceFile? _selectedEvidence;

  bool _isSubmitting = false;
  String? _errorMessage;
  double? _liveNormalizedScore;

  @override
  void initState() {
    super.initState();
    _rawScoreController.addListener(_updateScorePreview);
    _maxScoreController.addListener(_updateScorePreview);
  }

  @override
  void dispose() {
    _rawScoreController.dispose();
    _maxScoreController.dispose();
    _subjectController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _updateScorePreview() {
    final raw = double.tryParse(_rawScoreController.text.trim());
    final max = double.tryParse(_maxScoreController.text.trim());
    if (raw != null && max != null && max > 0 && raw >= 0 && raw <= max) {
      setState(() {
        _liveNormalizedScore = ((raw / max * 10.0) * 100).round() / 100.0;
      });
    } else {
      setState(() {
        _liveNormalizedScore = null;
      });
    }
  }

  Future<void> _pickEvidence() async {
    final picker = ref.read(evidencePickerServiceProvider);
    final file = await picker.pickEvidencePhoto();
    if (file != null) {
      setState(() {
        _selectedEvidence = file;
      });
    }
  }

  Future<void> _saveLocalDraft() async {
    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) return;

    final raw = double.tryParse(_rawScoreController.text.trim()) ?? 0.0;
    final max = double.tryParse(_maxScoreController.text.trim()) ?? 10.0;

    final draft = LocalAssessmentDraft(
      localDraftId: generateUuid(),
      familyId: activeChild.familyId.value,
      childId: activeChild.id.value,
      subject: _subjectController.text.trim(),
      title: _titleController.text.trim().isEmpty
          ? 'Draft Assessment'
          : _titleController.text.trim(),
      assessmentType: _selectedType.value,
      difficulty: _selectedDifficulty.value,
      rawScore: raw,
      maxScore: max,
      localPhotoPath: _selectedEvidence?.localPath,
      occurredAt: _occurredAt,
      updatedAt: DateTime.now().toUtc(),
    );

    final store = ref.read(localDraftStoreProvider);
    await store.saveLocalDraft(draft);

    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Draft saved locally.')));
    }
  }

  Future<void> _submitAssessment() async {
    if (!_formKey.currentState!.validate()) return;

    final activeChild = ref.read(activeChildModeProvider);
    if (activeChild == null) {
      setState(() => _errorMessage = 'No active child session');
      return;
    }

    final raw = double.parse(_rawScoreController.text.trim());
    final max = double.parse(_maxScoreController.text.trim());

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final repo = ref.read(assessmentRepositoryProvider);
      final storage = ref.read(assessmentEvidenceStorageProvider);

      // 1. Create Server Draft
      final createDraft = CreateAssessmentDraft(repo);
      final draft = await createDraft(
        familyId: activeChild.familyId,
        childId: activeChild.id,
        subject: _subjectController.text.trim(),
        title: _titleController.text.trim(),
        type: _selectedType,
        difficulty: _selectedDifficulty,
        score: AssessmentScore(rawScore: raw, maxScore: max),
        occurredAt: _occurredAt,
      );

      // 2. Attach Evidence if selected
      if (_selectedEvidence != null) {
        final uploadUseCase = UploadAssessmentEvidence(
          repository: repo,
          storage: storage,
        );
        await uploadUseCase(
          familyId: activeChild.familyId,
          childId: activeChild.id,
          assessmentId: draft.id,
          fileName: _selectedEvidence!.fileName,
          bytes: _selectedEvidence!.bytes,
          mediaType: _selectedEvidence!.mediaType,
        );
      }

      // 3. Submit for Review with unique commandId
      final submitUseCase = SubmitAssessment(repo);
      await submitUseCase(
        assessmentId: draft.id,
        expectedVersion: draft.version,
        commandId: generateUuid(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Assessment submitted for review!'),
            backgroundColor: Colors.green,
          ),
        );
        context.pop(true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to submit: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Add Assessment Result')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
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
                    TextFormField(
                      key: const Key('assessment_subject_field'),
                      controller: _subjectController,
                      decoration: const InputDecoration(
                        labelText: 'Subject *',
                        hintText: 'e.g. Mathematics, English, Science',
                        prefixIcon: Icon(Icons.menu_book),
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) => (val == null || val.trim().isEmpty)
                          ? 'Subject is required'
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      key: const Key('assessment_title_field'),
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: 'Assessment Title *',
                        hintText: 'e.g. Fractions Chapter Quiz, Essay 1',
                        prefixIcon: Icon(Icons.assignment),
                        border: OutlineInputBorder(),
                      ),
                      validator: (val) => (val == null || val.trim().isEmpty)
                          ? 'Title is required'
                          : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<AssessmentType>(
                            key: const Key('assessment_type_dropdown'),
                            initialValue: _selectedType,
                            decoration: const InputDecoration(
                              labelText: 'Type',
                              border: OutlineInputBorder(),
                            ),
                            items: AssessmentType.values
                                .map(
                                  (t) => DropdownMenuItem(
                                    value: t,
                                    child: Text(t.name.toUpperCase()),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedType = val);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: DropdownButtonFormField<AssessmentDifficulty>(
                            key: const Key('assessment_difficulty_dropdown'),
                            initialValue: _selectedDifficulty,
                            decoration: const InputDecoration(
                              labelText: 'Difficulty',
                              border: OutlineInputBorder(),
                            ),
                            items: AssessmentDifficulty.values
                                .map(
                                  (d) => DropdownMenuItem(
                                    value: d,
                                    child: Text(d.name),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                setState(() => _selectedDifficulty = val);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            key: const Key('assessment_raw_score_field'),
                            controller: _rawScoreController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Score *',
                              hintText: 'e.g. 8.5',
                              border: OutlineInputBorder(),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Required';
                              }
                              final numVal = double.tryParse(val.trim());
                              if (numVal == null || numVal < 0) {
                                return 'Invalid score';
                              }
                              final maxVal = double.tryParse(
                                _maxScoreController.text.trim(),
                              );
                              if (maxVal != null && numVal > maxVal) {
                                return 'Score > Max';
                              }
                              return null;
                            },
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                          ),
                          child: Text('/', style: TextStyle(fontSize: 24)),
                        ),
                        Expanded(
                          child: TextFormField(
                            key: const Key('assessment_max_score_field'),
                            controller: _maxScoreController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Out Of *',
                              hintText: 'e.g. 10',
                              border: OutlineInputBorder(),
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Required';
                              }
                              final numVal = double.tryParse(val.trim());
                              if (numVal == null || numVal <= 0) {
                                return 'Must be > 0';
                              }
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    if (_liveNormalizedScore != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer.withValues(
                            alpha: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.trending_up,
                              size: 20,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              'Normalized Score: ${_liveNormalizedScore!.toStringAsFixed(2)} / 10.0',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    // Evidence Photo Attachment Section
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
                                Icon(Icons.camera_alt_outlined, size: 20),
                                SizedBox(width: AppSpacing.sm),
                                Text(
                                  'Photo Evidence (Optional)',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            const Text(
                              'Attach a clear photo or worksheet scan for parent verification.',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            if (_selectedEvidence != null)
                              Row(
                                children: [
                                  const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                    size: 18,
                                  ),
                                  const SizedBox(width: AppSpacing.xs),
                                  Expanded(
                                    child: Text(
                                      '${_selectedEvidence!.fileName} (${(_selectedEvidence!.bytes.length / 1024).toStringAsFixed(1)} KB)',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () {
                                      setState(() => _selectedEvidence = null);
                                    },
                                  ),
                                ],
                              )
                            else
                              OutlinedButton.icon(
                                key: const Key('attach_evidence_button'),
                                icon: const Icon(Icons.add_a_photo),
                                label: const Text('Attach Photo'),
                                onPressed: _pickEvidence,
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('save_draft_button'),
                            onPressed: _isSubmitting ? null : _saveLocalDraft,
                            child: const Text('Save Local Draft'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: FilledButton(
                            key: const Key('submit_assessment_button'),
                            onPressed: _isSubmitting ? null : _submitAssessment,
                            child: _isSubmitting
                                ? const SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Submit for Review'),
                          ),
                        ),
                      ],
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
