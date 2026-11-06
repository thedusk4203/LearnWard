-- ===========================================================================
-- LearnWard Migration: Phase 6 Slice 2 - Child Archival Lifecycle,
-- Concurrency Hierarchy & SECURITY DEFINER Active-Child Mutation Barriers
--
-- Formal Specification:
-- - ACCEPTED ADR 0008: Child Lifecycle, Hardened RLS, and Archival Protocol
-- - Phase 6 Detailed Design §4.3.2.2: Archive Barrier for SECURITY DEFINER Mutations and Catch-up
-- - Global Monotonic Concurrency Protocol:
--     Order 1: public.child_profiles (FOR UPDATE on Archival, FOR SHARE on Child Mutations)
--     Order 2: Domain Entity & Catalog Locks (assessments, rewards, redemptions, wheel_settings)
--     Order 3: Economic Balance & Mastery Projections (child_balances, child_mastery_states)
--     Order 4: Transaction-Level Advisory Locks (vle_<id>, child_node_<child_id>_<node_id>)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. CANONICAL CHILD ARCHIVAL RPC (public.archive_child_profile)
-- ---------------------------------------------------------------------------

create or replace function public.archive_child_profile(p_child_id uuid)
returns public.child_profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child public.child_profiles%rowtype;
begin
  -- 1. Authentication check
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_child_id is null then
    raise exception 'Child ID is required' using errcode = '22000';
  end if;

  -- 2. Derive authoritative family_id and verify caller is an active adult in the child's family
  select family_id into v_family_id
  from public.child_profiles
  where id = p_child_id;

  if not found or not private.is_active_family_adult(v_family_id) then
    raise exception 'Unauthorized to archive child profile' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR UPDATE (exclusive serialization)
  select * into v_child
  from public.child_profiles
  where id = p_child_id and family_id = v_family_id
  for update;

  if v_child.status = 'archived' then
    raise exception 'Child profile is already archived' using errcode = '42501';
  end if;

  -- 5. Tier 1: Revoke all active paired device grants for this child
  update public.child_device_grants
  set status = 'revoked',
      revoked_at = clock_timestamp()
  where child_id = p_child_id
    and family_id = v_family_id
    and status = 'active';

  -- 6. Tier 2 & Tier 3: Atomically archive profile and scrub identifying attributes
  -- Evaluated by trg_guard_child_profile_lifecycle (satisfying LW013)
  update public.child_profiles
  set status = 'archived',
      archived_at = clock_timestamp(),
      display_name = '[Archived Learner]',
      avatar_key = null,
      school_grade = null,
      birth_year = null
  where id = p_child_id
  returning * into v_child;

  return v_child;
end;
$$;

revoke all on function public.archive_child_profile(uuid) from public, anon;
grant execute on function public.archive_child_profile(uuid) to authenticated;
grant all on function public.archive_child_profile(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 2. HARDENED ASSESSMENT MUTATION RPCS (Order 1 Child Lock FOR SHARE)
-- ---------------------------------------------------------------------------

create or replace function public.create_assessment_draft(
  p_command_id uuid,
  p_family_id uuid,
  p_child_id uuid,
  p_subject_key text,
  p_subject text,
  p_title text,
  p_assessment_type text,
  p_difficulty text,
  p_raw_score numeric,
  p_max_score numeric,
  p_occurred_at timestamptz default now(),
  p_entry_context text default 'adult'
)
returns public.assessments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_assessment public.assessments;
  v_receipt public.command_receipts;
  v_assessment_id uuid;
begin
  -- 1. Authentication
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 2. Authorization
  if not (
    private.is_active_family_adult(p_family_id)
    or private.is_active_child_device(p_family_id, p_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 3. Order 1: Child Profile Row Lock FOR SHARE & Active Status Validation
  perform 1
  from public.child_profiles
  where id = p_child_id and family_id = p_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile not found or inactive' using errcode = 'LW108';
  end if;

  -- 4. Validate subject key and entry context
  if p_subject_key not in ('math', 'english', 'literature', 'science', 'other') then
    raise exception 'Invalid subject key: %', p_subject_key using errcode = 'LW104';
  end if;

  if p_entry_context not in ('adult', 'shared_child', 'paired_child') then
    raise exception 'Invalid entry context: %', p_entry_context using errcode = 'LW104';
  end if;

  -- 5. Score bounds check (prevents division by zero on generated column)
  if p_max_score <= 0 then
    raise exception 'max_score must be greater than zero' using errcode = '23514';
  end if;

  if p_raw_score < 0 or p_raw_score > p_max_score then
    raise exception 'raw_score must be between 0 and max_score' using errcode = '23514';
  end if;

  -- 6. Idempotency check AFTER authorization
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'create_draft' or v_receipt.actor_user_id != v_user_id or v_receipt.family_id != p_family_id then
      raise exception 'Invalid command replay or permission denied' using errcode = '42501';
    end if;

    select * into v_assessment from public.assessments where id = v_receipt.resource_id;
    return v_assessment;
  end if;

  -- 7. Insert new draft
  v_assessment_id := gen_random_uuid();

  insert into public.assessments (
    id,
    family_id,
    child_id,
    subject_key,
    subject,
    title,
    assessment_type,
    difficulty,
    raw_score,
    max_score,
    entry_context,
    status,
    occurred_at,
    created_by_user_id
  ) values (
    v_assessment_id,
    p_family_id,
    p_child_id,
    p_subject_key,
    trim(p_subject),
    trim(p_title),
    p_assessment_type,
    p_difficulty,
    p_raw_score,
    p_max_score,
    p_entry_context,
    'draft',
    coalesce(p_occurred_at, now()),
    v_user_id
  ) returning * into v_assessment;

  -- 8. Record command receipt
  insert into public.command_receipts (
    command_id,
    operation,
    actor_user_id,
    resource_id,
    family_id
  ) values (
    p_command_id,
    'create_draft',
    v_user_id,
    v_assessment.id,
    p_family_id
  );

  return v_assessment;
end;
$$;

create or replace function public.update_assessment_draft(
  p_assessment_id uuid,
  p_subject_key text,
  p_subject text,
  p_title text,
  p_assessment_type text,
  p_difficulty text,
  p_raw_score numeric,
  p_max_score numeric,
  p_occurred_at timestamptz,
  p_expected_version int
)
returns public.assessments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_assessment public.assessments;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- Resolve assessment identity
  select family_id, child_id into v_family_id, v_child_id
  from public.assessments
  where id = p_assessment_id;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- Authorization check
  if not (
    private.is_active_family_adult(v_family_id)
    or private.is_active_child_device(v_family_id, v_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile not found or archived' using errcode = '42501';
  end if;

  -- Order 2: Domain Entity Lock FOR UPDATE
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if v_assessment.status != 'draft' then
    raise exception 'Only draft assessments can be updated' using errcode = 'LW107';
  end if;

  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  if p_subject_key not in ('math', 'english', 'literature', 'science', 'other') then
    raise exception 'Invalid subject key: %', p_subject_key using errcode = 'LW104';
  end if;

  if p_max_score <= 0 then
    raise exception 'max_score must be greater than zero' using errcode = '23514';
  end if;

  if p_raw_score < 0 or p_raw_score > p_max_score then
    raise exception 'raw_score must be between 0 and max_score' using errcode = '23514';
  end if;

  update public.assessments
  set subject_key = p_subject_key,
      subject = trim(p_subject),
      title = trim(p_title),
      assessment_type = p_assessment_type,
      difficulty = p_difficulty,
      raw_score = p_raw_score,
      max_score = p_max_score,
      occurred_at = coalesce(p_occurred_at, v_assessment.occurred_at),
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  return v_assessment;
end;
$$;

create or replace function public.register_assessment_evidence(
  p_assessment_id uuid,
  p_storage_path text,
  p_media_type text,
  p_file_size_bytes int
)
returns public.assessment_evidence
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_assessment public.assessments;
  v_evidence public.assessment_evidence;
  v_expected_pattern text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  select family_id, child_id into v_family_id, v_child_id
  from public.assessments
  where id = p_assessment_id;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  if not (
    private.is_active_family_adult(v_family_id)
    or private.is_active_child_device(v_family_id, v_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile not found or archived' using errcode = '42501';
  end if;

  -- Order 2: Domain Entity Lock FOR UPDATE
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if v_assessment.status != 'draft' then
    raise exception 'Evidence can only be attached to draft assessments' using errcode = 'LW109';
  end if;

  -- Path convention: <family_id>/<child_id>/<assessment_id>/<evidence_uuid>.(jpg|jpeg|png)
  v_expected_pattern := '^' || v_assessment.family_id::text || '/' || v_assessment.child_id::text || '/' || v_assessment.id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png)$';
  if not (trim(p_storage_path) ~* v_expected_pattern) then
    raise exception 'Storage path must match family/child/assessment hierarchy with evidence UUID' using errcode = 'LW110';
  end if;

  -- Idempotency check: return existing evidence record if already registered for this assessment
  select * into v_evidence
  from public.assessment_evidence
  where storage_path = trim(p_storage_path);

  if found then
    return v_evidence;
  end if;

  insert into public.assessment_evidence (
    family_id,
    assessment_id,
    storage_path,
    media_type,
    file_size_bytes,
    uploaded_by_user_id
  ) values (
    v_assessment.family_id,
    v_assessment.id,
    trim(p_storage_path),
    p_media_type,
    p_file_size_bytes,
    v_user_id
  ) returning * into v_evidence;

  return v_evidence;
end;
$$;

create or replace function public.remove_draft_assessment_evidence(
  p_evidence_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_assessment_id uuid;
  v_assessment public.assessments;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  select a.family_id, a.child_id, a.id into v_family_id, v_child_id, v_assessment_id
  from public.assessment_evidence e
  join public.assessments a on a.id = e.assessment_id
  where e.id = p_evidence_id;

  if not found then
    raise exception 'Evidence not found' using errcode = 'LW111';
  end if;

  if not (
    private.is_active_family_adult(v_family_id)
    or private.is_active_child_device(v_family_id, v_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile not found or archived' using errcode = '42501';
  end if;

  -- Order 2: Domain Entity Lock FOR UPDATE
  select * into v_assessment
  from public.assessments
  where id = v_assessment_id
  for update;

  if v_assessment.status != 'draft' then
    raise exception 'Evidence can only be removed from draft assessments' using errcode = 'LW109';
  end if;

  delete from public.assessment_evidence
  where id = p_evidence_id;
end;
$$;

create or replace function public.submit_assessment(
  p_assessment_id uuid,
  p_expected_version int,
  p_command_id uuid
)
returns public.assessments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_assessment public.assessments;
  v_receipt public.command_receipts;
begin
  -- 1. Authentication
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 2. Resolve assessment tenancy
  select family_id, child_id into v_family_id, v_child_id
  from public.assessments
  where id = p_assessment_id;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check FIRST (before idempotency inspection)
  if not (
    private.is_active_family_adult(v_family_id)
    or private.is_active_child_device(v_family_id, v_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- 5. Order 2: Domain Entity Lock FOR UPDATE
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  -- 6. Idempotency check AFTER authorization
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'submit' or v_receipt.resource_id != p_assessment_id or v_receipt.actor_user_id != v_user_id then
      raise exception 'Invalid command replay or command ID mismatch' using errcode = '42501';
    end if;

    return v_assessment;
  end if;

  -- 7. Version check
  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  -- 8. Status check
  if v_assessment.status != 'draft' then
    raise exception 'Only draft assessments can be submitted' using errcode = 'LW107';
  end if;

  -- 9. Transition status
  update public.assessments
  set status = 'pending_review',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  -- 10. Command receipt
  insert into public.command_receipts (
    command_id,
    operation,
    actor_user_id,
    resource_id,
    family_id
  ) values (
    p_command_id,
    'submit',
    v_user_id,
    p_assessment_id,
    v_assessment.family_id
  );

  -- 11. Review audit log
  insert into public.assessment_review_events (
    command_id,
    family_id,
    assessment_id,
    event_type,
    from_status,
    to_status,
    actor_user_id,
    review_notes
  ) values (
    p_command_id,
    v_assessment.family_id,
    v_assessment.id,
    'submitted',
    'draft',
    'pending_review',
    v_user_id,
    null
  );

  return v_assessment;
end;
$$;

create or replace function public.verify_assessment(
  p_assessment_id uuid,
  p_expected_version int,
  p_command_id uuid,
  p_notes text default null
)
returns public.assessments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_assessment public.assessments;
  v_review_event public.assessment_review_events;
  v_receipt public.command_receipts;
  v_evidence_count int;
  v_vle public.verified_learning_events;
begin
  -- 1. Authentication
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 2. Resolve assessment tenancy
  select family_id, child_id into v_family_id, v_child_id
  from public.assessments
  where id = p_assessment_id;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check FIRST (only active family adults can verify)
  if not private.is_active_family_adult(v_family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- 5. Order 2: Domain Entity Lock FOR UPDATE
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  -- 6. Validate notes length
  if p_notes is not null and length(p_notes) > 1000 then
    raise exception 'Verification notes must not exceed 1000 characters' using errcode = 'LW104';
  end if;

  -- 7. Idempotency check AFTER authorization
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'verify' or v_receipt.resource_id != p_assessment_id or v_receipt.actor_user_id != v_user_id then
      raise exception 'Invalid command replay or command ID mismatch' using errcode = '42501';
    end if;

    return v_assessment;
  end if;

  -- 8. Optimistic concurrency check
  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  -- 9. Status check
  if v_assessment.status != 'pending_review' then
    raise exception 'Assessment is not pending review' using errcode = 'LW106';
  end if;

  -- 10. Transition status
  update public.assessments
  set status = 'verified',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  -- 11. Command receipt
  insert into public.command_receipts (
    command_id,
    operation,
    actor_user_id,
    resource_id,
    family_id
  ) values (
    p_command_id,
    'verify',
    v_user_id,
    p_assessment_id,
    v_assessment.family_id
  );

  -- 12. Audit log
  insert into public.assessment_review_events (
    command_id,
    family_id,
    assessment_id,
    event_type,
    from_status,
    to_status,
    actor_user_id,
    review_notes
  ) values (
    p_command_id,
    v_assessment.family_id,
    v_assessment.id,
    'verified',
    'pending_review',
    'verified',
    v_user_id,
    p_notes
  ) returning * into v_review_event;

  -- 13. Count attached evidence
  select count(*)::int into v_evidence_count
  from public.assessment_evidence
  where assessment_id = v_assessment.id;

  -- 14. Create immutable verified_learning_events row
  insert into public.verified_learning_events (
    family_id,
    child_id,
    assessment_id,
    subject_key,
    subject,
    title,
    assessment_type,
    difficulty,
    raw_score,
    max_score,
    normalized_score,
    evidence_count,
    entry_context,
    occurred_at,
    verified_by_user_id,
    review_event_id
  ) values (
    v_assessment.family_id,
    v_assessment.child_id,
    v_assessment.id,
    v_assessment.subject_key,
    v_assessment.subject,
    v_assessment.title,
    v_assessment.assessment_type,
    v_assessment.difficulty,
    v_assessment.raw_score,
    v_assessment.max_score,
    v_assessment.normalized_score,
    v_evidence_count,
    v_assessment.entry_context,
    v_assessment.occurred_at,
    v_user_id,
    v_review_event.id
  );

  return v_assessment;
end;
$$;

create or replace function public.reject_assessment(
  p_assessment_id uuid,
  p_expected_version int,
  p_command_id uuid,
  p_rejection_reason text
)
returns public.assessments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_assessment public.assessments;
  v_receipt public.command_receipts;
begin
  -- 1. Authentication
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 2. Resolve assessment tenancy
  select family_id, child_id into v_family_id, v_child_id
  from public.assessments
  where id = p_assessment_id;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check FIRST (only active family adults can reject)
  if not private.is_active_family_adult(v_family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- 5. Order 2: Domain Entity Lock FOR UPDATE
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  -- 6. Server-enforce rejection reason validation
  if p_rejection_reason is null or length(trim(p_rejection_reason)) = 0 then
    raise exception 'Rejection reason is required' using errcode = 'LW104';
  end if;

  if length(p_rejection_reason) > 500 then
    raise exception 'Rejection reason must not exceed 500 characters' using errcode = 'LW104';
  end if;

  -- 7. Idempotency check AFTER authorization
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'reject' or v_receipt.resource_id != p_assessment_id or v_receipt.actor_user_id != v_user_id then
      raise exception 'Invalid command replay or command ID mismatch' using errcode = '42501';
    end if;

    return v_assessment;
  end if;

  -- 8. Optimistic concurrency check
  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  -- 9. Status check
  if v_assessment.status != 'pending_review' then
    raise exception 'Assessment is not pending review' using errcode = 'LW106';
  end if;

  -- 10. Transition status
  update public.assessments
  set status = 'rejected',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  -- 11. Command receipt
  insert into public.command_receipts (
    command_id,
    operation,
    actor_user_id,
    resource_id,
    family_id
  ) values (
    p_command_id,
    'reject',
    v_user_id,
    p_assessment_id,
    v_assessment.family_id
  );

  -- 12. Review audit log
  insert into public.assessment_review_events (
    command_id,
    family_id,
    assessment_id,
    event_type,
    from_status,
    to_status,
    actor_user_id,
    review_notes
  ) values (
    p_command_id,
    v_assessment.family_id,
    v_assessment.id,
    'rejected',
    'pending_review',
    'rejected',
    v_user_id,
    trim(p_rejection_reason)
  );

  return v_assessment;
end;
$$;

create or replace function public.set_assessment_learning_mappings(
  p_assessment_id uuid,
  p_mappings jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_assessment record;
  v_mapping jsonb;
  v_node record;
  v_score_source text;
  v_comp_key text;
  v_raw numeric;
  v_max numeric;
  v_items integer;
  v_correct integer;
  v_node_sources jsonb := '{}'::jsonb;
  v_comp_keys jsonb := '{}'::jsonb;
  v_result jsonb := '[]'::jsonb;
begin
  if p_assessment_id is null then
    raise exception 'Assessment ID is required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- Resolve tenancy
  select family_id, child_id into v_family_id, v_child_id
  from public.assessments
  where id = p_assessment_id;

  if not found then
    raise exception 'Assessment not found' using errcode = 'P0002';
  end if;

  -- Authorize: Active family adult ONLY
  if not private.is_active_family_adult(v_family_id) then
    raise exception 'Permission denied: active family adult authorization required' using errcode = '42501';
  end if;

  -- Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- Order 2: Domain Entity Lock FOR UPDATE
  select id, family_id, child_id, subject_key, status, learning_catalog_version
  into v_assessment
  from public.assessments
  where id = p_assessment_id for update;

  -- Lifecycle check: Authoritative mappings allowed ONLY while pending_review
  if v_assessment.status != 'pending_review' then
    raise exception 'Authoritative mappings may be set only while assessment status is pending_review (current: %)', v_assessment.status using errcode = 'LW103';
  end if;

  -- Delete existing mappings for this assessment
  delete from public.assessment_learning_mappings
  where assessment_id = p_assessment_id;

  -- Process new mappings array
  if p_mappings is not null and jsonb_array_length(p_mappings) > 0 then
    for v_mapping in select * from jsonb_array_elements(p_mappings) loop
      -- Validate node
      select id, catalog_version, subject_key, node_type, title
      into v_node
      from public.learning_nodes
      where id = (v_mapping ->> 'learning_node_id')::uuid;

      if not found then
        raise exception 'Learning node % not found', v_mapping ->> 'learning_node_id' using errcode = 'LW004';
      end if;

      -- Validate catalog version match
      if v_node.catalog_version != v_assessment.learning_catalog_version then
        raise exception 'Learning node catalog version (%) does not match assessment version (%)', v_node.catalog_version, v_assessment.learning_catalog_version using errcode = 'LW004';
      end if;

      -- Validate subject key match
      if v_node.subject_key != v_assessment.subject_key then
        raise exception 'Learning node subject (%) does not match assessment subject (%)', v_node.subject_key, v_assessment.subject_key using errcode = 'LW004';
      end if;

      -- Detailed mappings must target Domain, Topic, or Skill only
      if v_node.node_type not in ('domain', 'topic', 'skill') then
        raise exception 'Detailed mappings must target Domain, Topic, or Skill only' using errcode = 'LW004';
      end if;

      v_score_source := v_mapping ->> 'score_source';
      if v_score_source not in ('assessment_total', 'component_score', 'item_group') then
        raise exception 'Invalid score_source: %', v_score_source using errcode = 'LW004';
      end if;

      if v_node.node_type = 'skill' and v_score_source = 'assessment_total' then
        raise exception 'assessment_total cannot map to a Skill node (node % is skill)', v_node.id using errcode = 'LW004';
      end if;

      -- Validate mutually exclusive evidence source per learning node
      if v_node_sources ? v_node.id::text and (v_node_sources ->> v_node.id::text) != v_score_source then
        raise exception 'Multiple mapping entries for node % must use the same score_source', v_node.id using errcode = 'LW004';
      end if;
      v_node_sources := jsonb_set(v_node_sources, array[v_node.id::text], to_jsonb(v_score_source));

      -- Parse component fields
      v_comp_key := v_mapping ->> 'component_key';
      v_raw := coalesce((v_mapping ->> 'component_raw_score')::numeric, (v_mapping ->> 'raw_score')::numeric);
      v_max := coalesce((v_mapping ->> 'component_max_score')::numeric, (v_mapping ->> 'max_score')::numeric);
      v_items := (v_mapping ->> 'item_count')::integer;
      v_correct := (v_mapping ->> 'correct_count')::integer;

      if v_score_source = 'assessment_total' then
        if v_comp_key is not null and trim(v_comp_key) != '' and trim(v_comp_key) != 'assessment_total' then
          raise exception 'assessment_total component_key must be assessment_total' using errcode = 'LW004';
        end if;
        v_comp_key := 'assessment_total';
        v_raw := null;
        v_max := null;
        v_items := null;
        v_correct := null;

        if v_comp_keys ? (v_node.id::text || ':' || v_comp_key) then
          raise exception 'Duplicate component_key % for node %', v_comp_key, v_node.id using errcode = 'LW004';
        end if;
        v_comp_keys := jsonb_set(v_comp_keys, array[v_node.id::text || ':' || v_comp_key], 'true'::jsonb);
      elsif v_score_source = 'component_score' then
        v_comp_key := trim(coalesce(v_comp_key, ''));
        if v_comp_key = '' or v_comp_key = 'assessment_total' then
          raise exception 'component_key is required and cannot be assessment_total for component_score' using errcode = 'LW004';
        end if;
        -- Check component_key uniqueness per assessment/node
        if v_comp_keys ? (v_node.id::text || ':' || v_comp_key) then
          raise exception 'Duplicate component_key % for node %', v_comp_key, v_node.id using errcode = 'LW004';
        end if;
        v_comp_keys := jsonb_set(v_comp_keys, array[v_node.id::text || ':' || v_comp_key], 'true'::jsonb);

        if v_raw is null or v_raw < 0 or v_max is null or v_max <= 0 or v_raw > v_max then
          raise exception 'Invalid component score values: raw=%, max=%', v_raw, v_max using errcode = 'LW004';
        end if;
        v_items := null;
        v_correct := null;
      elsif v_score_source = 'item_group' then
        v_comp_key := trim(coalesce(v_comp_key, ''));
        if v_comp_key = '' or v_comp_key = 'assessment_total' then
          raise exception 'component_key is required and cannot be assessment_total for item_group' using errcode = 'LW004';
        end if;
        -- Check component_key uniqueness per assessment/node
        if v_comp_keys ? (v_node.id::text || ':' || v_comp_key) then
          raise exception 'Duplicate component_key % for node %', v_comp_key, v_node.id using errcode = 'LW004';
        end if;
        v_comp_keys := jsonb_set(v_comp_keys, array[v_node.id::text || ':' || v_comp_key], 'true'::jsonb);

        if v_items is null or v_items <= 0 or v_correct is null or v_correct < 0 or v_correct > v_items then
          raise exception 'Invalid item group values: items=%, correct=%', v_items, v_correct using errcode = 'LW004';
        end if;
        v_raw := null;
        v_max := null;
      end if;

      insert into public.assessment_learning_mappings (
        family_id, child_id, assessment_id, learning_node_id,
        component_key, score_source,
        component_raw_score, component_max_score, item_count, correct_count,
        confirmed_by_user_id, created_at, updated_at
      ) values (
        v_assessment.family_id, v_assessment.child_id, p_assessment_id, v_node.id,
        v_comp_key, v_score_source,
        v_raw, v_max, v_items, v_correct,
        v_user_id, clock_timestamp(), clock_timestamp()
      );
    end loop;
  end if;

  -- Return updated mappings in exact 16-field shape
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'family_id', m.family_id,
    'child_id', m.child_id,
    'assessment_id', m.assessment_id,
    'learning_node_id', m.learning_node_id,
    'node_title', n.title,
    'node_type', n.node_type,
    'score_source', m.score_source,
    'component_key', m.component_key,
    'component_raw_score', m.component_raw_score,
    'component_max_score', m.component_max_score,
    'item_count', m.item_count,
    'correct_count', m.correct_count,
    'confirmed_by_user_id', m.confirmed_by_user_id,
    'created_at', m.created_at,
    'updated_at', m.updated_at
  ) order by m.created_at asc, m.id asc), '[]'::jsonb) into v_result
  from public.assessment_learning_mappings m
  join public.learning_nodes n on n.id = m.learning_node_id
  where m.assessment_id = p_assessment_id;

  return v_result;
end;
$$;

create or replace function public.get_assessment_learning_mappings(
  p_assessment_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_assessment record;
  v_result jsonb;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select id, family_id, child_id into v_assessment
  from public.assessments
  where id = p_assessment_id;

  if not found then
    raise exception 'Assessment not found' using errcode = 'P0002';
  end if;

  if not (
    private.is_active_family_adult(v_assessment.family_id) or
    private.is_active_child_device(v_assessment.family_id, v_assessment.child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- Active child check
  if not private.is_child_active_in_family(v_assessment.child_id, v_assessment.family_id) then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'family_id', m.family_id,
    'child_id', m.child_id,
    'assessment_id', m.assessment_id,
    'learning_node_id', m.learning_node_id,
    'node_title', n.title,
    'node_type', n.node_type,
    'score_source', m.score_source,
    'component_key', m.component_key,
    'component_raw_score', m.component_raw_score,
    'component_max_score', m.component_max_score,
    'item_count', m.item_count,
    'correct_count', m.correct_count,
    'confirmed_by_user_id', m.confirmed_by_user_id,
    'created_at', m.created_at,
    'updated_at', m.updated_at
  ) order by m.created_at asc, m.id asc), '[]'::jsonb) into v_result
  from public.assessment_learning_mappings m
  join public.learning_nodes n on n.id = m.learning_node_id
  where m.assessment_id = p_assessment_id;

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. HARDENED REWARD STORE & WHEEL RPCS
-- ---------------------------------------------------------------------------

create or replace function public.redeem_store_reward(
  p_reward_id uuid,
  p_command_id uuid,
  p_child_id uuid
)
returns public.reward_redemptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_child_family_id uuid;
  v_family_id uuid;
  v_reward public.rewards%rowtype;
  v_receipt public.command_receipts%rowtype;
  v_existing_redemption public.reward_redemptions%rowtype;
  v_current_balance bigint;
  v_cost_minor bigint;
  v_snapshot jsonb;
  v_redemption_id uuid;
  v_redemption public.reward_redemptions%rowtype;
begin
  -- 1. Authenticate caller
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_command_id is null then
    raise exception 'Command ID is required' using errcode = '22000';
  end if;

  if p_child_id is null then
    raise exception 'Child ID is required' using errcode = '22000';
  end if;

  if p_reward_id is null then
    raise exception 'Reward ID is required' using errcode = '22000';
  end if;

  -- 2. Load authoritative target resource & derive family from DB state
  select family_id into v_child_family_id
  from public.child_profiles
  where id = p_child_id;

  if not found then
    raise exception 'Child profile not found' using errcode = 'P0002';
  end if;

  select * into v_reward
  from public.rewards
  where id = p_reward_id;

  if not found then
    raise exception 'Reward not found' using errcode = 'P0002';
  end if;

  if v_reward.family_id != v_child_family_id then
    raise exception 'Cross-family reward redemption denied' using errcode = '42501';
  end if;

  v_family_id := v_reward.family_id;

  -- 3. Authorize caller against resolved family
  if not (private.is_active_family_adult(v_family_id) or private.is_active_child_device(v_family_id, p_child_id)) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = p_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- 5. ONLY AFTER authorization: inspect command_receipts for replay
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'redeem_reward'
       or v_receipt.actor_user_id != v_user_id
       or v_receipt.family_id != v_family_id then
      raise exception 'Invalid command replay' using errcode = '42501';
    end if;

    select * into v_existing_redemption
    from public.reward_redemptions
    where id = v_receipt.resource_id;

    if not found then
      raise exception 'Invalid command replay: redemption not found' using errcode = '42501';
    end if;

    if v_existing_redemption.family_id != v_family_id
       or v_existing_redemption.child_id != p_child_id
       or v_existing_redemption.reward_id != p_reward_id
       or v_existing_redemption.origin != 'store' then
      raise exception 'Invalid command replay: resource mismatch' using errcode = '42501';
    end if;

    return v_existing_redemption;
  end if;

  -- 6. Order 2: Target reward row lock FOR UPDATE
  select * into v_reward
  from public.rewards
  where id = p_reward_id
  for update;

  if not v_reward.is_active or not v_reward.store_enabled then
    raise exception 'Reward no longer available' using errcode = 'LW205';
  end if;

  if v_reward.target_child_id is not null and v_reward.target_child_id != p_child_id then
    raise exception 'Child is not eligible for this reward' using errcode = '42501';
  end if;

  if v_reward.store_cost_minor is null or v_reward.store_cost_minor <= 0 then
    raise exception 'Invalid reward cost' using errcode = '22000';
  end if;

  v_cost_minor := v_reward.store_cost_minor;

  -- 7. Order 3: Lock child_balances row FOR UPDATE
  select rp_balance_minor into v_current_balance
  from public.child_balances
  where child_id = p_child_id
  for update;

  if not found then
    raise exception 'Child balance record not found' using errcode = 'P0002';
  end if;

  if v_current_balance < v_cost_minor then
    raise exception 'Insufficient RP balance' using errcode = 'LW201';
  end if;

  -- 8. Immutable Reward Snapshot
  v_snapshot := jsonb_build_object(
    'title', v_reward.title,
    'description', v_reward.description,
    'icon_key', v_reward.icon_key,
    'category', v_reward.category,
    'cost_minor', v_cost_minor,
    'wheel_tier', v_reward.wheel_tier
  );

  -- 9. State Mutation: insert redemption and deduct RP balance
  v_redemption_id := gen_random_uuid();

  insert into public.reward_redemptions (
    id,
    family_id,
    child_id,
    reward_id,
    origin,
    rp_cost_minor,
    reward_snapshot,
    status,
    created_at,
    updated_at
  ) values (
    v_redemption_id,
    v_family_id,
    p_child_id,
    p_reward_id,
    'store',
    v_cost_minor,
    v_snapshot,
    'pending_fulfillment',
    now(),
    now()
  ) returning * into v_redemption;

  insert into public.rp_ledger (
    family_id,
    child_id,
    amount_minor,
    reason_code,
    source_type,
    source_id,
    idempotency_key,
    metadata
  ) values (
    v_family_id,
    p_child_id,
    -v_cost_minor,
    'store_redemption',
    'reward_redemption',
    v_redemption_id,
    'rp:redemption:' || v_redemption_id::text,
    jsonb_build_object('reward_id', v_reward.id, 'title', v_reward.title)
  );

  update public.child_balances
  set rp_balance_minor = rp_balance_minor - v_cost_minor,
      updated_at = now()
  where child_id = p_child_id;

  -- 10. Record command receipt
  insert into public.command_receipts (
    command_id,
    operation,
    actor_user_id,
    resource_id,
    family_id
  ) values (
    p_command_id,
    'redeem_reward',
    v_user_id,
    v_redemption_id,
    v_family_id
  );

  return v_redemption;
end;
$$;

create or replace function public.fulfill_reward_redemption(
  p_redemption_id uuid,
  p_command_id uuid
)
returns public.reward_redemptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_redemption public.reward_redemptions%rowtype;
  v_receipt public.command_receipts%rowtype;
begin
  -- 1. Authenticate caller
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_command_id is null then
    raise exception 'Command ID is required' using errcode = '22000';
  end if;

  if p_redemption_id is null then
    raise exception 'Redemption ID is required' using errcode = '22000';
  end if;

  -- 2. Resolve target redemption tenancy
  select family_id, child_id into v_family_id, v_child_id
  from public.reward_redemptions
  where id = p_redemption_id;

  if not found then
    raise exception 'Reward redemption not found' using errcode = 'P0002';
  end if;

  -- 3. Authorize caller (active family adult only)
  if not private.is_active_family_adult(v_family_id) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- 5. Order 2: Domain Entity Lock FOR UPDATE
  select * into v_redemption
  from public.reward_redemptions
  where id = p_redemption_id
  for update;

  -- 6. ONLY AFTER authorization: inspect command_receipts for replay
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'fulfill_reward'
       or v_receipt.actor_user_id != v_user_id
       or v_receipt.family_id != v_family_id
       or v_receipt.resource_id != p_redemption_id then
      raise exception 'Invalid command replay' using errcode = '42501';
    end if;

    return v_redemption;
  end if;

  -- 7. Validate preconditions
  if v_redemption.status != 'pending_fulfillment' then
    raise exception 'Reward redemption is already in a terminal state: %', v_redemption.status using errcode = 'LW204';
  end if;

  -- 8. State Mutation: transition to fulfilled
  update public.reward_redemptions
  set status = 'fulfilled',
      fulfilled_at = now(),
      fulfilled_by_user_id = v_user_id,
      updated_at = now()
  where id = p_redemption_id
  returning * into v_redemption;

  -- 9. Record command receipt
  insert into public.command_receipts (
    command_id,
    operation,
    actor_user_id,
    resource_id,
    family_id
  ) values (
    p_command_id,
    'fulfill_reward',
    v_user_id,
    p_redemption_id,
    v_family_id
  );

  return v_redemption;
end;
$$;

create or replace function public.cancel_reward_redemption(
  p_redemption_id uuid,
  p_command_id uuid,
  p_cancellation_reason text
)
returns public.reward_redemptions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_child_id uuid;
  v_clean_reason text;
  v_redemption public.reward_redemptions%rowtype;
  v_receipt public.command_receipts%rowtype;
  v_current_balance bigint;
begin
  -- 1. Authenticate caller
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_command_id is null then
    raise exception 'Command ID is required' using errcode = '22000';
  end if;

  if p_redemption_id is null then
    raise exception 'Redemption ID is required' using errcode = '22000';
  end if;

  v_clean_reason := trim(coalesce(p_cancellation_reason, ''));
  if char_length(v_clean_reason) < 2 then
    raise exception 'Cancellation reason is required' using errcode = '22000';
  end if;

  -- 2. Resolve target redemption tenancy
  select family_id, child_id into v_family_id, v_child_id
  from public.reward_redemptions
  where id = p_redemption_id;

  if not found then
    raise exception 'Reward redemption not found' using errcode = 'P0002';
  end if;

  -- 3. Authorize caller (active family adult only)
  if not private.is_active_family_adult(v_family_id) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- 5. Order 2: Domain Entity Lock FOR UPDATE
  select * into v_redemption
  from public.reward_redemptions
  where id = p_redemption_id
  for update;

  -- 6. ONLY AFTER authorization: inspect command_receipts for replay
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'cancel_reward'
       or v_receipt.actor_user_id != v_user_id
       or v_receipt.family_id != v_family_id
       or v_receipt.resource_id != p_redemption_id then
      raise exception 'Invalid command replay' using errcode = '42501';
    end if;

    return v_redemption;
  end if;

  -- 7. Validate preconditions
  if v_redemption.status != 'pending_fulfillment' then
    raise exception 'Reward redemption is already in a terminal state: %', v_redemption.status using errcode = 'LW204';
  end if;

  -- 8. Order 3: Lock child_balances FOR UPDATE
  select rp_balance_minor into v_current_balance
  from public.child_balances
  where child_id = v_redemption.child_id
  for update;

  if not found then
    raise exception 'Child balance record not found' using errcode = 'P0002';
  end if;

  -- 9. State Mutation: cancel status and append compensating refund to rp_ledger
  update public.reward_redemptions
  set status = 'cancelled',
      cancellation_reason = v_clean_reason,
      updated_at = now()
  where id = p_redemption_id
  returning * into v_redemption;

  insert into public.rp_ledger (
    family_id,
    child_id,
    amount_minor,
    reason_code,
    source_type,
    source_id,
    idempotency_key,
    metadata
  ) values (
    v_family_id,
    v_redemption.child_id,
    v_redemption.rp_cost_minor,
    'redemption_refund',
    'reward_redemption',
    p_redemption_id,
    'rp:refund:' || p_redemption_id::text,
    jsonb_build_object('cancellation_reason', v_clean_reason, 'reward_id', v_redemption.reward_id)
  );

  update public.child_balances
  set rp_balance_minor = rp_balance_minor + v_redemption.rp_cost_minor,
      updated_at = now()
  where child_id = v_redemption.child_id;

  -- 10. Record command receipt
  insert into public.command_receipts (
    command_id,
    operation,
    actor_user_id,
    resource_id,
    family_id
  ) values (
    p_command_id,
    'cancel_reward',
    v_user_id,
    p_redemption_id,
    v_family_id
  );

  return v_redemption;
end;
$$;

create or replace function public.spin_reward_wheel(
  p_command_id uuid,
  p_child_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_family_id uuid;
  v_is_adult boolean;
  v_is_child boolean;
  v_receipt record;
  v_existing_spin record;
  v_spin_cost_minor bigint;
  v_daily_spin_cap integer;
  v_is_enabled boolean;
  v_candidate_count integer := 0;
  v_balance record;
  v_family_tz text;
  v_test_tz timestamptz;
  v_local_date date;
  v_today_start timestamptz;
  v_today_end timestamptz;
  v_spins_today integer;
  v_total_weight integer := 0;
  v_random_draw integer;
  v_cumulative integer := 0;
  v_interval_start integer;
  v_interval_end integer;
  v_prob_pct numeric;
  v_reward record;
  v_winning_reward jsonb := null;
  v_ordered_pool jsonb := '[]'::jsonb;
  v_pool_item jsonb;
  v_captured_pool jsonb := '[]'::jsonb;
  v_elem jsonb;
  v_selection_snapshot jsonb;
  v_spin_id uuid;
  v_redemption_id uuid;
  v_now timestamptz;
  v_result jsonb;
begin
  -- 1. Input validation
  if p_command_id is null or p_child_id is null then
    raise exception 'Command ID and Child ID are required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- 2. Load child & derive authoritative family identity from DB
  select family_id into v_family_id
  from public.child_profiles
  where id = p_child_id;

  if not found then
    raise exception 'Child profile not found or inactive' using errcode = 'P0002';
  end if;

  -- 3. Authorize caller against resolved family (BEFORE any timezone or config checks)
  v_is_adult := private.is_active_family_adult(v_family_id);
  v_is_child := private.is_active_child_device(v_family_id, p_child_id);

  if not (v_is_adult or v_is_child) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = p_child_id and family_id = v_family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- 5. ONLY AFTER authorization: inspect command_receipts for replay
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'spin_wheel'
       or v_receipt.actor_user_id != v_user_id
       or v_receipt.family_id != v_family_id then
      raise exception 'Invalid command replay' using errcode = '42501';
    end if;

    select
      ws.id as spin_id,
      ws.redemption_id,
      ws.family_id,
      ws.child_id,
      ws.reward_id,
      rr.reward_snapshot ->> 'title' as reward_title,
      rr.reward_snapshot ->> 'category' as reward_category,
      rr.reward_snapshot ->> 'icon_key' as reward_icon_key,
      rr.reward_snapshot ->> 'wheel_tier' as wheel_tier,
      ws.spin_cost_minor,
      cb.rp_balance_minor as new_balance_minor,
      ws.selection_snapshot,
      ws.created_at
    into v_existing_spin
    from public.wheel_spins ws
    join public.reward_redemptions rr on rr.id = ws.redemption_id
    join public.child_balances cb on cb.child_id = ws.child_id and cb.family_id = ws.family_id
    where ws.id = v_receipt.resource_id;

    if not found then
      raise exception 'Invalid command replay: spin not found' using errcode = '42501';
    end if;

    if v_existing_spin.family_id != v_family_id
       or v_existing_spin.child_id != p_child_id then
      raise exception 'Invalid command replay: resource mismatch' using errcode = '42501';
    end if;

    return jsonb_build_object(
      'spin_id', v_existing_spin.spin_id,
      'redemption_id', v_existing_spin.redemption_id,
      'family_id', v_existing_spin.family_id,
      'child_id', v_existing_spin.child_id,
      'reward_id', v_existing_spin.reward_id,
      'reward_title', v_existing_spin.reward_title,
      'reward_category', v_existing_spin.reward_category,
      'reward_icon_key', v_existing_spin.reward_icon_key,
      'wheel_tier', v_existing_spin.wheel_tier,
      'spin_cost_minor', v_existing_spin.spin_cost_minor,
      'new_balance_minor', v_existing_spin.new_balance_minor,
      'selection_snapshot', v_existing_spin.selection_snapshot,
      'created_at', v_existing_spin.created_at
    );
  end if;

  -- 6. ONLY FOR A NEW SPIN:
  -- Step 1: Validate family timezone (FAIL CLOSED on missing/corrupt timezone)
  select timezone into v_family_tz
  from public.families
  where id = v_family_id;

  if v_family_tz is null or trim(v_family_tz) = '' then
    raise exception 'Family timezone is missing or invalid' using errcode = 'LW004';
  end if;

  begin
    v_test_tz := now() at time zone v_family_tz;
  exception when others then
    raise exception 'Invalid family timezone: %', v_family_tz using errcode = 'LW004';
  end;

  -- Step 2: Lock/read family_wheel_settings FOR SHARE
  select spin_cost_minor, daily_spin_cap, is_enabled
  into v_spin_cost_minor, v_daily_spin_cap, v_is_enabled
  from public.family_wheel_settings
  where family_id = v_family_id
  for share;

  if not found then
    v_spin_cost_minor := 1000;
    v_daily_spin_cap := 3;
    v_is_enabled := true;
  end if;

  if not v_is_enabled then
    raise exception 'Wheel is currently disabled for this family' using errcode = 'LW206';
  end if;

  -- Step 3: Catalog stabilization table lock
  -- Tradeoff: Table-level SHARE lock serializes concurrent reward catalog writes (INSERT/UPDATE/DELETE)
  -- while taking the snapshot, avoiding hybrid states. Correctness now -> family-scoped optimization
  -- later if real multi-tenant contention appears.
  lock table public.rewards in share mode;

  -- Materialize eligible Wheel reward rows in ONE authoritative stabilized snapshot
  -- Captured in deterministic order: id ASC FOR SHARE
  for v_reward in
    select
      id,
      title,
      category,
      icon_key,
      wheel_tier,
      case wheel_tier
        when 'common' then 60
        when 'special' then 30
        when 'rare' then 10
        else 60
      end as weight
    from public.rewards
    where family_id = v_family_id
      and is_active = true
      and wheel_enabled = true
      and wheel_tier is not null
      and (target_child_id is null or target_child_id = p_child_id)
    order by id asc
    for share
  loop
    v_candidate_count := v_candidate_count + 1;
    v_total_weight := v_total_weight + v_reward.weight;
    v_captured_pool := v_captured_pool || jsonb_build_array(
      jsonb_build_object(
        'reward_id', v_reward.id,
        'title', v_reward.title,
        'category', v_reward.category,
        'icon_key', coalesce(v_reward.icon_key, 'default_star'),
        'tier', v_reward.wheel_tier,
        'weight', v_reward.weight
      )
    );
  end loop;

  -- Enforce minimum eligible pool size using the locked snapshot
  if v_candidate_count < 3 then
    raise exception 'Wheel requires at least 3 active eligible rewards (found %)', v_candidate_count using errcode = 'LW203';
  end if;

  -- Step 4: Lock child_balances FOR UPDATE
  select * into v_balance
  from public.child_balances
  where child_id = p_child_id and family_id = v_family_id
  for update;

  if not found then
    raise exception 'Child balance record not found' using errcode = 'P0002';
  end if;

  if v_balance.rp_balance_minor < v_spin_cost_minor then
    raise exception 'Insufficient RP balance' using errcode = 'LW201';
  end if;

  -- Step 5: Evaluate family timezone and daily spin cap
  v_local_date := (now() at time zone v_family_tz)::date;
  v_today_start := v_local_date::timestamp at time zone v_family_tz;
  v_today_end := (v_local_date + 1)::timestamp at time zone v_family_tz;

  select count(*) into v_spins_today
  from public.wheel_spins
  where child_id = p_child_id
    and created_at >= v_today_start
    and created_at < v_today_end;

  if v_spins_today >= v_daily_spin_cap then
    raise exception 'Daily spin limit reached (%/%)', v_spins_today, v_daily_spin_cap using errcode = 'LW202';
  end if;

  -- 7. Server-authoritative pseudorandom selection using the CAPTURED IN-MEMORY POOL ONLY
  -- (public.rewards is NOT queried again)
  v_random_draw := floor(random() * v_total_weight)::integer;

  v_cumulative := 0;
  v_ordered_pool := '[]'::jsonb;
  v_winning_reward := null;

  for v_elem in select * from jsonb_array_elements(v_captured_pool)
  loop
    v_interval_start := v_cumulative;
    v_interval_end := v_cumulative + (v_elem ->> 'weight')::integer;
    v_prob_pct := round(((v_elem ->> 'weight')::numeric / v_total_weight::numeric) * 100.0, 2);

    v_pool_item := jsonb_build_object(
      'reward_id', (v_elem ->> 'reward_id')::uuid,
      'title', v_elem ->> 'title',
      'category', v_elem ->> 'category',
      'icon_key', v_elem ->> 'icon_key',
      'tier', v_elem ->> 'tier',
      'weight', (v_elem ->> 'weight')::integer,
      'interval_start', v_interval_start,
      'interval_end', v_interval_end,
      'probability_pct', v_prob_pct
    );
    v_ordered_pool := v_ordered_pool || jsonb_build_array(v_pool_item);

    if v_random_draw >= v_interval_start and v_random_draw < v_interval_end then
      v_winning_reward := v_pool_item;
    end if;

    v_cumulative := v_interval_end;
  end loop;

  if v_winning_reward is null then
    -- Fail-safe boundary fallback
    v_winning_reward := v_ordered_pool -> (jsonb_array_length(v_ordered_pool) - 1);
  end if;

  v_selection_snapshot := jsonb_build_object(
    'wheel_config_version', 'wheel-v0.1',
    'spin_cost_minor', v_spin_cost_minor,
    'deterministic_ordering', 'reward_id_asc',
    'total_weight', v_total_weight,
    'random_draw', v_random_draw,
    'winning_reward_id', (v_winning_reward ->> 'reward_id')::uuid,
    'ordered_pool', v_ordered_pool
  );

  -- 8. Atomic transaction writes
  v_spin_id := gen_random_uuid();
  v_redemption_id := gen_random_uuid();
  v_now := now();

  -- A. reward_redemptions
  insert into public.reward_redemptions (
    id,
    family_id,
    child_id,
    reward_id,
    origin,
    rp_cost_minor,
    status,
    reward_snapshot,
    created_at,
    updated_at
  ) values (
    v_redemption_id,
    v_family_id,
    p_child_id,
    (v_winning_reward ->> 'reward_id')::uuid,
    'wheel',
    v_spin_cost_minor,
    'pending_fulfillment',
    jsonb_build_object(
      'title', v_winning_reward ->> 'title',
      'category', v_winning_reward ->> 'category',
      'icon_key', v_winning_reward ->> 'icon_key',
      'wheel_tier', v_winning_reward ->> 'tier',
      'origin', 'wheel',
      'spin_cost_minor', v_spin_cost_minor
    ),
    v_now,
    v_now
  );

  -- B. wheel_spins
  insert into public.wheel_spins (
    id,
    family_id,
    child_id,
    reward_id,
    redemption_id,
    origin,
    spin_cost_minor,
    selection_snapshot,
    created_at
  ) values (
    v_spin_id,
    v_family_id,
    p_child_id,
    (v_winning_reward ->> 'reward_id')::uuid,
    v_redemption_id,
    'wheel',
    v_spin_cost_minor,
    v_selection_snapshot,
    v_now
  );

  -- C. rp_ledger
  insert into public.rp_ledger (
    family_id,
    child_id,
    amount_minor,
    reason_code,
    source_type,
    source_id,
    idempotency_key,
    metadata,
    created_at
  ) values (
    v_family_id,
    p_child_id,
    -v_spin_cost_minor,
    'wheel_spin',
    'reward_redemption',
    v_redemption_id,
    'rp:wheel_spin:' || v_spin_id::text,
    jsonb_build_object('command_id', p_command_id, 'spin_id', v_spin_id),
    v_now
  );

  -- D. child_balances
  update public.child_balances
  set rp_balance_minor = rp_balance_minor - v_spin_cost_minor,
      updated_at = v_now
  where child_id = p_child_id and family_id = v_family_id;

  -- E. Build result payload
  v_result := jsonb_build_object(
    'spin_id', v_spin_id,
    'redemption_id', v_redemption_id,
    'family_id', v_family_id,
    'child_id', p_child_id,
    'reward_id', (v_winning_reward ->> 'reward_id')::uuid,
    'reward_title', v_winning_reward ->> 'title',
    'reward_category', v_winning_reward ->> 'category',
    'reward_icon_key', v_winning_reward ->> 'icon_key',
    'wheel_tier', v_winning_reward ->> 'tier',
    'spin_cost_minor', v_spin_cost_minor,
    'new_balance_minor', v_balance.rp_balance_minor - v_spin_cost_minor,
    'selection_snapshot', v_selection_snapshot,
    'created_at', v_now
  );

  -- F. command_receipts
  insert into public.command_receipts (
    command_id,
    family_id,
    actor_user_id,
    operation,
    resource_id,
    created_at
  ) values (
    p_command_id,
    v_family_id,
    v_user_id,
    'spin_wheel',
    v_spin_id,
    v_now
  );

  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. HARDENED GROWTH & LEARNING ENGINE MUTATION RPCS & CATCH-UP
-- ---------------------------------------------------------------------------

create or replace function public.process_verified_learning_event(
  p_verified_event_id uuid,
  p_command_id uuid default null
)
returns public.growth_events
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_event record;
  v_existing_growth public.growth_events;
  v_receipt record;

  v_engine_version text := 'growth-v0.1';
  v_normalized_score numeric(4, 2);
  v_difficulty text;
  v_subject_key text;
  v_grade_level integer;

  v_comparables record;
  v_count int := 0;
  v_sum numeric := 0;
  v_baseline numeric(4, 2) := null;
  v_baseline_count int := 0;
  v_growth_delta numeric(4, 2) := null;
  v_historical_best numeric(4, 2) := null;

  v_score_rp_minor bigint;
  v_growth_rp_minor bigint := 0;
  v_high_performer_rp_minor bigint := 0;
  v_goal_rp_minor bigint := 0;
  v_personal_best_rp_minor bigint := 0;
  v_difficulty_rp_minor bigint := 0;
  v_recovery_rp_minor bigint := 0;
  v_below_level boolean := false;
  v_total_rp_minor bigint;
  v_xp_awarded int;

  v_samples_json jsonb := '[]'::jsonb;
  v_inputs_snapshot jsonb;
  v_new_growth public.growth_events;
begin
  -- 1. Authentication check
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- 2. Resolve VLE tenancy (without locking yet to follow canonical locking order)
  select id, family_id, child_id into v_event
  from public.verified_learning_events
  where id = p_verified_event_id;

  if not found then
    raise exception 'Verified learning event not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check (only active family adults can process)
  if not private.is_active_family_adult(v_event.family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- 4. Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_event.child_id and family_id = v_event.family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- 5. Order 3: Resource row lock on verified_learning_events
  select * into v_event
  from public.verified_learning_events
  where id = p_verified_event_id
  for update;

  -- 6. Idempotency check 1: Has this verified event already produced a growth event?
  select * into v_existing_growth
  from public.growth_events
  where verified_learning_event_id = p_verified_event_id;

  if found then
    return v_existing_growth;
  end if;

  -- 7. Idempotency check 2: Command replay check if command ID provided
  if p_command_id is not null then
    select * into v_receipt
    from public.command_receipts
    where command_id = p_command_id;

    if found then
      if v_receipt.operation != 'process_growth' or
         v_receipt.resource_id != p_verified_event_id or
         v_receipt.actor_user_id != v_user_id then
        raise exception 'Invalid command replay or command ID mismatch' using errcode = '42501';
      end if;

      select * into v_existing_growth
      from public.growth_events
      where verified_learning_event_id = p_verified_event_id;

      if found then
        return v_existing_growth;
      end if;
    end if;
  end if;

  v_normalized_score := v_event.normalized_score;
  v_difficulty := v_event.difficulty;
  v_subject_key := v_event.subject_key;
  v_grade_level := v_event.grade_level_snapshot;
  -- Fail-closed: NEVER query mutable child_profiles.school_grade when snapshot is null.

  -- 8. Retrieve strictly prior comparable records:
  -- - Same child
  -- - Same canonical subject_key
  -- - Excludes current event
  -- - Strictly occurred before current event (or verified earlier)
  -- - Grade level comparability: both current event and candidate must have known matching grade level.
  --   Unknown grades are fail-closed and never longitudinally comparable.
  -- - Assessment type compatibility band (evaluative: quiz/exam, formative: homework/practice, other)
  -- - Difficulty compatibility band (standard: normal/hard, challenge, below_level)
  if v_grade_level is not null then
    for v_comparables in
      select id, normalized_score, difficulty, assessment_type, grade_level_snapshot, occurred_at, verified_at
      from public.verified_learning_events
      where child_id = v_event.child_id
        and subject_key = v_subject_key
        and id != v_event.id
        and (
          occurred_at < v_event.occurred_at
          or (occurred_at = v_event.occurred_at and verified_at < v_event.verified_at)
        )
        and grade_level_snapshot = v_grade_level
        and (
          case
            when v_event.assessment_type in ('quiz', 'exam') then assessment_type in ('quiz', 'exam')
            when v_event.assessment_type in ('homework', 'practice') then assessment_type in ('homework', 'practice')
            else assessment_type = v_event.assessment_type
          end
        )
        and (
          case
            when v_difficulty in ('normal', 'hard') then difficulty in ('normal', 'hard')
            when v_difficulty = 'challenge' then difficulty = 'challenge'
            when v_difficulty = 'below_level' then difficulty = 'below_level'
            else difficulty = v_difficulty
          end
        )
      order by occurred_at desc, verified_at desc
    loop
      -- Track historical best across all prior comparable records
      if v_historical_best is null or v_comparables.normalized_score > v_historical_best then
        v_historical_best := v_comparables.normalized_score;
      end if;

      -- Take first 3 for rolling baseline
      if v_count < 3 then
        v_sum := v_sum + v_comparables.normalized_score;
        v_count := v_count + 1;
        v_samples_json := v_samples_json || jsonb_build_object(
          'id', v_comparables.id,
          'score', v_comparables.normalized_score,
          'occurred_at', v_comparables.occurred_at,
          'assessment_type', v_comparables.assessment_type,
          'difficulty', v_comparables.difficulty,
          'grade_level', v_comparables.grade_level_snapshot
        );
      end if;
    end loop;
  end if;

  -- 9. Compute rolling baseline (requires 3 samples)
  if v_count >= 3 then
    v_baseline := round(v_sum / 3.0, 2);
    v_baseline_count := 3;
    v_growth_delta := round(v_normalized_score - v_baseline, 2);
  else
    v_baseline := null;
    v_baseline_count := v_count;
    v_growth_delta := null;
  end if;

  -- 10. Compute economic components in integer minor units (100 minor = 1.00 RP)
  if v_difficulty = 'below_level' then
    v_below_level := true;
    -- 25% of base score RP, bonuses disabled
    v_score_rp_minor := round((v_normalized_score * 100) * 0.25);
    v_growth_rp_minor := 0;
    v_high_performer_rp_minor := 0;
    v_personal_best_rp_minor := 0;
    v_difficulty_rp_minor := 0;
  else
    v_below_level := false;
    v_score_rp_minor := round(v_normalized_score * 100);

    -- Growth bonus
    if v_growth_delta is not null then
      if v_growth_delta >= 2.0 then
        v_growth_rp_minor := 400;
      elsif v_growth_delta >= 1.5 then
        v_growth_rp_minor := 300;
      elsif v_growth_delta >= 1.0 then
        v_growth_rp_minor := 200;
      elsif v_growth_delta >= 0.5 then
        v_growth_rp_minor := 100;
      else
        v_growth_rp_minor := 0;
      end if;
    else
      v_growth_rp_minor := 0;
    end if;

    -- High performer maintenance: baseline >= 8.5 AND current >= 8.5
    if v_baseline is not null and v_baseline >= 8.50 and v_normalized_score >= 8.50 then
      v_high_performer_rp_minor := 100;
    else
      v_high_performer_rp_minor := 0;
    end if;

    -- Personal best bonus: exceeds prior best by >= 0.25
    if v_historical_best is not null and round(v_normalized_score - v_historical_best, 2) >= 0.25 then
      v_personal_best_rp_minor := 100;
    else
      v_personal_best_rp_minor := 0;
    end if;

    -- Difficulty bonus
    if v_difficulty = 'challenge' then
      if v_normalized_score >= 5.00 then
        v_difficulty_rp_minor := 200;
      else
        v_difficulty_rp_minor := 0;
      end if;
    elsif v_difficulty = 'hard' then
      v_difficulty_rp_minor := 100;
    else
      v_difficulty_rp_minor := 0;
    end if;
  end if;

  v_total_rp_minor := v_score_rp_minor +
                      v_growth_rp_minor +
                      v_high_performer_rp_minor +
                      v_personal_best_rp_minor +
                      v_difficulty_rp_minor +
                      v_goal_rp_minor +
                      v_recovery_rp_minor;

  -- 11. Compute Study XP: XP = 10 + 2 * RP_awarded
  v_xp_awarded := 10 + round(2.0 * v_total_rp_minor / 100.0)::int;

  -- 12. Audit snapshot
  v_inputs_snapshot := jsonb_build_object(
    'engine_version', v_engine_version,
    'verified_event_id', v_event.id,
    'assessment_id', v_event.assessment_id,
    'child_id', v_event.child_id,
    'subject_key', v_subject_key,
    'grade_level', v_grade_level,
    'normalized_score', v_normalized_score,
    'difficulty', v_difficulty,
    'assessment_type', v_event.assessment_type,
    'baseline_score', v_baseline,
    'baseline_count', v_baseline_count,
    'growth_delta', v_growth_delta,
    'historical_best', v_historical_best,
    'samples_used', v_samples_json
  );

  -- 13. Insert immutable growth_event
  insert into public.growth_events (
    family_id,
    child_id,
    verified_learning_event_id,
    assessment_id,
    engine_version,
    normalized_score,
    baseline_score,
    baseline_sample_count,
    growth_delta,
    historical_best,
    score_rp_minor,
    growth_rp_minor,
    high_performer_rp_minor,
    goal_rp_minor,
    personal_best_rp_minor,
    difficulty_rp_minor,
    recovery_rp_minor,
    below_level_adjustment,
    total_rp_minor,
    xp_awarded,
    inputs_snapshot
  ) values (
    v_event.family_id,
    v_event.child_id,
    v_event.id,
    v_event.assessment_id,
    v_engine_version,
    v_normalized_score,
    v_baseline,
    v_baseline_count,
    v_growth_delta,
    v_historical_best,
    v_score_rp_minor,
    v_growth_rp_minor,
    v_high_performer_rp_minor,
    v_goal_rp_minor,
    v_personal_best_rp_minor,
    v_difficulty_rp_minor,
    v_recovery_rp_minor,
    v_below_level,
    v_total_rp_minor,
    v_xp_awarded,
    v_inputs_snapshot
  ) returning * into v_new_growth;

  -- 14. Append to authoritative XP ledger
  insert into public.xp_ledger (
    family_id,
    child_id,
    amount,
    reason_code,
    source_type,
    source_id,
    engine_version,
    idempotency_key,
    metadata
  ) values (
    v_event.family_id,
    v_event.child_id,
    v_xp_awarded,
    'growth_award',
    'growth_event',
    v_new_growth.id,
    v_engine_version,
    'xp:growth_event:' || v_new_growth.id,
    jsonb_build_object(
      'verified_learning_event_id', v_event.id,
      'assessment_id', v_event.assessment_id,
      'normalized_score', v_normalized_score
    )
  );

  -- 15. Append to authoritative RP ledger
  insert into public.rp_ledger (
    family_id,
    child_id,
    amount_minor,
    reason_code,
    source_type,
    source_id,
    engine_version,
    idempotency_key,
    metadata
  ) values (
    v_event.family_id,
    v_event.child_id,
    v_total_rp_minor,
    'growth_award',
    'growth_event',
    v_new_growth.id,
    v_engine_version,
    'rp:growth_event:' || v_new_growth.id,
    jsonb_build_object(
      'verified_learning_event_id', v_event.id,
      'assessment_id', v_event.assessment_id,
      'normalized_score', v_normalized_score
    )
  );

  -- 16. Update child_balances projection
  insert into public.child_balances (
    family_id,
    child_id,
    xp_total,
    rp_balance_minor,
    updated_at
  ) values (
    v_event.family_id,
    v_event.child_id,
    v_xp_awarded,
    v_total_rp_minor,
    now()
  ) on conflict (child_id) do update set
    xp_total = public.child_balances.xp_total + excluded.xp_total,
    rp_balance_minor = public.child_balances.rp_balance_minor + excluded.rp_balance_minor,
    updated_at = now();

  -- 17. Record command receipt if command_id provided
  if p_command_id is not null then
    insert into public.command_receipts (
      command_id,
      operation,
      actor_user_id,
      resource_id,
      family_id
    ) values (
      p_command_id,
      'process_growth',
      v_user_id,
      p_verified_event_id,
      v_event.family_id
    ) on conflict (command_id) do nothing;
  end if;

  return v_new_growth;
end;
$$;

create or replace function public.get_unprocessed_verified_learning_events(p_family_id uuid)
returns setof public.verified_learning_events
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if not private.is_active_family_adult(p_family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  return query
  select vle.*
  from public.verified_learning_events vle
  join public.child_profiles cp on cp.id = vle.child_id and cp.family_id = vle.family_id
  where vle.family_id = p_family_id
    and cp.status = 'active'
    and not exists (
      select 1
      from public.growth_events ge
      where ge.verified_learning_event_id = vle.id
    )
  order by vle.child_id asc, vle.occurred_at asc, vle.verified_at asc, vle.id asc;
end;
$$;

create or replace function public.catch_up_unprocessed_growth(p_family_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_child_row record;
  v_active_child_ids uuid[] := '{}';
  v_candidate_vle_ids uuid[] := '{}';
  v_event record;
  v_processed_count integer := 0;
begin
  if p_family_id is null then
    raise exception 'Family ID is required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if not private.is_active_family_adult(p_family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- Order 1: Deterministic Child Profile Row Locks FOR SHARE
  -- Prelock all candidate active child profiles for this family in deterministic order (id asc)
  for v_child_row in
    select id
    from public.child_profiles
    where family_id = p_family_id
      and status = 'active'
    order by id asc
    for share
  loop
    v_active_child_ids := array_append(v_active_child_ids, v_child_row.id);
  end loop;

  if cardinality(v_active_child_ids) = 0 then
    return 0;
  end if;

  -- Select candidate unprocessed VLEs for active children
  select coalesce(array_agg(vle.id order by vle.id asc), '{}')
  into v_candidate_vle_ids
  from public.verified_learning_events vle
  where vle.family_id = p_family_id
    and vle.child_id = any(v_active_child_ids)
    and not exists (
      select 1
      from public.growth_events ge
      where ge.verified_learning_event_id = vle.id
    );

  if cardinality(v_candidate_vle_ids) = 0 then
    return 0;
  end if;

  -- Order 2/3: Pre-lock all candidate verified_learning_events rows FOR UPDATE in deterministic id asc order.
  -- This guarantees all VLE row locks precede any downstream child_balances row locks acquired
  -- during growth processing, preventing lock hierarchy inversion deadlocks (40P01) with concurrent
  -- single-event process_verified_learning_event calls or concurrent catch_up_unprocessed_growth calls.
  perform 1
  from public.verified_learning_events
  where id = any(v_candidate_vle_ids)
  order by id asc
  for update;

  for v_event in
    select vle.id, vle.child_id
    from public.verified_learning_events vle
    where vle.id = any(v_candidate_vle_ids)
    order by vle.child_id asc, vle.occurred_at asc, vle.verified_at asc, vle.id asc
  loop
    -- Recheck child status (Order 1 lock already held for share)
    if exists (
      select 1
      from public.child_profiles
      where id = v_event.child_id
        and family_id = p_family_id
        and status = 'active'
    ) then
      -- Recheck pending growth processing state after acquiring synchronization locks
      if not exists (
        select 1
        from public.growth_events ge
        where ge.verified_learning_event_id = v_event.id
      ) then
        perform public.process_verified_learning_event(v_event.id, null);
        v_processed_count := v_processed_count + 1;
      end if;
    end if;
  end loop;

  return v_processed_count;
end;
$$;

create or replace function public.process_learning_event(
  p_command_id uuid,
  p_verified_event_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_vle record;
  v_receipt record;
  v_proc record;
  v_result jsonb;
begin
  if p_verified_event_id is null or p_command_id is null then
    raise exception 'Verified event ID and Command ID are required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select id, assessment_id, family_id, child_id
  into v_vle
  from public.verified_learning_events
  where id = p_verified_event_id;

  if not found then
    raise exception 'Verified learning event not found' using errcode = 'P0002';
  end if;

  if not private.is_active_family_adult(v_vle.family_id) then
    raise exception 'Permission denied: active family adult authorization required' using errcode = '42501';
  end if;

  -- Order 1: Child Profile Row Lock FOR SHARE & Active check
  perform 1
  from public.child_profiles
  where id = v_vle.child_id and family_id = v_vle.family_id and status = 'active'
  for share;

  if not found then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  -- Command receipt inspection
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'process_learning'
       or v_receipt.actor_user_id != v_user_id
       or v_receipt.family_id != v_vle.family_id
       or v_receipt.resource_id != p_verified_event_id then
      raise exception 'Invalid command replay' using errcode = '42501';
    end if;

    select * into v_proc
    from public.learning_processing_events
    where verified_learning_event_id = p_verified_event_id;

    if not found then
      raise exception 'Invalid command replay: processing event missing' using errcode = '42501';
    end if;

    return jsonb_build_object(
      'processing_id', v_proc.id,
      'verified_learning_event_id', v_proc.verified_learning_event_id,
      'assessment_id', v_proc.assessment_id,
      'family_id', v_proc.family_id,
      'child_id', v_proc.child_id,
      'evidence_count', v_proc.evidence_count,
      'affected_node_ids', to_jsonb(v_proc.affected_node_ids),
      'status', v_proc.status,
      'processed_at', v_proc.processed_at
    );
  end if;

  -- Order 4: Advisory serialization lock per VLE
  perform pg_advisory_xact_lock(hashtext('vle_' || p_verified_event_id::text));

  -- Recheck receipt
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'process_learning'
       or v_receipt.actor_user_id != v_user_id
       or v_receipt.family_id != v_vle.family_id
       or v_receipt.resource_id != p_verified_event_id then
      raise exception 'Invalid command replay' using errcode = '42501';
    end if;

    select * into v_proc
    from public.learning_processing_events
    where verified_learning_event_id = p_verified_event_id;

    if not found then
      raise exception 'Invalid command replay: processing event missing' using errcode = '42501';
    end if;

    return jsonb_build_object(
      'processing_id', v_proc.id,
      'verified_learning_event_id', v_proc.verified_learning_event_id,
      'assessment_id', v_proc.assessment_id,
      'family_id', v_proc.family_id,
      'child_id', v_proc.child_id,
      'evidence_count', v_proc.evidence_count,
      'affected_node_ids', to_jsonb(v_proc.affected_node_ids),
      'status', v_proc.status,
      'processed_at', v_proc.processed_at
    );
  end if;

  -- Check if VLE already processed under a different command
  select * into v_proc
  from public.learning_processing_events
  where verified_learning_event_id = p_verified_event_id;

  if found then
    insert into public.command_receipts (
      command_id, family_id, actor_user_id, operation, resource_id
    ) values (
      p_command_id, v_vle.family_id, v_user_id, 'process_learning', p_verified_event_id
    );

    return jsonb_build_object(
      'processing_id', v_proc.id,
      'verified_learning_event_id', v_proc.verified_learning_event_id,
      'assessment_id', v_proc.assessment_id,
      'family_id', v_proc.family_id,
      'child_id', v_proc.child_id,
      'evidence_count', v_proc.evidence_count,
      'affected_node_ids', to_jsonb(v_proc.affected_node_ids),
      'status', v_proc.status,
      'processed_at', v_proc.processed_at
    );
  end if;

  v_result := private.execute_learning_event_processing(p_verified_event_id);

  insert into public.command_receipts (
    command_id, family_id, actor_user_id, operation, resource_id
  ) values (
    p_command_id, v_vle.family_id, v_user_id, 'process_learning', p_verified_event_id
  );

  return v_result;
end;
$$;

create or replace function public.catch_up_unprocessed_learning(
  p_family_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_child_row record;
  v_active_child_ids uuid[] := '{}';
  v_candidate_vle_ids uuid[] := '{}';
  v_lock_rec record;
  v_vle record;
  v_count integer := 0;
begin
  if p_family_id is null then
    raise exception 'Family ID is required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if not private.is_active_family_adult(p_family_id) then
    raise exception 'Permission denied: active family adult authorization required' using errcode = '42501';
  end if;

  -- Order 1: Deterministic Child Profile Row Locks FOR SHARE
  -- Prelock all candidate active child profiles for this family in deterministic order (id asc)
  for v_child_row in
    select id
    from public.child_profiles
    where family_id = p_family_id
      and status = 'active'
    order by id asc
    for share
  loop
    v_active_child_ids := array_append(v_active_child_ids, v_child_row.id);
  end loop;

  if cardinality(v_active_child_ids) = 0 then
    return jsonb_build_object(
      'family_id', p_family_id,
      'processed_count', 0
    );
  end if;

  -- Select candidate unprocessed VLEs for active children
  select coalesce(array_agg(vle.id order by vle.id asc), '{}')
  into v_candidate_vle_ids
  from public.verified_learning_events vle
  where vle.family_id = p_family_id
    and vle.child_id = any(v_active_child_ids)
    and not exists (
      select 1 from public.learning_processing_events lpe
      where lpe.verified_learning_event_id = vle.id
    );

  if cardinality(v_candidate_vle_ids) = 0 then
    return jsonb_build_object(
      'family_id', p_family_id,
      'processed_count', 0
    );
  end if;

  -- Order 4: Advisory serialization locks across all candidate VLEs
  -- Prelock all candidate VLE advisory locks in strictly ascending lock key order
  -- BEFORE executing any processing. This maintains the monotonic lock hierarchy
  -- (Order 4: vle_ -> child_node_) and prevents deadlock with concurrent single-event
  -- processors that acquire vle_ before child_node_.
  for v_lock_rec in
    select distinct hashtext('vle_' || cid::text) as k
    from unnest(v_candidate_vle_ids) as cid
    order by k asc
  loop
    perform pg_advisory_xact_lock(v_lock_rec.k);
  end loop;

  -- Process candidate VLEs in canonical chronological order
  for v_vle in
    select vle.id, vle.child_id
    from public.verified_learning_events vle
    where vle.id = any(v_candidate_vle_ids)
    order by vle.child_id asc, vle.occurred_at asc, vle.id asc
  loop
    -- Recheck child lifecycle status (Order 1 lock already held for share)
    if exists (
      select 1
      from public.child_profiles
      where id = v_vle.child_id
        and family_id = p_family_id
        and status = 'active'
    ) then
      -- Recheck pending processing state after acquiring synchronization locks
      if not exists (
        select 1 from public.learning_processing_events where verified_learning_event_id = v_vle.id
      ) then
        perform private.execute_learning_event_processing(v_vle.id);
        v_count := v_count + 1;
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'family_id', p_family_id,
    'processed_count', v_count
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. HARDENED CHILD READER RPCS
-- ---------------------------------------------------------------------------

drop function if exists public.reconcile_child_balance(uuid);

create or replace function public.reconcile_child_balance(p_child_id uuid)
returns table (
  out_child_id uuid,
  out_family_id uuid,
  is_reconciled boolean,
  projected_xp bigint,
  ledger_xp bigint,
  projected_rp_minor bigint,
  ledger_rp_minor bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_fam_id uuid;
  v_status text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if p_child_id is null then
    raise exception 'Child ID is required' using errcode = '22000';
  end if;

  select cp.family_id, cp.status into v_fam_id, v_status
  from public.child_profiles cp
  where cp.id = p_child_id;

  if not found then
    raise exception 'Child profile not found' using errcode = 'LW105';
  end if;

  if not (
    private.is_active_family_adult(v_fam_id)
    or private.is_active_child_device(v_fam_id, p_child_id)
  ) then
    raise exception 'Permission denied: unauthorized for child balance reconciliation' using errcode = '42501';
  end if;

  if v_status != 'active' then
    raise exception 'Child profile is archived' using errcode = '42501';
  end if;

  return query
  select
    p_child_id,
    v_fam_id,
    (coalesce(cb.xp_total, 0) = coalesce(xl.xp_sum, 0) and
     coalesce(cb.rp_balance_minor, 0) = coalesce(rl.rp_sum, 0)) as is_reconciled,
    coalesce(cb.xp_total, 0)::bigint as projected_xp,
    coalesce(xl.xp_sum, 0)::bigint as ledger_xp,
    coalesce(cb.rp_balance_minor, 0)::bigint as projected_rp_minor,
    coalesce(rl.rp_sum, 0)::bigint as ledger_rp_minor
  from (select p_child_id as cid) target
  left join public.child_balances cb on cb.child_id = target.cid
  cross join (
    select coalesce(sum(amount), 0)::bigint as xp_sum
    from public.xp_ledger
    where child_id = p_child_id
  ) xl
  cross join (
    select coalesce(sum(amount_minor), 0)::bigint as rp_sum
    from public.rp_ledger
    where child_id = p_child_id
  ) rl;
end;
$$;

grant execute on function public.reconcile_child_balance(uuid) to authenticated;
