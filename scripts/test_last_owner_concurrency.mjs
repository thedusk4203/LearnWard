// scripts/test_last_owner_concurrency.mjs
/**
 * LearnWard - Last Active Owner Concurrency Regression Test
 *
 * PURPOSE & ARCHITECTURE:
 * Why this test requires separate database connections:
 * In PostgreSQL, transaction isolation and row locks (`FOR UPDATE`) are session-scoped.
 * A single pgTAP transaction cannot observe lock contention against itself.
 *
 * This test spawns TWO independent PostgreSQL client sessions simultaneously:
 * 1. Connection 1 begins a transaction and demotes Owner A, holding the row lock on `public.families`.
 * 2. Connection 2 concurrently begins a transaction and attempts to demote Owner B.
 * 3. Connection 2 is blocked by the row lock in `private.ensure_last_active_owner()`.
 * 4. When Connection 1 commits, Connection 2 unblocks, re-evaluates the remaining active owners count,
 *    detects that Owner B is now the sole active owner, and raises `LW006` ('Family must have at least one active owner').
 * 5. Final state assertion: The family NEVER has zero active owners. At least one active owner remains.
 */

import { spawn } from 'node:child_process';

const FAMILY_ID = 'f0000000-0000-4000-a000-000000000001';
const OWNER_1 = 'a0000000-0000-4000-a000-000000000001';
const OWNER_2 = 'a0000000-0000-4000-a000-000000000002';

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
  console.log('=== LearnWard Concurrency Test: Last Active Owner Serialization ===');
  console.log('Setting up test fixture: Family with 2 active owners...');

  const setupSql = `
    -- Clean previous fixture if any
    delete from public.families where id = '${FAMILY_ID}';
    delete from auth.users where id in ('${OWNER_1}', '${OWNER_2}');

    -- Insert two test auth users
    insert into auth.users (id, email) values
      ('${OWNER_1}', 'owner1_concurrency@example.com'),
      ('${OWNER_2}', 'owner2_concurrency@example.com');

    -- Insert family and both owners
    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${FAMILY_ID}', 'Concurrency Test Family', 'UTC', 'en-US', '${OWNER_1}');

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values
      ('${FAMILY_ID}', '${OWNER_1}', 'owner', 'active'),
      ('${FAMILY_ID}', '${OWNER_2}', 'owner', 'active');
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr || setupRes.stdout);
    process.exit(1);
  }
  console.log('Fixture established: Owner 1 and Owner 2 are active owners.');

  console.log('\nLaunching concurrent demotion race across 2 independent connections...');

  // Connection 1: Begins transaction, updates Owner 1 to 'parent', holds family lock with pg_sleep(1.5), then commits
  const conn1Sql = `
    \\set ON_ERROR_STOP 1
    begin;
    update public.family_memberships
       set role = 'parent'
     where family_id = '${FAMILY_ID}'
       and auth_user_id = '${OWNER_1}';
    select pg_sleep(1.5);
    commit;
  `;

  // Connection 2: Waits 0.3s (so Connection 1 is holding the lock), then attempts to update Owner 2 to 'parent'
  const conn2Sql = `
    \\set ON_ERROR_STOP 0
    select pg_sleep(0.3);
    begin;
    update public.family_memberships
       set role = 'parent'
     where family_id = '${FAMILY_ID}'
       and auth_user_id = '${OWNER_2}';
    commit;
  `;

  const [res1, res2] = await Promise.all([
    runPsql(conn1Sql),
    runPsql(conn2Sql),
  ]);

  console.log('\n--- Connection 1 Result ---');
  console.log(res1.stdout.trim());
  if (res1.stderr) console.error('Connection 1 stderr:', res1.stderr.trim());

  console.log('\n--- Connection 2 Result ---');
  console.log(res2.stdout.trim());
  if (res2.stderr) console.log('Connection 2 output:', res2.stderr.trim());

  // Verify that at least one transaction failed with LW006
  const conn2FailedWithLW006 =
    res2.stderr.includes('LW006') ||
    res2.stdout.includes('LW006') ||
    res2.stderr.includes('Family must have at least one active owner') ||
    res2.stdout.includes('Family must have at least one active owner');

  console.log('\n--- Invariant Verification ---');
  console.log(`Connection 2 correctly rejected with LW006: ${conn2FailedWithLW006}`);

  // Query final state
  const verifySql = `
    select auth_user_id, role, status
      from public.family_memberships
     where family_id = '${FAMILY_ID}';

    select count(*) as active_owners
      from public.family_memberships
     where family_id = '${FAMILY_ID}'
       and role = 'owner'
       and status = 'active';
  `;

  const verifyRes = await runPsql(verifySql);
  console.log('\nFinal Database State:');
  console.log(verifyRes.stdout.trim());

  // Teardown fixture
  const cleanupSql = `
    delete from public.families where id = '${FAMILY_ID}';
    delete from auth.users where id in ('${OWNER_1}', '${OWNER_2}');
  `;
  await runPsql(cleanupSql);

  const activeOwnerCountMatch = verifyRes.stdout.match(/active_owners\s*\n\s*-+\s*\n\s*(\d+)/);
  const activeOwners = activeOwnerCountMatch ? parseInt(activeOwnerCountMatch[1], 10) : 0;

  console.log(`Remaining active owners: ${activeOwners}`);

  if (activeOwners >= 1 && conn2FailedWithLW006) {
    console.log('\n[PASS] Concurrency Invariant Verified: Transactions were serialized and final active owners >= 1.');
    process.exit(0);
  } else {
    console.error('\n[FAIL] Concurrency Invariant Violated! Active owners:', activeOwners);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Unexpected error in concurrency test:', err);
  process.exit(1);
});
