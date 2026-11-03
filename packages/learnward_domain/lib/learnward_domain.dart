/// LearnWard domain library.
///
/// Contains pure Dart entities, value objects and deterministic rules.
/// Must never import Flutter, Riverpod, Drift, Supabase or platform plugins.
library;

export 'src/entities/assessment.dart';
export 'src/entities/assessment_evidence.dart';
export 'src/entities/child_balance.dart';
export 'src/entities/child_profile.dart';
export 'src/entities/family.dart';
export 'src/entities/growth_event.dart';
export 'src/entities/ledger_entry.dart';
export 'src/entities/reward.dart';
export 'src/entities/reward_redemption.dart';
export 'src/entities/verified_learning_event.dart';
export 'src/entities/wheel_settings.dart';
export 'src/entities/wheel_spin.dart';
export 'src/exceptions/domain_exceptions.dart';
export 'src/growth/comparable_result.dart';
export 'src/growth/growth_breakdown.dart';
export 'src/growth/growth_engine.dart';
export 'src/growth/growth_input.dart';
export 'src/growth/growth_result.dart';
export 'src/learning/confidence_engine.dart';
export 'src/learning/learning_enums.dart';
export 'src/learning/learning_models.dart';
export 'src/learning/mastery_engine.dart';
export 'src/value_objects/assessment_enums.dart';
export 'src/value_objects/assessment_score.dart';
export 'src/value_objects/entry_context.dart';
export 'src/value_objects/identifiers.dart';
export 'src/value_objects/normalized_score.dart';
export 'src/value_objects/reward_enums.dart';
export 'src/value_objects/rp_minor.dart';
export 'src/value_objects/subject_key.dart';
export 'src/value_objects/wheel_models.dart';
export 'src/value_objects/xp_amount.dart';
