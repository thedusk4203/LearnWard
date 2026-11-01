// scripts/test_growth_concurrency.mjs
/**
 * LearnWard - Growth Engine and Ledger Concurrency Regression Test
 *
 * PURPOSE:
 * Verifies that concurrent calls to process_verified_learning_event on the same
 * VerifiedLearningEvent across multiple database connections are serialized via
 * row locking (FOR UPDATE) and idempotency checks, guaranteeing that:
 * - Exactly ONE growth_event calculation record is created
 * - Exactly ONE XP ledger entry is appended
 * - Exactly ONE RP ledger entry is appended
 * - child_balances projection reflects exactly ONE award without duplicate credit
 */

import { spawn } from 'node:child_process';

const FAMILY_ID = 'f3000000-0000-4000-c000-000000000001';
const OWNER_ID = 'a3000000-0000-4000-c000-000000000001';
const CHILD_ID = 'c3000000-0000-4000-c000-000000000001';
const CMD_CREATE = '83000000-0000-4000-c000-000000000001';
const CMD_SUBMIT = '83000000-0000-4000-c000-000000000002';
const CMD_VERIFY = '83000000-0000-4000-c000-000000000003';
const CMD_1 = '93000000-0000-4000-c000-000000000001';
const CMD_2 = '93000000-0000-4000-c000-000000000002';

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
  console.log('=== LearnWard Concurrency Test: Growth Engine & Ledger Serialization ===');
  console.log('Setting up fixture: Family, Child, and creating verified assessment via RPC...');

  const setupSql = `
    insert into auth.users (id, email) values ('${OWNER_ID}', 'growth_concurrency_parent@example.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_ID}', 'Growth Concurrency Family', 'UTC', 'en-US', '${OWNER_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_ID}', '${FAMILY_ID}', 'Growth Test Child', 5, 2015)
    on conflict (id) do nothing;

    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    drop table if exists tmp_assessment;
    create temporary table tmp_assessment as
    select * from public.create_assessment_draft(
      '${CMD_CREATE}'::uuid,
      '${FAMILY_ID}'::uuid,
      '${CHILD_ID}'::uuid,
      'math',
      'Mathematics',
      'Weekly Quiz Concurrency',
      'quiz',
      'hard',
      7.5,
      10.0,
      now(),
      'adult'
    );

    -- Submit draft
    select public.submit_assessment(
      (select id from tmp_assessment),
      1,
      '${CMD_SUBMIT}'::uuid
    );

    -- Verify assessment
    select public.verify_assessment(
      (select id from tmp_assessment),
      2,
      '${CMD_VERIFY}'::uuid,
      'Verified for concurrency testing'
    );

    -- Output verified_learning_events id
    select 'VLE_ID:' || id as vle_marker from public.verified_learning_events
    where assessment_id = (select id from tmp_assessment);
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr || setupRes.stdout);
    process.exit(1);
  }

  const vleMatch = setupRes.stdout.match(/VLE_ID:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/);
  if (!vleMatch) {
    console.error('Failed to parse verified_learning_event ID from setup output:', setupRes.stdout);
    process.exit(1);
  }

  const verifiedEventId = vleMatch[1];
  console.log('Fixture established: VerifiedLearningEvent', verifiedEventId, 'is ready for concurrent processing.');

  // Session 1: Call process_verified_learning_event with CMD_1 and small simulated delay inside transaction
  const session1Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_sleep(0.05);
    select public.process_verified_learning_event('${verifiedEventId}'::uuid, '${CMD_1}'::uuid);
    commit;
  `;

  // Session 2: Call process_verified_learning_event concurrently with CMD_2
  const session2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select public.process_verified_learning_event('${verifiedEventId}'::uuid, '${CMD_2}'::uuid);
    commit;
  `;

  console.log('Launching Session 1 and Session 2 concurrently...');
  const [res1, res2] = await Promise.all([
    runPsql(session1Sql),
    runPsql(session2Sql),
  ]);

  console.log('Session 1 result code:', res1.code, res1.stdout, res1.stderr);
  console.log('Session 2 result code:', res2.code, res2.stdout, res2.stderr);

  // Verification queries
  const verifySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      (select count(*) from public.growth_events where verified_learning_event_id = '${verifiedEventId}') as growth_event_count,
      (select count(*) from public.xp_ledger where family_id = '${FAMILY_ID}') as xp_ledger_count,
      (select count(*) from public.rp_ledger where family_id = '${FAMILY_ID}') as rp_ledger_count,
      (select xp_total from public.child_balances where child_id = '${CHILD_ID}') as xp_total,
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as rp_balance_minor,
      r.is_reconciled
    from public.reconcile_child_balance('${CHILD_ID}') r;
  `;

  const verifyRes = await runPsql(verifySql);
  console.log('\n--- Final Database Verification ---');
  console.log('stdout:', verifyRes.stdout.trim());
  if (verifyRes.stderr) console.error('stderr:', verifyRes.stderr.trim());

  // Parse counts
  const growthEventMatch = verifyRes.stdout.match(/(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(t|f)/);
  if (!growthEventMatch) {
    console.error('FAILED: Unable to parse query output.');
    process.exit(1);
  }

  const [, growthEvents, xpEntries, rpEntries, xpTotal, rpBalanceMinor, isReconciled] = growthEventMatch;

  let passed = true;

  if (parseInt(growthEvents, 10) !== 1) {
    console.error(`FAILED: Expected exactly 1 growth_events row, found: ${growthEvents}`);
    passed = false;
  } else {
    console.log('PASS: Exactly 1 growth_event record exists.');
  }

  if (parseInt(xpEntries, 10) !== 1) {
    console.error(`FAILED: Expected exactly 1 xp_ledger entry, found: ${xpEntries}`);
    passed = false;
  } else {
    console.log('PASS: Exactly 1 xp_ledger entry exists.');
  }

  if (parseInt(rpEntries, 10) !== 1) {
    console.error(`FAILED: Expected exactly 1 rp_ledger entry, found: ${rpEntries}`);
    passed = false;
  } else {
    console.log('PASS: Exactly 1 rp_ledger entry exists.');
  }

  if (parseInt(xpTotal, 10) !== 27) {
    console.error(`FAILED: Expected child_balances xp_total to be 27, found: ${xpTotal}`);
    passed = false;
  } else {
    console.log('PASS: Balance reflects exactly one award (xp_total = 27).');
  }

  if (parseInt(rpBalanceMinor, 10) !== 850) {
    console.error(`FAILED: Expected child_balances rp_balance_minor to be 850, found: ${rpBalanceMinor}`);
    passed = false;
  } else {
    console.log('PASS: Balance reflects exactly one award (rp_balance_minor = 850).');
  }

  if (isReconciled !== 't') {
    console.error(`FAILED: Expected is_reconciled to be true, found: ${isReconciled}`);
    passed = false;
  } else {
    console.log('PASS: Child balances strictly reconcile with sum of ledgers.');
  }

  if (!passed) {
    console.error('\n*** TEST FAILED: Race condition or double-credit detected! ***');
    process.exit(1);
  }

  console.log('\n*** ALL CONCURRENCY CHECKS PASSED: Exactly-once invariant preserved under concurrent load ***');
  process.exit(0);
}

main().catch((err) => {
  console.error('Unhandled test failure:', err);
  process.exit(1);
});
