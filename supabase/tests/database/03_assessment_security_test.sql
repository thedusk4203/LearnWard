begin;
select plan(26);

-- ---------------------------------------------------------------------------
-- 0. FIXTURES SETUP (superuser context)
-- ---------------------------------------------------------------------------

insert into auth.users (id, aud, role, email) values
  ('20000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'p2_owner_a@test.com'),
  ('20000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'p2_owner_b@test.com'),
  ('20000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'p2_child_device_a@test.com')
on conflict (id) do nothing;

insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('f2000000-0000-0000-0000-000000000001'::uuid, 'Phase 2 Family A', 'UTC', 'en_US', '20000000-0000-0000-0000-000000000001'::uuid),
  ('f2000000-0000-0000-0000-000000000002'::uuid, 'Phase 2 Family B', 'UTC', 'en_US', '20000000-0000-0000-0000-000000000002'::uuid)
on conflict (id) do nothing;

insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('f2000000-0000-0000-0000-000000000001'::uuid, '20000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('f2000000-0000-0000-0000-000000000002'::uuid, '20000000-0000-0000-0000-000000000002'::uuid, 'owner', 'active')
on conflict (family_id, auth_user_id) do nothing;

insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
  ('c2000000-0000-0000-0000-000000000001'::uuid, 'f2000000-0000-0000-0000-000000000001'::uuid, 'Phase 2 Child A', 5, 2015),
  ('c2000000-0000-0000-0000-000000000002'::uuid, 'f2000000-0000-0000-0000-000000000002'::uuid, 'Phase 2 Child B', 6, 2014)
on conflict (id) do nothing;

insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('d2000000-0000-0000-0000-000000000001'::uuid, 'f2000000-0000-0000-0000-000000000001'::uuid, 'c2000000-0000-0000-0000-000000000001'::uuid, '20000000-0000-0000-0000-000000000003'::uuid, 'active', '20000000-0000-0000-0000-000000000001'::uuid)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 1. DRAFT CREATION & NORMALIZED SCORE
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Create draft assessment via RPC
create temporary table test_draft_1 on commit drop as
select * from public.create_assessment_draft(
  'f2000000-0000-0000-0000-000000000001'::uuid,
  'c2000000-0000-0000-0000-000000000001'::uuid,
  'Mathematics',
  'Fraction Quiz 1',
  'quiz',
  'normal',
  8.5,
  10.0,
  now()
);

select is(
  (select count(*)::int from test_draft_1),
  1,
  'create_assessment_draft succeeds for active adult'
);

select is(
  (select normalized_score from test_draft_1),
  8.50::numeric(4, 2),
  'normalized_score is generated server-side correctly (8.5 / 10 * 10 = 8.50)'
);

select is(
  (select status from test_draft_1),
  'draft',
  'initial assessment status is draft'
);

-- Cross-family draft creation denial
select throws_ok(
  $$
    select public.create_assessment_draft(
      'f2000000-0000-0000-0000-000000000002'::uuid,
      'c2000000-0000-0000-0000-000000000002'::uuid,
      'English',
      'Essay',
      'homework',
      'normal',
      9.0,
      10.0
    )
  $$,
  '42501',
  NULL,
  'Adult A cannot create draft in Family B'
);

-- ---------------------------------------------------------------------------
-- 2. DIRECT CLIENT TABLE MUTATION RESTRICTIONS
-- ---------------------------------------------------------------------------

select throws_ok(
  $$
    insert into public.assessments (
      family_id, child_id, subject, title, assessment_type, difficulty, raw_score, max_score, created_by_user_id
    ) values (
      'f2000000-0000-0000-0000-000000000001'::uuid,
      'c2000000-0000-0000-0000-000000000001'::uuid,
      'Math', 'Forged', 'quiz', 'normal', 10, 10,
      '20000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  '42501',
  NULL,
  'Direct client INSERT on assessments is denied (42501)'
);

select throws_ok(
  $$
    update public.assessments
    set raw_score = 10
    where family_id = 'f2000000-0000-0000-0000-000000000001'::uuid
  $$,
  '42501',
  NULL,
  'Direct client UPDATE on assessments is denied (42501)'
);

select throws_ok(
  $$
    delete from public.assessments
    where family_id = 'f2000000-0000-0000-0000-000000000001'::uuid
  $$,
  '42501',
  NULL,
  'Direct client DELETE on assessments is denied (42501)'
);

-- ---------------------------------------------------------------------------
-- 3. EVIDENCE ATTACHMENT
-- ---------------------------------------------------------------------------

-- Valid evidence registration
create temporary table test_evidence_1 on commit drop as
select * from public.register_assessment_evidence(
  (select id from test_draft_1),
  (select 'f2000000-0000-0000-0000-000000000001/c2000000-0000-0000-0000-000000000001/' || id::text || '/page1.jpg' from test_draft_1),
  'image/jpeg',
  102400
);

select is(
  (select count(*)::int from test_evidence_1),
  1,
  'register_assessment_evidence succeeds with proper hierarchy path'
);

-- Invalid evidence hierarchy path
select throws_ok(
  $$
    select public.register_assessment_evidence(
      (select id from test_draft_1),
      'invalid/path/to/evidence.jpg',
      'image/jpeg',
      50000
    )
  $$,
  'LW110',
  NULL,
  'register_assessment_evidence rejects non-matching storage hierarchy (LW110)'
);

-- ---------------------------------------------------------------------------
-- 4. CROSS-FAMILY READ ISOLATION
-- ---------------------------------------------------------------------------

-- Switch to Adult B
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

select is(
  (select count(*)::int from public.assessments where family_id = 'f2000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Adult B cannot view Family A assessments via SELECT'
);

select is(
  (select count(*)::int from public.assessment_evidence where family_id = 'f2000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Adult B cannot view Family A assessment evidence via SELECT'
);

-- Adult B cannot verify Adult A assessment
select throws_ok(
  $$
    select public.verify_assessment(
      (select id from test_draft_1),
      1,
      '90000000-0000-0000-0000-000000000001'::uuid,
      'Cross family attack'
    )
  $$,
  '42501',
  NULL,
  'Adult B cannot verify Family A assessment (42501)'
);

-- ---------------------------------------------------------------------------
-- 5. SUBMISSION & VERSION ADVANCEMENT
-- ---------------------------------------------------------------------------

-- Switch back to Adult A
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Stale version submit fails
select throws_ok(
  $$
    select public.submit_assessment(
      (select id from test_draft_1),
      99, -- wrong version
      '80000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  'LW101',
  NULL,
  'submit_assessment with wrong version throws LW101'
);

-- Submit draft for review
create temporary table test_submitted_1 on commit drop as
select * from public.submit_assessment(
  (select id from test_draft_1),
  1,
  '80000000-0000-0000-0000-000000000001'::uuid
);

select is(
  (select status from test_submitted_1),
  'pending_review',
  'submitted assessment moves to pending_review'
);

select is(
  (select version from test_submitted_1),
  2,
  'submitted assessment version increments to 2'
);

-- Updating a submitted assessment fails
select throws_ok(
  $$
    select public.update_assessment_draft(
      (select id from test_draft_1),
      'Math', 'Modified Title', 'quiz', 'normal', 9, 10, now(), 2
    )
  $$,
  'LW107',
  NULL,
  'update_assessment_draft rejects non-draft status (LW107)'
);

-- ---------------------------------------------------------------------------
-- 6. VERIFICATION, IDEMPOTENCY & IMMUTABLE LEARNING EVENTS
-- ---------------------------------------------------------------------------

-- Stale verification attempt throws LW101
select throws_ok(
  $$
    select public.verify_assessment(
      (select id from test_draft_1),
      1, -- expected 2
      '70000000-0000-0000-0000-000000000001'::uuid,
      'Approved'
    )
  $$,
  'LW101',
  NULL,
  'verify_assessment rejects stale expected_version (LW101)'
);

-- Real verification by Adult A
create temporary table test_verified_1 on commit drop as
select * from public.verify_assessment(
  (select id from test_draft_1),
  2,
  '70000000-0000-0000-0000-000000000001'::uuid,
  'Great performance on fractions!'
);

select is(
  (select status from test_verified_1),
  'verified',
  'verify_assessment moves status to verified'
);

select is(
  (select count(*)::int from public.verified_learning_events where assessment_id = (select id from test_draft_1)),
  1,
  'exactly 1 verified_learning_events row created'
);

select is(
  (select normalized_score from public.verified_learning_events where assessment_id = (select id from test_draft_1)),
  8.50::numeric(4, 2),
  'verified_learning_events captures canonical normalized_score snapshot'
);

-- Idempotent retry with same command_id
create temporary table test_verified_retry on commit drop as
select * from public.verify_assessment(
  (select id from test_draft_1),
  2,
  '70000000-0000-0000-0000-000000000001'::uuid,
  'Duplicate call'
);

select is(
  (select count(*)::int from public.verified_learning_events where assessment_id = (select id from test_draft_1)),
  1,
  'Idempotent verify retry does NOT create duplicate verified_learning_events'
);

-- ---------------------------------------------------------------------------
-- 7. TERMINAL IMMUTABILITY GUARANTEES
-- ---------------------------------------------------------------------------

-- Direct attempt by superuser context to mutate verified learning events fails via trigger
reset role;

select throws_ok(
  $$
    update public.verified_learning_events
    set normalized_score = 10.0
    where assessment_id = (select id from test_draft_1)
  $$,
  'LW102',
  NULL,
  'verified_learning_events cannot be updated even by superuser (LW102)'
);

select throws_ok(
  $$
    delete from public.verified_learning_events
    where assessment_id = (select id from test_draft_1)
  $$,
  'LW102',
  NULL,
  'verified_learning_events cannot be deleted even by superuser (LW102)'
);

select throws_ok(
  $$
    update public.assessments
    set raw_score = 10.0
    where id = (select id from test_draft_1)
  $$,
  'LW103',
  NULL,
  'verified assessments cannot be modified (LW103)'
);

-- ---------------------------------------------------------------------------
-- 8. REJECTION FLOW
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

create temporary table test_draft_reject on commit drop as
select * from public.create_assessment_draft(
  'f2000000-0000-0000-0000-000000000001'::uuid,
  'c2000000-0000-0000-0000-000000000001'::uuid,
  'Science',
  'Lab Report',
  'homework',
  'hard',
  5.0,
  10.0
);

select public.submit_assessment(
  (select id from test_draft_reject),
  1,
  '80000000-0000-0000-0000-000000000002'::uuid
);

create temporary table test_rejected_1 on commit drop as
select * from public.reject_assessment(
  (select id from test_draft_reject),
  2,
  '70000000-0000-0000-0000-000000000002'::uuid,
  'Incomplete calculations on question 3'
);

select is(
  (select status from test_rejected_1),
  'rejected',
  'reject_assessment transitions status to rejected'
);

select is(
  (select count(*)::int from public.verified_learning_events where assessment_id = (select id from test_draft_reject)),
  0,
  'rejected assessments create 0 verified_learning_events'
);

select * from finish();
rollback;
