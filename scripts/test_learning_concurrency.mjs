// scripts/test_learning_concurrency.mjs
/**
 * LearnWard - Phase 5.1 Learning Mastery Concurrency Regression Test
 *
 * SCENARIOS:
 * 1. First-Write Advisory Lock Serialization:
 *    When two concurrent process_learning_event transactions process distinct VLEs
 *    affecting the same previously unseen child and learning node, transaction-level
 *    advisory locks serialize the first write safely.
 *    - Both transactions succeed without unique constraint collisions
 *    - child_mastery_states has exactly 1 row for this child + node
 *    - mastery_state_revisions has exactly 2 revisions
 *    - Result converges to canonical chronological ordering
 *
 * 2. Concurrent Same-Command Replay Race:
 *    When two concurrent requests submit the same command_id for the same VLE:
 *    - One acquires lock and processes
 *    - The second serializes on lock, rechecks receipts, and returns committed snapshot
 *    - Exactly ONE learning_processing_events record exists
 *    - No duplicate evidence or revisions created
 *
 * 3. New Command on Already Processed VLE:
 *    Calling process_learning_event with a new command_id on an already processed VLE:
 *    - Binds new command receipt to existing VLE
 *    - Replays existing committed result snapshot
 *    - Zero additional evidence or revisions generated
 *
 * 4. Concurrent Catch-Up and Manual Process Convergence:
 *    Catch-up and manual process running simultaneously converge safely on the same VLE.
 */

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';

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
  console.log('=== LearnWard Concurrency Test: Learning Mastery Engine Serialization ===\n');

  const familyId = crypto.randomUUID();
  const ownerId = crypto.randomUUID();
  const childId = crypto.randomUUID();

  console.log('Setting up test fixtures for Family and Child...');
  const setupSql = `
    insert into auth.users (id, email) values ('${ownerId}', 'learning_concurrency_${ownerId}@test.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${familyId}', 'Concurrency Family', 'UTC', 'en_US', '${ownerId}');

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${familyId}', '${ownerId}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${childId}', '${familyId}', 'Concurrency Child', 4, 2016);
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Setup failed:', setupRes.stderr);
    process.exit(1);
  }

  // -------------------------------------------------------------------------
  // Scenario 1: First-Write Lock Serialization on Unseen Child + Node
  // -------------------------------------------------------------------------
  console.log('Scenario 1: Testing first-write concurrency on unseen child + node...');

  const assessId1 = crypto.randomUUID();
  const assessId2 = crypto.randomUUID();
  const vleId1 = crypto.randomUUID();
  const vleId2 = crypto.randomUUID();
  const cmd1 = crypto.randomUUID();
  const cmd2 = crypto.randomUUID();

  // Create two assessments and verify them (one at t1, one at t2)
  const createAssessSql = `
    insert into public.assessments (id, family_id, child_id, created_by_user_id, status, subject_key, title, occurred_at, raw_score, max_score)
    values
      ('${assessId1}', '${familyId}', '${childId}', '${ownerId}', 'pending_review', 'math', 'Quiz 1', now() - interval '2 days', 80, 100),
      ('${assessId2}', '${familyId}', '${childId}', '${ownerId}', 'pending_review', 'math', 'Quiz 2', now() - interval '1 day', 100, 100);

    -- Map both assessments to Single Digit Addition
    insert into public.assessment_learning_mappings (family_id, assessment_id, learning_node_id, score_source, component_key, raw_score, max_score)
    values
      ('${familyId}', '${assessId1}', 'b0000003-0000-0000-0000-000000000001', 'component_score', 'c1', 80, 100),
      ('${familyId}', '${assessId2}', 'b0000003-0000-0000-0000-000000000001', 'component_score', 'c1', 100, 100);

    -- Insert verified learning events
    insert into public.verified_learning_events (id, assessment_id, family_id, child_id, verified_by_user_id, verified_at, occurred_at, subject_key, raw_score, max_score, percentage_score, grade_level_snapshot)
    values
      ('${vleId1}', '${assessId1}', '${familyId}', '${childId}', '${ownerId}', now() - interval '2 days', now() - interval '2 days', 'math', 80, 100, 80.00, 4),
      ('${vleId2}', '${assessId2}', '${familyId}', '${childId}', '${ownerId}', now() - interval '1 day', now() - interval '1 day', 'math', 100, 100, 100.00, 4);

    update public.assessments set status = 'verified' where id in ('${assessId1}', '${assessId2}');
  `;

  const assessRes = await runPsql(createAssessSql);
  if (assessRes.code !== 0) {
    console.error('Failed to create assessments:', assessRes.stderr);
    process.exit(1);
  }

  // Fire process_learning_event for vleId1 and vleId2 concurrently
  const procSql1 = `
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.process_learning_event('${cmd1}'::uuid, '${vleId1}'::uuid);
  `;

  const procSql2 = `
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.process_learning_event('${cmd2}'::uuid, '${vleId2}'::uuid);
  `;

  const [res1, res2] = await Promise.all([runPsql(procSql1), runPsql(procSql2)]);

  if (res1.code !== 0 || res2.code !== 0) {
    console.error('Concurrent processing failed:', res1.stderr, res2.stderr);
    process.exit(1);
  }

  // Verify child_mastery_states and mastery_state_revisions
  const verifyStateSql = `
    select
      (select count(*) from public.child_mastery_states where child_id = '${childId}' and learning_node_id = 'b0000003-0000-0000-0000-000000000001') || '|' ||
      (select count(*) from public.mastery_state_revisions where child_id = '${childId}' and learning_node_id = 'b0000003-0000-0000-0000-000000000001') || '|' ||
      (select mastery_score from public.child_mastery_states where child_id = '${childId}' and learning_node_id = 'b0000003-0000-0000-0000-000000000001');
  `;

  const verifyRes = await runPsql(verifyStateSql);
  const [nodeCount, revCount, finalScore] = verifyRes.stdout.split('|');

  if (nodeCount !== '1' || revCount !== '2' || parseFloat(finalScore) !== 87.00) {
    console.error(`Unexpected state after concurrent first writes: nodes=${nodeCount}, revs=${revCount}, score=${finalScore}`);
    process.exit(1);
  }
  console.log('  -> PASS: Serialized first-write converged to canonical score (87.00) across 2 revisions.');

  // -------------------------------------------------------------------------
  // Scenario 2: Concurrent Same-Command Replay Race
  // -------------------------------------------------------------------------
  console.log('Scenario 2: Testing concurrent same-command replay race...');

  const replayCmd = crypto.randomUUID();
  const replaySql = `
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.process_learning_event('${replayCmd}'::uuid, '${vleId1}'::uuid);
  `;

  const [repRes1, repRes2] = await Promise.all([runPsql(replaySql), runPsql(replaySql)]);
  if (repRes1.code !== 0 || repRes2.code !== 0) {
    console.error('Concurrent replay failed:', repRes1.stderr, repRes2.stderr);
    process.exit(1);
  }

  const checkReplaySql = `
    select count(*) from public.command_receipts where command_id = '${replayCmd}';
  `;
  const checkReplayRes = await runPsql(checkReplaySql);
  if (checkReplayRes.stdout !== '1') {
    console.error(`Expected exactly 1 receipt for replay command, got ${checkReplayRes.stdout}`);
    process.exit(1);
  }
  console.log('  -> PASS: Concurrent replay serialized cleanly with exactly 1 receipt recorded.');

  // -------------------------------------------------------------------------
  // Scenario 3: New Command on Already-Processed VLE
  // -------------------------------------------------------------------------
  console.log('Scenario 3: Testing new command on already-processed VLE...');

  const newCmd = crypto.randomUUID();
  const newCmdSql = `
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.process_learning_event('${newCmd}'::uuid, '${vleId1}'::uuid);
  `;

  const newCmdRes = await runPsql(newCmdSql);
  if (newCmdRes.code !== 0) {
    console.error('New command on processed VLE failed:', newCmdRes.stderr);
    process.exit(1);
  }

  const checkNewCmdSql = `
    select
      (select count(*) from public.command_receipts where command_id = '${newCmd}') || '|' ||
      (select count(*) from public.mastery_state_revisions where child_id = '${childId}' and learning_node_id = 'b0000003-0000-0000-0000-000000000001');
  `;
  const checkNewCmdRes = await runPsql(checkNewCmdSql);
  const [newCmdReceipts, totalRevs] = checkNewCmdRes.stdout.split('|');

  if (newCmdReceipts !== '1' || totalRevs !== '2') {
    console.error(`New command handling error: receipts=${newCmdReceipts}, revs=${totalRevs}`);
    process.exit(1);
  }
  console.log('  -> PASS: New command bound receipt without duplicate revisions.');

  // -------------------------------------------------------------------------
  // Scenario 4: Concurrent Catch-Up and Manual Process Convergence
  // -------------------------------------------------------------------------
  console.log('Scenario 4: Testing concurrent catch-up and manual process convergence...');

  const assessId3 = crypto.randomUUID();
  const vleId3 = crypto.randomUUID();
  const manualCmd = crypto.randomUUID();

  const addVle3Sql = `
    insert into public.assessments (id, family_id, child_id, created_by_user_id, status, subject_key, title, occurred_at, raw_score, max_score)
    values ('${assessId3}', '${familyId}', '${childId}', '${ownerId}', 'verified', 'math', 'Quiz 3', now(), 95, 100);

    insert into public.verified_learning_events (id, assessment_id, family_id, child_id, verified_by_user_id, verified_at, occurred_at, subject_key, raw_score, max_score, percentage_score, grade_level_snapshot)
    values ('${vleId3}', '${assessId3}', '${familyId}', '${childId}', '${ownerId}', now(), now(), 'math', 95, 100, 95.00, 4);
  `;
  await runPsql(addVle3Sql);

  const catchUpSql = `
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.catch_up_unprocessed_learning('${familyId}'::uuid);
  `;

  const manualSql = `
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.process_learning_event('${manualCmd}'::uuid, '${vleId3}'::uuid);
  `;

  const [cuRes, manRes] = await Promise.all([runPsql(catchUpSql), runPsql(manualSql)]);
  if (cuRes.code !== 0 || manRes.code !== 0) {
    console.error('Concurrent catch-up / manual process failed:', cuRes.stderr, manRes.stderr);
    process.exit(1);
  }

  const checkVle3Sql = `
    select count(*) from public.learning_processing_events where verified_learning_event_id = '${vleId3}';
  `;
  const checkVle3Res = await runPsql(checkVle3Sql);
  if (checkVle3Res.stdout !== '1') {
    console.error(`Expected exactly 1 processing event for VLE 3, got ${checkVle3Res.stdout}`);
    process.exit(1);
  }
  console.log('  -> PASS: Concurrent catch-up and manual process converged to exactly 1 event.');

  console.log('\nAll Learning Concurrency Regression Tests PASSED!');
}

main().catch((err) => {
  console.error('Unhandled failure:', err);
  process.exit(1);
});
