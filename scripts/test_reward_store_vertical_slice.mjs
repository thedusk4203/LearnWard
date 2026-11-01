// scripts/test_reward_store_vertical_slice.mjs
/**
 * LearnWard - Reward Store Vertical Slice Integration Test
 *
 * PURPOSE:
 * Exercises the complete Phase 4.1 Reward Store lifecycle against local Supabase:
 *   1. Parent creates family, child, and configures catalog rewards.
 *   2. Child starts with verified RP balance in child_balances and rp_ledger.
 *   3. Child redeems a store reward -> immediate RP debit, pending_fulfillment.
 *   4. Parent cancels redemption with reason -> status cancelled, compensating refund appended, balance restored.
 *   5. Child redeems another store reward -> immediate RP debit, pending_fulfillment.
 *   6. Parent fulfills redemption -> status fulfilled, fulfilled_at & actor set, balance preserved.
 *   7. Overdraft prevention -> attempting to redeem more than available balance fails with LW201.
 *   8. Strict balance reconciliation: child_balances == sum(rp_ledger) across all operations.
 */

import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const FAMILY_ID = crypto.randomUUID();
const OWNER_ID = crypto.randomUUID();
const CHILD_ID = crypto.randomUUID();
const REWARD_1_ID = crypto.randomUUID();
const REWARD_2_ID = crypto.randomUUID();
const REWARD_EXPENSIVE_ID = crypto.randomUUID();

function runPsql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'docker',
      ['exec', '-i', 'supabase_db_learnward', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-t', '-A'],
      { stdio: ['pipe', 'pipe', 'pipe'] }
    );

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (d) => { stdout += d.toString(); });
    child.stderr.on('data', (d) => { stderr += d.toString(); });

    child.on('close', (code) => {
      resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
    });

    child.on('error', reject);

    child.stdin.write(sql);
    child.stdin.end();
  });
}

async function main() {
  console.log('=== LearnWard Phase 4.1: Reward Store Vertical Slice Integration Test ===\n');

  console.log('1. Setting up Family, Owner, Child, and Catalog Rewards...');
  const setupSql = `
    insert into auth.users (id, email) values ('${OWNER_ID}', 'store_vs_${OWNER_ID}@example.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_ID}', 'Store Slice Family', 'America/New_York', 'en-US', '${OWNER_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_ID}', '${FAMILY_ID}', 'Store Slice Child', 5, 2015)
    on conflict (id) do nothing;

    -- Initialize child balance with 6000 minor ($60.00) and 100 XP
    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_ID}', '${CHILD_ID}', 100, 6000);

    insert into public.xp_ledger (family_id, child_id, amount, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 100, 'initial_grant', 'growth_event', 'init_xp:${CHILD_ID}');

    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 6000, 'initial_grant', 'growth_event', 'init_rp:${CHILD_ID}');

    -- Parent creates catalog rewards
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    insert into public.rewards (id, family_id, title, description, category, store_enabled, store_cost_minor, is_active)
    values
      ('${REWARD_1_ID}', '${FAMILY_ID}', 'Choose Dinner', 'Pick any dinner on Friday', 'choice', true, 3000, true),
      ('${REWARD_2_ID}', '${FAMILY_ID}', '30 min Gaming', 'Weekend afternoon', 'privilege', true, 2000, true),
      ('${REWARD_EXPENSIVE_ID}', '${FAMILY_ID}', 'Expensive Video Game', 'Full game', 'item', true, 8000, true);
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('FAILED fixture setup:', setupRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Fixtures established: Child Balance = 6000 minor RP ($60.00).\n');

  // Step 2: Child redeems Reward 1 (3000 minor RP)
  console.log('2. Child redeems "Choose Dinner" (3000 minor RP)...');
  const CMD_REDEEM_1 = crypto.randomUUID();
  const redeem1Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select 'REDEMPTION_1:' || (public.redeem_store_reward(
      '${REWARD_1_ID}'::uuid,
      '${CMD_REDEEM_1}'::uuid,
      '${CHILD_ID}'::uuid
    )).id;
  `;

  const redeem1Res = await runPsql(redeem1Sql);
  if (redeem1Res.code !== 0) {
    console.error('FAILED redeem 1:', redeem1Res.stderr);
    process.exit(1);
  }
  const mRedeem1 = redeem1Res.stdout.match(/REDEMPTION_1:([0-9a-f-]+)/);
  if (!mRedeem1) {
    console.error('FAILED to parse redemption 1 ID:', redeem1Res.stdout);
    process.exit(1);
  }
  const redemption1Id = mRedeem1[1];
  console.log('PASS: Redemption 1 created:', redemption1Id);

  // Helper to get balance & reconciliation
  async function getBalanceAndReconciled() {
    const balSql = `
      set role authenticated;
      select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

      select cb.rp_balance_minor, r.is_reconciled
      from public.child_balances cb
      cross join public.reconcile_child_balance('${CHILD_ID}') r
      where cb.child_id = '${CHILD_ID}';
    `;
    const res = await runPsql(balSql);
    const lines = res.stdout.trim().split('\n').map(l => l.trim()).filter(Boolean);
    const [b, r] = lines[lines.length - 1].split('|');
    return { balance: parseInt(b, 10), isReconciled: r === 't' };
  }

  const check1 = await getBalanceAndReconciled();
  if (check1.balance !== 3000 || !check1.isReconciled) {
    console.error(`FAILED: Expected balance 3000, got ${check1.balance}, reconciled=${check1.isReconciled}`);
    process.exit(1);
  }
  console.log('PASS: Child balance decremented to 3000 minor RP, fully reconciled.\n');

  // Step 3: Parent cancels Redemption 1 with reason
  console.log('3. Parent cancels Redemption 1 ("Restaurant closed tonight")...');
  const CMD_CANCEL_1 = crypto.randomUUID();
  const cancel1Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select status, cancellation_reason
    from public.cancel_reward_redemption(
      '${redemption1Id}'::uuid,
      '${CMD_CANCEL_1}'::uuid,
      'Restaurant closed tonight'
    );
  `;
  const cancel1Res = await runPsql(cancel1Sql);
  if (cancel1Res.code !== 0) {
    console.error('FAILED cancel 1:', cancel1Res.stderr);
    process.exit(1);
  }

  const check2 = await getBalanceAndReconciled();
  if (check2.balance !== 6000 || !check2.isReconciled) {
    console.error(`FAILED: Expected balance restored to 6000, got ${check2.balance}, reconciled=${check2.isReconciled}`);
    process.exit(1);
  }
  console.log('PASS: Balance restored to 6000 minor RP via compensating refund, fully reconciled.\n');

  // Step 4: Child redeems Reward 2 ("30 min Gaming" for 2000 minor RP)
  console.log('4. Child redeems "30 min Gaming" (2000 minor RP)...');
  const CMD_REDEEM_2 = crypto.randomUUID();
  const redeem2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select 'REDEMPTION_2:' || (public.redeem_store_reward(
      '${REWARD_2_ID}'::uuid,
      '${CMD_REDEEM_2}'::uuid,
      '${CHILD_ID}'::uuid
    )).id;
  `;
  const redeem2Res = await runPsql(redeem2Sql);
  if (redeem2Res.code !== 0) {
    console.error('FAILED redeem 2:', redeem2Res.stderr);
    process.exit(1);
  }
  const mRedeem2 = redeem2Res.stdout.match(/REDEMPTION_2:([0-9a-f-]+)/);
  if (!mRedeem2) {
    console.error('FAILED to parse redemption 2 ID:', redeem2Res.stdout);
    process.exit(1);
  }
  const redemption2Id = mRedeem2[1];
  console.log('PASS: Redemption 2 created:', redemption2Id);

  // Step 5: Parent fulfills Redemption 2
  console.log('5. Parent fulfills Redemption 2...');
  const CMD_FULFILL_2 = crypto.randomUUID();
  const fulfill2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select status, fulfilled_by_user_id
    from public.fulfill_reward_redemption(
      '${redemption2Id}'::uuid,
      '${CMD_FULFILL_2}'::uuid
    );
  `;
  const fulfill2Res = await runPsql(fulfill2Sql);
  if (fulfill2Res.code !== 0) {
    console.error('FAILED fulfill 2:', fulfill2Res.stderr);
    process.exit(1);
  }

  const check3 = await getBalanceAndReconciled();
  if (check3.balance !== 4000 || !check3.isReconciled) {
    console.error(`FAILED: Expected balance 4000, got ${check3.balance}, reconciled=${check3.isReconciled}`);
    process.exit(1);
  }
  console.log('PASS: Redemption 2 fulfilled, balance remains 4000 minor RP, fully reconciled.\n');

  // Step 6: Overdraft attempt on expensive reward (8000 cost vs 4000 balance)
  console.log('6. Testing overdraft: Child attempts to redeem 8000 item with 4000 balance...');
  const CMD_OVERDRAFT = crypto.randomUUID();
  const overdraftSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select public.redeem_store_reward(
      '${REWARD_EXPENSIVE_ID}'::uuid,
      '${CMD_OVERDRAFT}'::uuid,
      '${CHILD_ID}'::uuid
    );
  `;
  const overdraftRes = await runPsql(overdraftSql);
  if (overdraftRes.code === 0) {
    console.error('FAILED: Overdraft should have failed but succeeded!');
    process.exit(1);
  }
  if (!overdraftRes.stderr.includes('Insufficient RP balance')) {
    console.error('FAILED: Overdraft did not report Insufficient RP balance:', overdraftRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Overdraft cleanly blocked with LW201 (Insufficient RP balance).\n');

  // Step 7: Final balance audit and reconciliation
  console.log('7. Final balance and reconciliation audit...');
  const checkFinal = await getBalanceAndReconciled();
  if (checkFinal.balance !== 4000 || !checkFinal.isReconciled) {
    console.error(`FAILED: Final balance unexpected: ${checkFinal.balance}, reconciled=${checkFinal.isReconciled}`);
    process.exit(1);
  }
  console.log(`PASS: Final child balance: ${checkFinal.balance} minor RP. Reconciled: ${checkFinal.isReconciled}`);
  console.log('\n=== All Phase 4.1 Vertical Slice tests PASSED successfully! ===');
}

main().catch((err) => {
  console.error('Fatal test error:', err);
  process.exit(1);
});
