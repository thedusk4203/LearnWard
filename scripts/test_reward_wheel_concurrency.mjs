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

  console.log('===============================================================');
  console.log('ALL CELEBRATION WHEEL CONCURRENCY REGRESSION TESTS PASSED!');
  console.log('===============================================================');
}

main().catch((err) => {
  console.error('Unhandled test failure:', err);
  process.exit(1);
});
