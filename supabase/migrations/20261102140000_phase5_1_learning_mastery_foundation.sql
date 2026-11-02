-- LearnWard Phase 5.1 — Learning Engine, Mastery & Confidence Foundation
-- Migration: 20261102140000_phase5_1_learning_mastery_foundation.sql

-- ---------------------------------------------------------------------------
-- 0. EXTEND COMMAND RECEIPTS OPERATION CHECK
-- ---------------------------------------------------------------------------
-- Preserves all frozen Phase 1–4 operations and adds Phase 5 operation: process_learning.

alter table public.command_receipts
  drop constraint if exists command_receipts_operation_check,
  add constraint command_receipts_operation_check
    check (operation in (
      'create_draft', 'submit', 'verify', 'reject', 'process_growth',
      'redeem_reward', 'fulfill_reward', 'cancel_reward', 'spin_wheel',
      'process_learning'
    ));

-- ---------------------------------------------------------------------------
-- 1. CATALOG REGISTRY (public.learning_catalog_versions)
-- ---------------------------------------------------------------------------

create table if not exists public.learning_catalog_versions (
  version text primary key,
  status text not null check (status in ('draft', 'active', 'retired')),
  activated_at timestamptz null,
  created_at timestamptz not null default clock_timestamp()
);

create unique index if not exists uq_learning_catalog_versions_single_active
  on public.learning_catalog_versions (status)
  where status = 'active';

alter table public.learning_catalog_versions enable row level security;

-- Client permissions: authenticated and anon can select/read active or retired versions
drop policy if exists learning_catalog_versions_select on public.learning_catalog_versions;
create policy learning_catalog_versions_select on public.learning_catalog_versions
  for select
  to authenticated, anon
  using (true);

-- Direct client writes are revoked; platform administration only
grant select on public.learning_catalog_versions to authenticated, anon;
grant all on public.learning_catalog_versions to service_role;

-- ---------------------------------------------------------------------------
-- 2. REFERENCE NODES (public.learning_nodes)
-- ---------------------------------------------------------------------------

create table if not exists public.learning_nodes (
  id uuid primary key default gen_random_uuid(),
  catalog_version text not null references public.learning_catalog_versions(version),
  node_type text not null check (node_type in ('subject', 'domain', 'topic', 'skill')),
  subject_key text not null check (subject_key in ('math', 'english', 'literature', 'science', 'other')),
  canonical_key text not null,
  title text not null,
  parent_id uuid null references public.learning_nodes(id),
  grade_min integer null check (grade_min is null or (grade_min >= 0 and grade_min <= 12)),
  grade_max integer null check (grade_max is null or (grade_max >= 0 and grade_max <= 12)),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  constraint uq_learning_nodes_version_id unique (catalog_version, id),
  constraint uq_learning_nodes_version_subject_id unique (catalog_version, subject_key, id),
  constraint uq_learning_nodes_version_key unique (catalog_version, canonical_key),
  constraint chk_learning_nodes_grades check (grade_min is null or grade_max is null or grade_min <= grade_max)
);

-- Exactly one Subject root node per (catalog_version, subject_key)
create unique index if not exists uq_learning_nodes_subject_root
  on public.learning_nodes (catalog_version, subject_key)
  where parent_id is null and node_type = 'subject';

-- Hierarchy and immutability trigger for learning_nodes
create or replace function private.validate_learning_node_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cat_status text;
  v_parent record;
begin
  -- Check catalog status: active and retired catalog content is completely immutable
  if tg_op in ('UPDATE', 'DELETE') then
    select status into v_cat_status
    from public.learning_catalog_versions
    where version = old.catalog_version;
    if v_cat_status in ('active', 'retired') then
      raise exception 'Published catalog content is immutable' using errcode = 'LW102';
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    -- Verify catalog version is in draft if inserting/updating
    select status into v_cat_status
    from public.learning_catalog_versions
    where version = new.catalog_version;
    if v_cat_status is null then
      raise exception 'Catalog version does not exist' using errcode = 'LW004';
    end if;
    if tg_op = 'INSERT' and v_cat_status in ('active', 'retired') and current_setting('learnward.bootstrap', true) != 'true' then
      raise exception 'Cannot add nodes to published catalog' using errcode = 'LW102';
    end if;

    -- Validate hierarchy parent integrity
    if new.node_type = 'subject' then
      if new.parent_id is not null then
        raise exception 'Subject root nodes cannot have a parent' using errcode = 'LW004';
      end if;
    else
      if new.parent_id is null then
        raise exception 'Non-subject nodes must have a parent' using errcode = 'LW004';
      end if;
      select id, catalog_version, subject_key, node_type into v_parent
      from public.learning_nodes
      where id = new.parent_id;
      if not found then
        raise exception 'Parent node not found' using errcode = 'LW004';
      end if;
      if v_parent.catalog_version != new.catalog_version then
        raise exception 'Cross-version parent edge rejected' using errcode = 'LW004';
      end if;
      if v_parent.subject_key != new.subject_key then
        raise exception 'Cross-subject parent edge rejected' using errcode = 'LW004';
      end if;
      -- Validate hierarchy levels
      if new.node_type = 'domain' and v_parent.node_type != 'subject' then
        raise exception 'Domain parent must be Subject' using errcode = 'LW004';
      elsif new.node_type = 'topic' and v_parent.node_type != 'domain' then
        raise exception 'Topic parent must be Domain' using errcode = 'LW004';
      elsif new.node_type = 'skill' and v_parent.node_type != 'topic' then
        raise exception 'Skill parent must be Topic' using errcode = 'LW004';
      end if;
    end if;
    return new;
  end if;

  return old;
end;
$$;

drop trigger if exists trg_learning_nodes_mutation on public.learning_nodes;
create trigger trg_learning_nodes_mutation
  before insert or update or delete on public.learning_nodes
  for each row
  execute function private.validate_learning_node_mutation();

alter table public.learning_nodes enable row level security;

drop policy if exists learning_nodes_select on public.learning_nodes;
create policy learning_nodes_select on public.learning_nodes
  for select
  to authenticated, anon
  using (true);

grant select on public.learning_nodes to authenticated, anon;
grant all on public.learning_nodes to service_role;

-- ---------------------------------------------------------------------------
-- 3. SKILL PREREQUISITE GRAPH (public.learning_prerequisites)
-- ---------------------------------------------------------------------------

create table if not exists public.learning_prerequisites (
  id uuid primary key default gen_random_uuid(),
  catalog_version text not null,
  subject_key text not null,
  prerequisite_node_id uuid not null,
  dependent_node_id uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint uq_learning_prerequisites_pair unique (catalog_version, prerequisite_node_id, dependent_node_id),
  constraint chk_learning_prerequisites_no_self check (prerequisite_node_id <> dependent_node_id),
  foreign key (catalog_version, subject_key, prerequisite_node_id)
    references public.learning_nodes(catalog_version, subject_key, id) on delete cascade,
  foreign key (catalog_version, subject_key, dependent_node_id)
    references public.learning_nodes(catalog_version, subject_key, id) on delete cascade
);

-- Prerequisite immutability and endpoint validation
create or replace function private.validate_learning_prerequisite_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cat_status text;
  v_prereq_type text;
  v_dep_type text;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select status into v_cat_status
    from public.learning_catalog_versions
    where version = old.catalog_version;
    if v_cat_status in ('active', 'retired') then
      raise exception 'Published catalog prerequisites are immutable' using errcode = 'LW102';
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    select status into v_cat_status
    from public.learning_catalog_versions
    where version = new.catalog_version;
    if v_cat_status is null then
      raise exception 'Catalog version does not exist' using errcode = 'LW004';
    end if;
    if tg_op = 'INSERT' and v_cat_status in ('active', 'retired') and current_setting('learnward.bootstrap', true) != 'true' then
      raise exception 'Cannot add prerequisites to published catalog' using errcode = 'LW102';
    end if;

    -- Validate endpoints are Skills
    select node_type into v_prereq_type
    from public.learning_nodes
    where id = new.prerequisite_node_id;

    select node_type into v_dep_type
    from public.learning_nodes
    where id = new.dependent_node_id;

    if v_prereq_type != 'skill' or v_dep_type != 'skill' then
      raise exception 'Prerequisite edges must link Skill nodes only' using errcode = 'LW004';
    end if;

    return new;
  end if;

  return old;
end;
$$;

drop trigger if exists trg_learning_prerequisites_mutation on public.learning_prerequisites;
create trigger trg_learning_prerequisites_mutation
  before insert or update or delete on public.learning_prerequisites
  for each row
  execute function private.validate_learning_prerequisite_mutation();

alter table public.learning_prerequisites enable row level security;

drop policy if exists learning_prerequisites_select on public.learning_prerequisites;
create policy learning_prerequisites_select on public.learning_prerequisites
  for select
  to authenticated, anon
  using (true);

grant select on public.learning_prerequisites to authenticated, anon;
grant all on public.learning_prerequisites to service_role;

-- ---------------------------------------------------------------------------
-- 4. PLATFORM-ONLY CATALOG PROMOTION RPC
-- ---------------------------------------------------------------------------

create or replace function public.promote_learning_catalog_version(
  p_new_version text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidate record;
  v_missing_roots integer;
  v_invalid_hierarchy integer;
  v_invalid_prereqs integer;
  v_cycle_detected boolean := false;
  v_active_count integer;
begin
  if p_new_version is null or trim(p_new_version) = '' then
    raise exception 'Catalog version parameter is required' using errcode = '22000';
  end if;

  -- 1. Coordination locking on the catalog registry
  perform 1 from public.learning_catalog_versions for update;

  -- 2. Validate candidate version exists and is in 'draft' status
  select * into v_candidate
  from public.learning_catalog_versions
  where version = p_new_version for update;

  if not found then
    raise exception 'Catalog version % not found', p_new_version using errcode = 'P0002';
  end if;

  if v_candidate.status != 'draft' then
    raise exception 'Only draft catalog versions may be promoted (current status: %)', v_candidate.status using errcode = 'LW004';
  end if;

  -- 3. Validate publishability:
  -- A. All 5 canonical Subject roots must exist
  select count(distinct subject_key) into v_missing_roots
  from public.learning_nodes
  where catalog_version = p_new_version
    and node_type = 'subject'
    and parent_id is null
    and subject_key in ('math', 'english', 'literature', 'science', 'other');

  if v_missing_roots < 5 then
    raise exception 'Candidate catalog is missing canonical Subject roots' using errcode = 'LW004';
  end if;

  -- B. Prerequisite edges: verify Skill endpoints and check for cycles (DAG)
  select count(*) into v_invalid_prereqs
  from public.learning_prerequisites p
  join public.learning_nodes n1 on n1.id = p.prerequisite_node_id
  join public.learning_nodes n2 on n2.id = p.dependent_node_id
  where p.catalog_version = p_new_version
    and (n1.node_type != 'skill' or n2.node_type != 'skill');

  if v_invalid_prereqs > 0 then
    raise exception 'Candidate catalog contains prerequisite edges linking non-Skill nodes' using errcode = 'LW004';
  end if;

  -- Cycle check using recursive CTE
  with recursive reach as (
    select prerequisite_node_id as root, dependent_node_id as current_node, 1 as depth
    from public.learning_prerequisites
    where catalog_version = p_new_version
    union all
    select r.root, p.dependent_node_id, r.depth + 1
    from reach r
    join public.learning_prerequisites p on p.prerequisite_node_id = r.current_node
    where p.catalog_version = p_new_version and r.depth < 100
  )
  select exists (
    select 1 from reach where root = current_node
  ) into v_cycle_detected;

  if v_cycle_detected then
    raise exception 'Candidate catalog contains cycles in prerequisite graph' using errcode = 'LW004';
  end if;

  -- 4. Atomic retirement and promotion
  update public.learning_catalog_versions
  set status = 'retired'
  where status = 'active';

  update public.learning_catalog_versions
  set status = 'active',
      activated_at = clock_timestamp()
  where version = p_new_version;

  -- 5. Post-assertion: exactly ONE active version must exist before commit
  select count(*) into v_active_count
  from public.learning_catalog_versions
  where status = 'active';

  if v_active_count != 1 then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  return jsonb_build_object(
    'status', 'success',
    'promoted_version', p_new_version,
    'activated_at', clock_timestamp()
  );
end;
$$;

-- Security: Platform-only execution
revoke execute on function public.promote_learning_catalog_version(text) from public;
revoke execute on function public.promote_learning_catalog_version(text) from anon;
revoke execute on function public.promote_learning_catalog_version(text) from authenticated;
grant execute on function public.promote_learning_catalog_version(text) to service_role;

-- ---------------------------------------------------------------------------
-- 5. INITIAL PILOT-V0.1 BOOTSTRAP
-- ---------------------------------------------------------------------------

set learnward.bootstrap = 'true';

-- Seed pilot-v0.1 version record
insert into public.learning_catalog_versions (version, status, activated_at, created_at)
values ('pilot-v0.1', 'active', clock_timestamp(), clock_timestamp())
on conflict (version) do update set status = 'active';

-- Seed the 5 canonical Subject root nodes
insert into public.learning_nodes (catalog_version, node_type, subject_key, canonical_key, title, parent_id, sort_order, is_active)
values
  ('pilot-v0.1', 'subject', 'math', 'pilot-v0.1:subject:math', 'Mathematics', null, 1, true),
  ('pilot-v0.1', 'subject', 'english', 'pilot-v0.1:subject:english', 'English Language Arts', null, 2, true),
  ('pilot-v0.1', 'subject', 'literature', 'pilot-v0.1:subject:literature', 'Literature & Reading', null, 3, true),
  ('pilot-v0.1', 'subject', 'science', 'pilot-v0.1:subject:science', 'Science', null, 4, true),
  ('pilot-v0.1', 'subject', 'other', 'pilot-v0.1:subject:other', 'Other Subjects', null, 5, true)
on conflict (catalog_version, canonical_key) do nothing;

-- Seed curated Pilot nodes for Mathematics (Domain -> Topic -> Skill)
insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active)
select
  'b0000001-0000-0000-0000-000000000001'::uuid, 'pilot-v0.1', 'domain', 'math', 'pilot-v0.1:math:arithmetic', 'Arithmetic & Numbers', n.id, 1, 6, 1, true
from public.learning_nodes n where n.catalog_version = 'pilot-v0.1' and n.canonical_key = 'pilot-v0.1:subject:math'
on conflict (catalog_version, canonical_key) do nothing;

insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active)
select
  'b0000002-0000-0000-0000-000000000001'::uuid, 'pilot-v0.1', 'topic', 'math', 'pilot-v0.1:math:arithmetic:addition', 'Addition Operations', n.id, 1, 4, 1, true
from public.learning_nodes n where n.catalog_version = 'pilot-v0.1' and n.canonical_key = 'pilot-v0.1:math:arithmetic'
on conflict (catalog_version, canonical_key) do nothing;

insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active)
select
  'b0000003-0000-0000-0000-000000000001'::uuid, 'pilot-v0.1', 'skill', 'math', 'pilot-v0.1:math:arithmetic:addition:single_digit', 'Single Digit Addition', n.id, 1, 2, 1, true
from public.learning_nodes n where n.catalog_version = 'pilot-v0.1' and n.canonical_key = 'pilot-v0.1:math:arithmetic:addition'
on conflict (catalog_version, canonical_key) do nothing;

insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active)
select
  'b0000003-0000-0000-0000-000000000002'::uuid, 'pilot-v0.1', 'skill', 'math', 'pilot-v0.1:math:arithmetic:addition:double_digit', 'Double Digit Addition', n.id, 2, 4, 2, true
from public.learning_nodes n where n.catalog_version = 'pilot-v0.1' and n.canonical_key = 'pilot-v0.1:math:arithmetic:addition'
on conflict (catalog_version, canonical_key) do nothing;

-- Seed prerequisite edge: Single Digit Addition -> Double Digit Addition
insert into public.learning_prerequisites (catalog_version, subject_key, prerequisite_node_id, dependent_node_id)
values ('pilot-v0.1', 'math', 'b0000003-0000-0000-0000-000000000001'::uuid, 'b0000003-0000-0000-0000-000000000002'::uuid)
on conflict do nothing;

-- Seed curated Pilot nodes for English Language Arts
insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active)
select
  'b0000001-0000-0000-0000-000000000002'::uuid, 'pilot-v0.1', 'domain', 'english', 'pilot-v0.1:english:grammar', 'Grammar & Mechanics', n.id, 1, 8, 1, true
from public.learning_nodes n where n.catalog_version = 'pilot-v0.1' and n.canonical_key = 'pilot-v0.1:subject:english'
on conflict (catalog_version, canonical_key) do nothing;

insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active)
select
  'b0000002-0000-0000-0000-000000000002'::uuid, 'pilot-v0.1', 'topic', 'english', 'pilot-v0.1:english:grammar:punctuation', 'Punctuation', n.id, 1, 5, 1, true
from public.learning_nodes n where n.catalog_version = 'pilot-v0.1' and n.canonical_key = 'pilot-v0.1:english:grammar'
on conflict (catalog_version, canonical_key) do nothing;

insert into public.learning_nodes (id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active)
select
  'b0000003-0000-0000-0000-000000000003'::uuid, 'pilot-v0.1', 'skill', 'english', 'pilot-v0.1:english:grammar:punctuation:end_marks', 'End Punctuation Marks', n.id, 1, 3, 1, true
from public.learning_nodes n where n.catalog_version = 'pilot-v0.1' and n.canonical_key = 'pilot-v0.1:english:grammar:punctuation'
on conflict (catalog_version, canonical_key) do nothing;

set learnward.bootstrap = 'false';

-- ---------------------------------------------------------------------------
-- 6. ADDITIVE CATALOG PROVENANCE ON ASSESSMENTS & VLEs
-- ---------------------------------------------------------------------------

-- A. assessments: Add column with DEFAULT 'pilot-v0.1' NOT NULL, then DROP DEFAULT
alter table public.assessments
  add column if not exists learning_catalog_version text not null default 'pilot-v0.1'
    references public.learning_catalog_versions(version);

alter table public.assessments
  alter column learning_catalog_version drop default;

-- Trigger to snapshot active catalog on assessment creation
create or replace function private.set_assessment_catalog_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active_version text;
begin
  select version into v_active_version
  from public.learning_catalog_versions
  where status = 'active';

  if v_active_version is null then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  -- Overwrite caller input with server authoritative active catalog version
  new.learning_catalog_version := v_active_version;
  return new;
end;
$$;

drop trigger if exists trg_assessment_catalog_snapshot on public.assessments;
create trigger trg_assessment_catalog_snapshot
  before insert on public.assessments
  for each row
  execute function private.set_assessment_catalog_snapshot();

-- B. verified_learning_events: Add column with DEFAULT 'pilot-v0.1' NOT NULL, then DROP DEFAULT
alter table public.verified_learning_events
  add column if not exists learning_catalog_version text not null default 'pilot-v0.1'
    references public.learning_catalog_versions(version);

alter table public.verified_learning_events
  alter column learning_catalog_version drop default;

-- Trigger to copy assessment catalog version snapshot into VLE
create or replace function private.set_vle_catalog_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assessment_version text;
begin
  select learning_catalog_version into v_assessment_version
  from public.assessments
  where id = new.assessment_id;

  if v_assessment_version is null then
    -- Fallback to active if assessment not found
    select version into v_assessment_version
    from public.learning_catalog_versions
    where status = 'active';
  end if;

  if v_assessment_version is null then
    raise exception 'No active learning catalog' using errcode = 'LW501';
  end if;

  new.learning_catalog_version := v_assessment_version;
  return new;
end;
$$;

drop trigger if exists trg_vle_catalog_snapshot on public.verified_learning_events;
create trigger trg_vle_catalog_snapshot
  before insert on public.verified_learning_events
  for each row
  execute function private.set_vle_catalog_snapshot();

-- ---------------------------------------------------------------------------
-- 7. ASSESSMENT LEARNING MAPPINGS (public.assessment_learning_mappings)
-- ---------------------------------------------------------------------------

create table if not exists public.assessment_learning_mappings (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references public.assessments(id) on delete cascade,
  learning_node_id uuid not null references public.learning_nodes(id),
  family_id uuid not null references public.families(id),
  score_source text not null check (score_source in ('assessment_total', 'component_score', 'item_group')),
  component_key text null,
  component_raw_score numeric(6,2) null,
  component_max_score numeric(6,2) null,
  item_count integer null check (item_count is null or item_count > 0),
  correct_count integer null check (correct_count is null or (correct_count >= 0 and correct_count <= item_count)),
  created_at timestamptz not null default clock_timestamp(),
  constraint chk_mapping_component check (
    score_source != 'component_score' or
    (component_key is null or trim(component_key) != '') and (component_raw_score is not null and component_raw_score >= 0 and component_max_score is not null and component_max_score > 0 and component_raw_score <= component_max_score)
  ),
  constraint chk_mapping_item_group check (
    score_source != 'item_group' or
    (item_count is not null and correct_count is not null and correct_count <= item_count)
  )
);

alter table public.assessment_learning_mappings enable row level security;

-- RLS: active family adults and child devices can read mappings for their family
drop policy if exists assessment_learning_mappings_select on public.assessment_learning_mappings;
create policy assessment_learning_mappings_select on public.assessment_learning_mappings
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or exists (
      select 1 from public.child_device_grants cdg
      join public.assessments a on a.id = assessment_learning_mappings.assessment_id
      where cdg.auth_user_id = auth.uid()
        and cdg.family_id = assessment_learning_mappings.family_id
        and cdg.child_id = a.child_id
        and cdg.status = 'active'
    )
  );

grant select on public.assessment_learning_mappings to authenticated;
grant all on public.assessment_learning_mappings to service_role;

-- RPC: set_assessment_learning_mappings
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
  v_total_mapped boolean := false;
  v_result jsonb := '[]'::jsonb;
begin
  if p_assessment_id is null then
    raise exception 'Assessment ID is required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- Lock assessment row FOR UPDATE to serialize against verification/rejection
  select id, family_id, child_id, subject_key, status, learning_catalog_version
  into v_assessment
  from public.assessments
  where id = p_assessment_id for update;

  if not found then
    raise exception 'Assessment not found' using errcode = 'P0002';
  end if;

  -- Authorize: Active family adult ONLY
  if not private.is_active_family_adult(v_assessment.family_id) then
    raise exception 'Permission denied: active family adult authorization required' using errcode = '42501';
  end if;

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

      -- Invariant: whole assessment_total cannot map to a Skill node
      if v_score_source = 'assessment_total' and v_node.node_type = 'skill' then
        raise exception 'assessment_total cannot be mapped to a Skill node' using errcode = 'LW004';
      end if;

      -- Invariant: at most one assessment_total mapping per assessment
      if v_score_source = 'assessment_total' then
        if v_total_mapped then
          raise exception 'At most one assessment_total mapping allowed per assessment' using errcode = 'LW004';
        end if;
        v_total_mapped := true;
      end if;

      -- Invariant: no mixed score sources for the same node
      if v_node_sources ? (v_node.id::text) then
        if (v_node_sources ->> (v_node.id::text)) != v_score_source then
          raise exception 'Mixed score sources for the same node % rejected', v_node.id using errcode = 'LW004';
        end if;
      else
        v_node_sources := jsonb_set(v_node_sources, array[v_node.id::text], to_jsonb(v_score_source));
      end if;

      -- Parse component fields
      v_comp_key := v_mapping ->> 'component_key';
      v_raw := coalesce((v_mapping ->> 'component_raw_score')::numeric, (v_mapping ->> 'raw_score')::numeric);
      v_max := coalesce((v_mapping ->> 'component_max_score')::numeric, (v_mapping ->> 'max_score')::numeric);
      v_items := (v_mapping ->> 'item_count')::integer;
      v_correct := (v_mapping ->> 'correct_count')::integer;

      if v_score_source = 'component_score' then
        if v_comp_key is null or trim(v_comp_key) = '' then
          raise exception 'component_key is required for component_score' using errcode = 'LW004';
        end if;
        -- Check component_key uniqueness per assessment/node
        if v_comp_keys ? (v_node.id::text || ':' || v_comp_key) then
          raise exception 'Duplicate component_key % for node %', v_comp_key, v_node.id using errcode = 'LW004';
        end if;
        v_comp_keys := jsonb_set(v_comp_keys, array[v_node.id::text || ':' || v_comp_key], 'true'::jsonb);

        if v_raw is null or v_raw < 0 or v_max is null or v_max <= 0 or v_raw > v_max then
          raise exception 'Invalid component score values: raw=%, max=%', v_raw, v_max using errcode = 'LW004';
        end if;
      elsif v_score_source = 'item_group' then
        if v_items is null or v_items <= 0 or v_correct is null or v_correct < 0 or v_correct > v_items then
          raise exception 'Invalid item group values: items=%, correct=%', v_items, v_correct using errcode = 'LW004';
        end if;
      end if;

      insert into public.assessment_learning_mappings (
        assessment_id, learning_node_id, family_id, score_source,
        component_key, component_raw_score, component_max_score,
        item_count, correct_count
      ) values (
        p_assessment_id, v_node.id, v_assessment.family_id, v_score_source,
        v_comp_key, v_raw, v_max,
        v_items, v_correct
      );
    end loop;
  end if;

  -- Return updated mappings
  select jsonb_agg(jsonb_build_object(
    'id', m.id,
    'learning_node_id', m.learning_node_id,
    'node_title', n.title,
    'node_type', n.node_type,
    'score_source', m.score_source,
    'component_key', m.component_key,
    'component_raw_score', m.component_raw_score,
    'raw_score', m.component_raw_score,
    'component_max_score', m.component_max_score,
    'max_score', m.component_max_score,
    'item_count', m.item_count,
    'correct_count', m.correct_count
  )) into v_result
  from public.assessment_learning_mappings m
  join public.learning_nodes n on n.id = m.learning_node_id
  where m.assessment_id = p_assessment_id;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

revoke execute on function public.set_assessment_learning_mappings(uuid, jsonb) from public;
revoke execute on function public.set_assessment_learning_mappings(uuid, jsonb) from anon;
grant execute on function public.set_assessment_learning_mappings(uuid, jsonb) to authenticated;
grant execute on function public.set_assessment_learning_mappings(uuid, jsonb) to service_role;

-- RPC: get_assessment_learning_mappings
create or replace function public.get_assessment_learning_mappings(
  p_assessment_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assessment record;
  v_result jsonb;
begin
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

  select jsonb_agg(jsonb_build_object(
    'id', m.id,
    'learning_node_id', m.learning_node_id,
    'node_title', n.title,
    'node_type', n.node_type,
    'canonical_key', n.canonical_key,
    'score_source', m.score_source,
    'component_key', m.component_key,
    'component_raw_score', m.component_raw_score,
    'raw_score', m.component_raw_score,
    'component_max_score', m.component_max_score,
    'max_score', m.component_max_score,
    'item_count', m.item_count,
    'correct_count', m.correct_count,
    'created_at', m.created_at
  )) into v_result
  from public.assessment_learning_mappings m
  join public.learning_nodes n on n.id = m.learning_node_id
  where m.assessment_id = p_assessment_id;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

grant execute on function public.get_assessment_learning_mappings(uuid) to authenticated;
grant execute on function public.get_assessment_learning_mappings(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 8. EFFECTIVE LEARNING EVIDENCE (public.learning_evidence_events)
-- ---------------------------------------------------------------------------

create table if not exists public.learning_evidence_events (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id),
  child_id uuid not null,
  verified_learning_event_id uuid not null references public.verified_learning_events(id),
  assessment_id uuid not null references public.assessments(id),
  learning_node_id uuid not null references public.learning_nodes(id),
  catalog_version text not null references public.learning_catalog_versions(version),
  node_type text not null check (node_type in ('subject', 'domain', 'topic', 'skill')),
  subject_key text not null check (subject_key in ('math', 'english', 'literature', 'science', 'other')),
  grade_level_snapshot integer null,
  assessment_type text not null,
  difficulty text not null,
  score_source text not null check (score_source in ('assessment_total', 'component_score', 'item_group')),
  performance_pct numeric(5,2) not null check (performance_pct between 0 and 100),
  specificity_weight numeric not null,
  level_weight numeric not null,
  item_count integer null,
  correct_count integer null,
  occurred_at timestamptz not null,
  effective_occurred_at timestamptz not null,
  verified_at timestamptz not null,
  created_at timestamptz not null default clock_timestamp(),
  constraint uq_learning_evidence_events_vle_node unique (verified_learning_event_id, learning_node_id),
  foreign key (child_id, family_id) references public.child_profiles(id, family_id)
);

-- Invariant: learning_evidence_events is strictly immutable and append-only
create or replace function private.prevent_learning_evidence_events_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'learning_evidence_events is strictly immutable' using errcode = 'LW102';
end;
$$;

drop trigger if exists trg_prevent_learning_evidence_events_mutation on public.learning_evidence_events;
create trigger trg_prevent_learning_evidence_events_mutation
  before update or delete on public.learning_evidence_events
  for each row
  execute function private.prevent_learning_evidence_events_mutation();

alter table public.learning_evidence_events enable row level security;

drop policy if exists learning_evidence_events_select on public.learning_evidence_events;
create policy learning_evidence_events_select on public.learning_evidence_events
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

grant select on public.learning_evidence_events to authenticated;
grant all on public.learning_evidence_events to service_role;

-- ---------------------------------------------------------------------------
-- 9. MASTERY HISTORY & CURRENT PROJECTIONS
-- ---------------------------------------------------------------------------

create table if not exists public.mastery_state_revisions (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id),
  child_id uuid not null,
  learning_node_id uuid not null references public.learning_nodes(id),
  trigger_verified_learning_event_id uuid not null references public.verified_learning_events(id),
  engine_version text not null default 'mastery-v0.1',
  previous_mastery_score numeric(5,2) null,
  new_mastery_score numeric(5,2) not null check (new_mastery_score between 0 and 100),
  effective_evidence_count integer not null check (effective_evidence_count >= 1),
  latest_evidence_at timestamptz not null,
  calculation_snapshot jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  foreign key (child_id, family_id) references public.child_profiles(id, family_id)
);

-- Invariant: mastery_state_revisions is strictly immutable and append-only
create or replace function private.prevent_mastery_state_revisions_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'mastery_state_revisions is strictly immutable' using errcode = 'LW102';
end;
$$;

drop trigger if exists trg_prevent_mastery_state_revisions_mutation on public.mastery_state_revisions;
create trigger trg_prevent_mastery_state_revisions_mutation
  before update or delete on public.mastery_state_revisions
  for each row
  execute function private.prevent_mastery_state_revisions_mutation();

alter table public.mastery_state_revisions enable row level security;

drop policy if exists mastery_state_revisions_select on public.mastery_state_revisions;
create policy mastery_state_revisions_select on public.mastery_state_revisions
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

grant select on public.mastery_state_revisions to authenticated;
grant all on public.mastery_state_revisions to service_role;

-- Current child mastery projection (child_mastery_states)
create table if not exists public.child_mastery_states (
  child_id uuid not null,
  learning_node_id uuid not null references public.learning_nodes(id),
  family_id uuid not null references public.families(id),
  engine_version text not null default 'mastery-v0.1',
  mastery_score numeric(5,2) not null check (mastery_score between 0 and 100),
  effective_evidence_count integer not null default 0,
  distinct_assessment_count integer not null default 0,
  last_evidence_event_id uuid not null references public.learning_evidence_events(id),
  last_evidence_occurred_at timestamptz not null,
  last_verified_at timestamptz not null,
  latest_revision_id uuid not null references public.mastery_state_revisions(id),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (child_id, learning_node_id),
  foreign key (child_id, family_id) references public.child_profiles(id, family_id)
);

alter table public.child_mastery_states enable row level security;

drop policy if exists child_mastery_states_select on public.child_mastery_states;
create policy child_mastery_states_select on public.child_mastery_states
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

grant select on public.child_mastery_states to authenticated;
grant all on public.child_mastery_states to service_role;

-- ---------------------------------------------------------------------------
-- 10. PROCESSING AUDIT (public.learning_processing_events)
-- ---------------------------------------------------------------------------

create table if not exists public.learning_processing_events (
  id uuid primary key default gen_random_uuid(),
  verified_learning_event_id uuid not null unique references public.verified_learning_events(id),
  assessment_id uuid not null references public.assessments(id),
  family_id uuid not null references public.families(id),
  child_id uuid not null,
  processed_at timestamptz not null default clock_timestamp(),
  evidence_count integer not null check (evidence_count >= 1),
  affected_node_ids uuid[] not null,
  status text not null check (status = 'processed'),
  foreign key (child_id, family_id) references public.child_profiles(id, family_id)
);

-- Invariant: learning_processing_events is strictly immutable and append-only
create or replace function private.prevent_learning_processing_events_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'learning_processing_events is strictly immutable' using errcode = 'LW102';
end;
$$;

drop trigger if exists trg_prevent_learning_processing_events_mutation on public.learning_processing_events;
create trigger trg_prevent_learning_processing_events_mutation
  before update or delete on public.learning_processing_events
  for each row
  execute function private.prevent_learning_processing_events_mutation();

alter table public.learning_processing_events enable row level security;

drop policy if exists learning_processing_events_select on public.learning_processing_events;
create policy learning_processing_events_select on public.learning_processing_events
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

grant select on public.learning_processing_events to authenticated;
grant all on public.learning_processing_events to service_role;

-- ---------------------------------------------------------------------------
-- 11. INTERNAL LEARNING PROCESSING ENGINE (private.execute_learning_event_processing)
-- ---------------------------------------------------------------------------

create or replace function private.execute_learning_event_processing(
  p_vle_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_vle record;
  v_subject_root record;
  v_subject_perf numeric(5,2);
  v_subject_spec_weight numeric := 0.35;
  v_subject_lvl_weight numeric;
  v_eff_occurred timestamptz;
  v_mapped record;
  v_perf numeric(5,2);
  v_spec_weight numeric;
  v_lvl_weight numeric;
  v_affected_node_ids uuid[] := array[]::uuid[];
  v_node_id uuid;
  v_evidence_count integer := 0;
  v_ev record;
  v_current_score numeric(5,2);
  v_prev_score numeric(5,2);
  v_step_count integer;
  v_steps jsonb;
  v_alpha_eff numeric;
  v_revision_id uuid;
  v_last_ev record;
  v_distinct_assessments integer;
  v_processing_id uuid;
begin
  -- 1. Load VLE
  select id, assessment_id, family_id, child_id, subject_key,
         normalized_score as score, difficulty, assessment_type as type,
         occurred_at, verified_at, learning_catalog_version, grade_level_snapshot
  into v_vle
  from public.verified_learning_events
  where id = p_vle_id;

  if not found then
    raise exception 'Verified learning event not found' using errcode = 'P0002';
  end if;

  v_eff_occurred := least(v_vle.occurred_at, v_vle.verified_at);

  -- 2. Materialize automatic Subject-root fallback evidence
  select id, catalog_version, subject_key, node_type
  into v_subject_root
  from public.learning_nodes
  where catalog_version = v_vle.learning_catalog_version
    and subject_key = v_vle.subject_key
    and parent_id is null
    and node_type = 'subject';

  if not found then
    raise exception 'Authoritative Subject root node not found for % %', v_vle.learning_catalog_version, v_vle.subject_key using errcode = 'LW501';
  end if;

  v_subject_perf := round((v_vle.score * 10.0)::numeric, 2);
  v_subject_lvl_weight := case when v_vle.difficulty = 'below_level' then 0.50 else 1.00 end;

  insert into public.learning_evidence_events (
    family_id, child_id, verified_learning_event_id, assessment_id,
    learning_node_id, catalog_version, node_type, subject_key,
    grade_level_snapshot, assessment_type, difficulty, score_source,
    performance_pct, specificity_weight, level_weight,
    item_count, correct_count, occurred_at, effective_occurred_at, verified_at
  ) values (
    v_vle.family_id, v_vle.child_id, v_vle.id, v_vle.assessment_id,
    v_subject_root.id, v_vle.learning_catalog_version, 'subject', v_vle.subject_key,
    v_vle.grade_level_snapshot, v_vle.type, v_vle.difficulty, 'assessment_total',
    v_subject_perf, v_subject_spec_weight, v_subject_lvl_weight,
    null, null, v_vle.occurred_at, v_eff_occurred, v_vle.verified_at
  )
  on conflict (verified_learning_event_id, learning_node_id) do nothing;

  v_affected_node_ids := array_append(v_affected_node_ids, v_subject_root.id);
  v_evidence_count := v_evidence_count + 1;

  -- 3. Materialize aggregated detailed evidence from assessment_learning_mappings
  for v_mapped in
    select
      m.learning_node_id,
      n.node_type,
      n.subject_key,
      m.score_source,
      sum(m.component_raw_score) as sum_raw,
      sum(m.component_max_score) as sum_max,
      sum(m.item_count) as sum_items,
      sum(m.correct_count) as sum_correct
    from public.assessment_learning_mappings m
    join public.learning_nodes n on n.id = m.learning_node_id
    where m.assessment_id = v_vle.assessment_id
    group by m.learning_node_id, n.node_type, n.subject_key, m.score_source
  loop
    if v_mapped.score_source = 'component_score' then
      v_perf := round(((v_mapped.sum_raw / v_mapped.sum_max) * 100.0)::numeric, 2);
    elsif v_mapped.score_source = 'item_group' then
      v_perf := round(((v_mapped.sum_correct::numeric / v_mapped.sum_items::numeric) * 100.0)::numeric, 2);
    else
      v_perf := round((v_vle.score * 10.0)::numeric, 2);
    end if;

    v_spec_weight := case v_mapped.node_type
      when 'skill' then 1.00
      when 'topic' then 0.75
      when 'domain' then 0.50
      else 0.35
    end;
    v_lvl_weight := case when v_vle.difficulty = 'below_level' then 0.50 else 1.00 end;

    insert into public.learning_evidence_events (
      family_id, child_id, verified_learning_event_id, assessment_id,
      learning_node_id, catalog_version, node_type, subject_key,
      grade_level_snapshot, assessment_type, difficulty, score_source,
      performance_pct, specificity_weight, level_weight,
      item_count, correct_count, occurred_at, effective_occurred_at, verified_at
    ) values (
      v_vle.family_id, v_vle.child_id, v_vle.id, v_vle.assessment_id,
      v_mapped.learning_node_id, v_vle.learning_catalog_version, v_mapped.node_type, v_mapped.subject_key,
      v_vle.grade_level_snapshot, v_vle.type, v_vle.difficulty, v_mapped.score_source,
      v_perf, v_spec_weight, v_lvl_weight,
      v_mapped.sum_items, v_mapped.sum_correct, v_vle.occurred_at, v_eff_occurred, v_vle.verified_at
    )
    on conflict (verified_learning_event_id, learning_node_id) do nothing;

    if not (v_affected_node_ids @> array[v_mapped.learning_node_id]) then
      v_affected_node_ids := array_append(v_affected_node_ids, v_mapped.learning_node_id);
    end if;
    v_evidence_count := v_evidence_count + 1;
  end loop;

  -- 4. Sort affected node IDs in canonical ASC order
  select array_agg(nid order by nid asc) into v_affected_node_ids
  from unnest(v_affected_node_ids) as nid;

  -- 5. Acquire transaction-scoped child+node serialization locks in deterministic order
  foreach v_node_id in array v_affected_node_ids loop
    perform pg_advisory_xact_lock(hashtext('child_node_' || v_vle.child_id::text || '_' || v_node_id::text));
  end loop;

  -- 6. For each affected node, execute canonical evidence rebuild
  foreach v_node_id in array v_affected_node_ids loop
    v_current_score := null;
    v_step_count := 0;
    v_steps := '[]'::jsonb;

    -- Load previous projection score for revision logging
    select mastery_score into v_prev_score
    from public.child_mastery_states
    where child_id = v_vle.child_id and learning_node_id = v_node_id;

    -- Read complete immutable evidence set in canonical chronology
    for v_ev in
      select * from public.learning_evidence_events
      where child_id = v_vle.child_id and learning_node_id = v_node_id
      order by effective_occurred_at asc, verified_at asc, verified_learning_event_id asc
    loop
      v_step_count := v_step_count + 1;
      v_last_ev := v_ev;

      if v_step_count = 1 then
        -- First credible observation: Option A (M_1 = P_1)
        v_current_score := v_ev.performance_pct;
        v_steps := v_steps || jsonb_build_object(
          'step', 1,
          'type', 'initialization',
          'vle_id', v_ev.verified_learning_event_id,
          'performance_pct', v_ev.performance_pct,
          'result_score', v_current_score
        );
      else
        -- Subsequent observations: EWMA
        v_alpha_eff := round(0.35 * v_ev.specificity_weight * v_ev.level_weight, 4);
        v_current_score := round(v_current_score + v_alpha_eff * (v_ev.performance_pct - v_current_score), 2);
        v_steps := v_steps || jsonb_build_object(
          'step', v_step_count,
          'type', 'ewma',
          'vle_id', v_ev.verified_learning_event_id,
          'performance_pct', v_ev.performance_pct,
          'alpha_effective', v_alpha_eff,
          'result_score', v_current_score
        );
      end if;
    end loop;

    -- Count distinct assessments
    select count(distinct assessment_id) into v_distinct_assessments
    from public.learning_evidence_events
    where child_id = v_vle.child_id and learning_node_id = v_node_id;

    -- Append revision
    insert into public.mastery_state_revisions (
      family_id, child_id, learning_node_id, trigger_verified_learning_event_id,
      engine_version, previous_mastery_score, new_mastery_score,
      effective_evidence_count, latest_evidence_at, calculation_snapshot
    ) values (
      v_vle.family_id, v_vle.child_id, v_node_id, v_vle.id,
      'mastery-v0.1', v_prev_score, v_current_score,
      v_step_count, v_last_ev.effective_occurred_at,
      jsonb_build_object(
        'steps', v_steps,
        'final_score', v_current_score,
        'distinct_assessments', v_distinct_assessments
      )
    ) returning id into v_revision_id;

    -- Upsert current child mastery projection
    insert into public.child_mastery_states (
      child_id, learning_node_id, family_id, engine_version,
      mastery_score, effective_evidence_count, distinct_assessment_count,
      last_evidence_event_id, last_evidence_occurred_at, last_verified_at,
      latest_revision_id, updated_at
    ) values (
      v_vle.child_id, v_node_id, v_vle.family_id, 'mastery-v0.1',
      v_current_score, v_step_count, v_distinct_assessments,
      v_last_ev.id, v_last_ev.effective_occurred_at, v_last_ev.verified_at,
      v_revision_id, clock_timestamp()
    )
    on conflict (child_id, learning_node_id) do update set
      mastery_score = excluded.mastery_score,
      effective_evidence_count = excluded.effective_evidence_count,
      distinct_assessment_count = excluded.distinct_assessment_count,
      last_evidence_event_id = excluded.last_evidence_event_id,
      last_evidence_occurred_at = excluded.last_evidence_occurred_at,
      last_verified_at = excluded.last_verified_at,
      latest_revision_id = excluded.latest_revision_id,
      updated_at = excluded.updated_at;
  end loop;

  -- 7. Append immutable learning_processing_event
  insert into public.learning_processing_events (
    verified_learning_event_id, assessment_id, family_id, child_id,
    processed_at, evidence_count, affected_node_ids, status
  ) values (
    v_vle.id, v_vle.assessment_id, v_vle.family_id, v_vle.child_id,
    clock_timestamp(), array_length(v_affected_node_ids, 1), v_affected_node_ids, 'processed'
  )
  returning id into v_processing_id;

  return jsonb_build_object(
    'processing_id', v_processing_id,
    'verified_learning_event_id', v_vle.id,
    'assessment_id', v_vle.assessment_id,
    'family_id', v_vle.family_id,
    'child_id', v_vle.child_id,
    'evidence_count', array_length(v_affected_node_ids, 1),
    'affected_node_ids', to_jsonb(v_affected_node_ids),
    'status', 'processed',
    'processed_at', clock_timestamp()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. PUBLIC TRUSTED LEARNING PROCESSING RPC (public.process_learning_event)
-- ---------------------------------------------------------------------------

create or replace function public.process_learning_event(
  p_verified_event_id uuid,
  p_command_id uuid
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
  -- 1. Input validation
  if p_verified_event_id is null or p_command_id is null then
    raise exception 'Verified event ID and Command ID are required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- 2. Load VLE and derive family & child from authoritative server state
  select id, assessment_id, family_id, child_id
  into v_vle
  from public.verified_learning_events
  where id = p_verified_event_id;

  if not found then
    raise exception 'Verified learning event not found' using errcode = 'P0002';
  end if;

  -- 3. Authorize caller against resolved family: Active family adult ONLY (paired child denied)
  if not private.is_active_family_adult(v_vle.family_id) then
    raise exception 'Permission denied: active family adult authorization required' using errcode = '42501';
  end if;

  -- 4. Initial command receipt inspection
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

    -- Return committed result snapshot directly from immutable learning_processing_events
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

  -- 5. Acquire per-VLE serialization lock
  perform pg_advisory_xact_lock(hashtext('vle_' || p_verified_event_id::text));

  -- 6. POST-LOCK RECHECK in fresh snapshot
  select * into v_receipt
  from public.command_receipts
  where command_id = p_command_id;

  if found then
    select * into v_proc
    from public.learning_processing_events
    where verified_learning_event_id = p_verified_event_id;

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
    -- Bind new command receipt to existing result
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

  -- 7. Unprocessed: execute internal processing engine
  v_result := private.execute_learning_event_processing(p_verified_event_id);

  -- 8. Record command receipt
  insert into public.command_receipts (
    command_id, family_id, actor_user_id, operation, resource_id
  ) values (
    p_command_id, v_vle.family_id, v_user_id, 'process_learning', p_verified_event_id
  );

  return v_result;
end;
$$;

revoke execute on function public.process_learning_event(uuid, uuid) from public;
revoke execute on function public.process_learning_event(uuid, uuid) from anon;
grant execute on function public.process_learning_event(uuid, uuid) to authenticated;
grant execute on function public.process_learning_event(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 13. BULK CATCH-UP RPC (public.catch_up_unprocessed_learning)
-- ---------------------------------------------------------------------------

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

  -- Authorize: Active family adult ONLY (paired child and cross-family denied)
  if not private.is_active_family_adult(p_family_id) then
    raise exception 'Permission denied: active family adult authorization required' using errcode = '42501';
  end if;

  -- Discover unprocessed VLEs for this family
  for v_vle in
    select vle.id
    from public.verified_learning_events vle
    where vle.family_id = p_family_id
      and not exists (
        select 1 from public.learning_processing_events lpe
        where lpe.verified_learning_event_id = vle.id
      )
    order by vle.occurred_at asc, vle.id asc
  loop
    -- Acquire serialization lock per VLE
    perform pg_advisory_xact_lock(hashtext('vle_' || v_vle.id::text));

    -- Recheck if still unprocessed
    if not exists (
      select 1 from public.learning_processing_events where verified_learning_event_id = v_vle.id
    ) then
      perform private.execute_learning_event_processing(v_vle.id);
      v_count := v_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'family_id', p_family_id,
    'processed_count', v_count
  );
end;
$$;

revoke execute on function public.catch_up_unprocessed_learning(uuid) from public;
revoke execute on function public.catch_up_unprocessed_learning(uuid) from anon;
grant execute on function public.catch_up_unprocessed_learning(uuid) to authenticated;
grant execute on function public.catch_up_unprocessed_learning(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 14. READ QUERY RPC: get_child_mastery
-- ---------------------------------------------------------------------------

create or replace function public.get_child_mastery(
  p_child_id uuid,
  p_as_of timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
  v_child record;
  v_as_of timestamptz;
  v_result jsonb := '[]'::jsonb;
begin
  if p_child_id is null then
    raise exception 'Child ID is required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select id, family_id into v_child
  from public.child_profiles
  where id = p_child_id and status = 'active';

  if not found then
    raise exception 'Child profile not found' using errcode = 'P0002';
  end if;

  if not (
    private.is_active_family_adult(v_child.family_id) or
    private.is_active_child_device(v_child.family_id, p_child_id)
  ) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  v_as_of := coalesce(p_as_of, transaction_timestamp());

  -- Query child mastery joined with learning nodes and evaluate confidence/bands
  select jsonb_agg(jsonb_build_object(
    'learning_node_id', cms.learning_node_id,
    'canonical_key', n.canonical_key,
    'title', n.title,
    'node_type', n.node_type,
    'subject_key', n.subject_key,
    'catalog_version', n.catalog_version,
    'mastery_score', cms.mastery_score,
    'effective_evidence_count', cms.effective_evidence_count,
    'distinct_assessment_count', cms.distinct_assessment_count,
    'last_evidence_occurred_at', cms.last_evidence_occurred_at,
    'confidence_band', conf.band,
    'confidence_units', conf.units,
    'mastery_band', case
      when cms.mastery_score >= 85 and conf.band = 'high' and conf.distinct_recent_vles >= 2 then 'mastered'
      when cms.mastery_score >= 85 then 'mastery_candidate'
      when cms.mastery_score >= 70 then 'secure'
      when cms.mastery_score >= 50 then 'developing'
      else 'emerging'
    end,
    'updated_at', cms.updated_at
  )) into v_result
  from public.child_mastery_states cms
  join public.learning_nodes n on n.id = cms.learning_node_id
  cross join lateral (
    select
      coalesce(sum(ev.specificity_weight * ev.level_weight), 0)::numeric(5,2) as units,
      count(distinct ev.verified_learning_event_id) as distinct_recent_vles,
      case
        when coalesce(sum(ev.specificity_weight * ev.level_weight), 0) > 3.5
             and count(distinct ev.verified_learning_event_id) >= 2 then 'high'
        when coalesce(sum(ev.specificity_weight * ev.level_weight), 0) >= 1.5 then 'medium'
        else 'low'
      end as band
    from public.learning_evidence_events ev
    where ev.child_id = p_child_id
      and ev.learning_node_id = cms.learning_node_id
      and ev.effective_occurred_at >= v_as_of - interval '60 days'
      and ev.effective_occurred_at <= v_as_of
  ) conf
  where cms.child_id = p_child_id;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;

grant execute on function public.get_child_mastery(uuid, timestamptz) to authenticated;
grant execute on function public.get_child_mastery(uuid, timestamptz) to service_role;
