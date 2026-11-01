// scripts/test_reward_store_concurrency.mjs
/**
 * LearnWard - Reward Store Concurrency Regression Test
 *
 * PURPOSE:
 * 1. Double Store Redemption Race:
 *    When two concurrent redeem_store_reward calls are made on the same child balance
 *    where balance = 4000 minor and reward cost = 4000 minor, row-level locking
 *    serializes execution:
 *    - Exactly ONE succeeds (balance becomes 0)
 *    - Exactly ONE fails with LW201: Insufficient RP balance
 *    - Balance never goes negative
 *    - Exactly ONE debit in rp_ledger
 *    - Exactly ONE reward_redemptions row created
 *
 * 2. Fulfill vs Cancel Race:
 *    When fulfill_reward_redemption and cancel_reward_redemption race on the same
 *    pending_fulfillment redemption, row-level locking on reward_redemptions guarantees:
 *    - Exactly ONE terminal transition wins
 *    - The other fails closed with LW204: Reward redemption is already in a terminal state
 *    - Terminal states are strictly mutually exclusive (never both)
 *    - Balance is strictly reconciled: child_balances.rp_balance_minor == sum(rp_ledger)
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
  console.log('=== LearnWard Concurrency Test: Reward Store & Redemption Serialization ===\n');

  const FAMILY_ID = crypto.randomUUID();
  const OWNER_ID = crypto.randomUUID();
  const CHILD_ID = crypto.randomUUID();
  const REWARD_1_ID = crypto.randomUUID();
  const REWARD_2_ID = crypto.randomUUID();

  console.log('1. Setting up fixture: Family, Child, Initial Balance = 4000 minor, and 4000 minor Reward...');

  const setupSql = `
    insert into auth.users (id, email) values ('${OWNER_ID}', 'store_concurrency_${OWNER_ID}@example.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_ID}', 'Store Concurrency Family', 'UTC', 'en-US', '${OWNER_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_ID}', '${FAMILY_ID}', 'Store Concurrency Child', 5, 2015)
    on conflict (id) do nothing;

    -- Initialize child balance with exactly 4000 minor ($40.00) and 50 XP
    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_ID}', '${CHILD_ID}', 50, 4000)
    on conflict (child_id) do update set rp_balance_minor = 4000, xp_total = 50;

    insert into public.xp_ledger (family_id, child_id, amount, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 50, 'initial_grant', 'growth_event', 'init_xp:${CHILD_ID}')
    on conflict (idempotency_key) do nothing;

    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 4000, 'initial_grant', 'growth_event', 'init:${CHILD_ID}')
    on conflict (idempotency_key) do nothing;

    -- Create catalog reward costing 4000 minor
    insert into public.rewards (id, family_id, title, category, store_enabled, store_cost_minor, is_active)
    values ('${REWARD_1_ID}', '${FAMILY_ID}', 'Big Toy', 'item', true, 4000, true)
    on conflict (id) do nothing;

    -- Create second catalog reward costing 2000 minor for scenario 2
    insert into public.rewards (id, family_id, title, category, store_enabled, store_cost_minor, is_active)
    values ('${REWARD_2_ID}', '${FAMILY_ID}', 'Movie Night', 'experience', true, 2000, true)
    on conflict (id) do nothing;
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr || setupRes.stdout);
    process.exit(1);
  }
  console.log('Fixture established: Balance = 4000 minor, Reward 1 Cost = 4000 minor.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 1: Double Store Redemption Race
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 1: Concurrent Double Store Redemption (4000 cost vs 4000 balance) ---');
  const CMD_REDEEM_1 = crypto.randomUUID();
  const CMD_REDEEM_2 = crypto.randomUUID();

  const t1RedeemSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_sleep(0.05);
    select public.redeem_store_reward('${REWARD_1_ID}'::uuid, '${CMD_REDEEM_1}'::uuid, '${CHILD_ID}'::uuid);
    commit;
  `;

  const t2RedeemSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select public.redeem_store_reward('${REWARD_1_ID}'::uuid, '${CMD_REDEEM_2}'::uuid, '${CHILD_ID}'::uuid);
    commit;
  `;

  console.log('Executing T1 and T2 concurrent redemptions...');
  const [t1Res, t2Res] = await Promise.all([
    runPsql(t1RedeemSql),
    runPsql(t2RedeemSql),
  ]);

  console.log('T1 Exit Code:', t1Res.code, t1Res.code === 0 ? 'SUCCESS' : 'FAILED: ' + t1Res.stderr.trim());
  console.log('T2 Exit Code:', t2Res.code, t2Res.code === 0 ? 'SUCCESS' : 'FAILED: ' + t2Res.stderr.trim());

  const successCount = (t1Res.code === 0 ? 1 : 0) + (t2Res.code === 0 ? 1 : 0);
  const failCount = (t1Res.code !== 0 ? 1 : 0) + (t2Res.code !== 0 ? 1 : 0);

  if (successCount !== 1 || failCount !== 1) {
    console.error(`FAILED: Expected exactly 1 success and 1 failure in double redemption race. Got ${successCount} successes, ${failCount} failures.`);
    process.exit(1);
  }
  console.log('PASS: Exactly 1 transaction succeeded and exactly 1 transaction failed.');

  // Verify DB state after Scenario 1
  const check1Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as balance,
      (select count(*) from public.rp_ledger where child_id = '${CHILD_ID}' and reason_code = 'store_redemption') as debits,
      (select count(*) from public.reward_redemptions where child_id = '${CHILD_ID}') as redemptions,
      r.is_reconciled
    from public.reconcile_child_balance('${CHILD_ID}') r;
  `;

  const check1Res = await runPsql(check1Sql);
  const match1 = check1Res.stdout.match(/(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(t|f)/);
  if (!match1) {
    console.error('FAILED to parse Scenario 1 verification output:', check1Res.stdout);
    process.exit(1);
  }

  const [, balance1, debits1, redemptions1, isReconciled1] = match1;
  console.log(`Verification: balance=${balance1}, debits=${debits1}, redemptions=${redemptions1}, is_reconciled=${isReconciled1}`);

  if (parseInt(balance1, 10) !== 0) {
    console.error(`FAILED: Expected balance to be 0, found: ${balance1}`);
    process.exit(1);
  }
  if (parseInt(debits1, 10) !== 1) {
    console.error(`FAILED: Expected exactly 1 store_redemption debit, found: ${debits1}`);
    process.exit(1);
  }
  if (parseInt(redemptions1, 10) !== 1) {
    console.error(`FAILED: Expected exactly 1 redemption, found: ${redemptions1}`);
    process.exit(1);
  }
  if (isReconciled1 !== 't') {
    console.error('FAILED: Balance is not reconciled with rp_ledger!');
    process.exit(1);
  }
  console.log('PASS: Balance is 0, never negative. Exactly 1 debit, 1 redemption, fully reconciled.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 2: Fulfill vs Cancel Race
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 2: Concurrent Fulfill vs Cancel Race on pending_fulfillment ---');

  // Add 2000 minor to child balance and create a fresh pending redemption
  const CMD_FRESH_REDEEM = crypto.randomUUID();
  const freshSetupSql = `
    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 2000, 'extra_grant', 'growth_event', 'extra:${CHILD_ID}');

    update public.child_balances
    set rp_balance_minor = rp_balance_minor + 2000
    where child_id = '${CHILD_ID}';

    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    -- Redeem Reward 2 (2000 cost) -> balance becomes 0 again, status = pending_fulfillment
    select 'PENDING_REDEMPTION_ID:' || (public.redeem_store_reward('${REWARD_2_ID}'::uuid, '${CMD_FRESH_REDEEM}'::uuid, '${CHILD_ID}'::uuid)).id as marker;
  `;

  const freshRes = await runPsql(freshSetupSql);
  const redMatch = freshRes.stdout.match(/PENDING_REDEMPTION_ID:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/);
  if (!redMatch) {
    console.error('FAILED to establish fresh redemption for fulfill vs cancel race:', freshRes.stderr || freshRes.stdout);
    process.exit(1);
  }
  const pendingRedemptionId = redMatch[1];
  console.log('Pending redemption established:', pendingRedemptionId);

  const CMD_FULFILL = crypto.randomUUID();
  const CMD_CANCEL = crypto.randomUUID();

  const tFulfillSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_sleep(0.04);
    select public.fulfill_reward_redemption('${pendingRedemptionId}'::uuid, '${CMD_FULFILL}'::uuid);
    commit;
  `;

  const tCancelSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select public.cancel_reward_redemption('${pendingRedemptionId}'::uuid, '${CMD_CANCEL}'::uuid, 'Race Cancel Reason');
    commit;
  `;

  console.log('Executing concurrent fulfill vs cancel...');
  const [fRes, cRes] = await Promise.all([
    runPsql(tFulfillSql),
    runPsql(tCancelSql),
  ]);

  console.log('Fulfill Exit Code:', fRes.code, fRes.code === 0 ? 'SUCCESS' : 'FAILED: ' + fRes.stderr.trim());
  console.log('Cancel Exit Code:', cRes.code, cRes.code === 0 ? 'SUCCESS' : 'FAILED: ' + cRes.stderr.trim());

  const fulfillWon = fRes.code === 0;
  const cancelWon = cRes.code === 0;

  if (fulfillWon === cancelWon) {
    console.error(`FAILED: Expected exactly one winner between fulfill and cancel. fulfillWon=${fulfillWon}, cancelWon=${cancelWon}`);
    process.exit(1);
  }
  console.log(`PASS: Exactly one transaction won: ${fulfillWon ? 'FULFILL' : 'CANCEL'}`);

  // Verification queries after Scenario 2
  const check2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      status,
      (select count(*) from public.rp_ledger where child_id = '${CHILD_ID}' and reason_code = 'redemption_refund') as refund_count,
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as balance,
      r.is_reconciled
    from public.reward_redemptions rr
    cross join public.reconcile_child_balance('${CHILD_ID}') r
    where rr.id = '${pendingRedemptionId}';
  `;

  const check2Res = await runPsql(check2Sql);
  const match2 = check2Res.stdout.match(/(fulfilled|cancelled)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(t|f)/);
  if (!match2) {
    console.error('FAILED to parse Scenario 2 verification output:', check2Res.stdout);
    process.exit(1);
  }

  const [, finalStatus, refundCount, finalBalance, isReconciled2] = match2;
  console.log(`Scenario 2 Outcome: status=${finalStatus}, refunds=${refundCount}, balance=${finalBalance}, reconciled=${isReconciled2}`);

  if (fulfillWon) {
    if (finalStatus !== 'fulfilled') {
      console.error(`FAILED: Expected status fulfilled, got ${finalStatus}`);
      process.exit(1);
    }
    if (parseInt(refundCount, 10) !== 0) {
      console.error(`FAILED: Expected 0 refunds when fulfill wins, got ${refundCount}`);
      process.exit(1);
    }
    if (parseInt(finalBalance, 10) !== 0) {
      console.error(`FAILED: Expected balance 0 when fulfill wins, got ${finalBalance}`);
      process.exit(1);
    }
  } else {
    if (finalStatus !== 'cancelled') {
      console.error(`FAILED: Expected status cancelled, got ${finalStatus}`);
      process.exit(1);
    }
    if (parseInt(refundCount, 10) !== 1) {
      console.error(`FAILED: Expected exactly 1 refund when cancel wins, got ${refundCount}`);
      process.exit(1);
    }
    if (parseInt(finalBalance, 10) !== 2000) {
      console.error(`FAILED: Expected balance 2000 when cancel wins, got ${finalBalance}`);
      process.exit(1);
    }
  }

  if (isReconciled2 !== 't') {
    console.error('FAILED: Final balance is not reconciled with rp_ledger!');
    process.exit(1);
  }

  console.log('PASS: Concurrency test completed successfully with 100% database reconciliation!');
}

main().catch((err) => {
  console.error('Fatal test error:', err);
  process.exit(1);
});
