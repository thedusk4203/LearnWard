begin;
select plan(60);

-- ===========================================================================
-- SECTION 1: SCHEMA & CATALOG INVARIANTS (Tests 1-8)
-- ===========================================================================

-- Test 1: No recommendations persistence table exists
select is(
  (select count(*)::integer from information_schema.tables
   where table_schema in ('public', 'private')
     and table_name in ('recommendations', 'child_recommendations', 'next_challenge_recommendations')),
  0,
  'Zero recommendation persistence tables exist in public or private schemas'
);

-- Test 2: No recovery_states persistence table exists
select is(
  (select count(*)::integer from information_schema.tables
   where table_schema in ('public', 'private')
     and table_name in ('recovery_states', 'child_recovery_states')),
  0,
  'Zero recovery_states persistence tables exist in public or private schemas'
);

-- Test 3: No freshness_states persistence table exists
select is(
  (select count(*)::integer from information_schema.tables
   where table_schema in ('public', 'private')
     and table_name in ('freshness_states', 'child_freshness_states')),
  0,
  'Zero freshness_states persistence tables exist in public or private schemas'
);

-- Test 4: pilot-v0.1 remains active catalog
select is(
  (select version from public.learning_catalog_versions where status = 'active'),
  'pilot-v0.1',
  'pilot-v0.1 remains the active catalog version'
);

-- Test 5: pilot-v0.1 node count remains exactly 12
select is(
  (select count(*)::integer from public.learning_nodes where catalog_version = 'pilot-v0.1'),
  12,
  'pilot-v0.1 contains exactly 12 learning nodes (frozen seed untouched)'
);

-- Test 6: pilot-v0.1 prerequisite edge count remains exactly 1
select is(
  (select count(*)::integer from public.learning_prerequisites where catalog_version = 'pilot-v0.1'),
  1,
  'pilot-v0.1 contains exactly 1 prerequisite edge (Single Digit -> Double Digit Addition)'
);

-- Test 7: private.*_at functions are not executable by authenticated or anon
select is(
  (select count(*)::integer
   from information_schema.routine_privileges
   where routine_schema = 'private'
     and routine_name in (
       'evaluate_node_recovery_at',
       'get_child_learning_overview_at',
       'get_node_learning_state_at',
       'get_next_challenge_candidates_at'
     )
     and grantee in ('PUBLIC', 'anon', 'authenticated')),
  0,
  'private.*_at Phase 5.2 functions have zero EXECUTE grants to PUBLIC, anon, or authenticated'
);

-- Test 8: public.get_* Phase 5.2 RPCs are not executable by anon or PUBLIC
select is(
  (select count(*)::integer
   from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in (
       'get_child_learning_overview',
       'get_node_learning_state',
       'get_next_challenge_candidates'
     )
     and grantee in ('PUBLIC', 'anon')),
  0,
  'public Phase 5.2 RPCs have zero EXECUTE grants to PUBLIC or anon'
);

-- ===========================================================================
-- FIXTURES SETUP (Superuser context)
-- ===========================================================================

insert into auth.users (id, aud, role, email) values
  ('52000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'p52_owner_a@test.com'),
  ('52000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'p52_parent_a@test.com'),
  ('52000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'p52_owner_b@test.com'),
  ('52000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'p52_child_a1@test.com'),
  ('52000000-0000-0000-0000-000000000005'::uuid, 'authenticated', 'authenticated', 'p52_child_a2@test.com')
on conflict (id) do nothing;

insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('f5200000-0000-0000-0000-000000000001'::uuid, 'Phase 5.2 Family A', 'UTC', 'en_US', '52000000-0000-0000-0000-000000000001'::uuid),
  ('f5200000-0000-0000-0000-000000000002'::uuid, 'Phase 5.2 Family B', 'UTC', 'en_US', '52000000-0000-0000-0000-000000000003'::uuid)
on conflict (id) do nothing;

insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('f5200000-0000-0000-0000-000000000001'::uuid, '52000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('f5200000-0000-0000-0000-000000000001'::uuid, '52000000-0000-0000-0000-000000000002'::uuid, 'parent', 'active'),
  ('f5200000-0000-0000-0000-000000000002'::uuid, '52000000-0000-0000-0000-000000000003'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year, status, archived_at) values
  ('c5200000-0000-0000-0000-000000000001'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid, 'Child 52A1', 2, 2018, 'active', null),
  ('c5200000-0000-0000-0000-000000000002'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid, 'Child 52A2', 3, 2017, 'active', null),
  ('c5200000-0000-0000-0000-000000000003'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid, 'Archived Child', 2, 2018, 'archived', now())
on conflict (id) do nothing;

insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('d5200000-0000-0000-0000-000000000001'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid, 'c5200000-0000-0000-0000-000000000001'::uuid, '52000000-0000-0000-0000-000000000004'::uuid, 'active', '52000000-0000-0000-0000-000000000001'::uuid),
  ('d5200000-0000-0000-0000-000000000002'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid, 'c5200000-0000-0000-0000-000000000002'::uuid, '52000000-0000-0000-0000-000000000005'::uuid, 'active', '52000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- ===========================================================================
-- SECTION 2: PARAMETER VALIDATION (Tests 9-18)
-- ===========================================================================

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "52000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 9: get_child_learning_overview rejects NULL p_child_id with 22000
select throws_ok(
  $$ select public.get_child_learning_overview(null) $$,
  '22000',
  NULL,
  'get_child_learning_overview rejects NULL p_child_id with 22000'
);

-- Test 10: get_node_learning_state rejects NULL p_child_id with 22000
select throws_ok(
  $$ select public.get_node_learning_state(null, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  '22000',
  NULL,
  'get_node_learning_state rejects NULL p_child_id with 22000'
);

-- Test 11: get_node_learning_state rejects NULL p_learning_node_id with 22000
select throws_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, null) $$,
  '22000',
  NULL,
  'get_node_learning_state rejects NULL p_learning_node_id with 22000'
);

-- Test 12: get_next_challenge_candidates rejects NULL p_child_id with 22000
select throws_ok(
  $$ select public.get_next_challenge_candidates(null, null, 3) $$,
  '22000',
  NULL,
  'get_next_challenge_candidates rejects NULL p_child_id with 22000'
);

-- Test 13: get_next_challenge_candidates rejects p_limit = 0 with 22000
select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, 0) $$,
  '22000',
  NULL,
  'get_next_challenge_candidates rejects p_limit = 0 with 22000'
);

-- Test 14: get_next_challenge_candidates rejects p_limit = -1 with 22000
select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, -1) $$,
  '22000',
  NULL,
  'get_next_challenge_candidates rejects p_limit = -1 with 22000'
);

-- Test 15: get_next_challenge_candidates rejects p_limit = 4 with 22000
select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, 4) $$,
  '22000',
  NULL,
  'get_next_challenge_candidates rejects p_limit = 4 with 22000'
);

-- Test 16: get_next_challenge_candidates rejects p_limit = NULL with 22000
select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, null) $$,
  '22000',
  NULL,
  'get_next_challenge_candidates rejects p_limit = NULL with 22000'
);

-- Test 17: get_next_challenge_candidates rejects invalid p_subject_key ('reading') with 22000
select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, 'reading', 3) $$,
  '22000',
  NULL,
  'get_next_challenge_candidates rejects non-canonical p_subject_key (reading) with 22000'
);

-- Test 18: get_next_challenge_candidates rejects invalid p_subject_key ('social_studies') with 22000
select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, 'social_studies', 3) $$,
  '22000',
  NULL,
  'get_next_challenge_candidates rejects non-canonical p_subject_key (social_studies) with 22000'
);

-- ===========================================================================
-- SECTION 3: AUTHORIZATION & SECURITY MATRIX (Tests 19-42)
-- ===========================================================================

-- Test 19-21: Unauthenticated JWT (missing sub) rejected with 42501 on all 3 RPCs
select set_config('request.jwt.claims', '{}', true);

select throws_ok(
  $$ select public.get_child_learning_overview('c5200000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Unauthenticated caller denied on get_child_learning_overview (42501)'
);

select throws_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Unauthenticated caller denied on get_node_learning_state (42501)'
);

select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, 3) $$,
  '42501',
  NULL,
  'Unauthenticated caller denied on get_next_challenge_candidates (42501)'
);

-- Test 22-24: Missing child rejected with P0002 on all 3 RPCs
select set_config('request.jwt.claims', '{"sub": "52000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select throws_ok(
  $$ select public.get_child_learning_overview('c5299999-9999-9999-9999-999999999999'::uuid) $$,
  'P0002',
  NULL,
  'Non-existent child rejected with P0002 on get_child_learning_overview'
);

select throws_ok(
  $$ select public.get_node_learning_state('c5299999-9999-9999-9999-999999999999'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  'P0002',
  NULL,
  'Non-existent child rejected with P0002 on get_node_learning_state'
);

select throws_ok(
  $$ select public.get_next_challenge_candidates('c5299999-9999-9999-9999-999999999999'::uuid, null, 3) $$,
  'P0002',
  NULL,
  'Non-existent child rejected with P0002 on get_next_challenge_candidates'
);

-- Test 25-27: Archived child rejected with P0002 on all 3 RPCs
select throws_ok(
  $$ select public.get_child_learning_overview('c5200000-0000-0000-0000-000000000003'::uuid) $$,
  'P0002',
  NULL,
  'Archived child rejected with P0002 on get_child_learning_overview'
);

select throws_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000003'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  'P0002',
  NULL,
  'Archived child rejected with P0002 on get_node_learning_state'
);

select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000003'::uuid, null, 3) $$,
  'P0002',
  NULL,
  'Archived child rejected with P0002 on get_next_challenge_candidates'
);

-- Test 28-30: Cross-family adult rejected with 42501 on all 3 RPCs
select set_config('request.jwt.claims', '{"sub": "52000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

select throws_ok(
  $$ select public.get_child_learning_overview('c5200000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Cross-family adult denied on get_child_learning_overview (42501)'
);

select throws_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Cross-family adult denied on get_node_learning_state (42501)'
);

select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, 3) $$,
  '42501',
  NULL,
  'Cross-family adult denied on get_next_challenge_candidates (42501)'
);

-- Test 31-33: Paired sibling child device (Child 52A2) denied for Child 52A1 with 42501 on all 3 RPCs
select set_config('request.jwt.claims', '{"sub": "52000000-0000-0000-0000-000000000005", "role": "authenticated"}', true);

select throws_ok(
  $$ select public.get_child_learning_overview('c5200000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Paired sibling child device denied on get_child_learning_overview (42501)'
);

select throws_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Paired sibling child device denied on get_node_learning_state (42501)'
);

select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, 3) $$,
  '42501',
  NULL,
  'Paired sibling child device denied on get_next_challenge_candidates (42501)'
);

-- Test 34-36: Paired child device (Child 52A1) succeeds for its own child_id on all 3 RPCs
select set_config('request.jwt.claims', '{"sub": "52000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);

select lives_ok(
  $$ select public.get_child_learning_overview('c5200000-0000-0000-0000-000000000001'::uuid) $$,
  'Paired child device succeeds for own child_id on get_child_learning_overview'
);

select lives_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  'Paired child device succeeds for own child_id on get_node_learning_state'
);

select lives_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, 3) $$,
  'Paired child device succeeds for own child_id on get_next_challenge_candidates'
);

-- Test 37-39: Active family parent succeeds on all 3 RPCs
select set_config('request.jwt.claims', '{"sub": "52000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

select lives_ok(
  $$ select public.get_child_learning_overview('c5200000-0000-0000-0000-000000000001'::uuid) $$,
  'Active family parent succeeds on get_child_learning_overview'
);

select lives_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  'Active family parent succeeds on get_node_learning_state'
);

select lives_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, 3) $$,
  'Active family parent succeeds on get_next_challenge_candidates'
);

-- Test 40-42: Authenticated caller cannot execute private.*_at helpers directly
select throws_ok(
  $$ select private.get_child_learning_overview_at('c5200000-0000-0000-0000-000000000001'::uuid, now()) $$,
  '42501',
  NULL,
  'Authenticated caller cannot execute private.get_child_learning_overview_at (42501)'
);

select throws_ok(
  $$ select private.get_node_learning_state_at('c5200000-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid, now()) $$,
  '42501',
  NULL,
  'Authenticated caller cannot execute private.get_node_learning_state_at (42501)'
);

select throws_ok(
  $$ select private.get_next_challenge_candidates_at('c5200000-0000-0000-0000-000000000001'::uuid, null, 3, now()) $$,
  '42501',
  NULL,
  'Authenticated caller cannot execute private.get_next_challenge_candidates_at (42501)'
);

-- ===========================================================================
-- SECTION 4: NODE & CATALOG VALIDATION (Tests 43-47)
-- ===========================================================================

reset role;

-- Create a draft catalog node to test non-active catalog node rejection
select public.create_learning_catalog_draft('draft-p52-test');
insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id)
values ('d5200001-0000-0000-0000-000000000001'::uuid, 'draft-p52-test', 'subject', 'math', 'draft-p52-test:subject:math', 'Draft Math', null);

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "52000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 43: get_node_learning_state rejects non-existent node with P0002
select throws_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, 'b9999999-9999-9999-9999-999999999999'::uuid) $$,
  'P0002',
  NULL,
  'get_node_learning_state rejects non-existent learning_node_id with P0002'
);

-- Test 44: get_node_learning_state rejects node belonging to non-active catalog version with P0002
select throws_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, 'd5200001-0000-0000-0000-000000000001'::uuid) $$,
  'P0002',
  NULL,
  'get_node_learning_state rejects node belonging to non-active catalog version with P0002'
);

-- Temporarily retire active catalog to test LW501 when no active catalog exists
reset role;
alter table public.learning_catalog_versions disable trigger trg_learning_catalog_versions_mutation;
update public.learning_catalog_versions set status = 'retired' where version = 'pilot-v0.1';
alter table public.learning_catalog_versions enable trigger trg_learning_catalog_versions_mutation;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "52000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 45-47: All 3 RPCs raise LW501 when no active catalog version exists
select throws_ok(
  $$ select public.get_child_learning_overview('c5200000-0000-0000-0000-000000000001'::uuid) $$,
  'LW501',
  NULL,
  'get_child_learning_overview raises LW501 when no active catalog exists'
);

select throws_ok(
  $$ select public.get_node_learning_state('c5200000-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  'LW501',
  NULL,
  'get_node_learning_state raises LW501 when no active catalog exists'
);

select throws_ok(
  $$ select public.get_next_challenge_candidates('c5200000-0000-0000-0000-000000000001'::uuid, null, 3) $$,
  'LW501',
  NULL,
  'get_next_challenge_candidates raises LW501 when no active catalog exists'
);

-- Restore pilot-v0.1 as active catalog
reset role;
alter table public.learning_catalog_versions disable trigger trg_learning_catalog_versions_mutation;
update public.learning_catalog_versions set status = 'active' where version = 'pilot-v0.1';
alter table public.learning_catalog_versions enable trigger trg_learning_catalog_versions_mutation;

-- ===========================================================================
-- SECTION 5: COLD-START, RECOVERY, UNLOCK & NEXT CHALLENGE (Tests 48-60)
-- ===========================================================================

-- Test 48: Cold-start overview returns 5 canonical subjects and 3 total skills
select is(
  ((private.get_child_learning_overview_at('c5200000-0000-0000-0000-000000000001'::uuid, '2026-06-01T12:00:00Z'::timestamptz)) -> 'overall_coverage' ->> 'total_skills')::integer,
  3,
  'Cold-start overview reports 3 total active pilot-v0.1 skills'
);

-- Test 49: Cold-start Double Digit Addition is locked (is_satisfied = false)
select is(
  ((private.get_node_learning_state_at(
    'c5200000-0000-0000-0000-000000000001'::uuid,
    'b0000003-0000-0000-0000-000000000002'::uuid,
    '2026-06-01T12:00:00Z'::timestamptz
  )) -> 'prerequisite_state' ->> 'is_satisfied')::boolean,
  false,
  'Double Digit Addition is locked before Single Digit Addition attains sticky Mastered'
);

-- Test 50: Cold-start Next Challenge returns 2 unlocked grade-2-compatible explore candidates
select is(
  jsonb_array_length(
    (private.get_next_challenge_candidates_at('c5200000-0000-0000-0000-000000000001'::uuid, null, 3, '2026-06-01T12:00:00Z'::timestamptz)) -> 'candidates'
  ),
  2,
  'Cold-start Next Challenge returns 2 unlocked explore candidates in pilot-v0.1'
);

-- Insert weak component evidence on Single Digit Addition (40% at 2026-05-28)
insert into public.assessments (
  id, family_id, child_id, created_by_user_id, status, subject_key, subject,
  assessment_type, difficulty, title, occurred_at, raw_score, max_score, learning_catalog_version
) values (
  'a5210000-0000-0000-0000-000000000001'::uuid,
  'f5200000-0000-0000-0000-000000000001'::uuid,
  'c5200000-0000-0000-0000-000000000001'::uuid,
  '52000000-0000-0000-0000-000000000001'::uuid,
  'verified', 'math', 'Mathematics', 'quiz', 'normal', 'Weak Quiz',
  '2026-05-28T12:00:00Z'::timestamptz, 40, 100, 'pilot-v0.1'
);

insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
values ('75210000-0000-0000-0000-000000000001'::uuid, 'verify', '52000000-0000-0000-0000-000000000001'::uuid, 'a5210000-0000-0000-0000-000000000001'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid);

insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id)
values ('e5210000-0000-0000-0000-000000000001'::uuid, '75210000-0000-0000-0000-000000000001'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid, 'a5210000-0000-0000-0000-000000000001'::uuid, 'verified', 'pending_review', 'verified', '52000000-0000-0000-0000-000000000001'::uuid);

insert into public.verified_learning_events (
  id, assessment_id, family_id, child_id, subject_key, subject, title,
  assessment_type, difficulty, raw_score, max_score, normalized_score,
  occurred_at, verified_at, verified_by_user_id, review_event_id, grade_level_snapshot, learning_catalog_version
) values (
  '15210000-0000-0000-0000-000000000001'::uuid,
  'a5210000-0000-0000-0000-000000000001'::uuid,
  'f5200000-0000-0000-0000-000000000001'::uuid,
  'c5200000-0000-0000-0000-000000000001'::uuid,
  'math', 'Mathematics', 'Weak Quiz', 'quiz', 'normal', 40, 100, 4.00,
  '2026-05-28T12:00:00Z'::timestamptz, '2026-05-28T12:00:00Z'::timestamptz,
  '52000000-0000-0000-0000-000000000001'::uuid, 'e5210000-0000-0000-0000-000000000001'::uuid, 2, 'pilot-v0.1'
);

insert into public.learning_evidence_events (
  id, family_id, child_id, verified_learning_event_id, assessment_id, learning_node_id,
  catalog_version, node_type, subject_key, grade_level_snapshot, assessment_type,
  difficulty, score_source, performance_pct, specificity_weight, level_weight,
  item_count, correct_count, occurred_at, effective_occurred_at, verified_at
) values (
  'ee521000-0000-0000-0000-000000000001'::uuid,
  'f5200000-0000-0000-0000-000000000001'::uuid,
  'c5200000-0000-0000-0000-000000000001'::uuid,
  '15210000-0000-0000-0000-000000000001'::uuid,
  'a5210000-0000-0000-0000-000000000001'::uuid,
  'b0000003-0000-0000-0000-000000000001'::uuid,
  'pilot-v0.1', 'skill', 'math', 2, 'quiz',
  'normal', 'component_score', 40.00, 1.00, 1.00,
  null, null,
  '2026-05-28T12:00:00Z'::timestamptz, '2026-05-28T12:00:00Z'::timestamptz, '2026-05-28T12:00:00Z'::timestamptz
);

insert into public.mastery_state_revisions (
  id, family_id, child_id, learning_node_id, evidence_event_id, engine_version,
  prior_mastery_score, new_mastery_score, effective_weight, alpha_used,
  effective_evidence_count, distinct_assessment_count, created_at
) values (
  'ab521000-0000-0000-0000-000000000001'::uuid,
  'f5200000-0000-0000-0000-000000000001'::uuid,
  'c5200000-0000-0000-0000-000000000001'::uuid,
  'b0000003-0000-0000-0000-000000000001'::uuid,
  'ee521000-0000-0000-0000-000000000001'::uuid,
  'mastery-v0.1', null, 40.00, 1.00, 0.35, 1, 1, '2026-05-28T12:00:00Z'::timestamptz
);

insert into public.child_mastery_states (
  child_id, learning_node_id, family_id, engine_version, mastery_score,
  effective_evidence_count, distinct_assessment_count, last_evidence_event_id,
  last_evidence_occurred_at, last_verified_at, latest_revision_id, mastery_attained_at, updated_at
) values (
  'c5200000-0000-0000-0000-000000000001'::uuid,
  'b0000003-0000-0000-0000-000000000001'::uuid,
  'f5200000-0000-0000-0000-000000000001'::uuid,
  'mastery-v0.1', 40.00, 1, 1, 'ee521000-0000-0000-0000-000000000001'::uuid,
  '2026-05-28T12:00:00Z'::timestamptz, '2026-05-28T12:00:00Z'::timestamptz,
  'ab521000-0000-0000-0000-000000000001'::uuid, null, '2026-05-28T12:00:00Z'::timestamptz
);

-- Test 51: Weak component evidence triggers recovery_signal = review_suggested
select is(
  (private.evaluate_node_recovery_at(
    'c5200000-0000-0000-0000-000000000001'::uuid,
    'b0000003-0000-0000-0000-000000000001'::uuid,
    'skill',
    '2026-06-01T12:00:00Z'::timestamptz
  )) ->> 'recovery_signal',
  'review_suggested',
  'Weak component evidence (40%) evaluates to recovery_signal = review_suggested'
);

-- Test 52: Next Challenge ranks recovery node #1 with priority_class = recovery
select is(
  (private.get_next_challenge_candidates_at(
    'c5200000-0000-0000-0000-000000000001'::uuid, null, 3, '2026-06-01T12:00:00Z'::timestamptz
  )) -> 'candidates' -> 0 ->> 'priority_class',
  'recovery',
  'Next Challenge ranks recovery node at #1 with priority_class = recovery'
);

-- Test 53: Recovery candidate has recommended_difficulty = below_level
select is(
  (private.get_next_challenge_candidates_at(
    'c5200000-0000-0000-0000-000000000001'::uuid, null, 3, '2026-06-01T12:00:00Z'::timestamptz
  )) -> 'candidates' -> 0 ->> 'recommended_difficulty',
  'below_level',
  'Recovery candidate has recommended_difficulty = below_level'
);

-- Test 54: 30 days + 1 second expires unresolved weakness to none
select is(
  (private.evaluate_node_recovery_at(
    'c5200000-0000-0000-0000-000000000001'::uuid,
    'b0000003-0000-0000-0000-000000000001'::uuid,
    'skill',
    '2026-06-27T12:00:01Z'::timestamptz
  )) ->> 'recovery_signal',
  'none',
  'Unresolved weakness expires to none at 30 days + 1 second'
);

-- Simulate sticky Mastered attainment on Single Digit Addition + credible clear on a second VLE
insert into public.assessments (
  id, family_id, child_id, created_by_user_id, status, subject_key, subject,
  assessment_type, difficulty, title, occurred_at, raw_score, max_score, learning_catalog_version
) values (
  'a5210000-0000-0000-0000-000000000002'::uuid,
  'f5200000-0000-0000-0000-000000000001'::uuid,
  'c5200000-0000-0000-0000-000000000001'::uuid,
  '52000000-0000-0000-0000-000000000001'::uuid,
  'verified', 'math', 'Mathematics', 'quiz', 'normal', 'Clear Quiz',
  '2026-05-30T12:00:00Z'::timestamptz, 95, 100, 'pilot-v0.1'
);

insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
values ('75210000-0000-0000-0000-000000000002'::uuid, 'verify', '52000000-0000-0000-0000-000000000001'::uuid, 'a5210000-0000-0000-0000-000000000002'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid);

insert into public.assessment_review_events (id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id)
values ('e5210000-0000-0000-0000-000000000002'::uuid, '75210000-0000-0000-0000-000000000002'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid, 'a5210000-0000-0000-0000-000000000002'::uuid, 'verified', 'pending_review', 'verified', '52000000-0000-0000-0000-000000000001'::uuid);

insert into public.verified_learning_events (
  id, assessment_id, family_id, child_id, subject_key, subject, title,
  assessment_type, difficulty, raw_score, max_score, normalized_score,
  occurred_at, verified_at, verified_by_user_id, review_event_id, grade_level_snapshot, learning_catalog_version
) values (
  '15210000-0000-0000-0000-000000000002'::uuid,
  'a5210000-0000-0000-0000-000000000002'::uuid,
  'f5200000-0000-0000-0000-000000000001'::uuid,
  'c5200000-0000-0000-0000-000000000001'::uuid,
  'math', 'Mathematics', 'Clear Quiz', 'quiz', 'normal', 95, 100, 9.50,
  '2026-05-30T12:00:00Z'::timestamptz, '2026-05-30T12:00:00Z'::timestamptz,
  '52000000-0000-0000-0000-000000000001'::uuid, 'e5210000-0000-0000-0000-000000000002'::uuid, 2, 'pilot-v0.1'
);

insert into public.learning_evidence_events (
  id, family_id, child_id, verified_learning_event_id, assessment_id, learning_node_id,
  catalog_version, node_type, subject_key, grade_level_snapshot, assessment_type,
  difficulty, score_source, performance_pct, specificity_weight, level_weight,
  item_count, correct_count, occurred_at, effective_occurred_at, verified_at
) values (
  'ee521000-0000-0000-0000-000000000002'::uuid,
  'f5200000-0000-0000-0000-000000000001'::uuid,
  'c5200000-0000-0000-0000-000000000001'::uuid,
  '15210000-0000-0000-0000-000000000002'::uuid,
  'a5210000-0000-0000-0000-000000000002'::uuid,
  'b0000003-0000-0000-0000-000000000001'::uuid,
  'pilot-v0.1', 'skill', 'math', 2, 'quiz',
  'normal', 'component_score', 95.00, 1.00, 1.00,
  null, null,
  '2026-05-30T12:00:00Z'::timestamptz, '2026-05-30T12:00:00Z'::timestamptz, '2026-05-30T12:00:00Z'::timestamptz
);

update public.child_mastery_states
set mastery_score = 92.00,
    mastery_attained_at = '2026-05-30T12:00:00Z'::timestamptz,
    effective_evidence_count = 2,
    distinct_assessment_count = 2,
    last_evidence_event_id = 'ee521000-0000-0000-0000-000000000002'::uuid,
    last_evidence_occurred_at = '2026-05-30T12:00:00Z'::timestamptz,
    last_verified_at = '2026-05-30T12:00:00Z'::timestamptz
where child_id = 'c5200000-0000-0000-0000-000000000001'::uuid
  and learning_node_id = 'b0000003-0000-0000-0000-000000000001'::uuid;

-- Test 55: Credible clear resets recovery_signal to none
select is(
  (private.evaluate_node_recovery_at(
    'c5200000-0000-0000-0000-000000000001'::uuid,
    'b0000003-0000-0000-0000-000000000001'::uuid,
    'skill',
    '2026-06-01T12:00:00Z'::timestamptz
  )) ->> 'recovery_signal',
  'none',
  'Later credible clear (95% component_score) resets recovery_signal to none'
);

-- Test 56: Sticky Mastered on Single Digit Addition unlocks Double Digit Addition
select is(
  (private.get_node_learning_state_at(
    'c5200000-0000-0000-0000-000000000001'::uuid,
    'b0000003-0000-0000-0000-000000000002'::uuid,
    '2026-06-01T12:00:00Z'::timestamptz
  )) -> 'prerequisite_state' ->> 'is_satisfied',
  'true',
  'Double Digit Addition unlocks when prerequisite Single Digit Addition has mastery_attained_at <= as_of'
);

-- Test 57: Unlocked unseen Double Digit Addition becomes #1 Next Challenge candidate (priority_class = unlock)
select is(
  (private.get_next_challenge_candidates_at(
    'c5200000-0000-0000-0000-000000000001'::uuid, null, 3, '2026-06-01T12:00:00Z'::timestamptz
  )) -> 'candidates' -> 0 ->> 'canonical_key',
  'pilot-v0.1:math:arithmetic:addition:double_digit',
  'Double Digit Addition is recommended at #1 once prerequisite is mastered'
);

-- Test 58: Unlock candidate has reason_code = unlock_prerequisites_mastered and recommended_difficulty = normal
select is(
  (private.get_next_challenge_candidates_at(
    'c5200000-0000-0000-0000-000000000001'::uuid, null, 3, '2026-06-01T12:00:00Z'::timestamptz
  )) -> 'candidates' -> 0 ->> 'reason_code',
  'unlock_prerequisites_mastered',
  'Unlock candidate has reason_code = unlock_prerequisites_mastered'
);

-- Test 59: Freshness aging > 45 days on sticky Mastered node transitions to needs_refresh and recommends refresh
select is(
  (private.get_next_challenge_candidates_at(
    'c5200000-0000-0000-0000-000000000001'::uuid, null, 3, '2026-07-16T12:00:00Z'::timestamptz
  )) -> 'candidates' -> 0 ->> 'priority_class',
  'refresh',
  'After 47 days without evidence, sticky Mastered Single Digit Addition enters refresh priority (#1)'
);

-- Test 60: Economy invariance — mutating child_balances has zero effect on Phase 5.2 outputs
insert into public.child_balances (child_id, family_id, xp_total, rp_balance, rp_lifetime_earned, rp_lifetime_spent)
values ('c5200000-0000-0000-0000-000000000001'::uuid, 'f5200000-0000-0000-0000-000000000001'::uuid, 5000, 250, 500, 250)
on conflict (child_id) do update set xp_total = 5000, rp_balance = 250;

select is(
  (private.get_next_challenge_candidates_at(
    'c5200000-0000-0000-0000-000000000001'::uuid, null, 3, '2026-06-01T12:00:00Z'::timestamptz
  )) -> 'candidates' -> 0 ->> 'canonical_key',
  'pilot-v0.1:math:arithmetic:addition:double_digit',
  'Economy balance mutations do not alter Phase 5.2 Next Challenge recommendations'
);

select * from finish();
rollback;
