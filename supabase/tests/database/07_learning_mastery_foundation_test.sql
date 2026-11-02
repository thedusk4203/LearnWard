begin;
select plan(89);

-- ===========================================================================
-- FIXTURES SETUP (Superuser context)
-- ===========================================================================

-- 1. Create auth users
insert into auth.users (id, aud, role, email) values
  ('50000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'p51_owner_a@test.com'),
  ('50000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'p51_owner_b@test.com'),
  ('50000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'p51_child_a1@test.com'),
  ('50000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'p51_child_a2@test.com')
on conflict (id) do nothing;

-- 2. Create families
insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('f5000000-0000-0000-0000-000000000001'::uuid, 'Phase 5.1 Family A', 'UTC', 'en_US', '50000000-0000-0000-0000-000000000001'::uuid),
  ('f5000000-0000-0000-0000-000000000002'::uuid, 'Phase 5.1 Family B', 'UTC', 'en_US', '50000000-0000-0000-0000-000000000002'::uuid)
on conflict (id) do nothing;

-- 3. Create family memberships
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('f5000000-0000-0000-0000-000000000001'::uuid, '50000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('f5000000-0000-0000-0000-000000000002'::uuid, '50000000-0000-0000-0000-000000000002'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

-- 4. Create child profiles
insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
  ('c5000000-0000-0000-0000-000000000001'::uuid, 'f5000000-0000-0000-0000-000000000001'::uuid, 'Child 51A1', 4, 2016),
  ('c5000000-0000-0000-0000-000000000002'::uuid, 'f5000000-0000-0000-0000-000000000001'::uuid, 'Child 51A2', 2, 2018),
  ('c5000000-0000-0000-0000-000000000003'::uuid, 'f5000000-0000-0000-0000-000000000002'::uuid, 'Child 51B1', 5, 2015)
on conflict (id) do nothing;

-- 5. Create child device grants
insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('d5000000-0000-0000-0000-000000000001'::uuid, 'f5000000-0000-0000-0000-000000000001'::uuid, 'c5000000-0000-0000-0000-000000000001'::uuid, '50000000-0000-0000-0000-000000000003'::uuid, 'active', '50000000-0000-0000-0000-000000000001'::uuid),
  ('d5000000-0000-0000-0000-000000000002'::uuid, 'f5000000-0000-0000-0000-000000000001'::uuid, 'c5000000-0000-0000-0000-000000000002'::uuid, '50000000-0000-0000-0000-000000000004'::uuid, 'active', '50000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- ===========================================================================
-- SECTION 1: COMMAND RECEIPTS EXTENSION (Tests 1-5)
-- ===========================================================================

-- Test 1: Preserves frozen operation: create_draft
select lives_ok(
  $$ insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id)
     values (gen_random_uuid(), 'f5000000-0000-0000-0000-000000000001'::uuid, '50000000-0000-0000-0000-000000000001'::uuid, 'create_draft', gen_random_uuid()) $$,
  'Command receipt accepts frozen operation: create_draft'
);

-- Test 2: Preserves frozen operations: verify & spin_wheel
select lives_ok(
  $$ insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id)
     values (gen_random_uuid(), 'f5000000-0000-0000-0000-000000000001'::uuid, '50000000-0000-0000-0000-000000000001'::uuid, 'spin_wheel', gen_random_uuid()) $$,
  'Command receipt accepts frozen operation: spin_wheel'
);

-- Test 3: Accepts new Phase 5 operation: process_learning
select lives_ok(
  $$ insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id)
     values (gen_random_uuid(), 'f5000000-0000-0000-0000-000000000001'::uuid, '50000000-0000-0000-0000-000000000001'::uuid, 'process_learning', gen_random_uuid()) $$,
  'Command receipt accepts new Phase 5 operation: process_learning'
);

-- Test 4: Rejects unknown operation
select throws_ok(
  $$ insert into public.command_receipts (command_id, family_id, actor_user_id, operation, resource_id)
     values (gen_random_uuid(), 'f5000000-0000-0000-0000-000000000001'::uuid, '50000000-0000-0000-0000-000000000001'::uuid, 'unknown_op', gen_random_uuid()) $$,
  '23514',
  NULL,
  'Command receipt rejects unknown operation'
);

-- Test 5: Pre-existing command receipt check constraint verification
select is(
  (select count(*)::integer from pg_constraint where conname = 'command_receipts_operation_check'),
  1,
  'Exactly one command_receipts_operation_check constraint exists'
);

-- ===========================================================================
-- SECTION 2: CATALOG REGISTRY & SEED INTEGRITY (Tests 6-10)
-- ===========================================================================

-- Test 6: Exactly one active catalog version exists initially
select is(
  (select count(*)::integer from public.learning_catalog_versions where status = 'active'),
  1,
  'Exactly one catalog version is active'
);

-- Test 7: Active catalog version is pilot-v0.1
select is(
  (select version from public.learning_catalog_versions where status = 'active'),
  'pilot-v0.1',
  'Active catalog version is pilot-v0.1'
);

-- Test 8: pilot-v0.1 contains all 5 canonical Subject roots
select is(
  (select count(*)::integer from public.learning_nodes
   where catalog_version = 'pilot-v0.1' and node_type = 'subject' and parent_id is null),
  5,
  'pilot-v0.1 contains exactly 5 Subject root nodes'
);

-- Test 9: All 5 canonical subjects are present
select is(
  (select array_agg(subject_key order by subject_key) from public.learning_nodes
   where catalog_version = 'pilot-v0.1' and node_type = 'subject'),
  array['english', 'literature', 'math', 'other', 'science'],
  'pilot-v0.1 contains all canonical subject keys'
);

-- Test 10: Subject root uniqueness per catalog
select throws_ok(
  $$ insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
     values ('pilot-v0.1', 'subject', 'math', 'pilot-v0.1:subject:math:dup', 'Duplicate Math', null) $$,
  '23505',
  NULL,
  'Duplicate Subject root node for same subject and catalog is rejected by unique index'
);

-- ===========================================================================
-- SECTION 3: HIERARCHY & PREREQUISITE INTEGRITY (Tests 11-16)
-- ===========================================================================

-- Seed a test draft catalog for hierarchy mutation validation
insert into public.learning_catalog_versions (version, status) values ('draft-test-v1', 'draft');
insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
values ('draft-test-v1', 'subject', 'math', 'draft-test-v1:subject:math', 'Math', null);

-- Test 11: Cross-subject parent rejected with LW004
select throws_ok(
  $$ insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
     select 'draft-test-v1', 'domain', 'english', 'draft-test-v1:english:test_domain', 'Test Domain', id
     from public.learning_nodes where catalog_version = 'draft-test-v1' and canonical_key = 'draft-test-v1:subject:math' $$,
  'LW004',
  NULL,
  'Node pointing to parent in different subject is rejected with LW004'
);

-- Test 12: Subject node cannot have parent_id
select throws_ok(
  $$ insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
     values ('draft-test-v1', 'subject', 'other', 'draft-test-v1:other:test_sub', 'Test Sub', 'b0000001-0000-0000-0000-000000000001'::uuid) $$,
  'LW004',
  NULL,
  'Subject node with non-null parent_id is rejected with LW004'
);

-- Test 13: Non-subject node must have parent_id
select throws_ok(
  $$ insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
     values ('draft-test-v1', 'domain', 'math', 'draft-test-v1:math:orphan_domain', 'Orphan Domain', null) $$,
  'LW004',
  NULL,
  'Non-subject node without parent_id is rejected with LW004'
);

-- Test 14: Prerequisite edge enforces composite foreign key (cross-subject skill rejected with 23503)
select throws_ok(
  $$ insert into public.learning_prerequisites (catalog_version, subject_key, prerequisite_node_id, dependent_node_id)
     values ('pilot-v0.1', 'math',
             'b0000003-0000-0000-0000-000000000001'::uuid, -- Math skill
             'b0000003-0000-0000-0000-000000000003'::uuid) $$, -- English skill
  '23503',
  NULL,
  'Prerequisite edge linking cross-subject nodes is rejected by composite foreign key (23503)'
);

-- Test 15: Prerequisite self-loop rejected by check constraint
select throws_ok(
  $$ insert into public.learning_prerequisites (catalog_version, subject_key, prerequisite_node_id, dependent_node_id)
     values ('pilot-v0.1', 'math',
             'b0000003-0000-0000-0000-000000000001'::uuid,
             'b0000003-0000-0000-0000-000000000001'::uuid) $$,
  '23514',
  NULL,
  'Prerequisite self-loop is rejected by check constraint (23514)'
);

-- Test 16: Published catalog node mutation rejected (immutability LW102)
select throws_ok(
  $$ update public.learning_nodes
     set title = 'Mutated Title'
     where catalog_version = 'pilot-v0.1' and canonical_key = 'pilot-v0.1:subject:math' $$,
  'LW102',
  NULL,
  'Mutating nodes in active catalog is rejected with LW102 (immutability)'
);

-- Test 17: Mutating learning_nodes.catalog_version is rejected with LW102
select throws_ok(
  $$ update public.learning_nodes set catalog_version = 'draft-test-v1'
     where catalog_version = 'pilot-v0.1' and canonical_key = 'pilot-v0.1:subject:math' $$,
  'LW102',
  NULL,
  'Mutating learning_nodes.catalog_version is rejected with LW102'
);

-- Test 18: Mutating learning_prerequisites.catalog_version is rejected with LW102
select throws_ok(
  $$ update public.learning_prerequisites set catalog_version = 'draft-test-v1'
     where catalog_version = 'pilot-v0.1' $$,
  'LW102',
  NULL,
  'Mutating learning_prerequisites.catalog_version is rejected with LW102'
);

-- ===========================================================================
-- SECTION 4: CATALOG PROMOTION & AUTHORIZATION (Tests 19-26)
-- ===========================================================================

-- Test 19: Anonymous caller cannot invoke promote_learning_catalog_version
set local role anon;
select throws_ok(
  $$ select public.promote_learning_catalog_version('pilot-v0.2') $$,
  '42501',
  NULL,
  'Anonymous caller cannot execute promote_learning_catalog_version'
);

-- Test 20: Paired child caller cannot invoke promote_learning_catalog_version
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.promote_learning_catalog_version('pilot-v0.2') $$,
  '42501',
  NULL,
  'Paired child caller cannot execute promote_learning_catalog_version'
);

-- Test 21: Active family adult caller cannot invoke promote_learning_catalog_version
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.promote_learning_catalog_version('pilot-v0.2') $$,
  '42501',
  NULL,
  'Active family adult cannot execute promote_learning_catalog_version'
);

-- Reset to service_role / superuser context
reset role;

-- Test 22: Promote non-existent version fails with P0002
select throws_ok(
  $$ select public.promote_learning_catalog_version('non-existent-v1.0') $$,
  'P0002',
  NULL,
  'Promote non-existent draft version fails with P0002'
);

-- Test 23: Setup draft catalog with incomplete roots and attempt promote (should fail LW004)
insert into public.learning_catalog_versions (version, status) values ('pilot-v0.2-bad', 'draft');
insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
values ('pilot-v0.2-bad', 'subject', 'math', 'pilot-v0.2-bad:subject:math', 'Math', null);

select throws_ok(
  $$ select public.promote_learning_catalog_version('pilot-v0.2-bad') $$,
  'LW004',
  NULL,
  'Promoting draft catalog missing required 5 Subject roots fails with LW004'
);

-- Test 24: Candidate catalog with prerequisite cycle is rejected with LW004
insert into public.learning_catalog_versions (version, status) values ('pilot-v0.2-cycle', 'draft');
insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
values
  ('pilot-v0.2-cycle', 'subject', 'math', 'pilot-v0.2-cycle:subject:math', 'Mathematics', null),
  ('pilot-v0.2-cycle', 'subject', 'english', 'pilot-v0.2-cycle:subject:english', 'English', null),
  ('pilot-v0.2-cycle', 'subject', 'literature', 'pilot-v0.2-cycle:subject:literature', 'Literature', null),
  ('pilot-v0.2-cycle', 'subject', 'science', 'pilot-v0.2-cycle:subject:science', 'Science', null),
  ('pilot-v0.2-cycle', 'subject', 'other', 'pilot-v0.2-cycle:subject:other', 'Other', null);

insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
values
  ('pilot-v0.2-cycle', 'domain', 'math', 'pilot-v0.2-cycle:math:domain1', 'Domain 1',
   (select id from public.learning_nodes where catalog_version = 'pilot-v0.2-cycle' and canonical_key = 'pilot-v0.2-cycle:subject:math'));

insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
values
  ('pilot-v0.2-cycle', 'topic', 'math', 'pilot-v0.2-cycle:math:topic1', 'Topic 1',
   (select id from public.learning_nodes where catalog_version = 'pilot-v0.2-cycle' and canonical_key = 'pilot-v0.2-cycle:math:domain1'));

insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id)
values
  ('c0000001-0000-0000-0000-000000000001'::uuid, 'pilot-v0.2-cycle', 'skill', 'math', 'pilot-v0.2-cycle:math:skill1', 'Skill 1', (select id from public.learning_nodes where catalog_version = 'pilot-v0.2-cycle' and canonical_key = 'pilot-v0.2-cycle:math:topic1')),
  ('c0000001-0000-0000-0000-000000000002'::uuid, 'pilot-v0.2-cycle', 'skill', 'math', 'pilot-v0.2-cycle:math:skill2', 'Skill 2', (select id from public.learning_nodes where catalog_version = 'pilot-v0.2-cycle' and canonical_key = 'pilot-v0.2-cycle:math:topic1'));

insert into public.learning_prerequisites (catalog_version, subject_key, prerequisite_node_id, dependent_node_id)
values
  ('pilot-v0.2-cycle', 'math', 'c0000001-0000-0000-0000-000000000001'::uuid, 'c0000001-0000-0000-0000-000000000002'::uuid),
  ('pilot-v0.2-cycle', 'math', 'c0000001-0000-0000-0000-000000000002'::uuid, 'c0000001-0000-0000-0000-000000000001'::uuid);

select throws_ok(
  $$ select public.promote_learning_catalog_version('pilot-v0.2-cycle') $$,
  'LW004',
  NULL,
  'Promoting draft catalog with cyclic prerequisites is rejected with LW004'
);

-- Test 25: Setup complete valid draft catalog pilot-v0.2 and promote successfully
insert into public.learning_catalog_versions (version, status) values ('pilot-v0.2', 'draft');
insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id)
values
  ('pilot-v0.2', 'subject', 'math', 'pilot-v0.2:subject:math', 'Mathematics', null),
  ('pilot-v0.2', 'subject', 'english', 'pilot-v0.2:subject:english', 'English', null),
  ('pilot-v0.2', 'subject', 'literature', 'pilot-v0.2:subject:literature', 'Literature', null),
  ('pilot-v0.2', 'subject', 'science', 'pilot-v0.2:subject:science', 'Science', null),
  ('pilot-v0.2', 'subject', 'other', 'pilot-v0.2:subject:other', 'Other', null);

select lives_ok(
  $$ select public.promote_learning_catalog_version('pilot-v0.2') $$,
  'Service role promotes valid complete draft catalog pilot-v0.2'
);

-- Test 26: After promotion, exactly one active version exists and previous was retired
select is(
  (select version from public.learning_catalog_versions where status = 'active'),
  'pilot-v0.2',
  'Newly promoted version pilot-v0.2 is now active'
);

-- Roll back active version to pilot-v0.1 for fixture consistency across rest of test
update public.learning_catalog_versions set status = 'retired' where version = 'pilot-v0.2';
update public.learning_catalog_versions set status = 'active' where version = 'pilot-v0.1';

-- ===========================================================================
-- SECTION 5: PROVENANCE SNAPSHOTTING & LEGACY PROTECTION (Tests 27-31)
-- ===========================================================================

-- Test 27: Assessments table has learning_catalog_version column without default
select is(
  (select column_default from information_schema.columns
   where table_name = 'assessments' and column_name = 'learning_catalog_version'),
  NULL,
  'assessments.learning_catalog_version has no default column constraint'
);

-- Test 28: Verified_learning_events has learning_catalog_version column without default
select is(
  (select column_default from information_schema.columns
   where table_name = 'verified_learning_events' and column_name = 'learning_catalog_version'),
  NULL,
  'verified_learning_events.learning_catalog_version has no default column constraint'
);

-- Test 29: Creating an assessment snapshots authoritative active catalog version ignoring caller input
insert into public.assessments (
  id, family_id, child_id, created_by_user_id, status, subject_key, subject, assessment_type, title,
  occurred_at, raw_score, max_score, learning_catalog_version
) values (
  'a5000000-0000-0000-0000-000000000001'::uuid,
  'f5000000-0000-0000-0000-000000000001'::uuid,
  'c5000000-0000-0000-0000-000000000001'::uuid,
  '50000000-0000-0000-0000-000000000001'::uuid,
  'draft', 'math', 'Mathematics', 'quiz', 'Math Quiz 1',
  now(), 85, 100, 'obsolete-v0.0'
);

select is(
  (select learning_catalog_version from public.assessments where id = 'a5000000-0000-0000-0000-000000000001'::uuid),
  'pilot-v0.1',
  'Assessment creation stamped authoritative active catalog pilot-v0.1 ignoring caller input'
);

-- Test 30: Updating verified assessment is rejected by frozen LW103
update public.assessments set status = 'pending_review' where id = 'a5000000-0000-0000-0000-000000000001'::uuid;

insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
values (
  '70000000-0000-0000-0000-000000000001'::uuid, 'verify',
  '50000000-0000-0000-0000-000000000001'::uuid,
  'a5000000-0000-0000-0000-000000000001'::uuid,
  'f5000000-0000-0000-0000-000000000001'::uuid
) on conflict do nothing;

insert into public.assessment_review_events (
  id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id
) values (
  'e5000000-0000-0000-0000-000000000001'::uuid,
  '70000000-0000-0000-0000-000000000001'::uuid,
  'f5000000-0000-0000-0000-000000000001'::uuid,
  'a5000000-0000-0000-0000-000000000001'::uuid,
  'verified',
  'pending_review',
  'verified',
  '50000000-0000-0000-0000-000000000001'::uuid
);

insert into public.verified_learning_events (
  id, assessment_id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty,
  raw_score, max_score, normalized_score, occurred_at, verified_at, verified_by_user_id,
  review_event_id, grade_level_snapshot
) values (
  '15000000-0000-0000-0000-000000000001'::uuid,
  'a5000000-0000-0000-0000-000000000001'::uuid,
  'f5000000-0000-0000-0000-000000000001'::uuid,
  'c5000000-0000-0000-0000-000000000001'::uuid,
  'math', 'Mathematics', 'Math Quiz 1', 'quiz', 'normal',
  85, 100, 8.50, now(), now(), '50000000-0000-0000-0000-000000000001'::uuid,
  'e5000000-0000-0000-0000-000000000001'::uuid, 4
);

update public.assessments set status = 'verified' where id = 'a5000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  $$ update public.assessments set title = 'Changed' where id = 'a5000000-0000-0000-0000-000000000001'::uuid $$,
  'LW103',
  NULL,
  'Frozen LW103 guards verified assessment against mutation'
);

-- Test 31: VLE copied assessment catalog snapshot
select is(
  (select learning_catalog_version from public.verified_learning_events where id = '15000000-0000-0000-0000-000000000001'::uuid),
  'pilot-v0.1',
  'VLE accurately copied assessment catalog snapshot'
);

-- ===========================================================================
-- ===========================================================================
-- SECTION 6: ASSESSMENT LEARNING MAPPINGS RPC & SECURITY (Tests 32-47)
-- ===========================================================================

-- Create a second assessment in draft state for mapping lifecycle tests
insert into public.assessments (
  id, family_id, child_id, created_by_user_id, status, subject_key, subject, assessment_type, title,
  occurred_at, raw_score, max_score
) values (
  'a5000000-0000-0000-0000-000000000002'::uuid,
  'f5000000-0000-0000-0000-000000000001'::uuid,
  'c5000000-0000-0000-0000-000000000001'::uuid,
  '50000000-0000-0000-0000-000000000001'::uuid,
  'draft', 'math', 'Mathematics', 'quiz', 'Math Quiz 2',
  now(), 90, 100
);

-- Test 32: Cannot map assessment in draft status
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[{"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "assessment_total"}]'::jsonb
     ) $$,
  'LW103',
  NULL,
  'set_assessment_learning_mappings rejects draft assessment'
);

-- Move assessment 2 to pending_review
reset role;
update public.assessments set status = 'pending_review' where id = 'a5000000-0000-0000-0000-000000000002'::uuid;

-- Test 33: Anonymous caller cannot set mappings
set local role anon;
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[]'::jsonb
     ) $$,
  '42501',
  NULL,
  'Anonymous caller cannot set assessment mappings'
);

-- Test 34: Paired child cannot set mappings
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[]'::jsonb
     ) $$,
  '42501',
  NULL,
  'Paired child cannot set assessment mappings'
);

-- Test 35: Cross-family adult cannot set mappings
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[]'::jsonb
     ) $$,
  '42501',
  NULL,
  'Cross-family adult cannot set assessment mappings'
);

-- Test 36: Mapping to node in different subject is rejected (LW004)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[{"learning_node_id": "b0000003-0000-0000-0000-000000000003", "score_source": "assessment_total"}]'::jsonb
     ) $$,
  'LW004',
  NULL,
  'Mapping Math assessment to English node is rejected with LW004'
);

-- Test 37: Duplicate component_key on same assessment node is rejected (LW004)
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "q1", "raw_score": 5, "max_score": 10},
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "q1", "raw_score": 8, "max_score": 10}
        ]'::jsonb
     ) $$,
  'LW004',
  NULL,
  'Duplicate component_key on same assessment node is rejected with LW004'
);

-- Test 38: Duplicate component_key for item_group on same assessment node is rejected (LW004)
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "item_group", "component_key": "grp1", "item_count": 5, "correct_count": 4},
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "item_group", "component_key": "grp1", "item_count": 5, "correct_count": 5}
        ]'::jsonb
     ) $$,
  'LW004',
  NULL,
  'Duplicate component_key for item_group on same assessment node is rejected with LW004'
);

-- Test 39: assessment_total with custom component_key != assessment_total is rejected with LW004
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "assessment_total", "component_key": "custom_key"}
        ]'::jsonb
     ) $$,
  'LW004',
  NULL,
  'assessment_total with custom component_key != assessment_total is rejected with LW004'
);

-- Test 40: Multiple assessment_total mappings rejected (LW004)
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "assessment_total"},
         {"learning_node_id": "b0000003-0000-0000-0000-000000000002", "score_source": "assessment_total"}
        ]'::jsonb
     ) $$,
  'LW004',
  NULL,
  'Multiple assessment_total mappings rejected with LW004'
);

-- Test 41: Mixed score sources on the same node rejected (LW004)
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "c1", "raw_score": 5, "max_score": 10},
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "item_group", "component_key": "c2", "item_count": 5, "correct_count": 4}
        ]'::jsonb
     ) $$,
  'LW004',
  NULL,
  'Mixed score sources on the same node rejected with LW004'
);

-- Test 42: Active adult sets valid assessment mappings successfully
select lives_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "q1", "raw_score": 9, "max_score": 10},
         {"learning_node_id": "b0000003-0000-0000-0000-000000000001", "score_source": "component_score", "component_key": "q2", "raw_score": 9, "max_score": 10}
        ]'::jsonb
     ) $$,
  'Active adult sets valid component mappings for Single Digit Addition'
);

-- Test 43: get_assessment_learning_mappings returns saved mappings
select is(
  (select jsonb_array_length(public.get_assessment_learning_mappings('a5000000-0000-0000-0000-000000000002'::uuid))),
  2,
  'get_assessment_learning_mappings returns exactly 2 mapped components'
);

-- Test 44: get_assessment_learning_mappings returns exact 16 fields
select is(
  (select count(*)::integer from jsonb_object_keys(
    (select public.get_assessment_learning_mappings('a5000000-0000-0000-0000-000000000002'::uuid)->0)
  )),
  16,
  'get_assessment_learning_mappings returns exact 16 fields per mapping'
);

-- Test 45: assessment_learning_mappings stores authoritative child_id, family_id, confirmed_by_user_id
select is(
  (select count(*)::integer from public.assessment_learning_mappings
   where assessment_id = 'a5000000-0000-0000-0000-000000000002'::uuid
     and family_id = 'f5000000-0000-0000-0000-000000000001'::uuid
     and child_id = 'c5000000-0000-0000-0000-000000000001'::uuid
     and confirmed_by_user_id = '50000000-0000-0000-0000-000000000001'::uuid),
  2,
  'assessment_learning_mappings contains authoritative family_id, child_id, and confirmed_by_user_id'
);

-- Test 46: Direct client INSERT on assessment_learning_mappings is denied
select throws_ok(
  $$ insert into public.assessment_learning_mappings (
       family_id, child_id, assessment_id, learning_node_id, score_source, component_key, confirmed_by_user_id
     ) values (
       'f5000000-0000-0000-0000-000000000001'::uuid,
       'c5000000-0000-0000-0000-000000000001'::uuid,
       'a5000000-0000-0000-0000-000000000002'::uuid,
       'b0000003-0000-0000-0000-000000000001'::uuid,
       'assessment_total', 'assessment_total',
       '50000000-0000-0000-0000-000000000001'::uuid
     ) $$,
  '42501',
  NULL,
  'Direct client INSERT on assessment_learning_mappings is denied'
);

-- Test 47: Cannot map verified assessment
reset role;
insert into public.command_receipts (command_id, operation, actor_user_id, resource_id, family_id)
values (
  '70000000-0000-0000-0000-000000000002'::uuid, 'verify',
  '50000000-0000-0000-0000-000000000001'::uuid,
  'a5000000-0000-0000-0000-000000000002'::uuid,
  'f5000000-0000-0000-0000-000000000001'::uuid
) on conflict do nothing;

insert into public.assessment_review_events (
  id, command_id, family_id, assessment_id, event_type, from_status, to_status, actor_user_id
) values (
  'e5000000-0000-0000-0000-000000000002'::uuid,
  '70000000-0000-0000-0000-000000000002'::uuid,
  'f5000000-0000-0000-0000-000000000001'::uuid,
  'a5000000-0000-0000-0000-000000000002'::uuid,
  'verified',
  'pending_review',
  'verified',
  '50000000-0000-0000-0000-000000000001'::uuid
);

insert into public.verified_learning_events (
  id, assessment_id, family_id, child_id, subject_key, subject, title, assessment_type, difficulty,
  raw_score, max_score, normalized_score, occurred_at, verified_at, verified_by_user_id,
  review_event_id, grade_level_snapshot
) values (
  '15000000-0000-0000-0000-000000000002'::uuid,
  'a5000000-0000-0000-0000-000000000002'::uuid,
  'f5000000-0000-0000-0000-000000000001'::uuid,
  'c5000000-0000-0000-0000-000000000001'::uuid,
  'math', 'Mathematics', 'Math Quiz 2', 'quiz', 'normal',
  90, 100, 9.00, now(), now(), '50000000-0000-0000-0000-000000000001'::uuid,
  'e5000000-0000-0000-0000-000000000002'::uuid, 4
);
update public.assessments set status = 'verified' where id = 'a5000000-0000-0000-0000-000000000002'::uuid;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.set_assessment_learning_mappings(
       'a5000000-0000-0000-0000-000000000002'::uuid,
       '[]'::jsonb
     ) $$,
  'LW103',
  NULL,
  'set_assessment_learning_mappings rejects verified assessment'
);

-- ===========================================================================
-- SECTION 7: LEARNING EVENT PROCESSING & EWMA ENGINE (Tests 48-61)
-- ===========================================================================

-- Test 48: Anonymous caller cannot execute process_learning_event
set local role anon;
select throws_ok(
  $$ select public.process_learning_event(gen_random_uuid(), '15000000-0000-0000-0000-000000000002'::uuid) $$,
  '42501',
  NULL,
  'Anonymous caller cannot execute process_learning_event'
);

-- Test 49: Paired child cannot execute process_learning_event
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.process_learning_event(gen_random_uuid(), '15000000-0000-0000-0000-000000000002'::uuid) $$,
  '42501',
  NULL,
  'Paired child cannot execute process_learning_event'
);

-- Test 50: Cross-family adult cannot execute process_learning_event
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.process_learning_event(gen_random_uuid(), '15000000-0000-0000-0000-000000000002'::uuid) $$,
  '42501',
  NULL,
  'Cross-family adult cannot execute process_learning_event'
);

-- Test 51: Active adult executes process_learning_event for VLE 2
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select lives_ok(
  $$ select public.process_learning_event(
       '00000000-0000-0000-0000-000000000001'::uuid,
       '15000000-0000-0000-0000-000000000002'::uuid
     ) $$,
  'Active adult executes process_learning_event for VLE 2'
);

-- Test 52: Evidence aggregated properly: 2 components (9/10 + 9/10 = 18/20 = 90%)
select is(
  (select performance_pct from public.learning_evidence_events
   where verified_learning_event_id = '15000000-0000-0000-0000-000000000002'::uuid
     and learning_node_id = 'b0000003-0000-0000-0000-000000000001'::uuid),
  90.00,
  'Component scores aggregated accurately by score mass: 18/20 = 90.00%'
);

-- Test 53: Subject fallback atom created for Math Subject root
select is(
  (select count(*)::integer from public.learning_evidence_events
   where verified_learning_event_id = '15000000-0000-0000-0000-000000000002'::uuid
     and learning_node_id = (select id from public.learning_nodes where catalog_version = 'pilot-v0.1' and canonical_key = 'pilot-v0.1:subject:math')),
  1,
  'Automatic subject fallback created exactly one Subject root evidence atom'
);

-- Test 54: Initial observation initializes mastery to observation score (Option A: M_1 = P_1)
select is(
  (select mastery_score from public.child_mastery_states
   where child_id = 'c5000000-0000-0000-0000-000000000001'::uuid
     and learning_node_id = 'b0000003-0000-0000-0000-000000000001'::uuid),
  90.00,
  'First observation initialized mastery to P_1 = 90.00 (Option A)'
);

-- Test 55: Learning processing event snapshot recorded
select is(
  (select count(*)::integer from public.learning_processing_events
   where verified_learning_event_id = '15000000-0000-0000-0000-000000000002'::uuid),
  1,
  'Learning processing event snapshot recorded'
);

-- Test 56: Same-command replay returns identical snapshot without creating duplicate evidence
select is(
  (select public.process_learning_event(
     '00000000-0000-0000-0000-000000000001'::uuid,
     '15000000-0000-0000-0000-000000000002'::uuid
   ) ->> 'status'),
  'processed',
  'Same-command replay returns clean processed status'
);

-- Test 57: First process execution timestamp and processing_id exactly match replay snapshot
select is(
  (select public.process_learning_event(
     '00000000-0000-0000-0000-000000000001'::uuid,
     '15000000-0000-0000-0000-000000000002'::uuid
   ) ->> 'processing_id'),
  (select id::text from public.learning_processing_events where verified_learning_event_id = '15000000-0000-0000-0000-000000000002'::uuid),
  'Replay snapshot processing_id matches persisted learning_processing_events id exactly'
);

-- Test 58: Evidence count is still exactly 2 (mapped skill + subject fallback)
select is(
  (select count(*)::integer from public.learning_evidence_events
   where verified_learning_event_id = '15000000-0000-0000-0000-000000000002'::uuid),
  2,
  'No duplicate evidence created on replay'
);

-- Test 59: New command ID on already-processed VLE binds command and returns result
select is(
  (select public.process_learning_event(
     '00000000-0000-0000-0000-000000000002'::uuid,
     '15000000-0000-0000-0000-000000000002'::uuid
   ) ->> 'status'),
  'processed',
  'New command ID on processed VLE binds receipt and returns processed result'
);

-- Test 60: Reused command ID with different VLE fails with 42501
select throws_ok(
  $$ select public.process_learning_event(
       '00000000-0000-0000-0000-000000000001'::uuid,
       '15000000-0000-0000-0000-000000000001'::uuid
     ) $$,
  '42501',
  NULL,
  'Reused command ID with different VLE fails with 42501'
);

-- Setup adult user 5 in family A to test mismatched actor replay
reset role;
insert into auth.users (id, aud, role, email) values
  ('50000000-0000-0000-0000-000000000005'::uuid, 'authenticated', 'authenticated', 'p51_adult_a2@test.com')
on conflict (id) do nothing;
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('f5000000-0000-0000-0000-000000000001'::uuid, '50000000-0000-0000-0000-000000000005'::uuid, 'adult', 'active')
on conflict (family_id, auth_user_id) do nothing;

-- Test 61: Reused command ID with different actor fails 42501
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000005", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.process_learning_event(
       '00000000-0000-0000-0000-000000000001'::uuid,
       '15000000-0000-0000-0000-000000000002'::uuid
     ) $$,
  '42501',
  NULL,
  'Reused command ID with different actor fails with 42501'
);

-- ===========================================================================
-- SECTION 8: BULK CATCH-UP RPC & IDEMPOTENCY (Tests 62-66)
-- ===========================================================================

-- Test 62: Anonymous caller cannot execute catch_up_unprocessed_learning
set local role anon;
select throws_ok(
  $$ select public.catch_up_unprocessed_learning('f5000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Anonymous caller cannot execute catch_up_unprocessed_learning'
);

-- Test 63: Paired child cannot execute catch_up_unprocessed_learning
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.catch_up_unprocessed_learning('f5000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Paired child cannot execute catch_up_unprocessed_learning'
);

-- Test 64: Cross-family adult cannot execute catch_up_unprocessed_learning
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.catch_up_unprocessed_learning('f5000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Cross-family adult cannot execute catch_up_unprocessed_learning'
);

-- Test 65: Active adult executes catch_up_unprocessed_learning (catches up VLE 1)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select is(
  (select (public.catch_up_unprocessed_learning('f5000000-0000-0000-0000-000000000001'::uuid) ->> 'processed_count')::integer),
  1,
  'catch_up_unprocessed_learning caught up 1 pending VLE (VLE 1)'
);

-- Test 66: Running catch_up again is a safe no-op (processed_count = 0)
select is(
  (select (public.catch_up_unprocessed_learning('f5000000-0000-0000-0000-000000000001'::uuid) ->> 'processed_count')::integer),
  0,
  'Running catch_up_unprocessed_learning again returns processed_count = 0'
);

-- ===========================================================================
-- SECTION 9: READ MODEL: GET_CHILD_MASTERY & CONFIDENCE (Tests 67-76)
-- ===========================================================================

-- Test 67: Cross-family adult cannot read child mastery
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.get_child_mastery('c5000000-0000-0000-0000-000000000001'::uuid) $$,
  '42501',
  NULL,
  'Cross-family adult cannot read child mastery'
);

-- Test 68: Paired child A1 cannot read sibling child A2 mastery
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select throws_ok(
  $$ select public.get_child_mastery('c5000000-0000-0000-0000-000000000002'::uuid) $$,
  '42501',
  NULL,
  'Paired child A1 cannot read sibling child A2 mastery'
);

-- Test 69: Paired child A1 can read own mastery
select lives_ok(
  $$ select public.get_child_mastery('c5000000-0000-0000-0000-000000000001'::uuid) $$,
  'Paired child A1 can read own mastery'
);

-- Test 70: Active adult reads child A1 mastery
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select is(
  (select count(*)::integer from jsonb_array_elements(public.get_child_mastery('c5000000-0000-0000-0000-000000000001'::uuid))),
  2,
  'get_child_mastery returns 2 nodes (Single Digit Addition + Math Subject root)'
);

-- Test 71: Confidence evaluation: 1 Skill observation (weight 1.0) = 1.0 units => Low confidence (< 1.5)
select is(
  (select elem ->> 'confidence_band'
   from jsonb_array_elements(public.get_child_mastery('c5000000-0000-0000-0000-000000000001'::uuid)) elem
   where elem ->> 'node_canonical_key' = 'pilot-v0.1:math:arithmetic:addition:single_digit'),
  'low',
  'Skill node with 1.0 confidence units has Low confidence band'
);

-- Test 72: Mastery band evaluation: score >= 85 but Low confidence => mastery_candidate (not Mastered)
select is(
  (select elem ->> 'mastery_band'
   from jsonb_array_elements(public.get_child_mastery('c5000000-0000-0000-0000-000000000001'::uuid)) elem
   where elem ->> 'node_canonical_key' = 'pilot-v0.1:math:arithmetic:addition:single_digit'),
  'mastery_candidate',
  'Score 90 with Low confidence is mastery_candidate, not Mastered'
);

-- Test 73: Subject root mastery evaluated from 2 observations (VLE 1 + VLE 2)
select is(
  (select (elem ->> 'distinct_assessment_count')::integer
   from jsonb_array_elements(public.get_child_mastery('c5000000-0000-0000-0000-000000000001'::uuid)) elem
   where elem ->> 'node_canonical_key' = 'pilot-v0.1:subject:math'),
  2,
  'Math Subject root distinct_assessment_count = 2'
);

-- Test 74: Client calling get_child_mastery(uuid, timestamptz) fails with 42883 (overload removed)
select throws_ok(
  $$ select public.get_child_mastery('c5000000-0000-0000-0000-000000000001'::uuid, now()) $$,
  '42883',
  NULL,
  'Client cannot pass as_of to public.get_child_mastery (overload removed)'
);

-- Test 75: Every element of public.get_child_mastery(uuid) includes as_of
select is(
  (select count(*)::integer
   from jsonb_array_elements(public.get_child_mastery('c5000000-0000-0000-0000-000000000001'::uuid)) elem
   where elem ? 'as_of'),
  2,
  'Every mastery projection element includes as_of timestamp'
);

-- Test 76: private.get_child_mastery_at(uuid, timestamptz) accepts explicit as_of
reset role;
select lives_ok(
  $$ select private.get_child_mastery_at('c5000000-0000-0000-0000-000000000001'::uuid, now() - interval '90 days') $$,
  'private.get_child_mastery_at accepts explicit as_of timestamp'
);

-- ===========================================================================
-- SECTION 10: AUDIT IMMUTABILITY & SECURITY (Tests 77-89)
-- ===========================================================================

-- Reset to authenticated user context
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 77: Direct client writes on learning_nodes denied
select throws_ok(
  $$ insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title)
     values ('pilot-v0.1', 'skill', 'math', 'pilot-v0.1:math:hack', 'Hack') $$,
  '42501',
  NULL,
  'Direct client write to learning_nodes is denied'
);

-- Test 78: Direct client writes on learning_prerequisites denied
select throws_ok(
  $$ insert into public.learning_prerequisites (catalog_version, subject_key, prerequisite_node_id, dependent_node_id)
     values ('pilot-v0.1', 'math', 'b0000003-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000002'::uuid) $$,
  '42501',
  NULL,
  'Direct client write to learning_prerequisites is denied'
);

-- Test 79: Direct client writes on learning_evidence_events denied
select throws_ok(
  $$ insert into public.learning_evidence_events (
       family_id, child_id, verified_learning_event_id, learning_node_id,
       node_type, subject_key, score_source, performance_pct, specificity_weight,
       level_weight, effective_occurred_at, verified_at, grade_level_snapshot
     ) values (
       'f5000000-0000-0000-0000-000000000001'::uuid,
       'c5000000-0000-0000-0000-000000000001'::uuid,
       '15000000-0000-0000-0000-000000000001'::uuid,
       'b0000003-0000-0000-0000-000000000001'::uuid,
       'skill', 'math', 'assessment_total', 100, 1.0, 1.0, now(), now(), 4
     ) $$,
  '42501',
  NULL,
  'Direct client write to learning_evidence_events is denied'
);

-- Test 80: Direct client writes on mastery_state_revisions denied
select throws_ok(
  $$ insert into public.mastery_state_revisions (
       family_id, child_id, learning_node_id, trigger_verified_learning_event_id,
       engine_version, new_mastery_score, effective_evidence_count, latest_evidence_at, calculation_snapshot
     ) values (
       'f5000000-0000-0000-0000-000000000001'::uuid,
       'c5000000-0000-0000-0000-000000000001'::uuid,
       'b0000003-0000-0000-0000-000000000001'::uuid,
       '15000000-0000-0000-0000-000000000001'::uuid,
       'mastery-v0.1', 99, 1, now(), '{}'::jsonb
     ) $$,
  '42501',
  NULL,
  'Direct client write to mastery_state_revisions is denied'
);

-- Test 81: Direct client writes on child_mastery_states denied
select throws_ok(
  $$ update public.child_mastery_states set mastery_score = 100
     where child_id = 'c5000000-0000-0000-0000-000000000001'::uuid $$,
  '42501',
  NULL,
  'Direct client update to child_mastery_states is denied'
);

-- Test 82: Direct client writes on learning_processing_events denied
select throws_ok(
  $$ insert into public.learning_processing_events (
       verified_learning_event_id, assessment_id, family_id, child_id, evidence_count, affected_node_ids, status
     ) values (
       '15000000-0000-0000-0000-000000000001'::uuid,
       'a5000000-0000-0000-0000-000000000001'::uuid,
       'f5000000-0000-0000-0000-000000000001'::uuid,
       'c5000000-0000-0000-0000-000000000001'::uuid,
       1,
       array['b0000003-0000-0000-0000-000000000001'::uuid],
       'processed'
     ) $$,
  '42501',
  NULL,
  'Direct client write to learning_processing_events is denied'
);

-- Test 83: learning_evidence_events is strictly append-only (UPDATE denied with LW102)
reset role;
select throws_ok(
  $$ update public.learning_evidence_events set performance_pct = 99 $$,
  'LW102',
  NULL,
  'learning_evidence_events is append-only: UPDATE rejected with LW102'
);

-- Test 84: mastery_state_revisions is strictly append-only (DELETE denied with LW102)
select throws_ok(
  $$ delete from public.mastery_state_revisions $$,
  'LW102',
  NULL,
  'mastery_state_revisions is append-only: DELETE rejected with LW102'
);

-- Test 85: learning_processing_events is strictly append-only (UPDATE denied with LW102)
select throws_ok(
  $$ update public.learning_processing_events set status = 'failed' $$,
  'LW102',
  NULL,
  'learning_processing_events is append-only: UPDATE rejected with LW102'
);

-- Test 86: Reward / economy independence (mutating balances produces zero change in child_mastery_states)
insert into public.child_balances (family_id, child_id, xp_total, rp_balance_minor)
values ('f5000000-0000-0000-0000-000000000001'::uuid, 'c5000000-0000-0000-0000-000000000001'::uuid, 9999, 999999)
on conflict (child_id) do update set xp_total = 9999, rp_balance_minor = 999999;

select is(
  (select mastery_score from public.child_mastery_states
   where child_id = 'c5000000-0000-0000-0000-000000000001'::uuid
     and learning_node_id = 'b0000003-0000-0000-0000-000000000001'::uuid),
  90.00,
  'Mastery score is completely invariant to child XP and RP economy mutations'
);

-- Test 87: Anonymous role cannot read learning_catalog_versions
set local role anon;
select is(
  (select count(*)::integer from public.learning_catalog_versions),
  0,
  'Anonymous role cannot read any learning catalog versions'
);

-- Test 88: Authenticated role cannot see draft catalog versions
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "50000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select is(
  (select count(*)::integer from public.learning_catalog_versions where status = 'draft'),
  0,
  'Authenticated role cannot see draft catalog versions'
);

-- Test 89: Authenticated role cannot see draft learning nodes
select is(
  (select count(*)::integer from public.learning_nodes where catalog_version = 'pilot-v0.2-bad'),
  0,
  'Authenticated role cannot see learning nodes from draft catalogs'
);

reset role;
select * from finish();
rollback;
