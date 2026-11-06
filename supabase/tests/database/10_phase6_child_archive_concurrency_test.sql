-- ===========================================================================
-- LearnWard pgTAP Test Suite: Phase 6 Slice 2 - Child Archival Lifecycle,
-- Concurrency Hierarchy & SECURITY DEFINER Active-Child Mutation Barriers
-- ===========================================================================

begin;
select plan(44);

-- ---------------------------------------------------------------------------
-- 1. FIXTURE SETUP
-- ---------------------------------------------------------------------------

-- Users
insert into auth.users (id, aud, role, email) values
  ('10000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'adult_a@test.com'),
  ('10000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'child_a1_device@test.com'),
  ('10000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'child_a2_device@test.com'),
  ('10000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'adult_b@test.com')
on conflict (id) do nothing;

-- Families
insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('a0000000-0000-0000-0000-000000000001'::uuid, 'Family A', 'UTC', 'en-US', '10000000-0000-0000-0000-000000000001'::uuid),
  ('b0000000-0000-0000-0000-000000000001'::uuid, 'Family B', 'UTC', 'en-US', '10000000-0000-0000-0000-000000000004'::uuid)
on conflict (id) do nothing;

-- Family Memberships
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('a0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('b0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000004'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

-- Child Profiles: A1 (to be archived), A2 (active sibling), B1 (foreign family)
insert into public.child_profiles (id, family_id, display_name, avatar_key, school_grade, birth_year, status) values
  ('a1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Child A1', 'avatar_1', 4, 2015, 'active'),
  ('a2000000-0000-0000-0000-000000000002'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Child A2', 'avatar_2', 6, 2013, 'active'),
  ('b1000000-0000-0000-0000-000000000001'::uuid, 'b0000000-0000-0000-0000-000000000001'::uuid, 'Child B1', 'avatar_b', 3, 2016, 'active')
on conflict (id) do nothing;

-- Child Device Grants
insert into public.child_device_grants (id, family_id, child_id, auth_user_id, paired_by_user_id, status) values
  ('c1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000002'::uuid, '10000000-0000-0000-0000-000000000001'::uuid, 'active'),
  ('c2000000-0000-0000-0000-000000000002'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'a2000000-0000-0000-0000-000000000002'::uuid, '10000000-0000-0000-0000-000000000003'::uuid, '10000000-0000-0000-0000-000000000001'::uuid, 'active')
on conflict (id) do nothing;

-- Balances
insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor) values
  ('a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, 100, 5000),
  ('a0000000-0000-0000-0000-000000000001'::uuid, 'a2000000-0000-0000-0000-000000000002'::uuid, 200, 10000)
on conflict (child_id) do nothing;

insert into public.xp_ledger (id, family_id, child_id, amount, reason_code, source_type, idempotency_key) values
  (gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, 100, 'initial_grant', 'growth_event', 'init:xp:a1'),
  (gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001'::uuid, 'a2000000-0000-0000-0000-000000000002'::uuid, 200, 'initial_grant', 'growth_event', 'init:xp:a2')
on conflict (idempotency_key) do nothing;

insert into public.rp_ledger (id, family_id, child_id, amount_minor, reason_code, source_type, idempotency_key) values
  (gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, 5000, 'initial_grant', 'growth_event', 'init:rp:a1'),
  (gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001'::uuid, 'a2000000-0000-0000-0000-000000000002'::uuid, 10000, 'initial_grant', 'growth_event', 'init:rp:a2')
on conflict (idempotency_key) do nothing;

-- Family Wheel Settings
insert into public.family_wheel_settings (family_id, is_enabled, spin_cost_minor, daily_spin_cap) values
  ('a0000000-0000-0000-0000-000000000001'::uuid, true, 2500, 5)
on conflict (family_id) do nothing;

-- Store Rewards (3 rewards with wheel_enabled = true to satisfy wheel minimum pool)
insert into public.rewards (id, family_id, title, description, icon_key, category, store_cost_minor, store_enabled, wheel_enabled, wheel_tier, is_active) values
  ('d1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Reward 1', 'Desc 1', 'icon_1', 'treat', 1000, true, true, 'common', true),
  ('d2000000-0000-0000-0000-000000000002'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Reward 2', 'Desc 2', 'icon_2', 'privilege', 2000, true, true, 'rare', true),
  ('d3000000-0000-0000-0000-000000000003'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Reward 3', 'Desc 3', 'icon_3', 'experience', 3000, true, true, 'special', true)
on conflict (id) do nothing;

-- Initial Draft Assessments for A1 and A2
insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, learning_catalog_version, created_by_user_id) values
  ('e1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'A1 Draft', 'quiz', 'normal', 8, 10, 'draft', 'pilot-v0.1', '10000000-0000-0000-0000-000000000001'::uuid),
  ('e2000000-0000-0000-0000-000000000002'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, 'english', 'English', 'A1 Pending', 'quiz', 'normal', 9, 10, 'pending_review', 'pilot-v0.1', '10000000-0000-0000-0000-000000000001'::uuid),
  ('e3000000-0000-0000-0000-000000000003'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'a2000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'A2 Draft', 'quiz', 'normal', 10, 10, 'draft', 'pilot-v0.1', '10000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Evidence for A1 Draft
insert into public.assessment_evidence (id, family_id, assessment_id, storage_path, media_type, file_size_bytes, uploaded_by_user_id) values
  ('f1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'e1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001/e1000000-0000-0000-0000-000000000001/f1000000-0000-0000-0000-000000000001.jpg', 'image/jpeg', 1024, '10000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Command Receipt for Review Event
insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id) values
  ('80000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000001'::uuid, 'verify', 'e2000000-0000-0000-0000-000000000002'::uuid)
on conflict (command_id) do nothing;

-- Assessment Review Event for A1 Pending
insert into public.assessment_review_events (
  id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id, review_notes
) values (
  '80000001-0000-0000-0000-000000000001'::uuid, '80000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid,
  'e2000000-0000-0000-0000-000000000002'::uuid, 'verified', 'pending_review', 'verified',
  '10000000-0000-0000-0000-000000000001'::uuid, 'Review notes'
) on conflict (id) do nothing;

-- Verified Learning Event for A1 (to test Growth/Learning catch-up on archived child)
insert into public.verified_learning_events (
  id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty,
  raw_score, max_score, normalized_score, evidence_count, entry_context, occurred_at, verified_at,
  verified_by_user_id, review_event_id, learning_catalog_version, grade_level_snapshot
) values (
  '90000001-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid,
  'e2000000-0000-0000-0000-000000000002'::uuid, 'english', 'English', 'A1 Pending', 'quiz', 'normal',
  9, 10, 90.00, 0, 'adult', now() - interval '1 hour', now() - interval '30 minutes',
  '10000000-0000-0000-0000-000000000001'::uuid, '80000001-0000-0000-0000-000000000001'::uuid, 'pilot-v0.1', 4
) on conflict (id) do nothing;

-- Pending redemption for A1
insert into public.reward_redemptions (
  id, family_id, child_id, reward_id, origin, rp_cost_minor, reward_snapshot, status
) values (
  '90000002-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid,
  'd1000000-0000-0000-0000-000000000001'::uuid, 'store', 1000, '{"title": "Reward 1"}'::jsonb, 'pending_fulfillment'
) on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. ARCHIVE RPC FUNCTION EXISTENCE AND ACCESS PRIVILEGES (Tests 1-4)
-- ---------------------------------------------------------------------------

select has_function('public', 'archive_child_profile', array['uuid'], 'archive_child_profile RPC exists');

set local role anon;
select throws_ok(
  $$ select public.archive_child_profile('a1000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  null,
  'Anon role cannot execute archive_child_profile'
);

set local role authenticated;
select set_config('request.jwt.claims', '', true);
select throws_ok(
  $$ select public.archive_child_profile('a1000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Authentication required',
  'Unauthenticated authenticated call fails with 42501'
);

-- Foreign adult (Adult B) cannot archive Family A child
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.archive_child_profile('a1000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Unauthorized to archive child profile',
  'Foreign family adult cannot archive child profile'
);

-- Nonexistent child ID throws identical 42501 when called by Adult A (cannot determine child existence)
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.archive_child_profile('99999999-9999-9999-9999-999999999999'::uuid) $$,
  '42501',
  'Unauthorized to archive child profile',
  'Adult A archiving nonexistent child ID fails with 42501 Unauthorized'
);

-- Nonexistent child ID throws identical 42501 when called by Foreign Adult B (cannot determine child existence)
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.archive_child_profile('99999999-9999-9999-9999-999999999999'::uuid) $$,
  '42501',
  'Unauthorized to archive child profile',
  'Foreign Adult B archiving nonexistent child ID fails with 42501 Unauthorized'
);

-- ---------------------------------------------------------------------------
-- 3. ARCHIVAL EXECUTION & ATOMIC TIER 1-3 AUDIT (Tests 7-13)
-- ---------------------------------------------------------------------------

-- Switch to Adult A
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Call archive_child_profile for Child A1
select lives_ok(
  $$ select public.archive_child_profile('a1000000-0000-0000-0000-000000000001'::uuid) $$,
  'Adult A can successfully archive Child A1'
);

-- Inspect Child A1 profile state (switch to postgres to bypass RLS)
set local role postgres;

select is(
  (select status from public.child_profiles where id = 'a1000000-0000-0000-0000-000000000001'::uuid),
  'archived',
  'Child A1 status is archived'
);

select isnt(
  (select archived_at from public.child_profiles where id = 'a1000000-0000-0000-0000-000000000001'::uuid),
  null,
  'Child A1 archived_at is not null'
);

select is(
  (select display_name from public.child_profiles where id = 'a1000000-0000-0000-0000-000000000001'::uuid),
  '[Archived Learner]',
  'Child A1 display_name is pseudonymized to [Archived Learner]'
);

select is(
  (select (avatar_key is null and school_grade is null and birth_year is null) from public.child_profiles where id = 'a1000000-0000-0000-0000-000000000001'::uuid),
  true,
  'Child A1 avatar_key, school_grade, and birth_year are atomically nullified'
);

-- Tier 1: Device grants revoked
select is(
  (select status from public.child_device_grants where id = 'c1000000-0000-0000-0000-000000000001'::uuid),
  'revoked',
  'Child A1 device grant is revoked'
);

-- Re-archive attempt throws 42501
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.archive_child_profile('a1000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Child profile is already archived',
  'Attempting to archive already-archived child profile throws 42501'
);

-- ---------------------------------------------------------------------------
-- 4. MUTATION BARRIER ON ARCHIVED CHILD (Tests 12-32)
-- ---------------------------------------------------------------------------

-- 4.1 create_assessment_draft on archived child
select throws_ok(
  $$ select public.create_assessment_draft(gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'New Draft', 'quiz', 'normal', 5, 10) $$,
  'LW108',
  'Child profile not found or inactive',
  'create_assessment_draft on archived child fails closed'
);

-- 4.2 update_assessment_draft on archived child assessment
select throws_ok(
  $$ select public.update_assessment_draft('e1000000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'Updated Draft', 'quiz', 'normal', 7, 10, now(), 1) $$,
  '42501',
  'Child profile not found or archived',
  'update_assessment_draft on archived child fails closed'
);

-- 4.3 register_assessment_evidence on archived child assessment
select throws_ok(
  $$ select public.register_assessment_evidence('e1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001/e1000000-0000-0000-0000-000000000001/f2000000-0000-0000-0000-000000000002.jpg', 'image/jpeg', 2048) $$,
  '42501',
  'Child profile not found or archived',
  'register_assessment_evidence on archived child fails closed'
);

-- 4.4 remove_draft_assessment_evidence on archived child assessment
select throws_ok(
  $$ select public.remove_draft_assessment_evidence('f1000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Child profile not found or archived',
  'remove_draft_assessment_evidence on archived child fails closed'
);

-- 4.5 submit_assessment on archived child assessment
select throws_ok(
  $$ select public.submit_assessment('e1000000-0000-0000-0000-000000000001'::uuid, 1, gen_random_uuid()) $$,
  '42501',
  'Child profile is archived',
  'submit_assessment on archived child fails closed'
);

-- 4.6 verify_assessment on archived child assessment
select throws_ok(
  $$ select public.verify_assessment('e2000000-0000-0000-0000-000000000002'::uuid, 1, gen_random_uuid(), 'notes') $$,
  '42501',
  'Child profile is archived',
  'verify_assessment on archived child fails closed'
);

-- 4.7 reject_assessment on archived child assessment
select throws_ok(
  $$ select public.reject_assessment('e2000000-0000-0000-0000-000000000002'::uuid, 1, gen_random_uuid(), 'reason') $$,
  '42501',
  'Child profile is archived',
  'reject_assessment on archived child fails closed'
);

-- 4.8 set_assessment_learning_mappings on archived child assessment
select throws_ok(
  $$ select public.set_assessment_learning_mappings('e2000000-0000-0000-0000-000000000002'::uuid, '[{"learning_node_id": "b0000002-0000-0000-0000-000000000002", "component_key": "assessment_total", "score_source": "assessment_total"}]'::jsonb) $$,
  '42501',
  'Child profile is archived',
  'set_assessment_learning_mappings on archived child fails closed'
);

-- 4.9 redeem_store_reward on archived child
select throws_ok(
  $$ select public.redeem_store_reward('d1000000-0000-0000-0000-000000000001'::uuid, gen_random_uuid(), 'a1000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Child profile is archived',
  'redeem_store_reward on archived child fails closed'
);

-- 4.10 fulfill_reward_redemption for archived child redemption
select throws_ok(
  $$ select public.fulfill_reward_redemption('90000002-0000-0000-0000-000000000001'::uuid, gen_random_uuid()) $$,
  '42501',
  'Child profile is archived',
  'fulfill_reward_redemption for archived child fails closed'
);

-- 4.11 cancel_reward_redemption for archived child redemption
select throws_ok(
  $$ select public.cancel_reward_redemption('90000002-0000-0000-0000-000000000001'::uuid, gen_random_uuid(), 'Cancelled by parent') $$,
  '42501',
  'Child profile is archived',
  'cancel_reward_redemption for archived child fails closed'
);

-- 4.12 spin_reward_wheel for archived child
select throws_ok(
  $$ select public.spin_reward_wheel(gen_random_uuid(), 'a1000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Child profile is archived',
  'spin_reward_wheel for archived child fails closed'
);

-- 4.13 process_verified_learning_event for archived child VLE
select throws_ok(
  $$ select public.process_verified_learning_event('90000001-0000-0000-0000-000000000001'::uuid, gen_random_uuid()) $$,
  '42501',
  'Child profile is archived',
  'process_verified_learning_event for archived child fails closed'
);

-- 4.14 process_learning_event for archived child VLE
select throws_ok(
  $$ select public.process_learning_event(gen_random_uuid(), '90000001-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Child profile is archived',
  'process_learning_event for archived child fails closed'
);

-- 4.15 reconcile_child_balance for archived child
select throws_ok(
  $$ select * from public.reconcile_child_balance('a1000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Child profile is archived',
  'reconcile_child_balance for archived child fails closed'
);

-- 4.16 get_child_mastery for archived child
select throws_ok(
  $$ select public.get_child_mastery('a1000000-0000-0000-0000-000000000001'::uuid) $$,
  'P0002',
  'Child profile not found',
  'get_child_mastery for archived child fails closed'
);

-- 4.17 get_child_learning_overview for archived child
select throws_ok(
  $$ select public.get_child_learning_overview('a1000000-0000-0000-0000-000000000001'::uuid) $$,
  'P0002',
  'Child profile not found',
  'get_child_learning_overview for archived child fails closed'
);

-- 4.18 get_node_learning_state for archived child
select throws_ok(
  $$ select public.get_node_learning_state('a1000000-0000-0000-0000-000000000001'::uuid, 'b0000002-0000-0000-0000-000000000002'::uuid) $$,
  'P0002',
  'Child profile not found',
  'get_node_learning_state for archived child fails closed'
);

-- 4.19 get_next_challenge_candidates for archived child
select throws_ok(
  $$ select public.get_next_challenge_candidates('a1000000-0000-0000-0000-000000000001'::uuid, 'math', 3) $$,
  'P0002',
  'Child profile not found',
  'get_next_challenge_candidates for archived child fails closed'
);

-- 4.20 get_assessment_learning_mappings for archived child assessment
select throws_ok(
  $$ select public.get_assessment_learning_mappings('e2000000-0000-0000-0000-000000000002'::uuid) $$,
  '42501',
  'Child profile is archived',
  'get_assessment_learning_mappings for archived child fails closed'
);

-- 4.21 get_unprocessed_verified_learning_events excludes archived child
select is(
  (select count(*)::int from public.get_unprocessed_verified_learning_events('a0000000-0000-0000-0000-000000000001'::uuid)),
  0,
  'get_unprocessed_verified_learning_events excludes archived child events'
);

-- ---------------------------------------------------------------------------
-- 5. CATCH-UP EXCLUSION FOR ARCHIVED CHILDREN (Tests 35-36)
-- ---------------------------------------------------------------------------

select is(
  public.catch_up_unprocessed_growth('a0000000-0000-0000-0000-000000000001'::uuid),
  0,
  'catch_up_unprocessed_growth skips archived child and processes 0 events'
);

select is(
  (public.catch_up_unprocessed_learning('a0000000-0000-0000-0000-000000000001'::uuid)->>'processed_count')::int,
  0,
  'catch_up_unprocessed_learning skips archived child and processes 0 events'
);

-- ---------------------------------------------------------------------------
-- 6. ACTIVE SIBLING CHILD UNAFFECTED (Tests 37-44)
-- ---------------------------------------------------------------------------

-- 6.1 update_assessment_draft on active sibling Child A2
select lives_ok(
  $$ select public.update_assessment_draft('e3000000-0000-0000-0000-000000000003'::uuid, 'math', 'Math', 'A2 Updated', 'quiz', 'hard', 9, 10, now(), 1) $$,
  'update_assessment_draft succeeds for active child'
);

-- 6.2 submit_assessment on active sibling Child A2
select lives_ok(
  $$ select public.submit_assessment('e3000000-0000-0000-0000-000000000003'::uuid, 2, '70000000-0000-0000-0000-000000000001'::uuid) $$,
  'submit_assessment succeeds for active child'
);

-- 6.3 verify_assessment on active sibling Child A2
select lives_ok(
  $$ select public.verify_assessment('e3000000-0000-0000-0000-000000000003'::uuid, 3, '70000000-0000-0000-0000-000000000002'::uuid, 'Verified A2') $$,
  'verify_assessment succeeds for active child'
);

-- 6.4 redeem_store_reward on active sibling Child A2
select lives_ok(
  $$ select public.redeem_store_reward('d1000000-0000-0000-0000-000000000001'::uuid, '70000000-0000-0000-0000-000000000003'::uuid, 'a2000000-0000-0000-0000-000000000002'::uuid) $$,
  'redeem_store_reward succeeds for active child'
);

-- 6.5 cancel_reward_redemption on active sibling Child A2
select lives_ok(
  $$ select public.cancel_reward_redemption((select resource_id from public.command_receipts where command_id = '70000000-0000-0000-0000-000000000003'::uuid), '70000000-0000-0000-0000-000000000004'::uuid, 'Refunded for test') $$,
  'cancel_reward_redemption succeeds for active child'
);

-- 6.6 spin_reward_wheel on active sibling Child A2
select lives_ok(
  $$ select public.spin_reward_wheel('70000000-0000-0000-0000-000000000005'::uuid, 'a2000000-0000-0000-0000-000000000002'::uuid) $$,
  'spin_reward_wheel succeeds for active child'
);

-- 6.7 reconcile_child_balance for active sibling Child A2
select is(
  (select is_reconciled from public.reconcile_child_balance('a2000000-0000-0000-0000-000000000002'::uuid)),
  true,
  'reconcile_child_balance succeeds and reports true for active child'
);

-- 6.8 get_child_mastery for active sibling Child A2
select lives_ok(
  $$ select public.get_child_mastery('a2000000-0000-0000-0000-000000000002'::uuid) $$,
  'get_child_mastery succeeds for active child'
);

select * from finish();
rollback;
