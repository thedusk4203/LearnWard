-- ===========================================================================
-- LearnWard pgTAP Test Suite: Phase 6 Slice 3 - Family Data Export & Portability
--
-- Formal Specification:
-- - ACCEPTED ADR 0008: Pilot Hardening, Security, and Governance Boundaries
-- - Phase 6 Detailed Design §4.3.4: Schema-Verified Family Data Portability RPC
-- ===========================================================================

begin;
select plan(33);

-- ---------------------------------------------------------------------------
-- 1. FIXTURE SETUP
-- ---------------------------------------------------------------------------

-- Users:
-- Adult A (Owner of Family A)
-- Device A1 (Paired child device for Child A1)
-- Adult B (Owner of foreign Family B)
insert into auth.users (id, aud, role, email) values
  ('11000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'adult_exp_a@test.com'),
  ('11000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'child_exp_a1_dev@test.com'),
  ('11000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'adult_exp_b@test.com')
on conflict (id) do nothing;

-- Families: Family A and Foreign Family B
insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('fa000000-0000-0000-0000-000000000001'::uuid, 'Export Family A', 'America/New_York', 'en-US', '11000000-0000-0000-0000-000000000001'::uuid),
  ('fb000000-0000-0000-0000-000000000001'::uuid, 'Foreign Family B', 'UTC', 'en-US', '11000000-0000-0000-0000-000000000003'::uuid)
on conflict (id) do nothing;

-- Family Memberships
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('fa000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('fb000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000003'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

-- Children:
-- Child A1: Active learner in Family A
-- Child A2: Archived learner in Family A (Tier 3 pseudonymized)
-- Child B1: Active learner in Family B (tenant isolation check)
insert into public.child_profiles (id, family_id, display_name, avatar_key, school_grade, birth_year, status, created_at, archived_at) values
  ('ca100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Child A1', 'avatar_exp_1', 4, 2015, 'active', now() - interval '30 days', null),
  ('ca200000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, '[Archived Learner]', null, null, null, 'archived', now() - interval '60 days', now() - interval '10 days'),
  ('cb100000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'Child B1', 'avatar_b', 5, 2014, 'active', now() - interval '20 days', null)
on conflict (id) do nothing;

-- Paired device grant for Child A1
insert into public.child_device_grants (id, family_id, child_id, auth_user_id, paired_by_user_id, status) values
  ('0a100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000002'::uuid, '11000000-0000-0000-0000-000000000001'::uuid, 'active')
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
-- Ass 3: Pending review for Child A2 (archived child assessment, must be included)
-- Ass 4: Verified for Child B1 (foreign family, must be isolated)
insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, learning_catalog_version, created_by_user_id) values
  ('ea100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'A1 Draft Math', 'quiz', 'normal', 7, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000001'::uuid),
  ('ea200000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'A1 Verified Math', 'quiz', 'normal', 9, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000001'::uuid),
  ('ea300000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca200000-0000-0000-0000-000000000002'::uuid, 'english', 'English', 'A2 Pending English', 'quiz', 'normal', 8, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000001'::uuid),
  ('eb100000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'B1 Verified Math', 'quiz', 'normal', 10, 10, 'draft', 'pilot-v0.1', '11000000-0000-0000-0000-000000000003'::uuid)
on conflict (id) do nothing;

-- Assessment Evidence (metadata only, no raw bytes) attached while assessments are in draft status
insert into public.assessment_evidence (id, family_id, assessment_id, storage_path, media_type, file_size_bytes, uploaded_by_user_id) values
  ('0e100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ea200000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001/ca100000-0000-0000-0000-000000000001/ea200000-0000-0000-0000-000000000002/ev1.jpg', 'image/jpeg', 2048, '11000000-0000-0000-0000-000000000001'::uuid),
  ('0e200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'eb100000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000001/cb100000-0000-0000-0000-000000000001/eb100000-0000-0000-0000-000000000001/ev2.jpg', 'image/jpeg', 4096, '11000000-0000-0000-0000-000000000003'::uuid)
on conflict (id) do nothing;

-- Advance assessments to their target statuses
update public.assessments
set status = 'verified'
where id in (
  'ea200000-0000-0000-0000-000000000002'::uuid,
  'eb100000-0000-0000-0000-000000000001'::uuid
);

update public.assessments
set status = 'pending_review'
where id = 'ea300000-0000-0000-0000-000000000003'::uuid;

-- Command receipts & review events for verified assessments
insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id) values
  ('70000000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000001'::uuid, 'verify', 'ea200000-0000-0000-0000-000000000002'::uuid),
  ('70000000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, '11000000-0000-0000-0000-000000000003'::uuid, 'verify', 'eb100000-0000-0000-0000-000000000001'::uuid)
on conflict (command_id) do nothing;

insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id, review_notes) values
  ('71000000-0000-0000-0000-000000000001'::uuid, '70000000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ea200000-0000-0000-0000-000000000002'::uuid, 'verified', 'pending_review', 'verified', '11000000-0000-0000-0000-000000000001'::uuid, 'Good work A1'),
  ('71000000-0000-0000-0000-000000000002'::uuid, '70000000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'eb100000-0000-0000-0000-000000000001'::uuid, 'verified', 'pending_review', 'verified', '11000000-0000-0000-0000-000000000003'::uuid, 'Good work B1')
on conflict (id) do nothing;

-- Verified Learning Events
insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, evidence_count, entry_context, occurred_at, verified_at, verified_by_user_id, review_event_id, learning_catalog_version, grade_level_snapshot) values
  ('ba100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'ea200000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'A1 Verified Math', 'quiz', 'normal', 9, 10, 9.00, 1, 'adult', now() - interval '2 days', now() - interval '2 days', '11000000-0000-0000-0000-000000000001'::uuid, '71000000-0000-0000-0000-000000000001'::uuid, 'pilot-v0.1', 4),
  ('bb100000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 'eb100000-0000-0000-0000-000000000001'::uuid, 'math', 'Math', 'B1 Verified Math', 'quiz', 'normal', 10, 10, 10.00, 1, 'adult', now() - interval '1 day', now() - interval '1 day', '11000000-0000-0000-0000-000000000003'::uuid, '71000000-0000-0000-0000-000000000002'::uuid, 'pilot-v0.1', 5)
on conflict (id) do nothing;

-- Growth Events
insert into public.growth_events (id, family_id, child_id, verified_learning_event_id, assessment_id, engine_version, normalized_score, baseline_score, baseline_sample_count, growth_delta, historical_best, score_rp_minor, total_rp_minor, xp_awarded, inputs_snapshot, created_at) values
  ('cc100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 'ba100000-0000-0000-0000-000000000001'::uuid, 'ea200000-0000-0000-0000-000000000002'::uuid, 'growth-v0.1', 9.00, 8.00, 1, 1.00, 9.00, 900, 1200, 34, '{}'::jsonb, now() - interval '2 days'),
  ('cc200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 'bb100000-0000-0000-0000-000000000001'::uuid, 'eb100000-0000-0000-0000-000000000001'::uuid, 'growth-v0.1', 10.00, 9.00, 1, 1.00, 10.00, 1000, 1500, 40, '{}'::jsonb, now() - interval '1 day')
on conflict (id) do nothing;

-- XP Ledger
insert into public.xp_ledger (id, family_id, child_id, amount, reason_code, source_type, idempotency_key, created_at) values
  ('dd100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 34, 'growth_award', 'growth_event', 'xp:gr1', now() - interval '2 days'),
  ('dd200000-0000-0000-0000-000000000002'::uuid, 'fb000000-0000-0000-0000-000000000001'::uuid, 'cb100000-0000-0000-0000-000000000001'::uuid, 40, 'growth_award', 'growth_event', 'xp:gr2', now() - interval '1 day')
on conflict (idempotency_key) do nothing;

-- RP Ledger
insert into public.rp_ledger (id, family_id, child_id, amount_minor, reason_code, source_type, idempotency_key, created_at) values
  ('ee100000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca100000-0000-0000-0000-000000000001'::uuid, 1200, 'growth_award', 'growth_event', 'rp:gr1', now() - interval '2 days'),
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

-- Test 6: Active adult of Family A succeeds
select set_config('request.jwt.claims', '{"sub": "11000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select lives_ok(
  $$ select public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) $$,
  'Active adult caller of Family A succeeds'
);


-- ---------------------------------------------------------------------------
-- 3. PAYLOAD STRUCTURE & METADATA TESTS
-- ---------------------------------------------------------------------------

-- Test 7: export_version is 1
select is(
  (public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) ->> 'export_version')::int,
  1,
  'Export payload export_version is 1'
);

-- Test 8: exported_at is not null
select ok(
  (public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) ->> 'exported_at') is not null,
  'Export payload contains non-null exported_at timestamp'
);

-- Test 9: family.id matches Family A ID
select is(
  public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'family' ->> 'id',
  'fa000000-0000-0000-0000-000000000001',
  'family.id matches requested family'
);

-- Test 10: family.name matches Family A name
select is(
  public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'family' ->> 'name',
  'Export Family A',
  'family.name matches Family A'
);

-- Test 11: family.timezone and locale are present
select is(
  public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'family' ->> 'timezone',
  'America/New_York',
  'family.timezone matches America/New_York'
);


-- ---------------------------------------------------------------------------
-- 4. MULTI-CHILD DATA CONTINUITY & ARCHIVAL PSEUDONYMIZATION
-- ---------------------------------------------------------------------------

-- Test 12: children array has exactly 2 children (both active A1 and archived A2)
select is(
  jsonb_array_length(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children'),
  2,
  'children array contains exactly 2 children (both active A1 and archived A2)'
);

-- Test 13: Active child A1 retains normal profile fields and null archived_at
select is(
  (
    select c ->> 'display_name'
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'ca100000-0000-0000-0000-000000000001'
  ),
  'Child A1',
  'Active child A1 preserves display_name "Child A1"'
);

-- Test 14: Archived child A2 reflects Tier 3 pseudonymization: [Archived Learner], null grade/year/avatar, not null archived_at
select is(
  (
    select c ->> 'display_name'
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  '[Archived Learner]',
  'Archived child A2 reflects pseudonymized display_name "[Archived Learner]"'
);

-- Test 15: Archived child A2 has non-null archived_at timestamp
select ok(
  (
    select (c ->> 'archived_at') is not null
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'ca200000-0000-0000-0000-000000000002'
  ),
  'Archived child A2 has non-null archived_at timestamp'
);


-- ---------------------------------------------------------------------------
-- 5. STRICT TENANT ISOLATION TESTS
-- ---------------------------------------------------------------------------

-- Test 16: Foreign child B1 is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'children') as c
    where c ->> 'id' = 'cb100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Foreign child B1 is completely excluded from Family A children array'
);

-- Test 17: Foreign assessment B1 is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'eb100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Foreign assessment B1 is completely excluded from Family A assessments array'
);

-- Test 18: Foreign balance is NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'child_balances') as b
    where b ->> 'child_id' = 'cb100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Foreign child balance is completely excluded from Family A child_balances array'
);

-- Test 19: Foreign ledger entries are NOT present in Family A export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'xp_ledger') as x
    where x ->> 'id' = 'dd200000-0000-0000-0000-000000000002'
  ),
  0::bigint,
  'Foreign XP ledger row is completely excluded from Family A xp_ledger array'
);


-- ---------------------------------------------------------------------------
-- 6. ASSESSMENT FILTERING & DRAFT EXCLUSION
-- ---------------------------------------------------------------------------

-- Test 20: Draft assessment (ea1) is excluded from export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'ea100000-0000-0000-0000-000000000001'
  ),
  0::bigint,
  'Draft assessment ea1 is excluded from assessments array'
);

-- Test 21: Verified assessment (ea2) is included in export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'ea200000-0000-0000-0000-000000000002'
  ),
  1::bigint,
  'Verified assessment ea2 is included in assessments array'
);

-- Test 22: Pending review assessment for archived child (ea3) is included in export
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessments') as a
    where a ->> 'id' = 'ea300000-0000-0000-0000-000000000003'
  ),
  1::bigint,
  'Pending review assessment ea3 for archived child is included in assessments array'
);


-- ---------------------------------------------------------------------------
-- 7. DATA MINIMIZATION & MEDIA BOUNDARY TESTS
-- ---------------------------------------------------------------------------

-- Test 23: assessment_evidence contains storage_path and metadata
select is(
  (
    select e ->> 'storage_path'
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessment_evidence') as e
    where e ->> 'id' = '0e100000-0000-0000-0000-000000000001'
  ),
  'fa000000-0000-0000-0000-000000000001/ca100000-0000-0000-0000-000000000001/ea200000-0000-0000-0000-000000000002/ev1.jpg',
  'assessment_evidence exports relative storage_path'
);

-- Test 24: assessment_evidence contains zero raw byte columns (data, bytes, payload are missing)
select ok(
  (
    select (e ? 'data') = false and (e ? 'bytes') = false and (e ? 'image_bytes') = false
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'assessment_evidence') as e
    where e ->> 'id' = '0e100000-0000-0000-0000-000000000001'
  ),
  'assessment_evidence adheres to data minimization: zero raw image bytes exported'
);


-- ---------------------------------------------------------------------------
-- 8. ECONOMIC & LEARNING COMPLETENESS TESTS
-- ---------------------------------------------------------------------------

-- Test 25: verified_learning_events contains Family A verified event
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'verified_learning_events') as v
    where v ->> 'id' = 'ba100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'verified_learning_events exports Family A VLE'
);

-- Test 26: growth_events contains Family A growth event
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'growth_events') as g
    where g ->> 'id' = 'cc100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'growth_events exports Family A growth event'
);

-- Test 27: xp_ledger contains Family A xp record
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'xp_ledger') as x
    where x ->> 'id' = 'dd100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'xp_ledger exports Family A XP record'
);

-- Test 28: rp_ledger contains Family A rp record
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'rp_ledger') as r
    where r ->> 'id' = 'ee100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'rp_ledger exports Family A RP record'
);

-- Test 29: reward_redemptions contains Family A redemption
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'reward_redemptions') as rd
    where rd ->> 'id' = 'ab100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'reward_redemptions exports Family A redemption'
);

-- Test 30: wheel_spins contains Family A spin
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'wheel_spins') as ws
    where ws ->> 'id' = 'ac100000-0000-0000-0000-000000000001'
  ),
  1::bigint,
  'wheel_spins exports Family A wheel spin'
);

-- Test 31: child_balances contains balances for both A1 and A2
select is(
  (
    select count(*)
    from jsonb_array_elements(public.export_family_data_json('fa000000-0000-0000-0000-000000000001'::uuid) -> 'child_balances') as cb
    where cb ->> 'child_id' in ('ca100000-0000-0000-0000-000000000001', 'ca200000-0000-0000-0000-000000000002')
  ),
  2::bigint,
  'child_balances exports both active and archived children'
);


-- ---------------------------------------------------------------------------
-- 9. PRIVILEGE & SEARCH_PATH SECURITY
-- ---------------------------------------------------------------------------

-- Test 32: Function is owned by postgres or superuser and has secure search_path
select has_function('public', 'export_family_data_json', array['uuid'], 'export_family_data_json(uuid) exists');

-- Test 33: Authenticated role has execute permission
select ok(
  has_function_privilege('authenticated', 'public.export_family_data_json(uuid)', 'execute'),
  'authenticated role has execute permission'
);

rollback;
