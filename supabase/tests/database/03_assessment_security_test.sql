begin;
select plan(42);

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
-- 1. DRAFT CREATION, IDEMPOTENCY & NORMALIZED SCORES
-- ---------------------------------------------------------------------------

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 1: Create draft assessment via RPC with command_id
create temporary table test_draft_1 on commit drop as
select * from public.create_assessment_draft(
  '60000000-0000-0000-0000-000000000001'::uuid,
  'f2000000-0000-0000-0000-000000000001'::uuid,
  'c2000000-0000-0000-0000-000000000001'::uuid,
  'math',
  'Mathematics',
  'Fraction Quiz 1',
  'quiz',
  'normal',
  8.5,
  10.0,
  now(),
  'adult'
);

select is(
  (select count(*)::int from test_draft_1),
  1,
  'create_assessment_draft succeeds for active adult'
);

-- Test 2: Normalized score calculation
select is(
  (select normalized_score from test_draft_1),
  8.50::numeric(4, 2),
  'normalized_score is generated server-side correctly (8.5 / 10 * 10 = 8.50)'
);

-- Test 3: Status is draft
select is(
  (select status from test_draft_1),
  'draft',
  'initial assessment status is draft'
);

-- Test 4: Idempotent create retry returns same assessment
create temporary table test_draft_1_retry on commit drop as
select * from public.create_assessment_draft(
  '60000000-0000-0000-0000-000000000001'::uuid,
  'f2000000-0000-0000-0000-000000000001'::uuid,
  'c2000000-0000-0000-0000-000000000001'::uuid,
  'math',
  'Mathematics',
  'Fraction Quiz 1',
  'quiz',
  'normal',
  8.5,
  10.0,
  now(),
  'adult'
);

select is(
  (select id from test_draft_1_retry),
  (select id from test_draft_1),
  'create_assessment_draft retry with same command_id returns exact same assessment'
);

-- Test 5: Cross-user create replay denied (Owner B using command X)
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

select throws_ok(
  $$
    select public.create_assessment_draft(
      '60000000-0000-0000-0000-000000000001'::uuid,
      'f2000000-0000-0000-0000-000000000002'::uuid,
      'c2000000-0000-0000-0000-000000000002'::uuid,
      'math', 'Mathematics', 'Hacked', 'quiz', 'normal', 10, 10
    )
  $$,
  '42501',
  NULL,
  'Different user replaying create_draft command_id is denied (42501)'
);

-- Switch back to Owner A
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

-- Test 6: Cross-family draft creation denial
select throws_ok(
  $$
    select public.create_assessment_draft(
      '60000000-0000-0000-0000-000000000099'::uuid,
      'f2000000-0000-0000-0000-000000000002'::uuid,
      'c2000000-0000-0000-0000-000000000002'::uuid,
      'english',
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
-- 2. SCORE NORMALIZATION MATRIX (Tests 7-14)
-- ---------------------------------------------------------------------------

-- 15 / 20 -> 7.50
select is(
  (select normalized_score from public.create_assessment_draft(
    '60000000-0000-0000-0000-000000000010'::uuid,
    'f2000000-0000-0000-0000-000000000001'::uuid,
    'c2000000-0000-0000-0000-000000000001'::uuid,
    'math', 'Math', 'Test 15/20', 'quiz', 'normal', 15.0, 20.0
  )),
  7.50::numeric(4, 2),
  'Score normalization matrix: 15 / 20 -> 7.50'
);

-- 36 / 50 -> 7.20
select is(
  (select normalized_score from public.create_assessment_draft(
    '60000000-0000-0000-0000-000000000011'::uuid,
    'f2000000-0000-0000-0000-000000000001'::uuid,
    'c2000000-0000-0000-0000-000000000001'::uuid,
    'math', 'Math', 'Test 36/50', 'quiz', 'normal', 36.0, 50.0
  )),
  7.20::numeric(4, 2),
  'Score normalization matrix: 36 / 50 -> 7.20'
);

-- 72 / 100 -> 7.20
select is(
  (select normalized_score from public.create_assessment_draft(
    '60000000-0000-0000-0000-000000000012'::uuid,
    'f2000000-0000-0000-0000-000000000001'::uuid,
    'c2000000-0000-0000-0000-000000000001'::uuid,
    'math', 'Math', 'Test 72/100', 'quiz', 'normal', 72.0, 100.0
  )),
  7.20::numeric(4, 2),
  'Score normalization matrix: 72 / 100 -> 7.20'
);

-- 0 / 10 -> 0.00
select is(
  (select normalized_score from public.create_assessment_draft(
    '60000000-0000-0000-0000-000000000013'::uuid,
    'f2000000-0000-0000-0000-000000000001'::uuid,
    'c2000000-0000-0000-0000-000000000001'::uuid,
    'math', 'Math', 'Test 0/10', 'quiz', 'normal', 0.0, 10.0
  )),
  0.00::numeric(4, 2),
  'Score normalization matrix: 0 / 10 -> 0.00'
);

-- 10 / 10 -> 10.00
select is(
  (select normalized_score from public.create_assessment_draft(
    '60000000-0000-0000-0000-000000000014'::uuid,
    'f2000000-0000-0000-0000-000000000001'::uuid,
    'c2000000-0000-0000-0000-000000000001'::uuid,
    'math', 'Math', 'Test 10/10', 'quiz', 'normal', 10.0, 10.0
  )),
  10.00::numeric(4, 2),
  'Score normalization matrix: 10 / 10 -> 10.00'
);

-- Reject: -1 / 10
select throws_ok(
  $$
    select public.create_assessment_draft(
      '60000000-0000-0000-0000-000000000015'::uuid,
      'f2000000-0000-0000-0000-000000000001'::uuid,
      'c2000000-0000-0000-0000-000000000001'::uuid,
      'math', 'Math', 'Invalid -1', 'quiz', 'normal', -1.0, 10.0
    )
  $$,
  '23514',
  NULL,
  'Score rejection: negative raw score throws check constraint 23514'
);

-- Reject: 11 / 10
select throws_ok(
  $$
    select public.create_assessment_draft(
      '60000000-0000-0000-0000-000000000016'::uuid,
      'f2000000-0000-0000-0000-000000000001'::uuid,
      'c2000000-0000-0000-0000-000000000001'::uuid,
      'math', 'Math', 'Invalid 11/10', 'quiz', 'normal', 11.0, 10.0
    )
  $$,
  '23514',
  NULL,
  'Score rejection: raw_score > max_score throws check constraint 23514'
);

-- Reject: 5 / 0
select throws_ok(
  $$
    select public.create_assessment_draft(
      '60000000-0000-0000-0000-000000000017'::uuid,
      'f2000000-0000-0000-0000-000000000001'::uuid,
      'c2000000-0000-0000-0000-000000000001'::uuid,
      'math', 'Math', 'Invalid 5/0', 'quiz', 'normal', 5.0, 0.0
    )
  $$,
  '23514',
  NULL,
  'Score rejection: max_score <= 0 throws check constraint 23514'
);

-- ---------------------------------------------------------------------------
-- 3. DIRECT CLIENT TABLE MUTATION RESTRICTIONS (Tests 15-17)
-- ---------------------------------------------------------------------------

select throws_ok(
  $$
    insert into public.assessments (
      family_id, child_id, subject_key, subject, title, assessment_type, difficulty, raw_score, max_score, created_by_user_id
    ) values (
      'f2000000-0000-0000-0000-000000000001'::uuid,
      'c2000000-0000-0000-0000-000000000001'::uuid,
      'math', 'Math', 'Forged', 'quiz', 'normal', 10, 10,
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
-- 4. EVIDENCE ATTACHMENT & HIERARCHY VALIDATION (Tests 18-19)
-- ---------------------------------------------------------------------------

create temporary table test_evidence_1 on commit drop as
select * from public.register_assessment_evidence(
  (select id from test_draft_1),
  (select 'f2000000-0000-0000-0000-000000000001/c2000000-0000-0000-0000-000000000001/' || id::text || '/550e8400-e29b-41d4-a716-446655440000.jpg' from test_draft_1),
  'image/jpeg',
  102400
);

select is(
  (select count(*)::int from test_evidence_1),
  1,
  'register_assessment_evidence succeeds with proper hierarchy path and evidence UUID'
);

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
-- 5. CROSS-FAMILY READ ISOLATION (Tests 20-22)
-- ---------------------------------------------------------------------------

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
-- 6. SUBMISSION & VERSION ADVANCEMENT (Tests 23-26)
-- ---------------------------------------------------------------------------

select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select throws_ok(
  $$
    select public.submit_assessment(
      (select id from test_draft_1),
      99,
      '80000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  'LW101',
  NULL,
  'submit_assessment with wrong version throws LW101'
);

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

select throws_ok(
  $$
    select public.update_assessment_draft(
      (select id from test_draft_1),
      'math', 'Math', 'Modified Title', 'quiz', 'normal', 9, 10, now(), 2
    )
  $$,
  'LW107',
  NULL,
  'update_assessment_draft rejects non-draft status (LW107)'
);

-- ---------------------------------------------------------------------------
-- 7. EVIDENCE IMMUTABILITY AFTER DRAFT (Tests 27-28)
-- ---------------------------------------------------------------------------

-- Evidence removal fails after draft status
select throws_ok(
  $$
    select public.remove_draft_assessment_evidence(
      (select id from test_evidence_1)
    )
  $$,
  'LW109',
  NULL,
  'remove_draft_assessment_evidence rejected when assessment is pending_review (LW109)'
);

-- Evidence registration fails after draft status
select throws_ok(
  $$
    select public.register_assessment_evidence(
      (select id from test_draft_1),
      (select 'f2000000-0000-0000-0000-000000000001/c2000000-0000-0000-0000-000000000001/' || id::text || '/550e8400-e29b-41d4-a716-446655440002.jpg' from test_draft_1),
      'image/jpeg',
      102400
    )
  $$,
  'LW109',
  NULL,
  'register_assessment_evidence rejected when assessment is pending_review (LW109)'
);

-- ---------------------------------------------------------------------------
-- 8. VERIFICATION, AUDIT & SNAPSHOT (Tests 29-34)
-- ---------------------------------------------------------------------------

select throws_ok(
  $$
    select public.verify_assessment(
      (select id from test_draft_1),
      1,
      '70000000-0000-0000-0000-000000000001'::uuid,
      'Approved'
    )
  $$,
  'LW101',
  NULL,
  'verify_assessment rejects stale expected_version (LW101)'
);

-- Verify notes length check > 1000 chars fails
select throws_ok(
  $$
    select public.verify_assessment(
      (select id from test_draft_1),
      2,
      '70000000-0000-0000-0000-000000000001'::uuid,
      repeat('a', 1001)
    )
  $$,
  'LW104',
  NULL,
  'verify_assessment rejects notes exceeding 1000 characters (LW104)'
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

-- Snapshot captures stable subject_key and evidence_count
select is(
  (select subject_key from public.verified_learning_events where assessment_id = (select id from test_draft_1)),
  'math',
  'verified_learning_events captures stable subject_key'
);

-- ---------------------------------------------------------------------------
-- 9. IDEMPOTENCY REPLAY ATTACKS & AUTHORIZATION (Tests 35-37)
-- ---------------------------------------------------------------------------

-- Idempotent retry by Owner A returns same assessment
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

-- Owner B attempts to replay Owner A's verify command -> 42501
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

select throws_ok(
  $$
    select public.verify_assessment(
      (select id from test_draft_1),
      2,
      '70000000-0000-0000-0000-000000000001'::uuid
    )
  $$,
  '42501',
  NULL,
  'Owner B cannot replay Owner A processed command_id (42501)'
);

-- Reusing command_id for different operation (e.g. reject) is rejected
select set_config('request.jwt.claims', '{"sub": "20000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select throws_ok(
  $$
    select public.reject_assessment(
      (select id from test_draft_1),
      2,
      '70000000-0000-0000-0000-000000000001'::uuid,
      'Invalid reuse of verify command'
    )
  $$,
  '42501',
  NULL,
  'Reusing verify command_id for reject operation is rejected (42501)'
);

-- ---------------------------------------------------------------------------
-- 10. REJECTION FLOW & SERVER-ENFORCED REASON (Tests 38-42)
-- ---------------------------------------------------------------------------

create temporary table test_draft_reject on commit drop as
select * from public.create_assessment_draft(
  '60000000-0000-0000-0000-000000000020'::uuid,
  'f2000000-0000-0000-0000-000000000001'::uuid,
  'c2000000-0000-0000-0000-000000000001'::uuid,
  'science',
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
  '80000000-0000-0000-0000-000000000020'::uuid
);

-- Rejection with null reason fails
select throws_ok(
  $$
    select public.reject_assessment(
      (select id from test_draft_reject),
      2,
      '70000000-0000-0000-0000-000000000020'::uuid,
      null
    )
  $$,
  'LW104',
  NULL,
  'reject_assessment with null reason is rejected (LW104)'
);

-- Rejection with empty / whitespace reason fails
select throws_ok(
  $$
    select public.reject_assessment(
      (select id from test_draft_reject),
      2,
      '70000000-0000-0000-0000-000000000020'::uuid,
      '   '
    )
  $$,
  'LW104',
  NULL,
  'reject_assessment with empty/whitespace reason is rejected (LW104)'
);

-- Rejection with > 500 characters fails
select throws_ok(
  $$
    select public.reject_assessment(
      (select id from test_draft_reject),
      2,
      '70000000-0000-0000-0000-000000000020'::uuid,
      repeat('x', 501)
    )
  $$,
  'LW104',
  NULL,
  'reject_assessment with reason > 500 characters is rejected (LW104)'
);

-- Valid rejection
create temporary table test_rejected_1 on commit drop as
select * from public.reject_assessment(
  (select id from test_draft_reject),
  2,
  '70000000-0000-0000-0000-000000000020'::uuid,
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
