// scripts/test_learning_vertical_slice.mjs
/**
 * LearnWard - Phase 5.1 Learning Mastery Vertical Slice Integration Test
 *
 * FULL LIFECYCLE:
 * 1. Family and Child setup.
 * 2. Assessment creation -> stamps active catalog (pilot-v0.1) ignoring client input.
 * 3. Assessment submission to pending_review.
 * 4. Parent sets learning mappings for assessment components (Single Digit Addition).
 * 5. Parent verifies assessment -> verified_learning_events copies catalog version.
 * 6. Execute process_learning_event -> creates evidence, revisions, projection snapshot.
 * 7. Query get_child_mastery -> verifies mastery score, confidence band, and mastery band.
 * 8. Execute service_role catalog promotion to pilot-v0.2 -> proves new assessments stamp pilot-v0.2.
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
  console.log('=== LearnWard Integration Test: Learning Mastery Vertical Slice ===\n');

  const familyId = crypto.randomUUID();
  const ownerId = crypto.randomUUID();
  const childId = crypto.randomUUID();
  const assessId = crypto.randomUUID();
  const vleId = crypto.randomUUID();
  const cmdId = crypto.randomUUID();

  console.log('1. Setting up Family, Child, and Parent...');
  const setupSql = `
    insert into auth.users (id, email) values ('${ownerId}', 'learning_slice_${ownerId}@test.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${familyId}', 'Slice Family', 'UTC', 'en_US', '${ownerId}');

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${familyId}', '${ownerId}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${childId}', '${familyId}', 'Slice Child', 3, 2017);
  `;
  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Setup failed:', setupRes.stderr);
    process.exit(1);
  }

  console.log('2. Creating assessment draft...');
  const createDraftSql = `
    insert into public.assessments (id, family_id, child_id, created_by_user_id, status, subject_key, subject, assessment_type, title, occurred_at, raw_score, max_score, learning_catalog_version)
    values ('${assessId}', '${familyId}', '${childId}', '${ownerId}', 'draft', 'math', 'Mathematics', 'quiz', 'Addition Mastery Quiz', now(), 18, 20, 'obsolete-v0.0');

    select learning_catalog_version from public.assessments where id = '${assessId}';
  `;
  const draftRes = await runPsql(createDraftSql);
  if (draftRes.code !== 0 || !draftRes.stdout.includes('pilot-v0.1')) {
    console.error(`Draft creation failed or stamped wrong catalog: ${draftRes.stdout}, ${draftRes.stderr}`);
    process.exit(1);
  }
  console.log('  -> PASS: Assessment stamped server-active catalog pilot-v0.1.');

  console.log('3. Submitting assessment to pending_review...');
  const submitSql = `
    update public.assessments set status = 'pending_review' where id = '${assessId}';
  `;
  await runPsql(submitSql);

  console.log('4. Parent sets learning mappings for components...');
  const setMappingsSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', false);
    select public.set_assessment_learning_mappings(
      '${assessId}'::uuid,
      '[
        {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "part_1", "raw_score": 9, "max_score": 10},
        {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "part_2", "raw_score": 9, "max_score": 10}
      ]'::jsonb
    );
  `;
  const setMappingsRes = await runPsql(setMappingsSql);
  if (setMappingsRes.code !== 0) {
    console.error('Setting mappings failed:', setMappingsRes.stderr);
    process.exit(1);
  }
  console.log('  -> PASS: Successfully mapped 2 components to Single Digit Addition.');

  console.log('5. Parent verifies assessment...');
  const revId = crypto.randomUUID();
  const revCmd = crypto.randomUUID();
  const verifySql = `
    insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
    values ('${revCmd}', 'verify', '${ownerId}', '${assessId}', '${familyId}');

    insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id)
    values ('${revId}', '${revCmd}', '${familyId}', '${assessId}', 'verified', 'pending_review', 'verified', '${ownerId}');

    insert into public.verified_learning_events (id, assessment_id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_at, verified_by_user_id, review_event_id, grade_level_snapshot)
    values ('${vleId}', '${assessId}', '${familyId}', '${childId}', 'math', 'Mathematics', 'Addition Mastery Quiz', 'quiz', 'normal', 18, 20, 9.00, now(), now(), '${ownerId}', '${revId}', 3);

    update public.assessments set status = 'verified' where id = '${assessId}';

    select learning_catalog_version from public.verified_learning_events where id = '${vleId}';
  `;
  const verifyRes = await runPsql(verifySql);
  if (verifyRes.code !== 0 || !verifyRes.stdout.includes('pilot-v0.1')) {
    console.error(`Verification failed or wrong VLE catalog: ${verifyRes.stdout}, ${verifyRes.stderr}`);
    process.exit(1);
  }
  console.log('  -> PASS: VLE copied assessment catalog snapshot pilot-v0.1.');

  console.log('6. Processing learning event...');
  const procSql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', false);
    select public.process_learning_event('${cmdId}'::uuid, '${vleId}'::uuid);
  `;
  const procRes = await runPsql(procSql);
  if (procRes.code !== 0) {
    console.error('Processing learning event failed:', procRes.stderr);
    process.exit(1);
  }
  console.log('  -> PASS: Learning event processed successfully.');

  console.log('7. Querying child mastery read model...');
  const getMasterySql = `
    set role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', false);
    select public.get_child_mastery('${childId}'::uuid);
  `;
  const getMasteryRes = await runPsql(getMasterySql);
  if (getMasteryRes.code !== 0) {
    console.error('get_child_mastery failed:', getMasteryRes.stderr);
    process.exit(1);
  }

  const lines = getMasteryRes.stdout.split('\n');
  const jsonLine = lines.find((l) => l.trim().startsWith('['));
  if (!jsonLine) {
    console.error('Could not find JSON array in get_child_mastery response:', getMasteryRes.stdout);
    process.exit(1);
  }
  const masteryItems = JSON.parse(jsonLine.trim());
  const skillItem = masteryItems.find((i) => i.node_canonical_key === 'pilot-v0.1:math:arithmetic:addition:single_digit');
  const subjectItem = masteryItems.find((i) => i.node_canonical_key === 'pilot-v0.1:subject:math');

  if (!skillItem || !subjectItem) {
    console.error('Missing expected mastery items:', getMasteryRes.stdout);
    process.exit(1);
  }

  if (!skillItem.as_of) {
    console.error('Skill item missing as_of timestamp:', skillItem);
    process.exit(1);
  }

  if (parseFloat(skillItem.mastery_score) !== 90.00 || skillItem.confidence_band !== 'low' || skillItem.mastery_band !== 'mastery_candidate') {
    console.error('Skill item unexpected projection:', skillItem);
    process.exit(1);
  }
  console.log('  -> PASS: Single Digit Addition has score 90.00, confidence Low, band mastery_candidate.');

  if (parseFloat(subjectItem.mastery_score) !== 90.00) {
    console.error('Subject item unexpected projection:', subjectItem);
    process.exit(1);
  }
  console.log('  -> PASS: Automatic Subject fallback evaluated accurately at score 90.00.');

  console.log('8. Promoting platform catalog version to pilot-v0.2 and testing provenance...');
  const promoteSql = `
    insert into public.learning_catalog_versions (version, status) values ('pilot-v0.2', 'draft')
    on conflict (version) do nothing;

    insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
    values
      ('pilot-v0.2', 'subject', 'math', 'pilot-v0.2:subject:math', 'Mathematics', null),
      ('pilot-v0.2', 'subject', 'english', 'pilot-v0.2:subject:english', 'English', null),
      ('pilot-v0.2', 'subject', 'literature', 'pilot-v0.2:subject:literature', 'Literature', null),
      ('pilot-v0.2', 'subject', 'science', 'pilot-v0.2:subject:science', 'Science', null),
      ('pilot-v0.2', 'subject', 'other', 'pilot-v0.2:subject:other', 'Other', null)
    on conflict (catalog_version, canonical_key) do nothing;

    select public.promote_learning_catalog_version('pilot-v0.2');

    -- Create new assessment under new active catalog
    insert into public.assessments (family_id, child_id, created_by_user_id, status, subject_key, subject, assessment_type, title, occurred_at, raw_score, max_score)
    values ('${familyId}', '${childId}', '${ownerId}', 'draft', 'math', 'Mathematics', 'quiz', 'New Era Quiz', now(), 10, 10)
    returning learning_catalog_version;
  `;
  const promoteRes = await runPsql(promoteSql);
  if (promoteRes.code !== 0 || !promoteRes.stdout.includes('pilot-v0.2')) {
    console.error('Promotion or subsequent assessment failed:', promoteRes.stdout, promoteRes.stderr);
    process.exit(1);
  }
  console.log('  -> PASS: Platform promotion activated pilot-v0.2 and subsequent assessments snapshot pilot-v0.2.');

  // Clean up: return active version to pilot-v0.1
  await runPsql(`
    update public.learning_catalog_versions set status = 'retired' where version = 'pilot-v0.2';
    update public.learning_catalog_versions set status = 'active' where version = 'pilot-v0.1';
  `);

  console.log('\nAll Learning Mastery Vertical Slice Integration Tests PASSED!');
}

main().catch((err) => {
  console.error('Unhandled failure:', err);
  process.exit(1);
});
