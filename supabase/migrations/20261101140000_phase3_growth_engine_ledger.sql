-- LearnWard Phase 3 — Growth Engine + XP/RP Ledger Foundation
-- Migration: 20261101140000_phase3_growth_engine_ledger.sql

-- ---------------------------------------------------------------------------
-- 0. EXTEND COMMAND RECEIPTS OPERATION CHECK
-- ---------------------------------------------------------------------------

alter table public.command_receipts
  drop constraint if exists command_receipts_operation_check,
  add constraint command_receipts_operation_check
    check (operation in ('create_draft', 'submit', 'verify', 'reject', 'process_growth'));

-- ---------------------------------------------------------------------------
-- 1. GROWTH EVENTS AUDIT TABLE
-- ---------------------------------------------------------------------------

create table if not exists public.growth_events (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null references public.child_profiles(id) on delete cascade,
  verified_learning_event_id uuid not null unique references public.verified_learning_events(id) on delete restrict,
  assessment_id uuid not null unique references public.assessments(id) on delete restrict,
  engine_version text not null,
  normalized_score numeric(4, 2) not null,
  baseline_score numeric(4, 2) null,
  baseline_sample_count integer not null default 0 check (baseline_sample_count >= 0),
  growth_delta numeric(4, 2) null,
  historical_best numeric(4, 2) null,
  score_rp_minor bigint not null check (score_rp_minor >= 0),
  growth_rp_minor bigint not null default 0 check (growth_rp_minor >= 0),
  high_performer_rp_minor bigint not null default 0 check (high_performer_rp_minor >= 0),
  goal_rp_minor bigint not null default 0 check (goal_rp_minor >= 0),
  personal_best_rp_minor bigint not null default 0 check (personal_best_rp_minor >= 0),
  difficulty_rp_minor bigint not null default 0 check (difficulty_rp_minor >= 0),
  recovery_rp_minor bigint not null default 0 check (recovery_rp_minor >= 0),
  below_level_adjustment boolean not null default false,
  total_rp_minor bigint not null check (total_rp_minor >= 0),
  xp_awarded integer not null check (xp_awarded >= 0),
  inputs_snapshot jsonb not null,
  created_at timestamptz not null default now(),

  constraint fk_growth_events_child_family
    foreign key (child_id, family_id)
    references public.child_profiles(id, family_id)
    on delete cascade
);

create index if not exists idx_growth_events_child_created
  on public.growth_events (child_id, created_at desc);

create index if not exists idx_growth_events_family
  on public.growth_events (family_id);

-- Invariant: growth_events is strictly immutable and append-only.
create or replace function private.prevent_growth_event_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'growth_events is strictly immutable' using errcode = 'LW102';
end;
$$;

create trigger trg_prevent_growth_event_mutation
before update or delete on public.growth_events
for each row
execute function private.prevent_growth_event_mutation();

-- ---------------------------------------------------------------------------
-- 2. XP AUTHORITATIVE LEDGER
-- ---------------------------------------------------------------------------

create table if not exists public.xp_ledger (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null references public.child_profiles(id) on delete cascade,
  amount integer not null,
  reason_code text not null,
  source_type text not null,
  source_id uuid null,
  engine_version text null,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint chk_xp_ledger_amount check (amount >= 0 or reason_code = 'correction'),
  constraint fk_xp_ledger_child_family
    foreign key (child_id, family_id)
    references public.child_profiles(id, family_id)
    on delete cascade
);

create index if not exists idx_xp_ledger_child_created
  on public.xp_ledger (child_id, created_at asc);

-- Invariant: xp_ledger is strictly immutable and append-only.
create or replace function private.prevent_xp_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'xp_ledger is strictly immutable' using errcode = 'LW102';
end;
$$;

create trigger trg_prevent_xp_ledger_mutation
before update or delete on public.xp_ledger
for each row
execute function private.prevent_xp_ledger_mutation();

-- ---------------------------------------------------------------------------
-- 3. RP AUTHORITATIVE LEDGER
-- ---------------------------------------------------------------------------

create table if not exists public.rp_ledger (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null references public.child_profiles(id) on delete cascade,
  amount_minor bigint not null,
  reason_code text not null,
  source_type text not null,
  source_id uuid null,
  engine_version text null,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint fk_rp_ledger_child_family
    foreign key (child_id, family_id)
    references public.child_profiles(id, family_id)
    on delete cascade
);

create index if not exists idx_rp_ledger_child_created
  on public.rp_ledger (child_id, created_at asc);

-- Invariant: rp_ledger is strictly immutable and append-only.
create or replace function private.prevent_rp_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'rp_ledger is strictly immutable' using errcode = 'LW102';
end;
$$;

create trigger trg_prevent_rp_ledger_mutation
before update or delete on public.rp_ledger
for each row
execute function private.prevent_rp_ledger_mutation();

-- ---------------------------------------------------------------------------
-- 4. CHILD BALANCES PROJECTION
-- ---------------------------------------------------------------------------

create table if not exists public.child_balances (
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid primary key references public.child_profiles(id) on delete cascade,
  xp_total bigint not null default 0 check (xp_total >= 0),
  rp_balance_minor bigint not null default 0 check (rp_balance_minor >= 0),
  updated_at timestamptz not null default now(),

  constraint fk_child_balances_family_child
    foreign key (child_id, family_id)
    references public.child_profiles(id, family_id)
    on delete cascade
);

create index if not exists idx_child_balances_family
  on public.child_balances (family_id);

-- ---------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY (RLS) & GRANTS
-- ---------------------------------------------------------------------------

alter table public.growth_events enable row level security;
alter table public.xp_ledger enable row level security;
alter table public.rp_ledger enable row level security;
alter table public.child_balances enable row level security;

-- Revoke all modifying permissions from public roles
revoke all on public.growth_events from anon, authenticated;
revoke all on public.xp_ledger from anon, authenticated;
revoke all on public.rp_ledger from anon, authenticated;
revoke all on public.child_balances from anon, authenticated;

-- Grant select only to authenticated users
grant select on public.growth_events to authenticated;
grant select on public.xp_ledger to authenticated;
grant select on public.rp_ledger to authenticated;
grant select on public.child_balances to authenticated;

-- RLS Policies for growth_events
create policy "growth_events_select"
  on public.growth_events
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

-- RLS Policies for xp_ledger
create policy "xp_ledger_select"
  on public.xp_ledger
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

-- RLS Policies for rp_ledger
create policy "rp_ledger_select"
  on public.rp_ledger
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

-- RLS Policies for child_balances
create policy "child_balances_select"
  on public.child_balances
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

-- ---------------------------------------------------------------------------
-- 6. TRUSTED SECURITY DEFINER PROCESSING COMMAND: process_verified_learning_event
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

  -- 2. Concurrency row lock & Target verification
  select * into v_event
  from public.verified_learning_events
  where id = p_verified_event_id
  for update;

  if not found then
    raise exception 'Verified learning event not found' using errcode = 'LW105';
  end if;

  -- 3. Authorization check (only active family adults can process)
  if not private.is_active_family_adult(v_event.family_id) then
    raise exception 'Permission denied: must be active family adult' using errcode = '42501';
  end if;

  -- 4. Idempotency check 1: Has this verified event already produced a growth event?
  select * into v_existing_growth
  from public.growth_events
  where verified_learning_event_id = p_verified_event_id;

  if found then
    return v_existing_growth;
  end if;

  -- 5. Idempotency check 2: Command replay check if command ID provided
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

  -- 6. Retrieve strictly prior comparable records:
  -- - Same child
  -- - Same canonical subject_key
  -- - Excludes current event
  -- - Strictly occurred before current event (or verified earlier)
  -- - Excludes below_level history if current is not below_level
  for v_comparables in
    select id, normalized_score, difficulty, assessment_type, occurred_at, verified_at
    from public.verified_learning_events
    where child_id = v_event.child_id
      and subject_key = v_subject_key
      and id != v_event.id
      and (
        occurred_at < v_event.occurred_at
        or (occurred_at = v_event.occurred_at and verified_at < v_event.verified_at)
      )
      and (
        case when v_difficulty != 'below_level' then difficulty != 'below_level' else true end
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
        'occurred_at', v_comparables.occurred_at
      );
    end if;
  end loop;

  -- 7. Compute rolling baseline (requires 3 samples)
  if v_count >= 3 then
    v_baseline := round(v_sum / 3.0, 2);
    v_baseline_count := 3;
    v_growth_delta := round(v_normalized_score - v_baseline, 2);
  else
    v_baseline := null;
    v_baseline_count := v_count;
    v_growth_delta := null;
  end if;

  -- 8. Compute economic components in integer minor units (100 minor = 1.00 RP)
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

  -- 9. Compute Study XP: XP = 10 + 2 * RP_awarded
  v_xp_awarded := 10 + round(2.0 * v_total_rp_minor / 100.0)::int;

  -- 10. Audit snapshot
  v_inputs_snapshot := jsonb_build_object(
    'engine_version', v_engine_version,
    'verified_event_id', v_event.id,
    'assessment_id', v_event.assessment_id,
    'child_id', v_event.child_id,
    'subject_key', v_subject_key,
    'normalized_score', v_normalized_score,
    'difficulty', v_difficulty,
    'baseline_score', v_baseline,
    'baseline_count', v_baseline_count,
    'growth_delta', v_growth_delta,
    'historical_best', v_historical_best,
    'samples_used', v_samples_json
  );

  -- 11. Insert immutable growth_event
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

  -- 12. Append to authoritative XP ledger
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

  -- 13. Append to authoritative RP ledger
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

  -- 14. Update child_balances projection
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

  -- 15. Record command receipt if command_id provided
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
    );
  end if;

  return v_new_growth;
end;
$$;

-- Grant execution to authenticated users
grant execute on function public.process_verified_learning_event(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. RECONCILIATION AUDIT FUNCTION: reconcile_child_balance
-- ---------------------------------------------------------------------------

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
  v_fam_id uuid;
  v_proj_xp bigint := 0;
  v_proj_rp bigint := 0;
  v_ledg_xp bigint := 0;
  v_ledg_rp bigint := 0;
begin
  select cp.family_id into v_fam_id from public.child_profiles cp where cp.id = p_child_id;
  if not found then
    raise exception 'Child profile not found' using errcode = 'LW105';
  end if;

  -- Read projection
  select coalesce(cb.xp_total, 0), coalesce(cb.rp_balance_minor, 0)
  into v_proj_xp, v_proj_rp
  from public.child_balances cb
  where cb.child_id = p_child_id;

  -- Read ledger sums
  select coalesce(sum(xl.amount), 0) into v_ledg_xp
  from public.xp_ledger xl
  where xl.child_id = p_child_id;

  select coalesce(sum(rl.amount_minor), 0) into v_ledg_rp
  from public.rp_ledger rl
  where rl.child_id = p_child_id;

  return query select
    p_child_id,
    v_fam_id,
    (v_proj_xp = v_ledg_xp and v_proj_rp = v_ledg_rp) as is_reconciled,
    v_proj_xp,
    v_ledg_xp,
    v_proj_rp,
    v_ledg_rp;
end;
$$;

grant execute on function public.reconcile_child_balance(uuid) to authenticated;
