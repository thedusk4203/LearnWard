-- ===========================================================================
-- LearnWard pgTAP Test Suite: Phase 6 Slice 3 - Family Data Export & Portability
--
-- Formal Specification:
-- - ACCEPTED ADR 0008: Pilot Hardening, Security, and Governance Boundaries
-- - Phase 6 Detailed Design §4.3.4: Schema-Verified Family Data Portability RPC
-- ===========================================================================

begin;
select plan(73);

-- ---------------------------------------------------------------------------
-- 1. FIXTURE SETUP
-- ---------------------------------------------------------------------------

-- Users:
-- Adult A (Owner of Family A)
-- Device A1 (Paired child device for Child A1)
-- Adult B (Owner of foreign Family B)
-- Parent A (Active parent in Family A, non-owner)
-- Revoked Adult A (Revoked parent membership in Family A)
-- Adult C (Owner of Empty Family C)
-- Device A2 (Paired child device for Child A2 prior to archival)
insert into auth.users (id, aud, role, email) values
  ('11000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'adult_exp_a@test.com'),
  ('11000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'child_exp_a1_dev@test.com'),
  ('11000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'adult_exp_b@test.com'),
  ('11000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'parent_exp_a@test.com'),
  ('11000000-0000-0000-0000-000000000005'::uuid, 'authenticated', 'authenticated', 'revoked_exp_a@test.com'),
  ('11000000-0000-0000-0000-000000000006'::uuid, 'authenticated', 'authenticated', 'adult_exp_c@test.com'),
  ('11000000-0000-0000-0000-000000000007'::uuid, 'authenticated', 'authenticated', 'child_exp_a2_dev@test.com')
on conflict (id) do nothing;

-- Families: Family A, Foreign Family B, and Empty Family C
insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('fa000000-0000-0000-0000-000000000001'::uuid, 'Export Family A', 'America/New_York', 'en-US', '11000000-0000-0000-0000-000000000001'::uuid),
  ('fb000000-0000-0000-0000-000000000001'::uuid, 'Foreign Family B', 'UTC', 'en-US', '11000000-0000-0000-0000-000000000003'::uuid),
  ('fc000000-0000-0000-0000-000000000001'::uuid, 'Empty Family C', 'America/Chicago', 'en-US', '11000000-0000-0000-0000-000000000006'::uuid)
on conflict (id) do nothing;

-- Family Memberships
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('fa000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('fa000000-0000-0000-0000-000000000004'::uuid, '11000000-0000-0000-0000-000000000004'::uuid, 'parent', 'active'),
  ('fa000000-0000-0000-0000-000000000005'::uuid, '11000000-0000-0000-0000-000000000005'::uuid, 'parent', 'revoked'),
  ('fb000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000003'::uuid, 'owner', 'active'),
  ('fc000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000006'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

-- Children:
-- Child A1: Active learner in Family A
-- Child A2: Active learner initially with historical records in Family A (to be archived via RPC)
-- Child B1: Active learner in Family B (tenant isolation check)
insert into public.child_profiles (id, family_id, display_name, avatar_key, school_grade, birth_year, status, created_at, archived_at) values
  ('ca100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Child A1', 'avatar_exp_1', 4, 2015, 'active', now() - interval '30 days', null),
  ('ca200000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Child A2 Prior Name', 'avatar_exp_2', 3, 2016, 'active', now() - interval '60 days', null),
  ('cb100000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'Child B1', 'avatar_b', 5, 2014, 'active', now() - interval '20 days', null)
on conflict (id) do nothing;

-- Paired device grants
insert into public.child_device_grants (id, family_id, child_id, auth_user_id, paired_by_user_id, status) values
  ('0a100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000002'::uuid, '11000000-0000-0000-0000-000000000001'::uuid, 'active'),
  ('0a200000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, '11000000-0000-0000-0000-000000000007'::uuid, '11000000-0000-0000-0000-000000000001'::uuid, 'active')
on conflict (id) do nothing;

-- Child Balances
insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor, updated_at) values
  ('fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 150, 4500, now()),
  ('fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, 300, 8000, now()),
  ('fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 500, 12000, now())
on conflict (child_id) do nothing;

-- Assessments:
-- Insert all assessments in 'draft' status initially so evidence can be attached
-- Ass 1: Draft for Child A1 (must be excluded from export)
-- Ass 2: Verified for Child A1 (must be included)
-- Ass 3: Verified historical assessment for Child A2 (must be included)
-- Ass 4: Pending review historical assessment for Child A2 (must be included)
-- Ass 5: Verified for Child B1 (foreign family, must be isolated)
insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, learning_catalog_version, created_by_user_id) values
  ('ea100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'A1 Draft Math', 'quiz', 'normal', 7, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000001'::uuid),
  ('ea200000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'A1 Verified Math', 'quiz', 'normal', 9, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000001'::uuid),
  ('ea300000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, 'english', 'English', 'A2 Verified English', 'quiz', 'normal', 8, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000001'::uuid),
  ('ea400000-0000-0000-0000-000000000004'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, 'science', 'Science', 'A2 Pending Science', 'quiz', 'normal', 7, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000001'::uuid),
  ('eb100000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'B1 Verified Math', 'quiz', 'normal', 10, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000003'::uuid)
on conflict (id) do nothing;

-- Assessment Evidence attached while assessments are in draft status
insert into public.assessment_evidence (id, family_id, assessment_id, storage_path, media_type, file_size_bytes, uploaded_by_user_id) values
  ('0e100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ea200000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001/ca100000-0000-0000-0000-000000000001/ea200000-0000-0000-0000-000000000002/ev1.jpg', 'image/jpeg', 2048, '11000000-0000-0000-0000-000000000001'::uuid),
  ('0e300000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ea300000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001/ca200000-0000-0000-0000-000000000002/ea300000-0000-0000-0000-000000000003/ev3.jpg', 'image/jpeg', 1024, '11000000-0000-0000-0000-000000000001'::uuid),
  ('0e200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'eb100000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000001/cb100000-0000-0000-0000-000000000001/eb100000-0000-0000-0000-000000000001/ev2.jpg', 'image/jpeg', 4096, '11000000-0000-0000-0000-000000000003'::uuid)
on conflict (id) do nothing;

-- Advance assessments to target statuses
update public.assessments set status = 'verified' where id in (
  'ea200000-0000-0000-0000-000000000002'::uuid,
  'ea300000-0000-0000-0000-000000000003'::uuid,
  'eb100000-0000-0000-0000-000000000001'::uuid
);

update public.assessments set status = 'pending_review' where id = 'ea400000-0000-0000-0000-000000000004'::uuid;

-- Command receipts & review events for verified assessments
insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id) values
  ('70000000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000001'::uuid, 'verify', 'ea200000-0000-0000-0000-000000000002'::uuid),
  ('70000000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000001'::uuid, 'verify', 'ea300000-0000-0000-0000-000000000003'::uuid),
  ('70000000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000003'::uuid, 'verify', 'eb100000-0000-0000-0000-000000000001'::uuid)
on conflict (command_id) do nothing;

insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id, review_notes) values
  ('71000000-0000-0000-0000-000000000001'::uuid, '70000000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ea200000-0000-0000-0000-000000000002'::uuid, 'verified', 'pending_review', 'verified', '11000000-0000-0000-0000-000000000001'::uuid, 'Good work A1'),
  ('71000000-0000-0000-0000-000000000003'::uuid, '70000000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ea300000-0000-0000-0000-000000000003'::uuid, 'verified', 'pending_review', 'verified', '11000000-0000-0000-0000-000000000001'::uuid, 'Historical work A2'),
  ('71000000-0000-0000-0000-000000000002'::uuid, '70000000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'eb100000-0000-0000-0000-000000000001'::uuid, 'verified', 'pending_review', 'verified', '11000000-0000-0000-0000-000000000003'::uuid, 'Good work B1')
on conflict (id) do nothing;

-- Verified Learning Events (including historical event for Child A2)
insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, evidence_count, entry_context, occurred_at, verified_at, verified_by_user_id, review_event_id, learning_catalog_version, grade_level_snapshot) values
  ('ba100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'ea200000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'A1 Verified Math', 'quiz', 'normal', 9, 10, 9.00, 1, 'adult', now() - interval '2 days', now() - interval '2 days', '11000000-0000-0000-0000-000000000001'::uuid, '71000000-0000-0000-0000-000000000001'::uuid, 'pilot-v0.1', 4),
  ('ba200000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, 'ea300000-0000-0000-0000-000000000003'::uuid, 'english', 'English', 'A2 Verified English', 'quiz', 'normal', 8, 10, 8.00, 1, 'adult', now() - interval '10 days', now() - interval '10 days', '11000000-0000-0000-0000-000000000001'::uuid, '71000000-0000-0000-0000-000000000003'::uuid, 'pilot-v0.1', 3),
  ('bb100000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 'eb100000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'B1 Verified Math', 'quiz', 'normal', 10, 10, 10.00, 1, 'adult', now() - interval '1 day', now() - interval '1 day', '11000000-0000-0000-0000-000000000003'::uuid, '71000000-0000-0000-0000-000000000002'::uuid, 'pilot-v0.1', 5)
on conflict (id) do nothing;

-- Growth Events (including historical growth event for Child A2)
insert into public.growth_events (id, family_id, child_id, verified_learning_event_id, assessment_id, engine_version, normalized_score, baseline_score, baseline_sample_count, growth_delta, historical_best, score_rp_minor, total_rp_minor, xp_awarded, inputs_snapshot, created_at) values
  ('cc100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'ba100000-0000-0000-0000-000000000001'::uuid, 'ea200000-0000-0000-0000-000000000002'::uuid, 'growth-v0.1', 9.00, 8.00, 1, 1.00, 9.00, 900, 1200, 34, '{}'::jsonb, now() - interval '2 days'),
  ('cc300000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, 'ba200000-0000-0000-0000-000000000002'::uuid, 'ea300000-0000-0000-0000-000000000003'::uuid, 'growth-v0.1', 8.00, 7.00, 1, 1.00, 8.00, 800, 1000, 25, '{}'::jsonb, now() - interval '10 days'),
  ('cc200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 'bb100000-0000-0000-0000-000000000001'::uuid, 'eb100000-0000-0000-0000-000000000001'::uuid, 'growth-v0.1', 10.00, 9.00, 1, 1.00, 10.00, 1000, 1500, 40, '{}'::jsonb, now() - interval '1 day')
on conflict (id) do nothing;

-- XP Ledger (including historical ledger entry for Child A2)
insert into public.xp_ledger (id, family_id, child_id, amount, reason_code, source_type, idempotency_key, created_at) values
  ('dd100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 34, 'growth_award', 'growth_event', 'xp:gr1', now() - interval '2 days'),
  ('dd300000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, 25, 'growth_award', 'growth_event', 'xp:gr3', now() - interval '10 days'),
  ('dd200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 40, 'growth_award', 'growth_event', 'xp:gr2', now() - interval '1 day')
on conflict (idempotency_key) do nothing;

-- RP Ledger (including historical ledger entry for Child A2)
insert into public.rp_ledger (id, family_id, child_id, amount_minor, reason_code, source_type, idempotency_key, created_at) values
  ('ee100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 1200, 'growth_award', 'growth_event', 'rp:gr1', now() - interval '2 days'),
  ('ee300000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, 1000, 'growth_award', 'growth_event', 'rp:gr3', now() - interval '10 days'),
  ('ee200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 1500, 'growth_award', 'growth_event', 'rp:gr2', now() - interval '1 day')
on conflict (idempotency_key) do nothing;

-- Rewards
insert into public.rewards (id, family_id, title, description, icon_key, category, store_cost_minor, store_enabled, wheel_enabled, wheel_tier, is_active) values
  ('aa100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Family A Book', 'Desc', 'book', 'treat', 1000, true, true, 'common', true),
  ('aa200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'Family B Toy', 'Desc', 'toy', 'treat', 1500, true, true, 'common', true)
on conflict (id) do nothing;

-- Reward Redemptions
insert into public.reward_redemptions (id, family_id, child_id, reward_id, origin, rp_cost_minor, status, reward_snapshot, created_at) values
  ('ab100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'aa100000-0000-0000-0000-000000000001'::uuid, 'wheel', 1000, 'fulfilled', '{"title": "Family A Book"}'::jsonb, now() - interval '3 days'),
  ('ab200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 'aa200000-0000-0000-0000-000000000002'::uuid, 'store', 1500, 'fulfilled', '{"title": "Family B Toy"}'::jsonb, now() - interval '2 days')
on conflict (id) do nothing;

-- Wheel Spins
insert into public.wheel_spins (id, family_id, child_id, reward_id, redemption_id, origin, spin_cost_minor, selection_snapshot, created_at) values
  ('ac100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'aa100000-0000-0000-0000-000000000001'::uuid, 'ab100000-0000-0000-0000-000000000001'::uuid, 'wheel', 1000, '{"winning_tier": "common"}'::jsonb, now() - interval '3 days')
on conflict (id) do nothing;


-- ---------------------------------------------------------------------------
-- 2. SECURITY & AUTHORIZATION TESTS
-- ---------------------------------------------------------------------------

-- Test 1: Anonymous caller cannot export family data
set role anon;
select throws_ok(
  $$ select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Anonymous caller cannot execute export_family_data_json'
);

-- Test 2: Unauthenticated caller throws 42501
set role authenticated;
select set_config('request.jwt.claims', '', true);
select throws_ok(
  $$ select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Unauthenticated caller (null uid) throws 42501'
);

-- Test 3: Null family_id throws 22000
select set_config('request.jwt.claims', '{"sub": "11000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.export_family_data_json(null) $$,
  '22000',
  'Family ID is required',
  'Null family_id throws SQLSTATE 22000'
);

-- Test 4: Paired child caller throws 42501
select set_config('request.jwt.claims', '{"sub": "11000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Unauthorized to export family data',
  'Paired child caller throws 42501 Unauthorized'
);

-- Test 5: Foreign family adult caller throws 42501
select set_config('request.jwt.claims', '{"sub": "11000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Unauthorized to export family data',
  'Foreign family adult caller throws 42501 Unauthorized'
);

-- Test 6: Revoked adult membership is denied (42501)
select set_config('request.jwt.claims', '{"sub": "11000000-0000-0000-0000-000000000005", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  'Unauthorized to export family data',
  'Revoked adult membership in Family A is denied (42501)'
);

-- Test 7: Active non-owner parent in Family A succeeds
select set_config('request.jwt.claims', '{"sub": "11000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);
select lives_ok(
  $$ select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) $$,
  'Active non-owner parent caller of Family A succeeds'
);

-- Test 8: Active owner adult of Family A succeeds
select set_config('request.jwt.claims', '{"sub": "11000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select lives_ok(
  $$ select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) $$,
  'Active adult owner caller of Family A succeeds'
);


-- ---------------------------------------------------------------------------
-- 3. FUNCTION CONTRACT & CATALOG SECURITY
-- ---------------------------------------------------------------------------

-- Test 9: export_family_data_json(uuid) exists in public schema
select has_function('public', 'export_family_data_json', array['uuid'], 'export_family_data_json(uuid) exists');

-- Test 10: export_family_data_json returns jsonb
select is(
  (select prorettype::regtype::text from pg_proc where pronamespace = 'public'::regnamespace and proname = 'export_family_data_json'),
  'jsonb',
  'export_family_data_json return type is jsonb'
);

-- Test 11: export_family_data_json is SECURITY DEFINER
select is(
  (select prosecdef from pg_proc where pronamespace = 'public'::regnamespace and proname = 'export_family_data_json'),
  true,
  'export_family_data_json is declared SECURITY DEFINER'
);

-- Test 12: export_family_data_json has secure search_path empty
select ok(
  (select proconfig::text from pg_proc where pronamespace = 'public'::regnamespace and proname = 'export_family_data_json') ilike '%search_path=%',
  'export_family_data_json has secure search_path empty configuration'
);

-- Test 13: export_family_data_json volatility is STABLE
select is(
  (select provolatile from pg_proc where pronamespace = 'public'::regnamespace and proname = 'export_family_data_json'),
  's',
  'export_family_data_json volatility is declared STABLE'
);

-- Test 14: Authenticated role has execute permission
select ok(
  has_function_privilege('authenticated', 'public.export_family_data_json(uuid)', 'execute'),
  'authenticated role has execute permission'
);

-- Test 15: Anon role does NOT have execute permission
select ok(
  not has_function_privilege('anon', 'public.export_family_data_json(uuid)', 'execute'),
  'anon role does NOT have execute permission'
);

-- Test 16: Public pseudo-role does NOT have execute permission
select ok(
  not has_function_privilege('public', 'public.export_family_data_json(uuid)', 'execute'),
  'public pseudo-role does NOT have execute permission'
);

-- Test 17: Read-only stability: repeated invocations on unchanged data yield identical payload
select is(
  public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid),
  public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid),
  'Read-only stability: repeated invocations on unchanged data produce identical payload'
);


-- ---------------------------------------------------------------------------
-- 4. REAL CHILD ARCHIVAL LIFECYCLE EXECUTION
-- ---------------------------------------------------------------------------

-- Test 18: Authoritative child archival executes successfully for Child A2
select lives_ok(
  $$ select public.archive_child_profile('ca200000-0000-0000-0000-000000000002'::uuid) $$,
  'Active adult successfully archives Child A2 via authoritative archive_child_profile RPC'
);

-- Test 19: Child A2 paired device grant is transitioned to revoked by archival RPC
select is(
  (select status from public.child_device_grants where id = '0a200000-0000-0000-0000-000000000002'::uuid),
  'revoked',
  'Child A2 device grant revoked by authoritative archive_child_profile'
);


-- ---------------------------------------------------------------------------
-- 5. PAYLOAD STRUCTURE, TOP-LEVEL KEYS & INTERNAL FIELD SANITIZATION
-- ---------------------------------------------------------------------------

-- Test 20: export_version is 1
select is(
  (public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) ->> 'export_version')::int,
  1,
  'Export payload export_version is 1'
);

-- Test 21: exported_at is not null
select ok(
  (public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) ->> 'exported_at') is not null,
  'Export payload contains non-null exported_at timestamp'
);

-- Test 22: Exactly 14 approved top-level keys exist in export payload
select is(
  (select count(*)::int from jsonb_object_keys(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid))),
  14,
  'Export payload contains exactly 14 approved top-level keys'
);

-- Test 23: All approved top-level keys match expected JSON types
select ok(
  (
    select jsonb_typeof(exp -> 'export_version') = 'number' and
           jsonb_typeof(exp -> 'exported_at') = 'string' and
           jsonb_typeof(exp -> 'family') = 'object' and
           jsonb_typeof(exp -> 'children') = 'array' and
           jsonb_typeof(exp -> 'child_balances') = 'array' and
           jsonb_typeof(exp -> 'assessments') = 'array' and
           jsonb_typeof(exp -> 'assessment_evidence') = 'array' and
           jsonb_typeof(exp -> 'verified_learning_events') = 'array' and
           jsonb_typeof(exp -> 'mastery_states') = 'array' and
           jsonb_typeof(exp -> 'growth_events') = 'array' and
           jsonb_typeof(exp -> 'xp_ledger') = 'array' and
           jsonb_typeof(exp -> 'rp_ledger') = 'array' and
           jsonb_typeof(exp -> 'reward_redemptions') = 'array' and
           jsonb_typeof(exp -> 'wheel_spins') = 'array'
    from (select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) as exp) as sub
  ),
  'All approved top-level keys match expected JSON data types'
);

-- Test 24: No internal idempotency_key leaked in xp_ledger
select ok(
  (
    select bool_and((entry ? 'idempotency_key') = false)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'xp_ledger') as entry
  ),
  'xp_ledger does not leak internal idempotency_key'
);

-- Test 25: No internal idempotency_key leaked in rp_ledger
select ok(
  (
    select bool_and((entry ? 'idempotency_key') = false)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'rp_ledger') as entry
  ),
  'rp_ledger does not leak internal idempotency_key'
);

-- Test 26: No internal created_by_user_id leaked in family
select ok(
  ((public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'family') ? 'created_by_user_id') = false,
  'family object does not leak internal created_by_user_id'
);

-- Test 27: No internal created_by_user_id leaked in assessments
select ok(
  (
    select bool_and((a ? 'created_by_user_id') = false)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
  ),
  'assessments array does not leak internal created_by_user_id'
);

-- Test 28: No internal uploaded_by_user_id leaked in assessment_evidence
select ok(
  (
    select bool_and((e ? 'uploaded_by_user_id') = false)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessment_evidence') as e
  ),
  'assessment_evidence array does not leak internal uploaded_by_user_id'
);


-- ---------------------------------------------------------------------------
-- 6. FAMILY DETAILS
-- ---------------------------------------------------------------------------

-- Test 29: family.id matches Family A ID
select is(
  public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'family' ->> 'id',
  'fa000000-0000-0000-0000-000000000001',
  'family.id matches requested family'
);

-- Test 30: family.name matches Family A name
select is(
  public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'family' ->> 'name',
  'Export Family A',
  'family.name matches Family A'
);

-- Test 31: family.timezone and locale are present
select is(
  public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'family' ->> 'timezone',
  'America/New_York',
  'family.timezone matches America/New_York'
);


-- ---------------------------------------------------------------------------
-- 7. MULTI-CHILD CONTINUITY & ARCHIVAL PSEUDONYMIZATION
-- ---------------------------------------------------------------------------

-- Test 32: children array has exactly 2 children (both active A1 and archived A2)
select is(
  jsonb_array_length(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children'),
  2,
  'children array contains exactly 2 children (both active A1 and archived A2)'
);

-- Test 33: Active child A1 retains normal profile fields and null archived_at
select ok(
  (
    select c ->> 'display_name' = 'Child A1' and
           c ->> 'avatar_key' = 'avatar_exp_1' and
           (c ->> 'school_grade')::int = 4 and
           (c ->> 'birth_year')::int = 2015 and
           c ->> 'status' = 'active' and
           (c ->> 'archived_at') is null
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'ca100000-0000-0000-0000-000000000001'
  ),
  'Active child A1 preserves display_name, avatar_key, grade, year and null archived_at'
);

-- Test 34: Archived child A2 reflects Tier 3 pseudonymization: [Archived Learner]
select is(
  (
    select c ->> 'display_name'
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  '[Archived Learner]',
  'Archived child A2 reflects pseudonymized display_name "[Archived Learner]"'
);

-- Test 35: Archived child A2 scrubbed sensitive attributes (null grade, year, avatar)
select ok(
  (
    select (c ->> 'avatar_key') is null and
           (c ->> 'school_grade') is null and
           (c ->> 'birth_year') is null and
           c ->> 'status' = 'archived'
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  'Archived child A2 attributes are scrubbed (null avatar, grade, birth_year)'
);

-- Test 36: Archived child A2 has non-null archived_at timestamp
select ok(
  (
    select (c ->> 'archived_at') is not null
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  'Archived child A2 has non-null archived_at timestamp'
);


-- ---------------------------------------------------------------------------
-- 8. HISTORICAL LEARNING & ECONOMIC CONTINUITY FOR ARCHIVED CHILD
-- ---------------------------------------------------------------------------

-- Test 37: Archived child A2 historical verified assessment (ea3) is present and associated
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'ea300000-0000-0000-0000-000000000003'
      and a ->> 'child_id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Archived child A2 historical verified assessment ea3 is present and correctly associated'
);

-- Test 38: Archived child A2 historical pending review assessment (ea4) is present and associated
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'ea400000-0000-0000-0000-000000000004'
      and a ->> 'child_id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Archived child A2 historical pending review assessment ea4 is present and correctly associated'
);

-- Test 39: Archived child A2 historical VLE (ba2) is present and associated
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'verified_learning_events') as v
    where v ->> 'id' = 'ba200000-0000-0000-0000-000000000002'
      and v ->> 'child_id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Archived child A2 historical VLE ba2 is present and correctly associated'
);

-- Test 40: Archived child A2 historical Growth Event (cc3) is present and associated
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'growth_events') as g
    where g ->> 'id' = 'cc300000-0000-0000-0000-000000000003'
      and g ->> 'child_id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Archived child A2 historical Growth Event cc3 is present and correctly associated'
);

-- Test 41: Archived child A2 historical XP ledger entry (dd3) is present and associated
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'xp_ledger') as x
    where x ->> 'id' = 'dd300000-0000-0000-0000-000000000003'
      and x ->> 'child_id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Archived child A2 historical XP ledger entry dd3 is present and correctly associated'
);

-- Test 42: Archived child A2 historical RP ledger entry (ee3) is present and associated
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'rp_ledger') as r
    where r ->> 'id' = 'ee300000-0000-0000-0000-000000000003'
      and r ->> 'child_id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Archived child A2 historical RP ledger entry ee3 is present and correctly associated'
);

-- Test 43: Archived child A2 balance is present in child_balances
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'child_balances') as cb
    where cb ->> 'child_id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Archived child A2 balance is present in child_balances'
);


-- ---------------------------------------------------------------------------
-- 9. ASSESSMENT FILTERING & DRAFT EXCLUSION
-- ---------------------------------------------------------------------------

-- Test 44: Draft assessment (ea1) is excluded from export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'ea100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Draft assessment ea1 is excluded from assessments array'
);

-- Test 45: Verified assessment (ea2) is included in export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'ea200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Verified assessment ea2 is included in assessments array'
);


-- ---------------------------------------------------------------------------
-- 10. DATA MINIMIZATION & MEDIA BOUNDARY TESTS
-- ---------------------------------------------------------------------------

-- Test 46: assessment_evidence contains relative storage_path
select is(
  (
    select e ->> 'storage_path'
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessment_evidence') as e
    where e ->> 'id' = '0e100000-0000-0000-0000-000000000001'
  ),
  'fa000000-0000-0000-0000-000000000001/ca100000-0000-0000-0000-000000000001/ea200000-0000-0000-0000-000000000002/ev1.jpg',
  'assessment_evidence exports relative storage_path'
);

-- Test 47: assessment_evidence contains zero raw byte columns (data, bytes, payload are missing)
select ok(
  (
    select (e ? 'data') = false and (e ? 'bytes') = false and (e ? 'image_bytes') = false
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessment_evidence') as e
    where e ->> 'id' = '0e100000-0000-0000-0000-000000000001'
  ),
  'assessment_evidence adheres to data minimization: zero raw image bytes exported'
);


-- ---------------------------------------------------------------------------
-- 11. ECONOMIC & LEARNING COMPLETENESS (ACTIVE CHILD A1)
-- ---------------------------------------------------------------------------

-- Test 48: verified_learning_events contains Family A verified event
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'verified_learning_events') as v
    where v ->> 'id' = 'ba100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'verified_learning_events exports Family A VLE ba1'
);

-- Test 49: growth_events contains Family A growth event
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'growth_events') as g
    where g ->> 'id' = 'cc100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'growth_events exports Family A growth event cc1'
);

-- Test 50: xp_ledger contains Family A xp record
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'xp_ledger') as x
    where x ->> 'id' = 'dd100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'xp_ledger exports Family A XP record dd1'
);

-- Test 51: rp_ledger contains Family A rp record
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'rp_ledger') as r
    where r ->> 'id' = 'ee100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'rp_ledger exports Family A RP record ee1'
);

-- Test 52: reward_redemptions contains Family A redemption
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'reward_redemptions') as rd
    where rd ->> 'id' = 'ab100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'reward_redemptions exports Family A redemption ab1'
);

-- Test 53: wheel_spins contains Family A spin
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'wheel_spins') as ws
    where ws ->> 'id' = 'ac100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'wheel_spins exports Family A wheel spin ac1'
);


-- ---------------------------------------------------------------------------
-- 12. STRICT TENANT ISOLATION TESTS
-- ---------------------------------------------------------------------------

-- Test 54: Foreign child B1 is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'cb100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Foreign child B1 is completely excluded from Family A children array'
);

-- Test 55: Foreign assessment B1 is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'eb100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Foreign assessment B1 is completely excluded from Family A assessments array'
);

-- Test 56: Foreign balance is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'child_balances') as b
    where b ->> 'child_id' = 'cb100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Foreign child balance is completely excluded from Family A child_balances array'
);

-- Test 57: Foreign XP ledger row is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'xp_ledger') as x
    where x ->> 'id' = 'dd200000-0000-0000-0000-000000000002'
  ),
  0::bigint,
  'Foreign XP ledger row is completely excluded from Family A xp_ledger array'
);

-- Test 58: Foreign RP ledger row is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'rp_ledger') as r
    where r ->> 'id' = 'ee200000-0000-0000-0000-000000000002'
  ),
  0::bigint,
  'Foreign RP ledger row is completely excluded from Family A rp_ledger array'
);

-- Test 59: Foreign VLE is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'verified_learning_events') as v
    where v ->> 'id' = 'bb100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Foreign VLE bb1 is completely excluded from Family A verified_learning_events array'
);

-- Test 60: Foreign Growth Event is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'growth_events') as g
    where g ->> 'id' = 'cc200000-0000-0000-0000-000000000002'
  ),
  0::bigint,
  'Foreign Growth event cc2 is completely excluded from Family A growth_events array'
);

-- Test 61: Foreign Reward Redemption is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'reward_redemptions') as rd
    where rd ->> 'id' = 'ab200000-0000-0000-0000-000000000002'
  ),
  0::bigint,
  'Foreign Reward redemption ab2 is completely excluded from Family A reward_redemptions array'
);


-- ---------------------------------------------------------------------------
-- 13. EMPTY COLLECTIONS SERIALIZATION (FAMILY C)
-- ---------------------------------------------------------------------------

-- Test 62: Empty Family C export executes successfully
select set_config('request.jwt.claims', '{"sub": "11000000-0000-0000-0000-000000000006", "role": "authenticated"}', true);
select lives_ok(
  $$ select public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) $$,
  'Export for Empty Family C succeeds for active owner'
);

-- Test 63: Empty Family C children serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'children',
  '[]'::jsonb,
  'Empty Family C children collection serializes as [], not null'
);

-- Test 64: Empty Family C child_balances serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'child_balances',
  '[]'::jsonb,
  'Empty Family C child_balances collection serializes as [], not null'
);

-- Test 65: Empty Family C assessments serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'assessments',
  '[]'::jsonb,
  'Empty Family C assessments collection serializes as [], not null'
);

-- Test 66: Empty Family C assessment_evidence serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'assessment_evidence',
  '[]'::jsonb,
  'Empty Family C assessment_evidence collection serializes as [], not null'
);

-- Test 67: Empty Family C verified_learning_events serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'verified_learning_events',
  '[]'::jsonb,
  'Empty Family C verified_learning_events collection serializes as [], not null'
);

-- Test 68: Empty Family C mastery_states serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'mastery_states',
  '[]'::jsonb,
  'Empty Family C mastery_states collection serializes as [], not null'
);

-- Test 69: Empty Family C growth_events serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'growth_events',
  '[]'::jsonb,
  'Empty Family C growth_events collection serializes as [], not null'
);

-- Test 70: Empty Family C xp_ledger serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'xp_ledger',
  '[]'::jsonb,
  'Empty Family C xp_ledger collection serializes as [], not null'
);

-- Test 71: Empty Family C rp_ledger serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'rp_ledger',
  '[]'::jsonb,
  'Empty Family C rp_ledger collection serializes as [], not null'
);

-- Test 72: Empty Family C reward_redemptions serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'reward_redemptions',
  '[]'::jsonb,
  'Empty Family C reward_redemptions collection serializes as [], not null'
);

-- Test 73: Empty Family C wheel_spins serializes as [], not null
select is(
  public.export_family_data_json('fc000000-0000-0000-0000-000000000001'::uuid) -> 'wheel_spins',
  '[]'::jsonb,
  'Empty Family C wheel_spins collection serializes as [], not null'
);

rollback;
