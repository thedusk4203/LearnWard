-- Phase 2: Secure Assessment Capture Vertical Slice
--
-- Implements assessment draft lifecycle, private evidence storage,
-- review/approval audit log, generated server-side normalized scores,
-- and immutable verified learning events.

-- ---------------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------------

create table public.assessments (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null,
  subject_key text not null check (subject_key in ('math', 'english', 'literature', 'science', 'other')),
  subject text not null check (char_length(trim(subject)) between 1 and 100),
  title text not null check (char_length(trim(title)) between 1 and 150),
  assessment_type text not null check (assessment_type in ('quiz', 'exam', 'homework', 'practice', 'other')),
  difficulty text not null default 'normal' check (difficulty in ('below_level', 'normal', 'hard', 'challenge')),
  raw_score numeric(6, 2) not null check (raw_score >= 0),
  max_score numeric(6, 2) not null check (max_score > 0),
  constraint chk_assessments_score_bound check (raw_score <= max_score),
  normalized_score numeric(4, 2) generated always as (round((raw_score / max_score) * 10.0, 2)) stored not null,
  entry_context text not null default 'adult' check (entry_context in ('adult', 'shared_child', 'paired_child')),
  status text not null default 'draft' check (status in ('draft', 'pending_review', 'verified', 'rejected')),
  occurred_at timestamptz not null default now(),
  version integer not null default 1 check (version >= 1),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint uq_assessments_id_family unique (id, family_id),
  foreign key (child_id, family_id) references public.child_profiles(id, family_id) on delete cascade
);

create index idx_assessments_family_id on public.assessments(family_id);
create index idx_assessments_child_id on public.assessments(child_id);
create index idx_assessments_status on public.assessments(status);
create index idx_assessments_family_status on public.assessments(family_id, status);
create index idx_assessments_subject_key on public.assessments(subject_key);

create table public.assessment_evidence (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  assessment_id uuid not null,
  storage_path text not null unique check (char_length(trim(storage_path)) > 0),
  media_type text not null check (media_type in ('image/jpeg', 'image/png')),
  file_size_bytes integer not null check (file_size_bytes > 0 and file_size_bytes <= 10485760),
  uploaded_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (assessment_id, family_id) references public.assessments(id, family_id) on delete cascade
);

create index idx_assessment_evidence_assessment_id on public.assessment_evidence(assessment_id);
create index idx_assessment_evidence_family_id on public.assessment_evidence(family_id);

create table public.command_receipts (
  command_id uuid primary key,
  operation text not null check (operation in ('create_draft', 'submit', 'verify', 'reject')),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  resource_id uuid not null,
  family_id uuid not null references public.families(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index idx_command_receipts_resource on public.command_receipts(resource_id);
create index idx_command_receipts_family on public.command_receipts(family_id);

create table public.assessment_review_events (
  id uuid primary key default gen_random_uuid(),
  command_id uuid not null unique references public.command_receipts(command_id) on delete cascade,
  family_id uuid not null references public.families(id) on delete cascade,
  assessment_id uuid not null,
  event_type text not null check (event_type in ('submitted', 'verified', 'rejected')),
  from_status text not null,
  to_status text not null,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  review_notes text null check (review_notes is null or char_length(review_notes) <= 1000),
  created_at timestamptz not null default now(),
  foreign key (assessment_id, family_id) references public.assessments(id, family_id) on delete cascade
);

create index idx_assessment_review_events_assessment on public.assessment_review_events(assessment_id);
create index idx_assessment_review_events_family on public.assessment_review_events(family_id);
create index idx_assessment_review_events_command on public.assessment_review_events(command_id);

create table public.verified_learning_events (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null,
  assessment_id uuid not null unique,
  subject_key text not null check (subject_key in ('math', 'english', 'literature', 'science', 'other')),
  subject text not null,
  title text not null,
  assessment_type text not null,
  difficulty text not null,
  raw_score numeric(6, 2) not null,
  max_score numeric(6, 2) not null,
  normalized_score numeric(4, 2) not null,
  evidence_count integer not null default 0 check (evidence_count >= 0),
  entry_context text not null default 'adult' check (entry_context in ('adult', 'shared_child', 'paired_child')),
  occurred_at timestamptz not null,
  verified_at timestamptz not null default now(),
  verified_by_user_id uuid not null references auth.users(id) on delete restrict,
  review_event_id uuid not null references public.assessment_review_events(id) on delete restrict,
  foreign key (child_id, family_id) references public.child_profiles(id, family_id) on delete cascade,
  foreign key (assessment_id, family_id) references public.assessments(id, family_id) on delete cascade
);

create index idx_verified_learning_events_child on public.verified_learning_events(child_id);
create index idx_verified_learning_events_family on public.verified_learning_events(family_id);
create index idx_verified_learning_events_occurred on public.verified_learning_events(occurred_at desc);
create index idx_verified_learning_events_subject_key on public.verified_learning_events(subject_key);

-- ---------------------------------------------------------------------------
-- 2. INVARIANT TRIGGERS
-- ---------------------------------------------------------------------------

-- Invariant: Verified and rejected assessments are strictly terminal.
create or replace function private.prevent_terminal_assessment_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if OLD.status in ('verified', 'rejected') then
    raise exception 'Terminal assessments cannot be modified or deleted' using errcode = 'LW103';
  end if;
  return coalesce(NEW, OLD);
end;
$$;

create trigger trg_prevent_terminal_assessment_mutation
before update or delete on public.assessments
for each row
execute function private.prevent_terminal_assessment_mutation();

-- Invariant: verified_learning_events is strictly immutable and append-only.
create or replace function private.prevent_verified_learning_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'verified_learning_events is strictly immutable' using errcode = 'LW102';
end;
$$;

create trigger trg_prevent_verified_learning_event_mutation
before update or delete on public.verified_learning_events
for each row
execute function private.prevent_verified_learning_event_mutation();

-- Invariant: assessment_review_events is strictly immutable and append-only.
create or replace function private.prevent_assessment_review_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'assessment_review_events is strictly immutable' using errcode = 'LW102';
end;
$$;

create trigger trg_prevent_assessment_review_event_mutation
before update or delete on public.assessment_review_events
for each row
execute function private.prevent_assessment_review_event_mutation();

-- Invariant: command_receipts is strictly immutable and append-only.
create or replace function private.prevent_command_receipt_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'command_receipts is strictly immutable' using errcode = 'LW102';
end;
$$;

create trigger trg_prevent_command_receipt_mutation
before update or delete on public.command_receipts
for each row
execute function private.prevent_command_receipt_mutation();

-- Invariant: assessment_evidence cannot be inserted, updated, or deleted once assessment leaves draft.
create or replace function private.prevent_terminal_assessment_evidence_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status text;
  v_assessment_id uuid;
begin
  v_assessment_id := coalesce(NEW.assessment_id, OLD.assessment_id);
  select status into v_status from public.assessments where id = v_assessment_id;
  if v_status is distinct from 'draft' then
    raise exception 'Assessment evidence can only be mutated when assessment is in draft status' using errcode = 'LW109';
  end if;
  return coalesce(NEW, OLD);
end;
$$;

create trigger trg_prevent_terminal_assessment_evidence_mutation
before insert or update or delete on public.assessment_evidence
for each row
execute function private.prevent_terminal_assessment_evidence_mutation();

-- ---------------------------------------------------------------------------
-- 3. STORAGE ACCESS VALIDATION HELPER
-- ---------------------------------------------------------------------------

create or replace function private.validate_storage_evidence_access(
  p_name text,
  p_require_draft boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_parts text[];
  v_family_id uuid;
  v_child_id uuid;
  v_assessment_id uuid;
  v_status text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    return false;
  end if;

  v_parts := string_to_array(p_name, '/');
  if array_length(v_parts, 1) != 4 then
    return false;
  end if;

  -- Validate UUID regex for segments 1, 2, 3 and opaque UUID filename with allowed extension
  if not (
    v_parts[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and v_parts[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and v_parts[3] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and v_parts[4] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png)$'
  ) then
    return false;
  end if;

  v_family_id := v_parts[1]::uuid;
  v_child_id := v_parts[2]::uuid;
  v_assessment_id := v_parts[3]::uuid;

  -- Verify active adult membership in family (or active child device grant)
  if not (
    private.is_active_family_adult(v_family_id)
    or private.is_active_child_device(v_family_id, v_child_id)
  ) then
    return false;
  end if;

  -- Check real assessment exists with matching family and child
  select status into v_status
  from public.assessments
  where id = v_assessment_id
    and family_id = v_family_id
    and child_id = v_child_id;

  if not found then
    return false;
  end if;

  -- If mutation requires draft (INSERT and DELETE)
  if p_require_draft and v_status != 'draft' then
    return false;
  end if;

  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. TRUSTED RPCs (SECURITY DEFINER)
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

  -- 3. Child profile validation
  if not exists (
    select 1 from public.child_profiles
    where id = p_child_id and family_id = p_family_id and status = 'active'
  ) then
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

  -- 6. Insert new draft
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

  -- 7. Record command receipt
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
  v_assessment public.assessments;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  if not (
    private.is_active_family_adult(v_assessment.family_id)
    or private.is_active_child_device(v_assessment.family_id, v_assessment.child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

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
  v_assessment public.assessments;
  v_evidence public.assessment_evidence;
  v_expected_pattern text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  if not (
    private.is_active_family_adult(v_assessment.family_id)
    or private.is_active_child_device(v_assessment.family_id, v_assessment.child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

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
  v_evidence public.assessment_evidence;
  v_assessment public.assessments;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  select * into v_evidence
  from public.assessment_evidence
  where id = p_evidence_id;

  if not found then
    raise exception 'Evidence not found' using errcode = 'LW111';
  end if;

  select * into v_assessment
  from public.assessments
  where id = v_evidence.assessment_id
  for update;

  if not (
    private.is_active_family_adult(v_assessment.family_id)
    or private.is_active_child_device(v_assessment.family_id, v_assessment.child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

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
  v_assessment public.assessments;
  v_receipt public.command_receipts;
begin
  -- 1. Authentication
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 2. Concurrency row lock & Target existence
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check FIRST (before idempotency inspection)
  if not (
    private.is_active_family_adult(v_assessment.family_id)
    or private.is_active_child_device(v_assessment.family_id, v_assessment.child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. Idempotency check AFTER authorization
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'submit' or v_receipt.resource_id != p_assessment_id or v_receipt.actor_user_id != v_user_id then
      raise exception 'Invalid command replay or command ID mismatch' using errcode = '42501';
    end if;

    return v_assessment;
  end if;

  -- 5. Version check
  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  -- 6. Status check
  if v_assessment.status != 'draft' then
    raise exception 'Only draft assessments can be submitted' using errcode = 'LW107';
  end if;

  -- 7. Transition status
  update public.assessments
  set status = 'pending_review',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  -- 8. Command receipt
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

  -- 9. Review audit log
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
  v_assessment public.assessments;
  v_review_event public.assessment_review_events;
  v_receipt public.command_receipts;
  v_evidence_count int;
begin
  -- 1. Authentication
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 2. Concurrency row lock & Target existence
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check FIRST (only active family adults can verify)
  if not private.is_active_family_adult(v_assessment.family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- 4. Validate notes length
  if p_notes is not null and length(p_notes) > 1000 then
    raise exception 'Verification notes must not exceed 1000 characters' using errcode = 'LW104';
  end if;

  -- 5. Idempotency check AFTER authorization
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'verify' or v_receipt.resource_id != p_assessment_id or v_receipt.actor_user_id != v_user_id then
      raise exception 'Invalid command replay or command ID mismatch' using errcode = '42501';
    end if;

    return v_assessment;
  end if;

  -- 6. Optimistic concurrency check
  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  -- 7. Status check
  if v_assessment.status != 'pending_review' then
    raise exception 'Assessment is not pending review' using errcode = 'LW106';
  end if;

  -- 8. Transition status
  update public.assessments
  set status = 'verified',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  -- 9. Command receipt
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

  -- 10. Audit log
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

  -- 11. Count attached evidence
  select count(*)::int into v_evidence_count
  from public.assessment_evidence
  where assessment_id = v_assessment.id;

  -- 12. Immutable learning event snapshot
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
  v_assessment public.assessments;
  v_receipt public.command_receipts;
begin
  -- 1. Authentication
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 2. Concurrency row lock & Target existence
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check FIRST (only active family adults can reject)
  if not private.is_active_family_adult(v_assessment.family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- 4. Server-enforce rejection reason validation
  if p_rejection_reason is null or length(trim(p_rejection_reason)) = 0 then
    raise exception 'Rejection reason is required' using errcode = 'LW104';
  end if;

  if length(p_rejection_reason) > 500 then
    raise exception 'Rejection reason must not exceed 500 characters' using errcode = 'LW104';
  end if;

  -- 5. Idempotency check AFTER authorization
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    if v_receipt.operation != 'reject' or v_receipt.resource_id != p_assessment_id or v_receipt.actor_user_id != v_user_id then
      raise exception 'Invalid command replay or command ID mismatch' using errcode = '42501';
    end if;

    return v_assessment;
  end if;

  -- 6. Optimistic concurrency check
  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  -- 7. Status check
  if v_assessment.status != 'pending_review' then
    raise exception 'Assessment is not pending review' using errcode = 'LW106';
  end if;

  -- 8. Transition status
  update public.assessments
  set status = 'rejected',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  -- 9. Command receipt
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

  -- 10. Audit log
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

-- Revoke execute from public
revoke all on function public.create_assessment_draft(uuid, uuid, uuid, text, text, text, text, text, numeric, numeric, timestamptz, text) from public;
revoke all on function public.update_assessment_draft(uuid, text, text, text, text, text, numeric, numeric, timestamptz, int) from public;
revoke all on function public.register_assessment_evidence(uuid, text, text, int) from public;
revoke all on function public.remove_draft_assessment_evidence(uuid) from public;
revoke all on function public.submit_assessment(uuid, int, uuid) from public;
revoke all on function public.verify_assessment(uuid, int, uuid, text) from public;
revoke all on function public.reject_assessment(uuid, int, uuid, text) from public;

-- Grant execute to authenticated
grant execute on function public.create_assessment_draft(uuid, uuid, uuid, text, text, text, text, text, numeric, numeric, timestamptz, text) to authenticated;
grant execute on function public.update_assessment_draft(uuid, text, text, text, text, text, numeric, numeric, timestamptz, int) to authenticated;
grant execute on function public.register_assessment_evidence(uuid, text, text, int) to authenticated;
grant execute on function public.remove_draft_assessment_evidence(uuid) to authenticated;
grant execute on function public.submit_assessment(uuid, int, uuid) to authenticated;
grant execute on function public.verify_assessment(uuid, int, uuid, text) to authenticated;
grant execute on function public.reject_assessment(uuid, int, uuid, text) to authenticated;

-- Storage validation helper grant for RLS evaluation
revoke all on function private.validate_storage_evidence_access(text, boolean) from public;
grant execute on function private.validate_storage_evidence_access(text, boolean) to authenticated;
grant execute on function private.validate_storage_evidence_access(text, boolean) to anon;
grant execute on function private.validate_storage_evidence_access(text, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY (RLS)
-- ---------------------------------------------------------------------------

alter table public.assessments enable row level security;
alter table public.assessment_evidence enable row level security;
alter table public.command_receipts enable row level security;
alter table public.assessment_review_events enable row level security;
alter table public.verified_learning_events enable row level security;

-- assessments: SELECT only for active family adults or paired child devices
create policy assessments_select on public.assessments
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

-- assessment_evidence: SELECT only for active family adults or paired child devices
create policy assessment_evidence_select on public.assessment_evidence
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or exists (
      select 1 from public.assessments a
      where a.id = assessment_evidence.assessment_id
        and private.is_active_child_device(a.family_id, a.child_id)
    )
  );

-- command_receipts: SELECT only for active family adults
create policy command_receipts_select on public.command_receipts
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
  );

-- assessment_review_events: SELECT only for active family adults
create policy assessment_review_events_select on public.assessment_review_events
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
  );

-- verified_learning_events: SELECT only for active family adults or paired child devices
create policy verified_learning_events_select on public.verified_learning_events
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

-- ---------------------------------------------------------------------------
-- 6. STORAGE BUCKET & STORAGE RLS POLICIES
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'assessment-evidence',
  'assessment-evidence',
  false,
  10485760,
  array['image/jpeg', 'image/png']
)
on conflict (id) do update set
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg', 'image/png'];

-- Evidence Read: Caller must belong to the assessment's family and path must match real assessment
create policy "Assessment evidence read for authorized family"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'assessment-evidence'
  and private.validate_storage_evidence_access(name, false)
);

-- Evidence Insert: Caller must belong to the assessment's family, path must match, and assessment must be draft
create policy "Assessment evidence insert for draft assessment"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'assessment-evidence'
  and private.validate_storage_evidence_access(name, true)
);

-- Evidence Delete: Caller must belong to the assessment's family, path must match, and assessment must be draft
create policy "Assessment evidence delete for draft assessment"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'assessment-evidence'
  and private.validate_storage_evidence_access(name, true)
);

-- Notice: No UPDATE policy is defined. Overwrite / upsert on storage.objects is strictly forbidden.

-- ---------------------------------------------------------------------------
-- 7. EXPLICIT TABLE GRANTS
-- ---------------------------------------------------------------------------

-- Authenticated role has SELECT only. Direct INSERT/UPDATE/DELETE is revoked.
grant select on public.assessments to authenticated;
grant select on public.assessment_evidence to authenticated;
grant select on public.command_receipts to authenticated;
grant select on public.assessment_review_events to authenticated;
grant select on public.verified_learning_events to authenticated;

-- Service role retains full administrative access
grant all on public.assessments to service_role;
grant all on public.assessment_evidence to service_role;
grant all on public.command_receipts to service_role;
grant all on public.assessment_review_events to service_role;
grant all on public.verified_learning_events to service_role;
