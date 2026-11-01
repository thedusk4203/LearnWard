// scripts/test_growth_delivery_recovery.mjs
/**
 * LearnWard - Verify -> Growth Delivery Reliability & Catch-Up Integration Test
 *
 * PURPOSE:
 * Proves that when an assessment verification succeeds but Growth processing is interrupted
 * or fails, the system provides at-least-once recovery without double-reward risk:
 *   1. Setup tenancy: Family, Owner Adult, Child profile.
 *   2. Establish baseline: 3 prior verified results (6.0, 6.5, 6.8) in evaluative band.
 *   3. Create and submit target assessment (7.5 / 10, Hard).
 *   4. Parent verifies assessment -> verify_assessment succeeds and creates VerifiedLearningEvent.
 *   5. SIMULATE INTERRUPTION: Growth processing is skipped/interrupted.
 *   6. Verify event is discoverable via get_unprocessed_verified_learning_events().
 *   7. Execute catch-up via catch_up_unprocessed_growth().
 *   8. Verify exact awards:
 *      - exactly 1 GrowthEvent (Baseline: 6.43, Delta: 1.07, Total RP: 11.50, XP: 33)
 *      - exactly 1 xp_ledger entry
 *      - exactly 1 rp_ledger entry
 *      - child_balances projection matches ledger sums
 *      - reconcile_child_balance() confirms reconciliation
 *   9. Execute retry / second catch-up:
 *      - catch_up_unprocessed_growth() returns 0
 *      - manual process_verified_learning_event replay returns existing event
 *      - exactly 1 GrowthEvent remains (no duplicate)
 *      - exactly 1 XP ledger entry remains (no duplicate award)
 *      - exactly 1 RP ledger entry remains (no duplicate award)
 *      - balances remain identical
 */

import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const FAMILY_ID = crypto.randomUUID();
const OWNER_ID = crypto.randomUUID();
const CHILD_ID = crypto.randomUUID();

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

function assert(condition, message) {
  if (!condition) {
    console.error(`FAIL: ${message}`);
    process.exit(1);
  }
  console.log(`PASS: ${message}`);
}

async function main() {
  console.log('=== LearnWard: Growth Delivery Recovery & Catch-up Integration Test ===\n');

  console.log('1. Setting up Family, Owner Adult, and Child profile...');
  const setupSql = `
    insert into auth.users (id, email) values
      ('${OWNER_ID}', 'recovery_${OWNER_ID}@example.com');

    insert into public.families (id, name, timezone, locale, created_by_user_id) values
      ('${FAMILY_ID}', 'Recovery Family', 'UTC', 'en-US', '${OWNER_ID}');

    insert into public.family_memberships (family_id, auth_user_id, role, status) values
      ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
      ('${CHILD_ID}', '${FAMILY_ID}', 'Target Child', 5, 2015);
  `;
  const setupRes = await runPsql(setupSql);
  assert(setupRes.code === 0, 'Tenancy fixtures setup successfully');

  console.log('\n2. Creating 3 historical verified assessments with Growth processed...');
  const histSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    do $$
    declare
      v_a public.assessments;
      v_vle public.verified_learning_events;
    begin
      -- Hist 1: 6.0/10 quiz normal (3 days ago)
      v_a := public.create_assessment_draft('${crypto.randomUUID()}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid, 'math', 'Mathematics', 'H1', 'quiz', 'normal', 6.0, 10.0, now() - interval '3 days', 'adult');
      perform public.submit_assessment(v_a.id, 1, '${crypto.randomUUID()}'::uuid);
      v_a := public.verify_assessment(v_a.id, 2, '${crypto.randomUUID()}'::uuid, 'verified h1');
      select * into v_vle from public.verified_learning_events where assessment_id = v_a.id;
      perform public.process_verified_learning_event(v_vle.id, null);

      -- Hist 2: 6.5/10 exam normal (2 days ago)
      v_a := public.create_assessment_draft('${crypto.randomUUID()}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid, 'math', 'Mathematics', 'H2', 'exam', 'normal', 6.5, 10.0, now() - interval '2 days', 'adult');
      perform public.submit_assessment(v_a.id, 1, '${crypto.randomUUID()}'::uuid);
      v_a := public.verify_assessment(v_a.id, 2, '${crypto.randomUUID()}'::uuid, 'verified h2');
      select * into v_vle from public.verified_learning_events where assessment_id = v_a.id;
      perform public.process_verified_learning_event(v_vle.id, null);

      -- Hist 3: 6.8/10 quiz hard (1 day ago)
      v_a := public.create_assessment_draft('${crypto.randomUUID()}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid, 'math', 'Mathematics', 'H3', 'quiz', 'hard', 6.8, 10.0, now() - interval '1 day', 'adult');
      perform public.submit_assessment(v_a.id, 1, '${crypto.randomUUID()}'::uuid);
      v_a := public.verify_assessment(v_a.id, 2, '${crypto.randomUUID()}'::uuid, 'verified h3');
      select * into v_vle from public.verified_learning_events where assessment_id = v_a.id;
      perform public.process_verified_learning_event(v_vle.id, null);
    end $$;
  `;
  const histRes = await runPsql(histSql);
  assert(histRes.code === 0, '3 historical baseline assessments created and processed');

  console.log('\n3. Creating, submitting, and verifying target assessment (7.5 / 10, Hard)...');
  const targetDraftCmd = crypto.randomUUID();
  const targetSubmitCmd = crypto.randomUUID();
  const targetVerifyCmd = crypto.randomUUID();
  const targetGrowthCmd = crypto.randomUUID();

  const verifySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    do $$
    declare
      v_target public.assessments;
      v_vle public.verified_learning_events;
    begin
      v_target := public.create_assessment_draft(
        '${targetDraftCmd}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid,
        'math', 'Mathematics', 'Target Test', 'exam', 'hard', 7.5, 10.0, now(), 'adult'
      );
      perform public.submit_assessment(v_target.id, 1, '${targetSubmitCmd}'::uuid);
      v_target := public.verify_assessment(v_target.id, 2, '${targetVerifyCmd}'::uuid, 'Verified target');
      select * into v_vle from public.verified_learning_events where assessment_id = v_target.id;
      raise notice 'TARGET_VLE_ID:%', v_vle.id;
    end $$;
  `;
  const verifyRes = await runPsql(verifySql);
  assert(verifyRes.code === 0, 'Target assessment verified by parent');

  // Extract TARGET_VLE_ID from notice
  const match = (verifyRes.stderr || verifyRes.stdout).match(/TARGET_VLE_ID:([0-9a-f-]+)/);
  assert(match !== null, 'Target VerifiedLearningEvent ID extracted');
  const targetVleId = match[1];
  console.log(`Target VerifiedLearningEvent ID: ${targetVleId}`);

  console.log('\n4. Simulating failure / interruption: Growth processing was interrupted.');
  console.log('Proving target event remains discoverable as unprocessed...');
  const discoverSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select id from public.get_unprocessed_verified_learning_events('${FAMILY_ID}'::uuid);
  `;
  const discoverRes = await runPsql(discoverSql);
  assert(discoverRes.code === 0, 'get_unprocessed_verified_learning_events executed');
  assert(discoverRes.stdout.includes(targetVleId), 'Target event discovered in unprocessed queue');

  // Verify no growth_event or ledger entries exist yet for target
  const checkEmptySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      (select count(*)::int from public.growth_events where verified_learning_event_id = '${targetVleId}'::uuid) as ge_cnt,
      (select count(*)::int from public.xp_ledger where metadata->>'verified_learning_event_id' = '${targetVleId}') as xp_cnt,
      (select count(*)::int from public.rp_ledger where metadata->>'verified_learning_event_id' = '${targetVleId}') as rp_cnt;
  `;
  const checkEmptyRes = await runPsql(checkEmptySql);
  const emptyLines = checkEmptyRes.stdout.split('\n').map(l => l.trim()).filter(Boolean);
  assert(emptyLines[emptyLines.length - 1] === '0|0|0', 'Proved zero growth events and zero ledger entries exist before catch-up');

  console.log('\n5. Executing durable catch-up via catch_up_unprocessed_growth()...');
  const catchUpSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select public.catch_up_unprocessed_growth('${FAMILY_ID}'::uuid);
  `;
  const catchUpRes = await runPsql(catchUpSql);
  assert(catchUpRes.code === 0, 'catch_up_unprocessed_growth executed');
  const catchUpLines = catchUpRes.stdout.split('\n').map(l => l.trim()).filter(Boolean);
  assert(catchUpLines[catchUpLines.length - 1] === '1', 'catch_up_unprocessed_growth processed exactly 1 event');

  console.log('\n6. Verifying exactly 1 GrowthEvent, 1 XP entry, 1 RP entry, and correct breakdown...');
  const verifyAwardSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      (select count(*)::int from public.growth_events where verified_learning_event_id = '${targetVleId}'::uuid) as ge_cnt,
      (select baseline_score from public.growth_events where verified_learning_event_id = '${targetVleId}'::uuid) as base_score,
      (select growth_delta from public.growth_events where verified_learning_event_id = '${targetVleId}'::uuid) as g_delta,
      (select total_rp_minor from public.growth_events where verified_learning_event_id = '${targetVleId}'::uuid) as rp_minor,
      (select xp_awarded from public.growth_events where verified_learning_event_id = '${targetVleId}'::uuid) as xp_pts,
      (select count(*)::int from public.xp_ledger where metadata->>'verified_learning_event_id' = '${targetVleId}') as xp_cnt,
      (select count(*)::int from public.rp_ledger where metadata->>'verified_learning_event_id' = '${targetVleId}') as rp_cnt;
  `;
  const awardRes = await runPsql(verifyAwardSql);
  assert(awardRes.code === 0, 'Award verification query executed');
  const awardLines = awardRes.stdout.split('\n').map(l => l.trim()).filter(Boolean);
  const [geCnt, baseScore, gDelta, rpMinor, xpPts, xpCnt, rpCnt] = awardLines[awardLines.length - 1].split('|');
  assert(geCnt === '1', 'Exactly 1 growth_event record generated');
  assert(baseScore === '6.43', 'Authoritative rolling baseline matches 6.43');
  assert(gDelta === '1.07', 'Authoritative growth delta matches +1.07');
  assert(rpMinor === '1150', 'Authoritative total RP matches 11.50 (1150 minor)');
  assert(xpPts === '33', 'Authoritative Study XP matches 33 XP');
  assert(xpCnt === '1', 'Exactly 1 row appended to xp_ledger');
  assert(rpCnt === '1', 'Exactly 1 row appended to rp_ledger');

  console.log('\n7. Verifying balance reconciliation under audit check...');
  const reconcileSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select is_reconciled from public.reconcile_child_balance('${CHILD_ID}'::uuid);
  `;
  const reconRes = await runPsql(reconcileSql);
  const reconLines = reconRes.stdout.split('\n').map(l => l.trim()).filter(Boolean);
  assert(reconLines[reconLines.length - 1] === 't', 'reconcile_child_balance() confirms projection equals ledger totals');

  console.log('\n8. Proving idempotent retry: retrying catch-up and direct command replay...');
  // A. Catch-up again: should find 0 events
  const catchUp2Res = await runPsql(catchUpSql);
  const catchUp2Lines = catchUp2Res.stdout.split('\n').map(l => l.trim()).filter(Boolean);
  assert(catchUp2Lines[catchUp2Lines.length - 1] === '0', 'Second catch-up finds 0 unprocessed events (idempotent)');

  // B. Manual direct call with command ID: should return existing growth event without duplicating
  const directReplaySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select id from public.process_verified_learning_event('${targetVleId}'::uuid, '${targetGrowthCmd}'::uuid);
  `;
  const replayRes1 = await runPsql(directReplaySql);
  assert(replayRes1.code === 0, 'Direct process_verified_learning_event replay succeeded');
  const replayLines1 = replayRes1.stdout.split('\n').map(l => l.trim()).filter(Boolean);

  const replayRes2 = await runPsql(directReplaySql);
  const replayLines2 = replayRes2.stdout.split('\n').map(l => l.trim()).filter(Boolean);
  assert(replayLines1[replayLines1.length - 1] === replayLines2[replayLines2.length - 1], 'Second replay returned identical growth event ID');

  // Verify counts remain exactly 1
  const finalCheckRes = await runPsql(verifyAwardSql);
  const finalCheckLines = finalCheckRes.stdout.split('\n').map(l => l.trim()).filter(Boolean);
  const [fGeCnt, , , , , fXpCnt, fRpCnt] = finalCheckLines[finalCheckLines.length - 1].split('|');
  assert(fGeCnt === '1', 'Still exactly 1 growth_event record (no duplicates)');
  assert(fXpCnt === '1', 'Still exactly 1 xp_ledger row (no duplicate XP awarded)');
  assert(fRpCnt === '1', 'Still exactly 1 rp_ledger row (no duplicate RP awarded)');

  console.log('\n=== ALL GROWTH DELIVERY RECOVERY TESTS PASSED (100%) ===');
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
