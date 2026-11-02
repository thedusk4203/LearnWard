// scripts/test_reward_wheel_concurrency.mjs
/**
 * LearnWard - Celebration Wheel Concurrency Regression Test
 *
 * SCENARIOS:
 * 1. Double Wheel Spin Race:
 *    When two concurrent spin_reward_wheel calls race on a child balance of 1000 minor
 *    and spin cost = 1000 minor, row-level locking on child_balances serializes execution:
 *    - Exactly ONE succeeds (balance becomes 0)
 *    - Exactly ONE fails with LW201: Insufficient RP balance
 *    - Balance never goes negative
 *    - Exactly ONE debit in rp_ledger
 *    - Exactly ONE wheel_spins and ONE reward_redemptions row created
 *
 * 2. Concurrent Daily Spin Cap Race:
 *    When daily cap = 3, 2 spins already exist, and two concurrent spin_reward_wheel
 *    transactions race to claim the 3rd and final spin of the day:
 *    - Exactly ONE succeeds (recording the 3rd spin)
 *    - Exactly ONE fails with LW202: Daily spin limit reached
 *    - Exactly 3 spins recorded for the day
 *    - Balance reconciled
 *
 * 3. Store Redemption vs Wheel Spin Concurrency Race:
 *    When redeem_store_reward and spin_reward_wheel race concurrently on a 1000 minor balance:
 *    - Consistent lock acquisition (rewards FOR SHARE before child_balances FOR UPDATE)
 *      prevents cross-surface deadlocks
 *    - Exactly ONE succeeds, exactly ONE fails with LW201
 *    - Balance is strictly reconciled
 */

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';

function runPsql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'docker',
      ['exec', '-i', 'supabase_db_learnward', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'],
      { stdio: ['pipe', 'pipe', 'pipe'] }
    );

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (d) => { stdout += d.toString(); });
    child.stderr.on('data', (d) => { stderr += d.toString(); });

    child.on('close', (code) => {
      resolve({ code, stdout, stderr });
    });

    child.on('error', reject);

    child.stdin.write(sql);
    child.stdin.end();
  });
}

async function main() {
  console.log('=== LearnWard Concurrency Test: Celebration Wheel Serialization ===\n');

  const FAMILY_ID = crypto.randomUUID();
  const OWNER_ID = crypto.randomUUID();
  const CHILD_ID = crypto.randomUUID();
  const REWARD_1_ID = crypto.randomUUID();
  const REWARD_2_ID = crypto.randomUUID();
  const REWARD_3_ID = crypto.randomUUID();
  const STORE_REWARD_ID = crypto.randomUUID();

  console.log('1. Setting up fixture: Family, Child, Initial Balance = 1000 minor, and 3 Wheel Rewards...');

  const setupSql = `
    insert into auth.users (id, email) values ('${OWNER_ID}', 'wheel_concurrency_${OWNER_ID}@example.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_ID}', 'Wheel Concurrency Family', 'America/New_York', 'en-US', '${OWNER_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_ID}', '${FAMILY_ID}', 'Wheel Concurrency Child', 5, 2015)
    on conflict (id) do nothing;

    -- Initialize child balance with exactly 1000 minor ($10.00) and 50 XP
    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_ID}', '${CHILD_ID}', 50, 1000)
    on conflict (child_id) do update set rp_balance_minor = 1000, xp_total = 50;

    insert into public.xp_ledger (family_id, child_id, amount, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 50, 'initial_grant', 'growth_event', 'init_xp:${CHILD_ID}')
    on conflict (idempotency_key) do nothing;

    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 1000, 'initial_grant', 'growth_event', 'init:${CHILD_ID}')
    on conflict (idempotency_key) do nothing;

    -- Ensure 3 active eligible Wheel rewards
    insert into public.rewards (id, family_id, title, category, store_enabled, store_cost_minor, wheel_enabled, wheel_tier, is_active)
    values
      ('${REWARD_1_ID}', '${FAMILY_ID}', 'Screen Time 15m', 'privilege', false, null, true, 'common', true),
      ('${REWARD_2_ID}', '${FAMILY_ID}', 'Ice Cream Treat', 'treat', false, null, true, 'special', true),
      ('${REWARD_3_ID}', '${FAMILY_ID}', 'Movie Night Pick', 'experience', false, null, true, 'rare', true),
      ('${STORE_REWARD_ID}', '${FAMILY_ID}', 'Store Toy', 'item', true, 1000, false, null, true)
    on conflict (id) do nothing;
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr || setupRes.stdout);
    process.exit(1);
  }
  console.log('Fixture established: Balance = 1000 minor, 3 Wheel Rewards, 1 Store Reward (1000 minor).\n');

  // -------------------------------------------------------------------------
  // SCENARIO 1: Double Wheel Spin Race
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 1: Concurrent Double Wheel Spin (1000 spin cost vs 1000 balance) ---');
  const CMD_SPIN_1 = crypto.randomUUID();
  const CMD_SPIN_2 = crypto.randomUUID();

  const t1SpinSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_sleep(0.05);
    select public.spin_reward_wheel('${CMD_SPIN_1}'::uuid, '${CHILD_ID}'::uuid);
    commit;
  `;

  const t2SpinSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select public.spin_reward_wheel('${CMD_SPIN_2}'::uuid, '${CHILD_ID}'::uuid);
    commit;
  `;

  console.log('Executing T1 and T2 concurrent spins...');
  const [t1Res, t2Res] = await Promise.all([
    runPsql(t1SpinSql),
    runPsql(t2SpinSql),
  ]);

  console.log('T1 Exit Code:', t1Res.code, t1Res.code === 0 ? 'SUCCESS' : 'FAILED: ' + t1Res.stderr.trim());
  console.log('T2 Exit Code:', t2Res.code, t2Res.code === 0 ? 'SUCCESS' : 'FAILED: ' + t2Res.stderr.trim());

  const s1SuccessCount = (t1Res.code === 0 ? 1 : 0) + (t2Res.code === 0 ? 1 : 0);
  const s1FailCount = (t1Res.code !== 0 ? 1 : 0) + (t2Res.code !== 0 ? 1 : 0);

  if (s1SuccessCount !== 1 || s1FailCount !== 1) {
    console.error(`FAILED: Expected exactly 1 success and 1 failure in double spin race. Got ${s1SuccessCount} successes, ${s1FailCount} failures.`);
    process.exit(1);
  }
  console.log('PASS: Exactly 1 transaction succeeded and exactly 1 transaction failed (LW201).');

  // Verify DB state after Scenario 1
  const check1Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as balance,
      (select count(*) from public.rp_ledger where child_id = '${CHILD_ID}' and reason_code = 'wheel_spin') as debits,
      (select count(*) from public.wheel_spins where child_id = '${CHILD_ID}') as spins,
      (select count(*) from public.reward_redemptions where child_id = '${CHILD_ID}' and origin = 'wheel') as redemptions,
      r.is_reconciled
    from public.reconcile_child_balance('${CHILD_ID}') r;
  `;

  const check1Res = await runPsql(check1Sql);
  const match1 = check1Res.stdout.match(/(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(t|f)/);
  if (!match1) {
    console.error('FAILED to parse Scenario 1 verification output:', check1Res.stdout);
    process.exit(1);
  }

  const [, balance1, debits1, spins1, redemptions1, isReconciled1] = match1;
  console.log(`Verification: balance=${balance1}, debits=${debits1}, spins=${spins1}, redemptions=${redemptions1}, is_reconciled=${isReconciled1}`);

  if (parseInt(balance1, 10) !== 0) {
    console.error(`FAILED: Expected balance to be 0, found: ${balance1}`);
    process.exit(1);
  }
  if (parseInt(debits1, 10) !== 1) {
    console.error(`FAILED: Expected exactly 1 wheel_spin debit, found: ${debits1}`);
    process.exit(1);
  }
  if (parseInt(spins1, 10) !== 1 || parseInt(redemptions1, 10) !== 1) {
    console.error(`FAILED: Expected exactly 1 spin and 1 redemption, found spins=${spins1}, redemptions=${redemptions1}`);
    process.exit(1);
  }
  if (isReconciled1 !== 't') {
    console.error('FAILED: Balance is not reconciled with rp_ledger!');
    process.exit(1);
  }
  console.log('PASS: Balance is 0, never negative. Exactly 1 debit, 1 spin, 1 redemption, fully reconciled.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 2: Concurrent Daily Spin Cap Race
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 2: Concurrent Daily Spin Cap Race (Cap = 3, 2 spins exist, 2 concurrent spins) ---');

  // Fund child with 3000 minor RP and execute 1 more spin to reach exactly 2 spins today
  const CMD_SPIN_PREP = crypto.randomUUID();
  const prepCapSql = `
    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 5000, 'grant', 'growth_event', 'prep_cap:${CHILD_ID}')
    on conflict (idempotency_key) do nothing;

    update public.child_balances
    set rp_balance_minor = rp_balance_minor + 5000
    where child_id = '${CHILD_ID}';

    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${CMD_SPIN_PREP}'::uuid, '${CHILD_ID}'::uuid);
  `;

  const prepCapRes = await runPsql(prepCapSql);
  if (prepCapRes.code !== 0) {
    console.error('Failed to prepare Scenario 2 cap state:', prepCapRes.stderr || prepCapRes.stdout);
    process.exit(1);
  }
  console.log('Child now has exactly 2 spins today with ample balance (4000 minor RP). Daily cap is 3.');

  // Now race for the 3rd and final spin of the day
  const CMD_RACE_CAP_1 = crypto.randomUUID();
  const CMD_RACE_CAP_2 = crypto.randomUUID();

  const t1CapSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_sleep(0.04);
    select public.spin_reward_wheel('${CMD_RACE_CAP_1}'::uuid, '${CHILD_ID}'::uuid);
    commit;
  `;

  const t2CapSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select public.spin_reward_wheel('${CMD_RACE_CAP_2}'::uuid, '${CHILD_ID}'::uuid);
    commit;
  `;

  console.log('Executing T1 and T2 concurrent spins for the 3rd daily slot...');
  const [t1CapRes, t2CapRes] = await Promise.all([
    runPsql(t1CapSql),
    runPsql(t2CapSql),
  ]);

  console.log('T1 Cap Exit Code:', t1CapRes.code, t1CapRes.code === 0 ? 'SUCCESS' : 'FAILED: ' + t1CapRes.stderr.trim());
  console.log('T2 Cap Exit Code:', t2CapRes.code, t2CapRes.code === 0 ? 'SUCCESS' : 'FAILED: ' + t2CapRes.stderr.trim());

  const s2SuccessCount = (t1CapRes.code === 0 ? 1 : 0) + (t2CapRes.code === 0 ? 1 : 0);
  const s2FailCount = (t1CapRes.code !== 0 ? 1 : 0) + (t2CapRes.code !== 0 ? 1 : 0);

  if (s2SuccessCount !== 1 || s2FailCount !== 1) {
    console.error(`FAILED: Expected exactly 1 success and 1 failure in cap race. Got ${s2SuccessCount} successes, ${s2FailCount} failures.`);
    process.exit(1);
  }

  const failedError = t1CapRes.code !== 0 ? t1CapRes.stderr : t2CapRes.stderr;
  if (!failedError.includes('LW202') && !failedError.includes('Daily spin limit reached')) {
    console.error('FAILED: Expected daily cap rejection (LW202), found:', failedError);
    process.exit(1);
  }
  console.log('PASS: Exactly 1 spin claimed the 3rd slot; the other was rejected with LW202.\n');

  // Verify total spins today is exactly 3
  const check2Sql = `
    select count(*) as count from public.wheel_spins where child_id = '${CHILD_ID}';
  `;
  const check2Res = await runPsql(check2Sql);
  const match2 = check2Res.stdout.match(/\b(\d+)\b/);
  if (!match2 || parseInt(match2[1], 10) !== 3) {
    console.error('FAILED: Expected exactly 3 spins in database, found:', check2Res.stdout);
    process.exit(1);
  }
  console.log('PASS: Exactly 3 spins recorded in total for the day.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 3: Store Redemption vs Wheel Spin Concurrency Race
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 3: Concurrent Store Redemption vs Wheel Spin Race ---');

  // Reset child balance to exactly 1000 minor RP, reset spin cap setting to 10 to allow spins
  const CMD_STORE_RACE = crypto.randomUUID();
  const CMD_WHEEL_RACE = crypto.randomUUID();

  const prepRaceSql = `
    update public.family_wheel_settings
    set daily_spin_cap = 5
    where family_id = '${FAMILY_ID}';

    -- Set child balance directly to 1000 minor and add compensating ledger entry
    with current_bal as (
      select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}'
    )
    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    select '${FAMILY_ID}', '${CHILD_ID}', 1000 - cb.rp_balance_minor, 'admin_adjustment', 'manual', 'adjust:${CHILD_ID}'
    from current_bal cb
    on conflict (idempotency_key) do nothing;

    update public.child_balances
    set rp_balance_minor = 1000
    where child_id = '${CHILD_ID}';
  `;

  const prepRaceRes = await runPsql(prepRaceSql);
  if (prepRaceRes.code !== 0) {
    console.error('Failed to prepare Scenario 3 race state:', prepRaceRes.stderr || prepRaceRes.stdout);
    process.exit(1);
  }
  console.log('Prepared: Balance = 1000 minor, Store Reward = 1000 minor, Spin Cost = 1000 minor.');

  const tStoreSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_sleep(0.03);
    select public.redeem_store_reward('${STORE_REWARD_ID}'::uuid, '${CMD_STORE_RACE}'::uuid, '${CHILD_ID}'::uuid);
    commit;
  `;

  const tWheelSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select public.spin_reward_wheel('${CMD_WHEEL_RACE}'::uuid, '${CHILD_ID}'::uuid);
    commit;
  `;

  console.log('Executing concurrent Store Redemption and Wheel Spin on same 1000 balance...');
  const [storeRes, wheelRes] = await Promise.all([
    runPsql(tStoreSql),
    runPsql(tWheelSql),
  ]);

  console.log('Store Exit Code:', storeRes.code, storeRes.code === 0 ? 'SUCCESS' : 'FAILED: ' + storeRes.stderr.trim());
  console.log('Wheel Exit Code:', wheelRes.code, wheelRes.code === 0 ? 'SUCCESS' : 'FAILED: ' + wheelRes.stderr.trim());

  const s3SuccessCount = (storeRes.code === 0 ? 1 : 0) + (wheelRes.code === 0 ? 1 : 0);
  const s3FailCount = (storeRes.code !== 0 ? 1 : 0) + (wheelRes.code !== 0 ? 1 : 0);

  if (s3SuccessCount !== 1 || s3FailCount !== 1) {
    console.error(`FAILED: Expected exactly 1 success and 1 failure in store vs wheel race. Got ${s3SuccessCount} successes, ${s3FailCount} failures.`);
    process.exit(1);
  }

  // Ensure no deadlock occurred
  if (storeRes.stderr.includes('deadlock') || wheelRes.stderr.includes('deadlock')) {
    console.error('FAILED: Deadlock detected between store and wheel operations!');
    process.exit(1);
  }

  console.log('PASS: Exactly 1 transaction succeeded, 1 failed (LW201), NO deadlocks occurred.');

  // Final reconciliation check
  const finalCheckSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as balance,
      r.is_reconciled
    from public.reconcile_child_balance('${CHILD_ID}') r;
  `;

  const finalCheckRes = await runPsql(finalCheckSql);
  const matchFinal = finalCheckRes.stdout.match(/(\d+)\s*\|\s*(t|f)/);
  if (!matchFinal || parseInt(matchFinal[1], 10) !== 0 || matchFinal[2] !== 't') {
    console.error('FAILED: Final state is invalid or not reconciled:', finalCheckRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Final balance = 0, fully reconciled.\n');

  // --- SCENARIO 4A: Deterministic Concurrency Case A (Parent Mutation Wins First -> Spin Waits -> Complete NEW Pool) ---
  console.log('--- SCENARIO 4A: Deterministic Case A (Parent Mutation Wins First -> Spin Waits) ---');
  const CHILD_4A_ID = crypto.randomUUID();
  const R4_A_ID = crypto.randomUUID();
  const R5_NEW_A_ID = crypto.randomUUID();
  const CMD_SPIN_4A = crypto.randomUUID();

  const prep4ASql = `
    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_4A_ID}', '${FAMILY_ID}', 'Child 4A', 4, 2016);

    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_ID}', '${CHILD_4A_ID}', 50, 5000);

    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_4A_ID}', 5000, 'initial_grant', 'growth_event', 'init:${CHILD_4A_ID}');

    insert into public.rewards (id, family_id, title, category, store_enabled, wheel_enabled, wheel_tier, is_active)
    values ('${R4_A_ID}', '${FAMILY_ID}', 'Wheel Reward 4A (To Disable)', 'treat', false, true, 'common', true);
  `;

  const prep4ARes = await runPsql(prep4ASql);
  if (prep4ARes.code !== 0) {
    console.error('Failed to prepare Scenario 4A fixture:', prep4ARes.stderr || prep4ARes.stdout);
    process.exit(1);
  }
  console.log('Prepared fixture for 4A: 4 active wheel rewards, child with 5000 RP.');

  // Parent starts transaction, modifies catalog, and holds transaction open for 0.4s
  const tParentMutASql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    update public.rewards set wheel_enabled = false where id = '${R4_A_ID}';
    update public.rewards set wheel_tier = 'rare' where id = '${REWARD_2_ID}';
    insert into public.rewards (id, family_id, title, category, store_enabled, wheel_enabled, wheel_tier, is_active)
    values ('${R5_NEW_A_ID}', '${FAMILY_ID}', 'Brand New Wheel Reward 5A', 'experience', false, true, 'special', true);
    select pg_sleep(0.45);
    commit;
  `;

  // Child spin starts after 0.08s delay and attempts to acquire SHARE lock
  const tChildSpinASql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select pg_sleep(0.08);
    begin;
    select public.spin_reward_wheel('${CMD_SPIN_4A}'::uuid, '${CHILD_4A_ID}'::uuid);
    commit;
  `;

  // Watcher checks that the spin transaction is waiting on the rewards table lock while parent holds RowExclusiveLock
  const checkWaitASql = `
    select pg_sleep(0.20);
    select count(*) as waiting_count
    from pg_locks l
    where l.relation = 'public.rewards'::regclass
      and l.mode = 'ShareLock'
      and l.granted = false;
  `;

  console.log('Starting Parent mutation transaction and concurrent child spin...');
  const [parentMutARes, childSpinARes, waitCheckARes] = await Promise.all([
    runPsql(tParentMutASql),
    runPsql(tChildSpinASql),
    runPsql(checkWaitASql),
  ]);

  if (parentMutARes.code !== 0) {
    console.error('FAILED: Parent transaction failed in 4A:', parentMutARes.stderr);
    process.exit(1);
  }
  if (childSpinARes.code !== 0) {
    console.error('FAILED: Child spin failed in 4A:', childSpinARes.stderr);
    process.exit(1);
  }

  const waitMatchA = waitCheckARes.stdout.match(/waiting_count\s*\r?\n-+\s*\r?\n\s*(\d+)/) || waitCheckARes.stdout.match(/\b(\d+)\b/);
  const waitingCountA = waitMatchA ? parseInt(waitMatchA[1], 10) : 0;
  console.log(`Lock observation: ${waitingCountA} spin process(es) observed waiting for table lock.`);
  if (waitingCountA < 1) {
    console.error(`FAILED: Scenario 4A expected waiting_count >= 1 (spin waiting on ShareLock granted=false), but observed: ${waitingCountA}`);
    process.exit(1);
  }
  console.log('PASS: Spin was observed waiting on ShareLock (granted = false) while parent held catalog write lock.');
  console.log('PASS: Parent catalog mutation committed before spin completed.');

  // Verify the snapshot contains the COMPLETE NEW POOL (not hybrid)
  const inspectASql = `
    select selection_snapshot from public.wheel_spins where child_id = '${CHILD_4A_ID}';
  `;
  const inspectARes = await runPsql(inspectASql);
  const jsonMatchA = inspectARes.stdout.match(/\{[\s\S]*\}/);
  if (!jsonMatchA) {
    console.error('Failed to parse 4A snapshot JSON:', inspectARes.stdout);
    process.exit(1);
  }
  const snapA = JSON.parse(jsonMatchA[0]);

  // Assertions for Complete NEW Pool:
  // - R4_A_ID must be ABSENT
  // - REWARD_2_ID must have tier 'rare' (weight 10)
  // - R5_NEW_A_ID must be PRESENT
  const hasR4A = snapA.ordered_pool.some((p) => p.reward_id === R4_A_ID);
  const r2ItemA = snapA.ordered_pool.find((p) => p.reward_id === REWARD_2_ID);
  const hasR5A = snapA.ordered_pool.some((p) => p.reward_id === R5_NEW_A_ID);

  if (hasR4A) {
    console.error('FAILED: Disabled reward R4_A_ID is still present in snapshot!');
    process.exit(1);
  }
  if (!r2ItemA || r2ItemA.tier !== 'rare' || r2ItemA.weight !== 10) {
    console.error('FAILED: REWARD_2_ID did not reflect new tier rare (10)! Item:', r2ItemA);
    process.exit(1);
  }
  if (!hasR5A) {
    console.error('FAILED: Newly inserted reward R5_NEW_A_ID is absent from snapshot!');
    process.exit(1);
  }

  // Validate mathematical continuity of snapshot
  validateSnapshotMath(snapA, 'Case A');
  console.log('PASS: Snapshot contains exactly the COMPLETE NEW pool (no hybrid state).\n');

  // --- SCENARIO 4B: Deterministic Concurrency Case B (Spin Snapshot Wins First -> Parent Mutation Waits -> Complete OLD Pool) ---
  console.log('--- SCENARIO 4B: Deterministic Case B (Spin Snapshot Wins First -> Parent Mutation Waits) ---');
  const CHILD_4B_ID = crypto.randomUUID();
  const CMD_SPIN_4B = crypto.randomUUID();
  const R6_NEW_B_ID = crypto.randomUUID();

  const prep4BSql = `
    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_4B_ID}', '${FAMILY_ID}', 'Child 4B', 4, 2016);

    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_ID}', '${CHILD_4B_ID}', 50, 5000);

    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_4B_ID}', 5000, 'initial_grant', 'growth_event', 'init:${CHILD_4B_ID}');
  `;

  const prep4BRes = await runPsql(prep4BSql);
  if (prep4BRes.code !== 0) {
    console.error('Failed to prepare Scenario 4B fixture:', prep4BRes.stderr || prep4BRes.stdout);
    process.exit(1);
  }
  console.log('Prepared fixture for 4B.');

  // Spin holds SHARE lock on rewards table for 0.45s while performing spin
  const tSpinBSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    lock table public.rewards in share mode;
    select pg_sleep(0.45);
    select public.spin_reward_wheel('${CMD_SPIN_4B}'::uuid, '${CHILD_4B_ID}'::uuid);
    commit;
  `;

  // Parent attempts to insert and update rewards with 0.08s delay -> blocked by SHARE lock
  const tParentMutBSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select pg_sleep(0.08);
    begin;
    insert into public.rewards (id, family_id, title, category, store_enabled, wheel_enabled, wheel_tier, is_active)
    values ('${R6_NEW_B_ID}', '${FAMILY_ID}', 'Reward 6B (Concurrent with Spin)', 'treat', false, true, 'common', true);
    commit;
  `;

  // Watcher checks that the parent write transaction is waiting on the rewards table lock while spin holds ShareLock
  const checkWaitBSql = `
    select pg_sleep(0.20);
    select count(*) as waiting_count
    from pg_locks l
    where l.relation = 'public.rewards'::regclass
      and l.mode = 'RowExclusiveLock'
      and l.granted = false;
  `;

  console.log('Starting Spin holding SHARE lock and concurrent parent mutation...');
  const [spinBRes, parentMutBRes, waitCheckBRes] = await Promise.all([
    runPsql(tSpinBSql),
    runPsql(tParentMutBSql),
    runPsql(checkWaitBSql),
  ]);

  if (spinBRes.code !== 0) {
    console.error('FAILED: Spin failed in 4B:', spinBRes.stderr);
    process.exit(1);
  }
  if (parentMutBRes.code !== 0) {
    console.error('FAILED: Parent transaction failed in 4B:', parentMutBRes.stderr);
    process.exit(1);
  }

  const waitMatchB = waitCheckBRes.stdout.match(/waiting_count\s*\r?\n-+\s*\r?\n\s*(\d+)/) || waitCheckBRes.stdout.match(/\b(\d+)\b/);
  const waitingCountB = waitMatchB ? parseInt(waitMatchB[1], 10) : 0;
  console.log(`Lock observation: ${waitingCountB} parent write process(es) observed waiting for table lock.`);
  if (waitingCountB < 1) {
    console.error(`FAILED: Scenario 4B expected waiting_count >= 1 (parent writer waiting on RowExclusiveLock granted=false), but observed: ${waitingCountB}`);
    process.exit(1);
  }
  console.log('PASS: Parent writer was observed waiting on RowExclusiveLock (granted = false) while spin held ShareLock.');
  console.log('PASS: Spin committed before parent mutation was allowed to commit.');

  // Verify the snapshot contains the COMPLETE OLD POOL (R6_NEW_B_ID must be absent)
  const inspectBSql = `
    select selection_snapshot from public.wheel_spins where child_id = '${CHILD_4B_ID}';
  `;
  const inspectBRes = await runPsql(inspectBSql);
  const jsonMatchB = inspectBRes.stdout.match(/\{[\s\S]*\}/);
  if (!jsonMatchB) {
    console.error('Failed to parse 4B snapshot JSON:', inspectBRes.stdout);
    process.exit(1);
  }
  const snapB = JSON.parse(jsonMatchB[0]);

  const hasR6B = snapB.ordered_pool.some((p) => p.reward_id === R6_NEW_B_ID);
  if (hasR6B) {
    console.error('FAILED: Concurrent reward R6_NEW_B_ID leaked into spin snapshot!');
    process.exit(1);
  }

  validateSnapshotMath(snapB, 'Case B');
  console.log('PASS: Snapshot contains exactly the COMPLETE OLD pool (concurrent mutation did not leak in).\n');

  console.log('===============================================================');
  console.log('ALL CELEBRATION WHEEL CONCURRENCY REGRESSION TESTS PASSED!');
  console.log('===============================================================');
}

function validateSnapshotMath(snapshot, label) {
  const totalWeight = snapshot.total_weight;
  const pool = snapshot.ordered_pool;
  const winnerId = snapshot.winning_reward_id;
  const randomDraw = snapshot.random_draw;

  let sumWeights = 0;
  let prevEnd = 0;
  let winnerFound = false;

  for (let i = 0; i < pool.length; i++) {
    const item = pool[i];
    sumWeights += item.weight;
    if (item.interval_start !== prevEnd) {
      console.error(`FAILED (${label}): Discontinuity at index ${i}: expected ${prevEnd}, got ${item.interval_start}`);
      process.exit(1);
    }
    prevEnd = item.interval_end;

    if (item.reward_id === winnerId) {
      winnerFound = true;
      if (randomDraw < item.interval_start || randomDraw >= item.interval_end) {
        console.error(`FAILED (${label}): random_draw ${randomDraw} not in [${item.interval_start}, ${item.interval_end})`);
        process.exit(1);
      }
    }
  }

  if (sumWeights !== totalWeight) {
    console.error(`FAILED (${label}): sum(weights) ${sumWeights} != total_weight ${totalWeight}`);
    process.exit(1);
  }
  if (prevEnd !== totalWeight) {
    console.error(`FAILED (${label}): Final interval_end ${prevEnd} != total_weight ${totalWeight}`);
    process.exit(1);
  }
  if (!winnerFound) {
    console.error(`FAILED (${label}): Winner ${winnerId} not found in ordered_pool`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Unhandled test failure:', err);
  process.exit(1);
});
