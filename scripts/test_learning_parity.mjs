// scripts/test_learning_parity.mjs
/**
 * LearnWard - Dart <-> PostgreSQL Learning Mastery Engine v0.1 Parity Test
 *
 * PURPOSE:
 * Runs all test fixtures in fixtures/learning_v01_parity_fixtures.json against
 * PostgreSQL's process_learning_event() and get_child_mastery() functions and verifies
 * exact parity with the documented specification and Dart implementation:
 *   - Option A initialization (M_1 = P_1)
 *   - Below-level initialization constraint (< 1.5 Low confidence)
 *   - Subsequent EWMA calculation (alpha_base = 0.35, specificity & level weights)
 *   - Canonical chronology ordering (effective_occurred_at, verified_at, verified_learning_event_id)
 *   - Confidence units calculation over 60-day window
 *   - Confidence bands (Low, Medium, High with >= 2 distinct VLEs)
 *   - Mastery bands (Emerging, Developing, Secure, Mastery candidate, Mastered)
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
    'fixtures/learning_v01_parity_fixtures.json',
    '../fixtures/learning_v01_parity_fixtures.json',
    '../../fixtures/learning_v01_parity_fixtures.json'
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      return JSON.parse(fs.readFileSync(c, 'utf8'));
    }
  }
  throw new Error('Could not find learning_v01_parity_fixtures.json');
}

async function main() {
  console.log('=== LearnWard Parity Test: Learning Engine Mastery & Confidence (PostgreSQL) ===\n');

  const fixtures = findFixtures();
  console.log(`Loaded ${fixtures.length} test fixtures from JSON.\n`);

  const familyId = crypto.randomUUID();
  const ownerId = crypto.randomUUID();

  // Setup parent and family
  const setupSql = `
    insert into auth.users (id, email) values ('${ownerId}', 'learning_parity_${ownerId}@test.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id)
    values ('${familyId}', 'Parity Family', 'UTC', 'en_US', '${ownerId}');

    insert into public.family_memberships (family_id, auth_user_id, role, status)
    values ('${familyId}', '${ownerId}', 'owner', 'active');
  `;
  const setupRes = await runPsql(setupSql);
  if (setupRes.code !== 0) {
    console.error('Setup failed:', setupRes.stderr);
    process.exit(1);
  }

  // Lookup node IDs for math
  const lookupSql = `
    select
      (select id from public.learning_nodes where catalog_version = 'pilot-v0.1' and canonical_key = 'pilot-v0.1:subject:math') || '|' ||
      'b0000001-0000-0000-0000-000000000001' || '|' ||
      'b0000002-0000-0000-0000-000000000001' || '|' ||
      'b0000003-0000-0000-0000-000000000001';
  `;
  const lookupRes = await runPsql(lookupSql);
  const [subjectNodeId, domainNodeId, topicNodeId, skillNodeId] = lookupRes.stdout.split('|');

  const nodeMap = {
    subject: subjectNodeId,
    domain: domainNodeId,
    topic: topicNodeId,
    skill: skillNodeId
  };

  let passed = 0;
  let failed = 0;

  for (let idx = 0; idx < fixtures.length; idx++) {
    const fixture = fixtures[idx];
    const scenario = fixture.scenario;
    const childId = crypto.randomUUID();
    const nodeId = nodeMap[fixture.node_type];

    // Create child profile
    await runPsql(`
      insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year)
      values ('${childId}', '${familyId}', 'Child ${idx}', 4, 2016);
    `);

    // Create and process each observation in chronological order
    for (let obsIdx = 0; obsIdx < fixture.observations.length; obsIdx++) {
      const obs = fixture.observations[obsIdx];
      const assessId = crypto.randomUUID();
      const vleId = crypto.randomUUID();
      const cmdId = crypto.randomUUID();
      const revId = crypto.randomUUID();
      const revCmd = crypto.randomUUID();
      const rawDiff = obs.difficulty_override || fixture.difficulty_level || 'standard';
      const dbDifficulty = rawDiff === 'below_level' ? 'below_level' : 'normal';
      const offsetDays = obs.occurred_offset_days || (10 - obsIdx);
      const normScore = ((obs.performance_pct / 100.0) * 10.0).toFixed(2);

      const obsSql = `
        insert into public.assessments (id, family_id, child_id, created_by_user_id, status, subject_key, subject, assessment_type, difficulty, title, occurred_at, raw_score, max_score, learning_catalog_version)
        values ('${assessId}', '${familyId}', '${childId}', '${ownerId}', 'pending_review', 'math', 'Mathematics', 'quiz', '${dbDifficulty}', 'Quiz ${obsIdx}', now() - interval '${offsetDays} days', ${obs.performance_pct}, 100, 'pilot-v0.1');

        insert into public.assessment_learning_mappings (family_id, child_id, assessment_id, learning_node_id, score_source, component_key, component_raw_score, component_max_score, confirmed_by_user_id)
        values ('${familyId}', '${childId}', '${assessId}', '${nodeId}', 'component_score', 'comp_1', ${obs.performance_pct}, 100, '${ownerId}');

        insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
        values ('${revCmd}', 'verify', '${ownerId}', '${assessId}', '${familyId}');

        insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id)
        values ('${revId}', '${revCmd}', '${familyId}', '${assessId}', 'verified', 'pending_review', 'verified', '${ownerId}');

        insert into public.verified_learning_events (id, assessment_id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, normalized_score, occurred_at, verified_at, verified_by_user_id, review_event_id, grade_level_snapshot)
        values ('${vleId}', '${assessId}', '${familyId}', '${childId}', 'math', 'Mathematics', 'Quiz ${obsIdx}', 'quiz', '${dbDifficulty}', ${obs.performance_pct}, 100, ${normScore}, now() - interval '${offsetDays} days', now() - interval '${offsetDays} days', '${ownerId}', '${revId}', 4);

        update public.assessments set status = 'verified' where id = '${assessId}';

        set role authenticated;
        select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', false);
        select public.process_learning_event('${cmdId}'::uuid, '${vleId}'::uuid);
      `;

      const obsRes = await runPsql(obsSql);
      if (obsRes.code !== 0) {
        console.error(`Observation ${obsIdx} failed in scenario "${scenario}":`, obsRes.stderr);
        failed++;
        break;
      }
    }

    // Query get_child_mastery for this child based on fixture read_mode
    let querySql;
    if (fixture.read_mode === 'before_attainment') {
      querySql = `
        reset role;
        select private.get_child_mastery_at(
          '${childId}'::uuid,
          coalesce(
            (select mastery_attained_at from public.child_mastery_states where child_id = '${childId}'::uuid and learning_node_id = '${nodeId}'::uuid) - interval '1 second',
            now() - interval '1 second'
          )
        );
      `;
    } else if (fixture.read_mode === 'aged_61_days') {
      querySql = `
        reset role;
        select private.get_child_mastery_at('${childId}'::uuid, now() + interval '61 days');
      `;
    } else {
      querySql = `
        set role authenticated;
        select set_config('request.jwt.claims', '{"sub": "${ownerId}", "role": "authenticated"}', false);
        select public.get_child_mastery('${childId}'::uuid);
      `;
    }

    const queryRes = await runPsql(querySql);
    if (queryRes.code !== 0) {
      console.error(`Query failed for scenario "${scenario}":`, queryRes.stderr);
      failed++;
      continue;
    }

    const lines = queryRes.stdout.split('\n');
    const jsonLine = lines.find((l) => l.trim().startsWith('['));
    if (!jsonLine) {
      console.error(`FAIL: [${scenario}] Could not find JSON array in response:`, queryRes.stdout);
      failed++;
      continue;
    }
    const items = JSON.parse(jsonLine.trim());
    const item = items.find((i) => i.learning_node_id === nodeId);

    if (!item) {
      console.error(`FAIL: [${scenario}] Node ${nodeId} not found in child mastery projection.`);
      failed++;
      continue;
    }

    const expected = fixture.expected;
    const actualScore = parseFloat(item.mastery_score);
    const actualUnits = parseFloat(item.confidence_units);
    const actualConfBand = item.confidence_band;
    const actualMasteryBand = item.mastery_band;

    const scoreMatch = Math.abs(actualScore - expected.mastery_score) <= 0.05;
    const unitsMatch = Math.abs(actualUnits - expected.confidence_units) <= 0.05;
    const confBandMatch = actualConfBand === expected.confidence_band;
    const masteryBandMatch = actualMasteryBand === expected.mastery_band;

    if (scoreMatch && unitsMatch && confBandMatch && masteryBandMatch) {
      console.log(`PASS: [${idx + 1}/${fixtures.length}] ${scenario}`);
      passed++;
    } else {
      console.error(`FAIL: [${scenario}]`);
      if (!scoreMatch) console.error(`  - Score: expected ${expected.mastery_score}, got ${actualScore}`);
      if (!unitsMatch) console.error(`  - Units: expected ${expected.confidence_units}, got ${actualUnits}`);
      if (!confBandMatch) console.error(`  - Confidence band: expected ${expected.confidence_band}, got ${actualConfBand}`);
      if (!masteryBandMatch) console.error(`  - Mastery band: expected ${expected.mastery_band}, got ${actualMasteryBand}`);
      failed++;
    }
  }

  console.log(`\nParity Test Summary: ${passed} passed, ${failed} failed out of ${fixtures.length} fixtures.`);
  if (failed > 0) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Fatal parity test failure:', err);
  process.exit(1);
});
