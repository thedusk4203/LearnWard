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
  await runPsql(`update public.family_memberships set status = 'revoked' where family_id = '${FAMILY_A}' and auth_user_id = '${OWNER_A}';`);
  const resP = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
    },
  });
  if (resP.ok) {
    console.error('FAIL [Test P]: Revoked member was able to download evidence!');
    process.exit(1);
  }
  console.log(`PASS [Test P]: Revoked member download denied (HTTP ${resP.status}).`);

  // Restore active membership
  await runPsql(`update public.family_memberships set status = 'active' where family_id = '${FAMILY_A}' and auth_user_id = '${OWNER_A}';`);
  const resPRestored = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${pathA}`, {
    headers: {
      'apikey': ANON_KEY,
      'Authorization': `Bearer ${tokenA}`,
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

  // Cleanup
  console.log('\nCleaning up storage and database...');
  await runPsql(`
    delete from public.assessments where id = '${ASSESSMENT_A}';
    delete from public.child_profiles where id in ('${CHILD_A}', '${CHILD_B}');
    delete from public.families where id in ('${FAMILY_A}', '${FAMILY_B}');
    delete from auth.users where id in ('${OWNER_A}', '${OWNER_B}');
  `);

  console.log('=== All Storage Evidence Security Tests A-Q PASSED ===\n');
}

main().catch((err) => {
  console.error('Unexpected error:', err);
  process.exit(1);
});
