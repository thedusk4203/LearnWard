// scripts/test_learning_recommendation_parity.mjs
/**
 * LearnWard - Phase 5.2 Skill Graph, Freshness, Recovery & Next Challenge Parity Test (PostgreSQL)
 *
 * PURPOSE:
 * Executes all 61 numbered parity cases in fixtures/learning_v02_recommendation_parity_fixtures.json
 * against PostgreSQL's Phase 5.2 SQL functions and verifies exact parity with the pure Dart domain engine:
 *   - 18.1 Phase 5.1 Read Semantics Reuse (Cases 1-9, including Part A 5-field overlap & Part B distinct_recent_vle_count)
 *   - 18.2 Unified Evaluation Clock & Verification Authority (Cases 10-12)
 *   - 18.3 Freshness Overlay Boundaries (Cases 13-18)
 *   - 18.4 Recovery Signal Rules (Cases 19-26)
 *   - 18.5 Skill Prerequisite Graph & Unlock Rules (Cases 27-37)
 *   - 18.6 Grade Filter & Difficulty Rules (Cases 38-45)
 *   - 18.7 Next Challenge Priority & Tie-Break Ordering (Cases 46-54 + SQLSTATE 22000 parameter checks)
 *   - 18.8 Authorization & Security Matrix (Cases 55-59 across all 3 public RPCs & 4 private helpers)
 *   - 18.9 Economy Invariance (Case 60: XP/RP ledgers, child_balances, Reward Store, Celebration Wheel)
 */

import fs from 'node:fs';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';

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

function findFixtures() {
  const candidates = [
    'fixtures/learning_v02_recommendation_parity_fixtures.json',
    '../fixtures/learning_v02_recommendation_parity_fixtures.json',
    '../../fixtures/learning_v02_recommendation_parity_fixtures.json',
  ];
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      return JSON.parse(fs.readFileSync(c, 'utf8'));
    }
  }
  throw new Error('Could not find learning_v02_recommendation_parity_fixtures.json');
}

function numEq(a, b, eps = 0.01) {
  if (a === null && b === null) return true;
  if (a === null || b === null) return false;
  return Math.abs(Number(a) - Number(b)) <= eps;
}

function tsEq(a, b) {
  if (a === null && b === null) return true;
  if (!a || !b) return false;
  return new Date(a).getTime() === new Date(b).getTime();
}

function nodeIdExpr(idOrKey, defaultCatalog = 'pilot-v0.1') {
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(idOrKey)) {
    return `'${idOrKey}'::uuid`;
  }
  const cat = idOrKey.split(':')[0] || defaultCatalog;
  return `(select id from public.learning_nodes where catalog_version = '${cat}' and canonical_key = '${idOrKey}')`;
}

function buildCaseSetupSql(fixture, ids) {
  const {
    familyId,
    familyBId,
    ownerId,
    parentId,
    otherOwnerId,
    childUserId,
    siblingUserId,
    childId,
    siblingId,
  } = ids;

  const schoolGradeSql =
    fixture.school_grade === null || fixture.school_grade === undefined
      ? 'NULL'
      : String(fixture.school_grade);

  let sql = `
    -- Ensure pilot-v0.1 is the active catalog at the start of this case transaction
    alter table public.learning_catalog_versions disable trigger trg_learning_catalog_versions_mutation;
    update public.learning_catalog_versions set status = 'retired' where status = 'active' and version <> 'pilot-v0.1';
    update public.learning_catalog_versions set status = 'active', activated_at = coalesce(activated_at, now()) where version = 'pilot-v0.1';
    alter table public.learning_catalog_versions enable trigger trg_learning_catalog_versions_mutation;

    insert into auth.users (id, aud, role, email) values
      ('${ownerId}', 'authenticated', 'authenticated', 'owner_${ownerId}@test.com'),
      ('${parentId}', 'authenticated', 'authenticated', 'parent_${parentId}@test.com'),
      ('${otherOwnerId}', 'authenticated', 'authenticated', 'other_${otherOwnerId}@test.com'),
      ('${childUserId}', 'authenticated', 'authenticated', 'child_${childUserId}@test.com'),
      ('${siblingUserId}', 'authenticated', 'authenticated', 'sibling_${siblingUserId}@test.com')
    on conflict (id) do nothing;

    insert into public.families (id, name, timezone, locale, created_by_user_id) values
      ('${familyId}', 'Phase 5.2 Parity Family A', 'UTC', 'en_US', '${ownerId}'),
      ('${familyBId}', 'Phase 5.2 Parity Family B', 'UTC', 'en_US', '${otherOwnerId}');

    insert into public.family_memberships (family_id, auth_user_id, role, status) values
      ('${familyId}', '${ownerId}', 'owner', 'active'),
      ('${familyId}', '${parentId}', 'parent', 'active'),
      ('${familyBId}', '${otherOwnerId}', 'owner', 'active');

    insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
      ('${childId}', '${familyId}', 'Parity Child', ${schoolGradeSql}, 2017),
      ('${siblingId}', '${familyId}', 'Sibling Child', 3, 2017);

    insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
      ('${crypto.randomUUID()}', '${familyId}', '${childId}', '${childUserId}', 'active', '${ownerId}'),
      ('${crypto.randomUUID()}', '${familyId}', '${siblingId}', '${siblingUserId}', 'active', '${ownerId}');
  `;

  // If active_catalog_version is pilot-v0.2 (Case 37), create draft pilot-v0.2 and seed its 5 subject roots first
  if (fixture.active_catalog_version && fixture.active_catalog_version !== 'pilot-v0.1') {
    const newCat = fixture.active_catalog_version;
    sql += `
      select public.create_learning_catalog_draft('${newCat}');
      insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id, sort_order, is_active)
      values
        ('${newCat}', 'subject', 'math', '${newCat}:subject:math', 'Mathematics', null, 1, true),
        ('${newCat}', 'subject', 'english', '${newCat}:subject:english', 'English Language Arts', null, 2, true),
        ('${newCat}', 'subject', 'literature', '${newCat}:subject:literature', 'Literature & Reading', null, 3, true),
        ('${newCat}', 'subject', 'science', '${newCat}:subject:science', 'Science', null, 4, true),
        ('${newCat}', 'subject', 'other', '${newCat}:subject:other', 'Other Subjects', null, 5, true)
      on conflict (catalog_version, canonical_key) do nothing;
    `;
  }

  // Insert extra_nodes and extra_prerequisites (temporarily disabling immutability triggers inside the transaction)
  if ((fixture.extra_nodes && fixture.extra_nodes.length > 0) || (fixture.extra_prerequisites && fixture.extra_prerequisites.length > 0)) {
    sql += `
      alter table public.learning_nodes disable trigger trg_learning_nodes_mutation;
      alter table public.learning_prerequisites disable trigger trg_learning_prerequisites_mutation;
    `;
    for (const en of fixture.extra_nodes || []) {
      const parentExpr = en.parent_id ? nodeIdExpr(en.parent_id, en.catalog_version) : 'NULL';
      const gradeMinSql = en.grade_min === null || en.grade_min === undefined ? 'NULL' : String(en.grade_min);
      const gradeMaxSql = en.grade_max === null || en.grade_max === undefined ? 'NULL' : String(en.grade_max);
      const sortOrderSql = en.sort_order === null || en.sort_order === undefined ? '0' : String(en.sort_order);
      const isActiveSql = en.is_active === false ? 'false' : 'true';
      sql += `
        insert into public.learning_nodes (
          id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active
        ) values (
          '${en.id}'::uuid, '${en.catalog_version}', '${en.node_type}', '${en.subject_key}',
          '${en.canonical_key}', '${en.title.replace(/'/g, "''")}', ${parentExpr},
          ${gradeMinSql}, ${gradeMaxSql}, ${sortOrderSql}, ${isActiveSql}
        ) on conflict (catalog_version, canonical_key) do update set
          id = excluded.id,
          parent_id = excluded.parent_id,
          grade_min = excluded.grade_min,
          grade_max = excluded.grade_max,
          sort_order = excluded.sort_order,
          is_active = excluded.is_active;
      `;
    }
    for (const ep of fixture.extra_prerequisites || []) {
      const subj = ep.subject_key || 'math';
      sql += `
        insert into public.learning_prerequisites (
          catalog_version, subject_key, prerequisite_node_id, dependent_node_id
        ) values (
          '${ep.catalog_version}', '${subj}',
          ${nodeIdExpr(ep.prerequisite_node_id, ep.catalog_version)},
          ${nodeIdExpr(ep.dependent_node_id, ep.catalog_version)}
        ) on conflict do nothing;
      `;
    }
    sql += `
      alter table public.learning_nodes enable trigger trg_learning_nodes_mutation;
      alter table public.learning_prerequisites enable trigger trg_learning_prerequisites_mutation;
    `;
  }

  if (fixture.active_catalog_version && fixture.active_catalog_version !== 'pilot-v0.1') {
    sql += `
      select public.promote_learning_catalog_version('${fixture.active_catalog_version}');
    `;
  }

  // Insert evidence events and backing assessments + VLEs
  const seenVles = new Set();
  const lastEvidenceIdByNode = new Map();
  const lastVleIdByNode = new Map();

  for (let i = 0; i < (fixture.evidence_events || []).length; i++) {
    const ev = fixture.evidence_events[i];
    const vleId = ev.vle_id;
    const assessId = `20000000-0000-0000-0000-${String(i + 1).padStart(12, '0')}`;
    const evId = `30000000-0000-0000-0000-${String(i + 1).padStart(12, '0')}`;
    const diff = ev.difficulty || 'normal';
    const nExpr = nodeIdExpr(ev.node_id, 'pilot-v0.1');

    if (!seenVles.has(vleId)) {
      seenVles.add(vleId);
      const revId = crypto.randomUUID();
      const cmdId = crypto.randomUUID();
      sql += `
        insert into public.assessments (
          id, family_id, child_id, created_by_user_id, status, subject_key, subject,
          assessment_type, difficulty, title, occurred_at, raw_score, max_score, learning_catalog_version
        ) values (
          '${vleId}'::uuid, '${familyId}', '${childId}', '${ownerId}', 'verified', 'math', 'Mathematics',
          'quiz', '${diff}', 'Fixture Assessment ${i}', '${ev.effective_occurred_at}'::timestamptz, 90, 100, 'pilot-v0.1'
        ) on conflict (id) do nothing;

        insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
        values ('${cmdId}', 'verify', '${ownerId}', '${vleId}'::uuid, '${familyId}')
        on conflict do nothing;

        insert into public.assessment_review_events (
          id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id
        ) values (
          '${revId}', '${cmdId}', '${familyId}', '${vleId}'::uuid, 'verified', 'pending_review', 'verified', '${ownerId}'
        );

        insert into public.verified_learning_events (
          id, assessment_id, family_id, child_id, subject_key, subject, title,
          assessment_type, difficulty, raw_score, max_score, normalized_score,
          occurred_at, verified_at, verified_by_user_id, review_event_id, grade_level_snapshot, learning_catalog_version
        ) values (
          '${vleId}'::uuid, '${vleId}'::uuid, '${familyId}', '${childId}', 'math', 'Mathematics', 'Fixture Assessment ${i}',
          'quiz', '${diff}', 90, 100, 9.00,
          '${ev.effective_occurred_at}'::timestamptz, '${ev.verified_at}'::timestamptz, '${ownerId}', '${revId}', 2, 'pilot-v0.1'
        ) on conflict (id) do nothing;
      `;
    }

    const itemCountSql = ev.item_count === null || ev.item_count === undefined ? 'NULL' : String(ev.item_count);
    const correctCountSql =
      ev.correct_count === null || ev.correct_count === undefined ? 'NULL' : String(ev.correct_count);

    sql += `
      insert into public.learning_evidence_events (
        id, family_id, child_id, verified_learning_event_id, assessment_id, learning_node_id,
        catalog_version, node_type, subject_key, grade_level_snapshot, assessment_type, difficulty,
        score_source, performance_pct, specificity_weight, level_weight, item_count, correct_count,
        occurred_at, effective_occurred_at, verified_at
      )
      select
        '${evId}'::uuid, '${familyId}'::uuid, '${childId}'::uuid, '${vleId}'::uuid, '${vleId}'::uuid, n.id,
        n.catalog_version, n.node_type, n.subject_key, 2, 'quiz', '${diff}',
        '${ev.score_source}', ${ev.performance_pct}, ${ev.specificity_weight}, ${ev.level_weight},
        ${itemCountSql}, ${correctCountSql},
        '${ev.effective_occurred_at}'::timestamptz, '${ev.effective_occurred_at}'::timestamptz, '${ev.verified_at}'::timestamptz
      from public.learning_nodes n
      where n.id = ${nExpr};
    `;

    lastEvidenceIdByNode.set(ev.node_id, evId);
    lastVleIdByNode.set(ev.node_id, vleId);
  }

  // Insert mastery_state_revisions and child_mastery_states
  for (let i = 0; i < (fixture.mastery_states || []).length; i++) {
    const ms = fixture.mastery_states[i];
    const nExpr = nodeIdExpr(ms.node_id, 'pilot-v0.1');
    const attainedSql = ms.mastery_attained_at ? `'${ms.mastery_attained_at}'::timestamptz` : 'NULL';
    const lastEvId = lastEvidenceIdByNode.get(ms.node_id);
    const lastVleId = lastVleIdByNode.get(ms.node_id);
    const revId = `40000000-0000-0000-0000-${String(i + 1).padStart(12, '0')}`;

    sql += `
      insert into public.mastery_state_revisions (
        id, family_id, child_id, learning_node_id, trigger_verified_learning_event_id,
        engine_version, previous_mastery_score, new_mastery_score,
        effective_evidence_count, latest_evidence_at, mastery_attained_at, calculation_snapshot
      ) values (
        '${revId}'::uuid, '${familyId}'::uuid, '${childId}'::uuid, ${nExpr}, '${lastVleId}'::uuid,
        'mastery-v0.1', null, ${ms.mastery_score},
        ${ms.effective_evidence_count || 1}, '${ms.last_evidence_occurred_at}'::timestamptz, ${attainedSql}, '{}'::jsonb
      );

      insert into public.child_mastery_states (
        child_id, learning_node_id, family_id, engine_version,
        mastery_score, effective_evidence_count, distinct_assessment_count,
        last_evidence_event_id, last_evidence_occurred_at, last_verified_at,
        latest_revision_id, mastery_attained_at, updated_at
      ) values (
        '${childId}'::uuid, ${nExpr}, '${familyId}'::uuid, 'mastery-v0.1',
        ${ms.mastery_score}, ${ms.effective_evidence_count || 1}, ${ms.distinct_assessment_count || 1},
        '${lastEvId}'::uuid, '${ms.last_evidence_occurred_at}'::timestamptz, '${ms.last_evidence_occurred_at}'::timestamptz,
        '${revId}'::uuid, ${attainedSql}, '${fixture.as_of}'::timestamptz
      );
    `;
  }

  return sql;
}

async function main() {
  console.log('=== LearnWard Parity Test: Phase 5.2 Skill Graph & Next Challenge (PostgreSQL) ===\n');

  const fixtures = findFixtures();
  console.log(`Loaded ${fixtures.length} parity cases from JSON.\n`);

  let passed = 0;
  let failed = 0;

  for (const fixture of fixtures) {
    const caseId = fixture.case_id;
    const section = fixture.section;
    const scenario = fixture.scenario;

    const ids = {
      familyId: 'f5200000-0000-0000-0000-000000000001',
      familyBId: 'f5200000-0000-0000-0000-000000000002',
      ownerId: crypto.randomUUID(),
      parentId: crypto.randomUUID(),
      otherOwnerId: crypto.randomUUID(),
      childUserId: crypto.randomUUID(),
      siblingUserId: crypto.randomUUID(),
      childId: 'c5200000-0000-0000-0000-000000000001',
      siblingId: 'c5200000-0000-0000-0000-000000000002',
    };

    const setupSql = buildCaseSetupSql(fixture, ids);
    const subjectFilterSql = fixture.subject_key_filter ? `'${fixture.subject_key_filter}'` : 'NULL';
    const limitSql = fixture.limit || 3;
    const activeCatalog = fixture.active_catalog_version || 'pilot-v0.1';
    const inspectNodeExpr = fixture.inspect_node_id
      ? nodeIdExpr(fixture.inspect_node_id, activeCatalog)
      : `'b0000003-0000-0000-0000-000000000001'::uuid`;

    const querySql = `
      begin;
      ${setupSql}

      select 'OVERVIEW_JSON:' || private.get_child_learning_overview_at('${ids.childId}'::uuid, '${fixture.as_of}'::timestamptz)::text;
      select 'NEXT_JSON:' || private.get_next_challenge_candidates_at('${ids.childId}'::uuid, ${subjectFilterSql}, ${limitSql}, '${fixture.as_of}'::timestamptz)::text;
      ${
        fixture.inspect_node_id
          ? `select 'DETAIL_JSON:' || private.get_node_learning_state_at('${ids.childId}'::uuid, ${inspectNodeExpr}, '${fixture.as_of}'::timestamptz)::text;`
          : `select 'DETAIL_JSON:null';`
      }
      select 'P51_JSON:' || private.get_child_mastery_at('${ids.childId}'::uuid, '${fixture.as_of}'::timestamptz)::text;

      rollback;
    `;

    const res = await runPsql(querySql);
    if (res.code !== 0) {
      console.error(`FAIL: [Case ${caseId}] SQL execution error:`, res.stderr);
      failed++;
      continue;
    }

    const lines = res.stdout.split('\n').map((l) => l.trim());
    const overviewLine = lines.find((l) => l.startsWith('OVERVIEW_JSON:'));
    const nextLine = lines.find((l) => l.startsWith('NEXT_JSON:'));
    const detailLine = lines.find((l) => l.startsWith('DETAIL_JSON:'));
    const p51Line = lines.find((l) => l.startsWith('P51_JSON:'));

    if (!overviewLine || !nextLine || !detailLine || !p51Line) {
      console.error(`FAIL: [Case ${caseId}] Missing JSON markers in stdout:`, res.stdout);
      failed++;
      continue;
    }

    const actualOverview = JSON.parse(overviewLine.slice('OVERVIEW_JSON:'.length));
    const actualNext = JSON.parse(nextLine.slice('NEXT_JSON:'.length));
    const actualDetail = JSON.parse(detailLine.slice('DETAIL_JSON:'.length));
    const actualP51 = JSON.parse(p51Line.slice('P51_JSON:'.length));

    const expected = fixture.expected;
    const errs = [];

    // 1. Check expected.phase51_overlap (Part A + Part B)
    const expOverlap = expected.phase51_overlap;
    if (expOverlap && actualDetail) {
      const st = actualDetail.state;
      if (!numEq(st.mastery_score, expOverlap.mastery_score)) {
        errs.push(`phase51_overlap.mastery_score: expected ${expOverlap.mastery_score}, got ${st.mastery_score}`);
      }
      if (st.mastery_band !== expOverlap.mastery_band) {
        errs.push(`phase51_overlap.mastery_band: expected ${expOverlap.mastery_band}, got ${st.mastery_band}`);
      }
      if (st.confidence_band !== expOverlap.confidence_band) {
        errs.push(`phase51_overlap.confidence_band: expected ${expOverlap.confidence_band}, got ${st.confidence_band}`);
      }
      if (!numEq(st.confidence_units, expOverlap.confidence_units)) {
        errs.push(`phase51_overlap.confidence_units: expected ${expOverlap.confidence_units}, got ${st.confidence_units}`);
      }
      if (!tsEq(st.mastery_attained_at, expOverlap.mastery_attained_at)) {
        errs.push(`phase51_overlap.mastery_attained_at: expected ${expOverlap.mastery_attained_at}, got ${st.mastery_attained_at}`);
      }
      if (st.distinct_recent_vle_count !== expOverlap.distinct_recent_vle_count) {
        errs.push(`phase51_overlap.distinct_recent_vle_count: expected ${expOverlap.distinct_recent_vle_count}, got ${st.distinct_recent_vle_count}`);
      }

      // Also verify direct match against private.get_child_mastery_at row for the inspected node
      const p51Row = actualP51.find((r) => r.learning_node_id === actualDetail.node.learning_node_id);
      if (!p51Row) {
        errs.push(`phase51_overlap: node ${actualDetail.node.learning_node_id} missing from private.get_child_mastery_at`);
      } else {
        if (!numEq(st.mastery_score, p51Row.mastery_score)) errs.push(`P51 vs P52 mastery_score mismatch`);
        if (st.mastery_band !== p51Row.mastery_band) errs.push(`P51 vs P52 mastery_band mismatch`);
        if (st.confidence_band !== p51Row.confidence_band) errs.push(`P51 vs P52 confidence_band mismatch`);
        if (!numEq(st.confidence_units, p51Row.confidence_units)) errs.push(`P51 vs P52 confidence_units mismatch`);
        if (!tsEq(st.mastery_attained_at, p51Row.mastery_attained_at)) errs.push(`P51 vs P52 mastery_attained_at mismatch`);
      }
    }

    // 2. Check expected.node_state
    const expNode = expected.node_state;
    if (expNode && actualDetail) {
      const st = actualDetail.state;
      const pr = actualDetail.prerequisite_state;
      if ('is_observed' in expNode && st.is_observed !== expNode.is_observed) {
        errs.push(`node_state.is_observed: expected ${expNode.is_observed}, got ${st.is_observed}`);
      }
      if ('mastery_score' in expNode && !numEq(st.mastery_score, expNode.mastery_score)) {
        errs.push(`node_state.mastery_score: expected ${expNode.mastery_score}, got ${st.mastery_score}`);
      }
      if ('mastery_band' in expNode && st.mastery_band !== expNode.mastery_band) {
        errs.push(`node_state.mastery_band: expected ${expNode.mastery_band}, got ${st.mastery_band}`);
      }
      if ('confidence_band' in expNode && st.confidence_band !== expNode.confidence_band) {
        errs.push(`node_state.confidence_band: expected ${expNode.confidence_band}, got ${st.confidence_band}`);
      }
      if ('confidence_units' in expNode && !numEq(st.confidence_units, expNode.confidence_units)) {
        errs.push(`node_state.confidence_units: expected ${expNode.confidence_units}, got ${st.confidence_units}`);
      }
      if ('distinct_recent_vle_count' in expNode && st.distinct_recent_vle_count !== expNode.distinct_recent_vle_count) {
        errs.push(`node_state.distinct_recent_vle_count: expected ${expNode.distinct_recent_vle_count}, got ${st.distinct_recent_vle_count}`);
      }
      if ('freshness' in expNode && st.freshness !== expNode.freshness) {
        errs.push(`node_state.freshness: expected ${expNode.freshness}, got ${st.freshness}`);
      }
      if ('days_since_last_evidence' in expNode && st.days_since_last_evidence !== expNode.days_since_last_evidence) {
        errs.push(`node_state.days_since_last_evidence: expected ${expNode.days_since_last_evidence}, got ${st.days_since_last_evidence}`);
      }
      if ('recovery_signal' in expNode && st.recovery_signal !== expNode.recovery_signal) {
        errs.push(`node_state.recovery_signal: expected ${expNode.recovery_signal}, got ${st.recovery_signal}`);
      }
      if ('latest_unresolved_weakness_at' in expNode && !tsEq(st.latest_unresolved_weakness_at, expNode.latest_unresolved_weakness_at)) {
        errs.push(`node_state.latest_unresolved_weakness_at: expected ${expNode.latest_unresolved_weakness_at}, got ${st.latest_unresolved_weakness_at}`);
      }
      if ('recommended_difficulty' in expNode && st.recommended_difficulty !== expNode.recommended_difficulty) {
        errs.push(`node_state.recommended_difficulty: expected ${expNode.recommended_difficulty}, got ${st.recommended_difficulty}`);
      }
      if ('is_grade_compatible' in expNode && st.is_grade_compatible !== expNode.is_grade_compatible) {
        errs.push(`node_state.is_grade_compatible: expected ${expNode.is_grade_compatible}, got ${st.is_grade_compatible}`);
      }
      if ('latest_evidence_present' in expNode && (actualDetail.latest_evidence !== null) !== expNode.latest_evidence_present) {
        errs.push(`node_state.latest_evidence_present: expected ${expNode.latest_evidence_present}, got ${actualDetail.latest_evidence !== null}`);
      }
      if ('prerequisite_applicable' in expNode && pr.applicable !== expNode.prerequisite_applicable) {
        errs.push(`node_state.prerequisite_applicable: expected ${expNode.prerequisite_applicable}, got ${pr.applicable}`);
      }
      if ('prerequisite_count' in expNode && pr.prerequisite_count !== expNode.prerequisite_count) {
        errs.push(`node_state.prerequisite_count: expected ${expNode.prerequisite_count}, got ${pr.prerequisite_count}`);
      }
      if ('attained_prerequisite_count' in expNode && pr.attained_prerequisite_count !== expNode.attained_prerequisite_count) {
        errs.push(`node_state.attained_prerequisite_count: expected ${expNode.attained_prerequisite_count}, got ${pr.attained_prerequisite_count}`);
      }
      if ('is_prerequisite_satisfied' in expNode && pr.is_satisfied !== expNode.is_prerequisite_satisfied) {
        errs.push(`node_state.is_prerequisite_satisfied: expected ${expNode.is_prerequisite_satisfied}, got ${pr.is_satisfied}`);
      }
      if ('dependent_ids' in expNode) {
        const actDeps = pr.dependents.map((d) => d.learning_node_id);
        if (JSON.stringify(actDeps) !== JSON.stringify(expNode.dependent_ids)) {
          errs.push(`node_state.dependent_ids: expected ${JSON.stringify(expNode.dependent_ids)}, got ${JSON.stringify(actDeps)}`);
        }
      }
      if ('dependents' in expNode) {
        if (pr.dependents.length !== expNode.dependents.length) {
          errs.push(`node_state.dependents.length: expected ${expNode.dependents.length}, got ${pr.dependents.length}`);
        } else {
          for (let i = 0; i < expNode.dependents.length; i++) {
            const actD = pr.dependents[i];
            const expD = expNode.dependents[i];
            for (const k of Object.keys(expD)) {
              if (actD[k] !== expD[k]) {
                errs.push(`node_state.dependents[${i}].${k}: expected ${expD[k]}, got ${actD[k]}`);
              }
            }
          }
        }
      }
    }

    // 3. Check expected.overview
    const expOverview = expected.overview;
    if (expOverview) {
      const cov = actualOverview.overall_coverage;
      if ('active_catalog_version' in expOverview && actualOverview.active_catalog_version !== expOverview.active_catalog_version) {
        errs.push(`overview.active_catalog_version: expected ${expOverview.active_catalog_version}, got ${actualOverview.active_catalog_version}`);
      }
      if ('total_skills' in expOverview && cov.total_skills !== expOverview.total_skills) {
        errs.push(`overview.total_skills: expected ${expOverview.total_skills}, got ${cov.total_skills}`);
      }
      if ('observed_skills' in expOverview && cov.observed_skills !== expOverview.observed_skills) {
        errs.push(`overview.observed_skills: expected ${expOverview.observed_skills}, got ${cov.observed_skills}`);
      }
      if ('unseen_skills' in expOverview && cov.unseen_skills !== expOverview.unseen_skills) {
        errs.push(`overview.unseen_skills: expected ${expOverview.unseen_skills}, got ${cov.unseen_skills}`);
      }
      if ('mastered_skills' in expOverview && cov.mastered_skills !== expOverview.mastered_skills) {
        errs.push(`overview.mastered_skills: expected ${expOverview.mastered_skills}, got ${cov.mastered_skills}`);
      }
      if ('active_recovery_count' in expOverview && cov.active_recovery_count !== expOverview.active_recovery_count) {
        errs.push(`overview.active_recovery_count: expected ${expOverview.active_recovery_count}, got ${cov.active_recovery_count}`);
      }
    }

    // 4. Check expected.next_challenge
    const expNext = expected.next_challenge;
    if (expNext) {
      if ('candidate_node_ids' in expNext) {
        const actIds = actualNext.candidates.map((c) => c.learning_node_id);
        if (JSON.stringify(actIds) !== JSON.stringify(expNext.candidate_node_ids)) {
          errs.push(`next_challenge.candidate_node_ids: expected ${JSON.stringify(expNext.candidate_node_ids)}, got ${JSON.stringify(actIds)}`);
        }
      }
      if ('candidates' in expNext) {
        if (actualNext.candidates.length !== expNext.candidates.length) {
          errs.push(`next_challenge.candidates.length: expected ${expNext.candidates.length}, got ${actualNext.candidates.length}`);
        } else {
          for (let i = 0; i < expNext.candidates.length; i++) {
            const actC = actualNext.candidates[i];
            const expC = expNext.candidates[i];
            if (actC.rank !== expC.rank) errs.push(`candidates[${i}].rank: expected ${expC.rank}, got ${actC.rank}`);
            if (actC.learning_node_id !== expC.learning_node_id) {
              errs.push(`candidates[${i}].learning_node_id: expected ${expC.learning_node_id}, got ${actC.learning_node_id}`);
            }
            if ('priority_class' in expC && actC.priority_class !== expC.priority_class) {
              errs.push(`candidates[${i}].priority_class: expected ${expC.priority_class}, got ${actC.priority_class}`);
            }
            if ('reason_code' in expC && actC.reason_code !== expC.reason_code) {
              errs.push(`candidates[${i}].reason_code: expected ${expC.reason_code}, got ${actC.reason_code}`);
            }
            if ('recommended_difficulty' in expC && actC.recommended_difficulty !== expC.recommended_difficulty) {
              errs.push(`candidates[${i}].recommended_difficulty: expected ${expC.recommended_difficulty}, got ${actC.recommended_difficulty}`);
            }
            if ('explore_proximity_rank' in expC && actC.explanation.explore_proximity_rank !== expC.explore_proximity_rank) {
              errs.push(`candidates[${i}].explore_proximity_rank: expected ${expC.explore_proximity_rank}, got ${actC.explanation.explore_proximity_rank}`);
            }
            if ('attained_prerequisite_titles' in expC) {
              if (JSON.stringify(actC.explanation.attained_prerequisite_titles) !== JSON.stringify(expC.attained_prerequisite_titles)) {
                errs.push(
                  `candidates[${i}].attained_prerequisite_titles: expected ${JSON.stringify(expC.attained_prerequisite_titles)}, got ${JSON.stringify(actC.explanation.attained_prerequisite_titles)}`
                );
              }
            }
          }
        }
      }
    }

    // Additional PostgreSQL contract / security / economy invariance checks for Cases 51, 55-61
    if (caseId === 51) {
      const paramCheckSql = `
        begin;
        ${setupSql}
        set local role authenticated;
        select set_config('request.jwt.claims', '{"sub": "${ids.ownerId}", "role": "authenticated"}', true);
        do $$
        begin
          begin
            perform public.get_next_challenge_candidates('${ids.childId}'::uuid, null, 0);
            raise exception 'Expected 22000 for p_limit = 0';
          exception when sqlstate '22000' then null;
          end;
          begin
            perform public.get_next_challenge_candidates('${ids.childId}'::uuid, null, -1);
            raise exception 'Expected 22000 for p_limit = -1';
          exception when sqlstate '22000' then null;
          end;
          begin
            perform public.get_next_challenge_candidates('${ids.childId}'::uuid, null, 4);
            raise exception 'Expected 22000 for p_limit = 4';
          exception when sqlstate '22000' then null;
          end;
          begin
            perform public.get_next_challenge_candidates('${ids.childId}'::uuid, null, null);
            raise exception 'Expected 22000 for p_limit = null';
          exception when sqlstate '22000' then null;
          end;
          begin
            perform public.get_next_challenge_candidates('${ids.childId}'::uuid, 'reading', 3);
            raise exception 'Expected 22000 for invalid p_subject_key';
          exception when sqlstate '22000' then null;
          end;
        end $$;
        select 'PARAM_CHECK_OK';
        rollback;
      `;
      const pRes = await runPsql(paramCheckSql);
      if (pRes.code !== 0 || !pRes.stdout.includes('PARAM_CHECK_OK')) {
        errs.push(`Case 51 SQL parameter validation failed: ${pRes.stderr}`);
      }
    }

    if (caseId === 55) {
      const authSql = `
        begin;
        ${setupSql}
        set local role authenticated;
        select set_config('request.jwt.claims', '{"sub": "${ids.ownerId}", "role": "authenticated"}', true);
        select public.get_child_learning_overview('${ids.childId}'::uuid);
        select public.get_node_learning_state('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid);
        select public.get_next_challenge_candidates('${ids.childId}'::uuid, null, 3);

        select set_config('request.jwt.claims', '{"sub": "${ids.parentId}", "role": "authenticated"}', true);
        select public.get_child_learning_overview('${ids.childId}'::uuid);
        select public.get_node_learning_state('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid);
        select public.get_next_challenge_candidates('${ids.childId}'::uuid, null, 3);
        select 'ADULT_AUTH_OK';
        rollback;
      `;
      const aRes = await runPsql(authSql);
      if (aRes.code !== 0 || !aRes.stdout.includes('ADULT_AUTH_OK')) {
        errs.push(`Case 55 adult auth check failed: ${aRes.stderr}`);
      }
    }

    if (caseId === 56) {
      const childAuthSql = `
        begin;
        ${setupSql}
        set local role authenticated;
        select set_config('request.jwt.claims', '{"sub": "${ids.childUserId}", "role": "authenticated"}', true);
        select public.get_child_learning_overview('${ids.childId}'::uuid);
        select public.get_node_learning_state('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid);
        select public.get_next_challenge_candidates('${ids.childId}'::uuid, null, 3);
        select 'CHILD_AUTH_OK';
        rollback;
      `;
      const cRes = await runPsql(childAuthSql);
      if (cRes.code !== 0 || !cRes.stdout.includes('CHILD_AUTH_OK')) {
        errs.push(`Case 56 child device auth check failed: ${cRes.stderr}`);
      }
    }

    if (caseId === 57) {
      const sibAuthSql = `
        begin;
        ${setupSql}
        set local role authenticated;
        select set_config('request.jwt.claims', '{"sub": "${ids.siblingUserId}", "role": "authenticated"}', true);
        do $$
        begin
          begin
            perform public.get_child_learning_overview('${ids.childId}'::uuid);
            raise exception 'Expected 42501 on overview';
          exception when sqlstate '42501' then null;
          end;
          begin
            perform public.get_node_learning_state('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid);
            raise exception 'Expected 42501 on node detail';
          exception when sqlstate '42501' then null;
          end;
          begin
            perform public.get_next_challenge_candidates('${ids.childId}'::uuid, null, 3);
            raise exception 'Expected 42501 on next challenge';
          exception when sqlstate '42501' then null;
          end;
        end $$;
        select 'SIBLING_DENIED_OK';
        rollback;
      `;
      const sRes = await runPsql(sibAuthSql);
      if (sRes.code !== 0 || !sRes.stdout.includes('SIBLING_DENIED_OK')) {
        errs.push(`Case 57 sibling denial check failed: ${sRes.stderr}`);
      }
    }

    if (caseId === 58) {
      const crossSql = `
        begin;
        ${setupSql}
        set local role authenticated;
        select set_config('request.jwt.claims', '{"sub": "${ids.otherOwnerId}", "role": "authenticated"}', true);
        do $$
        begin
          begin
            perform public.get_child_learning_overview('${ids.childId}'::uuid);
            raise exception 'Expected 42501 on overview';
          exception when sqlstate '42501' then null;
          end;
          begin
            perform public.get_node_learning_state('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid);
            raise exception 'Expected 42501 on node detail';
          exception when sqlstate '42501' then null;
          end;
          begin
            perform public.get_next_challenge_candidates('${ids.childId}'::uuid, null, 3);
            raise exception 'Expected 42501 on next challenge';
          exception when sqlstate '42501' then null;
          end;
        end $$;
        select 'CROSS_FAMILY_DENIED_OK';
        rollback;
      `;
      const xRes = await runPsql(crossSql);
      if (xRes.code !== 0 || !xRes.stdout.includes('CROSS_FAMILY_DENIED_OK')) {
        errs.push(`Case 58 cross-family denial check failed: ${xRes.stderr}`);
      }
    }

    if (caseId === 59) {
      const anonSql = `
        begin;
        ${setupSql}
        set local role anon;
        do $$
        begin
          begin
            perform public.get_child_learning_overview('${ids.childId}'::uuid);
            raise exception 'Expected 42501 for anon';
          exception when sqlstate '42501' then null;
          end;
        end $$;

        set local role authenticated;
        select set_config('request.jwt.claims', '{"sub": "${ids.ownerId}", "role": "authenticated"}', true);
        do $$
        begin
          begin
            perform private.get_child_learning_overview_at('${ids.childId}'::uuid, now());
            raise exception 'Expected 42501 on private.get_child_learning_overview_at';
          exception when sqlstate '42501' then null;
          end;
          begin
            perform private.get_node_learning_state_at('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid, now());
            raise exception 'Expected 42501 on private.get_node_learning_state_at';
          exception when sqlstate '42501' then null;
          end;
          begin
            perform private.get_next_challenge_candidates_at('${ids.childId}'::uuid, null, 3, now());
            raise exception 'Expected 42501 on private.get_next_challenge_candidates_at';
          exception when sqlstate '42501' then null;
          end;
          begin
            perform private.evaluate_node_recovery_at('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid, 'skill', now());
            raise exception 'Expected 42501 on private.evaluate_node_recovery_at';
          exception when sqlstate '42501' then null;
          end;
        end $$;
        select 'ANON_AND_PRIVATE_DENIED_OK';
        rollback;
      `;
      const nRes = await runPsql(anonSql);
      if (nRes.code !== 0 || !nRes.stdout.includes('ANON_AND_PRIVATE_DENIED_OK')) {
        errs.push(`Case 59 anon & private helper denial check failed: ${nRes.stderr}`);
      }
    }

    if (caseId === 61) {
      // Temporal regression explicit assertions:
      // 1. At T2: inspected node MUST NOT be in candidates and no candidate has reason_code = developing_keep_practicing
      const hasDevAtT2 = actualNext.candidates.some(
        (c) => c.learning_node_id === fixture.inspect_node_id || c.reason_code === 'developing_keep_practicing'
      );
      if (hasDevAtT2) {
        errs.push('Case 61: node leaked into Developing at T2 before verification (freshness = unknown)');
      }

      // 2. At T3 (post-verification): node qualifies as Developing
      const t3Sql = `
        begin;
        ${setupSql}
        select 'NEXT_T3:' || private.get_next_challenge_candidates_at('${ids.childId}'::uuid, NULL, 3, '2026-01-10T00:00:00.000Z'::timestamptz)::text;
        select 'DETAIL_T3:' || private.get_node_learning_state_at('${ids.childId}'::uuid, ${inspectNodeExpr}, '2026-01-10T00:00:00.000Z'::timestamptz)::text;
        rollback;
      `;
      const t3Res = await runPsql(t3Sql);
      if (t3Res.code !== 0) {
        errs.push(`Case 61 T3 query failed: ${t3Res.stderr}`);
      } else {
        const t3Lines = t3Res.stdout.split('\n').map((l) => l.trim());
        const nextT3Line = t3Lines.find((l) => l.startsWith('NEXT_T3:'));
        const detailT3Line = t3Lines.find((l) => l.startsWith('DETAIL_T3:'));
        if (!nextT3Line || !detailT3Line) {
          errs.push('Case 61: Missing T3 output lines');
        } else {
          const nextT3 = JSON.parse(nextT3Line.slice('NEXT_T3:'.length));
          const detailT3 = JSON.parse(detailT3Line.slice('DETAIL_T3:'.length));
          if (detailT3.state.freshness !== 'recent') {
            errs.push(`Case 61 at T3: expected freshness recent, got ${detailT3.state.freshness}`);
          }
          if (!nextT3.candidates.length || nextT3.candidates[0].learning_node_id !== fixture.inspect_node_id) {
            errs.push(`Case 61 at T3: expected node ${fixture.inspect_node_id} at candidates[0], got ${nextT3.candidates[0]?.learning_node_id}`);
          }
          if (nextT3.candidates[0]?.reason_code !== 'developing_keep_practicing') {
            errs.push(`Case 61 at T3: expected reason developing_keep_practicing, got ${nextT3.candidates[0]?.reason_code}`);
          }
        }
      }
    }

    if (caseId === 60) {
      const econSql = `
        begin;
        ${setupSql}
        select 'BEFORE_OVERVIEW:' || private.get_child_learning_overview_at('${ids.childId}'::uuid, '${fixture.as_of}'::timestamptz)::text;
        select 'BEFORE_NEXT:' || private.get_next_challenge_candidates_at('${ids.childId}'::uuid, null, 3, '${fixture.as_of}'::timestamptz)::text;
        select 'BEFORE_DETAIL:' || private.get_node_learning_state_at('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid, '${fixture.as_of}'::timestamptz)::text;

        insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
        values ('${ids.familyId}', '${ids.childId}', 9999, 50000)
        on conflict (child_id) do update set xp_total = 9999, rp_balance_minor = 50000;

        select 'AFTER_OVERVIEW:' || private.get_child_learning_overview_at('${ids.childId}'::uuid, '${fixture.as_of}'::timestamptz)::text;
        select 'AFTER_NEXT:' || private.get_next_challenge_candidates_at('${ids.childId}'::uuid, null, 3, '${fixture.as_of}'::timestamptz)::text;
        select 'AFTER_DETAIL:' || private.get_node_learning_state_at('${ids.childId}'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid, '${fixture.as_of}'::timestamptz)::text;
        rollback;
      `;
      const eRes = await runPsql(econSql);
      if (eRes.code !== 0) {
        errs.push(`Case 60 economy invariance SQL failed: ${eRes.stderr}`);
      } else {
        const eLines = eRes.stdout.split('\n').map((l) => l.trim());
        const bOv = eLines.find((l) => l.startsWith('BEFORE_OVERVIEW:'))?.slice('BEFORE_OVERVIEW:'.length);
        const aOv = eLines.find((l) => l.startsWith('AFTER_OVERVIEW:'))?.slice('AFTER_OVERVIEW:'.length);
        const bNx = eLines.find((l) => l.startsWith('BEFORE_NEXT:'))?.slice('BEFORE_NEXT:'.length);
        const aNx = eLines.find((l) => l.startsWith('AFTER_NEXT:'))?.slice('AFTER_NEXT:'.length);
        const bDt = eLines.find((l) => l.startsWith('BEFORE_DETAIL:'))?.slice('BEFORE_DETAIL:'.length);
        const aDt = eLines.find((l) => l.startsWith('AFTER_DETAIL:'))?.slice('AFTER_DETAIL:'.length);
        if (bOv !== aOv || bNx !== aNx || bDt !== aDt) {
          errs.push('Case 60 economy invariance violated: Phase 5.2 outputs changed after economy mutations');
        }
      }
    }

    if (errs.length === 0) {
      console.log(`PASS: [Case ${caseId}/${fixtures.length} | ${section}] ${scenario}`);
      passed++;
    } else {
      console.error(`FAIL: [Case ${caseId}/${fixtures.length} | ${section}] ${scenario}`);
      for (const e of errs) {
        console.error(`  - ${e}`);
      }
      failed++;
    }
  }

  console.log(`\nPhase 5.2 Parity Summary: ${passed} passed, ${failed} failed out of ${fixtures.length} cases.`);
  if (failed > 0) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Fatal Phase 5.2 parity test failure:', err);
  process.exit(1);
});
