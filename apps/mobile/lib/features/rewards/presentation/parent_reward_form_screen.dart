import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:learnward_application/learnward_application.dart';
import 'package:learnward_design_system/learnward_design_system.dart';
import 'package:learnward_domain/learnward_domain.dart';

import '../../../app/bootstrap/app_providers.dart';

/// Screen allowing parents to create or edit a family reward.
class ParentRewardFormScreen extends ConsumerStatefulWidget {
  const ParentRewardFormScreen({super.key, this.rewardToEdit});

  final Reward? rewardToEdit;

  @override
  ConsumerState<ParentRewardFormScreen> createState() =>
      _ParentRewardFormScreenState();
}

class _ParentRewardFormScreenState
    extends ConsumerState<ParentRewardFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  late TextEditingController _costRpController;

  RewardCategory _selectedCategory = RewardCategory.privilege;
  bool _storeEnabled = true;
  bool _wheelEnabled = false;
  WheelTier _selectedWheelTier = WheelTier.common;
  String? _selectedTargetChildId;
  List<ChildProfile> _familyChildren = [];
  bool _isSaving = false;
  String? _saveErrorMessage;

  @override
  void initState() {
    super.initState();
    final r = widget.rewardToEdit;
    _titleController = TextEditingController(text: r?.title ?? '');
    _descriptionController = TextEditingController(text: r?.description ?? '');
    _costRpController = TextEditingController(
      text: r?.storeCostRp != null
          ? (r!.storeCostRp! == r.storeCostRp!.roundToDouble()
                ? r.storeCostRp!.toInt().toString()
                : r.storeCostRp!.toString())
          : '10',
    );
    if (r != null) {
      _selectedCategory = r.category;
      _storeEnabled = r.storeEnabled;
      _wheelEnabled = r.wheelEnabled;
      _selectedWheelTier = r.wheelTier ?? WheelTier.common;
      _selectedTargetChildId = r.targetChildId?.value;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _loadChildren());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _costRpController.dispose();
    super.dispose();
  }

  Future<void> _loadChildren() async {
    final family = ref.read(activeFamilyProvider);
    if (family == null) return;
    try {
      final childRepo = ref.read(childProfileRepositoryProvider);
      final listChildren = ListFamilyChildren(childRepo);
      final children = await listChildren(family.id);
      if (mounted) {
        setState(() {
          _familyChildren = children;
        });
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final family = ref.read(activeFamilyProvider);
    if (family == null) return;

    setState(() {
      _isSaving = true;
      _saveErrorMessage = null;
    });

    try {
      final costRp = double.tryParse(_costRpController.text.trim()) ?? 10.0;
      final costMinor = (costRp * 100).round();
      final targetChild = _selectedTargetChildId != null
          ? ChildId(_selectedTargetChildId!)
          : null;

      final rewardRepo = ref.read(rewardRepositoryProvider);

      if (widget.rewardToEdit != null) {
        final updated = widget.rewardToEdit!.copyWith(
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          category: _selectedCategory,
          storeEnabled: _storeEnabled,
          storeCostMinor: _storeEnabled ? costMinor : null,
          wheelEnabled: _wheelEnabled,
          wheelTier: _wheelEnabled ? _selectedWheelTier : null,
          targetChildId: targetChild,
        );
        final updateUseCase = UpdateReward(rewardRepo);
        await updateUseCase(updated);
      } else {
        final createUseCase = CreateReward(rewardRepo);
        await createUseCase(
          familyId: family.id,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          category: _selectedCategory,
          storeEnabled: _storeEnabled,
          storeCostMinor: _storeEnabled ? costMinor : null,
          wheelEnabled: _wheelEnabled,
          wheelTier: _wheelEnabled ? _selectedWheelTier : null,
          targetChildId: targetChild,
        );
      }

      if (mounted) {
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saveErrorMessage = e.toString();
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEditing = widget.rewardToEdit != null;

    return Scaffold(
      appBar: AppBar(title: Text(isEditing ? 'Edit Reward' : 'Create Reward')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_saveErrorMessage != null) ...[
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      child: Text(
                        _saveErrorMessage!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                TextFormField(
                  key: const Key('reward_title_field'),
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Reward Title *',
                    hintText: 'e.g. 30 Minutes Extra Gaming',
                    border: OutlineInputBorder(),
                  ),
                  maxLength: 100,
                  validator: (value) {
                    final trimmed = (value ?? '').trim();
                    if (trimmed.length < 2) {
                      return 'Title must be at least 2 characters';
                    }
                    if (trimmed.length > 100) {
                      return 'Title cannot exceed 100 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  key: const Key('reward_description_field'),
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description / Terms (Optional)',
                    hintText: 'e.g. Applies on weekend afternoons only',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                  maxLength: 500,
                ),
                const SizedBox(height: AppSpacing.sm),
                DropdownButtonFormField<RewardCategory>(
                  key: const Key('reward_category_dropdown'),
                  initialValue: _selectedCategory,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    border: OutlineInputBorder(),
                  ),
                  items: RewardCategory.values.map((cat) {
                    return DropdownMenuItem(
                      value: cat,
                      child: Text(cat.displayName),
                    );
                  }).toList(),
                  onChanged: (cat) {
                    if (cat != null) {
                      setState(() {
                        _selectedCategory = cat;
                      });
                    }
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                SwitchListTile(
                  key: const Key('store_enabled_switch'),
                  title: const Text('Available in Reward Store'),
                  subtitle: const Text(
                    'Children can save up and redeem directly',
                  ),
                  value: _storeEnabled,
                  onChanged: (val) {
                    setState(() {
                      _storeEnabled = val;
                    });
                  },
                ),
                if (_storeEnabled) ...[
                  const SizedBox(height: AppSpacing.sm),
                  TextFormField(
                    key: const Key('reward_cost_field'),
                    controller: _costRpController,
                    decoration: const InputDecoration(
                      labelText: 'Store Cost in Reward Points (RP) *',
                      hintText: 'e.g. 10 or 25',
                      prefixIcon: Icon(Icons.stars),
                      suffixText: 'RP',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*\.?\d{0,2}'),
                      ),
                    ],
                    validator: (val) {
                      if (!_storeEnabled) return null;
                      final numVal = double.tryParse(val ?? '');
                      if (numVal == null || numVal <= 0) {
                        return 'Enter a positive RP cost (e.g. 10)';
                      }
                      return null;
                    },
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                DropdownButtonFormField<String?>(
                  key: const Key('target_child_dropdown'),
                  initialValue: _selectedTargetChildId,
                  decoration: const InputDecoration(
                    labelText: 'Eligible Child',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All Children in Family'),
                    ),
                    ..._familyChildren.map((c) {
                      return DropdownMenuItem(
                        value: c.id.value,
                        child: Text(c.displayName),
                      );
                    }),
                  ],
                  onChanged: (val) {
                    setState(() {
                      _selectedTargetChildId = val;
                    });
                  },
                ),
                const SizedBox(height: AppSpacing.md),
                SwitchListTile(
                  key: const Key('reward_wheel_enabled_switch'),
                  title: const Text('Available on Celebration Wheel'),
                  subtitle: const Text(
                    'Can be won by children spinning the Celebration Wheel',
                  ),
                  value: _wheelEnabled,
                  onChanged: (val) => setState(() => _wheelEnabled = val),
                ),
                if (_wheelEnabled) ...[
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<WheelTier>(
                    key: const Key('reward_wheel_tier_dropdown'),
                    initialValue: _selectedWheelTier,
                    decoration: const InputDecoration(
                      labelText: 'Wheel Tier & Weight *',
                      border: OutlineInputBorder(),
                    ),
                    items: WheelTier.values.map((tier) {
                      return DropdownMenuItem(
                        value: tier,
                        child: Text(
                          '${tier.displayName} (Weight: ${tier.relativeWeight})',
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedWheelTier = val);
                    },
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                FilledButton.icon(
                  key: const Key('save_reward_button'),
                  onPressed: _isSaving ? null : _save,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(isEditing ? 'Save Changes' : 'Create Reward'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
