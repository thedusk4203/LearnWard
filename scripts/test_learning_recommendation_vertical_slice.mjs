// scripts/test_learning_recommendation_vertical_slice.mjs
/**
 * LearnWard - Phase 5.2 Skill Graph, Freshness, Recovery & Next Challenge Vertical Slice Test
 *
 * FULL LIFECYCLE (wrapped in clean transaction so active catalog remains pilot-v0.1):
 * 1. Family, Owner, Child (grade 2), and Paired Child Device setup.
 * 2. Cold-start read:
 *    - get_child_learning_overview returns 5 canonical subjects and 3 pilot-v0.1 skills, Double Digit Addition locked.
 *    - get_next_challenge_candidates returns explore candidates (Single Digit Addition, End Punctuation Marks).
 * 3. Weak component evidence on Single Digit Addition (40%):
 *    - process_learning_event -> Single Digit Addition enters review_suggested recovery.
 *    - get_next_challenge_candidates promotes Single Digit Addition to #1 (recovery / recovery_recent_errors / below_level).
 * 4. Credible clear + Mastery attainment on Single Digit Addition (four 100% assessments):
 *    - process_learning_event -> Single Digit Addition attains sticky Mastered and clears recovery_signal to none.
 *    - Dependent Double Digit Addition unlocks (is_satisfied = true, attained_prerequisite_count = 1).
 *    - get_next_challenge_candidates promotes Double Digit Addition to #1 (unlock / unlock_prerequisites_mastered / normal).
 * 5. Paired child device read + Economy invariance verification:
 *    - Paired child device reads all 3 RPCs successfully.
 *    - Zero rows created/mutated in XP/RP ledgers, child_balances, redemptions, or wheel spins by Phase 5.2 RPCs.
 */

import { spawn } from 'node:child_process';
import crypto from 'node:crypto';

function runPsql(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'docker',
      [
        'exec',
        '-i',
        'supabase_db_learnward',
        'psql',
        '-U',
        'postgres',
        '-d',
        'postgres',
        '-v',
        'ON_ERROR_STOP=1',
        '-t',
        '-A',
      ],
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
  console.log('=== LearnWard Integration Test: Phase 5.2 Skill Graph & Next Challenge Vertical Slice ===\n');

  const familyId = crypto.randomUUID();
  const ownerId = crypto.randomUUID();
  const childUserId = crypto.randomUUID();
  const childId = crypto.randomUUID();

  const sql = `
    begin;

    insert into auth.users (id, aud, role, email) values
      ('${ownerId}', 'authenticated', 'authenticated', 'p52_slice_owner_${ownerId}@test.com'),
      ('${childUserId}', 'authenticated', 'authenticated', 'p52_slice_child_${childUserId}@test.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${familyId}', 'Phase 5.2 Vertical Slice Family', 'UTC', 'en_US', '${ownerId}');

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${familyId}', '${ownerId}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
    values ('${childId}', '${familyId}', 'Slice Grade 2 Child', 2, 2018);

    insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id)
    values ('${crypto.randomUUID()}', '${familyId}', '${childId}', '${childUserId}', 'active', '${ownerId}');

    -- Step 2: Cold-start read as authenticated owner
    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);

    select 'STEP2_OVERVIEW:' || public.get_child_learning_overview('${childId}'::uuid)::text;
    select 'STEP2_NEXT:' || public.get_next_challenge_candidates('${childId}'::uuid, null, 3)::text;

    -- Step 3: Weak component evidence on Single Digit Addition (4/10 -> 40%)
    reset role;
    insert into public.assessments (
      id, family_id, child_id, created_by_user_id, status, subject_key, subject,
      assessment_type, difficulty, title, occurred_at, raw_score, max_score, learning_catalog_version
    ) values (
      'a5200000-0000-0000-0000-000000000001', '${familyId}', '${childId}', '${ownerId}', 'pending_review',
      'math', 'Mathematics', 'quiz', 'normal', 'Weak Addition Quiz', now() - interval '5 days', 4, 10, 'pilot-v0.1'
    );

    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.set_assessment_learning_mappings(
      'a5200000-0000-0000-0000-000000000001'::uuid,
      '[{"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "part_1", "raw_score": 4, "max_score": 10}]'::jsonb
    );

    reset role;
    insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
    values ('75200000-0000-0000-0000-000000000001', 'verify', '${ownerId}', 'a5200000-0000-0000-0000-000000000001', '${familyId}');

    insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id)
    values ('e5200000-0000-0000-0000-000000000001', '75200000-0000-0000-0000-000000000001', '${familyId}', 'a5200000-0000-0000-0000-000000000001', 'verified', 'pending_review', 'verified', '${ownerId}');

    insert into public.verified_learning_events (
      id, assessment_id, family_id, child_id, subject_key, subject, title,
      assessment_type, difficulty, raw_score, max_score, normalized_score,
      occurred_at, verified_at, verified_by_user_id, review_event_id, grade_level_snapshot, learning_catalog_version
    ) values (
      '15200000-0000-0000-0000-000000000001', 'a5200000-0000-0000-0000-000000000001', '${familyId}', '${childId}',
      'math', 'Mathematics', 'Weak Addition Quiz', 'quiz', 'normal', 4, 10, 4.00,
      now() - interval '5 days', now() - interval '5 days', '${ownerId}', 'e5200000-0000-0000-0000-000000000001', 2, 'pilot-v0.1'
    );
    update public.assessments set status = 'verified' where id = 'a5200000-0000-0000-0000-000000000001';

    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.process_learning_event('85200000-0000-0000-0000-000000000001'::uuid, '15200000-0000-0000-0000-000000000001'::uuid);

    select 'STEP3_NEXT:' || public.get_next_challenge_candidates('${childId}'::uuid, null, 3)::text;
    select 'STEP3_DETAIL:' || public.get_node_learning_state('${childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid)::text;

    -- Step 4: Four high-scoring assessments on Single Digit Addition to clear weakness and attain sticky Mastered
    reset role;
    insert into public.assessments (
      id, family_id, child_id, created_by_user_id, status, subject_key, subject,
      assessment_type, difficulty, title, occurred_at, raw_score, max_score, learning_catalog_version
    ) values
      ('a5200000-0000-0000-0000-000000000002', '${familyId}', '${childId}', '${ownerId}', 'pending_review', 'math', 'Mathematics', 'quiz', 'normal', 'Strong Addition Quiz 1', now() - interval '4 days', 100, 100, 'pilot-v0.1'),
      ('a5200000-0000-0000-0000-000000000003', '${familyId}', '${childId}', '${ownerId}', 'pending_review', 'math', 'Mathematics', 'quiz', 'normal', 'Strong Addition Quiz 2', now() - interval '3 days', 100, 100, 'pilot-v0.1'),
      ('a5200000-0000-0000-0000-000000000004', '${familyId}', '${childId}', '${ownerId}', 'pending_review', 'math', 'Mathematics', 'quiz', 'normal', 'Strong Addition Quiz 3', now() - interval '2 days', 100, 100, 'pilot-v0.1'),
      ('a5200000-0000-0000-0000-000000000005', '${familyId}', '${childId}', '${ownerId}', 'pending_review', 'math', 'Mathematics', 'quiz', 'normal', 'Strong Addition Quiz 4', now() - interval '1 day', 100, 100, 'pilot-v0.1');

    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.set_assessment_learning_mappings(
      'a5200000-0000-0000-0000-000000000002'::uuid,
      '[{"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "part_1", "raw_score": 100, "max_score": 100}]'::jsonb
    );
    select public.set_assessment_learning_mappings(
      'a5200000-0000-0000-0000-000000000003'::uuid,
      '[{"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "part_1", "raw_score": 100, "max_score": 100}]'::jsonb
    );
    select public.set_assessment_learning_mappings(
      'a5200000-0000-0000-0000-000000000004'::uuid,
      '[{"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "part_1", "raw_score": 100, "max_score": 100}]'::jsonb
    );
    select public.set_assessment_learning_mappings(
      'a5200000-0000-0000-0000-000000000005'::uuid,
      '[{"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "part_1", "raw_score": 100, "max_score": 100}]'::jsonb
    );

    reset role;
    insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id) values
      ('75200000-0000-0000-0000-000000000002', 'verify', '${ownerId}', 'a5200000-0000-0000-0000-000000000002', '${familyId}'),
      ('75200000-0000-0000-0000-000000000003', 'verify', '${ownerId}', 'a5200000-0000-0000-0000-000000000003', '${familyId}'),
      ('75200000-0000-0000-0000-000000000004', 'verify', '${ownerId}', 'a5200000-0000-0000-0000-000000000004', '${familyId}'),
      ('75200000-0000-0000-0000-000000000005', 'verify', '${ownerId}', 'a5200000-0000-0000-0000-000000000005', '${familyId}');

    insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id) values
      ('e5200000-0000-0000-0000-000000000002', '75200000-0000-0000-0000-000000000002', '${familyId}', 'a5200000-0000-0000-0000-000000000002', 'verified', 'pending_review', 'verified', '${ownerId}'),
      ('e5200000-0000-0000-0000-000000000003', '75200000-0000-0000-0000-000000000003', '${familyId}', 'a5200000-0000-0000-0000-000000000003', 'verified', 'pending_review', 'verified', '${ownerId}'),
      ('e5200000-0000-0000-0000-000000000004', '75200000-0000-0000-0000-000000000004', '${familyId}', 'a5200000-0000-0000-0000-000000000004', 'verified', 'pending_review', 'verified', '${ownerId}'),
      ('e5200000-0000-0000-0000-000000000005', '75200000-0000-0000-0000-000000000005', '${familyId}', 'a5200000-0000-0000-0000-000000000005', 'verified', 'pending_review', 'verified', '${ownerId}');

    insert into public.verified_learning_events (
      id, assessment_id, family_id, child_id, subject_key, subject, title,
      assessment_type, difficulty, raw_score, max_score, normalized_score,
      occurred_at, verified_at, verified_by_user_id, review_event_id, grade_level_snapshot, learning_catalog_version
    ) values
      ('15200000-0000-0000-0000-000000000002', 'a5200000-0000-0000-0000-000000000002', '${familyId}', '${childId}', 'math', 'Mathematics', 'Strong Addition Quiz 1', 'quiz', 'normal', 100, 100, 10.00, now() - interval '4 days', now() - interval '4 days', '${ownerId}', 'e5200000-0000-0000-0000-000000000002', 2, 'pilot-v0.1'),
      ('15200000-0000-0000-0000-000000000003', 'a5200000-0000-0000-0000-000000000003', '${familyId}', '${childId}', 'math', 'Mathematics', 'Strong Addition Quiz 2', 'quiz', 'normal', 100, 100, 10.00, now() - interval '3 days', now() - interval '3 days', '${ownerId}', 'e5200000-0000-0000-0000-000000000003', 2, 'pilot-v0.1'),
      ('15200000-0000-0000-0000-000000000004', 'a5200000-0000-0000-0000-000000000004', '${familyId}', '${childId}', 'math', 'Mathematics', 'Strong Addition Quiz 3', 'quiz', 'normal', 100, 100, 10.00, now() - interval '2 days', now() - interval '2 days', '${ownerId}', 'e5200000-0000-0000-0000-000000000004', 2, 'pilot-v0.1'),
      ('15200000-0000-0000-0000-000000000005', 'a5200000-0000-0000-0000-000000000005', '${familyId}', '${childId}', 'math', 'Mathematics', 'Strong Addition Quiz 4', 'quiz', 'normal', 100, 100, 10.00, now() - interval '1 day', now() - interval '1 day', '${ownerId}', 'e5200000-0000-0000-0000-000000000005', 2, 'pilot-v0.1');

    update public.assessments set status = 'verified' where id in (
      'a5200000-0000-0000-0000-000000000002',
      'a5200000-0000-0000-0000-000000000003',
      'a5200000-0000-0000-0000-000000000004',
      'a5200000-0000-0000-0000-000000000005'
    );

    set local role authenticated;
    select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', true);
    select public.process_learning_event('85200000-0000-0000-0000-000000000002'::uuid, '15200000-0000-0000-0000-000000000002'::uuid);
    select public.process_learning_event('85200000-0000-0000-0000-000000000003'::uuid, '15200000-0000-0000-0000-000000000003'::uuid);
    select public.process_learning_event('85200000-0000-0000-0000-000000000004'::uuid, '15200000-0000-0000-0000-000000000004'::uuid);
    select public.process_learning_event('85200000-0000-0000-0000-000000000005'::uuid, '15200000-0000-0000-0000-000000000005'::uuid);

    -- Step 5: Paired child device queries overview, Double Digit Addition detail, and next challenge candidates
    select set_config('request.jwt.claims', '{"sub": "${childUserId}", "role": "authenticated"}', true);
    select 'STEP5_OVERVIEW:' || public.get_child_learning_overview('${childId}'::uuid)::text;
    select 'STEP5_DETAIL_DOUBLE:' || public.get_node_learning_state('${childId}'::uuid, 'b0000003-0000-0000-0000-000000000002'::uuid)::text;
    select 'STEP5_NEXT:' || public.get_next_challenge_candidates('${childId}'::uuid, 'math', 3)::text;

    reset role;
    select 'ECON_COUNT:' || (
      (select count(*) from public.xp_ledger where child_id = '${childId}') +
      (select count(*) from public.rp_ledger where child_id = '${childId}') +
      (select count(*) from public.child_balances where child_id = '${childId}' and (xp_total <> 0 or rp_balance_minor <> 0)) +
      (select count(*) from public.reward_redemptions where child_id = '${childId}') +
      (select count(*) from public.wheel_spins where child_id = '${childId}')
    )::text;

    rollback;
  `;

  const res = await runPsql(sql);
  if (res.code !== 0) {
    console.error('Vertical slice failed:', res.stderr);
    process.exit(1);
  }

  const lines = res.stdout.split('\n').map((l) => l.trim());
  const getJson = (prefix) => {
    const line = lines.find((l) => l.startsWith(prefix));
    if (!line) throw new Error(`Missing output line for ${prefix}`);
    return JSON.parse(line.slice(prefix.length));
  };

  // Verify Step 2: Cold start
  const step2Ov = getJson('STEP2_OVERVIEW:');
  const step2Next = getJson('STEP2_NEXT:');
  if (step2Ov.subjects.length !== 5 || step2Ov.overall_coverage.total_skills !== 3) {
    throw new Error(
      `Expected 5 subjects and 3 total skills in pilot-v0.1 overview, got ${step2Ov.subjects.length} subjects and ${step2Ov.overall_coverage.total_skills} skills`
    );
  }
  const mathSubj = step2Ov.subjects.find((s) => s.subject_key === 'math');
  const ddCold = mathSubj.topics[0].skills.find((s) => s.canonical_key === 'pilot-v0.1:math:arithmetic:addition:double_digit');
  if (ddCold.is_prerequisite_satisfied !== false) {
    throw new Error('Expected Double Digit Addition to be locked at cold start');
  }
  if (
    step2Next.candidates.length !== 2 ||
    step2Next.candidates[0].priority_class !== 'explore' ||
    step2Next.candidates[0].reason_code !== 'explore_available_skill'
  ) {
    throw new Error(`Unexpected cold-start candidates: ${JSON.stringify(step2Next.candidates)}`);
  }
  console.log('  -> PASS Step 2: Cold-start overview (5 subjects, 3 skills, Double Digit locked) & explore candidates verified.');

  // Verify Step 3: Weak evidence recovery
  const step3Next = getJson('STEP3_NEXT:');
  const step3Detail = getJson('STEP3_DETAIL:');
  if (
    step3Next.candidates[0].canonical_key !== 'pilot-v0.1:math:arithmetic:addition:single_digit' ||
    step3Next.candidates[0].priority_class !== 'recovery' ||
    step3Next.candidates[0].reason_code !== 'recovery_recent_errors' ||
    step3Next.candidates[0].recommended_difficulty !== 'below_level'
  ) {
    throw new Error(`Expected Single Digit Addition at #1 with recovery/recovery_recent_errors/below_level, got: ${JSON.stringify(step3Next.candidates[0])}`);
  }
  if (step3Detail.state.recovery_signal !== 'review_suggested') {
    throw new Error(`Expected review_suggested in node detail, got: ${step3Detail.state.recovery_signal}`);
  }
  console.log('  -> PASS Step 3: Weak component evidence triggers review_suggested and promotes Single Digit Addition to #1 recovery candidate.');

  // Verify Step 5: Credible clear + Mastery attainment + Prerequisite unlock + Paired Child Device read
  const step5Ov = getJson('STEP5_OVERVIEW:');
  const step5DetailDd = getJson('STEP5_DETAIL_DOUBLE:');
  const step5Next = getJson('STEP5_NEXT:');

  const mathSubj5 = step5Ov.subjects.find((s) => s.subject_key === 'math');
  const sdMastered = mathSubj5.topics[0].skills.find((s) => s.canonical_key === 'pilot-v0.1:math:arithmetic:addition:single_digit');
  if (sdMastered.mastery_band !== 'mastered' || sdMastered.recovery_signal !== 'none' || !sdMastered.mastery_attained_at) {
    throw new Error(`Expected Single Digit Addition to be sticky Mastered with recovery=none, got: ${JSON.stringify(sdMastered)}`);
  }
  if (
    step5DetailDd.prerequisite_state.is_satisfied !== true ||
    step5DetailDd.prerequisite_state.attained_prerequisite_count !== 1 ||
    step5DetailDd.prerequisite_state.prerequisite_count !== 1
  ) {
    throw new Error(`Expected Double Digit Addition to be unlocked in node detail, got: ${JSON.stringify(step5DetailDd.prerequisite_state)}`);
  }
  if (
    step5Next.candidates[0].canonical_key !== 'pilot-v0.1:math:arithmetic:addition:double_digit' ||
    step5Next.candidates[0].priority_class !== 'unlock' ||
    step5Next.candidates[0].reason_code !== 'unlock_prerequisites_mastered' ||
    step5Next.candidates[0].recommended_difficulty !== 'normal'
  ) {
    throw new Error(`Expected Double Digit Addition at #1 with unlock/unlock_prerequisites_mastered/normal, got: ${JSON.stringify(step5Next.candidates[0])}`);
  }
  console.log('  -> PASS Step 4 & 5: Single Digit Addition attained sticky Mastered, cleared recovery, and unlocked Double Digit Addition (#1 unlock candidate) for paired child device.');

  const econLine = lines.find((l) => l.startsWith('ECON_COUNT:'));
  if (econLine !== 'ECON_COUNT:0') {
    throw new Error(`Expected zero economy mutations, got ${econLine}`);
  }
  console.log('  -> PASS Step 6: Economy invariance verified (zero XP/RP/balance/redemption/wheel mutations).');

  console.log('\nAll Phase 5.2 Skill Graph & Next Challenge Vertical Slice Tests PASSED!');
}

main().catch((err) => {
  console.error('Unhandled vertical slice failure:', err);
  process.exit(1);
});
