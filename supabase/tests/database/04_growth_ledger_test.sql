begin;
select plan(28);

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
-- 6. BALANCE RECONCILIATION
-- ---------------------------------------------------------------------------

-- Test 23: Deterministic reconciliation check
select is(
  (select is_reconciled from public.reconcile_child_balance('c3000000-0000-0000-0000-000000000001'::uuid)),
  true,
  'reconcile_child_balance confirms projected balances equal sum of ledgers'
);

-- ---------------------------------------------------------------------------
-- 7. TENANT ISOLATION: FAMILY B CANNOT READ FAMILY A LEDGER
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "30000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 24: Owner B cannot see Family A growth events or ledgers
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

-- Test 25: Child A2 cannot read sibling Child A1 growth_events
select is(
  (select count(*)::int from public.growth_events where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Sibling isolation prevents Child A2 from reading Child A1 growth_events'
);

-- Test 26: Child A2 cannot read sibling Child A1 xp_ledger
select is(
  (select count(*)::int from public.xp_ledger where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Sibling isolation prevents Child A2 from reading Child A1 xp_ledger'
);

-- Test 27: Child A2 cannot read sibling Child A1 rp_ledger
select is(
  (select count(*)::int from public.rp_ledger where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Sibling isolation prevents Child A2 from reading Child A1 rp_ledger'
);

-- Test 28: Child A2 cannot read sibling Child A1 child_balances
select is(
  (select count(*)::int from public.child_balances where child_id = 'c3000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Sibling isolation prevents Child A2 from reading Child A1 child_balances'
);

select * from finish();
rollback;
