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
  console.log('=== LearnWard Concurrency Test: Growth Engine & Ledger Serialization ===');
  console.log('Setting up fixture: Family, Child, and creating verified assessment via RPC...');

  const FAMILY_ID = crypto.randomUUID();
  const OWNER_ID = crypto.randomUUID();
  const CHILD_ID = crypto.randomUUID();
  const CMD_CREATE = crypto.randomUUID();
  const CMD_SUBMIT = crypto.randomUUID();
  const CMD_VERIFY = crypto.randomUUID();
  const CMD_1 = crypto.randomUUID();
  const CMD_2 = crypto.randomUUID();

  const setupSql = `
    insert into auth.users (id, email) values ('${OWNER_ID}', 'growth_concurrency_${OWNER_ID}@example.com')
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

  console.log('\n--- Part 2: Single-Snapshot Reconciliation Concurrency Invariant ---');
  console.log('Testing that concurrent Growth commits cannot cause reconcile_child_balance to report false drift...');

  // Setup a second verified assessment through trusted RPCs
  const CMD_CREATE_2 = crypto.randomUUID();
  const CMD_SUBMIT_2 = crypto.randomUUID();
  const CMD_VERIFY_2 = crypto.randomUUID();
  const CMD_GROWTH_2 = crypto.randomUUID();

  const setup2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    -- 1. Create assessment draft 2
    create temp table tmp_assessment_2 as
    select * from public.create_assessment_draft(
      '${CMD_CREATE_2}'::uuid,
      '${FAMILY_ID}'::uuid,
      '${CHILD_ID}'::uuid,
      'math',
      'Mathematics',
      'Weekly Test 2 Concurrency',
      'quiz',
      'normal',
      8.0,
      10.0,
      now(),
      'adult'
    );

    -- 2. Submit assessment 2
    select public.submit_assessment(
      (select id from tmp_assessment_2),
      1,
      '${CMD_SUBMIT_2}'::uuid
    );

    -- 3. Verify assessment 2
    select public.verify_assessment(
      (select id from tmp_assessment_2),
      2,
      '${CMD_VERIFY_2}'::uuid,
      'Approved assessment 2'
    );

    -- 4. Query/extract real VerifiedLearningEvent ID
    select 'VLE2_ID:' || id as vle_marker from public.verified_learning_events
    where assessment_id = (select id from tmp_assessment_2);
  `;

  const setup2Res = await runPsql(setup2Sql);
  // 5. Assert fixture setup result code == 0
  if (setup2Res.code !== 0) {
    console.error('FAILED: Fixture setup 2 failed:', setup2Res.stderr || setup2Res.stdout);
    process.exit(1);
  }

  // 6. Assert VLE ID was extracted
  const vle2Match = setup2Res.stdout.match(/VLE2_ID:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/);
  if (!vle2Match) {
    console.error('FAILED: Failed to parse VerifiedLearningEvent ID 2 from setup output:', setup2Res.stdout);
    process.exit(1);
  }

  const realVle2Id = vle2Match[1];
  console.log('PASS: Fixture 2 established with REAL VerifiedLearningEvent ID:', realVle2Id);

  // 7. Reconciliation loop: polls reconcile_child_balance repeatedly across the concurrent mutation
  const reconLoopSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    do $$
    declare
      v_recon record;
      i int;
    begin
      for i in 1..15 loop
        select * into v_recon from public.reconcile_child_balance('${CHILD_ID}') r;
        if not v_recon.is_reconciled then
          raise exception 'False drift detected during concurrent processing: proj_xp=%, ledg_xp=%, proj_rp=%, ledg_rp=%',
            v_recon.projected_xp, v_recon.ledger_xp, v_recon.projected_rp_minor, v_recon.ledger_rp_minor;
        end if;
        perform pg_sleep(0.04);
      end loop;
    end $$;
    select 'RECON_LOOP_SUCCESS';
  `;

  // 8. Mutator: concurrently call process_verified_learning_event with REAL vle_id and command_id
  const mutateSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select pg_sleep(0.1);
    select row_to_json(g.*) as growth_json from public.process_verified_learning_event(
      '${realVle2Id}'::uuid,
      '${CMD_GROWTH_2}'::uuid
    ) g;
  `;

  console.log('Launching reconciliation loop and mutator concurrently...');
  const [reconRes, mutateRes] = await Promise.all([
    runPsql(reconLoopSql),
    runPsql(mutateSql),
  ]);

  // 9. Assert mutator result code == 0
  if (mutateRes.code !== 0) {
    console.error('FAILED: Mutator process_verified_learning_event failed:', mutateRes.stderr || mutateRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Mutator executed successfully (code 0).');

  if (reconRes.code !== 0 || !reconRes.stdout.includes('RECON_LOOP_SUCCESS')) {
    console.error('FAILED: Reconciliation loop observed torn state / false drift:', reconRes.stderr || reconRes.stdout);
    process.exit(1);
  }
  console.log('PASS: Single-snapshot reconciliation observed 0 false drift events during concurrent commit.');

  // Final assertions on the database state
  const finalVerifySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      (select count(*) from public.growth_events where verified_learning_event_id = '${realVle2Id}') as new_ge_count,
      (select count(*) from public.growth_events where family_id = '${FAMILY_ID}') as total_ge_count,
      (select count(*) from public.xp_ledger where source_id = (select id from public.growth_events where verified_learning_event_id = '${realVle2Id}')) as new_xp_count,
      (select count(*) from public.rp_ledger where source_id = (select id from public.growth_events where verified_learning_event_id = '${realVle2Id}')) as new_rp_count,
      (select count(*) from public.xp_ledger where family_id = '${FAMILY_ID}') as total_xp_count,
      (select count(*) from public.rp_ledger where family_id = '${FAMILY_ID}') as total_rp_count,
      (select xp_total from public.child_balances where child_id = '${CHILD_ID}') as xp_total,
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as rp_balance_minor,
      r.is_reconciled
    from public.reconcile_child_balance('${CHILD_ID}') r;
  `;

  const finalRes = await runPsql(finalVerifySql);
  if (finalRes.code !== 0) {
    console.error('FAILED: Final verification query failed:', finalRes.stderr);
    process.exit(1);
  }

  const finalMatch = finalRes.stdout.match(/(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(t|f)/);
  if (!finalMatch) {
    console.error('FAILED: Could not parse final verification output:', finalRes.stdout);
    process.exit(1);
  }

  const [, newGe, totalGe, newXp, newRp, totalXp, totalRp, finalXpTotal, finalRpTotal, finalReconciled] = finalMatch;

  // 10. Assert the new GrowthEvent actually exists
  if (parseInt(newGe, 10) !== 1 || parseInt(totalGe, 10) !== 2) {
    console.error(`FAILED: Expected new_ge=1, total_ge=2; found: new_ge=${newGe}, total_ge=${totalGe}`);
    process.exit(1);
  }
  console.log('PASS: New GrowthEvent exists (total: 2 growth_events).');

  // 11. Assert corresponding XP ledger row exists
  if (parseInt(newXp, 10) !== 1 || parseInt(totalXp, 10) !== 2) {
    console.error(`FAILED: Expected new_xp=1, total_xp=2; found: new_xp=${newXp}, total_xp=${totalXp}`);
    process.exit(1);
  }
  console.log('PASS: New XP ledger row exists (total: 2 xp_ledger rows).');

  // 12. Assert corresponding RP ledger row exists
  if (parseInt(newRp, 10) !== 1 || parseInt(totalRp, 10) !== 2) {
    console.error(`FAILED: Expected new_rp=1, total_rp=2; found: new_rp=${newRp}, total_rp=${totalRp}`);
    process.exit(1);
  }
  console.log('PASS: New RP ledger row exists (total: 2 rp_ledger rows).');

  // 13. Assert final balances include both the original award and the concurrent second award
  // Award 1: xp=27, rp=850. Award 2 (score 8.0 normal with PB bonus 100): rp=900, xp=28.
  // Cumulative: xp=55, rp=1750.
  if (parseInt(finalXpTotal, 10) !== 55 || parseInt(finalRpTotal, 10) !== 1750) {
    console.error(`FAILED: Expected final balances xp=55, rp=1750; found: xp=${finalXpTotal}, rp=${finalRpTotal}`);
    process.exit(1);
  }
  console.log('PASS: Final balances include both original award and concurrent second award (xp=55, rp_minor=1750).');

  // 14. Assert final ledger sums equal projections
  if (finalReconciled !== 't') {
    console.error('FAILED: Final reconcile_child_balance reported is_reconciled=false');
    process.exit(1);
  }
  console.log('PASS: Final ledger sums strictly equal projection (is_reconciled=true).');

  console.log('\n*** ALL CONCURRENCY CHECKS PASSED: Exactly-once invariant and atomic reconciliation preserved ***');
  process.exit(0);
}

main().catch((err) => {
  console.error('Unhandled test failure:', err);
  process.exit(1);
});
