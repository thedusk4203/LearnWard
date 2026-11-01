// scripts/test_growth_parity.mjs
/**
 * LearnWard - Dart <-> PostgreSQL Growth Engine v0.1 Parity Test
 *
 * PURPOSE:
 * Runs all 15 test fixtures in fixtures/growth_v01_parity_fixtures.json against
 * PostgreSQL's process_verified_learning_event() function and verifies exact bit-for-bit
 * parity with the documented specification and Dart implementation:
 *   - Rolling baseline (last 3 comparable)
 *   - Growth Delta
 *   - Historical Best
 *   - Score RP (minor units)
 *   - Growth RP (minor units, 5 discrete thresholds)
 *   - High Performer RP (Mastery Maintenance +1.00 RP)
 *   - Personal Best RP (+1.00 RP at >= +0.25 margin)
 *   - Difficulty RP (+1.00 RP Hard, +2.00 RP Challenge >= 5.0)
 *   - Anti-farming Below-level reduction (25% base RP, 0 bonuses)
 *   - Longitudinal comparability bands (Evaluative, Formative, Other; Standard, Challenge, BelowLevel)
 *   - Study XP awarded (10 + round(2.0 * total_rp_minor / 100.0))
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

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

function findFixtures() {
  const candidates = [
    'fixtures/growth_v01_parity_fixtures.json',
    '../fixtures/growth_v01_parity_fixtures.json',
    '../../fixtures/growth_v01_parity_fixtures.json'
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      return JSON.parse(fs.readFileSync(c, 'utf8'));
    }
  }
  throw new Error('Could not find fixtures/growth_v01_parity_fixtures.json');
}

async function main() {
  console.log('=== LearnWard: Growth Engine v0.1 Parity Test (PostgreSQL) ===');

  const fixtures = findFixtures();
  console.log(`Loaded ${fixtures.length} parity fixtures.`);

  const FAMILY_ID = crypto.randomUUID();
  const OWNER_ID = crypto.randomUUID();

  // Setup tenancy and helper function in DB
  const setupSql = `
    insert into auth.users (id, email) values
      ('${OWNER_ID}', 'growth_parity_${OWNER_ID}@example.com');

    insert into public.families (id, name, timezone, locale, created_by_user_id) values
      ('${FAMILY_ID}', 'Parity Test Family', 'UTC', 'en-US', '${OWNER_ID}');

    insert into public.family_memberships (family_id, auth_user_id, role, status) values
      ('${FAMILY_ID}', '${OWNER_ID}', 'owner', 'active');

    create or replace function public.test_create_and_verify(
      p_family_id uuid,
      p_child_id uuid,
      p_subject_key text,
      p_type text,
      p_difficulty text,
      p_raw_score numeric,
      p_max_score numeric,
      p_occurred_at timestamptz
    ) returns uuid language plpgsql security definer as $$
    declare
      v_a public.assessments;
      v_vle public.verified_learning_events;
    begin
      v_a := public.create_assessment_draft(
        gen_random_uuid(), p_family_id, p_child_id,
        p_subject_key, 'Subject', 'Test Title', p_type, p_difficulty,
        p_raw_score, p_max_score, p_occurred_at, 'adult'
      );
      perform public.submit_assessment(v_a.id, 1, gen_random_uuid());
      perform public.verify_assessment(v_a.id, 2, gen_random_uuid(), 'verified');
      select * into v_vle from public.verified_learning_events where assessment_id = v_a.id;
      return v_vle.id;
    end;
    $$;

    grant execute on function public.test_create_and_verify to authenticated, service_role;
  `;

  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Setup failed:', setupRes.stderr);
    process.exit(1);
  }
  console.log('PASS: Tenancy and helper established.');

  let passed = 0;
  let failed = 0;

  for (const fixture of fixtures) {
    const { id, description, current, history, expected } = fixture;
    const childId = crypto.randomUUID();

    // 1. Create Child profile
    // 2. Insert and verify history
    // 3. Insert and verify current event
    // 4. Process verified event as owner adult
    // 5. Query and return growth_events row as json
    const historyCalls = history.map((h) => `
      perform public.test_create_and_verify(
        '${FAMILY_ID}'::uuid, '${childId}'::uuid, '${current.subject_key}',
        '${h.type}', '${h.difficulty}', ${h.score}, 10.0,
        now() - interval '${h.days_ago} days'
      );
    `).join('\n');

    const testSql = `
      insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
      values ('${childId}', '${FAMILY_ID}', 'Child ${id}', 5, 2015);

      set role authenticated;
      select set_config('request.jwt.claims', '{"sub": "${OWNER_ID}", "role": "authenticated"}', false);

      do $$
      begin
        ${historyCalls}
      end $$;

      select row_to_json(g.*)
      from (
        select public.test_create_and_verify(
          '${FAMILY_ID}'::uuid, '${childId}'::uuid, '${current.subject_key}',
          '${current.assessment_type}', '${current.difficulty}',
          ${current.raw_score}, ${current.max_score}, now()
        ) as vle_id
      ) t
      cross join lateral public.process_verified_learning_event(t.vle_id) g;
    `;

    const res = await runPsql(testSql);
    if (res.code !== 0) {
      console.error(`FAIL: [${id}] Execution error:`, res.stderr);
      failed++;
      continue;
    }

    // Last line of stdout contains the JSON row
    const lines = res.stdout.split('\n').map((l) => l.trim()).filter((l) => l.length > 0 && l.startsWith('{'));
    if (lines.length === 0) {
      console.error(`FAIL: [${id}] No JSON output returned:`, res.stdout);
      failed++;
      continue;
    }

    const actual = JSON.parse(lines[lines.length - 1]);

    const numOrNull = (v) => (v === null || v === undefined ? null : Number(v));

    const checks = [
      { name: 'baseline_score', expected: numOrNull(expected.baseline_score), actual: numOrNull(actual.baseline_score) },
      { name: 'baseline_sample_count', expected: expected.baseline_sample_count, actual: Number(actual.baseline_sample_count) },
      { name: 'growth_delta', expected: numOrNull(expected.growth_delta), actual: numOrNull(actual.growth_delta) },
      { name: 'historical_best', expected: numOrNull(expected.historical_best), actual: numOrNull(actual.historical_best) },
      { name: 'score_rp_minor', expected: expected.score_rp_minor, actual: Number(actual.score_rp_minor) },
      { name: 'growth_rp_minor', expected: expected.growth_rp_minor, actual: Number(actual.growth_rp_minor) },
      { name: 'high_performer_rp_minor', expected: expected.high_performer_rp_minor, actual: Number(actual.high_performer_rp_minor) },
      { name: 'personal_best_rp_minor', expected: expected.personal_best_rp_minor, actual: Number(actual.personal_best_rp_minor) },
      { name: 'difficulty_rp_minor', expected: expected.difficulty_rp_minor, actual: Number(actual.difficulty_rp_minor) },
      { name: 'total_rp_minor', expected: expected.total_rp_minor, actual: Number(actual.total_rp_minor) },
      { name: 'xp_awarded', expected: expected.xp_awarded, actual: Number(actual.xp_awarded) }
    ];

    let hasMismatch = false;
    for (const c of checks) {
      if (c.expected !== c.actual) {
        console.error(`FAIL: [${id}] ${c.name} mismatch: expected ${c.expected}, got ${c.actual}`);
        hasMismatch = true;
      }
    }

    if (hasMismatch) {
      failed++;
    } else {
      console.log(`PASS: [${id}] ${description}`);
      passed++;
    }
  }

  // Cleanup helper function
  await runPsql('drop function if exists public.test_create_and_verify;');

  console.log(`\nParity Test Summary: ${passed} passed, ${failed} failed out of ${fixtures.length} tests.`);
  if (failed > 0) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Fatal parity test failure:', err);
  process.exit(1);
});
