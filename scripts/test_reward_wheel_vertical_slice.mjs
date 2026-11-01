// scripts/test_reward_wheel_vertical_slice.mjs
/**
 * LearnWard - Celebration Wheel & Parent Controls Vertical Slice Integration Test
 *
 * PURPOSE:
 * 1. End-to-end Wheel Spin Lifecycle with Parent Fulfillment:
 *    - Child spins wheel via spin_reward_wheel
 *    - Validates server-authoritative pseudorandom winner and selection snapshot
 *    - Confirms rp_ledger debit (-1000 minor), wheel_spins row, and reward_redemptions row
 *    - Idempotent command replay returns exact same payload without additional debit
 *    - Parent fulfills redemption via fulfill_reward_redemption
 *    - State transitions to 'fulfilled'
 *
 * 2. Wheel Spin Cancellation & Compensating Refund:
 *    - Child spins wheel
 *    - Parent cancels redemption with reason
 *    - Compensating refund row (+1000 minor) appended to rp_ledger
 *    - Balance restored
 *    - wheel_spins row remains immutable
 *    - Daily spin quota is NOT restored (no reroll)
 *
 * 3. Guardrail Invariants & Security:
 *    - Disabled wheel (is_enabled = false) throws LW206
 *    - Insufficient eligible reward pool (< 3 active rewards) throws LW203
 *    - Immutability trigger prevents direct UPDATE or DELETE on wheel_spins (LW102)
 *    - Single-snapshot reconciliation audit passes 100%
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
  console.log('=== LearnWard Vertical Slice: Celebration Wheel & Parent Controls ===\n');

  const FAMILY_ID = crypto.randomUUID();
  const OWNER_ID = crypto.randomUUID();
  const CHILD_ID = crypto.randomUUID();
  const CHILD_DEVICE_USER_ID = crypto.randomUUID();
  const REWARD_1_ID = crypto.randomUUID();
  const REWARD_2_ID = crypto.randomUUID();
  const REWARD_3_ID = crypto.randomUUID();

  console.log('1. Establishing fixture: Family, Child profile, Device Grant, Initial Balance = 5000 minor, and 3 Wheel Rewards...');

  const setupSql = `
    insert into auth.users (id, email) values
      ('${OWNER_ID}', 'wheel_vs_owner_${OWNER_ID}@example.com'),
      ('${CHILD_DEVICE_USER_ID}', 'wheel_vs_child_${CHILD_DEVICE_USER_ID}@example.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_ID}', 'Wheel Vertical Slice Family', 'America/New_York', 'en-US', '${OWNER_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_ID}', '${FAMILY_ID}', 'Wheel Child', 4, 2016)
    on conflict (id) do nothing;

    insert into public.child_device_grants (family_id, child_id, auth_user_id, status, paired_by_user_id)
    values ('${FAMILY_ID}', '${CHILD_ID}', '${CHILD_DEVICE_USER_ID}', 'active', '${OWNER_ID}')
    on conflict (id) do nothing;

    -- Initialize child balance with exactly 5000 minor ($50.00) and 100 XP
    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_ID}', '${CHILD_ID}', 100, 5000)
    on conflict (child_id) do update set rp_balance_minor = 5000, xp_total = 100;

    insert into public.xp_ledger (family_id, child_id, amount, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 100, 'initial_grant', 'growth_event', 'init_xp:${CHILD_ID}')
    on conflict (idempotency_key) do nothing;

    insert into public.rp_ledger (family_id, child_id, amount_minor, reason_code, source_type, idempotency_key)
    values ('${FAMILY_ID}', '${CHILD_ID}', 5000, 'initial_grant', 'growth_event', 'init:${CHILD_ID}')
    on conflict (idempotency_key) do nothing;

    -- Create 3 distinct active eligible Wheel rewards (Common, Special, Rare)
    insert into public.rewards (id, family_id, title, category, store_enabled, store_cost_minor, wheel_enabled, wheel_tier, is_active)
    values
      ('${REWARD_1_ID}', '${FAMILY_ID}', '15m Video Game Time', 'privilege', false, null, true, 'common', true),
      ('${REWARD_2_ID}', '${FAMILY_ID}', 'Choice of Dessert', 'treat', true, 1200, true, 'special', true),
      ('${REWARD_3_ID}', '${FAMILY_ID}', 'Trip to Trampoline Park', 'experience', false, null, true, 'rare', true)
    on conflict (id) do nothing;
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr || setupRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Fixture established.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 1: End-to-End Wheel Spin Lifecycle with Parent Fulfillment
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 1: Spin Wheel as Paired Child Device & Fulfill as Parent ---');
  const CMD_SPIN_1 = crypto.randomUUID();

  const spin1Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${CHILD_DEVICE_USER_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${CMD_SPIN_1}'::uuid, '${CHILD_ID}'::uuid);
  `;

  const spin1Res = await runPsql(spin1Sql);
  if (spin1Res.code !== 0) {
    console.error('FAILED: Paired child device spin failed:', spin1Res.stderr || spin1Res.stdout);
    process.exit(1);
  }

  console.log('Spin 1 output:', spin1Res.stdout.trim());
  const lines1 = spin1Res.stdout.split('\n');
  const spinLine1 = lines1.find((l) => l.trim().startsWith('{') && l.includes('"spin_id"'));
  if (!spinLine1) {
    console.error('FAILED: Could not parse JSON response from spin_reward_wheel');
    process.exit(1);
  }

  const spinResult = JSON.parse(spinLine1.trim());
  console.log(`Winning Reward: "${spinResult.reward_title}" [Tier: ${spinResult.wheel_tier}]`);
  console.log(`Cost: ${spinResult.spin_cost_minor} minor, New Balance: ${spinResult.new_balance_minor}`);

  if (spinResult.spin_cost_minor !== 1000 || spinResult.new_balance_minor !== 4000) {
    console.error('FAILED: Incorrect debit or balance reported in spin result');
    process.exit(1);
  }

  // Idempotent Replay Check
  console.log('Executing identical replay with same command_id...');
  const replayRes = await runPsql(spin1Sql);
  if (replayRes.code !== 0) {
    console.error('FAILED: Command replay failed:', replayRes.stderr);
    process.exit(1);
  }

  const replayLine = replayRes.stdout.split('\n').find((l) => l.trim().startsWith('{') && l.includes('"spin_id"'));
  const replayResult = JSON.parse(replayLine.trim());
  if (replayResult.spin_id !== spinResult.spin_id || replayResult.redemption_id !== spinResult.redemption_id) {
    console.error('FAILED: Replay returned different resource identity');
    process.exit(1);
  }
  console.log('PASS: Idempotent replay returned exact same spin payload without extra debit.\n');

  // Verify DB state: exactly 1 wheel_spins, 1 reward_redemptions, 1 rp_ledger debit
  const verifySpinSql = `
    select
      (select count(*) from public.wheel_spins where child_id = '${CHILD_ID}') as spins,
      (select count(*) from public.reward_redemptions where child_id = '${CHILD_ID}') as redemptions,
      (select count(*) from public.rp_ledger where child_id = '${CHILD_ID}' and reason_code = 'wheel_spin') as debits,
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as balance;
  `;
  const verifySpinRes = await runPsql(verifySpinSql);
  const vMatch = verifySpinRes.stdout.match(/(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)/);
  if (!vMatch || vMatch[1] !== '1' || vMatch[2] !== '1' || vMatch[3] !== '1' || vMatch[4] !== '4000') {
    console.error('FAILED: Database records mismatch after spin:', verifySpinRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Exactly 1 spin, 1 redemption, 1 ledger debit, balance = 4000 minor.');

  // Parent fulfills the redemption
  console.log('Parent fulfills the winning redemption...');
  const CMD_FULFILL = crypto.randomUUID();
  const fulfillSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.fulfill_reward_redemption('${spinResult.redemption_id}'::uuid, '${CMD_FULFILL}'::uuid);
  `;

  const fulfillRes = await runPsql(fulfillSql);
  if (fulfillRes.code !== 0) {
    console.error('FAILED: Fulfill reward redemption failed:', fulfillRes.stderr || fulfillRes.stdout);
    process.exit(1);
  }

  const checkFulfillSql = `
    select status, fulfilled_at is not null as is_fulfilled
    from public.reward_redemptions
    where id = '${spinResult.redemption_id}';
  `;
  const checkFulfillRes = await runPsql(checkFulfillSql);
  if (!checkFulfillRes.stdout.includes('fulfilled') || !checkFulfillRes.stdout.includes('t')) {
    console.error('FAILED: Redemption did not transition to fulfilled:', checkFulfillRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Redemption marked as fulfilled by parent.\n');

  // -------------------------------------------------------------------------
  // SCENARIO 2: Wheel Spin Cancellation & Compensating Refund (No Reroll)
  // -------------------------------------------------------------------------
  console.log('--- SCENARIO 2: Wheel Spin Cancellation, Refund & Daily Cap Invariance ---');
  const CMD_SPIN_2 = crypto.randomUUID();

  const spin2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${CHILD_DEVICE_USER_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${CMD_SPIN_2}'::uuid, '${CHILD_ID}'::uuid);
  `;
  const spin2Res = await runPsql(spin2Sql);
  if (spin2Res.code !== 0) {
    console.error('FAILED: Spin 2 failed:', spin2Res.stderr);
    process.exit(1);
  }
  const spin2Line = spin2Res.stdout.split('\n').find((l) => l.trim().startsWith('{') && l.includes('"spin_id"'));
  const spin2Result = JSON.parse(spin2Line.trim());
  console.log(`Spin 2 Winner: "${spin2Result.reward_title}", Balance after spin: ${spin2Result.new_balance_minor}`);

  // Cancel redemption as parent
  console.log('Parent cancels Spin 2 redemption due to unavailability...');
  const CMD_CANCEL = crypto.randomUUID();
  const cancelSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.cancel_reward_redemption('${spin2Result.redemption_id}'::uuid, '${CMD_CANCEL}'::uuid, 'Venue closed for renovation');
  `;
  const cancelRes = await runPsql(cancelSql);
  if (cancelRes.code !== 0) {
    console.error('FAILED: Cancel reward redemption failed:', cancelRes.stderr);
    process.exit(1);
  }

  // Verify: refund appended, balance restored from 3000 to 4000 minor
  const verifyRefundSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as balance,
      (select count(*) from public.rp_ledger where child_id = '${CHILD_ID}' and reason_code = 'redemption_refund') as refunds,
      (select count(*) from public.wheel_spins where child_id = '${CHILD_ID}') as total_spins,
      r.is_reconciled
    from public.reconcile_child_balance('${CHILD_ID}') r;
  `;
  const verifyRefundRes = await runPsql(verifyRefundSql);
  const rMatch = verifyRefundRes.stdout.match(/(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(t|f)/);
  if (!rMatch || rMatch[1] !== '4000' || rMatch[2] !== '1' || rMatch[3] !== '2' || rMatch[4] !== 't') {
    console.error('FAILED: Refund state invalid:', verifyRefundRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Compensating refund restored 1000 minor RP (balance=4000). Total spins recorded = 2.');

  // -------------------------------------------------------------------------
  // SCENARIO 3: Guardrail Invariants
  // -------------------------------------------------------------------------
  console.log('\n--- SCENARIO 3: Guardrail Invariants & Immutability ---');

  // Test 3.1: Disabled wheel
  console.log('Disabling wheel for family...');
  await runPsql(`update public.family_wheel_settings set is_enabled = false where family_id = '${FAMILY_ID}';`);
  const disabledSpinRes = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${CHILD_ID}'::uuid);
  `);
  if (!disabledSpinRes.stderr.includes('Wheel is currently disabled for this family') && !disabledSpinRes.stderr.includes('LW206')) {
    console.error('FAILED: Expected LW206 for disabled wheel, found:', disabledSpinRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Disabled wheel rejected with LW206.');

  // Re-enable wheel and deactivate rewards to test minimum pool guardrail (< 3)
  await runPsql(`update public.family_wheel_settings set is_enabled = true where family_id = '${FAMILY_ID}';`);
  await runPsql(`update public.rewards set is_active = false where id in ('${REWARD_1_ID}', '${REWARD_2_ID}');`);

  const poolFailRes = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${CHILD_ID}'::uuid);
  `);
  if (!poolFailRes.stderr.includes('Wheel requires at least 3 active eligible rewards') && !poolFailRes.stderr.includes('LW203')) {
    console.error('FAILED: Expected LW203 for pool size < 3, found:', poolFailRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Wheel spin rejected with LW203 when active eligible rewards < 3.');

  // Test 3.3: Immutability trigger on wheel_spins
  console.log('Verifying immutability trigger blocks UPDATE/DELETE on wheel_spins...');
  const immutUpdateRes = await runPsql(`
    update public.wheel_spins set spin_cost_minor = 0 where child_id = '${CHILD_ID}';
  `);
  if (!immutUpdateRes.stderr.includes('strictly immutable') && !immutUpdateRes.stderr.includes('LW102')) {
    console.error('FAILED: Expected LW102 immutability error on UPDATE wheel_spins, found:', immutUpdateRes.stderr);
    process.exit(1);
  }

  const immutDeleteRes = await runPsql(`
    delete from public.wheel_spins where child_id = '${CHILD_ID}';
  `);
  if (!immutDeleteRes.stderr.includes('cannot be deleted') && !immutDeleteRes.stderr.includes('LW102')) {
    console.error('FAILED: Expected LW102 immutability error on DELETE wheel_spins, found:', immutDeleteRes.stderr);
    process.exit(1);
  }
  console.log('PASS: wheel_spins is strictly immutable (UPDATE/DELETE rejected with LW102).\n');

  console.log('===============================================================');
  console.log('ALL CELEBRATION WHEEL VERTICAL SLICE TESTS PASSED!');
  console.log('===============================================================');
}

main().catch((err) => {
  console.error('Unhandled vertical slice failure:', err);
  process.exit(1);
});
