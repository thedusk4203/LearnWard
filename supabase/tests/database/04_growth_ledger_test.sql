begin;
select plan(42);

-- ---------------------------------------------------------------------------
-- 0. FIXTURES SETUP (superuser context)
-- ---------------------------------------------------------------------------

insert into auth.users (id, aud, role, email) values
  ('30000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'p3_owner_a@test.com'),
  ('30000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'p3_owner_b@test.com'),
  ('30000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'p3_child_device_a1@test.com'),
  ('30000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'p3_child_device_a2@test.com')
on conflict (id) do nothing;

insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('f3000000-0000-0000-0000-000000000001'::uuid, 'Phase 3 Family A', 'UTC', 'en_US', '30000000-0000-0000-0000-000000000001'::uuid),
  ('f3000000-0000-0000-0000-000000000002'::uuid, 'Phase 3 Family B', 'UTC', 'en_US', '30000000-0000-0000-0000-000000000002'::uuid)
on conflict (id) do nothing;

insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('f3000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('f3000000-0000-0000-0000-000000000002'::uuid, '30000000-0000-0000-0000-000000000002'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
  ('c3000000-0000-0000-0000-000000000001'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'Child A1', 5, 2015),
  ('c3000000-0000-0000-0000-000000000002'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'Child A2 (Sibling)', 3, 2017),
  ('c3000000-0000-0000-0000-000000000003'::uuid, 'f3000000-0000-0000-0000-000000000002'::uuid, 'Child B1', 6, 2014)
on conflict (id) do nothing;

insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('d3000000-0000-0000-0000-000000000001'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000001'::uuid, '30000000-0000-0000-0000-000000000003'::uuid, 'active', '30000000-0000-0000-0000-000000000001'::uuid),
  ('d3000000-0000-0000-0000-000000000002'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, '30000000-0000-0000-0000-000000000004'::uuid, 'active', '30000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 1. DIRECT CLIENT MUTATION PROTECTION (Security & RLS)
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 1: Direct insert into growth_events denied to clients
select throws_ok(
  $$
    insert into public.growth_events (
      family_id, child_id, verified_learning_event_id, assessment_id, engine_version,
      normalized_score, score_rp_minor, total_rp_minor, xp_awarded, inputs_snapshot
    ) values (
      'f3000000-0000-0000-0000-000000000001'::uuid,
      'c3000000-0000-0000-0000-000000000001'::uuid,
      gen_random_uuid(), gen_random_uuid(), 'growth-v0.1',
      8.0, 800, 800, 26, '{}'::jsonb
    )
  $$,
  '42501',
  null,
  'Direct client INSERT into growth_events is strictly denied'
);

-- Test 2: Direct insert into xp_ledger denied to clients
select throws_ok(
  $$
    insert into public.xp_ledger (
      family_id, child_id, amount, reason_code, source_type, idempotency_key
    ) values (
      'f3000000-0000-0000-0000-000000000001'::uuid,
      'c3000000-0000-0000-0000-000000000001'::uuid,
      100, 'cheat', 'client', 'cheat_xp_1'
    )
  $$,
  '42501',
  null,
  'Direct client INSERT into xp_ledger is strictly denied'
);

-- Test 3: Direct insert into rp_ledger denied to clients
select throws_ok(
  $$
    insert into public.rp_ledger (
      family_id, child_id, amount_minor, reason_code, source_type, idempotency_key
    ) values (
      'f3000000-0000-0000-0000-000000000001'::uuid,
      'c3000000-0000-0000-0000-000000000001'::uuid,
      1000, 'cheat', 'client', 'cheat_rp_1'
    )
  $$,
  '42501',
  null,
  'Direct client INSERT into rp_ledger is strictly denied'
);

-- Test 4: Direct update on child_balances denied to clients
select throws_ok(
  $$
    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000001'::uuid, 9999, 9999)
    on conflict (child_id) do update set xp_total = 9999
  $$,
  '42501',
  null,
  'Direct client mutation of child_balances is strictly denied'
);

-- ---------------------------------------------------------------------------
-- 2. CREATE AND VERIFY AN ASSESSMENT TO PRODUCE A VERIFIED LEARNING EVENT
-- ---------------------------------------------------------------------------

-- Create draft
create temporary table test_draft on commit drop as
select * from public.create_assessment_draft(
  '70000000-0000-0000-0000-000000000001'::uuid,
  'f3000000-0000-0000-0000-000000000001'::uuid,
  'c3000000-0000-0000-0000-000000000001'::uuid,
  'math',
  'Mathematics',
  'Unit 1 Quiz',
  'quiz',
  'hard',
  7.5,
  10.0,
  now(),
  'adult'
);

-- Submit assessment
select public.submit_assessment(
  (select id from test_draft),
  1,
  '70000000-0000-0000-0000-000000000002'::uuid
);

-- Verify assessment -> creates VerifiedLearningEvent
select public.verify_assessment(
  (select id from test_draft),
  2,
  '70000000-0000-0000-0000-000000000003'::uuid,
  'Great work'
);

create temporary table test_vle on commit drop as
select id from public.verified_learning_events
where assessment_id = (select id from test_draft);

-- Test 5: VerifiedLearningEvent exists
select is(
  (select count(*)::int from test_vle),
  1,
  'VerifiedLearningEvent generated successfully from verification'
);

-- ---------------------------------------------------------------------------
-- 3. PROCESS GROWTH VIA TRUSTED COMMAND: process_verified_learning_event
-- ---------------------------------------------------------------------------

create temporary table test_growth_res on commit drop as
select * from public.process_verified_learning_event(
  (select id from test_vle),
  '70000000-0000-0000-0000-000000000004'::uuid
);

-- Test 6: GrowthEvent created
select is(
  (select count(*)::int from test_growth_res),
  1,
  'process_verified_learning_event creates a GrowthEvent'
);

-- Test 7: Normalized score is 7.50
select is(
  (select normalized_score from test_growth_res),
  7.50::numeric(4, 2),
  'growth_events records normalized score 7.50'
);

-- Test 8: Economic breakdown without history: base score 750 minor, hard challenge +100 minor = 850 minor (8.50 RP)
select is(
  (select score_rp_minor from test_growth_res),
  750::bigint,
  'score_rp_minor is 750 (7.50 RP)'
);

select is(
  (select difficulty_rp_minor from test_growth_res),
  100::bigint,
  'difficulty_rp_minor is 100 (+1.00 RP for hard)'
);

select is(
  (select total_rp_minor from test_growth_res),
  850::bigint,
  'total_rp_minor is 850 (+8.50 RP)'
);

-- Test 11: XP calculation: 10 + 2 * 8.50 = 27 XP
select is(
  (select xp_awarded from test_growth_res),
  27::int,
  'xp_awarded is 27 XP (10 + 2 * 8.50)'
);

-- Test 12: XP ledger entry created
select is(
  (select count(*)::int from public.xp_ledger where source_id = (select id from test_growth_res)),
  1,
  'Exactly one XP ledger row appended'
);

-- Test 13: RP ledger entry created
select is(
  (select count(*)::int from public.rp_ledger where source_id = (select id from test_growth_res)),
  1,
  'Exactly one RP ledger row appended'
);

-- Test 14: Balance projection updated
select is(
  (select xp_total from public.child_balances where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  27::bigint,
  'child_balances xp_total reflects award (27 XP)'
);

select is(
  (select rp_balance_minor from public.child_balances where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  850::bigint,
  'child_balances rp_balance_minor reflects award (850 minor)'
);

-- ---------------------------------------------------------------------------
-- 4. IDEMPOTENCY: RETRY DOES NOT CREATE DUPLICATE AWARDS
-- ---------------------------------------------------------------------------

-- Retry process_verified_learning_event with same command_id
create temporary table test_growth_retry on commit drop as
select * from public.process_verified_learning_event(
  (select id from test_vle),
  '70000000-0000-0000-0000-000000000004'::uuid
);

-- Test 16: Returns same growth event ID
select is(
  (select id from test_growth_retry),
  (select id from test_growth_res),
  'Idempotent retry returns identical growth_event record'
);

-- Test 17: No duplicate XP ledger entry
select is(
  (select count(*)::int from public.xp_ledger where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  1,
  'No duplicate XP ledger entry created on retry'
);

-- Test 18: No duplicate RP ledger entry
select is(
  (select count(*)::int from public.rp_ledger where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  1,
  'No duplicate RP ledger entry created on retry'
);

-- Test 19: Balance remains unchanged
select is(
  (select xp_total from public.child_balances where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  27::bigint,
  'child_balances xp_total is unchanged after retry'
);

-- ---------------------------------------------------------------------------
-- 5. IMMUTABILITY TRIGGERS (tested in superuser context to verify trigger LW102)
-- ---------------------------------------------------------------------------

reset role;

-- Test 20: growth_events update rejected
select throws_ok(
  format('update public.growth_events set total_rp_minor = 9999 where id = %L', (select id from test_growth_res)),
  'LW102',
  null,
  'growth_events UPDATE rejected by immutability trigger (LW102)'
);

-- Test 21: xp_ledger update rejected
select throws_ok(
  format('update public.xp_ledger set amount = 9999 where source_id = %L', (select id from test_growth_res)),
  'LW102',
  null,
  'xp_ledger UPDATE rejected by immutability trigger (LW102)'
);

-- Test 22: rp_ledger delete rejected
select throws_ok(
  format('delete from public.rp_ledger where source_id = %L', (select id from test_growth_res)),
  'LW102',
  null,
  'rp_ledger DELETE rejected by immutability trigger (LW102)'
);

-- ---------------------------------------------------------------------------
-- 6. BALANCE RECONCILIATION & AUTHORIZATION CHECKS
-- ---------------------------------------------------------------------------

-- Test 23: Unauthenticated caller cannot reconcile child balance
set local role anon;
select throws_ok(
  $$ select * from public.reconcile_child_balance('c3000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  null,
  'reconcile_child_balance rejects unauthenticated caller with 42501'
);

-- Test 24: Family B owner cannot reconcile Family A child balance
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select throws_ok(
  $$ select * from public.reconcile_child_balance('c3000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  null,
  'reconcile_child_balance rejects cross-family caller with 42501'
);

-- Test 25: Sibling child device (Child A2) cannot reconcile Child A1 balance
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);
select throws_ok(
  $$ select * from public.reconcile_child_balance('c3000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  null,
  'reconcile_child_balance rejects sibling child device with 42501'
);

-- Test 26: Authorized Family A adult succeeds
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select is(
  (select is_reconciled from public.reconcile_child_balance('c3000000-0000-0000-0000-000000000001'::uuid)),
  true,
  'reconcile_child_balance succeeds for active family adult and confirms reconciliation'
);

-- Test 27: Paired child device (Child A1) succeeds for their own balance
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select is(
  (select is_reconciled from public.reconcile_child_balance('c3000000-0000-0000-0000-000000000001'::uuid)),
  true,
  'reconcile_child_balance succeeds for paired child device for their own profile'
);

-- ---------------------------------------------------------------------------
-- 7. TENANT ISOLATION: FAMILY B CANNOT READ FAMILY A LEDGER
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 28: Owner B cannot see Family A growth events or ledgers
select is(
  (select count(*)::int from public.growth_events where family_id = 'f3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Cross-family RLS prevents Owner B from reading Family A growth_events'
);

-- ---------------------------------------------------------------------------
-- 8. SIBLING ISOLATION: CHILD A2 CANNOT READ SIBLING CHILD A1 LEDGER
-- ---------------------------------------------------------------------------

-- Set context to Child Device A2
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);

-- Test 29: Child A2 cannot read sibling Child A1 growth_events
select is(
  (select count(*)::int from public.growth_events where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Sibling isolation prevents Child A2 from reading Child A1 growth_events'
);

-- Test 30: Child A2 cannot read sibling Child A1 xp_ledger
select is(
  (select count(*)::int from public.xp_ledger where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Sibling isolation prevents Child A2 from reading Child A1 xp_ledger'
);

-- Test 31: Child A2 cannot read sibling Child A1 rp_ledger
select is(
  (select count(*)::int from public.rp_ledger where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Sibling isolation prevents Child A2 from reading Child A1 rp_ledger'
);

-- Test 32: Child A2 cannot read sibling Child A1 child_balances
select is(
  (select count(*)::int from public.child_balances where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Sibling isolation prevents Child A2 from reading Child A1 child_balances'
);

-- ---------------------------------------------------------------------------
-- 9. LONGITUDINAL COMPARABILITY FILTERING IN SQL
-- ---------------------------------------------------------------------------

reset role;

-- Setup historical records for child A2:
-- Target subject: math
-- Event h1: math, quiz (evaluative), normal (standard), 6.00 (3 days ago) -> COMPATIBLE
-- Event h2: math, homework (formative), normal (standard), 9.00 (2 days ago) -> INCOMPATIBLE TYPE
-- Event h3: math, quiz (evaluative), challenge, 4.00 (2 days ago) -> INCOMPATIBLE DIFFICULTY
-- Event h4: math, exam (evaluative), normal (standard), 6.50 (2 days ago) -> COMPATIBLE
-- Event h5: math, quiz (evaluative), below_level, 10.00 (1 day ago) -> INCOMPATIBLE DIFFICULTY
-- Event h6: math, quiz (evaluative), hard (standard), 6.80 (1 day ago) -> COMPATIBLE
-- Current: math, exam (evaluative), hard (standard), 7.50 (now) -> Target

do $$
begin
  -- h1: compatible (quiz, normal, 6.00)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000011'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Q1', 'quiz', 'normal', 6, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);

  -- Command receipt and Review event placeholder
  insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
  values ('70000000-0000-0000-0000-000000000099'::uuid, 'verify', '30000000-0000-0000-0000-000000000001'::uuid, 'a3000000-0000-0000-0000-000000000011'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid) on conflict do nothing;

  insert into public.assessment_review_events (
    id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id
  ) values (
    'e3000000-0000-0000-0000-000000000099'::uuid,
    '70000000-0000-0000-0000-000000000099'::uuid,
    'f3000000-0000-0000-0000-000000000001'::uuid,
    'a3000000-0000-0000-0000-000000000011'::uuid,
    'verified',
    'pending_review',
    'verified',
    '30000000-0000-0000-0000-000000000001'::uuid
  ) on conflict (id) do nothing;
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000011'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000011'::uuid, 'math', 'Math', 'Q1', 'quiz', 'normal', 6, 10, 6.00, now() - interval '3 days', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- h2: incompatible type (homework, normal, 9.00)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000012'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'HW1', 'homework', 'normal', 9, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000012'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000012'::uuid, 'math', 'Math', 'HW1', 'homework', 'normal', 9, 10, 9.00, now() - interval '2 days', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- h3: incompatible diff (quiz, challenge, 4.00)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000013'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Ch1', 'quiz', 'challenge', 4, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000013'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000013'::uuid, 'math', 'Math', 'Ch1', 'quiz', 'challenge', 4, 10, 4.00, now() - interval '2 days', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- h4: compatible (exam, normal, 6.50)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000014'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'E1', 'exam', 'normal', 6.5, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000014'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000014'::uuid, 'math', 'Math', 'E1', 'exam', 'normal', 6.5, 10, 6.50, now() - interval '2 days', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- h5: incompatible diff (quiz, below_level, 10.00)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000015'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'BL1', 'quiz', 'below_level', 10, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000015'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000015'::uuid, 'math', 'Math', 'BL1', 'quiz', 'below_level', 10, 10, 10.00, now() - interval '1 day', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- h6: compatible (quiz, hard, 6.80)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000016'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Q2', 'quiz', 'hard', 6.8, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000016'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000016'::uuid, 'math', 'Math', 'Q2', 'quiz', 'hard', 6.8, 10, 6.80, now() - interval '1 day', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- Current target: exam, hard, 7.50
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000017'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'E2_Target', 'exam', 'hard', 7.5, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000017'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000017'::uuid, 'math', 'Math', 'E2_Target', 'exam', 'hard', 7.5, 10, 7.50, now(), '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);
end;
$$;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

create temp table comp_test_res as
select * from public.process_verified_learning_event('93000000-0000-0000-0000-000000000017'::uuid, null);

-- Test 33: SQL process_verified_learning_event computes 6.43 baseline filtering incompatible type & difficulty
select is(
  (select baseline_score from comp_test_res),
  6.43::numeric,
  'SQL process_verified_learning_event computes 6.43 baseline filtering incompatible type and difficulty'
);

-- Test 34: SQL inputs_snapshot contains current assessment_type & difficulty
select is(
  (select inputs_snapshot->>'assessment_type' from comp_test_res),
  'exam',
  'inputs_snapshot contains current assessment_type'
);

-- Test 35: SQL inputs_snapshot samples_used contains exactly 3 compatible items
select is(
  (select jsonb_array_length(inputs_snapshot->'samples_used') from comp_test_res),
  3,
  'inputs_snapshot samples_used contains exactly 3 compatible items'
);

-- ---------------------------------------------------------------------------
-- 10. UNPROCESSED DISCOVERY & CATCH-UP DELIVERY
-- ---------------------------------------------------------------------------

reset role;

-- Create an unprocessed verified event
do $$
begin
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000020'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'math', 'Math', 'Unprocessed_1', 'quiz', 'normal', 8, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);

  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000020'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000002'::uuid, 'a3000000-0000-0000-0000-000000000020'::uuid, 'math', 'Math', 'Unprocessed_1', 'quiz', 'normal', 8, 10, 8.00, now(), '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);
end;
$$;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 36: get_unprocessed_verified_learning_events discovers unprocessed events
select is(
  (select count(*)::int from public.get_unprocessed_verified_learning_events('f3000000-0000-0000-0000-000000000001'::uuid)),
  7,
  'get_unprocessed_verified_learning_events discovers 7 unprocessed verified events'
);

-- Test 37: catch_up_unprocessed_growth processes the events
select is(
  (select public.catch_up_unprocessed_growth('f3000000-0000-0000-0000-000000000001'::uuid)),
  7,
  'catch_up_unprocessed_growth processes 7 unprocessed events'
);

-- Test 38: catch_up_unprocessed_growth returns 0 on second run (idempotent)
select is(
  (select public.catch_up_unprocessed_growth('f3000000-0000-0000-0000-000000000001'::uuid)),
  0,
  'catch_up_unprocessed_growth returns 0 on second run (idempotent)'
);

-- Test 39: get_unprocessed_verified_learning_events returns 0 after catch-up
select is(
  (select count(*)::int from public.get_unprocessed_verified_learning_events('f3000000-0000-0000-0000-000000000001'::uuid)),
  0,
  'get_unprocessed_verified_learning_events returns 0 after catch-up completed'
);

-- ---------------------------------------------------------------------------
-- 11. GRADE LEVEL COMPARABILITY EXCLUSION
-- ---------------------------------------------------------------------------

reset role;

insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
values ('c3000000-0000-0000-0000-000000000009'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'Grade Test Child', 5, 2015);

-- Insert 3 historical Grade 4 assessments and verified events
do $$
begin
  -- g4_1: Grade 4 (8.00)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, grade_level_snapshot, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000041'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000009'::uuid, 'math', 'Math', 'G4_1', 'quiz', 'normal', 8, 10, 4, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, grade_level_snapshot, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000041'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000009'::uuid, 'a3000000-0000-0000-0000-000000000041'::uuid, 'math', 'Math', 'G4_1', 'quiz', 'normal', 8, 10, 8.00, 4, now() - interval '30 days', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- g4_2: Grade 4 (8.50)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, grade_level_snapshot, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000042'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000009'::uuid, 'math', 'Math', 'G4_2', 'quiz', 'normal', 8.5, 10, 4, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, grade_level_snapshot, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000042'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000009'::uuid, 'a3000000-0000-0000-0000-000000000042'::uuid, 'math', 'Math', 'G4_2', 'quiz', 'normal', 8.5, 10, 8.50, 4, now() - interval '20 days', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- g4_3: Grade 4 (9.00)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, grade_level_snapshot, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000043'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000009'::uuid, 'math', 'Math', 'G4_3', 'quiz', 'normal', 9, 10, 4, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, grade_level_snapshot, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000043'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000009'::uuid, 'a3000000-0000-0000-0000-000000000043'::uuid, 'math', 'Math', 'G4_3', 'quiz', 'normal', 9, 10, 9.00, 4, now() - interval '10 days', '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);

  -- Current Grade 5 target assessment (trigger automatically snapshots grade 5 from child profile)
  insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, created_by_user_id)
  values ('a3000000-0000-0000-0000-000000000044'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000009'::uuid, 'math', 'Math', 'G5_Target', 'quiz', 'normal', 8, 10, 'verified', '30000000-0000-0000-0000-000000000001'::uuid);
  insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_by_user_id, review_event_id)
  values ('93000000-0000-0000-0000-000000000044'::uuid, 'f3000000-0000-0000-0000-000000000001'::uuid, 'c3000000-0000-0000-0000-000000000009'::uuid, 'a3000000-0000-0000-0000-000000000044'::uuid, 'math', 'Math', 'G5_Target', 'quiz', 'normal', 8, 10, 8.00, now(), '30000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000099'::uuid);
end;
$$;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

create temp table grade_test_res as
select * from public.process_verified_learning_event('93000000-0000-0000-0000-000000000044'::uuid, null);

-- Test 40: Grade 4 history is strictly excluded when processing Grade 5 event -> baseline is null
select is(
  (select baseline_score from grade_test_res),
  null,
  'Incompatible grade-level history (Grade 4 vs Grade 5) is excluded from rolling baseline'
);

-- Test 41: inputs_snapshot records current grade_level as 5
select is(
  (select (inputs_snapshot->>'grade_level')::int from grade_test_res),
  5,
  'inputs_snapshot records current grade_level snapshot'
);

-- ---------------------------------------------------------------------------
-- 12. SINGLE-SNAPSHOT READ-ONLY RECONCILIATION INTEGRITY
-- ---------------------------------------------------------------------------

-- Test 42: Single-snapshot read-only reconciliation returns is_reconciled = true
select is(
  (select is_reconciled from public.reconcile_child_balance('c3000000-0000-0000-0000-000000000009'::uuid)),
  true,
  'Single-snapshot reconcile_child_balance confirms projection equals ledger totals'
);

select * from finish();
rollback;
