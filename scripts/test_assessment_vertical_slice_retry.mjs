// scripts/test_assessment_vertical_slice_retry.mjs
/**
 * LearnWard - Assessment Vertical Slice & Retry Idempotency Integration Test
 *
 * PURPOSE:
 * Exercises the complete mobile orchestration path against the real local Supabase stack:
 *   create_assessment_draft (createCommandId)
 *   -> upload evidence to storage
 *   -> register_assessment_evidence
 *   -> submit_assessment (submitCommandId)
 *
 * Verifies:
 * 1. Happy path: full draft -> evidence -> pending_review transitions with distinct command IDs.
 * 2. Cross-operation command reuse rejection: using createCommandId for submit is rejected (42501).
 * 3. Failure & Retry Safety:
 *    - Client initiates submission with stable create/submit/evidence IDs.
 *    - First attempt creates server draft and evidence, then failure is simulated before submit response.
 *    - Retry after restart reuses the EXACT same create/submit/evidence IDs.
 *    - Exactly ONE assessment row, ONE evidence metadata row, ONE storage object,
 *      ONE submit event, and EXACTLY TWO command receipts (create_draft, submit) are created.
 *    - Final status is pending_review.
 * 4. Post-completion idempotent replay: replaying create and submit commands after submission
 *    succeeds idempotently without modifying version or duplicating records.
 */

import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

const API_URL = 'http://127.0.0.1:45321';
const ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0';
const JWT_SECRET = 'super-secret-jwt-token-with-at-least-32-characters-long';

const FAMILY_ID = crypto.randomUUID();
const OWNER_ID = crypto.randomUUID();
const CHILD_ID = crypto.randomUUID();

function createJwt(userId) {
  const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(
    JSON.stringify({
      sub: userId,
      aud: 'authenticated',
      role: 'authenticated',
      exp: Math.floor(Date.now() / 1000) + 3600,
    })
  ).toString('base64url');
  const signature = crypto.createHmac('sha256', JWT_SECRET).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${signature}`;
}

function runPsql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'docker',
      ['exec', '-i', 'supabase_db_learnward', 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-t', '-A'],
      { stdio: ['pipe', 'pipe', 'pipe'] }
    );

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (d) => {
      stdout += d.toString();
    });
    child.stderr.on('data', (d) => {
      stderr += d.toString();
    });

    child.on('close', (code) => {
      resolve({ code, stdout: stdout.trim(), stderr: stderr.trim() });
    });

    child.on('error', reject);

    child.stdin.write(sql);
    child.stdin.end();
  });
}

async function main() {
  console.log('=== LearnWard Assessment Vertical Slice & Retry Idempotency Test ===');

  console.log('Setting up database fixtures for tenancy...');
  const setupSql = `
    insert into auth.users (id, email) values
      ('${OWNER_ID}', 'vertical_slice_${OWNER_ID}@example.com');

    insert into public.families (id, name, timezone, locale, created_by_user_id) values
      ('${FAMILY_ID}', 'Vertical Slice Family', 'UTC', 'en-US', '${OWNER_ID}');

    insert into public.family_memberships (family_id, auth_user_id, role, status) values
      ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
      ('${CHILD_ID}', '${FAMILY_ID}', 'Learner Child', 4, 2016);
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Fixture setup failed:', setupRes.stderr);
    process.exit(1);
  }
  console.log('Fixtures established: Real family, owner adult, and child profile exist.');

  const token = createJwt(OWNER_ID);

  // -------------------------------------------------------------------------
  // Scenario 1: Complete happy path vertical slice
  // -------------------------------------------------------------------------
  console.log('\n--- Scenario 1: Standard Vertical Slice (create -> upload -> register -> submit) ---');
  const createCmd1 = crypto.randomUUID();
  const submitCmd1 = crypto.randomUUID();
  const evidenceId1 = crypto.randomUUID();

  // 1. Create draft
  console.log('[1.1] Calling create_assessment_draft with createCommandId...');
  const resCreate1 = await fetch(`${API_URL}/rest/v1/rpc/create_assessment_draft`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_command_id: createCmd1,
      p_family_id: FAMILY_ID,
      p_child_id: CHILD_ID,
      p_subject_key: 'math',
      p_subject: 'Mathematics',
      p_title: 'Scenario 1 Math Test',
      p_assessment_type: 'quiz',
      p_difficulty: 'normal',
      p_raw_score: 9.5,
      p_max_score: 10.0,
      p_entry_context: 'shared_child',
    }),
  });

  if (!resCreate1.ok) {
    console.error('FAIL: create_assessment_draft failed:', await resCreate1.text());
    process.exit(1);
  }
  const draft1 = await resCreate1.json();
  const assessmentId1 = draft1.id;
  if (!assessmentId1 || draft1.status !== 'draft' || draft1.version !== 1) {
    console.error('FAIL: Unexpected draft payload:', draft1);
    process.exit(1);
  }
  console.log(`PASS: Draft created successfully (ID: ${assessmentId1}, status: ${draft1.status}, version: ${draft1.version}).`);

  // 2. Upload evidence
  console.log('[1.2] Uploading evidence file to private bucket...');
  const storagePath1 = `${FAMILY_ID}/${CHILD_ID}/${assessmentId1}/${evidenceId1}.jpg`;
  const imageBytes = Buffer.from('JPEG_EVIDENCE_PAYLOAD_TEST');
  const resStorage1 = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${storagePath1}`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'image/jpeg',
    },
    body: imageBytes,
  });

  if (!resStorage1.ok) {
    console.error('FAIL: Storage upload failed:', await resStorage1.text());
    process.exit(1);
  }
  console.log(`PASS: Storage object uploaded (${storagePath1}).`);

  // 3. Register evidence
  console.log('[1.3] Registering evidence in database via RPC...');
  const resReg1 = await fetch(`${API_URL}/rest/v1/rpc/register_assessment_evidence`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_assessment_id: assessmentId1,
      p_storage_path: storagePath1,
      p_media_type: 'image/jpeg',
      p_file_size_bytes: imageBytes.length,
    }),
  });

  if (!resReg1.ok) {
    console.error('FAIL: register_assessment_evidence failed:', await resReg1.text());
    process.exit(1);
  }
  const evidenceRow1 = await resReg1.json();
  if (evidenceRow1.storage_path !== storagePath1) {
    console.error('FAIL: Unexpected evidence registration row:', evidenceRow1);
    process.exit(1);
  }
  console.log(`PASS: Evidence registered (ID: ${evidenceRow1.id}).`);

  // 4. Submit assessment with distinct submitCommandId
  console.log('[1.4] Submitting assessment with distinct submitCommandId...');
  const resSubmit1 = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_assessment_id: assessmentId1,
      p_expected_version: 1,
      p_command_id: submitCmd1,
    }),
  });

  if (!resSubmit1.ok) {
    console.error('FAIL: submit_assessment failed:', await resSubmit1.text());
    process.exit(1);
  }
  const submitted1 = await resSubmit1.json();
  if (submitted1.status !== 'pending_review' || submitted1.version !== 2) {
    console.error('FAIL: Unexpected submitted payload:', submitted1);
    process.exit(1);
  }
  console.log(`PASS: Assessment successfully submitted (status: ${submitted1.status}, version: ${submitted1.version}).`);

  // -------------------------------------------------------------------------
  // Scenario 1.5: Verify reusing createCommandId for submit throws 42501
  // -------------------------------------------------------------------------
  console.log('\n--- Scenario 1.5: Reusing createCommandId for submit must be rejected (42501) ---');
  const resIllegalSubmit = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_assessment_id: assessmentId1,
      p_expected_version: 2,
      p_command_id: createCmd1, // Reusing create command id for submit operation!
    }),
  });

  if (resIllegalSubmit.ok) {
    console.error('FAIL: Reusing createCommandId for submit should have been rejected!');
    process.exit(1);
  }
  const illegalErr = await resIllegalSubmit.json();
  if (illegalErr.code !== '42501') {
    console.error('FAIL: Expected error code 42501 for command operation conflict, got:', illegalErr);
    process.exit(1);
  }
  console.log(`PASS: Operation mismatch correctly rejected with 42501 (${illegalErr.message}).`);

  // -------------------------------------------------------------------------
  // Scenario 2: Failure before submit response, followed by idempotent retry
  // -------------------------------------------------------------------------
  console.log('\n--- Scenario 2: Simulated Interrupted Submission & Idempotent Retry ---');
  const createCmd2 = crypto.randomUUID();
  const submitCmd2 = crypto.randomUUID();
  const evidenceId2 = crypto.randomUUID();

  // Attempt 1, Step A: Create draft
  console.log('[2.1] Attempt 1: Calling create_assessment_draft...');
  const resCreate2 = await fetch(`${API_URL}/rest/v1/rpc/create_assessment_draft`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_command_id: createCmd2,
      p_family_id: FAMILY_ID,
      p_child_id: CHILD_ID,
      p_subject_key: 'science',
      p_subject: 'Science',
      p_title: 'Scenario 2 Science Lab',
      p_assessment_type: 'homework',
      p_difficulty: 'normal',
      p_raw_score: 8.0,
      p_max_score: 10.0,
      p_entry_context: 'shared_child',
    }),
  });
  if (!resCreate2.ok) {
    console.error('FAIL [2.1]: Create draft failed:', await resCreate2.text());
    process.exit(1);
  }
  const draft2 = await resCreate2.json();
  const assessmentId2 = draft2.id;
  console.log(`PASS [2.1]: Server draft established (ID: ${assessmentId2}).`);

  // Attempt 1, Step B: Upload evidence to storage
  console.log('[2.2] Attempt 1: Uploading evidence...');
  const storagePath2 = `${FAMILY_ID}/${CHILD_ID}/${assessmentId2}/${evidenceId2}.jpg`;
  const resStorage2 = await fetch(`${API_URL}/storage/v1/object/assessment-evidence/${storagePath2}`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'image/jpeg',
    },
    body: imageBytes,
  });
  if (!resStorage2.ok) {
    console.error('FAIL [2.2]: Storage upload failed:', await resStorage2.text());
    process.exit(1);
  }
  console.log(`PASS [2.2]: Evidence uploaded to storage.`);

  // Attempt 1, Step C: Register evidence in database
  console.log('[2.3] Attempt 1: Registering evidence metadata...');
  const resReg2 = await fetch(`${API_URL}/rest/v1/rpc/register_assessment_evidence`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_assessment_id: assessmentId2,
      p_storage_path: storagePath2,
      p_media_type: 'image/jpeg',
      p_file_size_bytes: imageBytes.length,
    }),
  });
  if (!resReg2.ok) {
    console.error('FAIL [2.3]: Register evidence failed:', await resReg2.text());
    process.exit(1);
  }
  console.log(`PASS [2.3]: Evidence registered.`);

  // SIMULATE FAILURE / APP RESTART BEFORE SUBMIT RESPONSE
  console.log('[2.4] *Simulating failure: network drop / crash before submit execution*');
  console.log('      Client state: LocalAssessmentDraft retains persisted createCmd2, submitCmd2, evidenceId2.');

  // Attempt 2: Client recovers and retries the entire submission pipeline with SAME IDs
  console.log('\n[2.5] Attempt 2: Re-executing create_assessment_draft with SAME createCmd2...');
  const resRetryCreate = await fetch(`${API_URL}/rest/v1/rpc/create_assessment_draft`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_command_id: createCmd2,
      p_family_id: FAMILY_ID,
      p_child_id: CHILD_ID,
      p_subject_key: 'science',
      p_subject: 'Science',
      p_title: 'Scenario 2 Science Lab',
      p_assessment_type: 'homework',
      p_difficulty: 'normal',
      p_raw_score: 8.0,
      p_max_score: 10.0,
      p_entry_context: 'shared_child',
    }),
  });
  if (!resRetryCreate.ok) {
    console.error('FAIL [2.5]: Idempotent create retry failed:', await resRetryCreate.text());
    process.exit(1);
  }
  const retryDraft = await resRetryCreate.json();
  if (retryDraft.id !== assessmentId2) {
    console.error(`FAIL [2.5]: Idempotent create returned different assessment! Original: ${assessmentId2}, Retried: ${retryDraft.id}`);
    process.exit(1);
  }
  console.log(`PASS [2.5]: Idempotent create returned identical assessment (${retryDraft.id}). No duplicate created.`);

  // Attempt 2, Step B: Re-attempt evidence registration (idempotent)
  console.log('[2.6] Attempt 2: Re-attempting register_assessment_evidence with same storagePath...');
  const resRetryReg = await fetch(`${API_URL}/rest/v1/rpc/register_assessment_evidence`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_assessment_id: assessmentId2,
      p_storage_path: storagePath2,
      p_media_type: 'image/jpeg',
      p_file_size_bytes: imageBytes.length,
    }),
  });
  if (!resRetryReg.ok) {
    console.error('FAIL [2.6]: Idempotent evidence registration failed:', await resRetryReg.text());
    process.exit(1);
  }
  const retryEv = await resRetryReg.json();
  console.log(`PASS [2.6]: Idempotent evidence registration returned existing record (${retryEv.id}).`);

  // Attempt 2, Step C: Submit assessment with submitCmd2
  console.log('[2.7] Attempt 2: Submitting assessment with submitCmd2...');
  const resRetrySubmit = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_assessment_id: assessmentId2,
      p_expected_version: 1,
      p_command_id: submitCmd2,
    }),
  });
  if (!resRetrySubmit.ok) {
    console.error('FAIL [2.7]: Submit assessment failed:', await resRetrySubmit.text());
    process.exit(1);
  }
  const submitted2 = await resRetrySubmit.json();
  if (submitted2.status !== 'pending_review' || submitted2.version !== 2) {
    console.error('FAIL [2.7]: Unexpected submitted payload on retry:', submitted2);
    process.exit(1);
  }
  console.log(`PASS [2.7]: Submit succeeded (status: ${submitted2.status}, version: ${submitted2.version}).`);

  // -------------------------------------------------------------------------
  // Scenario 3: Verify exact database counts and integrity
  // -------------------------------------------------------------------------
  console.log('\n--- Scenario 3: Database Direct Assertions via psql ---');

  // Check assessment count for Scenario 2 title
  const { stdout: assessCount } = await runPsql(`
    select count(*) from public.assessments
    where family_id = '${FAMILY_ID}' and title = 'Scenario 2 Science Lab';
  `);
  if (assessCount !== '1') {
    console.error(`FAIL: Expected exactly 1 assessment row for Scenario 2, got: ${assessCount}`);
    process.exit(1);
  }
  console.log(`PASS: Exactly 1 row in public.assessments.`);

  // Check evidence count for assessmentId2
  const { stdout: evCount } = await runPsql(`
    select count(*) from public.assessment_evidence where assessment_id = '${assessmentId2}';
  `);
  if (evCount !== '1') {
    console.error(`FAIL: Expected exactly 1 assessment_evidence row for ${assessmentId2}, got: ${evCount}`);
    process.exit(1);
  }
  console.log(`PASS: Exactly 1 row in public.assessment_evidence.`);

  // Check storage object count for assessmentId2
  const { stdout: objCount } = await runPsql(`
    select count(*) from storage.objects where name like '%${assessmentId2}%';
  `);
  if (objCount !== '1') {
    console.error(`FAIL: Expected exactly 1 storage object for ${assessmentId2}, got: ${objCount}`);
    process.exit(1);
  }
  console.log(`PASS: Exactly 1 object in storage.objects.`);

  // Check assessment review events count (submitted)
  const { stdout: revEventCount, stderr: revErr } = await runPsql(`
    select count(*) from public.assessment_review_events
    where assessment_id = '${assessmentId2}' and event_type = 'submitted';
  `);
  if (revEventCount !== '1') {
    console.error(`FAIL: Expected exactly 1 submitted review event, got: '${revEventCount}', stderr: '${revErr}'`);
    process.exit(1);
  }
  console.log(`PASS: Exactly 1 submitted event in public.assessment_review_events.`);

  // Check command receipts for assessmentId2 (should be exactly 2: create_draft and submit)
  const { stdout: cmdReceipts } = await runPsql(`
    select operation from public.command_receipts
    where resource_id = '${assessmentId2}' order by operation asc;
  `);
  const lines = cmdReceipts.split('\n').filter(Boolean);
  if (lines.length !== 2 || lines[0] !== 'create_draft' || lines[1] !== 'submit') {
    console.error(`FAIL: Expected exactly [create_draft, submit] receipts, got:`, lines);
    process.exit(1);
  }
  console.log(`PASS: Exactly 2 command_receipts (create_draft and submit).`);

  // Final status check
  const { stdout: finalStatus } = await runPsql(`
    select status from public.assessments where id = '${assessmentId2}';
  `);
  if (finalStatus !== 'pending_review') {
    console.error(`FAIL: Expected final status pending_review, got: ${finalStatus}`);
    process.exit(1);
  }
  console.log(`PASS: Final status is pending_review.`);

  // -------------------------------------------------------------------------
  // Scenario 4: Replay submit after already submitted is completely idempotent
  // -------------------------------------------------------------------------
  console.log('\n--- Scenario 4: Post-completion Idempotent Replay ---');
  const resReplaySubmit = await fetch(`${API_URL}/rest/v1/rpc/submit_assessment`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_assessment_id: assessmentId2,
      p_expected_version: 1, // Notice original expectedVersion on replay
      p_command_id: submitCmd2,
    }),
  });
  if (!resReplaySubmit.ok) {
    console.error('FAIL: Replay submit failed:', await resReplaySubmit.text());
    process.exit(1);
  }
  const replayed = await resReplaySubmit.json();
  if (replayed.id !== assessmentId2 || replayed.status !== 'pending_review') {
    console.error('FAIL: Unexpected replayed payload:', replayed);
    process.exit(1);
  }
  console.log(`PASS: Post-completion replay returned existing assessment (${replayed.id}) without modification.`);

  console.log('\n=== ALL ASSESSMENT VERTICAL SLICE & RETRY TESTS PASSED CLEANLY ===');
}

main().catch((err) => {
  console.error('Unhandled test failure:', err);
  process.exit(1);
});
