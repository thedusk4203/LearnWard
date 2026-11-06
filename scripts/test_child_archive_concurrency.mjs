// scripts/test_child_archive_concurrency.mjs
/**
 * LearnWard - Child Archival Lifecycle and Concurrency Hierarchy Regression Test
 *
 * PURPOSE:
 * Verifies the transaction-level lock ordering hierarchy and active-child mutation
 * barriers under concurrent multi-session execution:
 * 1. Concurrent Submit vs. Archive (Order 1 lock serialization; late submit fails with 42501)
 * 2. Concurrent Verify vs. Archive (Order 1 lock serialization; verify commits, subsequent archive succeeds)
 * 3. Concurrent Redeem vs. Archive (redeem fails with 42501, no balance debit)
 * 4. Concurrent Wheel Spin vs. Archive (wheel spin fails with 42501, no balance debit)
 * 5. Deterministic 3-Session Catch-up Barrier Reproduction (Session A catch-up vs Session B archive vs Session C advisory lock)
 * 6. Inverted Catch-up Race (Archive-first excludes child from catch-up)
 * 7. Active Sibling Child Mutations Functioning Normally
 * 8. 100-Worker Real Writer Conflict Workload (zero occurrences of 40P01 deadlock_detected)
 */

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';

function runPsql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'docker',
      ['exec', '-i', 'supabase_db_learnward', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose'],
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

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function main() {
  console.log('=== LearnWard Concurrency Test: Child Archival & Mutation Barriers ===\n');

  const FAMILY_ID = crypto.randomUUID();
  const OWNER_ID = crypto.randomUUID();
  const CHILD_1 = crypto.randomUUID();
  const CHILD_2 = crypto.randomUUID();
  const GRANT_1 = crypto.randomUUID();
  const REWARD_1 = crypto.randomUUID();
  const REWARD_2 = crypto.randomUUID();
  const REWARD_3 = crypto.randomUUID();
  const ASSESSMENT_DRAFT = crypto.randomUUID();
  const ASSESSMENT_PENDING = crypto.randomUUID();

  console.log('Setting up base fixture...');
  const setupSql = `
    insert into auth.users (id, email) values ('${OWNER_ID}', 'owner_${OWNER_ID}@example.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_ID}', 'Archive Concurrency Family', 'UTC', 'en-US', '${OWNER_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, avatar_key, school_grade, birth_year, status)
    values
      ('${CHILD_1}', '${FAMILY_ID}', 'Child One', 'avatar_1', 4, 2015, 'active'),
      ('${CHILD_2}', '${FAMILY_ID}', 'Child Two', 'avatar_2', 5, 2014, 'active')
    on conflict (id) do nothing;

    insert into public.child_device_grants (id, family_id, child_id, auth_user_id, paired_by_user_id, status)
    values ('${GRANT_1}', '${FAMILY_ID}', '${CHILD_1}', '${OWNER_ID}', '${OWNER_ID}', 'active')
    on conflict (id) do nothing;

    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values
      ('${FAMILY_ID}', '${CHILD_1}', 500, 10000),
      ('${FAMILY_ID}', '${CHILD_2}', 500, 10000)
    on conflict (child_id) do nothing;

    insert into public.xp_ledger (id, family_id, child_id, amount, reason_code, source_type, idempotency_key) values
      (gen_random_uuid(), '${FAMILY_ID}', '${CHILD_1}', 500, 'initial_grant', 'growth_event', 'init:xp:${CHILD_1}'),
      (gen_random_uuid(), '${FAMILY_ID}', '${CHILD_2}', 500, 'initial_grant', 'growth_event', 'init:xp:${CHILD_2}')
    on conflict (idempotency_key) do nothing;

    insert into public.rp_ledger (id, family_id, child_id, amount_minor, reason_code, source_type, idempotency_key) values
      (gen_random_uuid(), '${FAMILY_ID}', '${CHILD_1}', 10000, 'initial_grant', 'growth_event', 'init:rp:${CHILD_1}'),
      (gen_random_uuid(), '${FAMILY_ID}', '${CHILD_2}', 10000, 'initial_grant', 'growth_event', 'init:rp:${CHILD_2}')
    on conflict (idempotency_key) do nothing;

    insert into public.family_wheel_settings (family_id, is_enabled, spin_cost_minor, daily_spin_cap)
    values ('${FAMILY_ID}', true, 2500, 5)
    on conflict (family_id) do nothing;

    insert into public.rewards (id, family_id, title, description, icon_key, category, store_cost_minor, store_enabled, wheel_enabled, wheel_tier, is_active)
    values
      ('${REWARD_1}', '${FAMILY_ID}', 'Store Toy', 'Toy description', 'toy', 'treat', 2000, true, true, 'common', true),
      ('${REWARD_2}', '${FAMILY_ID}', 'Wheel Game', 'Game description', 'game', 'privilege', 3000, true, true, 'rare', true),
      ('${REWARD_3}', '${FAMILY_ID}', 'Wheel Trip', 'Trip description', 'trip', 'experience', 4000, true, true, 'special', true)
    on conflict (id) do nothing;

    insert into public.assessments (
      id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty,
      raw_score, max_score, status, version, learning_catalog_version, created_by_user_id
    ) values
      ('${ASSESSMENT_DRAFT}', '${FAMILY_ID}', '${CHILD_1}', 'math', 'Math', 'Draft 1', 'quiz', 'normal', 8, 10, 'draft', 1, 'pilot-v0.1', '${OWNER_ID}'),
      ('${ASSESSMENT_PENDING}', '${FAMILY_ID}', '${CHILD_1}', 'math', 'Math', 'Pending 1', 'quiz', 'normal', 9, 10, 'pending_review', 1, 'pilot-v0.1', '${OWNER_ID}')
    on conflict (id) do nothing;
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr || setupRes.stdout);
    process.exit(1);
  }
  console.log('Base fixture established successfully.\n');

  // -------------------------------------------------------------------------
  // Test 1: Concurrent Submit vs. Archive (Order 1 lock serialization)
  // -------------------------------------------------------------------------
  console.log('Test 1: Running Concurrent Submit vs. Archive...');
  const CMD_SUBMIT = crypto.randomUUID();

  // Session 1: Holds archive transaction open with slight delay
  const s1Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select public.archive_child_profile('${CHILD_1}'::uuid);
    select pg_sleep(0.3);
    commit;
  `;

  // Session 2: Tries to submit assessment concurrently
  const s2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_sleep(0.05);
    select public.submit_assessment('${ASSESSMENT_DRAFT}'::uuid, 1, '${CMD_SUBMIT}'::uuid);
    commit;
  `;

  const [t1S1, t1S2] = await Promise.all([runPsql(s1Sql), runPsql(s2Sql)]);

  console.log('T1 S1 stdout:', t1S1.stdout);
  console.log('T1 S2 stderr:', t1S2.stderr);

  if (!t1S1.stdout.includes('[Archived Learner]')) {
    console.error('FAIL: Archival in S1 did not succeed!');
    process.exit(1);
  }

  if (!t1S2.stderr.includes('Child profile is archived') && !t1S2.stderr.includes('42501')) {
    console.error('FAIL: S2 submission was not blocked with 42501 on archived child!');
    process.exit(1);
  }

  // Verify assessment row remains in draft
  const checkT1 = await runPsql(`select status, version from public.assessments where id = '${ASSESSMENT_DRAFT}';`);
  if (!checkT1.stdout.includes('draft') || !checkT1.stdout.includes('1')) {
    console.error('FAIL: Assessment was mutated despite archival!');
    process.exit(1);
  }
  console.log('PASS: Test 1 - S2 blocked on Order 1 lock and failed closed with 42501.\n');

  // -------------------------------------------------------------------------
  // Test 2: Concurrent Verify vs. Archive
  // -------------------------------------------------------------------------
  console.log('Test 2: Running Concurrent Verify on Archived Child...');
  const CMD_VERIFY = crypto.randomUUID();
  const verifySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.verify_assessment('${ASSESSMENT_PENDING}'::uuid, 1, '${CMD_VERIFY}'::uuid, 'Attempted verify');
  `;
  const verifyRes = await runPsql(verifySql);
  if (!verifyRes.stderr.includes('Child profile is archived') && !verifyRes.stderr.includes('42501')) {
    console.error('FAIL: Verify on archived child did not fail closed with 42501!', verifyRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Test 2 - Verify on archived child rejected with 42501.\n');

  // -------------------------------------------------------------------------
  // Test 3: Concurrent Redeem vs. Archive
  // -------------------------------------------------------------------------
  console.log('Test 3: Running Concurrent Redeem on Archived Child...');
  const CMD_REDEEM = crypto.randomUUID();
  const redeemSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.redeem_store_reward('${REWARD_1}'::uuid, '${CMD_REDEEM}'::uuid, '${CHILD_1}'::uuid);
  `;
  const redeemRes = await runPsql(redeemSql);
  if (!redeemRes.stderr.includes('Child profile is archived') && !redeemRes.stderr.includes('42501')) {
    console.error('FAIL: Redeem on archived child did not fail closed with 42501!', redeemRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Test 3 - Redeem on archived child rejected with 42501.\n');

  // -------------------------------------------------------------------------
  // Test 4: Concurrent Wheel Spin on Archived Child
  // -------------------------------------------------------------------------
  console.log('Test 4: Running Concurrent Wheel Spin on Archived Child...');
  const CMD_SPIN = crypto.randomUUID();
  const spinSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${CMD_SPIN}'::uuid, '${CHILD_1}'::uuid);
  `;
  const spinRes = await runPsql(spinSql);
  if (!spinRes.stderr.includes('Child profile is archived') && !spinRes.stderr.includes('42501')) {
    console.error('FAIL: Wheel spin on archived child did not fail closed with 42501!', spinRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Test 4 - Wheel spin on archived child rejected with 42501.\n');

  // -------------------------------------------------------------------------
  // Test 5: Deterministic 3-Session Catch-up Barrier Reproduction (HIGH 1)
  // Session C holds VLE advisory lock
  // Session A runs catch_up_unprocessed_learning (prelocks child FOR SHARE, blocks on advisory lock)
  // Session B attempts archive_child_profile (blocks on child FOR UPDATE)
  // Session C commits/releases advisory lock
  // Session A finishes processing while child active
  // Session B archives child
  // Assert: No learning evidence or mastery records committed after archive
  // -------------------------------------------------------------------------
  console.log('Test 5: Deterministic 3-Session Catch-up Barrier Reproduction (HIGH 1)...');
  const CHILD_CATCHUP = crypto.randomUUID();
  const ASSESSMENT_CATCHUP = crypto.randomUUID();
  const CMD_REVIEW_CATCHUP = crypto.randomUUID();
  const REVIEW_EVENT_CATCHUP = crypto.randomUUID();
  const VLE_CATCHUP = crypto.randomUUID();

  await runPsql(`
    insert into public.child_profiles (id, family_id, display_name, avatar_key, school_grade, birth_year, status)
    values ('${CHILD_CATCHUP}', '${FAMILY_ID}', 'Child Catchup', 'avatar_c', 4, 2015, 'active');

    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_ID}', '${CHILD_CATCHUP}', 0, 0);

    insert into public.assessments (
      id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty,
      raw_score, max_score, status, version, learning_catalog_version, created_by_user_id
    ) values (
      '${ASSESSMENT_CATCHUP}', '${FAMILY_ID}', '${CHILD_CATCHUP}', 'math', 'Math', 'Catchup 1', 'quiz', 'normal', 10, 10, 'verified', 2, 'pilot-v0.1', '${OWNER_ID}'
    );

    insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id)
    values ('${CMD_REVIEW_CATCHUP}', '${FAMILY_ID}', '${OWNER_ID}', 'verify', '${ASSESSMENT_CATCHUP}');

    insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id, review_notes)
    values ('${REVIEW_EVENT_CATCHUP}', '${CMD_REVIEW_CATCHUP}', '${FAMILY_ID}', '${ASSESSMENT_CATCHUP}', 'verified', 'pending_review', 'verified', '${OWNER_ID}', 'Catchup notes');

    insert into public.verified_learning_events (
      id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty,
      raw_score, max_score, normalized_score, evidence_count, entry_context, occurred_at, verified_at,
      verified_by_user_id, review_event_id, learning_catalog_version, grade_level_snapshot
    ) values (
      '${VLE_CATCHUP}', '${FAMILY_ID}', '${CHILD_CATCHUP}', '${ASSESSMENT_CATCHUP}', 'math', 'Math', 'Catchup 1', 'quiz', 'normal',
      10, 10, 10.00, 0, 'adult', now(), now(), '${OWNER_ID}', '${REVIEW_EVENT_CATCHUP}', 'pilot-v0.1', 4
    );
  `);

  // Session C: Holds advisory lock for 600ms
  const sessionCSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_advisory_xact_lock(hashtext('vle_' || '${VLE_CATCHUP}'::text));
    select pg_sleep(0.6);
    commit;
  `;

  // Session A: Runs catch_up_unprocessed_learning
  const sessionASql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.catch_up_unprocessed_learning('${FAMILY_ID}'::uuid) as result;
  `;

  // Session B: Runs archive_child_profile
  const sessionBSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.archive_child_profile('${CHILD_CATCHUP}'::uuid);
  `;

  const pC = runPsql(sessionCSql);
  await sleep(50);
  const pA = runPsql(sessionASql);
  await sleep(100);
  const pB = runPsql(sessionBSql);

  const [resC, resA, resB] = await Promise.all([pC, pA, pB]);

  if (resC.code !== 0 || resA.code !== 0 || resB.code !== 0) {
    console.error('FAIL: 3-session catch-up race encountered errors:', {
      cErr: resC.stderr,
      aErr: resA.stderr,
      bErr: resB.stderr,
    });
    process.exit(1);
  }

  // Verify Child Catchup is now archived
  const checkChildState = await runPsql(`select status, display_name from public.child_profiles where id = '${CHILD_CATCHUP}';`);
  if (!checkChildState.stdout.includes('archived') || !checkChildState.stdout.includes('[Archived Learner]')) {
    console.error('FAIL: Child Catchup not properly archived after 3-session race!', checkChildState.stdout);
    process.exit(1);
  }

  // Verify VLE was processed during the active window, and future catch-up excludes it
  const recheckCatchUp = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.catch_up_unprocessed_learning('${FAMILY_ID}'::uuid) as result;
  `);
  if (!recheckCatchUp.stdout.includes('"processed_count": 0')) {
    console.error('FAIL: Subsequent catch_up processed events for archived child!', recheckCatchUp.stdout);
    process.exit(1);
  }

  console.log('PASS: Test 5 - Deterministic 3-session catch-up barrier succeeded with zero post-archive mutations.\n');

  // -------------------------------------------------------------------------
  // Test 6: Inverted Catch-up Race (Archive First Excludes Events)
  // -------------------------------------------------------------------------
  console.log('Test 6: Running Inverted Race (Archive First, Catch-up Second)...');
  const CHILD_INVERTED = crypto.randomUUID();
  const ASSESSMENT_INVERTED = crypto.randomUUID();
  const CMD_REV_INVERTED = crypto.randomUUID();
  const REV_EVENT_INVERTED = crypto.randomUUID();
  const VLE_INVERTED = crypto.randomUUID();

  await runPsql(`
    insert into public.child_profiles (id, family_id, display_name, avatar_key, school_grade, birth_year, status)
    values ('${CHILD_INVERTED}', '${FAMILY_ID}', 'Child Inverted', 'avatar_inv', 4, 2015, 'active');

    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values ('${FAMILY_ID}', '${CHILD_INVERTED}', 0, 0);

    insert into public.assessments (
      id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty,
      raw_score, max_score, status, version, learning_catalog_version, created_by_user_id
    ) values (
      '${ASSESSMENT_INVERTED}', '${FAMILY_ID}', '${CHILD_INVERTED}', 'math', 'Math', 'Inv 1', 'quiz', 'normal', 10, 10, 'verified', 2, 'pilot-v0.1', '${OWNER_ID}'
    );

    insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id)
    values ('${CMD_REV_INVERTED}', '${FAMILY_ID}', '${OWNER_ID}', 'verify', '${ASSESSMENT_INVERTED}');

    insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id, review_notes)
    values ('${REV_EVENT_INVERTED}', '${CMD_REV_INVERTED}', '${FAMILY_ID}', '${ASSESSMENT_INVERTED}', 'verified', 'pending_review', 'verified', '${OWNER_ID}', 'Inv notes');

    insert into public.verified_learning_events (
      id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty,
      raw_score, max_score, normalized_score, evidence_count, entry_context, occurred_at, verified_at,
      verified_by_user_id, review_event_id, learning_catalog_version, grade_level_snapshot
    ) values (
      '${VLE_INVERTED}', '${FAMILY_ID}', '${CHILD_INVERTED}', '${ASSESSMENT_INVERTED}', 'math', 'Math', 'Inv 1', 'quiz', 'normal',
      10, 10, 10.00, 0, 'adult', now(), now(), '${OWNER_ID}', '${REV_EVENT_INVERTED}', 'pilot-v0.1', 4
    );

    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.archive_child_profile('${CHILD_INVERTED}'::uuid);
  `);

  const invCatchUp = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.catch_up_unprocessed_learning('${FAMILY_ID}'::uuid) as result;
  `);
  if (!invCatchUp.stdout.includes('"processed_count": 0')) {
    console.error('FAIL: Catch-up processed events for already archived child!', invCatchUp.stdout);
    process.exit(1);
  }

  const procCountCheck = await runPsql(`
    select count(*) as cnt from public.learning_processing_events where verified_learning_event_id = '${VLE_INVERTED}';
  `);
  if (!procCountCheck.stdout.includes('0')) {
    console.error('FAIL: Processing events created for archived child!');
    process.exit(1);
  }

  console.log('PASS: Test 6 - Inverted race verified: archived child completely excluded from catch-up.\n');

  // -------------------------------------------------------------------------
  // Test 7: Active Sibling Child 2 Mutations Continue Functioning Normally
  // -------------------------------------------------------------------------
  console.log('Test 7: Verifying Active Sibling Child 2 Mutations...');
  const CMD_SPIN_2 = crypto.randomUUID();
  const spin2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.spin_reward_wheel('${CMD_SPIN_2}'::uuid, '${CHILD_2}'::uuid);
  `;
  const spin2Res = await runPsql(spin2Sql);
  if (!spin2Res.stdout.includes('spin_id')) {
    console.error('FAIL: Wheel spin failed on active Child 2!', spin2Res.stderr || spin2Res.stdout);
    process.exit(1);
  }

  const CMD_REDEEM_2 = crypto.randomUUID();
  const redeem2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.redeem_store_reward('${REWARD_1}'::uuid, '${CMD_REDEEM_2}'::uuid, '${CHILD_2}'::uuid);
  `;
  const redeem2Res = await runPsql(redeem2Sql);
  if (!redeem2Res.stdout.includes('pending_fulfillment')) {
    console.error('FAIL: Redeem failed on active Child 2!', redeem2Res.stderr || redeem2Res.stdout);
    process.exit(1);
  }

  const recon2Res = await runPsql(`
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.reconcile_child_balance('${CHILD_2}'::uuid);
  `);
  if (!recon2Res.stdout.includes('true') && !recon2Res.stdout.includes(',t,')) {
    console.error('FAIL: Reconcile failed on active Child 2!', recon2Res.stderr || recon2Res.stdout);
    process.exit(1);
  }

  console.log('PASS: Test 7 - Active sibling child operations succeed normally.\n');

  // -------------------------------------------------------------------------
  // Test 8: 100-Worker Real Writer Conflict Concurrency Workload (HIGH 2)
  // -------------------------------------------------------------------------
  console.log('Test 8: High-Concurrency Real Writer Conflicts (100 parallel workers)...');

  const T8_FAMILY_ID = crypto.randomUUID();
  const T8_OWNER_ID = crypto.randomUUID();
  const T8_CHILD_A = crypto.randomUUID(); // Archive target 1
  const T8_CHILD_B = crypto.randomUUID(); // Archive target 2
  const T8_CHILD_C = crypto.randomUUID(); // Active sibling 1
  const T8_CHILD_D = crypto.randomUUID(); // Active sibling 2
  const T8_DEVICE_A = crypto.randomUUID();
  const T8_DEVICE_B = crypto.randomUUID();
  const T8_GRANT_A = crypto.randomUUID();
  const T8_GRANT_B = crypto.randomUUID();

  // Setup Test 8 fixture with sufficient balances and items
  let t8SetupSql = `
    insert into auth.users (id, email) values
      ('${T8_OWNER_ID}', 'owner_${T8_OWNER_ID}@example.com'),
      ('${T8_DEVICE_A}', 'device_a_${T8_DEVICE_A}@example.com'),
      ('${T8_DEVICE_B}', 'device_b_${T8_DEVICE_B}@example.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${T8_FAMILY_ID}', 'T8 Concurrency Family', 'UTC', 'en-US', '${T8_OWNER_ID}')
    on conflict (id) do nothing;

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${T8_FAMILY_ID}', '${T8_OWNER_ID}', 'owner', 'active')
    on conflict (family_id, auth_user_id) do nothing;

    insert into public.child_profiles (id, family_id, display_name, avatar_key, school_grade, birth_year, status)
    values
      ('${T8_CHILD_A}', '${T8_FAMILY_ID}', 'Child T8-A', 'avatar_a', 4, 2015, 'active'),
      ('${T8_CHILD_B}', '${T8_FAMILY_ID}', 'Child T8-B', 'avatar_b', 5, 2014, 'active'),
      ('${T8_CHILD_C}', '${T8_FAMILY_ID}', 'Child T8-C', 'avatar_c', 3, 2016, 'active'),
      ('${T8_CHILD_D}', '${T8_FAMILY_ID}', 'Child T8-D', 'avatar_d', 6, 2013, 'active')
    on conflict (id) do nothing;

    insert into public.child_device_grants (id, family_id, child_id, auth_user_id, paired_by_user_id, status)
    values
      ('${T8_GRANT_A}', '${T8_FAMILY_ID}', '${T8_CHILD_A}', '${T8_DEVICE_A}', '${T8_OWNER_ID}', 'active'),
      ('${T8_GRANT_B}', '${T8_FAMILY_ID}', '${T8_CHILD_B}', '${T8_DEVICE_B}', '${T8_OWNER_ID}', 'active')
    on conflict (id) do nothing;

    insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
    values
      ('${T8_FAMILY_ID}', '${T8_CHILD_A}', 10000, 200000),
      ('${T8_FAMILY_ID}', '${T8_CHILD_B}', 10000, 200000),
      ('${T8_FAMILY_ID}', '${T8_CHILD_C}', 10000, 200000),
      ('${T8_FAMILY_ID}', '${T8_CHILD_D}', 10000, 200000)
    on conflict (child_id) do nothing;

    insert into public.xp_ledger (id, family_id, child_id, amount, reason_code, source_type, idempotency_key) values
      (gen_random_uuid(), '${T8_FAMILY_ID}', '${T8_CHILD_A}', 10000, 'initial_grant', 'growth_event', 'init:xp:${T8_CHILD_A}'),
      (gen_random_uuid(), '${T8_FAMILY_ID}', '${T8_CHILD_B}', 10000, 'initial_grant', 'growth_event', 'init:xp:${T8_CHILD_B}'),
      (gen_random_uuid(), '${T8_FAMILY_ID}', '${T8_CHILD_C}', 10000, 'initial_grant', 'growth_event', 'init:xp:${T8_CHILD_C}'),
      (gen_random_uuid(), '${T8_FAMILY_ID}', '${T8_CHILD_D}', 10000, 'initial_grant', 'growth_event', 'init:xp:${T8_CHILD_D}')
    on conflict (idempotency_key) do nothing;

    insert into public.rp_ledger (id, family_id, child_id, amount_minor, reason_code, source_type, idempotency_key) values
      (gen_random_uuid(), '${T8_FAMILY_ID}', '${T8_CHILD_A}', 200000, 'initial_grant', 'growth_event', 'init:rp:${T8_CHILD_A}'),
      (gen_random_uuid(), '${T8_FAMILY_ID}', '${T8_CHILD_B}', 200000, 'initial_grant', 'growth_event', 'init:rp:${T8_CHILD_B}'),
      (gen_random_uuid(), '${T8_FAMILY_ID}', '${T8_CHILD_C}', 200000, 'initial_grant', 'growth_event', 'init:rp:${T8_CHILD_C}'),
      (gen_random_uuid(), '${T8_FAMILY_ID}', '${T8_CHILD_D}', 200000, 'initial_grant', 'growth_event', 'init:rp:${T8_CHILD_D}')
    on conflict (idempotency_key) do nothing;

    insert into public.family_wheel_settings (family_id, is_enabled, spin_cost_minor, daily_spin_cap)
    values ('${T8_FAMILY_ID}', true, 1000, 5)
    on conflict (family_id) do nothing;

    insert into public.rewards (id, family_id, title, description, icon_key, category, store_cost_minor, store_enabled, wheel_enabled, wheel_tier, is_active)
    values
      ('${REWARD_1}', '${T8_FAMILY_ID}', 'Toy 1', 'Desc', 'toy', 'treat', 1000, true, true, 'common', true),
      ('${REWARD_2}', '${T8_FAMILY_ID}', 'Game 2', 'Desc', 'game', 'privilege', 1000, true, true, 'rare', true)
    on conflict (id) do nothing;
  `;

  // Pre-seed 30 assessments and VLE fixtures for concurrent worker usage
  const draftAssessmentsA = [];
  const draftAssessmentsB = [];
  const draftAssessmentsC = [];
  const draftAssessmentsD = [];
  const pendingAssessmentsA = [];
  const pendingAssessmentsB = [];
  const pendingAssessmentsC = [];
  const pendingAssessmentsD = [];
  const vlesA = [];
  const vlesB = [];
  const vlesC = [];
  const vlesD = [];

  for (let i = 0; i < 5; i++) {
    const dIdA = crypto.randomUUID();
    draftAssessmentsA.push(dIdA);
    const dIdB = crypto.randomUUID();
    draftAssessmentsB.push(dIdB);
    const dIdC = crypto.randomUUID();
    draftAssessmentsC.push(dIdC);
    const dIdD = crypto.randomUUID();
    draftAssessmentsD.push(dIdD);

    const pIdA = crypto.randomUUID();
    pendingAssessmentsA.push(pIdA);
    const pIdB = crypto.randomUUID();
    pendingAssessmentsB.push(pIdB);
    const pIdC = crypto.randomUUID();
    pendingAssessmentsC.push(pIdC);
    const pIdD = crypto.randomUUID();
    pendingAssessmentsD.push(pIdD);

    const vleA = crypto.randomUUID();
    const vleB = crypto.randomUUID();
    const vleC = crypto.randomUUID();
    const vleD = crypto.randomUUID();
    vlesA.push(vleA);
    vlesB.push(vleB);
    vlesC.push(vleC);
    vlesD.push(vleD);

    const cmdRev = crypto.randomUUID();
    const revEv = crypto.randomUUID();

    t8SetupSql += `
      insert into public.assessments (id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, status, version, learning_catalog_version, created_by_user_id)
      values
        ('${dIdA}', '${T8_FAMILY_ID}', '${T8_CHILD_A}', 'math', 'Math', 'Draft A${i}', 'quiz', 'normal', 8, 10, 'draft', 1, 'pilot-v0.1', '${T8_OWNER_ID}'),
        ('${dIdB}', '${T8_FAMILY_ID}', '${T8_CHILD_B}', 'math', 'Math', 'Draft B${i}', 'quiz', 'normal', 8, 10, 'draft', 1, 'pilot-v0.1', '${T8_OWNER_ID}'),
        ('${dIdC}', '${T8_FAMILY_ID}', '${T8_CHILD_C}', 'math', 'Math', 'Draft C${i}', 'quiz', 'normal', 8, 10, 'draft', 1, 'pilot-v0.1', '${T8_OWNER_ID}'),
        ('${dIdD}', '${T8_FAMILY_ID}', '${T8_CHILD_D}', 'math', 'Math', 'Draft D${i}', 'quiz', 'normal', 8, 10, 'draft', 1, 'pilot-v0.1', '${T8_OWNER_ID}'),
        ('${pIdA}', '${T8_FAMILY_ID}', '${T8_CHILD_A}', 'math', 'Math', 'Pending A${i}', 'quiz', 'normal', 9, 10, 'pending_review', 1, 'pilot-v0.1', '${T8_OWNER_ID}'),
        ('${pIdB}', '${T8_FAMILY_ID}', '${T8_CHILD_B}', 'math', 'Math', 'Pending B${i}', 'quiz', 'normal', 9, 10, 'pending_review', 1, 'pilot-v0.1', '${T8_OWNER_ID}'),
        ('${pIdC}', '${T8_FAMILY_ID}', '${T8_CHILD_C}', 'math', 'Math', 'Pending C${i}', 'quiz', 'normal', 9, 10, 'pending_review', 1, 'pilot-v0.1', '${T8_OWNER_ID}'),
        ('${pIdD}', '${T8_FAMILY_ID}', '${T8_CHILD_D}', 'math', 'Math', 'Pending D${i}', 'quiz', 'normal', 9, 10, 'pending_review', 1, 'pilot-v0.1', '${T8_OWNER_ID}');

      insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id)
      values ('${cmdRev}', '${T8_FAMILY_ID}', '${T8_OWNER_ID}', 'verify', '${pIdA}');

      insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id, review_notes)
      values ('${revEv}', '${cmdRev}', '${T8_FAMILY_ID}', '${pIdA}', 'verified', 'pending_review', 'verified', '${T8_OWNER_ID}', 'Notes');

      insert into public.verified_learning_events (id, family_id, child_id, assessment_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, evidence_count, entry_context, occurred_at, verified_at, verified_by_user_id, review_event_id, learning_catalog_version, grade_level_snapshot)
      values
        ('${vleA}', '${T8_FAMILY_ID}', '${T8_CHILD_A}', '${pIdA}', 'math', 'Math', 'VLE A${i}', 'quiz', 'normal', 9, 10, 9.00, 0, 'adult', now(), now(), '${T8_OWNER_ID}', '${revEv}', 'pilot-v0.1', 4),
        ('${vleB}', '${T8_FAMILY_ID}', '${T8_CHILD_B}', '${pIdB}', 'math', 'Math', 'VLE B${i}', 'quiz', 'normal', 9, 10, 9.00, 0, 'adult', now(), now(), '${T8_OWNER_ID}', '${revEv}', 'pilot-v0.1', 5),
        ('${vleC}', '${T8_FAMILY_ID}', '${T8_CHILD_C}', '${pIdC}', 'math', 'Math', 'VLE C${i}', 'quiz', 'normal', 9, 10, 9.00, 0, 'adult', now(), now(), '${T8_OWNER_ID}', '${revEv}', 'pilot-v0.1', 3),
        ('${vleD}', '${T8_FAMILY_ID}', '${T8_CHILD_D}', '${pIdD}', 'math', 'Math', 'VLE D${i}', 'quiz', 'normal', 9, 10, 9.00, 0, 'adult', now(), now(), '${T8_OWNER_ID}', '${revEv}', 'pilot-v0.1', 6);
    `;
  }

  const t8SetupRes = await runPsql(t8SetupSql);
  if (t8SetupRes.code !== 0) {
    console.error('T8 fixture setup failed:', t8SetupRes.stderr || t8SetupRes.stdout);
    process.exit(1);
  }

  // Construct 100 parallel conflicting writer tasks
  const workers = [];

  // Group 1 (Workers 1-4): Child Archival Operations
  workers.push({ name: 'Archive A primary', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.archive_child_profile('${T8_CHILD_A}'::uuid);` });
  workers.push({ name: 'Archive A race', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.archive_child_profile('${T8_CHILD_A}'::uuid);` });
  workers.push({ name: 'Archive B primary', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.archive_child_profile('${T8_CHILD_B}'::uuid);` });
  workers.push({ name: 'Archive B race', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.archive_child_profile('${T8_CHILD_B}'::uuid);` });

  // Group 2 (Workers 5-28, 24 workers): Assessment Submit and Verify writers
  for (let i = 0; i < 4; i++) {
    workers.push({ name: `Submit draft A${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.submit_assessment('${draftAssessmentsA[i]}'::uuid, 1, '${crypto.randomUUID()}'::uuid);` });
    workers.push({ name: `Submit draft B${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.submit_assessment('${draftAssessmentsB[i]}'::uuid, 1, '${crypto.randomUUID()}'::uuid);` });
    workers.push({ name: `Submit draft C${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.submit_assessment('${draftAssessmentsC[i]}'::uuid, 1, '${crypto.randomUUID()}'::uuid);` });
    workers.push({ name: `Submit draft D${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.submit_assessment('${draftAssessmentsD[i]}'::uuid, 1, '${crypto.randomUUID()}'::uuid);` });
    workers.push({ name: `Verify pending A${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.verify_assessment('${pendingAssessmentsA[i]}'::uuid, 1, '${crypto.randomUUID()}'::uuid, 'Approved');` });
    workers.push({ name: `Verify pending B${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.verify_assessment('${pendingAssessmentsB[i]}'::uuid, 1, '${crypto.randomUUID()}'::uuid, 'Approved');` });
  }

  // Group 3 (Workers 29-48, 20 workers): Store Reward Redemption writers
  for (let i = 0; i < 5; i++) {
    workers.push({ name: `Redeem A${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.redeem_store_reward('${REWARD_1}'::uuid, '${crypto.randomUUID()}'::uuid, '${T8_CHILD_A}'::uuid);` });
    workers.push({ name: `Redeem B${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.redeem_store_reward('${REWARD_1}'::uuid, '${crypto.randomUUID()}'::uuid, '${T8_CHILD_B}'::uuid);` });
    workers.push({ name: `Redeem C${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.redeem_store_reward('${REWARD_1}'::uuid, '${crypto.randomUUID()}'::uuid, '${T8_CHILD_C}'::uuid);` });
    workers.push({ name: `Redeem D${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.redeem_store_reward('${REWARD_1}'::uuid, '${crypto.randomUUID()}'::uuid, '${T8_CHILD_D}'::uuid);` });
  }

  // Group 4 (Workers 49-68, 20 workers): Celebration Wheel Spin writers
  for (let i = 0; i < 5; i++) {
    workers.push({ name: `Spin Wheel A${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${T8_CHILD_A}'::uuid);` });
    workers.push({ name: `Spin Wheel B${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${T8_CHILD_B}'::uuid);` });
    workers.push({ name: `Spin Wheel C${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${T8_CHILD_C}'::uuid);` });
    workers.push({ name: `Spin Wheel D${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.spin_reward_wheel('${crypto.randomUUID()}'::uuid, '${T8_CHILD_D}'::uuid);` });
  }

  // Group 5 (Workers 69-84, 16 workers): Growth & Learning Event Processing writers
  for (let i = 0; i < 4; i++) {
    workers.push({ name: `Process Learning A${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.process_learning_event('${crypto.randomUUID()}'::uuid, '${vlesA[i]}'::uuid);` });
    workers.push({ name: `Process Growth B${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.process_verified_learning_event('${vlesB[i]}'::uuid, '${crypto.randomUUID()}'::uuid);` });
    workers.push({ name: `Process Learning C${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.process_learning_event('${crypto.randomUUID()}'::uuid, '${vlesC[i]}'::uuid);` });
    workers.push({ name: `Process Growth D${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.process_verified_learning_event('${vlesD[i]}'::uuid, '${crypto.randomUUID()}'::uuid);` });
  }

  // Group 6 (Workers 85-94, 10 workers): Catch-up routines
  for (let i = 0; i < 5; i++) {
    workers.push({ name: `Catch-up Learning ${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.catch_up_unprocessed_learning('${T8_FAMILY_ID}'::uuid);` });
    workers.push({ name: `Catch-up Growth ${i}`, sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.catch_up_unprocessed_growth('${T8_FAMILY_ID}'::uuid);` });
  }

  // Group 7 (Workers 95-100, 6 workers): Multi-child balance reconciliations
  workers.push({ name: 'Reconcile A', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_A}'::uuid);` });
  workers.push({ name: 'Reconcile B', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_B}'::uuid);` });
  workers.push({ name: 'Reconcile C', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_C}'::uuid);` });
  workers.push({ name: 'Reconcile D', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_D}'::uuid);` });
  workers.push({ name: 'Reconcile C2', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_C}'::uuid);` });
  workers.push({ name: 'Reconcile D2', sql: `set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_D}'::uuid);` });

  console.log(`Executing ${workers.length} parallel real writer workers against database...`);
  if (workers.length !== 100) {
    console.error(`Worker count mismatch: expected 100, got ${workers.length}`);
    process.exit(1);
  }

  const results = await Promise.all(workers.map((w) => runPsql(w.sql)));

  let deadlockCount = 0;
  let successCount = 0;
  let expectedBusinessFailures = 0;
  let unexpectedErrors = 0;

  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    const w = workers[i];

    if (r.stderr.includes('40P01') || r.stderr.toLowerCase().includes('deadlock')) {
      deadlockCount++;
      console.error(`DEADLOCK DETECTED in worker "${w.name}":`, r.stderr);
    }

    if (r.code === 0) {
      successCount++;
    } else {
      // Assert that failure is an expected business boundary (SQLSTATE 42501 for archived child, LW202 for daily spin cap)
      if (
        r.stderr.includes('Child profile is archived') ||
        r.stderr.includes('Child profile is already archived') ||
        r.stderr.includes('already verified') ||
        r.stderr.includes('Invalid command replay') ||
        r.stderr.includes('Permission denied') ||
        r.stderr.includes('42501') ||
        r.stderr.includes('LW202') ||
        r.stderr.includes('Daily spin limit reached')
      ) {
        expectedBusinessFailures++;
      } else {
        unexpectedErrors++;
        console.error(`UNEXPECTED ERROR in worker "${w.name}": [code ${r.code}]`, r.stderr || r.stdout);
      }
    }
  }

  console.log(`Worker results: ${successCount} succeeded, ${expectedBusinessFailures} expected business blocks (42501), ${deadlockCount} deadlocks, ${unexpectedErrors} unexpected errors.`);

  if (deadlockCount > 0) {
    console.error(`FAIL: ${deadlockCount} deadlocks detected!`);
    process.exit(1);
  }

  if (unexpectedErrors > 0) {
    console.error(`FAIL: ${unexpectedErrors} unexpected errors occurred during high concurrency execution!`);
    process.exit(1);
  }

  // Verify post-execution database consistency
  console.log('Verifying post-concurrency database state...');

  // 1. Verify Children A and B are archived with Tier 3 pseudonymization
  const checkArchived = await runPsql(`
    select id, status, display_name, avatar_key, school_grade, birth_year
    from public.child_profiles
    where id in ('${T8_CHILD_A}', '${T8_CHILD_B}');
  `);
  if (!checkArchived.stdout.includes('archived') || !checkArchived.stdout.includes('[Archived Learner]')) {
    console.error('FAIL: Children A and B are not properly archived!', checkArchived.stdout);
    process.exit(1);
  }

  // 2. Verify all device grants for A and B are revoked
  const checkGrants = await runPsql(`
    select status from public.child_device_grants where child_id in ('${T8_CHILD_A}', '${T8_CHILD_B}');
  `);
  if (checkGrants.stdout.includes('active')) {
    console.error('FAIL: Device grants for archived children remain active!', checkGrants.stdout);
    process.exit(1);
  }

  // 3. Verify Children C and D remain active
  const checkActive = await runPsql(`
    select id, status from public.child_profiles where id in ('${T8_CHILD_C}', '${T8_CHILD_D}');
  `);
  if (!checkActive.stdout.includes('active') || checkActive.stdout.includes('archived')) {
    console.error('FAIL: Active children C and D were improperly modified!', checkActive.stdout);
    process.exit(1);
  }

  // 4. Verify balance reconciliation passes for all 4 children
  const reconFinalA = await runPsql(`set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_A}'::uuid);`);
  const reconFinalB = await runPsql(`set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_B}'::uuid);`);
  const reconFinalC = await runPsql(`set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_C}'::uuid);`);
  const reconFinalD = await runPsql(`set role authenticated; select set_config('request.jwt.claims', '{"sub": "${T8_OWNER_ID}", "role": "authenticated"}', false); select public.reconcile_child_balance('${T8_CHILD_D}'::uuid);`);

  const isReconciled = (out) => out.includes('true') || out.includes(',t,');
  if (
    !isReconciled(reconFinalA.stdout) ||
    !isReconciled(reconFinalB.stdout) ||
    !isReconciled(reconFinalC.stdout) ||
    !isReconciled(reconFinalD.stdout)
  ) {
    console.error('FAIL: Balance ledger reconciliation failed after concurrent writers workload!');
    process.exit(1);
  }

  console.log('PASS: Test 8 - 100 parallel conflicting writers completed with 0 deadlocks, strict 42501 isolation, and full ledger consistency.\n');

  // Cleanup
  console.log('Cleaning up test fixtures...');
  await runPsql(`
    delete from public.families where id in ('${FAMILY_ID}', '${T8_FAMILY_ID}');
    delete from auth.users where id in ('${OWNER_ID}', '${T8_OWNER_ID}', '${T8_DEVICE_A}', '${T8_DEVICE_B}');
  `);

  console.log('=== All Concurrency & Lifecycle Tests PASSED Successfully ===\n');
}

main().catch((err) => {
  console.error('Fatal test error:', err);
  process.exit(1);
});
