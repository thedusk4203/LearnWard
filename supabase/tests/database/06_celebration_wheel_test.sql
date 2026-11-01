begin;
select plan(38);

-- ---------------------------------------------------------------------------
-- 0. FIXTURES SETUP (superuser context)
-- ---------------------------------------------------------------------------

insert into auth.users (id, aud, role, email) values
  ('60000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'p42_owner_a@test.com'),
  ('60000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'p42_owner_b@test.com'),
  ('60000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'p42_child_device_a1@test.com'),
  ('60000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'p42_child_device_a2@test.com')
on conflict (id) do nothing;

insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('fa420000-0000-0000-0000-000000000001'::uuid, 'Phase 4.2 Family A', 'America/New_York', 'en_US', '60000000-0000-0000-0000-000000000001'::uuid),
  ('fa420000-0000-0000-0000-000000000002'::uuid, 'Phase 4.2 Family B', 'UTC', 'en_US', '60000000-0000-0000-0000-000000000002'::uuid)
on conflict (id) do nothing;

insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('fa420000-0000-0000-0000-000000000001'::uuid, '60000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('fa420000-0000-0000-0000-000000000002'::uuid, '60000000-0000-0000-0000-000000000002'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
  ('ca420000-0000-0000-0000-000000000001'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'Child 42A1', 5, 2015),
  ('ca420000-0000-0000-0000-000000000002'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'Child 42A2', 3, 2017),
  ('ca420000-0000-0000-0000-000000000003'::uuid, 'fa420000-0000-0000-0000-000000000002'::uuid, 'Child 42B1', 6, 2014)
on conflict (id) do nothing;

insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('da420000-0000-0000-0000-000000000001'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid, '60000000-0000-0000-0000-000000000003'::uuid, 'active', '60000000-0000-0000-0000-000000000001'::uuid),
  ('da420000-0000-0000-0000-000000000002'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'ca420000-0000-0000-0000-000000000002'::uuid, '60000000-0000-0000-0000-000000000004'::uuid, 'active', '60000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Initialize Child 42A1 with 100 XP and 5000 RP minor ($50.00)
insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor) values
  ('fa420000-0000-0000-0000-000000000001'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid, 100, 5000)
on conflict (child_id) do update set rp_balance_minor = 5000;

insert into public.xp_ledger (id, family_id, child_id, amount, reason_code, source_type, idempotency_key) values
  (gen_random_uuid(), 'fa420000-0000-0000-0000-000000000001'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid, 100, 'initial_grant', 'growth_event', 'init_xp:42a1')
on conflict (idempotency_key) do nothing;

insert into public.rp_ledger (id, family_id, child_id, amount_minor, reason_code, source_type, idempotency_key) values
  (gen_random_uuid(), 'fa420000-0000-0000-0000-000000000001'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid, 5000, 'initial_grant', 'growth_event', 'init:42a1')
on conflict (idempotency_key) do nothing;

-- 4 Eligible Wheel Rewards for Family A (pool size 4 >= 3)
insert into public.rewards (id, family_id, title, description, category, store_enabled, store_cost_minor, wheel_enabled, wheel_tier, is_active) values
  ('ea420000-0000-0000-0000-000000000001'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, '15m Screen Time', 'Quick bonus', 'privilege', false, null, true, 'common', true),
  ('ea420000-0000-0000-0000-000000000002'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'Ice Cream Treat', 'Dessert choice', 'treat', true, 1500, true, 'special', true),
  ('ea420000-0000-0000-0000-000000000003'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'Movie Night Choice', 'Pick weekend movie', 'experience', false, null, true, 'rare', true),
  ('ea420000-0000-0000-0000-000000000004'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'Late Bedtime 30m', 'Friday night', 'privilege', true, 2000, true, 'common', true),
  -- Inactive wheel reward
  ('ea420000-0000-0000-0000-000000000005'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'Inactive Wheel Item', 'Disabled', 'treat', false, null, true, 'common', false),
  -- Sibling targeted wheel reward (for Child 42A2 only)
  ('ea420000-0000-0000-0000-000000000006'::uuid, 'fa420000-0000-0000-0000-000000000001'::uuid, 'Sibling Toy', 'For A2', 'item', false, null, true, 'common', true)
on conflict (id) do nothing;

update public.rewards set target_child_id = 'ca420000-0000-0000-0000-000000000002'::uuid
where id = 'ea420000-0000-0000-0000-000000000006'::uuid;

-- Family B reward
insert into public.rewards (id, family_id, title, category, store_enabled, store_cost_minor, wheel_enabled, wheel_tier, is_active) values
  ('eb420000-0000-0000-0000-000000000001'::uuid, 'fa420000-0000-0000-0000-000000000002'::uuid, 'Family B Prize', 'treat', false, null, true, 'common', true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 1. FAMILY WHEEL SETTINGS & TRIGGER TESTS
-- ---------------------------------------------------------------------------

-- Test 1: family_wheel_settings automatically created for Family A and Family B
select is(
  (select count(*) from public.family_wheel_settings where family_id in ('fa420000-0000-0000-0000-000000000001'::uuid, 'fa420000-0000-0000-0000-000000000002'::uuid)),
  2::bigint,
  'family_wheel_settings row backfilled/initialized for all families'
);

-- Test 2: default values are spin_cost_minor = 1000, daily_spin_cap = 3, is_enabled = true
select is(
  (select spin_cost_minor from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid),
  1000::bigint,
  'Default spin_cost_minor is 1000 (10 RP)'
);
select is(
  (select daily_spin_cap from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid),
  3,
  'Default daily_spin_cap is 3'
);
select is(
  (select is_enabled from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid),
  true,
  'Default is_enabled is true'
);

-- Test 5: trigger creates default wheel settings on newly inserted family
insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('fa420000-0000-0000-0000-000000000099'::uuid, 'Trigger Test Family', 'UTC', 'en_US', '60000000-0000-0000-0000-000000000001'::uuid);

select is(
  (select count(*) from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000099'::uuid),
  1::bigint,
  'Trigger automatically creates family_wheel_settings on family INSERT'
);

-- Test 6: check constraints on family_wheel_settings
select throws_ok(
  $$ update public.family_wheel_settings set spin_cost_minor = 400 where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid $$,
  '23514',
  NULL,
  'spin_cost_minor < 500 violates check constraint'
);

select throws_ok(
  $$ update public.family_wheel_settings set daily_spin_cap = 6 where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid $$,
  '23514',
  NULL,
  'daily_spin_cap > 5 violates check constraint'
);

-- ---------------------------------------------------------------------------
-- 2. RLS SECURITY POLICIES
-- ---------------------------------------------------------------------------

-- Switch to Owner A context
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "60000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 8: Owner A can read own family settings
select is(
  (select count(*) from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid),
  1::bigint,
  'Owner A can SELECT own family_wheel_settings'
);

-- Test 9: Owner A cannot read Family B settings
select is(
  (select count(*) from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000002'::uuid),
  0::bigint,
  'Owner A cannot SELECT Family B family_wheel_settings (isolated)'
);

-- Test 10: Owner A can update own family settings
update public.family_wheel_settings set spin_cost_minor = 1200 where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid;
select is(
  (select spin_cost_minor from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid),
  1200::bigint,
  'Owner A can UPDATE own family_wheel_settings'
);
-- Reset spin cost to 1000
update public.family_wheel_settings set spin_cost_minor = 1000 where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid;

-- Switch to Paired Child Device A1 context
select set_config('request.jwt.claims', '{"sub": "60000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 11: Paired child can read own family settings
select is(
  (select count(*) from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid),
  1::bigint,
  'Paired child can SELECT own family_wheel_settings'
);

-- Test 12: Paired child cannot update family settings (denied / 0 rows updated)
update public.family_wheel_settings set spin_cost_minor = 500 where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid;
select is(
  (select spin_cost_minor from public.family_wheel_settings where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid),
  1000::bigint,
  'Paired child cannot UPDATE family_wheel_settings'
);

-- ---------------------------------------------------------------------------
-- 3. EXPANDED PAIRED-CHILD REWARD SELECT SEMANTICS
-- ---------------------------------------------------------------------------

-- Test 13: Paired child A1 can see wheel-only active eligible reward ('15m Screen Time')
select is(
  (select count(*) from public.rewards where id = 'ea420000-0000-0000-0000-000000000001'::uuid),
  1::bigint,
  'Paired child can see active wheel-only reward'
);

-- Test 14: Paired child A1 can see store-and-wheel reward ('Ice Cream Treat')
select is(
  (select count(*) from public.rewards where id = 'ea420000-0000-0000-0000-000000000002'::uuid),
  1::bigint,
  'Paired child can see active store+wheel reward'
);

-- Test 15: Paired child A1 cannot see inactive reward ('Inactive Wheel Item')
select is(
  (select count(*) from public.rewards where id = 'ea420000-0000-0000-0000-000000000005'::uuid),
  0::bigint,
  'Paired child cannot see inactive wheel reward'
);

-- Test 16: Paired child A1 cannot see sibling-targeted reward ('Sibling Toy')
select is(
  (select count(*) from public.rewards where id = 'ea420000-0000-0000-0000-000000000006'::uuid),
  0::bigint,
  'Paired child cannot see sibling-targeted wheel reward'
);

-- Test 17: Paired child A1 cannot see Family B reward
select is(
  (select count(*) from public.rewards where id = 'eb420000-0000-0000-0000-000000000001'::uuid),
  0::bigint,
  'Paired child cannot see Family B reward'
);

-- Test 18: Direct INSERT into wheel_spins denied
select throws_ok(
  $$ insert into public.wheel_spins (id, family_id, child_id, reward_id, redemption_id, spin_cost_minor, selection_snapshot)
     values (gen_random_uuid(), 'fa420000-0000-0000-0000-000000000001'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid, 'ea420000-0000-0000-0000-000000000001'::uuid, gen_random_uuid(), 1000, '{}'::jsonb) $$,
  '42501',
  NULL,
  'Direct INSERT into wheel_spins is denied to authenticated clients'
);

-- ---------------------------------------------------------------------------
-- 4. SPIN REWARD WHEEL RPC TESTS
-- ---------------------------------------------------------------------------

-- Test 19: Unauthenticated call fails (42501)
set local role anon;
select throws_ok(
  $$ select public.spin_reward_wheel('ca420000-0000-0000-0000-000000000101'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Unauthenticated call to spin_reward_wheel fails'
);

-- Switch back to Paired Child Device A1
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "60000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 20: Child device attempting to spin for sibling fails (42501)
select throws_ok(
  $$ select public.spin_reward_wheel('ca420000-0000-0000-0000-000000000102'::uuid, 'ca420000-0000-0000-0000-000000000002'::uuid) $$,
  '42501',
  NULL,
  'Child device spinning for sibling child is denied'
);

-- Test 21: Disabled wheel fails (LW206) with zero economic effects
-- Temporarily disable wheel for Family A (superuser context)
reset role;
update public.family_wheel_settings set is_enabled = false where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "60000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

select throws_ok(
  $$ select public.spin_reward_wheel('ca420000-0000-0000-0000-000000000103'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid) $$,
  'LW206',
  NULL,
  'Disabled wheel fails with LW206'
);

-- Re-enable wheel
reset role;
update public.family_wheel_settings set is_enabled = true where family_id = 'fa420000-0000-0000-0000-000000000001'::uuid;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "60000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 22: Successful Spin 1
select is(
  (select (public.spin_reward_wheel('ca420000-0000-0000-0000-000000000104'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid) ->> 'spin_cost_minor')::bigint),
  1000::bigint,
  'Spin 1 succeeds and returns spin_cost_minor = 1000'
);

-- Test 23: Balance reduced by exactly 1000 minor RP (from 5000 to 4000)
select is(
  (select rp_balance_minor from public.child_balances where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid),
  4000::bigint,
  'Child balance decremented by exactly 1000 minor'
);

-- Test 24: Exactly 1 wheel_spins row created
select is(
  (select count(*) from public.wheel_spins where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid),
  1::bigint,
  'Exactly 1 wheel_spins row created'
);

-- Test 25: Exactly 1 reward_redemptions row created with origin = 'wheel' and status = 'pending_fulfillment'
select is(
  (select count(*) from public.reward_redemptions where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid and origin = 'wheel' and status = 'pending_fulfillment'),
  1::bigint,
  'Exactly 1 reward_redemptions created with origin = wheel'
);

-- Test 26: Exactly 1 rp_ledger row created with reason_code = 'wheel_spin' and amount = -1000
select is(
  (select count(*) from public.rp_ledger where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid and reason_code = 'wheel_spin' and amount_minor = -1000),
  1::bigint,
  'Exactly 1 rp_ledger debit row created for wheel_spin'
);

-- Test 27: Idempotent replay of same command_id returns identical result
select is(
  (select public.spin_reward_wheel('ca420000-0000-0000-0000-000000000104'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid) ->> 'spin_id'),
  (select id::text from public.wheel_spins where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid),
  'Command receipt replay returns exact same spin_id'
);

-- Test 28: Replay did NOT cause a second debit
select is(
  (select rp_balance_minor from public.child_balances where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid),
  4000::bigint,
  'Replay did not perform duplicate debit (balance remains 4000)'
);

-- Test 29: selection_snapshot contains deterministic random_draw within winning interval
select is(
  (select (ws.selection_snapshot ->> 'random_draw')::integer >= (winner.item ->> 'interval_start')::integer
          and (ws.selection_snapshot ->> 'random_draw')::integer < (winner.item ->> 'interval_end')::integer
   from public.wheel_spins ws,
   lateral (
     select item from jsonb_array_elements(ws.selection_snapshot -> 'ordered_pool') item
     where (item ->> 'reward_id')::uuid = ws.reward_id
   ) winner
   where ws.child_id = 'ca420000-0000-0000-0000-000000000001'::uuid),
  true,
  'Selection snapshot random_draw falls strictly within winning interval [start, end)'
);

-- Test 30: Spin 2 succeeds (balance 4000 -> 3000)
select ok(
  (select public.spin_reward_wheel('ca420000-0000-0000-0000-000000000105'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid) is not null),
  'Spin 2 succeeds'
);

-- Test 31: Spin 3 succeeds (balance 3000 -> 2000, 3/3 daily cap reached)
select ok(
  (select public.spin_reward_wheel('ca420000-0000-0000-0000-000000000106'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid) is not null),
  'Spin 3 succeeds'
);

-- Test 32: Spin 4 fails with LW202 (Daily spin limit reached)
select throws_ok(
  $$ select public.spin_reward_wheel('ca420000-0000-0000-0000-000000000107'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid) $$,
  'LW202',
  NULL,
  'Spin 4 blocked by daily spin cap (LW202)'
);

-- Test 33: Balance remains 2000 (no debit on failed daily cap spin)
select is(
  (select rp_balance_minor from public.child_balances where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid),
  2000::bigint,
  'Failed daily cap spin does not decrement balance'
);

-- ---------------------------------------------------------------------------
-- 5. WHEEL CANCELLATION / REFUND / NO-REROLL TESTS
-- ---------------------------------------------------------------------------

-- Switch to Parent Owner A context to cancel redemption from Spin 1
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "60000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Retrieve redemption_id for Spin 1
create temp table temp_spin_1 on commit drop as
select redemption_id, id as spin_id
from public.wheel_spins
where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid
order by created_at asc limit 1;

-- Test 34: Cancel Wheel Redemption using existing cancel_reward_redemption RPC
select is(
  (select status from public.cancel_reward_redemption(
    (select redemption_id from temp_spin_1),
    'ca420000-0000-0000-0000-000000000201'::uuid,
    'Out of stock at grocery store'
  )),
  'cancelled',
  'cancel_reward_redemption cancels wheel redemption and refunds RP'
);

-- Test 35: Balance refunded by 1000 minor RP (2000 -> 3000)
select is(
  (select rp_balance_minor from public.child_balances where child_id = 'ca420000-0000-0000-0000-000000000001'::uuid),
  3000::bigint,
  'Compensating refund restored 1000 RP minor to balance'
);

-- Test 36: wheel_spins row remains intact (immutable history)
select is(
  (select count(*) from public.wheel_spins where id = (select spin_id from temp_spin_1)),
  1::bigint,
  'wheel_spins row remains immutable after cancellation'
);

-- Test 37: Daily spin cap is NOT restored (3 spins still counted, Spin 4 still blocked)
select throws_ok(
  $$ select public.spin_reward_wheel('ca420000-0000-0000-0000-000000000108'::uuid, 'ca420000-0000-0000-0000-000000000001'::uuid) $$,
  'LW202',
  NULL,
  'Cancellation does NOT restore daily spin quota (no rerolls permitted)'
);

-- Test 38: Balance reconciliation passes
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "60000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select is(
  (select is_reconciled from public.reconcile_child_balance('ca420000-0000-0000-0000-000000000001'::uuid)),
  true,
  'Balance is 100% reconciled with rp_ledger sum after wheel spins and refund'
);

select * from finish();
rollback;
