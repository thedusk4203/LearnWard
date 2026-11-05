begin;
select plan(104);

-- ---------------------------------------------------------------------------
-- SECTION 0: TEST FIXTURES SETUP (superuser context)
-- ---------------------------------------------------------------------------

-- Auth Users:
-- 1. Family A Adult (Owner): 90000000-0000-0000-0000-000000000001
-- 2. Family A Active Child Device: 90000000-0000-0000-0000-000000000002
-- 3. Family A Archived Child Device: 90000000-0000-0000-0000-000000000003
-- 4. Family B Foreign Adult (Owner): 90000000-0000-0000-0000-000000000004
-- 5. Family B Foreign Child Device: 90000000-0000-0000-0000-000000000005
insert into auth.users (id, aud, role, email) values
  ('90000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'fam_a_owner@test.com'),
  ('90000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'fam_a_child1_dev@test.com'),
  ('90000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'fam_a_child2_dev@test.com'),
  ('90000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'fam_b_owner@test.com'),
  ('90000000-0000-0000-0000-000000000005'::uuid, 'authenticated', 'authenticated', 'fam_b_child3_dev@test.com')
on conflict (id) do nothing;

-- Families:
-- Family A: 90000001-0000-0000-0000-000000000001
-- Family B: 90000001-0000-0000-0000-000000000002
insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('90000001-0000-0000-0000-000000000001'::uuid, 'Phase 6 Family A', 'America/New_York', 'en_US', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000001-0000-0000-0000-000000000002'::uuid, 'Phase 6 Family B', 'America/Chicago', 'en_US', '90000000-0000-0000-0000-000000000004'::uuid)
on conflict (id) do nothing;

-- Memberships:
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('90000001-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('90000001-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000004'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

-- Children:
-- Child 1: Family A Active Child
-- Child 2: Family A Archived Child (atomically pseudonymized per Tier 3)
-- Child 3: Family B Active Child
insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year, avatar_key, status, archived_at) values
  ('90000002-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Active Child', 4, 2016, 'star_gold', 'active', null),
  ('90000002-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '[Archived Learner]', null, null, null, 'archived', now() - interval '1 day'),
  ('90000002-0000-0000-0000-000000000003'::uuid, '90000001-0000-0000-0000-000000000002'::uuid, 'Foreign Child', 5, 2015, 'shield_blue', 'active', null)
on conflict (id) do nothing;

-- Device Grants:
-- Grant 1: Active child device grant for Active Child 1
-- Grant 2: Active child device grant row for Archived Child 2 (testing still-active grant row on archived child)
-- Grant 3: Active child device grant for Foreign Child 3
insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('90000003-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000002'::uuid, 'active', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000003-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000003'::uuid, 'active', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000003-0000-0000-0000-000000000003'::uuid, '90000001-0000-0000-0000-000000000002'::uuid, '90000002-0000-0000-0000-000000000003'::uuid, '90000000-0000-0000-0000-000000000005'::uuid, 'active', '90000000-0000-0000-0000-000000000004'::uuid)
on conflict (id) do nothing;

-- Wheel Settings:
insert into public.family_wheel_settings (family_id, spin_cost_minor, daily_spin_cap, is_enabled) values
  ('90000001-0000-0000-0000-000000000001'::uuid, 1000, 3, true),
  ('90000001-0000-0000-0000-000000000002'::uuid, 1000, 3, true)
on conflict (family_id) do nothing;

-- Rewards:
insert into public.rewards (id, family_id, title, category, store_cost_minor, is_active, store_enabled, wheel_enabled, wheel_tier, target_child_id) values
  ('90000005-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Family Pizza Night', 'treat', 1000, true, true, true, 'common', null),
  ('90000005-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Active Child Book', 'item', 500, true, true, true, 'common', '90000002-0000-0000-0000-000000000001'::uuid),
  ('90000005-0000-0000-0000-000000000003'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Archived Child Legacy Reward', 'treat', 750, true, true, true, 'common', '90000002-0000-0000-0000-000000000002'::uuid),
  ('90000005-0000-0000-0000-000000000004'::uuid, '90000001-0000-0000-0000-000000000002'::uuid, 'Foreign Reward', 'item', 500, true, true, true, 'common', '90000002-0000-0000-0000-000000000003'::uuid)
on conflict (id) do nothing;

-- Assessments: Insert in draft status so evidence can be registered before terminal transition
insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id) values
  ('90000006-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Active Quiz', 'quiz', 'normal', 10, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000006-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Archived Quiz', 'quiz', 'normal', 10, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000006-0000-0000-0000-000000000003'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Active Draft', 'quiz', 'normal', 8, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000006-0000-0000-0000-000000000004'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Archived Draft', 'quiz', 'normal', 8, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000006-0000-0000-0000-000000000005'::uuid, '90000001-0000-0000-0000-000000000002'::uuid, '90000002-0000-0000-0000-000000000003'::uuid, 'math', 'Math', 'Foreign Quiz', 'quiz', 'normal', 10, 10, 'draft', '90000000-0000-0000-0000-000000000004'::uuid)
on conflict (id) do nothing;

-- Assessment Evidence (attached while assessments are draft)
insert into public.assessment_evidence (id, assessment_id, family_id, storage_path, media_type, file_size_bytes, uploaded_by_user_id) values
  ('90000007-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001/90000002-0000-0000-0000-000000000001/90000006-0000-0000-0000-000000000001/e0000000-0000-0000-0000-000000000001.jpg', 'image/jpeg', 1024, '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000007-0000-0000-0000-000000000002'::uuid, '90000006-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001/90000002-0000-0000-0000-000000000002/90000006-0000-0000-0000-000000000002/e0000000-0000-0000-0000-000000000002.jpg', 'image/jpeg', 1024, '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000007-0000-0000-0000-000000000005'::uuid, '90000006-0000-0000-0000-000000000005'::uuid, '90000001-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000002/90000002-0000-0000-0000-000000000003/90000006-0000-0000-0000-000000000005/e0000000-0000-0000-0000-000000000005.jpg', 'image/jpeg', 1024, '90000000-0000-0000-0000-000000000004'::uuid)
on conflict (id) do nothing;

-- Transition assessments 1, 2, 5 to verified status
update public.assessments
set status = 'verified'
where id in (
  '90000006-0000-0000-0000-000000000001'::uuid,
  '90000006-0000-0000-0000-000000000002'::uuid,
  '90000006-0000-0000-0000-000000000005'::uuid
);

-- Command Receipts:
insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id) values
  ('90000008-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'verify', '90000006-0000-0000-0000-000000000001'::uuid),
  ('90000008-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'verify', '90000006-0000-0000-0000-000000000002'::uuid),
  ('90000008-0000-0000-0000-000000000005'::uuid, '90000001-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000004'::uuid, 'verify', '90000006-0000-0000-0000-000000000005'::uuid)
on conflict (command_id) do nothing;

-- Assessment Review Events:
insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id, review_notes) values
  ('90000009-0000-0000-0000-000000000001'::uuid, '90000008-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000001'::uuid, 'verified', 'submitted', 'verified', '90000000-0000-0000-0000-000000000001'::uuid, 'Great job!'),
  ('90000009-0000-0000-0000-000000000002'::uuid, '90000008-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000002'::uuid, 'verified', 'submitted', 'verified', '90000000-0000-0000-0000-000000000001'::uuid, 'Archived historical review')
on conflict (id) do nothing;

-- Verified Learning Events (VLE):
insert into public.verified_learning_events (id, assessment_id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id) values
  ('9000000a-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Active Quiz', 'quiz', 'normal', 10, 10, 10.0, now(), '90000000-0000-0000-0000-000000000001'::uuid, '90000009-0000-0000-0000-000000000001'::uuid),
  ('9000000a-0000-0000-0000-000000000002'::uuid, '90000006-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Archived Quiz', 'quiz', 'normal', 10, 10, 10.0, now(), '90000000-0000-0000-0000-000000000001'::uuid, '90000009-0000-0000-0000-000000000002'::uuid)
on conflict (id) do nothing;

-- Growth Events & Ledgers:
insert into public.growth_events (id, family_id, child_id, verified_learning_event_id, assessment_id, engine_version, normalized_score, score_rp_minor, total_rp_minor, xp_awarded, inputs_snapshot) values
  ('9000000b-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, '9000000a-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000001'::uuid, 'growth-v0.1', 10.0, 100, 100, 50, '{}'::jsonb),
  ('9000000b-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, '9000000a-0000-0000-0000-000000000002'::uuid, '90000006-0000-0000-0000-000000000002'::uuid, 'growth-v0.1', 10.0, 100, 100, 50, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.xp_ledger (id, family_id, child_id, amount, reason_code, source_type, idempotency_key) values
  ('9000000c-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 50, 'assessment_earned', 'growth_event', 'xp_key_1'),
  ('9000000c-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 50, 'assessment_earned', 'growth_event', 'xp_key_2')
on conflict (id) do nothing;

insert into public.rp_ledger (id, family_id, child_id, amount_minor, reason_code, source_type, idempotency_key) values
  ('9000000d-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 100, 'assessment_earned', 'growth_event', 'rp_key_1'),
  ('9000000d-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 100, 'assessment_earned', 'growth_event', 'rp_key_2')
on conflict (id) do nothing;

insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor) values
  ('90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 50, 100),
  ('90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 50, 100)
on conflict (child_id) do nothing;

insert into public.reward_redemptions (id, family_id, child_id, reward_id, origin, rp_cost_minor, status, reward_snapshot) values
  ('9000000e-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, '90000005-0000-0000-0000-000000000001'::uuid, 'wheel', 1000, 'pending_fulfillment', '{"title": "Pizza"}'::jsonb),
  ('9000000e-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, '90000005-0000-0000-0000-000000000001'::uuid, 'wheel', 1000, 'pending_fulfillment', '{"title": "Pizza"}'::jsonb)
on conflict (id) do nothing;

insert into public.wheel_spins (id, family_id, child_id, reward_id, redemption_id, origin, spin_cost_minor, selection_snapshot) values
  ('9000000f-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, '90000005-0000-0000-0000-000000000001'::uuid, '9000000e-0000-0000-0000-000000000001'::uuid, 'wheel', 1000, '{"result": "reward"}'::jsonb),
  ('9000000f-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, '90000005-0000-0000-0000-000000000001'::uuid, '9000000e-0000-0000-0000-000000000002'::uuid, 'wheel', 1000, '{"result": "reward"}'::jsonb)
on conflict (id) do nothing;

-- Learning Mastery fixtures:
insert into public.assessment_learning_mappings (
  assessment_id, learning_node_id, component_key, family_id, child_id, score_source, confirmed_by_user_id
) values (
  '90000006-0000-0000-0000-000000000001'::uuid,
  'b0000001-0000-0000-0000-000000000001'::uuid,
  'assessment_total',
  '90000001-0000-0000-0000-000000000001'::uuid,
  '90000002-0000-0000-0000-000000000001'::uuid,
  'assessment_total',
  '90000000-0000-0000-0000-000000000001'::uuid
), (
  '90000006-0000-0000-0000-000000000002'::uuid,
  'b0000001-0000-0000-0000-000000000001'::uuid,
  'assessment_total',
  '90000001-0000-0000-0000-000000000001'::uuid,
  '90000002-0000-0000-0000-000000000002'::uuid,
  'assessment_total',
  '90000000-0000-0000-0000-000000000001'::uuid
) on conflict (assessment_id, learning_node_id, component_key) do nothing;

insert into public.learning_evidence_events (
  id, family_id, child_id, verified_learning_event_id, assessment_id, learning_node_id,
  catalog_version, node_type, subject_key, grade_level_snapshot, assessment_type,
  difficulty, score_source, performance_pct, specificity_weight, level_weight,
  item_count, correct_count, occurred_at, effective_occurred_at, verified_at
) values (
  '90000010-0000-0000-0000-000000000001'::uuid,
  '90000001-0000-0000-0000-000000000001'::uuid,
  '90000002-0000-0000-0000-000000000001'::uuid,
  '9000000a-0000-0000-0000-000000000001'::uuid,
  '90000006-0000-0000-0000-000000000001'::uuid,
  'b0000001-0000-0000-0000-000000000001'::uuid,
  'pilot-v0.1', 'domain', 'math', 4, 'quiz',
  'normal', 'assessment_total', 100.00, 1.00, 1.00,
  null, null,
  now(), now(), now()
), (
  '90000010-0000-0000-0000-000000000002'::uuid,
  '90000001-0000-0000-0000-000000000001'::uuid,
  '90000002-0000-0000-0000-000000000002'::uuid,
  '9000000a-0000-0000-0000-000000000002'::uuid,
  '90000006-0000-0000-0000-000000000002'::uuid,
  'b0000001-0000-0000-0000-000000000001'::uuid,
  'pilot-v0.1', 'domain', 'math', 4, 'quiz',
  'normal', 'assessment_total', 100.00, 1.00, 1.00,
  null, null,
  now(), now(), now()
) on conflict (id) do nothing;

insert into public.mastery_state_revisions (
  id, family_id, child_id, learning_node_id, trigger_verified_learning_event_id, engine_version,
  previous_mastery_score, new_mastery_score, effective_evidence_count,
  latest_evidence_at, mastery_attained_at, calculation_snapshot, created_at
) values (
  '90000011-0000-0000-0000-000000000001'::uuid,
  '90000001-0000-0000-0000-000000000001'::uuid,
  '90000002-0000-0000-0000-000000000001'::uuid,
  'b0000001-0000-0000-0000-000000000001'::uuid,
  '9000000a-0000-0000-0000-000000000001'::uuid,
  'mastery-v0.1', null, 85.00, 1,
  now(), null, '{}'::jsonb, now()
), (
  '90000011-0000-0000-0000-000000000002'::uuid,
  '90000001-0000-0000-0000-000000000001'::uuid,
  '90000002-0000-0000-0000-000000000002'::uuid,
  'b0000001-0000-0000-0000-000000000001'::uuid,
  '9000000a-0000-0000-0000-000000000002'::uuid,
  'mastery-v0.1', null, 85.00, 1,
  now(), null, '{}'::jsonb, now()
) on conflict (id) do nothing;

insert into public.child_mastery_states (
  child_id, learning_node_id, family_id, engine_version, mastery_score,
  effective_evidence_count, distinct_assessment_count, last_evidence_event_id,
  last_evidence_occurred_at, last_verified_at, latest_revision_id, mastery_attained_at, updated_at
) values (
  '90000002-0000-0000-0000-000000000001'::uuid,
  'b0000001-0000-0000-0000-000000000001'::uuid,
  '90000001-0000-0000-0000-000000000001'::uuid,
  'mastery-v0.1', 85.00, 1, 1, '90000010-0000-0000-0000-000000000001'::uuid,
  now(), now(), '90000011-0000-0000-0000-000000000001'::uuid, null, now()
), (
  '90000002-0000-0000-0000-000000000002'::uuid,
  'b0000001-0000-0000-0000-000000000001'::uuid,
  '90000001-0000-0000-0000-000000000001'::uuid,
  'mastery-v0.1', 85.00, 1, 1, '90000010-0000-0000-0000-000000000002'::uuid,
  now(), now(), '90000011-0000-0000-0000-000000000002'::uuid, null, now()
) on conflict (child_id, learning_node_id) do nothing;

insert into public.learning_processing_events (
  id, verified_learning_event_id, assessment_id, family_id, child_id, evidence_count, affected_node_ids, status
) values (
  '90000012-0000-0000-0000-000000000001'::uuid,
  '9000000a-0000-0000-0000-000000000001'::uuid,
  '90000006-0000-0000-0000-000000000001'::uuid,
  '90000001-0000-0000-0000-000000000001'::uuid,
  '90000002-0000-0000-0000-000000000001'::uuid,
  1, ARRAY['b0000001-0000-0000-0000-000000000001'::uuid], 'processed'
), (
  '90000012-0000-0000-0000-000000000002'::uuid,
  '9000000a-0000-0000-0000-000000000002'::uuid,
  '90000006-0000-0000-0000-000000000002'::uuid,
  '90000001-0000-0000-0000-000000000001'::uuid,
  '90000002-0000-0000-0000-000000000002'::uuid,
  1, ARRAY['b0000001-0000-0000-0000-000000000001'::uuid], 'processed'
) on conflict (id) do nothing;


-- ===========================================================================
-- SECTION 1: SCHEMA, FUNCTION & PRIVILEGE INVARIANTS (Tests 1-11)
-- ===========================================================================

-- Test 1: Helper function private.is_child_active_in_family exists
select has_function('private', 'is_child_active_in_family', ARRAY['uuid', 'uuid'], 'Helper private.is_child_active_in_family exists');

-- Test 2: Helper private.is_child_active_in_family reports active child true
select is(
  private.is_child_active_in_family('90000002-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid),
  true,
  'is_child_active_in_family returns true for active child'
);

-- Test 3: Helper private.is_child_active_in_family reports archived child false
select is(
  private.is_child_active_in_family('90000002-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid),
  false,
  'is_child_active_in_family returns false for archived child'
);

-- Test 4: Table-wide update privilege on child_profiles is revoked from authenticated
select is(
  (select count(*)::int from information_schema.table_privileges
   where table_schema = 'public'
     and table_name = 'child_profiles'
     and grantee = 'authenticated'
     and privilege_type = 'UPDATE'),
  0,
  'Authenticated role has NO table-wide UPDATE privilege on child_profiles'
);

-- Test 5: Specific column update privilege granted on display_name
select ok(
  has_column_privilege('authenticated', 'public.child_profiles', 'display_name', 'UPDATE'),
  'Authenticated role has UPDATE privilege on display_name'
);

-- Test 6: Specific column update privilege granted on avatar_key
select ok(
  has_column_privilege('authenticated', 'public.child_profiles', 'avatar_key', 'UPDATE'),
  'Authenticated role has UPDATE privilege on avatar_key'
);

-- Test 7: Specific column update privilege granted on school_grade
select ok(
  has_column_privilege('authenticated', 'public.child_profiles', 'school_grade', 'UPDATE'),
  'Authenticated role has UPDATE privilege on school_grade'
);

-- Test 8: Sensitive lifecycle column status has NO update privilege for authenticated
select ok(
  not has_column_privilege('authenticated', 'public.child_profiles', 'status', 'UPDATE'),
  'Authenticated role has NO UPDATE privilege on status'
);

-- Test 9: Sensitive lifecycle column archived_at has NO update privilege for authenticated
select ok(
  not has_column_privilege('authenticated', 'public.child_profiles', 'archived_at', 'UPDATE'),
  'Authenticated role has NO UPDATE privilege on archived_at'
);

-- Test 10: Sensitive immutable column birth_year has NO update privilege for authenticated
select ok(
  not has_column_privilege('authenticated', 'public.child_profiles', 'birth_year', 'UPDATE'),
  'Authenticated role has NO UPDATE privilege on birth_year'
);

-- Test 11: Tenant identifier column family_id has NO update privilege for authenticated
select ok(
  not has_column_privilege('authenticated', 'public.child_profiles', 'family_id', 'UPDATE'),
  'Authenticated role has NO UPDATE privilege on family_id'
);


-- ===========================================================================
-- SECTION 2: AUTHENTICATED COLUMN PRIVILEGE REJECTIONS & PERMITTED EDITS (Tests 12-17)
-- ===========================================================================

-- Switch to Family A Owner
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 12: Direct SQL update on status fails with SQLSTATE 42501
prepare attempt_update_status as
  update public.child_profiles
  set status = 'archived'
  where id = '90000002-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'attempt_update_status',
  '42501',
  NULL,
  'Direct SQL update on child_profiles.status is rejected by PostgreSQL column privileges'
);

-- Test 13: Direct SQL update on archived_at fails with SQLSTATE 42501
prepare attempt_update_archived_at as
  update public.child_profiles
  set archived_at = now()
  where id = '90000002-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'attempt_update_archived_at',
  '42501',
  NULL,
  'Direct SQL update on child_profiles.archived_at is rejected by PostgreSQL column privileges'
);

-- Test 14: Direct SQL update on birth_year fails with SQLSTATE 42501
prepare attempt_update_birth_year as
  update public.child_profiles
  set birth_year = 2020
  where id = '90000002-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'attempt_update_birth_year',
  '42501',
  NULL,
  'Direct SQL update on child_profiles.birth_year is rejected by PostgreSQL column privileges'
);

-- Test 15: Authenticated attempt to change family_id fails with SQLSTATE 42501
prepare attempt_update_family_id as
  update public.child_profiles
  set family_id = '90000001-0000-0000-0000-000000000002'::uuid
  where id = '90000002-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'attempt_update_family_id',
  '42501',
  NULL,
  'Authenticated attempt to change family_id fails with SQLSTATE 42501'
);

-- Test 16: Permitted parent edit on active profile succeeds
update public.child_profiles
set display_name = 'Active Child Updated',
    avatar_key = 'star_silver',
    school_grade = 5
where id = '90000002-0000-0000-0000-000000000001'::uuid;

select is(
  (select display_name from public.child_profiles where id = '90000002-0000-0000-0000-000000000001'::uuid),
  'Active Child Updated',
  'Parent can update permitted fields on active profile'
);

-- Test 17: Value persistence
select is(
  (select school_grade from public.child_profiles where id = '90000002-0000-0000-0000-000000000001'::uuid),
  5::smallint,
  'Updated school_grade persists correctly on active child profile'
);


-- ===========================================================================
-- SECTION 3: PRIVILEGED TRIGGER-LEVEL LIFECYCLE INVARIANTS (Tests 18-23)
-- ===========================================================================

-- Reset to superuser to test trigger-level defenses directly
set local role postgres;

-- Test 18: Trigger trg_guard_child_profile_lifecycle exists
select has_trigger('public', 'child_profiles', 'trg_guard_child_profile_lifecycle', 'Trigger trg_guard_child_profile_lifecycle is attached');

-- Test 19: Privileged trigger-level attempt to change family_id throws LW005
prepare privileged_attempt_change_family as
  update public.child_profiles
  set family_id = '90000001-0000-0000-0000-000000000002'::uuid
  where id = '90000002-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'privileged_attempt_change_family',
  'LW005',
  'family_id on child_profiles is immutable',
  'Privileged trigger-level attempt to change child family_id throws LW005'
);

-- Test 20: Updating already-archived child profile throws LW011
prepare attempt_update_archived as
  update public.child_profiles
  set display_name = 'Hacked Archived Name'
  where id = '90000002-0000-0000-0000-000000000002'::uuid;

select throws_ok(
  'attempt_update_archived',
  'LW011',
  'Archived child profile is immutable',
  'Modifying already-archived child profile throws LW011'
);

-- Test 21: Invalid transition (e.g. status='archived' but archived_at is null) throws LW012
prepare attempt_invalid_transition as
  update public.child_profiles
  set status = 'archived',
      archived_at = null,
      display_name = '[Archived Learner]',
      avatar_key = null,
      school_grade = null,
      birth_year = null
  where id = '90000002-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'attempt_invalid_transition',
  'LW012',
  'Invalid child profile lifecycle transition',
  'Archival without archived_at timestamp throws LW012'
);

-- Test 22: Archival transition without atomic pseudonymization throws LW013
prepare attempt_non_pseudonymized_archive as
  update public.child_profiles
  set status = 'archived',
      archived_at = now(),
      display_name = 'Still Real Name'
  where id = '90000002-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'attempt_non_pseudonymized_archive',
  'LW013',
  'Archival transition requires atomic pseudonymization of identifying attributes',
  'Archival without atomic pseudonymization throws LW013'
);

-- Test 23: Full atomic archival transition succeeds on dedicated profile under superuser
insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year, avatar_key, status, archived_at)
values ('90000002-0000-0000-0000-000000000004'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'To Be Archived', 3, 2017, 'star_gold', 'active', null);

prepare valid_atomic_archive as
  update public.child_profiles
  set status = 'archived',
      archived_at = now(),
      display_name = '[Archived Learner]',
      avatar_key = null,
      school_grade = null,
      birth_year = null
  where id = '90000002-0000-0000-0000-000000000004'::uuid;

select lives_ok(
  'valid_atomic_archive',
  'Atomic archival update satisfying all trigger invariants succeeds under superuser'
);

delete from public.child_profiles where id = '90000002-0000-0000-0000-000000000004'::uuid;


-- ===========================================================================
-- SECTION 4: CHILD PROFILES & GRANTS RLS ISOLATION (Tests 24-32)
-- ===========================================================================

-- Switch to Family A Owner
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 24: Adult sees active child in child_profiles
select is(
  (select count(*)::int from public.child_profiles where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  1,
  'Family adult sees active child profile'
);

-- Test 25: Archived child is hidden from adult SELECT
select is(
  (select count(*)::int from public.child_profiles where id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Archived child profile is hidden from normal adult SELECT'
);

-- Test 26: Attempt to insert child profile with status = archived fails RLS with check
prepare insert_archived_child as
  insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year, status)
  values ('90000002-0000-0000-0000-000000000099'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Direct Archived', 3, 2017, 'archived');

select throws_ok(
  'insert_archived_child',
  '42501',
  NULL,
  'Adult cannot directly create a child in archived status (blocked by RLS WITH CHECK)'
);

-- Test 27: Adult sees only active child device grants
select is(
  (select count(*)::int from public.child_device_grants where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  1,
  'Family adult sees only grants belonging to active children'
);

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 28: Active child device can read own child profile
select is(
  (select count(*)::int from public.child_profiles where id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own child profile'
);

-- Test 29: Active child device CANNOT read archived child profile
select is(
  (select count(*)::int from public.child_profiles where id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Active child device cannot read archived child profile'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 30: Archived child device CANNOT read archived child profile
select is(
  (select count(*)::int from public.child_profiles where id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Archived child device cannot read archived child profile'
);

-- Test 31: Archived child device retains own-row grant read access to inspect grant status
select is(
  (select count(*)::int from public.child_device_grants where auth_user_id = '90000000-0000-0000-0000-000000000003'::uuid),
  1,
  'Archived child device retains own-row grant read access to inspect grant status'
);

-- Test 32: Archived child device CANNOT read other device grants
select is(
  (select count(*)::int from public.child_device_grants where auth_user_id != '90000000-0000-0000-0000-000000000003'::uuid),
  0,
  'Archived child device cannot read other child device grants'
);


-- ===========================================================================
-- SECTION 5: FAMILY-WIDE TABLES READ BOUNDARY (Tests 33-36)
-- ===========================================================================

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 33: Active child device can read family_wheel_settings
select is(
  (select count(*)::int from public.family_wheel_settings where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read family wheel settings'
);

-- Test 34: Active child device can read untargeted family rewards
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read untargeted family rewards'
);

-- Switch to Archived Child Device (with still-active grant row)
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 35: Archived child device with active grant CANNOT read family_wheel_settings
select is(
  (select count(*)::int from public.family_wheel_settings where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Archived child device cannot read family wheel settings'
);

-- Test 36: Archived child device with active grant CANNOT read untargeted family rewards
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000001'::uuid),
  0,
  'Archived child device cannot read untargeted family rewards'
);


-- ===========================================================================
-- SECTION 6: REWARDS TABLE TARGETED HARDENING (Tests 37-41)
-- ===========================================================================

-- Switch back to Family A Owner
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 37: Adult can read reward targeted to active child
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000002'::uuid),
  1,
  'Family adult can read reward targeted to active child'
);

-- Test 38: Adult CANNOT see reward targeted to archived child
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000003'::uuid),
  0,
  'Family adult cannot read reward targeted to archived child'
);

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 39: Active child device can read reward targeted to itself
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000002'::uuid),
  1,
  'Active child device can read reward targeted to itself'
);

-- Test 40: Active child device CANNOT read reward targeted to archived child
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000003'::uuid),
  0,
  'Active child device cannot read reward targeted to archived child'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 41: Archived child device CANNOT read reward targeted to itself
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000003'::uuid),
  0,
  'Archived child device cannot read reward targeted to itself'
);


-- ===========================================================================
-- SECTION 7: ADULT ACTIVE READ ACCESS VS ARCHIVED CHILD EXCLUSION (Tests 42-73)
-- ===========================================================================

-- Switch back to Family A Owner
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Part A: Adult CAN read active child data
-- Test 42: assessments (verified + draft for active child = 2)
select is(
  (select count(*)::int from public.assessments where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  2,
  'Adult can read assessments for active child'
);

-- Test 43: assessment_evidence
select is(
  (select count(*)::int from public.assessment_evidence where id = '90000007-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read assessment evidence for active child'
);

-- Test 44: assessment_review_events
select is(
  (select count(*)::int from public.assessment_review_events where id = '90000009-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read assessment review events for active child'
);

-- Test 45: verified_learning_events
select is(
  (select count(*)::int from public.verified_learning_events where id = '9000000a-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read verified learning events for active child'
);

-- Test 46: command_receipts
select is(
  (select count(*)::int from public.command_receipts where command_id = '90000008-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read command receipts for active child assessment'
);

-- Test 47: growth_events
select is(
  (select count(*)::int from public.growth_events where id = '9000000b-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read growth events for active child'
);

-- Test 48: xp_ledger
select is(
  (select count(*)::int from public.xp_ledger where id = '9000000c-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read XP ledger for active child'
);

-- Test 49: rp_ledger
select is(
  (select count(*)::int from public.rp_ledger where id = '9000000d-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read RP ledger for active child'
);

-- Test 50: child_balances
select is(
  (select count(*)::int from public.child_balances where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read child balance for active child'
);

-- Test 51: reward_redemptions
select is(
  (select count(*)::int from public.reward_redemptions where id = '9000000e-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read reward redemptions for active child'
);

-- Test 52: wheel_spins
select is(
  (select count(*)::int from public.wheel_spins where id = '9000000f-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read wheel spins for active child'
);

-- Test 53: assessment_learning_mappings
select is(
  (select count(*)::int from public.assessment_learning_mappings where assessment_id = '90000006-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read assessment learning mappings for active child'
);

-- Test 54: learning_evidence_events
select is(
  (select count(*)::int from public.learning_evidence_events where id = '90000010-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read learning evidence events for active child'
);

-- Test 55: child_mastery_states
select is(
  (select count(*)::int from public.child_mastery_states where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read child mastery states for active child'
);

-- Test 56: mastery_state_revisions
select is(
  (select count(*)::int from public.mastery_state_revisions where id = '90000011-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read mastery state revisions for active child'
);

-- Test 57: learning_processing_events
select is(
  (select count(*)::int from public.learning_processing_events where id = '90000012-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read learning processing events for active child'
);


-- Part B: Adult CANNOT read archived child data
-- Test 58: assessments
select is(
  (select count(*)::int from public.assessments where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessments for archived child'
);

-- Test 59: assessment_evidence
select is(
  (select count(*)::int from public.assessment_evidence where id = '90000007-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment evidence for archived child'
);

-- Test 60: assessment_review_events
select is(
  (select count(*)::int from public.assessment_review_events where id = '90000009-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment review events for archived child'
);

-- Test 61: verified_learning_events
select is(
  (select count(*)::int from public.verified_learning_events where id = '9000000a-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read verified learning events for archived child'
);

-- Test 62: command_receipts
select is(
  (select count(*)::int from public.command_receipts where command_id = '90000008-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read command receipts for archived child'
);

-- Test 63: growth_events
select is(
  (select count(*)::int from public.growth_events where id = '9000000b-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read growth events for archived child'
);

-- Test 64: xp_ledger
select is(
  (select count(*)::int from public.xp_ledger where id = '9000000c-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read XP ledger for archived child'
);

-- Test 65: rp_ledger
select is(
  (select count(*)::int from public.rp_ledger where id = '9000000d-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read RP ledger for archived child'
);

-- Test 66: child_balances
select is(
  (select count(*)::int from public.child_balances where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read child balance for archived child'
);

-- Test 67: reward_redemptions
select is(
  (select count(*)::int from public.reward_redemptions where id = '9000000e-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read reward redemptions for archived child'
);

-- Test 68: wheel_spins
select is(
  (select count(*)::int from public.wheel_spins where id = '9000000f-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read wheel spins for archived child'
);

-- Test 69: assessment_learning_mappings
select is(
  (select count(*)::int from public.assessment_learning_mappings where assessment_id = '90000006-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment learning mappings for archived child'
);

-- Test 70: learning_evidence_events
select is(
  (select count(*)::int from public.learning_evidence_events where id = '90000010-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read learning evidence events for archived child'
);

-- Test 71: child_mastery_states
select is(
  (select count(*)::int from public.child_mastery_states where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read child mastery states for archived child'
);

-- Test 72: mastery_state_revisions
select is(
  (select count(*)::int from public.mastery_state_revisions where id = '90000011-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read mastery state revisions for archived child'
);

-- Test 73: learning_processing_events
select is(
  (select count(*)::int from public.learning_processing_events where id = '90000012-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read learning processing events for archived child'
);


-- ===========================================================================
-- SECTION 8: PAIRED CHILD ALLOWED READS, ARCHIVED EXCLUSION & ADULT-ONLY DEFENSE (Tests 74-89)
-- ===========================================================================

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Part A: Active paired child can read permitted active-child data
-- Test 74: assessments
select is(
  (select count(*)::int from public.assessments where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  2,
  'Active child device can read own assessments'
);

-- Test 75: assessment_evidence
select is(
  (select count(*)::int from public.assessment_evidence where id = '90000007-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own assessment evidence'
);

-- Test 76: growth_events
select is(
  (select count(*)::int from public.growth_events where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own growth events'
);

-- Test 77: child_balances
select is(
  (select count(*)::int from public.child_balances where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own child balance'
);

-- Test 78: reward_redemptions
select is(
  (select count(*)::int from public.reward_redemptions where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own reward redemptions'
);

-- Test 79: wheel_spins
select is(
  (select count(*)::int from public.wheel_spins where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own wheel spins'
);

-- Test 80: child_mastery_states
select is(
  (select count(*)::int from public.child_mastery_states where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own child mastery states'
);

-- Test 81: mastery_state_revisions
select is(
  (select count(*)::int from public.mastery_state_revisions where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own mastery state revisions'
);

-- Test 82: learning_processing_events
select is(
  (select count(*)::int from public.learning_processing_events where child_id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own learning processing events'
);

-- Part B: Active paired child CANNOT read archived child data
-- Test 83: assessments for archived child
select is(
  (select count(*)::int from public.assessments where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Active child device cannot read archived child assessments'
);

-- Test 84: growth_events for archived child
select is(
  (select count(*)::int from public.growth_events where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Active child device cannot read archived child growth events'
);

-- Test 85: child_balances for archived child
select is(
  (select count(*)::int from public.child_balances where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Active child device cannot read archived child balances'
);

-- Test 86: child_mastery_states for archived child
select is(
  (select count(*)::int from public.child_mastery_states where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Active child device cannot read archived child mastery states'
);

-- Test 87: mastery_state_revisions for archived child
select is(
  (select count(*)::int from public.mastery_state_revisions where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Active child device cannot read archived child mastery state revisions'
);

-- Part C: No originally adult-only table becomes readable by paired children
-- Test 88: Paired child CANNOT read command_receipts
select is(
  (select count(*)::int from public.command_receipts where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Paired child device CANNOT read adult-only command_receipts'
);

-- Test 89: Paired child CANNOT read assessment_review_events
select is(
  (select count(*)::int from public.assessment_review_events where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Paired child device CANNOT read adult-only assessment_review_events'
);


-- ===========================================================================
-- SECTION 9: FOREIGN FAMILY MULTI-TENANT ISOLATION (Tests 90-100)
-- ===========================================================================

-- Switch to Foreign Adult (Family B Owner: 90000000-0000-0000-0000-000000000004)
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);

-- Test 90: Foreign adult cannot read Family A child profiles
select is(
  (select count(*)::int from public.child_profiles where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A child profiles'
);

-- Test 91: Foreign adult cannot read Family A child device grants
select is(
  (select count(*)::int from public.child_device_grants where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A child device grants'
);

-- Test 92: Foreign adult cannot read Family A wheel settings
select is(
  (select count(*)::int from public.family_wheel_settings where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A wheel settings'
);

-- Test 93: Foreign adult cannot read Family A rewards
select is(
  (select count(*)::int from public.rewards where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A rewards'
);

-- Test 94: Foreign adult cannot read Family A assessments
select is(
  (select count(*)::int from public.assessments where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A assessments'
);

-- Test 95: Foreign adult cannot read Family A command receipts
select is(
  (select count(*)::int from public.command_receipts where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A command receipts'
);

-- Test 96: Foreign adult cannot read Family A growth events
select is(
  (select count(*)::int from public.growth_events where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A growth events'
);

-- Test 97: Foreign adult cannot read Family A child balances
select is(
  (select count(*)::int from public.child_balances where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A child balances'
);

-- Test 98: Foreign adult cannot read Family A child mastery states
select is(
  (select count(*)::int from public.child_mastery_states where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A child mastery states'
);

-- Test 99: Foreign adult cannot read Family A mastery state revisions
select is(
  (select count(*)::int from public.mastery_state_revisions where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A mastery state revisions'
);

-- Test 100: Foreign adult cannot read Family A learning processing events
select is(
  (select count(*)::int from public.learning_processing_events where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Foreign adult cannot read Family A learning processing events'
);


-- ===========================================================================
-- SECTION 10: POLICY & PERMISSIONS REGRESSION INVARIANTS (Tests 101-102)
-- ===========================================================================

-- Switch to postgres role
set local role postgres;

-- Test 101: Policy mastery_state_revisions_select exists on public.mastery_state_revisions
select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'mastery_state_revisions'
      and policyname = 'mastery_state_revisions_select'
  ),
  'Policy mastery_state_revisions_select exists on public.mastery_state_revisions'
);

-- Test 102: Policy learning_processing_events_select exists on public.learning_processing_events
select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'learning_processing_events'
      and policyname = 'learning_processing_events_select'
  ),
  'Policy learning_processing_events_select exists on public.learning_processing_events'
);


-- ===========================================================================
-- SECTION 11: STORAGE EVIDENCE ACCESS HELPER HARDENING (Tests 103-104)
-- ===========================================================================

-- Keep postgres role; set JWT claims to Family A Owner to test helper
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 103: Storage helper permits draft assessment evidence for active child
select is(
  private.validate_storage_evidence_access(
    '90000001-0000-0000-0000-000000000001/90000002-0000-0000-0000-000000000001/90000006-0000-0000-0000-000000000003/e0000000-0000-0000-0000-000000000001.jpg',
    true
  ),
  true,
  'Storage access helper validates active child draft assessment evidence'
);

-- Test 104: Storage helper denies draft assessment evidence for archived child
select is(
  private.validate_storage_evidence_access(
    '90000001-0000-0000-0000-000000000001/90000002-0000-0000-0000-000000000002/90000006-0000-0000-0000-000000000004/e0000000-0000-0000-0000-000000000002.jpg',
    true
  ),
  false,
  'Storage access helper rejects evidence access for archived child'
);

select * from finish();
rollback;
