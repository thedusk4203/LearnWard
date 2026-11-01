// scripts/test_storage_evidence_security.mjs
/**
 * LearnWard - Assessment Evidence Storage Security Regression Test
 *
 * Verifies:
 * 1. Storage bucket 'assessment-evidence' is private.
 * 2. Unauthenticated access is denied.
 * 3. Cross-family read/write access is denied via Storage RLS.
 * 4. Legitimate family adult can upload and read evidence for their family path.
 */

import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const API_URL = 'http://127.0.0.1:45321';
const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const JWT_SECRET = 'super-secret-jwt-token-with-at-least-32-characters-long';

const FAMILY_A = 'fa000000-0000-4000-c000-000000000001';
const OWNER_A = 'aa000000-0000-4000-c000-000000000001';
const CHILD_A = 'ca000000-0000-4000-c000-000000000001';
const ASSESSMENT_A = 'ea000000-0000-4000-c000-000000000001';

const FAMILY_B = 'fb000000-0000-4000-c000-000000000002';
const OWNER_B = 'ab000000-0000-4000-c000-000000000002';
const CHILD_B = 'cb000000-0000-4000-c000-000000000002';

function createJwt(userId) {
  const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({
    sub: userId,
    aud: 'authenticated',
    role: 'authenticated',
    exp: Math.floor(Date.now() / 1000) + 3600
  })).toString('base64url');
  const signature = crypto.createHmac('sha256', JWT_SECRET).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${signature}`;
}

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
  console.log('=== LearnWard Storage Evidence Security Test ===');
  console.log('Setting up database fixtures for Family A and Family B...');

  const setupSql = `
    delete from public.assessments where id = '${ASSESSMENT_A}';
    delete from public.child_profiles where id in ('${CHILD_A}', '${CHILD_B}');
    delete from public.families where id in ('${FAMILY_A}', '${FAMILY_B}');
    delete from auth.users where id in ('${OWNER_A}', '${OWNER_B}');

    insert into auth.users (id, email) values
      ('${OWNER_A}', 'storage_owner_a@example.com'),
      ('${OWNER_B}', 'storage_owner_b@example.com');

    insert into public.families (id, name, timezone, locale, created_by_user_id) values
      ('${FAMILY_A}', 'Storage Family A', 'UTC', 'en-US', '${OWNER_A}'),
      ('${FAMILY_B}', 'Storage Family B', 'UTC', 'en-US', '${OWNER_B}');

    insert into public.family_memberships (family_id, auth_user_id, role, status) values
      ('${FAMILY_A}', '${OWNER_A}', 'owner', 'active'),
      ('${FAMILY_B}', '${OWNER_B}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
      ('${CHILD_A}', '${FAMILY_A}', 'Child A', 3, 2017),
      ('${CHILD_B}', '${FAMILY_B}', 'Child B', 4, 2016);
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr);
    process.exit(1);
  }
  console.log('Fixtures established.');

  const tokenA = createJwt(OWNER_A);
  const tokenB = createJwt(OWNER_B);

  const pathA = `${FAMILY_A}/${CHILD_A}/${ASSESSMENT_A}/page1.jpg`;
  const dummyImageBytes = Buffer.from('FAKE_JPEG_IMAGE_CONTENT');

  // Test 1: Unauthenticated upload attempt must fail
  console.log('\nTest 1: Unauthenticated upload rejection...');
  const unauthUploadRes = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (unauthUploadRes.status !== 400 && unauthUploadRes.status !== 401 && unauthUploadRes.status !== 403) {
    console.error(`FAIL: Expected unauthenticated upload to be denied, got status ${unauthUploadRes.status}`);
    process.exit(1);
  }
  console.log(`PASS: Unauthenticated upload rejected with status ${unauthUploadRes.status}.`);

  // Test 2: Owner A uploads evidence to Family A path -> must succeed
  console.log('\nTest 2: Family A adult uploads to Family A path...');
  const ownerAUploadRes = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (!ownerAUploadRes.ok) {
    const errText = await ownerAUploadRes.text();
    console.error(`FAIL: Owner A upload failed: ${ownerAUploadRes.status} ${errText}`);
    process.exit(1);
  }
  console.log(`PASS: Owner A upload succeeded (HTTP ${ownerAUploadRes.status}).`);

  // Test 3: Owner A downloads evidence from Family A path -> must succeed
  console.log('\nTest 3: Family A adult reads Family A evidence...');
  const ownerAGetRes = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
    },
  });
  if (!ownerAGetRes.ok) {
    console.error(`FAIL: Owner A read failed: ${ownerAGetRes.status}`);
    process.exit(1);
  }
  const content = await ownerAGetRes.text();
  if (content !== 'FAKE_JPEG_IMAGE_CONTENT') {
    console.error('FAIL: Downloaded content does not match uploaded bytes');
    process.exit(1);
  }
  console.log('PASS: Owner A read succeeded with exact content match.');

  // Test 4: Owner B attempts to download Family A evidence -> must fail
  console.log('\nTest 4: Cross-family read attempt (Owner B reading Family A evidence)...');
  const ownerBGetRes = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenB}`,
    },
  });
  if (ownerBGetRes.ok) {
    console.error('FAIL: Owner B was able to read Family A private evidence!');
    process.exit(1);
  }
  console.log(`PASS: Cross-family read denied (HTTP ${ownerBGetRes.status}).`);

  // Test 5: Owner B attempts to upload to Family A path -> must fail
  console.log('\nTest 5: Cross-family upload attempt (Owner B uploading to Family A path)...');
  const crossUploadPath = `${FAMILY_A}/${CHILD_A}/${ASSESSMENT_A}/malicious.jpg`;
  const ownerBCrossUploadRes = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${crossUploadPath}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenB}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (ownerBCrossUploadRes.ok) {
    console.error('FAIL: Owner B was able to upload into Family A path!');
    process.exit(1);
  }
  console.log(`PASS: Cross-family upload denied (HTTP ${ownerBCrossUploadRes.status}).`);

  // Cleanup storage & database
  console.log('\nCleaning up storage and database...');
  await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    method: 'DELETE',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
    },
  });

  await runPsql(`
    delete from public.assessments where id = '${ASSESSMENT_A}';
    delete from public.child_profiles where id in ('${CHILD_A}', '${CHILD_B}');
    delete from public.families where id in ('${FAMILY_A}', '${FAMILY_B}');
    delete from auth.users where id in ('${OWNER_A}', '${OWNER_B}');
  `);

  console.log('=== Storage Evidence Security Test PASSED ===\n');
}

main().catch((err) => {
  console.error('Unexpected error:', err);
  process.exit(1);
});
