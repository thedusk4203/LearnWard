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
  subject text not null check (char_length(trim(subject)) between 1 and 100),
  title text not null check (char_length(trim(title)) between 1 and 150),
  assessment_type text not null check (assessment_type in ('quiz', 'exam', 'homework', 'practice', 'other')),
  difficulty text not null default 'normal' check (difficulty in ('below_level', 'normal', 'hard', 'challenge')),
  raw_score numeric(6, 2) not null check (raw_score >= 0),
  max_score numeric(6, 2) not null check (max_score > 0),
  constraint chk_assessments_score_bound check (raw_score <= max_score),
  normalized_score numeric(4, 2) generated always as (round((raw_score / max_score) * 10.0, 2)) stored not null,
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

create table public.assessment_review_events (
  id uuid primary key default gen_random_uuid(),
  command_id uuid not null unique,
  family_id uuid not null references public.families(id) on delete cascade,
  assessment_id uuid not null,
  event_type text not null check (event_type in ('submitted', 'verified', 'rejected')),
  from_status text not null,
  to_status text not null,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  review_notes text null,
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
  subject text not null,
  title text not null,
  assessment_type text not null,
  difficulty text not null,
  raw_score numeric(6, 2) not null,
  max_score numeric(6, 2) not null,
  normalized_score numeric(4, 2) not null,
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

-- ---------------------------------------------------------------------------
-- 3. TRUSTED RPCs (SECURITY DEFINER)
-- ---------------------------------------------------------------------------

create or replace function public.create_assessment_draft(
  p_family_id uuid,
  p_child_id uuid,
  p_subject text,
  p_title text,
  p_assessment_type text,
  p_difficulty text,
  p_raw_score numeric,
  p_max_score numeric,
  p_occurred_at timestamptz default now()
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

  if not (
    private.is_active_family_adult(p_family_id)
    or private.is_active_child_device(p_family_id, p_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.child_profiles
    where id = p_child_id and family_id = p_family_id and status = 'active'
  ) then
    raise exception 'Child profile not found or inactive' using errcode = 'LW108';
  end if;

  insert into public.assessments (
    family_id,
    child_id,
    subject,
    title,
    assessment_type,
    difficulty,
    raw_score,
    max_score,
    status,
    occurred_at,
    created_by_user_id
  ) values (
    p_family_id,
    p_child_id,
    trim(p_subject),
    trim(p_title),
    p_assessment_type,
    p_difficulty,
    p_raw_score,
    p_max_score,
    'draft',
    coalesce(p_occurred_at, now()),
    v_user_id
  ) returning * into v_assessment;

  return v_assessment;
end;
$$;

create or replace function public.update_assessment_draft(
  p_assessment_id uuid,
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

  update public.assessments
  set subject = trim(p_subject),
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
  v_expected_prefix text;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  select * into v_assessment
  from public.assessments
  where id = p_assessment_id;

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

  -- Path convention: <family_id>/<child_id>/<assessment_id>/<filename>
  v_expected_prefix := v_assessment.family_id::text || '/' || v_assessment.child_id::text || '/' || v_assessment.id::text || '/';
  if not (trim(p_storage_path) like v_expected_prefix || '%') then
    raise exception 'Storage path must match family/child/assessment hierarchy' using errcode = 'LW110';
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
  where id = v_evidence.assessment_id;

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
  v_existing_event public.assessment_review_events;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  select * into v_existing_event
  from public.assessment_review_events
  where command_id = p_command_id;

  if found then
    if v_existing_event.assessment_id != p_assessment_id then
      raise exception 'command_id already used for different assessment' using errcode = 'LW104';
    end if;
    select * into v_assessment from public.assessments where id = p_assessment_id;
    return v_assessment;
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

  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  if v_assessment.status != 'draft' then
    raise exception 'Only draft assessments can be submitted' using errcode = 'LW107';
  end if;

  update public.assessments
  set status = 'pending_review',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

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
  v_existing_event public.assessment_review_events;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 1. Idempotency check on command_id
  select * into v_existing_event
  from public.assessment_review_events
  where command_id = p_command_id;

  if found then
    if v_existing_event.assessment_id != p_assessment_id then
      raise exception 'command_id already used for different assessment' using errcode = 'LW104';
    end if;
    select * into v_assessment from public.assessments where id = p_assessment_id;
    return v_assessment;
  end if;

  -- 2. Concurrency row lock on target assessment
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check (only active family adults can verify)
  if not private.is_active_family_adult(v_assessment.family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- 4. Optimistic concurrency check
  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  -- 5. Status check
  if v_assessment.status != 'pending_review' then
    raise exception 'Assessment is not pending review' using errcode = 'LW106';
  end if;

  -- 6. Transition status
  update public.assessments
  set status = 'verified',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  -- 7. Audit log
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

  -- 8. Immutable learning event snapshot
  insert into public.verified_learning_events (
    family_id,
    child_id,
    assessment_id,
    subject,
    title,
    assessment_type,
    difficulty,
    raw_score,
    max_score,
    normalized_score,
    occurred_at,
    verified_by_user_id,
    review_event_id
  ) values (
    v_assessment.family_id,
    v_assessment.child_id,
    v_assessment.id,
    v_assessment.subject,
    v_assessment.title,
    v_assessment.assessment_type,
    v_assessment.difficulty,
    v_assessment.raw_score,
    v_assessment.max_score,
    v_assessment.normalized_score,
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
  p_rejection_reason text default null
)
returns public.assessments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_assessment public.assessments;
  v_existing_event public.assessment_review_events;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = 'LW001';
  end if;

  -- 1. Idempotency check
  select * into v_existing_event
  from public.assessment_review_events
  where command_id = p_command_id;

  if found then
    if v_existing_event.assessment_id != p_assessment_id then
      raise exception 'command_id already used for different assessment' using errcode = 'LW104';
    end if;
    select * into v_assessment from public.assessments where id = p_assessment_id;
    return v_assessment;
  end if;

  -- 2. Concurrency row lock
  select * into v_assessment
  from public.assessments
  where id = p_assessment_id
  for update;

  if not found then
    raise exception 'Assessment not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check (only active family adults can reject)
  if not private.is_active_family_adult(v_assessment.family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- 4. Optimistic concurrency check
  if v_assessment.version != p_expected_version then
    raise exception 'Stale assessment version' using errcode = 'LW101';
  end if;

  -- 5. Status check
  if v_assessment.status != 'pending_review' then
    raise exception 'Assessment is not pending review' using errcode = 'LW106';
  end if;

  -- 6. Transition status
  update public.assessments
  set status = 'rejected',
      version = version + 1,
      updated_at = now()
  where id = p_assessment_id
  returning * into v_assessment;

  -- 7. Audit log
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
    p_rejection_reason
  );

  return v_assessment;
end;
$$;

-- Revoke execute from public
revoke all on function public.create_assessment_draft(uuid, uuid, text, text, text, text, numeric, numeric, timestamptz) from public;
revoke all on function public.update_assessment_draft(uuid, text, text, text, text, numeric, numeric, timestamptz, int) from public;
revoke all on function public.register_assessment_evidence(uuid, text, text, int) from public;
revoke all on function public.remove_draft_assessment_evidence(uuid) from public;
revoke all on function public.submit_assessment(uuid, int, uuid) from public;
revoke all on function public.verify_assessment(uuid, int, uuid, text) from public;
revoke all on function public.reject_assessment(uuid, int, uuid, text) from public;

-- Grant execute to authenticated
grant execute on function public.create_assessment_draft(uuid, uuid, text, text, text, text, numeric, numeric, timestamptz) to authenticated;
grant execute on function public.update_assessment_draft(uuid, text, text, text, text, numeric, numeric, timestamptz, int) to authenticated;
grant execute on function public.register_assessment_evidence(uuid, text, text, int) to authenticated;
grant execute on function public.remove_draft_assessment_evidence(uuid) to authenticated;
grant execute on function public.submit_assessment(uuid, int, uuid) to authenticated;
grant execute on function public.verify_assessment(uuid, int, uuid, text) to authenticated;
grant execute on function public.reject_assessment(uuid, int, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY (RLS)
-- ---------------------------------------------------------------------------

alter table public.assessments enable row level security;
alter table public.assessment_evidence enable row level security;
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
-- 5. STORAGE BUCKET & STORAGE RLS POLICIES
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

create policy "Assessment evidence read for family adults"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'assessment-evidence'
  and (
    case when name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
         then private.is_active_family_adult((split_part(name, '/', 1))::uuid)
         else false
    end
  )
);

create policy "Assessment evidence insert for family adults"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'assessment-evidence'
  and (
    case when name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
         then private.is_active_family_adult((split_part(name, '/', 1))::uuid)
         else false
    end
  )
);

create policy "Assessment evidence delete for family adults"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'assessment-evidence'
  and (
    case when name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
         then private.is_active_family_adult((split_part(name, '/', 1))::uuid)
         else false
    end
  )
);

-- ---------------------------------------------------------------------------
-- 6. EXPLICIT TABLE GRANTS
-- ---------------------------------------------------------------------------

-- Authenticated role has SELECT only. Direct INSERT/UPDATE/DELETE is revoked.
grant select on public.assessments to authenticated;
grant select on public.assessment_evidence to authenticated;
grant select on public.assessment_review_events to authenticated;
grant select on public.verified_learning_events to authenticated;

-- Service role retains full administrative access
grant all on public.assessments to service_role;
grant all on public.assessment_evidence to service_role;
grant all on public.assessment_review_events to service_role;
grant all on public.verified_learning_events to service_role;
