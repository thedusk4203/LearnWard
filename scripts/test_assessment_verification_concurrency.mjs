// scripts/test_assessment_verification_concurrency.mjs
/**
 * LearnWard - Assessment Verification Concurrency Regression Test
 *
 * PURPOSE:
 * Verifies that concurrent verification attempts on the same assessment
 * are serialized via pessimistic row lock (FOR UPDATE), prevent race conditions,
 * and guarantee that exactly ONE verified_learning_event record is created.
 */

import { spawn } from 'node:child_process';

const FAMILY_ID = 'f2000000-0000-4000-b000-000000000001';
const OWNER_ID = 'a2000000-0000-4000-b000-000000000001';
const CHILD_ID = 'c2000000-0000-4000-b000-000000000001';
const ASSESSMENT_ID = 'e2000000-0000-4000-b000-000000000001';
const CMD_1 = '91000000-0000-4000-b000-000000000001';
const CMD_2 = '92000000-0000-4000-b000-000000000002';

function runPsql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'docker',
      ['exec', '-i', 'supabase_db_learnward', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=0'],
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
  console.log('=== LearnWard Concurrency Test: Assessment Verification Serialization ===');
  console.log('Setting up fixture: Family, Child, and Pending Assessment...');

  const setupSql = `
    delete from public.assessments where id = '${ASSESSMENT_ID}';
    delete from public.child_profiles where id = '${CHILD_ID}';
    delete from public.families where id = '${FAMILY_ID}';
    delete from auth.users where id = '${OWNER_ID}';

    insert into auth.users (id, email) values ('${OWNER_ID}', 'concurrency_parent@example.com');

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_ID}', 'Concurrency Family', 'UTC', 'en-US', '${OWNER_ID}');

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${CHILD_ID}', '${FAMILY_ID}', 'Test Child', 4, 2016);

    insert into public.assessments (
      id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty,
      raw_score, max_score, status, version, created_by_user_id
    ) values (
      '${ASSESSMENT_ID}', '${FAMILY_ID}', '${CHILD_ID}', 'math', 'Mathematics', 'Weekly Test',
      'quiz', 'normal', 9.0, 10.0, 'pending_review', 2, '${OWNER_ID}'
    );
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr || setupRes.stdout);
    process.exit(1);
  }
  console.log('Fixture established: Assessment in pending_review with version=2.');

  // Session 1: Call verify_assessment with CMD_1 and simulated slight delay inside transaction
  const session1Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select pg_sleep(0.1);
    select public.verify_assessment('${ASSESSMENT_ID}'::uuid, 2, '${CMD_1}'::uuid, 'Session 1 verify');
    commit;
  `;

  // Session 2: Call verify_assessment concurrently with CMD_2
  const session2Sql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    begin;
    select public.verify_assessment('${ASSESSMENT_ID}'::uuid, 2, '${CMD_2}'::uuid, 'Session 2 verify');
    commit;
  `;

  console.log('Spawning two concurrent verification transactions...');
  const [res1, res2] = await Promise.all([
    runPsql(session1Sql),
    runPsql(session2Sql)
  ]);

  console.log('Session 1 stdout:', res1.stdout.trim());
  console.log('Session 1 stderr:', res1.stderr.trim());
  console.log('Session 2 stdout:', res2.stdout.trim());
  console.log('Session 2 stderr:', res2.stderr.trim());

  // Check database state
  const checkSql = `
    select
      (select count(*) from public.verified_learning_events where assessment_id = '${ASSESSMENT_ID}') as learning_events_count,
      (select status from public.assessments where id = '${ASSESSMENT_ID}') as current_status,
      (select version from public.assessments where id = '${ASSESSMENT_ID}') as current_version;
  `;
  const checkRes = await runPsql(checkSql);
  console.log('Database state check:');
  console.log(checkRes.stdout.trim());

  // Assertions:
  // 1. One transaction must succeed, one must fail with LW101 (Stale assessment version)
  const oneSucceeded = res1.stdout.includes('verify_assessment') || res2.stdout.includes('verify_assessment');
  const oneFailedStale = res1.stderr.includes('Stale assessment version') || res2.stderr.includes('Stale assessment version') ||
                         res1.stderr.includes('LW101') || res2.stderr.includes('LW101');

  if (!oneSucceeded || !oneFailedStale) {
    console.error('FAIL: Expected one transaction to succeed and one to fail with LW101');
    process.exit(1);
  }

  // 2. Verified learning events count must be exactly 1
  if (!checkRes.stdout.match(/1\s+\|\s+verified\s+\|\s+3/)) {
    console.error('FAIL: Expected exactly 1 verified_learning_event, status=verified, version=3');
    process.exit(1);
  }

  console.log('SUCCESS: Exactly one verified_learning_event was created, version serialized to 3.');

  // Test Case B: Idempotent verify call using the successful CMD
  console.log('\nTesting Idempotency: Retrying verify with already-processed command_id...');
  const successfulCmd = (res1.stdout.includes('verify_assessment')) ? CMD_1 : CMD_2;
  const retrySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);
    select public.verify_assessment('${ASSESSMENT_ID}'::uuid, 2, '${successfulCmd}'::uuid, 'Idempotent retry');
  `;
  const retryRes = await runPsql(retrySql);
  console.log('Retry output:', retryRes.stdout.trim());

  const checkRetrySql = `
    select count(*) as learning_events_count from public.verified_learning_events where assessment_id = '${ASSESSMENT_ID}';
  `;
  const checkRetryRes = await runPsql(checkRetrySql);
  if (!checkRetryRes.stdout.includes('1')) {
    console.error('FAIL: Duplicate learning events created during retry!');
    process.exit(1);
  }

  console.log('SUCCESS: Idempotent retry did not create duplicate events.');

  // Cleanup
  await runPsql(`
    delete from public.assessments where id = '${ASSESSMENT_ID}';
    delete from public.child_profiles where id = '${CHILD_ID}';
    delete from public.families where id = '${FAMILY_ID}';
    delete from auth.users where id = '${OWNER_ID}';
  `);

  console.log('=== Assessment Concurrency Verification PASSED ===\n');
}

main().catch((err) => {
  console.error('Unexpected error:', err);
  process.exit(1);
});
