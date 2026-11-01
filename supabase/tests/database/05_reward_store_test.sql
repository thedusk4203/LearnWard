begin;
select plan(49);

-- ---------------------------------------------------------------------------
-- 0. FIXTURES SETUP (superuser context)
-- ---------------------------------------------------------------------------

insert into auth.users (id, aud, role, email) values
  ('40000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'p4_owner_a@test.com'),
  ('40000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'p4_owner_b@test.com'),
  ('40000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'p4_child_device_a1@test.com'),
  ('40000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'p4_child_device_a2@test.com')
on conflict (id) do nothing;

insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('fa000000-0000-0000-0000-000000000001'::uuid, 'Phase 4 Family A', 'America/New_York', 'en_US', '40000000-0000-0000-0000-000000000001'::uuid),
  ('fb000000-0000-0000-0000-000000000002'::uuid, 'Phase 4 Family B', 'UTC', 'en_US', '40000000-0000-0000-0000-000000000002'::uuid)
on conflict (id) do nothing;

insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('fa000000-0000-0000-0000-000000000001'::uuid, '40000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('fb000000-0000-0000-0000-000000000002'::uuid, '40000000-0000-0000-0000-000000000002'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
  ('ca000000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Child A1', 5, 2015),
  ('ca000000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Child A2 (Sibling)', 3, 2017),
  ('cb000000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000002'::uuid, 'Child B1', 6, 2014)
on conflict (id) do nothing;

insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('da000000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000001'::uuid, '40000000-0000-0000-0000-000000000003'::uuid, 'active', '40000000-0000-0000-0000-000000000001'::uuid),
  ('da000000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000002'::uuid, '40000000-0000-0000-0000-000000000004'::uuid, 'active', '40000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- Initialize Child A1 with 5000 RP minor ($50.00)
insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor) values
  ('fa000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000001'::uuid, 100, 5000),
  ('fa000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000002'::uuid, 50, 500)
on conflict (child_id) do update set rp_balance_minor = excluded.rp_balance_minor;

insert into public.rp_ledger (id, family_id, child_id, amount_minor, reason_code, source_type, idempotency_key) values
  (gen_random_uuid(), 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000001'::uuid, 5000, 'initial_grant', 'growth_event', 'init:a1'),
  (gen_random_uuid(), 'fa000000-0000-0000-0000-000000000001'::uuid, 'ca000000-0000-0000-0000-000000000002'::uuid, 500, 'initial_grant', 'growth_event', 'init:a2')
on conflict (idempotency_key) do nothing;

-- Rewards fixtures
insert into public.rewards (id, family_id, title, description, category, store_enabled, store_cost_minor, is_active) values
  ('ea000000-0000-0000-0000-000000000001'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, '30 min gaming', 'Weekend only', 'privilege', true, 2000, true),
  ('ea000000-0000-0000-0000-000000000004'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Paused Toy', 'Seasonal', 'item', true, 1000, false),
  ('ea000000-0000-0000-0000-000000000005'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Wheel Only Privilege', 'Not in store', 'privilege', false, null, true),
  ('eb000000-0000-0000-0000-000000000001'::uuid, 'fb000000-0000-0000-0000-000000000002'::uuid, 'Family B Ice Cream', 'Dessert', 'treat', true, 3000, true)
on conflict (id) do nothing;

-- Child-specific rewards
insert into public.rewards (id, family_id, title, description, category, store_enabled, store_cost_minor, target_child_id, is_active) values
  ('ea000000-0000-0000-0000-000000000002'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Child A1 Special Book', 'For A1 only', 'item', true, 1500, 'ca000000-0000-0000-0000-000000000001'::uuid, true),
  ('ea000000-0000-0000-0000-000000000003'::uuid, 'fa000000-0000-0000-0000-000000000001'::uuid, 'Child A2 Special Toy', 'For A2 only', 'item', true, 1000, 'ca000000-0000-0000-0000-000000000002'::uuid, true)
on conflict (id) do nothing;

-- Setup fixture receipt with operation='submit' for adversarial replay test
insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
values (
  'ca000000-0000-0000-0000-000000000999'::uuid,
  'submit',
  '40000000-0000-0000-0000-000000000003'::uuid,
  gen_random_uuid(),
  'fa000000-0000-0000-0000-000000000001'::uuid
);

-- ---------------------------------------------------------------------------
-- 1. SECURITY & RLS POLICIES
-- ---------------------------------------------------------------------------

-- Switch to Paired Child Device A1 context
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 1: Paired child cannot INSERT into rewards
select throws_ok(
  $$
    insert into public.rewards (family_id, title, category, store_cost_minor)
    values ('fa000000-0000-0000-0000-000000000001'::uuid, 'Hacked Reward', 'treat', 100)
  $$,
  '42501',
  null,
  'Paired child device cannot INSERT into rewards catalog'
);

-- Test 2: Paired child cannot UPDATE rewards (invisible via RLS)
select is_empty(
  $$
    update public.rewards
    set store_cost_minor = 10
    where id = 'ea000000-0000-0000-0000-000000000001'::uuid
    returning *
  $$,
  'Paired child device cannot UPDATE rewards catalog'
);

-- Test 3: Paired child cannot DELETE rewards (invisible via RLS)
select is_empty(
  $$
    delete from public.rewards
    where id = 'ea000000-0000-0000-0000-000000000001'::uuid
    returning *
  $$,
  'Paired child device cannot DELETE rewards catalog'
);

-- Test 3a: Paired child A1 can SELECT active family-wide Store reward
select results_eq(
  $$
    select id from public.rewards
    where id = 'ea000000-0000-0000-0000-000000000001'::uuid
  $$,
  $$ values ('ea000000-0000-0000-0000-000000000001'::uuid) $$,
  'Paired child A1 can SELECT active family-wide Store reward'
);

-- Test 3b: Paired child A1 can SELECT A1-targeted Store reward
select results_eq(
  $$
    select id from public.rewards
    where id = 'ea000000-0000-0000-0000-000000000002'::uuid
  $$,
  $$ values ('ea000000-0000-0000-0000-000000000002'::uuid) $$,
  'Paired child A1 can SELECT A1-targeted Store reward'
);

-- Test 3c: Paired child A1 cannot SELECT A2-targeted sibling reward
select is_empty(
  $$
    select id from public.rewards
    where id = 'ea000000-0000-0000-0000-000000000003'::uuid
  $$,
  'Paired child A1 cannot SELECT A2-targeted sibling reward'
);

-- Test 3d: Paired child cannot SELECT inactive reward (is_active = false)
select is_empty(
  $$
    select id from public.rewards
    where id = 'ea000000-0000-0000-0000-000000000004'::uuid
  $$,
  'Paired child cannot SELECT inactive reward (is_active = false)'
);

-- Test 3e: Paired child cannot SELECT store_enabled = false (Wheel-only reward)
select is_empty(
  $$
    select id from public.rewards
    where id = 'ea000000-0000-0000-0000-000000000005'::uuid
  $$,
  'Paired child cannot SELECT store_enabled = false (Wheel-only reward)'
);

-- Test 3f: Paired child cannot SELECT another family reward
select is_empty(
  $$
    select id from public.rewards
    where id = 'eb000000-0000-0000-0000-000000000001'::uuid
  $$,
  'Paired child cannot SELECT another family reward'
);

-- Test 4: Direct client INSERT into reward_redemptions is revoked
select throws_ok(
  $$
    insert into public.reward_redemptions (
      family_id, child_id, reward_id, origin, rp_cost_minor, reward_snapshot
    ) values (
      'fa000000-0000-0000-0000-000000000001'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid,
      'ea000000-0000-0000-0000-000000000001'::uuid,
      'store', 0, '{}'::jsonb
    )
  $$,
  '42501',
  null,
  'Direct client INSERT into reward_redemptions is strictly revoked'
);

-- Switch to Family A Owner context
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 5: Family A owner cannot read Family B catalog
select is_empty(
  $$
    select * from public.rewards
    where family_id = 'fb000000-0000-0000-0000-000000000002'::uuid
  $$,
  'Family A adult cannot read Family B reward catalog'
);

-- Test 6: Family A owner cannot mutate Family B catalog
select is_empty(
  $$
    update public.rewards
    set title = 'Malicious Rename'
    where family_id = 'fb000000-0000-0000-0000-000000000002'::uuid
    returning *
  $$,
  'Family A adult cannot update Family B rewards'
);

-- Test 7: Family A owner cannot delete Family B catalog
select is_empty(
  $$
    delete from public.rewards
    where family_id = 'fb000000-0000-0000-0000-000000000002'::uuid
    returning *
  $$,
  'Family A adult cannot delete Family B rewards'
);

-- Test 8: Reward tenant reassignment is blocked by trigger
select throws_ok(
  $$
    update public.rewards
    set family_id = 'fb000000-0000-0000-0000-000000000002'::uuid
    where id = 'ea000000-0000-0000-0000-000000000001'::uuid
  $$,
  'LW102',
  'Reward family_id is immutable',
  'Reward family_id is immutable'
);

-- Test 9: Composite FK restricts target_child_id to same family
select throws_ok(
  $$
    insert into public.rewards (
      family_id, title, category, store_cost_minor, target_child_id
    ) values (
      'fa000000-0000-0000-0000-000000000001'::uuid,
      'Cross Family Target',
      'treat',
      1000,
      'cb000000-0000-0000-0000-000000000001'::uuid -- Belongs to Family B!
    )
  $$,
  '23503',
  null,
  'target_child_id must belong to the exact same family_id'
);

-- ---------------------------------------------------------------------------
-- 2. STORE REDEMPTION (redeem_store_reward)
-- ---------------------------------------------------------------------------

-- Switch to Child A1 session
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 10: Successful redemption debits balance and returns redemption
select lives_ok(
  $$
    select * from public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000001'::uuid, -- 2000 minor RP
      'ca000000-0000-0000-0000-000000000101'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  'redeem_store_reward succeeds for active child with sufficient balance'
);

-- Test 11: Child A1 balance is decremented from 5000 to 3000
select results_eq(
  $$
    select rp_balance_minor from public.child_balances
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
  $$,
  $$ values (3000::bigint) $$,
  'child_balances.rp_balance_minor decremented from 5000 to 3000'
);

-- Test 12: Negative debit appended to rp_ledger
select results_eq(
  $$
    select amount_minor, reason_code, source_type
    from public.rp_ledger
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
      and reason_code = 'store_redemption'
  $$,
  $$ values (-2000::bigint, 'store_redemption'::text, 'reward_redemption'::text) $$,
  'rp_ledger contains exactly one negative debit of 2000 minor'
);

-- Test 13: Redemption row created with status pending_fulfillment and origin store
select results_eq(
  $$
    select status, origin, rp_cost_minor
    from public.reward_redemptions
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
      and reward_id = 'ea000000-0000-0000-0000-000000000001'::uuid
  $$,
  $$ values ('pending_fulfillment'::text, 'store'::text, 2000::bigint) $$,
  'reward_redemptions row created with pending_fulfillment and origin=store'
);

-- Switch to Family A adult to verify command receipt
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 14: Command receipt recorded with resource_id = redemption.id
select results_eq(
  $$
    select cr.operation, cr.family_id, (cr.resource_id = rr.id)
    from public.command_receipts cr
    join public.reward_redemptions rr on rr.id = cr.resource_id
    where cr.command_id = 'ca000000-0000-0000-0000-000000000101'::uuid
  $$,
  $$ values ('redeem_reward'::text, 'fa000000-0000-0000-0000-000000000001'::uuid, true) $$,
  'command_receipt recorded with operation=redeem_reward and resource_id matching redemption.id'
);

-- Switch back to Child A1
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 15: Replaying same command ID returns existing redemption without additional debit
select results_eq(
  $$
    select id, status, rp_cost_minor
    from public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000001'::uuid,
      'ca000000-0000-0000-0000-000000000101'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  $$
    select id, status, rp_cost_minor
    from public.reward_redemptions
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
      and reward_id = 'ea000000-0000-0000-0000-000000000001'::uuid
  $$,
  'Replaying redeem command returns existing redemption idempotently'
);

-- Test 16: Balance still 3000 after replay
select results_eq(
  $$
    select rp_balance_minor from public.child_balances
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
  $$,
  $$ values (3000::bigint) $$,
  'Balance remains 3000 after idempotent command replay'
);

-- Test 17: Child device A1 cannot redeem for sibling Child A2
select throws_ok(
  $$
    select public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000001'::uuid,
      'ca000000-0000-0000-0000-000000000102'::uuid,
      'ca000000-0000-0000-0000-000000000002'::uuid
    )
  $$,
  '42501',
  'Permission denied',
  'Child device A1 cannot redeem for sibling Child A2'
);

-- Switch to Child A2 session
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);

-- Test 18: Child A2 has 500 minor; reward costs 2000 minor -> LW201
select throws_ok(
  $$
    select public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000001'::uuid,
      'ca000000-0000-0000-0000-000000000103'::uuid,
      'ca000000-0000-0000-0000-000000000002'::uuid
    )
  $$,
  'LW201',
  'Insufficient RP balance',
  'Insufficient balance fails closed with LW201'
);

-- Test 19: Child A2 balance remains 500
select results_eq(
  $$
    select rp_balance_minor from public.child_balances
    where child_id = 'ca000000-0000-0000-0000-000000000002'::uuid
  $$,
  $$ values (500::bigint) $$,
  'Child A2 balance remains unchanged at 500 after failed overdraft'
);

-- Switch back to Child A1
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 20: Inactive reward fails with LW205
select throws_ok(
  $$
    select public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000004'::uuid, -- is_active = false
      'ca000000-0000-0000-0000-000000000104'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  'LW205',
  'Reward no longer available',
  'Inactive reward fails with LW205'
);

-- Test 21: Store-disabled reward fails with LW205
select throws_ok(
  $$
    select public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000005'::uuid, -- store_enabled = false
      'ca000000-0000-0000-0000-000000000105'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  'LW205',
  'Reward no longer available',
  'Store-disabled reward fails with LW205'
);

-- Test 22: Target child mismatch (Child A1 attempting to buy Child A2-only reward) fails closed
select throws_ok(
  $$
    select public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000003'::uuid, -- target_child_id = Child A2
      'ca000000-0000-0000-0000-000000000106'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  '42501',
  'Child is not eligible for this reward',
  'Child is not eligible for sibling-specific reward'
);

-- Test 23: Cross-family reward redemption fails closed
select throws_ok(
  $$
    select public.redeem_store_reward(
      'eb000000-0000-0000-0000-000000000001'::uuid, -- Belongs to Family B
      'ca000000-0000-0000-0000-000000000107'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  '42501',
  'Cross-family reward redemption denied',
  'Cross-family reward redemption fails closed'
);

-- ---------------------------------------------------------------------------
-- 3. ADVERSARIAL IDEMPOTENCY & REPLAY ATTACK TESTS
-- ---------------------------------------------------------------------------

-- Test 24: Replaying same command ID with different operation fails closed
select throws_ok(
  $$
    select public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000001'::uuid,
      'ca000000-0000-0000-0000-000000000999'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  '42501',
  'Invalid command replay',
  'Replaying command ID with wrong operation fails closed'
);

-- Test 25: Replaying same command ID with different reward fails closed
select throws_ok(
  $$
    select public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000002'::uuid, -- Different reward!
      'ca000000-0000-0000-0000-000000000101'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  '42501',
  'Invalid command replay: resource mismatch',
  'Replaying command ID with different reward fails closed'
);

-- Switch to Family B Owner context
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Test 26: Replaying another family command ID from unauthorized user fails closed BEFORE replay check
select throws_ok(
  $$
    select public.redeem_store_reward(
      'ea000000-0000-0000-0000-000000000001'::uuid,
      'ca000000-0000-0000-0000-000000000101'::uuid,
      'ca000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  '42501',
  'Permission denied',
  'Unauthorized caller cannot probe or replay another family command receipt'
);

-- ---------------------------------------------------------------------------
-- 4. FULFILLMENT LIFECYCLE (fulfill_reward_redemption)
-- ---------------------------------------------------------------------------

-- Switch to Paired Child Device A1 context
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

-- Test 27: Paired child cannot fulfill redemptions (adult only)
select throws_ok(
  $$
    select public.fulfill_reward_redemption(
      (select id from public.reward_redemptions where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid limit 1),
      'ca000000-0000-0000-0000-000000000201'::uuid
    )
  $$,
  '42501',
  'Permission denied',
  'Paired child device cannot fulfill redemptions'
);

-- Switch to Family A Owner context
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 28: Active family adult can fulfill pending redemption
select lives_ok(
  $$
    select public.fulfill_reward_redemption(
      (select id from public.reward_redemptions where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid limit 1),
      'ca000000-0000-0000-0000-000000000201'::uuid
    )
  $$,
  'Active adult successfully fulfills pending redemption'
);

-- Test 29: Status is fulfilled, fulfilled_at and fulfilled_by_user_id are populated
select results_eq(
  $$
    select status, (fulfilled_at is not null), fulfilled_by_user_id
    from public.reward_redemptions
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
  $$,
  $$ values ('fulfilled'::text, true, '40000000-0000-0000-0000-000000000001'::uuid) $$,
  'Redemption transitioned to fulfilled with audit timestamps and actor'
);

-- Test 30: Replaying fulfill command returns fulfilled redemption idempotently
select results_eq(
  $$
    select id, status
    from public.fulfill_reward_redemption(
      (select id from public.reward_redemptions where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid limit 1),
      'ca000000-0000-0000-0000-000000000201'::uuid
    )
  $$,
  $$
    select id, status
    from public.reward_redemptions
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid limit 1
  $$,
  'Replaying fulfill command returns existing fulfilled redemption idempotently'
);

-- Test 31: Attempting to fulfill an already fulfilled redemption with a NEW command ID fails with LW204
select throws_ok(
  $$
    select public.fulfill_reward_redemption(
      (select id from public.reward_redemptions where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid limit 1),
      'ca000000-0000-0000-0000-000000000202'::uuid -- New command ID!
    )
  $$,
  'LW204',
  'Reward redemption is already in a terminal state: fulfilled',
  'Fulfilling an already fulfilled redemption fails closed with LW204'
);

-- Test 32: Attempting to cancel an already fulfilled redemption fails with LW204
select throws_ok(
  $$
    select public.cancel_reward_redemption(
      (select id from public.reward_redemptions where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid limit 1),
      'ca000000-0000-0000-0000-000000000301'::uuid,
      'Out of stock'
    )
  $$,
  'LW204',
  'Reward redemption is already in a terminal state: fulfilled',
  'Cancelling an already fulfilled redemption fails closed with LW204'
);

-- ---------------------------------------------------------------------------
-- 5. CANCELLATION & COMPENSATING REFUND (cancel_reward_redemption)
-- ---------------------------------------------------------------------------

-- First, let's create a SECOND redemption to cancel
-- Switch to Child A1: balance is currently 3000
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

select public.redeem_store_reward(
  'ea000000-0000-0000-0000-000000000002'::uuid, -- 1500 minor RP
  'ca000000-0000-0000-0000-000000000108'::uuid,
  'ca000000-0000-0000-0000-000000000001'::uuid
);

-- Balance is now 3000 - 1500 = 1500 minor RP
-- Test 33: Balance decremented to 1500
select results_eq(
  $$
    select rp_balance_minor from public.child_balances
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
  $$,
  $$ values (1500::bigint) $$,
  'Balance is 1500 after second redemption'
);

-- Switch to Family A Owner context
select set_config('request.jwt.claims', '{"sub": "40000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 34: Cancel requires non-empty cancellation reason
select throws_ok(
  $$
    select public.cancel_reward_redemption(
      (select id from public.reward_redemptions where reward_id = 'ea000000-0000-0000-0000-000000000002'::uuid),
      'ca000000-0000-0000-0000-000000000302'::uuid,
      '  '
    )
  $$,
  '22000',
  'Cancellation reason is required',
  'Empty cancellation reason fails with 22000'
);

-- Test 35: Active adult cancels pending redemption with reason
select lives_ok(
  $$
    select public.cancel_reward_redemption(
      (select id from public.reward_redemptions where reward_id = 'ea000000-0000-0000-0000-000000000002'::uuid),
      'ca000000-0000-0000-0000-000000000303'::uuid,
      'Book was out of print'
    )
  $$,
  'Active adult successfully cancels pending redemption'
);

-- Test 36: Status is cancelled and reason is recorded
select results_eq(
  $$
    select status, cancellation_reason
    from public.reward_redemptions
    where reward_id = 'ea000000-0000-0000-0000-000000000002'::uuid
  $$,
  $$ values ('cancelled'::text, 'Book was out of print'::text) $$,
  'Redemption transitioned to cancelled with reason recorded'
);

-- Test 37: Compensating credit of +1500 minor appended to rp_ledger
select results_eq(
  $$
    select amount_minor, reason_code, source_type
    from public.rp_ledger
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
      and reason_code = 'redemption_refund'
  $$,
  $$ values (1500::bigint, 'redemption_refund'::text, 'reward_redemption'::text) $$,
  'rp_ledger contains exactly one compensating credit of +1500 minor'
);

-- Test 38: Child balance restored from 1500 back to 3000
select results_eq(
  $$
    select rp_balance_minor from public.child_balances
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
  $$,
  $$ values (3000::bigint) $$,
  'child_balances.rp_balance_minor restored from 1500 back to 3000'
);

-- Test 39: Replaying cancel command returns cancelled redemption without second refund
select results_eq(
  $$
    select id, status
    from public.cancel_reward_redemption(
      (select id from public.reward_redemptions where reward_id = 'ea000000-0000-0000-0000-000000000002'::uuid),
      'ca000000-0000-0000-0000-000000000303'::uuid,
      'Book was out of print'
    )
  $$,
  $$
    select id, status
    from public.reward_redemptions
    where reward_id = 'ea000000-0000-0000-0000-000000000002'::uuid
  $$,
  'Replaying cancel command returns existing cancelled redemption idempotently'
);

-- Test 40: Balance remains 3000 after idempotent cancel replay (no duplicate refund)
select results_eq(
  $$
    select rp_balance_minor from public.child_balances
    where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid
  $$,
  $$ values (3000::bigint) $$,
  'Balance remains 3000 without second refund on replay'
);

-- Test 41: Attempting to cancel an already cancelled redemption with a NEW command ID fails with LW204
select throws_ok(
  $$
    select public.cancel_reward_redemption(
      (select id from public.reward_redemptions where reward_id = 'ea000000-0000-0000-0000-000000000002'::uuid),
      'ca000000-0000-0000-0000-000000000304'::uuid,
      'Different reason'
    )
  $$,
  'LW204',
  'Reward redemption is already in a terminal state: cancelled',
  'Cancelling an already cancelled redemption fails closed with LW204'
);

-- Test 42: Attempting to fulfill an already cancelled redemption fails with LW204
select throws_ok(
  $$
    select public.fulfill_reward_redemption(
      (select id from public.reward_redemptions where reward_id = 'ea000000-0000-0000-0000-000000000002'::uuid),
      'ca000000-0000-0000-0000-000000000203'::uuid
    )
  $$,
  'LW204',
  'Reward redemption is already in a terminal state: cancelled',
  'Fulfilling an already cancelled redemption fails closed with LW204'
);

-- ---------------------------------------------------------------------------
-- 6. BALANCE RECONCILIATION
-- ---------------------------------------------------------------------------

-- Test 43: child_balances strictly equals sum of rp_ledger entries
select results_eq(
  $$
    select
      (select rp_balance_minor from public.child_balances where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid),
      (select coalesce(sum(amount_minor), 0)::bigint from public.rp_ledger where child_id = 'ca000000-0000-0000-0000-000000000001'::uuid)
  $$,
  $$ values (3000::bigint, 3000::bigint) $$,
  'child_balances.rp_balance_minor strictly equals SUM(rp_ledger.amount_minor)'
);

rollback;
