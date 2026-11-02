-- LearnWard Phase 4.2 — Celebration Wheel & Parent Controls
-- Migration: 20261102060000_phase4_2_celebration_wheel.sql

-- ---------------------------------------------------------------------------
-- 0. EXTEND COMMAND RECEIPTS OPERATION CHECK
-- ---------------------------------------------------------------------------
-- Extends the frozen operations to include Phase 4.2 Wheel operation: spin_wheel.
-- Preserves all previously frozen operations.

alter table public.command_receipts
  drop constraint if exists command_receipts_operation_check,
  add constraint command_receipts_operation_check
    check (operation in (
      'create_draft', 'submit', 'verify', 'reject', 'process_growth',
      'redeem_reward', 'fulfill_reward', 'cancel_reward',
      'spin_wheel'
    ));

-- ---------------------------------------------------------------------------
-- 1. UPDATE PAIRED-CHILD REWARD SELECT SEMANTICS
-- ---------------------------------------------------------------------------
-- Phase 4.1 restricted paired-child catalog access to store_enabled = true.
-- Phase 4.2 intentionally expands this to allow paired children to view eligible
-- active rewards that are store_enabled OR wheel_enabled.

drop policy if exists rewards_select on public.rewards;
create policy rewards_select on public.rewards
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or (
      is_active = true
      and (store_enabled = true or wheel_enabled = true)
      and (
        (target_child_id is null and exists (
          select 1 from public.child_device_grants cdg
          where cdg.auth_user_id = auth.uid()
            and cdg.family_id = rewards.family_id
            and cdg.status = 'active'
        ))
        or (target_child_id is not null and private.is_active_child_device(family_id, target_child_id))
      )
    )
  );

-- ---------------------------------------------------------------------------
-- 2. FAMILY WHEEL SETTINGS (public.family_wheel_settings)
-- ---------------------------------------------------------------------------

create table if not exists public.family_wheel_settings (
  family_id uuid primary key references public.families(id) on delete cascade,
  spin_cost_minor bigint not null default 1000 check (spin_cost_minor between 500 and 5000),
  daily_spin_cap integer not null default 3 check (daily_spin_cap between 1 and 5),
  is_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

-- Enforce family_id immutability and maintain updated_at
create or replace function private.prevent_family_wheel_settings_tenant_reassignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.family_id != old.family_id then
    raise exception 'family_wheel_settings family_id is immutable' using errcode = 'LW102';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_prevent_family_wheel_settings_tenant_reassignment on public.family_wheel_settings;
create trigger trg_prevent_family_wheel_settings_tenant_reassignment
  before update on public.family_wheel_settings
  for each row
  execute function private.prevent_family_wheel_settings_tenant_reassignment();

-- Automatic trigger for newly created families
create or replace function private.handle_new_family_wheel_settings()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.family_wheel_settings (family_id)
  values (new.id)
  on conflict (family_id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_family_created_wheel_settings on public.families;
create trigger trg_family_created_wheel_settings
  after insert on public.families
  for each row
  execute function private.handle_new_family_wheel_settings();

-- Backfill default settings for all existing families
insert into public.family_wheel_settings (family_id)
select id from public.families
on conflict (family_id) do nothing;

-- RLS on family_wheel_settings
alter table public.family_wheel_settings enable row level security;

create policy family_wheel_settings_select on public.family_wheel_settings
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or exists (
      select 1 from public.child_device_grants cdg
      where cdg.auth_user_id = auth.uid()
        and cdg.family_id = family_wheel_settings.family_id
        and cdg.status = 'active'
    )
  );

create policy family_wheel_settings_update on public.family_wheel_settings
  for update
  to authenticated
  using (
    private.is_active_family_adult(family_id)
  )
  with check (
    private.is_active_family_adult(family_id)
  );

grant select, update on public.family_wheel_settings to authenticated;
grant all on public.family_wheel_settings to service_role;
revoke insert, delete on public.family_wheel_settings from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. WHEEL SPINS (public.wheel_spins)
-- ---------------------------------------------------------------------------

create table if not exists public.wheel_spins (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null,
  reward_id uuid not null,
  redemption_id uuid not null unique,
  origin text not null default 'wheel' check (origin = 'wheel'),
  spin_cost_minor bigint not null check (spin_cost_minor between 500 and 5000),
  selection_snapshot jsonb not null,
  created_at timestamptz not null default now(),

  -- Composite relational invariant linking exactly to reward_redemptions
  constraint fk_wheel_spins_redemption_composite
    foreign key (redemption_id, family_id, child_id, reward_id, origin, spin_cost_minor)
    references public.reward_redemptions (id, family_id, child_id, reward_id, origin, rp_cost_minor)
    on delete restrict,

  -- Tenant composite FKs
  constraint fk_wheel_spins_family_child
    foreign key (child_id, family_id)
    references public.child_profiles(id, family_id)
    on delete cascade,

  constraint fk_wheel_spins_family_reward
    foreign key (reward_id, family_id)
    references public.rewards(id, family_id)
    on delete restrict
);

create index if not exists idx_wheel_spins_child_created on public.wheel_spins(child_id, created_at desc);
create index if not exists idx_wheel_spins_family_created on public.wheel_spins(family_id, created_at desc);

-- Wheel spins are strictly immutable
create or replace function private.enforce_wheel_spins_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'wheel_spins rows cannot be deleted' using errcode = 'LW102';
  end if;
  if tg_op = 'UPDATE' then
    raise exception 'wheel_spins rows are strictly immutable' using errcode = 'LW102';
  end if;
  return null;
end;
$$;

drop trigger if exists trg_enforce_wheel_spins_immutability on public.wheel_spins;
create trigger trg_enforce_wheel_spins_immutability
  before update or delete on public.wheel_spins
  for each row
  execute function private.enforce_wheel_spins_immutability();

-- RLS on wheel_spins
alter table public.wheel_spins enable row level security;

create policy wheel_spins_select on public.wheel_spins
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

grant select on public.wheel_spins to authenticated;
grant all on public.wheel_spins to service_role;
revoke insert, update, delete on public.wheel_spins from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. WHEEL SPIN RPC (public.spin_reward_wheel)
-- ---------------------------------------------------------------------------

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
  where id = p_child_id and status = 'active';

  if not found then
    raise exception 'Child profile not found or inactive' using errcode = 'P0002';
  end if;

  -- 3. Authorize caller against resolved family (BEFORE any timezone or config checks)
  v_is_adult := private.is_active_family_adult(v_family_id);
  v_is_child := private.is_active_child_device(v_family_id, p_child_id);

  if not (v_is_adult or v_is_child) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. ONLY AFTER authorization: inspect command_receipts for replay
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

  -- 5. ONLY FOR A NEW SPIN:
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

  -- 6. Server-authoritative pseudorandom selection using the CAPTURED IN-MEMORY POOL ONLY
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

  -- 7. Atomic transaction writes
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

revoke execute on function public.spin_reward_wheel(uuid, uuid) from public, anon;
grant execute on function public.spin_reward_wheel(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. WHEEL STATUS RPC (public.get_wheel_status)
-- ---------------------------------------------------------------------------

create or replace function public.get_wheel_status(
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
  v_family_tz text;
  v_test_tz timestamptz;
  v_local_date date;
  v_today_start timestamptz;
  v_today_end timestamptz;
  v_spin_cost_minor bigint;
  v_daily_spin_cap integer;
  v_is_enabled boolean;
  v_spins_today integer;
  v_spins_remaining integer;
  v_eligible_reward_count integer;
begin
  if p_child_id is null then
    raise exception 'Child ID is required' using errcode = '22000';
  end if;

  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- Load child and derive family
  select family_id into v_family_id
  from public.child_profiles
  where id = p_child_id and status = 'active';

  if not found then
    raise exception 'Child profile not found or inactive' using errcode = 'P0002';
  end if;

  -- Authorize caller: active family adult or exact paired child
  v_is_adult := private.is_active_family_adult(v_family_id);
  v_is_child := private.is_active_child_device(v_family_id, p_child_id);

  if not (v_is_adult or v_is_child) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- Load family timezone (FAIL CLOSED on missing/corrupt timezone)
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

  -- Local day boundaries
  v_local_date := (now() at time zone v_family_tz)::date;
  v_today_start := v_local_date::timestamp at time zone v_family_tz;
  v_today_end := (v_local_date + 1)::timestamp at time zone v_family_tz;

  -- Load wheel settings
  select spin_cost_minor, daily_spin_cap, is_enabled
  into v_spin_cost_minor, v_daily_spin_cap, v_is_enabled
  from public.family_wheel_settings
  where family_id = v_family_id;

  if not found then
    v_spin_cost_minor := 1000;
    v_daily_spin_cap := 3;
    v_is_enabled := true;
  end if;

  -- Count spins today in local day interval [today_start, today_end)
  select count(*) into v_spins_today
  from public.wheel_spins
  where child_id = p_child_id
    and created_at >= v_today_start
    and created_at < v_today_end;

  v_spins_remaining := greatest(0, v_daily_spin_cap - v_spins_today);

  -- Count eligible active rewards
  select count(*) into v_eligible_reward_count
  from public.rewards
  where family_id = v_family_id
    and is_active = true
    and wheel_enabled = true
    and wheel_tier is not null
    and (target_child_id is null or target_child_id = p_child_id);

  return jsonb_build_object(
    'family_id', v_family_id,
    'child_id', p_child_id,
    'spin_cost_minor', v_spin_cost_minor,
    'daily_spin_cap', v_daily_spin_cap,
    'is_enabled', v_is_enabled,
    'spins_today', v_spins_today,
    'spins_remaining', v_spins_remaining,
    'eligible_reward_count', v_eligible_reward_count,
    'local_day_start', v_today_start,
    'local_day_end', v_today_end
  );
end;
$$;

revoke execute on function public.get_wheel_status(uuid) from public, anon;
grant execute on function public.get_wheel_status(uuid) to authenticated;
