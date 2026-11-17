// scripts/test_storage_evidence_security.mjs
/**
 * LearnWard - Assessment Evidence Storage Security Regression Test
 *
 * Verifies all Phase 2 Storage security invariants:
 * A. Owner A uploads to Family A / Child A / Draft Assessment A -> SUCCESS
 * B. Owner A uploads to Family A / Child A / NONEXISTENT ASSESSMENT -> DENIED
 * C. Owner A uploads using Family A / Child B / Assessment A -> DENIED
 * D. Owner A uploads Family A / arbitrary UUID child / Assessment A -> DENIED
 * E. Owner B uploads into Family A -> DENIED
 * F. Owner B reads Family A evidence -> DENIED
 * G. Anon reads evidence -> DENIED
 * H. Submit Assessment A, then delete evidence -> DENIED
 * I. Submit Assessment A, then upload additional evidence -> DENIED
 * J. Overwrite / upsert existing evidence -> DENIED
 * K. Public unauthenticated evidence URL -> DENIED
 * L. MIME verification (image/gif, application/pdf, text/plain) -> DENIED
 * M. Oversize upload (> 10 MiB) -> DENIED
 * N. 409 Conflict with matching bytes -> DENIED overwrite, remote bytes verified intact
 * O. 409 Conflict with same-size / different-content bytes -> DENIED overwrite, remote bytes intact
 * P. Revoked actor download -> DENIED
 * Q. Remote storage retention on registration failure -> RETAINED (I04)
 */

import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const API_URL = 'http://127.0.0.1:45321';
const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const JWT_SECRET = 'super-secret-jwt-token-with-at-least-32-characters-long';

const FAMILY_A = 'fa000000-0000-4000-c000-000000000001';
const OWNER_A = 'aa000000-0000-4000-c000-000000000001';
const PARENT_A = 'aa000000-0000-4000-c000-000000000003';
const CHILD_A = 'ca000000-0000-4000-c000-000000000001';
const ASSESSMENT_A = 'ea000000-0000-4000-c000-000000000001';

const FAMILY_B = 'fb000000-0000-4000-c000-000000000002';
const OWNER_B = 'ab000000-0000-4000-c000-000000000002';
const CHILD_B = 'cb000000-0000-4000-c000-000000000002';

const EVIDENCE_ID_1 = crypto.randomUUID();
const EVIDENCE_ID_2 = crypto.randomUUID();
const EVIDENCE_ID_3 = crypto.randomUUID();

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
  console.log('=== LearnWard Full Storage Evidence Security Test ===');
  console.log('Setting up database fixtures for Family A, Family B, and Draft Assessment A...');

  const setupSql = `
    delete from public.assessments where id = '${ASSESSMENT_A}';
    delete from public.child_profiles where id in ('${CHILD_A}', '${CHILD_B}');
    delete from public.families where id in ('${FAMILY_A}', '${FAMILY_B}');
    delete from auth.users where id in ('${OWNER_A}', '${OWNER_B}', '${PARENT_A}');

    insert into auth.users (id, email) values
      ('${OWNER_A}', 'storage_owner_a@example.com'),
      ('${OWNER_B}', 'storage_owner_b@example.com'),
      ('${PARENT_A}', 'storage_parent_a@example.com');

    insert into public.families (id, name, timezone, locale, created_by_user_id) values
      ('${FAMILY_A}', 'Storage Family A', 'UTC', 'en-US', '${OWNER_A}'),
      ('${FAMILY_B}', 'Storage Family B', 'UTC', 'en-US', '${OWNER_B}');

    insert into public.family_memberships (family_id, auth_user_id, role, status) values
      ('${FAMILY_A}', '${OWNER_A}', 'owner', 'active'),
      ('${FAMILY_A}', '${PARENT_A}', 'parent', 'active'),
      ('${FAMILY_B}', '${OWNER_B}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
      ('${CHILD_A}', '${FAMILY_A}', 'Child A', 3, 2017),
      ('${CHILD_B}', '${FAMILY_B}', 'Child B', 4, 2016);

    insert into public.assessments (
      id, family_id, child_id, subject_key, subject, title,
      assessment_type, difficulty, raw_score, max_score,
      status, created_by_user_id
    ) values (
      '${ASSESSMENT_A}', '${FAMILY_A}', '${CHILD_A}', 'math', 'Mathematics', 'Fractions Quiz',
      'quiz', 'normal', 8.0, 10.0,
      'draft', '${OWNER_A}'
    );
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr);
    process.exit(1);
  }
  console.log('Fixtures established: Real Draft Assessment A exists.');

  const tokenA = createJwt(OWNER_A);
  const tokenParentA = createJwt(PARENT_A);
  const tokenB = createJwt(OWNER_B);

  const pathA = `${FAMILY_A}/${CHILD_A}/${ASSESSMENT_A}/${EVIDENCE_ID_1}.jpg`;
  const dummyImageBytes = Buffer.from('FAKE_JPEG_IMAGE_CONTENT');

  // A. Owner A uploads to Family A / Child A / Draft Assessment A -> SUCCESS
  console.log('\n[Test A] Owner A uploads to Family A / Child A / Draft Assessment A...');
  const resA = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (!resA.ok) {
    const errText = await resA.text();
    console.error(`FAIL [Test A]: Upload failed with status ${resA.status}: ${errText}`);
    process.exit(1);
  }
  console.log(`PASS [Test A]: Upload succeeded (HTTP ${resA.status}).`);

  // B. Owner A uploads to Family A / Child A / NONEXISTENT ASSESSMENT -> DENIED
  console.log('\n[Test B] Owner A uploads to NONEXISTENT assessment...');
  const fakeAssessmentId = 'ea000000-0000-4000-c000-999999999999';
  const pathNonexistent = `${FAMILY_A}/${CHILD_A}/${fakeAssessmentId}/${EVIDENCE_ID_2}.jpg`;
  const resB = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathNonexistent}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (resB.ok) {
    console.error('FAIL [Test B]: Upload to nonexistent assessment was allowed!');
    process.exit(1);
  }
  console.log(`PASS [Test B]: Upload to nonexistent assessment denied (HTTP ${resB.status}).`);

  // C. Owner A uploads using Family A / Child B / Assessment A -> DENIED
  console.log('\n[Test C] Owner A uploads using mismatched child (Child B for Assessment A)...');
  const pathWrongChild = `${FAMILY_A}/${CHILD_B}/${ASSESSMENT_A}/${EVIDENCE_ID_2}.jpg`;
  const resC = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathWrongChild}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (resC.ok) {
    console.error('FAIL [Test C]: Upload with mismatched child was allowed!');
    process.exit(1);
  }
  console.log(`PASS [Test C]: Upload with mismatched child denied (HTTP ${resC.status}).`);

  // D. Owner A uploads using Family A / arbitrary UUID child / Assessment A -> DENIED
  console.log('\n[Test D] Owner A uploads using arbitrary UUID child...');
  const arbitraryChild = 'ca000000-0000-4000-c000-888888888888';
  const pathArbitraryChild = `${FAMILY_A}/${arbitraryChild}/${ASSESSMENT_A}/${EVIDENCE_ID_2}.jpg`;
  const resD = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathArbitraryChild}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (resD.ok) {
    console.error('FAIL [Test D]: Upload with arbitrary child UUID was allowed!');
    process.exit(1);
  }
  console.log(`PASS [Test D]: Upload with arbitrary child UUID denied (HTTP ${resD.status}).`);

  // E. Owner B uploads into Family A -> DENIED
  console.log('\n[Test E] Owner B attempts to upload into Family A path...');
  const resE = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${FAMILY_A}/${CHILD_A}/${ASSESSMENT_A}/${EVIDENCE_ID_2}.jpg`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenB}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (resE.ok) {
    console.error('FAIL [Test E]: Cross-family upload by Owner B was allowed!');
    process.exit(1);
  }
  console.log(`PASS [Test E]: Cross-family upload denied (HTTP ${resE.status}).`);

  // F. Owner B reads Family A evidence -> DENIED
  console.log('\n[Test F] Owner B attempts to read Family A evidence...');
  const resF = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenB}`,
    },
  });
  if (resF.ok) {
    console.error('FAIL [Test F]: Cross-family read by Owner B was allowed!');
    process.exit(1);
  }
  console.log(`PASS [Test F]: Cross-family read denied (HTTP ${resF.status}).`);

  // G. Anon reads evidence -> DENIED
  console.log('\n[Test G] Anonymous caller attempts to read Family A evidence...');
  const resG = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
    },
  });
  if (resG.ok) {
    console.error('FAIL [Test G]: Unauthenticated read was allowed!');
    process.exit(1);
  }
  console.log(`PASS [Test G]: Unauthenticated read denied (HTTP ${resG.status}).`);

  // J. Evidence overwrite / upsert attempt -> DENIED
  console.log('\n[Test J] Overwrite / upsert attempt on existing evidence object...');
  const resJ = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    method: 'PUT',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: Buffer.from('MUTATED_BYTES'),
  });
  if (resJ.ok) {
    console.error('FAIL [Test J]: Evidence overwrite was allowed!');
    process.exit(1);
  }
  console.log(`PASS [Test J]: Overwrite / upsert attempt denied (HTTP ${resJ.status}).`);

  // K. Public unauthenticated evidence URL -> DENIED
  console.log('\n[Test K] Public URL retrieve on private bucket...');
  const resK = await fetch(`${API_URL}/storage/v1/object/public/assessment-evidence/${pathA}`);
  if (resK.ok) {
    console.error('FAIL [Test K]: Public unauthenticated URL succeeded on private bucket!');
    process.exit(1);
  }
  console.log(`PASS [Test K]: Public URL access denied (HTTP ${resK.status}).`);

  // L. MIME verification (disallowed types) -> DENIED
  console.log('\n[Test L] Uploads with disallowed MIME types (image/gif, application/pdf, text/plain)...');
  for (const mime of ['image/gif', 'application/pdf', 'text/plain']) {
    const resMime = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${FAMILY_A}/${CHILD_A}/${ASSESSMENT_A}/${crypto.randomUUID()}.jpg`, {
      method: 'POST',
      headers: {
        'apikey': ANON_KEY,
        'Authorization': `Bearer ${tokenA}`,
        'Content-Type': mime,
      },
      body: dummyImageBytes,
    });
    if (resMime.ok) {
      console.error(`FAIL [Test L]: Upload with disallowed MIME ${mime} succeeded!`);
      process.exit(1);
    }
  }
  console.log('PASS [Test L]: Disallowed MIME types rejected.');

  // M. Oversize upload (> 10 MiB) -> DENIED
  console.log('\n[Test M] Oversize upload (> 10 MiB)...');
  const oversizeBytes = Buffer.alloc(10485760 + 1024, 0x42);
  const resM = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${FAMILY_A}/${CHILD_A}/${ASSESSMENT_A}/${crypto.randomUUID()}.jpg`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: oversizeBytes,
  });
  if (resM.ok) {
    console.error('FAIL [Test M]: Oversize upload was allowed!');
    process.exit(1);
  }
  console.log(`PASS [Test M]: Oversize upload denied (HTTP ${resM.status}).`);

  // N. 409 Conflict with matching bytes -> DENIED overwrite, remote bytes verified intact
  console.log('\n[Test N] 409 Conflict with matching bytes on duplicate upload...');
  const resN = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (resN.ok) {
    console.error('FAIL [Test N]: Duplicate upload unexpectedly succeeded without conflict!');
    process.exit(1);
  }
  const textN = await resN.text();
  const isConflictN = resN.status === 409 || (resN.status === 400 && (textN.includes('already exists') || textN.includes('Duplicate') || textN.includes('409')));
  if (!isConflictN) {
    console.error(`FAIL [Test N]: Expected conflict status (409 or 400 duplicate), got HTTP ${resN.status}: ${textN}`);
    process.exit(1);
  }
  const dlResN = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
    },
  });
  if (!dlResN.ok) {
    console.error(`FAIL [Test N]: Download of existing evidence failed: ${dlResN.status}`);
    process.exit(1);
  }
  const dlBytesN = Buffer.from(await dlResN.arrayBuffer());
  if (!dlBytesN.equals(dummyImageBytes)) {
    console.error('FAIL [Test N]: Downloaded bytes do not match expected dummyImageBytes!');
    process.exit(1);
  }
  console.log(`PASS [Test N]: Duplicate upload rejected with conflict (${resN.status}) and remote bytes verified intact.`);

  // O. 409 Conflict with same-size / different-content bytes -> DENIED overwrite, remote bytes intact
  console.log('\n[Test O] 409 Conflict with same-size / different-content bytes...');
  const mutatedSameSizeBytes = Buffer.alloc(dummyImageBytes.length, 0x5a); // Same length, all 'Z'
  const resO = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: mutatedSameSizeBytes,
  });
  if (resO.ok) {
    console.error('FAIL [Test O]: Mutated same-size upload unexpectedly succeeded!');
    process.exit(1);
  }
  const textO = await resO.text();
  const isConflictO = resO.status === 409 || (resO.status === 400 && (textO.includes('already exists') || textO.includes('Duplicate') || textO.includes('409')));
  if (!isConflictO) {
    console.error(`FAIL [Test O]: Expected conflict status, got HTTP ${resO.status}: ${textO}`);
    process.exit(1);
  }
  const dlResO = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
    },
  });
  if (!dlResO.ok) {
    console.error(`FAIL [Test O]: Download after failed mutate upload failed: ${dlResO.status}`);
    process.exit(1);
  }
  const dlBytesO = Buffer.from(await dlResO.arrayBuffer());
  if (!dlBytesO.equals(dummyImageBytes)) {
    console.error('FAIL [Test O]: Remote bytes altered after conflict upload!');
    process.exit(1);
  }
  if (dlBytesO.equals(mutatedSameSizeBytes)) {
    console.error('FAIL [Test O]: Remote bytes were overwritten with mutated bytes!');
    process.exit(1);
  }
  console.log(`PASS [Test O]: Same-size conflict upload rejected (${resO.status}) and original bytes preserved.`);

  // P. Revoked actor download -> DENIED
  console.log('\n[Test P] Revoked actor download denial...');
  // First verify active adult member (PARENT_A) can download evidence
  const resPActive = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenParentA}`,
    },
  });
  if (!resPActive.ok) {
    console.error(`FAIL [Test P]: Active adult member initial download failed: ${resPActive.status}`);
    process.exit(1);
  }
  console.log('PASS [Test P]: Active adult member successfully downloads evidence.');

  // Revoke membership for PARENT_A
  const revokeRes = await runPsql(`update public.family_memberships set status = 'revoked' where family_id = '${FAMILY_A}' and auth_user_id = '${PARENT_A}';`);
  if (revokeRes.code !== 0) {
    console.error('FAIL [Test P]: Failed to update membership status to revoked:', revokeRes.stderr);
    process.exit(1);
  }

  // Attempt download as revoked actor -> DENIED
  const resP = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenParentA}`,
    },
  });
  if (resP.ok) {
    console.error('FAIL [Test P]: Revoked member was able to download evidence!');
    process.exit(1);
  }
  console.log(`PASS [Test P]: Revoked member download denied (HTTP ${resP.status}).`);

  // Restore active membership
  await runPsql(`update public.family_memberships set status = 'active' where family_id = '${FAMILY_A}' and auth_user_id = '${PARENT_A}';`);
  const resPRestored = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenParentA}`,
    },
  });
  if (!resPRestored.ok) {
    console.error(`FAIL [Test P]: Restored active member download failed: ${resPRestored.status}`);
    process.exit(1);
  }
  console.log('PASS [Test P]: Restored active member download succeeds.');

  // Q. Remote storage retention on registration failure (I04)
  console.log('\n[Test Q] Remote storage retention on registration failure (I04)...');
  const pathQ = `${FAMILY_A}/${CHILD_A}/${ASSESSMENT_A}/${EVIDENCE_ID_3}.jpg`;
  const resQUpload = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathQ}`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (!resQUpload.ok) {
    console.error(`FAIL [Test Q]: Initial upload for pathQ failed: ${resQUpload.status}`);
    process.exit(1);
  }
  console.log('Evidence uploaded for pathQ while assessment is draft.');

  // Advance Assessment A status to pending_review
  console.log('\nTransitioning Assessment A to pending_review...');
  await runPsql(`update public.assessments set status = 'pending_review' where id = '${ASSESSMENT_A}';`);

  // Attempt registration on non-draft assessment -> must fail with LW109
  const resQReg = await fetch(`${API_URL}/rest/v1/rpc/register_assessment_evidence`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_assessment_id: ASSESSMENT_A,
      p_storage_path: pathQ,
      p_media_type: 'image/jpeg',
      p_file_size_bytes: dummyImageBytes.length,
    }),
  });
  if (resQReg.ok) {
    console.error('FAIL [Test Q]: Registration unexpectedly succeeded on non-draft assessment!');
    process.exit(1);
  }
  const textQReg = await resQReg.text();
  if (!textQReg.includes('LW109')) {
    console.error(`FAIL [Test Q]: Expected LW109 from register_assessment_evidence, got: ${textQReg}`);
    process.exit(1);
  }
  console.log(`PASS [Test Q]: Evidence registration rejected on non-draft assessment with LW109 (HTTP ${resQReg.status}).`);

  // Verify remote storage bytes are retained and readable (I04)
  const resQCheck = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathQ}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
    },
  });
  if (!resQCheck.ok) {
    console.error(`FAIL [Test Q]: Remote evidence was deleted or unreadable after registration failure! Status: ${resQCheck.status}`);
    process.exit(1);
  }
  const retainedBytes = Buffer.from(await resQCheck.arrayBuffer());
  if (!retainedBytes.equals(dummyImageBytes)) {
    console.error('FAIL [Test Q]: Retained bytes do not match uploaded dummyImageBytes!');
    process.exit(1);
  }
  console.log('PASS [Test Q]: Remote evidence retained and intact after registration failure (I04).');

  // Verify no DB evidence row exists for pathQ
  const countQ = await runPsql(`select count(*) from public.assessment_evidence where storage_path = '${pathQ}';`);
  if (!countQ.stdout.includes('0')) {
    console.error(`FAIL [Test Q]: Database evidence row exists despite registration failure: ${countQ.stdout}`);
    process.exit(1);
  }
  console.log('PASS [Test Q]: Zero evidence rows recorded in database.');

  // H. Submit Assessment A then delete evidence -> DENIED
  console.log('\n[Test H] Delete evidence after submission (pending_review status)...');
  const resH = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    method: 'DELETE',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
    },
  });
  if (resH.ok) {
    console.error('FAIL [Test H]: Evidence delete was allowed after assessment was submitted!');
    process.exit(1);
  }
  console.log(`PASS [Test H]: Evidence delete denied after submit (HTTP ${resH.status}).`);

  // I. Submit Assessment A then upload additional evidence -> DENIED
  console.log('\n[Test I] Upload evidence after submission (pending_review status)...');
  const resI = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${FAMILY_A}/${CHILD_A}/${ASSESSMENT_A}/${EVIDENCE_ID_2}.jpg`, {
    method: 'POST',
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
      'Content-Type': 'image/jpeg',
    },
    body: dummyImageBytes,
  });
  if (resI.ok) {
    console.error('FAIL [Test I]: Upload was allowed after assessment was submitted!');
    process.exit(1);
  }
  console.log(`PASS [Test I]: Upload denied after submit (HTTP ${resI.status}).`);

  // Cleanup Tests A-Q fixtures before isolated WP5 Extensions R, S, T
  console.log('\nCleaning up Tests A-Q fixtures...');
  await runPsql(`
    delete from public.assessments where id = '${ASSESSMENT_A}';
    delete from public.child_profiles where id in ('${CHILD_A}', '${CHILD_B}');
    delete from public.families where id in ('${FAMILY_A}', '${FAMILY_B}');
    delete from auth.users where id in ('${OWNER_A}', '${OWNER_B}', '${PARENT_A}');
  `);

  // -------------------------------------------------------------------------
  // WP5 Real-Backend Extensions: Tests S, R, T (B1-02, B1-05, B1-12, B1-13, B1-15, B1-17, B1-19, B1-20, B1-29)
  // Using isolated randomUUID() tenancy because assessments/receipts/review_events have immutability triggers.
  // -------------------------------------------------------------------------
  const FAMILY_ST = crypto.randomUUID();
  const OWNER_ST = crypto.randomUUID();
  const PARENT_ST = crypto.randomUUID();
  const CHILD_ST = crypto.randomUUID();
  const FAMILY_B_ST = crypto.randomUUID();
  const OWNER_B_ST = crypto.randomUUID();

  const stSetup = await runPsql(`
    insert into auth.users (id, email) values
      ('${OWNER_ST}', 'wp5_owner_${OWNER_ST}@example.com'),
      ('${PARENT_ST}', 'wp5_parent_${PARENT_ST}@example.com'),
      ('${OWNER_B_ST}', 'wp5_foreign_${OWNER_B_ST}@example.com');

    insert into public.families (id, name, timezone, locale, created_by_user_id) values
      ('${FAMILY_ST}', 'WP5 Security Family', 'UTC', 'en-US', '${OWNER_ST}'),
      ('${FAMILY_B_ST}', 'WP5 Foreign Family', 'UTC', 'en-US', '${OWNER_B_ST}');

    insert into public.family_memberships (family_id, auth_user_id, role, status) values
      ('${FAMILY_ST}', '${OWNER_ST}', 'owner', 'active'),
      ('${FAMILY_ST}', '${PARENT_ST}', 'parent', 'active'),
      ('${FAMILY_B_ST}', '${OWNER_B_ST}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
      ('${CHILD_ST}', '${FAMILY_ST}', 'WP5 Child', 4, 2016);
  `);
  if (stSetup.code !== 0) {
    console.error('FAIL: WP5 R/S/T fixture setup failed:', stSetup.stderr);
    process.exit(1);
  }

  const tokenStOwner = createJwt(OWNER_ST);
  const tokenStParent = createJwt(PARENT_ST);
  const tokenStForeign = createJwt(OWNER_B_ST);

  // S. PNG upload + DB-generated serverEvidenceId != evidenceId + LW109 read-only reconciliation
  console.log('\n[Test S] PNG evidence registration, DB-generated serverEvidenceId, and LW109 read-only reconciliation...');
  const CMD_CREATE_PNG = crypto.randomUUID();
  const CMD_SUBMIT_PNG = crypto.randomUUID();
  const CLIENT_PNG_EVIDENCE_ID = crypto.randomUUID();
  const pngBytes = Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x42, 0x43, 0x44, 0x45,
  ]);
  const expectedPngSha = crypto.createHash('sha256').update(pngBytes).digest('hex');

  const createPngRes = await fetch(`${API_URL}/rest/v1/rpc/create_assessment_draft`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      p_command_id: CMD_CREATE_PNG,
      p_family_id: FAMILY_ST,
      p_child_id: CHILD_ST,
      p_subject_key: 'math',
      p_subject: 'Mathematics',
      p_title: 'WP5 PNG Evidence Test',
      p_assessment_type: 'quiz',
      p_difficulty: 'normal',
      p_raw_score: 9.0,
      p_max_score: 10.0,
      p_entry_context: 'adult',
    }),
  });
  if (!createPngRes.ok) {
    console.error('FAIL [Test S]: create_assessment_draft failed:', await createPngRes.text());
    process.exit(1);
  }
  const pngDraft = await createPngRes.json();
  const pngAssessmentId = pngDraft.id;
  const pngPath = `${FAMILY_ST}/${CHILD_ST}/${pngAssessmentId}/${CLIENT_PNG_EVIDENCE_ID}.png`;

  const uploadPngRes = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pngPath}`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}`, 'Content-Type': 'image/png', 'x-upsert': 'false' },
    body: pngBytes,
  });
  if (!uploadPngRes.ok) {
    console.error('FAIL [Test S]: PNG Storage upload failed:', await uploadPngRes.text());
    process.exit(1);
  }

  const regPngRes = await fetch(`${API_URL}/rest/v1/rpc/register_assessment_evidence`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      p_assessment_id: pngAssessmentId,
      p_storage_path: pngPath,
      p_media_type: 'image/png',
      p_file_size_bytes: pngBytes.length,
    }),
  });
  if (!regPngRes.ok) {
    console.error('FAIL [Test S]: register_assessment_evidence for PNG failed:', await regPngRes.text());
    process.exit(1);
  }
  const regPngRow = await regPngRes.json();
  if (!regPngRow.id || regPngRow.id === CLIENT_PNG_EVIDENCE_ID) {
    console.error('FAIL [Test S]: Expected DB-generated serverEvidenceId != client evidenceId!', regPngRow);
    process.exit(1);
  }

  // Idempotent register while still draft returns exact same row id
  const regPngIdempotent = await fetch(`${API_URL}/rest/v1/rpc/register_assessment_evidence`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      p_assessment_id: pngAssessmentId,
      p_storage_path: pngPath,
      p_media_type: 'image/png',
      p_file_size_bytes: pngBytes.length,
    }),
  });
  const regPngRow2 = await regPngIdempotent.json();
  if (regPngRow2.id !== regPngRow.id) {
    console.error('FAIL [Test S]: Idempotent registration changed row.id!');
    process.exit(1);
  }

  // Submit assessment to leave draft -> subsequent register returns LW109 -> read-only GET + byte SHA reconcile passes
  const submitPngRes = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_assessment_id: pngAssessmentId, p_expected_version: 1, p_command_id: CMD_SUBMIT_PNG }),
  });
  if (!submitPngRes.ok) {
    console.error('FAIL [Test S]: submit_assessment failed:', await submitPngRes.text());
    process.exit(1);
  }
  const lw109Res = await fetch(`${API_URL}/rest/v1/rpc/register_assessment_evidence`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      p_assessment_id: pngAssessmentId,
      p_storage_path: pngPath,
      p_media_type: 'image/png',
      p_file_size_bytes: pngBytes.length,
    }),
  });
  const lw109Text = await lw109Res.text();
  if (lw109Res.ok || !lw109Text.includes('LW109')) {
    console.error('FAIL [Test S]: Expected LW109 on post-submit register call, got:', lw109Res.status, lw109Text);
    process.exit(1);
  }
  const listEvRes = await fetch(`${API_URL}/rest/v1/assessment_evidence?assessment_id=eq.${pngAssessmentId}`, {
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}` },
  });
  const listEvRows = await listEvRes.json();
  if (listEvRows.length !== 1 || listEvRows[0].id !== regPngRow.id || listEvRows[0].media_type !== 'image/png' || listEvRows[0].file_size_bytes !== pngBytes.length) {
    console.error('FAIL [Test S]: Read-only evidence row reconciliation mismatch:', listEvRows);
    process.exit(1);
  }
  const dlPngRes = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pngPath}`, {
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}` },
  });
  const dlPngBuf = Buffer.from(await dlPngRes.arrayBuffer());
  const actualPngSha = crypto.createHash('sha256').update(dlPngBuf).digest('hex');
  if (actualPngSha !== expectedPngSha || !dlPngBuf.equals(pngBytes)) {
    console.error('FAIL [Test S]: PNG Storage byte SHA-256 verification failed!');
    process.exit(1);
  }
  console.log(`PASS [Test S]: PNG stored (serverEvidenceId=${regPngRow.id} != client=${CLIENT_PNG_EVIDENCE_ID}), LW109 reconciled read-only, SHA-256 verified.`);

  // R. PostgREST RLS-null verification (foreign adult and revoked adult receive 200 [])
  console.log('\n[Test R] PostgREST RLS-null reads for foreign & revoked actors...');
  const rlsForeignAssess = await fetch(`${API_URL}/rest/v1/assessments?id=eq.${pngAssessmentId}`, {
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStForeign}` },
  });
  const rlsForeignEv = await fetch(`${API_URL}/rest/v1/assessment_evidence?assessment_id=eq.${pngAssessmentId}`, {
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStForeign}` },
  });
  if (!rlsForeignAssess.ok || !rlsForeignEv.ok) {
    console.error('FAIL [Test R]: Unexpected HTTP error on foreign RLS SELECT');
    process.exit(1);
  }
  const foreignAssessRows = await rlsForeignAssess.json();
  const foreignEvRows = await rlsForeignEv.json();
  if (foreignAssessRows.length !== 0 || foreignEvRows.length !== 0) {
    console.error('FAIL [Test R]: Foreign actor observed WP5 family rows via PostgREST!');
    process.exit(1);
  }

  // Revoke PARENT_ST and verify RLS returns [] while OWNER_ST still sees intact assessment + evidence
  await runPsql(`update public.family_memberships set status = 'revoked' where family_id = '${FAMILY_ST}' and auth_user_id = '${PARENT_ST}';`);
  const rlsRevokedAssess = await fetch(`${API_URL}/rest/v1/assessments?id=eq.${pngAssessmentId}`, {
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStParent}` },
  });
  const revokedAssessRows = await rlsRevokedAssess.json();
  if (revokedAssessRows.length !== 0) {
    console.error('FAIL [Test R]: Revoked member observed WP5 assessment via PostgREST!');
    process.exit(1);
  }
  const ownerCheckAssess = await fetch(`${API_URL}/rest/v1/assessments?id=eq.${pngAssessmentId}`, {
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}` },
  });
  const ownerCheckEv = await fetch(`${API_URL}/rest/v1/assessment_evidence?assessment_id=eq.${pngAssessmentId}`, {
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}` },
  });
  const ownerAssessRows = await ownerCheckAssess.json();
  const ownerEvRows = await ownerCheckEv.json();
  if (ownerAssessRows.length !== 1 || ownerEvRows.length !== 1) {
    console.error('FAIL [Test R]: RLS-null test corrupted owner visibility!');
    process.exit(1);
  }
  await runPsql(`update public.family_memberships set status = 'active' where family_id = '${FAMILY_ST}' and auth_user_id = '${PARENT_ST}';`);
  console.log('PASS [Test R]: PostgREST RLS returns [] for foreign/revoked callers while retaining real rows & bytes.');

  // T. Real Postgres submit_assessment execution order & 42501 ambiguity proof
  console.log('\n[Test T] Real Postgres submit_assessment SQL execution order (Step 3, Step 4, Step 6)...');
  // T.1: Second adult (PARENT_ST) replaying OWNER_ST's committed submitCommandId is rejected at Step 6 with 42501
  const t1Res = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStParent}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_assessment_id: pngAssessmentId, p_expected_version: 1, p_command_id: CMD_SUBMIT_PNG }),
  });
  const t1Err = await t1Res.json();
  if (t1Res.ok || t1Err.code !== '42501') {
    console.error('FAIL [Test T.1]: Expected 42501 on foreign adult command replay, got:', t1Res.status, t1Err);
    process.exit(1);
  }
  console.log(`PASS [Test T.1]: Foreign adult replay of OWNER submitCommandId rejected at Step 6 (${t1Err.code}).`);

  // T.2: Revoking PARENT_ST AFTER PARENT_ST's submit_assessment committed triggers Step 3 42501 before Step 6 receipt check
  const CMD_CREATE_P = crypto.randomUUID();
  const CMD_SUBMIT_P = crypto.randomUUID();
  const createPRes = await fetch(`${API_URL}/rest/v1/rpc/create_assessment_draft`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStParent}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      p_command_id: CMD_CREATE_P,
      p_family_id: FAMILY_ST,
      p_child_id: CHILD_ST,
      p_subject_key: 'science',
      p_subject: 'Science',
      p_title: 'Parent ST Submit Then Revoke',
      p_assessment_type: 'quiz',
      p_difficulty: 'normal',
      p_raw_score: 10.0,
      p_max_score: 10.0,
      p_entry_context: 'adult',
    }),
  });
  const draftP = await createPRes.json();
  const submitPRes = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStParent}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_assessment_id: draftP.id, p_expected_version: 1, p_command_id: CMD_SUBMIT_P }),
  });
  if (!submitPRes.ok) {
    console.error('FAIL [Test T.2]: PARENT_ST submit failed:', await submitPRes.text());
    process.exit(1);
  }
  await runPsql(`update public.family_memberships set status = 'revoked' where family_id = '${FAMILY_ST}' and auth_user_id = '${PARENT_ST}';`);
  const t2Res = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStParent}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_assessment_id: draftP.id, p_expected_version: 1, p_command_id: CMD_SUBMIT_P }),
  });
  const t2Err = await t2Res.json();
  if (t2Res.ok || t2Err.code !== '42501') {
    console.error('FAIL [Test T.2]: Expected Step 3 42501 ambiguity for revoked original actor, got:', t2Res.status, t2Err);
    process.exit(1);
  }
  console.log(`PASS [Test T.2]: Revoked actor replay hits Step 3 42501 despite committed receipt (ambiguous 42501 proven).`);

  // T.3: Archiving CHILD_ST AFTER submit_assessment committed triggers Step 4 42501 before Step 6 receipt check
  const archiveRes = await fetch(`${API_URL}/rest/v1/rpc/archive_child_profile`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_child_id: CHILD_ST }),
  });
  if (!archiveRes.ok) {
    console.error('FAIL [Test T.3]: archive_child_profile failed:', await archiveRes.text());
    process.exit(1);
  }
  const t3Res = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: { 'apikey': ANON_KEY, 'Authorization': `Bearer ${tokenStOwner}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_assessment_id: pngAssessmentId, p_expected_version: 1, p_command_id: CMD_SUBMIT_PNG }),
  });
  const t3Err = await t3Res.json();
  if (t3Res.ok || t3Err.code !== '42501' || !String(t3Err.message || '').includes('archived')) {
    console.error('FAIL [Test T.3]: Expected Step 4 42501 archived-child error before Step 6 receipt check, got:', t3Res.status, t3Err);
    process.exit(1);
  }
  // Confirm committed rows and PNG object remain intact in Postgres/Storage
  const dbVerifyT3 = await runPsql(`select a.status || ':' || (select count(*) from public.command_receipts r where r.command_id = '${CMD_SUBMIT_PNG}') || ':' || (select count(*) from storage.objects o where o.name = '${pngPath}') as proof from public.assessments a where a.id = '${pngAssessmentId}';`);
  if (!dbVerifyT3.stdout.includes('pending_review:1:1')) {
    console.error('FAIL [Test T.3]: Committed assessment/receipt/object state was lost:', dbVerifyT3.stdout);
    process.exit(1);
  }
  console.log(`PASS [Test T.3]: Archived child replay hits Step 4 42501 while pending_review:1:1 remains intact.`);

  console.log('=== All Storage Evidence Security Tests A-T PASSED ===\n');
}

main().catch((err) => {
  console.error('Unexpected error:', err);
  process.exit(1);
});
