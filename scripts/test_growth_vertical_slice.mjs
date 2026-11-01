// scripts/test_growth_vertical_slice.mjs
/**
 * LearnWard - Growth Engine & XP/RP Ledger Vertical Slice Integration Test
 *
 * PURPOSE:
 * Exercises the complete end-to-end integration against real local Supabase:
 *   1. Historical assessment ingestion: 3 prior verified assessments (6.0, 6.5, 6.8).
 *   2. Target assessment: Score 7.5/10, Difficulty 'hard'.
 *   3. Parent verification -> VerifiedLearningEvent.
 *   4. process_verified_learning_event RPC execution:
 *      - Rolling baseline: (6.0 + 6.5 + 6.8) / 3 = 6.43
 *      - Improvement delta: 7.50 - 6.43 = +1.07
 *      - Score RP: +7.50 (750 minor)
 *      - Growth Bonus: +2.00 (200 minor)
 *      - Personal Best: +1.00 (100 minor)
 *      - Hard Challenge: +1.00 (100 minor)
 *      - Total RP: +11.50 (1150 minor)
 *      - Study XP: +33 XP (10 + 2 * 11.50)
 *   5. Authoritative Ledgers (xp_ledger, rp_ledger) and child_balances projection verification.
 *   6. Idempotent Retry: Retrying the command produces zero duplicate ledger entries or balance drift.
 *   7. Below-level Anti-Farming: Verifies 25% base RP reduction, zero bonuses, and legitimate Study XP.
 *   8. Deterministic balance reconciliation check.
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

async function main() {
  console.log('=== LearnWard Phase 3: Growth Engine & XP/RP Ledger Vertical Slice ===');
  console.log('1. Setting up Family, Owner, and Child profiles...');

  const setupSql = `
    insert into auth.users (id, email) values
      ('${OWNER_ID}', 'growth_slice_${OWNER_ID}@example.com');

    insert into public.families (id, name, timezone, locale, created_by_user_id) values
      ('${FAMILY_ID}', 'Growth Slice Family', 'UTC', 'en-US', '${OWNER_ID}');

    insert into public.family_memberships (family_id, auth_user_id, role, status) values
      ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
      ('${CHILD_ID}', '${FAMILY_ID}', 'Learner Child', 5, 2015);
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Setup failed:', setupRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Tenancy established.');

  console.log('\n2. Creating 3 historical verified assessments to establish rolling baseline (6.0, 6.5, 6.8)...');
  const historySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    -- Historical 1: 6.0/10 (3 days ago)
    do $$
    declare
      v_a public.assessments;
    begin
      v_a := public.create_assessment_draft(
        '${crypto.randomUUID()}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid,
        'math', 'Mathematics', 'Hist 1', 'quiz', 'normal', 6.0, 10.0, now() - interval '3 days', 'adult'
      );
      perform public.submit_assessment(v_a.id, 1, '${crypto.randomUUID()}'::uuid);
      perform public.verify_assessment(v_a.id, 2, '${crypto.randomUUID()}'::uuid, 'hist 1 verified');
    end $$;

    -- Historical 2: 6.5/10 (2 days ago)
    do $$
    declare
      v_a public.assessments;
    begin
      v_a := public.create_assessment_draft(
        '${crypto.randomUUID()}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid,
        'math', 'Mathematics', 'Hist 2', 'quiz', 'normal', 6.5, 10.0, now() - interval '2 days', 'adult'
      );
      perform public.submit_assessment(v_a.id, 1, '${crypto.randomUUID()}'::uuid);
      perform public.verify_assessment(v_a.id, 2, '${crypto.randomUUID()}'::uuid, 'hist 2 verified');
    end $$;

    -- Historical 3: 6.8/10 (1 day ago)
    do $$
    declare
      v_a public.assessments;
    begin
      v_a := public.create_assessment_draft(
        '${crypto.randomUUID()}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid,
        'math', 'Mathematics', 'Hist 3', 'quiz', 'normal', 6.8, 10.0, now() - interval '1 day', 'adult'
      );
      perform public.submit_assessment(v_a.id, 1, '${crypto.randomUUID()}'::uuid);
      perform public.verify_assessment(v_a.id, 2, '${crypto.randomUUID()}'::uuid, 'hist 3 verified');
    end $$;
  `;

  const historyRes = await runPsql(historySql);
  if (historyRes.code !== 0) {
    console.error('History setup failed:', historyRes.stderr);
    process.exit(1);
  }
  console.log('PASS: 3 historical verified assessments established.');

  console.log('\n3. Creating and verifying target assessment (Score: 7.5/10, Difficulty: Hard)...');
  const targetAssessmentId = crypto.randomUUID();
  const targetCommandId = crypto.randomUUID();

  const targetSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    drop table if exists target_assessment;
    create temporary table target_assessment as
    select * from public.create_assessment_draft(
      '${crypto.randomUUID()}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid,
      'math', 'Mathematics', 'Target Test', 'practice', 'hard', 15.0, 20.0, now(), 'adult'
    );

    select public.submit_assessment((select id from target_assessment), 1, '${crypto.randomUUID()}'::uuid);
    select public.verify_assessment((select id from target_assessment), 2, '${crypto.randomUUID()}'::uuid, 'Approved');

    select 'VLE_TARGET:' || id as vle_marker from public.verified_learning_events where assessment_id = (select id from target_assessment);
  `;

  const targetRes = await runPsql(targetSql);
  if (targetRes.code !== 0) {
    console.error('Target assessment creation failed:', targetRes.stderr);
    process.exit(1);
  }

  const targetVleMatch = targetRes.stdout.match(/VLE_TARGET:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/);
  if (!targetVleMatch) {
    console.error('Unable to parse target VLE ID:', targetRes.stdout);
    process.exit(1);
  }
  const targetVleId = targetVleMatch[1];
  console.log(`PASS: Target VerifiedLearningEvent created: ${targetVleId}`);

  console.log('\n4. Executing process_verified_learning_event RPC...');
  const processSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select
      normalized_score,
      baseline_score,
      baseline_sample_count,
      growth_delta,
      historical_best,
      score_rp_minor,
      growth_rp_minor,
      personal_best_rp_minor,
      difficulty_rp_minor,
      total_rp_minor,
      xp_awarded
    from public.process_verified_learning_event('${targetVleId}'::uuid, '${targetCommandId}'::uuid);
  `;

  const processRes = await runPsql(processSql);
  if (processRes.code !== 0) {
    console.error('Growth processing failed:', processRes.stderr);
    process.exit(1);
  }

  console.log('Growth Event Calculation Result:');
  console.log(processRes.stdout);

  const lines = processRes.stdout.trim().split('\n').map(l => l.trim()).filter(Boolean);
  const parts = lines[lines.length - 1].split('|');
  const [normScore, baseline, sampleCount, delta, histBest, scoreRp, growthRp, pbRp, diffRp, totalRp, xp] = parts;

  // Assert expected formula results:
  if (parseFloat(normScore) !== 7.50) throw new Error(`Expected normalized score 7.50, got ${normScore}`);
  if (parseFloat(baseline) !== 6.43) throw new Error(`Expected baseline 6.43, got ${baseline}`);
  if (parseInt(sampleCount, 10) !== 3) throw new Error(`Expected sample count 3, got ${sampleCount}`);
  if (parseFloat(delta) !== 1.07) throw new Error(`Expected growth delta +1.07, got ${delta}`);
  if (parseFloat(histBest) !== 6.80) throw new Error(`Expected historical best 6.80, got ${histBest}`);
  if (parseInt(scoreRp, 10) !== 750) throw new Error(`Expected score RP 750, got ${scoreRp}`);
  if (parseInt(growthRp, 10) !== 200) throw new Error(`Expected growth bonus 200 (+2.00 RP), got ${growthRp}`);
  if (parseInt(pbRp, 10) !== 100) throw new Error(`Expected personal best 100 (+1.00 RP), got ${pbRp}`);
  if (parseInt(diffRp, 10) !== 100) throw new Error(`Expected difficulty bonus 100 (+1.00 RP), got ${diffRp}`);
  if (parseInt(totalRp, 10) !== 1150) throw new Error(`Expected total RP 1150 (+11.50 RP), got ${totalRp}`);
  if (parseInt(xp, 10) !== 33) throw new Error(`Expected XP 33, got ${xp}`);

  console.log('PASS: All Growth Engine v0.1 breakdown components match the specification exactly!');

  console.log('\n5. Verifying Ledgers and child_balances projection...');
  const ledgerSql = `
    select
      (select amount from public.xp_ledger where source_id in (select id from public.growth_events where verified_learning_event_id = '${targetVleId}')) as xp_award,
      (select amount_minor from public.rp_ledger where source_id in (select id from public.growth_events where verified_learning_event_id = '${targetVleId}')) as rp_award,
      (select xp_total from public.child_balances where child_id = '${CHILD_ID}') as xp_balance,
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}') as rp_balance,
      r.is_reconciled
    from public.reconcile_child_balance('${CHILD_ID}') r;
  `;

  const ledgerRes = await runPsql(ledgerSql);
  console.log('Ledger & Balance Verification:');
  console.log(ledgerRes.stdout);

  const ledgerLines = ledgerRes.stdout.trim().split('\n').map(l => l.trim()).filter(Boolean);
  const [ledgerXp, ledgerRp, balanceXp, balanceRp, reconciled] = ledgerLines[ledgerLines.length - 1].split('|');
  if (parseInt(ledgerXp, 10) !== 33) throw new Error(`Expected ledger XP 33, got ${ledgerXp}`);
  if (parseInt(ledgerRp, 10) !== 1150) throw new Error(`Expected ledger RP 1150, got ${ledgerRp}`);
  if (parseInt(balanceXp, 10) !== 33) throw new Error(`Expected balance XP 33, got ${balanceXp}`);
  if (parseInt(balanceRp, 10) !== 1150) throw new Error(`Expected balance RP 1150, got ${balanceRp}`);
  if (reconciled !== 't') throw new Error(`Balance reconciliation failed!`);

  console.log('PASS: Authoritative ledgers and balance projection match.');

  console.log('\n6. Testing Idempotent Retry of process_verified_learning_event...');
  const retrySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    select total_rp_minor, xp_awarded
    from public.process_verified_learning_event('${targetVleId}'::uuid, '${targetCommandId}'::uuid);
  `;

  const retryRes = await runPsql(retrySql);
  if (retryRes.code !== 0) {
    console.error('Retry failed:', retryRes.stderr);
    process.exit(1);
  }

  // Ensure ledgers did NOT double count
  const verifyRetrySql = `
    select
      (select count(*) from public.growth_events where verified_learning_event_id = '${targetVleId}'),
      (select count(*) from public.xp_ledger where child_id = '${CHILD_ID}'),
      (select count(*) from public.rp_ledger where child_id = '${CHILD_ID}'),
      (select xp_total from public.child_balances where child_id = '${CHILD_ID}'),
      (select rp_balance_minor from public.child_balances where child_id = '${CHILD_ID}');
  `;
  const verifyRetryRes = await runPsql(verifyRetrySql);
  const retryLines = verifyRetryRes.stdout.trim().split('\n').map(l => l.trim()).filter(Boolean);
  const [geCount, xpCount, rpCount, curXp, curRp] = retryLines[retryLines.length - 1].split('|');

  if (parseInt(geCount, 10) !== 1) throw new Error(`Expected 1 growth event, got ${geCount}`);
  if (parseInt(xpCount, 10) !== 1) throw new Error(`Expected 1 XP entry, got ${xpCount}`);
  if (parseInt(rpCount, 10) !== 1) throw new Error(`Expected 1 RP entry, got ${rpCount}`);
  if (parseInt(curXp, 10) !== 33) throw new Error(`Balance changed on retry! XP: ${curXp}`);
  if (parseInt(curRp, 10) !== 1150) throw new Error(`Balance changed on retry! RP: ${curRp}`);

  console.log('PASS: Idempotent retry produced zero duplicates and zero balance drift.');

  console.log('\n7. Testing Below-Level Anti-Farming Protection...');
  const belowLevelSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

    drop table if exists below_assessment;
    create temporary table below_assessment as
    select * from public.create_assessment_draft(
      '${crypto.randomUUID()}'::uuid, '${FAMILY_ID}'::uuid, '${CHILD_ID}'::uuid,
      'math', 'Mathematics', 'Below Level Easy', 'practice', 'below_level', 10.0, 10.0, now(), 'adult'
    );

    select public.submit_assessment((select id from below_assessment), 1, '${crypto.randomUUID()}'::uuid);
    select public.verify_assessment((select id from below_assessment), 2, '${crypto.randomUUID()}'::uuid, 'Easy work verified');

    select
      score_rp_minor,
      growth_rp_minor,
      personal_best_rp_minor,
      difficulty_rp_minor,
      total_rp_minor,
      xp_awarded,
      below_level_adjustment
    from public.process_verified_learning_event(
      (select id from public.verified_learning_events where assessment_id = (select id from below_assessment))
    );
  `;

  const belowRes = await runPsql(belowLevelSql);
  if (belowRes.code !== 0) {
    console.error('Below-level test failed:', belowRes.stderr);
    process.exit(1);
  }

  console.log('Below-Level Result:', belowRes.stdout);
  const belowLines = belowRes.stdout.trim().split('\n').map(l => l.trim()).filter(Boolean);
  const [bScoreRp, bGrowthRp, bPbRp, bDiffRp, bTotalRp, bXp, bAdj] = belowLines[belowLines.length - 1].split('|');

  // Base score 1000 minor * 0.25 = 250 minor (+2.50 RP), bonuses = 0, XP = 10 + 2 * 2.50 = 15 XP
  if (parseInt(bScoreRp, 10) !== 250) throw new Error(`Expected below-level base RP 250, got ${bScoreRp}`);
  if (parseInt(bGrowthRp, 10) !== 0) throw new Error(`Expected growth bonus disabled (0), got ${bGrowthRp}`);
  if (parseInt(bPbRp, 10) !== 0) throw new Error(`Expected PB bonus disabled (0), got ${bPbRp}`);
  if (parseInt(bDiffRp, 10) !== 0) throw new Error(`Expected difficulty bonus 0, got ${bDiffRp}`);
  if (parseInt(bTotalRp, 10) !== 250) throw new Error(`Expected total RP 250 (+2.50 RP), got ${bTotalRp}`);
  if (parseInt(bXp, 10) !== 15) throw new Error(`Expected XP 15, got ${bXp}`);
  if (bAdj !== 't') throw new Error(`Expected below_level_adjustment true, got ${bAdj}`);

  console.log('PASS: Below-level anti-farming protection verified successfully.');

  console.log('\n8. Final Balance Reconciliation Audit...');
  const finalReconSql = `select is_reconciled from public.reconcile_child_balance('${CHILD_ID}');`;
  const finalReconRes = await runPsql(finalReconSql);
  const finalReconLines = finalReconRes.stdout.trim().split('\n').map(l => l.trim()).filter(Boolean);
  if (finalReconLines[finalReconLines.length - 1] !== 't') throw new Error('Final reconciliation failed!');
  console.log('PASS: Child balance is strictly reconciled with all ledger entries.');

  console.log('\n*** ALL PHASE 3 VERTICAL SLICE INTEGRATION TESTS PASSED ***');
  process.exit(0);
}

main().catch((err) => {
  console.error('\n*** TEST FAILED ***', err);
  process.exit(1);
});
