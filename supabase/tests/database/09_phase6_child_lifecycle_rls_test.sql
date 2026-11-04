begin;
select plan(50);

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
  ('f9000000-0000-0000-0000-000000000001'::uuid, 'Phase 6 Family A', 'America/New_York', 'en_US', '90000000-0000-0000-0000-000000000001'::uuid),
  ('f9000000-0000-0000-0000-000000000002'::uuid, 'Phase 6 Family B', 'America/Chicago', 'en_US', '90000000-0000-0000-0000-000000000004'::uuid)
on conflict (id) do nothing;

-- Memberships
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('f9000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('f9000000-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000004'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

-- Children: One Active, One Archived (Pseudonymized per Tier 3), One Foreign
insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year, avatar_key, status, archived_at) values
  ('c9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'Active Child', 4, 2016, 'star_gold', 'active', null),
  ('c9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, '[Archived Learner]', null, null, null, 'archived', now() - interval '1 day'),
  ('c9000000-0000-0000-0000-000000000003'::uuid, 'f9000000-0000-0000-0000-000000000002'::uuid, 'Foreign Child', 5, 2015, 'shield_blue', 'active', null)
on conflict (id) do nothing;

-- Device Grants: Active grant for active child, active grant for archived child
insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('d9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000002'::uuid, 'active', '90000000-0000-0000-0000-000000000001'::uuid),
  ('d9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000003'::uuid, 'active', '90000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Wheel Settings for Family A
insert into public.family_wheel_settings (family_id, max_daily_spins, cooldown_hours, min_streak_days, updated_by_user_id) values
  ('f9000000-0000-0000-0000-000000000001'::uuid, 3, 4, 1, '90000000-0000-0000-0000-000000000001'::uuid)
on conflict (family_id) do nothing;

-- Rewards: One Family-wide, One targeted to Active Child, One targeted to Archived Child
insert into public.rewards (id, family_id, title, cost_rp, is_active, store_enabled, wheel_enabled, target_child_id, created_by_user_id) values
  ('r9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'Family Pizza Night', 100, true, true, true, null, '90000000-0000-0000-0000-000000000001'::uuid),
  ('r9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'Active Child Book', 50, true, true, true, 'c9000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid),
  ('r9000000-0000-0000-0000-000000000003'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'Archived Child Legacy Reward', 75, true, true, true, 'c9000000-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Assessments: One for Active Child, One for Archived Child
insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id) values
  ('a9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Active Quiz', 'quiz', 'normal', 10, 10, 'verified', '90000000-0000-0000-0000-000000000001'::uuid),
  ('a9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Archived Quiz', 'quiz', 'normal', 10, 10, 'verified', '90000000-0000-0000-0000-000000000001'::uuid),
  ('a9000000-0000-0000-0000-000000000003'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Active Draft', 'quiz', 'normal', 8, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid),
  ('a9000000-0000-0000-0000-000000000004'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Archived Draft', 'quiz', 'normal', 8, 10, 'draft', '90000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Assessment Evidence
insert into public.assessment_evidence (id, assessment_id, family_id, storage_path, media_type, file_size_bytes, sha256_checksum) values
  ('e9000000-0000-0000-0000-000000000001'::uuid, 'a9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001/c9000000-0000-0000-0000-000000000001/a9000000-0000-0000-0000-000000000001/ev1.jpg', 'image/jpeg', 1024, 'sha256_1'),
  ('e9000000-0000-0000-0000-000000000002'::uuid, 'a9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001/c9000000-0000-0000-0000-000000000002/a9000000-0000-0000-0000-000000000002/ev2.jpg', 'image/jpeg', 1024, 'sha256_2')
on conflict (id) do nothing;

-- Assessment Review Events
insert into public.assessment_review_events (id, assessment_id, family_id, reviewer_user_id, review_action, review_notes) values
  ('v9000000-0000-0000-0000-000000000001'::uuid, 'a9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'verify', 'Great job!'),
  ('v9000000-0000-0000-0000-000000000002'::uuid, 'a9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'verify', 'Archived historical review')
on conflict (id) do nothing;

-- Verified Learning Events (VLE)
insert into public.verified_learning_events (id, assessment_id, family_id, child_id, subject_key, verified_score, verified_by_user_id) values
  ('l9000000-0000-0000-0000-000000000001'::uuid, 'a9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 'math', 10, '90000000-0000-0000-0000-000000000001'::uuid),
  ('l9000000-0000-0000-0000-000000000002'::uuid, 'a9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 'math', 10, '90000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Command Receipts
insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id) values
  ('cmd90000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'verify_assessment', 'a9000000-0000-0000-0000-000000000001'::uuid),
  ('cmd90000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, '90000000-0000-0000-0000-000000000001'::uuid, 'verify_assessment', 'a9000000-0000-0000-0000-000000000002'::uuid)
on conflict (command_id) do nothing;

-- Growth Events & Ledgers
insert into public.growth_events (id, vle_id, family_id, child_id, earned_xp, earned_rp, current_streak) values
  ('g9000000-0000-0000-0000-000000000001'::uuid, 'l9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 50, 10, 1),
  ('g9000000-0000-0000-0000-000000000002'::uuid, 'l9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 50, 10, 1)
on conflict (id) do nothing;

insert into public.xp_ledger (id, family_id, child_id, growth_event_id, amount_xp) values
  ('x9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 'g9000000-0000-0000-0000-000000000001'::uuid, 50),
  ('x9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 'g9000000-0000-0000-0000-000000000002'::uuid, 50)
on conflict (id) do nothing;

insert into public.rp_ledger (id, family_id, child_id, amount_rp, balance_after, reason_code) values
  ('p9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 10, 10, 'assessment_earned'),
  ('p9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 10, 10, 'assessment_earned')
on conflict (id) do nothing;

insert into public.child_balances (child_id, family_id, total_xp, current_rp, lifetime_rp, level, current_streak) values
  ('c9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 50, 10, 10, 1, 1),
  ('c9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 50, 10, 10, 1, 1)
on conflict (child_id) do nothing;

insert into public.reward_redemptions (id, family_id, child_id, reward_id, cost_rp, status) values
  ('m9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 'r9000000-0000-0000-0000-000000000001'::uuid, 100, 'pending'),
  ('m9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 'r9000000-0000-0000-0000-000000000001'::uuid, 100, 'pending')
on conflict (id) do nothing;

insert into public.wheel_spins (id, family_id, child_id, reward_id, result_type) values
  ('w9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 'r9000000-0000-0000-0000-000000000001'::uuid, 'reward'),
  ('w9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 'r9000000-0000-0000-0000-000000000001'::uuid, 'reward')
on conflict (id) do nothing;

-- Learning Mastery fixtures
insert into public.child_mastery_states (family_id, child_id, learning_node_id, mastery_score, status) values
  ('f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 85.0, 'mastered'),
  ('f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 85.0, 'mastered')
on conflict (child_id, learning_node_id) do nothing;

insert into public.assessment_learning_mappings (assessment_id, learning_node_id, family_id, weight) values
  ('a9000000-0000-0000-0000-000000000001'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 1.0),
  ('a9000000-0000-0000-0000-000000000002'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 1.0)
on conflict (assessment_id, learning_node_id) do nothing;

insert into public.learning_evidence_events (id, assessment_id, family_id, child_id, learning_node_id, score) values
  ('k9000000-0000-0000-0000-000000000001'::uuid, 'a9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000001'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 85.0),
  ('k9000000-0000-0000-0000-000000000002'::uuid, 'a9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'c9000000-0000-0000-0000-000000000002'::uuid, 'b0000001-0000-0000-0000-000000000001'::uuid, 85.0)
on conflict (id) do nothing;


-- ===========================================================================
-- SECTION 1: SCHEMA, FUNCTION & PRIVILEGE INVARIANTS (Tests 1-8)
-- ===========================================================================

-- Test 1: Helper function private.is_child_active_in_family exists
select has_function('private', 'is_child_active_in_family', ARRAY['uuid', 'uuid'], 'Helper private.is_child_active_in_family exists');

-- Test 2: Helper private.is_child_active_in_family correctly reports active vs archived
select is(
  private.is_child_active_in_family('c9000000-0000-0000-0000-000000000001'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid),
  true,
  'is_child_active_in_family returns true for active child'
);

select is(
  private.is_child_active_in_family('c9000000-0000-0000-0000-000000000002'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid),
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

-- Test 5: Specific column update privileges granted to authenticated
select ok(
  has_column_privilege('authenticated', 'public.child_profiles', 'display_name', 'UPDATE'),
  'Authenticated role has UPDATE privilege on display_name'
);

select ok(
  has_column_privilege('authenticated', 'public.child_profiles', 'avatar_key', 'UPDATE'),
  'Authenticated role has UPDATE privilege on avatar_key'
);

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
  where id = 'c9000000-0000-0000-0000-000000000001'::uuid;

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
  where id = 'c9000000-0000-0000-0000-000000000001'::uuid;

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
  where id = 'c9000000-0000-0000-0000-000000000001'::uuid;

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
where id = 'c9000000-0000-0000-0000-000000000001'::uuid;

select is(
  (select display_name from public.child_profiles where id = 'c9000000-0000-0000-0000-000000000001'::uuid),
  'Active Child Updated',
  'Parent can update permitted fields on active profile'
);

select is(
  (select school_grade from public.child_profiles where id = 'c9000000-0000-0000-0000-000000000001'::uuid),
  5::smallint,
  'Updated school_grade persists correctly on active child profile'
);


-- ===========================================================================
-- SECTION 3: LIFECYCLE TRIGGER INVARIANTS (Tests 14-19)
-- ===========================================================================

-- Test 14: Core identity immutability (attempting to update family_id throws LW005)
prepare attempt_change_family as
  update public.child_profiles
  set family_id = 'f9000000-0000-0000-0000-000000000002'::uuid
  where id = 'c9000000-0000-0000-0000-000000000001'::uuid;

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
  where id = 'c9000000-0000-0000-0000-000000000002'::uuid;

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
  where id = 'c9000000-0000-0000-0000-000000000001'::uuid;

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
  where id = 'c9000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'attempt_non_pseudonymized_archive',
  'LW013',
  'Archival transition requires atomic pseudonymization of identifying attributes',
  'Archival without atomic pseudonymization throws LW013'
);

-- Test 19: Full atomic archival transition succeeds when all invariants are satisfied
prepare valid_atomic_archive as
  update public.child_profiles
  set status = 'archived',
      archived_at = now(),
      display_name = '[Archived Learner]',
      avatar_key = null,
      school_grade = null,
      birth_year = null
  where id = 'c9000000-0000-0000-0000-000000000001'::uuid;

select lives_ok(
  'valid_atomic_archive',
  'Atomic archival update satisfying all trigger invariants succeeds under superuser'
);

-- Rollback child 1 back to active for subsequent RLS tests
update public.child_profiles
set status = 'active',
    archived_at = null,
    display_name = 'Active Child',
    school_grade = 4,
    birth_year = 2016,
    avatar_key = 'star_gold'
where id = 'c9000000-0000-0000-0000-000000000001'::uuid;


-- ===========================================================================
-- SECTION 4: CHILD PROFILES & GRANTS RLS ISOLATION (Tests 20-25)
-- ===========================================================================

-- Switch to Family A Owner
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 20: Adult sees active child, does NOT see archived child in child_profiles
select is(
  (select count(*)::int from public.child_profiles where family_id = 'f9000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Family adult sees only active child profile (archived child excluded from SELECT)'
);

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 21: Active child device sees own active profile
select is(
  (select count(*)::int from public.child_profiles where id = 'c9000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read own child profile'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 22: Archived child device CANNOT read archived child profile
select is(
  (select count(*)::int from public.child_profiles where id = 'c9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Archived child device cannot read archived child profile'
);

-- Switch back to Family A Owner
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 23: Adult sees only active child device grants
select is(
  (select count(*)::int from public.child_device_grants where family_id = 'f9000000-0000-0000-0000-000000000001'::uuid),
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
  values ('c9000000-0000-0000-0000-000000000099'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'Direct Archived', 3, 2017, 'archived');

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
  (select count(*)::int from public.family_wheel_settings where family_id = 'f9000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read family wheel settings'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 27: Archived child device CANNOT read family_wheel_settings
select is(
  (select count(*)::int from public.family_wheel_settings where family_id = 'f9000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Archived child device cannot read family wheel settings'
);

-- Switch to Active Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 28: Active child device can read untargeted family rewards
select is(
  (select count(*)::int from public.rewards where id = 'r9000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Active child device can read untargeted family rewards'
);

-- Switch to Archived Child Device
select set_config('request.jwt.claims', '{"sub": "90000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 29: Archived child device CANNOT read untargeted family rewards
select is(
  (select count(*)::int from public.rewards where id = 'r9000000-0000-0000-0000-000000000001'::uuid),
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
  (select count(*)::int from public.rewards where id = 'r9000000-0000-0000-0000-000000000002'::uuid),
  1,
  'Family adult can read reward targeted to active child'
);

-- Test 31: Adult CANNOT see reward targeted to archived child
select is(
  (select count(*)::int from public.rewards where id = 'r9000000-0000-0000-0000-000000000003'::uuid),
  0,
  'Family adult cannot read reward targeted to archived child'
);

-- Test 32: Adult cannot insert reward targeted to archived child
prepare insert_archived_reward as
  insert into public.rewards (id, family_id, title, cost_rp, is_active, store_enabled, target_child_id, created_by_user_id)
  values ('r9000000-0000-0000-0000-000000000099'::uuid, 'f9000000-0000-0000-0000-000000000001'::uuid, 'Invalid Reward', 25, true, true, 'c9000000-0000-0000-0000-000000000002'::uuid, '90000000-0000-0000-0000-000000000001'::uuid);

select throws_ok(
  'insert_archived_reward',
  '42501',
  NULL,
  'Inserting reward targeted to archived child fails RLS WITH CHECK'
);

-- Test 33: Adult cannot update reward target to archived child
prepare update_reward_target_archived as
  update public.rewards
  set target_child_id = 'c9000000-0000-0000-0000-000000000002'::uuid
  where id = 'r9000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'update_reward_target_archived',
  '42501',
  NULL,
  'Retargeting reward to archived child fails RLS'
);


-- ===========================================================================
-- SECTION 7: DOMAIN ENTITY TABLES ACTIVE-CHILD READ BARRIER (Tests 34-47)
-- ===========================================================================

-- Adult reads active assessment
select is(
  (select count(*)::int from public.assessments where id = 'a9000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Adult can read assessment for active child'
);

-- Test 34: Adult cannot read assessment for archived child
select is(
  (select count(*)::int from public.assessments where id = 'a9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment for archived child'
);

-- Test 35: Adult cannot read evidence for archived child assessment
select is(
  (select count(*)::int from public.assessment_evidence where id = 'e9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment evidence for archived child'
);

-- Test 36: Adult cannot read review events for archived child assessment
select is(
  (select count(*)::int from public.assessment_review_events where id = 'v9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment review events for archived child'
);

-- Test 37: Adult cannot read verified learning events for archived child
select is(
  (select count(*)::int from public.verified_learning_events where id = 'l9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read verified learning events for archived child'
);

-- Test 38: Adult cannot read command receipts for archived child operations
select is(
  (select count(*)::int from public.command_receipts where command_id = 'cmd90000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read command receipts for archived child'
);

-- Test 39: Adult cannot read growth events for archived child
select is(
  (select count(*)::int from public.growth_events where id = 'g9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read growth events for archived child'
);

-- Test 40: Adult cannot read XP ledger for archived child
select is(
  (select count(*)::int from public.xp_ledger where id = 'x9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read XP ledger for archived child'
);

-- Test 41: Adult cannot read RP ledger for archived child
select is(
  (select count(*)::int from public.rp_ledger where id = 'p9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read RP ledger for archived child'
);

-- Test 42: Adult cannot read child balance for archived child
select is(
  (select count(*)::int from public.child_balances where child_id = 'c9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read child balance for archived child'
);

-- Test 43: Adult cannot read reward redemptions for archived child
select is(
  (select count(*)::int from public.reward_redemptions where id = 'm9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read reward redemptions for archived child'
);

-- Test 44: Adult cannot read wheel spins for archived child
select is(
  (select count(*)::int from public.wheel_spins where id = 'w9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read wheel spins for archived child'
);

-- Test 45: Adult cannot read assessment learning mappings for archived child
select is(
  (select count(*)::int from public.assessment_learning_mappings where assessment_id = 'a9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read assessment learning mappings for archived child'
);

-- Test 46: Adult cannot read learning evidence events for archived child
select is(
  (select count(*)::int from public.learning_evidence_events where id = 'k9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read learning evidence events for archived child'
);

-- Test 47: Adult cannot read child mastery states for archived child
select is(
  (select count(*)::int from public.child_mastery_states where child_id = 'c9000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Adult cannot read child mastery states for archived child'
);


-- ===========================================================================
-- SECTION 8: STORAGE EVIDENCE ACCESS HELPER HARDENING (Tests 48-49)
-- ===========================================================================

-- Test 48: Storage helper permits draft assessment evidence for active child
select is(
  private.validate_storage_evidence_access(
    'f9000000-0000-0000-0000-000000000001/c9000000-0000-0000-0000-000000000001/a9000000-0000-0000-0000-000000000003/e0000000-0000-0000-0000-000000000001.jpg',
    true
  ),
  true,
  'Storage access helper validates active child draft assessment evidence'
);

-- Test 49: Storage helper denies draft assessment evidence for archived child
select is(
  private.validate_storage_evidence_access(
    'f9000000-0000-0000-0000-000000000001/c9000000-0000-0000-0000-000000000002/a9000000-0000-0000-0000-000000000004/e0000000-0000-0000-0000-000000000002.jpg',
    true
  ),
  false,
  'Storage access helper rejects evidence access for archived child'
);

select * from finish();
rollback;
