begin;
select plan(49);

-- ===========================================================================
-- 0. FIXTURES SETUP (superuser context)
-- ===========================================================================

-- Identities
insert into auth.users (id, aud, role, email) values
  ('90000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'p6_owner_a@test.com'),
  ('90000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'p6_active_child_device@test.com'),
  ('90000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'p6_archived_child_device@test.com'),
  ('90000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'p6_foreign_owner@test.com')
on conflict (id) do nothing;

-- Families
insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('90000001-0000-0000-0000-000000000001'::uuid, 'Phase 6 Family A', 'America/New_York', 'en_US', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000001-0000-0000-0000-000000000002'::uuid, 'Phase 6 Family B', 'America/Chicago', 'en_US', '90000000-0000-0000-0000-000000000004'::uuid)
on conflict (id) do nothing;

-- Memberships
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('90000001-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('90000001-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000004'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

-- Children: One Active, One Archived (Pseudonymized per Tier 3), One Foreign
insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year, avatar_key, status, archived_at) values
  ('90000002-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Active Child', 4, 2016, 'star_gold', 'active', null),
  ('90000002-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '[Archived Learner]', null, null, null, 'archived', now() - interval '1 day'),
  ('90000002-0000-0000-0000-000000000003'::uuid, '90000001-0000-0000-0000-000000000002'::uuid, 'Foreign Child', 5, 2015, 'shield_blue', 'active', null)
on conflict (id) do nothing;

-- Device Grants: Active grant for active child, active grant for archived child
insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('90000003-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000002'::uuid, 'active', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000003-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000003'::uuid, 'active', '90000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Wheel Settings for Family A
insert into public.family_wheel_settings (family_id, spin_cost_minor, daily_spin_cap, is_enabled) values
  ('90000001-0000-0000-0000-000000000001'::uuid, 1000, 3, true)
on conflict (family_id) do nothing;

-- Rewards: One Family-wide, One targeted to Active Child, One targeted to Archived Child
insert into public.rewards (id, family_id, title, category, store_cost_minor, is_active, store_enabled, wheel_enabled, wheel_tier, target_child_id) values
  ('90000005-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Family Pizza Night', 'treat', 1000, true, true, true, 'common', null),
  ('90000005-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Active Child Book', 'item', 500, true, true, true, 'common', '90000002-0000-0000-0000-000000000001'::uuid),
  ('90000005-0000-0000-0000-000000000003'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Archived Child Legacy Reward', 'treat', 750, true, true, true, 'common', '90000002-0000-0000-0000-000000000002'::uuid)
on conflict (id) do nothing;

-- Assessments: Insert in draft status so evidence can be attached before terminal transition
insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id) values
  ('90000006-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Active Quiz', 'quiz', 'normal', 10, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000006-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Archived Quiz', 'quiz', 'normal', 10, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000006-0000-0000-0000-000000000003'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Active Draft', 'quiz', 'normal', 8, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000006-0000-0000-0000-000000000004'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Archived Draft', 'quiz', 'normal', 8, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Assessment Evidence (attached while assessments 1 & 2 are in draft)
insert into public.assessment_evidence (id, assessment_id, family_id, storage_path, media_type, file_size_bytes, uploaded_by_user_id) values
  ('90000007-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001/90000002-0000-0000-0000-000000000001/90000006-0000-0000-0000-000000000001/e0000000-0000-0000-0000-000000000001.jpg', 'image/jpeg', 1024, '90000000-0000-0000-0000-000000000001'::uuid),
  ('90000007-0000-0000-0000-000000000002'::uuid, '90000006-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001/90000002-0000-0000-0000-000000000002/90000006-0000-0000-0000-000000000002/e0000000-0000-0000-0000-000000000002.jpg', 'image/jpeg', 1024, '90000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Transition assessments 1 & 2 to verified status
update public.assessments
set status = 'verified'
where id in ('90000006-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000002'::uuid);

-- Command Receipts
insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id, status) values
  ('90000008-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'verify', '90000006-0000-0000-0000-000000000001'::uuid, 'applied'),
  ('90000008-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'verify', '90000006-0000-0000-0000-000000000002'::uuid, 'applied')
on conflict (command_id) do nothing;

-- Assessment Review Events
insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id, review_notes) values
  ('90000009-0000-0000-0000-000000000001'::uuid, '90000008-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000001'::uuid, 'verified', 'submitted', 'verified', '90000000-0000-0000-0000-000000000001'::uuid, 'Great job!'),
  ('90000009-0000-0000-0000-000000000002'::uuid, '90000008-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000002'::uuid, 'verified', 'submitted', 'verified', '90000000-0000-0000-0000-000000000001'::uuid, 'Archived historical review')
on conflict (id) do nothing;

-- Verified Learning Events (VLE)
insert into public.verified_learning_events (id, assessment_id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id) values
  ('9000000a-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Active Quiz', 'quiz', 'normal', 10, 10, 10.0, now(), '90000000-0000-0000-0000-000000000001'::uuid, '90000009-0000-0000-0000-000000000001'::uuid),
  ('9000000a-0000-0000-0000-000000000002'::uuid, '90000006-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Archived Quiz', 'quiz', 'normal', 10, 10, 10.0, now(), '90000000-0000-0000-0000-000000000001'::uuid, '90000009-0000-0000-0000-000000000002'::uuid)
on conflict (id) do nothing;

-- Growth Events & Ledgers
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

-- Learning Mastery fixtures
insert into public.child_mastery_states (family_id, child_id, learning_node_id, mastery_score, status) values
  ('90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 85.0, 'mastered'),
  ('90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 85.0, 'mastered')
on conflict (child_id, learning_node_id) do nothing;

insert into public.assessment_learning_mappings (assessment_id, learning_node_id, family_id, weight) values
  ('90000006-0000-0000-0000-000000000001'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 1.0),
  ('90000006-0000-0000-0000-000000000002'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 1.0)
on conflict (assessment_id, learning_node_id) do nothing;

insert into public.learning_evidence_events (id, assessment_id, family_id, child_id, learning_node_id, score) values
  ('90000010-0000-0000-0000-000000000001'::uuid, '90000006-0000-0000-0000-000000000001'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000001'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 85.0),
  ('90000010-0000-0000-0000-000000000002'::uuid, '90000006-0000-0000-0000-000000000002'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, '90000002-0000-0000-0000-000000000002'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 85.0)
on conflict (id) do nothing;


-- ===========================================================================
-- SECTION 1: SCHEMA, FUNCTION & PRIVILEGE INVARIANTS (Tests 1-8)
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


-- ===========================================================================
-- SECTION 2: COLUMN PRIVILEGE REJECTION & PERMITTED EDITS (Tests 9-13)
-- ===========================================================================

-- Switch to Family A Owner
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 9: Direct SQL update on status fails with SQLSTATE 42501
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

-- Test 10: Direct SQL update on archived_at fails with SQLSTATE 42501
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

-- Test 11: Direct SQL update on birth_year fails with SQLSTATE 42501
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

-- Test 12: Permitted parent edit on active profile succeeds
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

-- Test 13: Value persistence
select is(
  (select school_grade from public.child_profiles where id = '90000002-0000-0000-0000-000000000001'::uuid),
  5::smallint,
  'Updated school_grade persists correctly on active child profile'
);


-- ===========================================================================
-- SECTION 3: LIFECYCLE TRIGGER INVARIANTS (Tests 14-19)
-- ===========================================================================

-- Test 14: Core identity immutability (attempting to update family_id throws LW005)
prepare attempt_change_family as
  update public.child_profiles
  set family_id = '90000001-0000-0000-0000-000000000002'::uuid
  where id = '90000002-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'attempt_change_family',
  'LW005',
  'family_id on child_profiles is immutable',
  'Attempting to change child family_id throws LW005'
);

-- Reset to superuser to test trigger-level defenses directly
set local role postgres;

-- Test 15: Trigger trg_guard_child_profile_lifecycle exists
select has_trigger('public', 'child_profiles', 'trg_guard_child_profile_lifecycle', 'Trigger trg_guard_child_profile_lifecycle is attached');

-- Test 16: Updating already-archived child profile throws LW011
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

-- Test 17: Invalid transition (e.g. status='archived' but archived_at is null) throws LW012
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

-- Test 18: Archival transition without atomic pseudonymization throws LW013
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

-- Test 19: Full atomic archival transition succeeds when all invariants are satisfied
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
-- SECTION 4: CHILD PROFILES & GRANTS RLS ISOLATION (Tests 20-25)
-- ===========================================================================

-- Switch to Family A Owner
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 20: Adult sees active child, does NOT see archived child in child_profiles
select is(
  (select count(*)::int from public.child_profiles where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  1,
  'Family adult sees only active child profile (archived child excluded from SELECT)'
);

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 21: Active child device sees own active profile
select is(
  (select count(*)::int from public.child_profiles where id = '90000002-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own child profile'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 22: Archived child device CANNOT read archived child profile
select is(
  (select count(*)::int from public.child_profiles where id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Archived child device cannot read archived child profile'
);

-- Switch back to Family A Owner
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 23: Adult sees only active child device grants
select is(
  (select count(*)::int from public.child_device_grants where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  1,
  'Family adult sees only grants belonging to active children'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 24: Archived child device can read its own grant row (to detect revocation/status)
select is(
  (select count(*)::int from public.child_device_grants where auth_user_id = '90000000-0000-0000-0000-000000000003'::uuid),
  1,
  'Archived child device retains own-row grant read access to inspect grant status'
);

-- Switch back to Family A Owner
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 25: Attempt to insert child profile with status = 'archived' fails RLS with check
prepare insert_archived_child as
  insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year, status)
  values ('90000002-0000-0000-0000-000000000099'::uuid, '90000001-0000-0000-0000-000000000001'::uuid, 'Direct Archived', 3, 2017, 'archived');

select throws_ok(
  'insert_archived_child',
  '42501',
  NULL,
  'Adult cannot directly create a child in archived status (blocked by RLS WITH CHECK)'
);


-- ===========================================================================
-- SECTION 5: FAMILY-WIDE TABLES READ BOUNDARY (Tests 26-29)
-- ===========================================================================

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 26: Active child device can read family_wheel_settings
select is(
  (select count(*)::int from public.family_wheel_settings where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read family wheel settings'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 27: Archived child device CANNOT read family_wheel_settings
select is(
  (select count(*)::int from public.family_wheel_settings where family_id = '90000001-0000-0000-0000-000000000001'::uuid),
  0,
  'Archived child device cannot read family wheel settings'
);

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 28: Active child device can read untargeted family rewards
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read untargeted family rewards'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 29: Archived child device CANNOT read untargeted family rewards
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000001'::uuid),
  0,
  'Archived child device cannot read untargeted family rewards'
);


-- ===========================================================================
-- SECTION 6: REWARDS TABLE TARGETED HARDENING (Tests 30-33)
-- ===========================================================================

-- Switch back to Family A Owner
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 30: Adult sees reward targeted to active child
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000002'::uuid),
  1,
  'Family adult can read reward targeted to active child'
);

-- Test 31: Adult CANNOT see reward targeted to archived child
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000003'::uuid),
  0,
  'Family adult cannot read reward targeted to archived child'
);

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 32: Active child device can read reward targeted to itself
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000002'::uuid),
  1,
  'Active child device can read reward targeted to itself'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 33: Archived child device CANNOT read reward targeted to itself
select is(
  (select count(*)::int from public.rewards where id = '90000005-0000-0000-0000-000000000003'::uuid),
  0,
  'Archived child device cannot read reward targeted to itself'
);


-- ===========================================================================
-- SECTION 7: DOMAIN ENTITY TABLES ACTIVE-CHILD READ BARRIER (Tests 34-47)
-- ===========================================================================

-- Switch back to Family A Owner
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 34: Adult cannot read assessment for archived child
select is(
  (select count(*)::int from public.assessments where id = '90000006-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment for archived child'
);

-- Test 35: Adult cannot read evidence for archived child assessment
select is(
  (select count(*)::int from public.assessment_evidence where id = '90000007-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment evidence for archived child'
);

-- Test 36: Adult cannot read review events for archived child assessment
select is(
  (select count(*)::int from public.assessment_review_events where id = '90000009-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment review events for archived child'
);

-- Test 37: Adult cannot read verified learning events for archived child
select is(
  (select count(*)::int from public.verified_learning_events where id = '9000000a-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read verified learning events for archived child'
);

-- Test 38: Adult cannot read command receipts for archived child operations
select is(
  (select count(*)::int from public.command_receipts where command_id = '90000008-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read command receipts for archived child'
);

-- Test 39: Adult cannot read growth events for archived child
select is(
  (select count(*)::int from public.growth_events where id = '9000000b-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read growth events for archived child'
);

-- Test 40: Adult cannot read XP ledger for archived child
select is(
  (select count(*)::int from public.xp_ledger where id = '9000000c-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read XP ledger for archived child'
);

-- Test 41: Adult cannot read RP ledger for archived child
select is(
  (select count(*)::int from public.rp_ledger where id = '9000000d-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read RP ledger for archived child'
);

-- Test 42: Adult cannot read child balance for archived child
select is(
  (select count(*)::int from public.child_balances where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read child balance for archived child'
);

-- Test 43: Adult cannot read reward redemptions for archived child
select is(
  (select count(*)::int from public.reward_redemptions where id = '9000000e-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read reward redemptions for archived child'
);

-- Test 44: Adult cannot read wheel spins for archived child
select is(
  (select count(*)::int from public.wheel_spins where id = '9000000f-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read wheel spins for archived child'
);

-- Test 45: Adult cannot read assessment learning mappings for archived child
select is(
  (select count(*)::int from public.assessment_learning_mappings where assessment_id = '90000006-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment learning mappings for archived child'
);

-- Test 46: Adult cannot read learning evidence events for archived child
select is(
  (select count(*)::int from public.learning_evidence_events where id = '90000010-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read learning evidence events for archived child'
);

-- Test 47: Adult cannot read child mastery states for archived child
select is(
  (select count(*)::int from public.child_mastery_states where child_id = '90000002-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read child mastery states for archived child'
);


-- ===========================================================================
-- SECTION 8: STORAGE EVIDENCE ACCESS HELPER HARDENING (Tests 48-49)
-- ===========================================================================

-- Test 48: Storage helper permits draft assessment evidence for active child
select is(
  private.validate_storage_evidence_access(
    '90000001-0000-0000-0000-000000000001/90000002-0000-0000-0000-000000000001/90000006-0000-0000-0000-000000000003/e0000000-0000-0000-0000-000000000001.jpg',
    true
  ),
  true,
  'Storage access helper validates active child draft assessment evidence'
);

-- Test 49: Storage helper denies draft assessment evidence for archived child
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
