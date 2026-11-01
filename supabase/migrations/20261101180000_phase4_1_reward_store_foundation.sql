-- LearnWard Phase 4.1 — Reward Catalog + Store Redemption Foundation
-- Migration: 20261101180000_phase4_1_reward_store_foundation.sql

-- ---------------------------------------------------------------------------
-- 0. EXTEND COMMAND RECEIPTS OPERATION CHECK
-- ---------------------------------------------------------------------------
-- PR 4.1 extends the frozen operations to include Store operations:
-- redeem_reward, fulfill_reward, cancel_reward.
-- Note: 'spin_wheel' is strictly deferred to PR 4.2.

alter table public.command_receipts
  drop constraint if exists command_receipts_operation_check,
  add constraint command_receipts_operation_check
    check (operation in (
      'create_draft', 'submit', 'verify', 'reject', 'process_growth',
      'redeem_reward', 'fulfill_reward', 'cancel_reward'
    ));

-- ---------------------------------------------------------------------------
-- 1. REWARD CATALOG (public.rewards)
-- ---------------------------------------------------------------------------

create table if not exists public.rewards (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 2 and 100),
  description text null check (description is null or char_length(description) <= 500),
  category text not null check (category in ('privilege', 'experience', 'treat', 'item', 'choice', 'custom')),
  icon_key text not null default 'default_star',
  store_enabled boolean not null default true,
  store_cost_minor bigint null check (store_cost_minor is null or store_cost_minor > 0),
  wheel_enabled boolean not null default false,
  wheel_tier text null check (wheel_tier is null or wheel_tier in ('common', 'special', 'rare')),
  target_child_id uuid null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Composite unique key to support composite FK references
  constraint uq_rewards_id_family unique (id, family_id),

  -- Composite FK: target_child_id must belong to the exact same family_id
  constraint fk_rewards_target_child_family
    foreign key (target_child_id, family_id)
    references public.child_profiles(id, family_id)
    on delete restrict,

  constraint chk_reward_cost_if_store check (not store_enabled or store_cost_minor is not null),
  constraint chk_reward_tier_if_wheel check (not wheel_enabled or wheel_tier is not null)
);

create index if not exists idx_rewards_family_active on public.rewards(family_id, is_active);
create index if not exists idx_rewards_target_child on public.rewards(target_child_id);

-- Enforce immutable tenant identity on rewards and automatically maintain updated_at
create or replace function private.prevent_rewards_tenant_reassignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.family_id != old.family_id then
    raise exception 'Reward family_id is immutable' using errcode = 'LW102';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_prevent_rewards_tenant_reassignment on public.rewards;
create trigger trg_prevent_rewards_tenant_reassignment
  before update on public.rewards
  for each row
  execute function private.prevent_rewards_tenant_reassignment();

-- ---------------------------------------------------------------------------
-- 2. REWARD REDEMPTIONS (public.reward_redemptions)
-- ---------------------------------------------------------------------------

create table if not exists public.reward_redemptions (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null,
  reward_id uuid not null,
  origin text not null check (origin in ('store', 'wheel')),
  rp_cost_minor bigint not null check (rp_cost_minor >= 0),
  status text not null default 'pending_fulfillment' check (status in ('pending_fulfillment', 'fulfilled', 'cancelled')),
  reward_snapshot jsonb not null,
  cancellation_reason text null,
  fulfilled_at timestamptz null,
  fulfilled_by_user_id uuid null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Composite unique key for downstream references
  constraint uq_reward_redemptions_id_family_child unique (id, family_id, child_id),

  -- Composite unique key for Wheel linking (relational composite invariant for Phase 4.2)
  constraint uq_reward_redemptions_wheel_link
    unique (id, family_id, child_id, reward_id, origin, rp_cost_minor),

  -- Composite FK: child_id must belong to family_id
  constraint fk_redemptions_child_family
    foreign key (child_id, family_id)
    references public.child_profiles(id, family_id)
    on delete cascade,

  -- Composite FK: reward_id must belong to family_id
  constraint fk_redemptions_reward_family
    foreign key (reward_id, family_id)
    references public.rewards(id, family_id)
    on delete restrict
);

create index if not exists idx_redemptions_child_status on public.reward_redemptions(child_id, status, created_at desc);
create index if not exists idx_redemptions_family_status on public.reward_redemptions(family_id, status);

-- Enforce core redemption field immutability and terminal state protection
create or replace function private.enforce_redemption_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'reward_redemptions rows cannot be deleted' using errcode = 'LW102';
  end if;

  if tg_op = 'UPDATE' then
    -- Immutability of core fields
    if old.id != new.id
       or old.family_id != new.family_id
       or old.child_id != new.child_id
       or old.reward_id != new.reward_id
       or old.origin != new.origin
       or old.rp_cost_minor != new.rp_cost_minor
       or old.reward_snapshot != new.reward_snapshot
       or old.created_at != new.created_at then
      raise exception 'Core fields of reward_redemptions are immutable' using errcode = 'LW102';
    end if;

    -- Terminal state protection: once terminal, no transitions allowed
    if old.status in ('fulfilled', 'cancelled') then
      raise exception 'Reward redemption is already in a terminal state: %', old.status using errcode = 'LW204';
    end if;

    -- Valid transitions from pending_fulfillment
    if new.status not in ('fulfilled', 'cancelled') then
      raise exception 'Invalid status transition: % to %', old.status, new.status using errcode = 'LW204';
    end if;

    new.updated_at := now();
    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_redemption_immutability on public.reward_redemptions;
create trigger trg_enforce_redemption_immutability
  before update or delete on public.reward_redemptions
  for each row
  execute function private.enforce_redemption_immutability();

-- ---------------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY & PERMISSIONS
-- ---------------------------------------------------------------------------

alter table public.rewards enable row level security;
alter table public.reward_redemptions enable row level security;

-- rewards policies
create policy rewards_select on public.rewards
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or (
      is_active = true
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

create policy rewards_insert on public.rewards
  for insert
  to authenticated
  with check (
    private.is_active_family_adult(family_id)
  );

create policy rewards_update on public.rewards
  for update
  to authenticated
  using (
    private.is_active_family_adult(family_id)
  )
  with check (
    private.is_active_family_adult(family_id)
  );

create policy rewards_delete on public.rewards
  for delete
  to authenticated
  using (
    private.is_active_family_adult(family_id)
  );

grant select, insert, update, delete on public.rewards to authenticated;
grant all on public.rewards to service_role;

-- reward_redemptions policies
-- Clients may read redemptions according to family/child authorization,
-- but all direct mutations (INSERT, UPDATE, DELETE) are strictly revoked.
create policy reward_redemptions_select on public.reward_redemptions
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or private.is_active_child_device(family_id, child_id)
  );

grant select on public.reward_redemptions to authenticated;
revoke insert, update, delete on public.reward_redemptions from anon, authenticated;
grant all on public.reward_redemptions to service_role;

-- ---------------------------------------------------------------------------
-- 4. TRUSTED RPC: redeem_store_reward
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

  -- 4. ONLY AFTER authorization: inspect command_receipts for replay
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

  -- 5. Validate preconditions + acquire row locks
  -- Lock target reward row FOR UPDATE
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

  -- Lock child_balances row FOR UPDATE
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

  -- 6. State Mutation: atomic debit and redemption creation
  v_redemption_id := gen_random_uuid();
  v_snapshot := jsonb_build_object(
    'reward_id', v_reward.id,
    'title', v_reward.title,
    'description', v_reward.description,
    'category', v_reward.category,
    'icon_key', v_reward.icon_key,
    'store_cost_minor', v_cost_minor,
    'redeemed_at', now()
  );

  insert into public.reward_redemptions (
    id,
    family_id,
    child_id,
    reward_id,
    origin,
    rp_cost_minor,
    status,
    reward_snapshot
  ) values (
    v_redemption_id,
    v_family_id,
    p_child_id,
    v_reward.id,
    'store',
    v_cost_minor,
    'pending_fulfillment',
    v_snapshot
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

  -- 7. Record command receipt
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

  -- 8. Return created redemption
  return v_redemption;
end;
$$;

revoke all on function public.redeem_store_reward(uuid, uuid, uuid) from public, anon;
grant execute on function public.redeem_store_reward(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. TRUSTED RPC: fulfill_reward_redemption
-- ---------------------------------------------------------------------------

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

  -- 2. Load authoritative target resource & derive family under row lock
  select * into v_redemption
  from public.reward_redemptions
  where id = p_redemption_id
  for update;

  if not found then
    raise exception 'Reward redemption not found' using errcode = 'P0002';
  end if;

  v_family_id := v_redemption.family_id;

  -- 3. Authorize caller (active family adult only)
  if not private.is_active_family_adult(v_family_id) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. ONLY AFTER authorization: inspect command_receipts for replay
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

  -- 5. Validate preconditions
  if v_redemption.status != 'pending_fulfillment' then
    raise exception 'Reward redemption is already in a terminal state: %', v_redemption.status using errcode = 'LW204';
  end if;

  -- 6. State Mutation: transition to fulfilled
  update public.reward_redemptions
  set status = 'fulfilled',
      fulfilled_at = now(),
      fulfilled_by_user_id = v_user_id,
      updated_at = now()
  where id = p_redemption_id
  returning * into v_redemption;

  -- 7. Record command receipt
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

  -- 8. Return fulfilled redemption
  return v_redemption;
end;
$$;

revoke all on function public.fulfill_reward_redemption(uuid, uuid) from public, anon;
grant execute on function public.fulfill_reward_redemption(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. TRUSTED RPC: cancel_reward_redemption
-- ---------------------------------------------------------------------------

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

  -- 2. Load authoritative target resource & derive family under row lock
  select * into v_redemption
  from public.reward_redemptions
  where id = p_redemption_id
  for update;

  if not found then
    raise exception 'Reward redemption not found' using errcode = 'P0002';
  end if;

  v_family_id := v_redemption.family_id;

  -- 3. Authorize caller (active family adult only)
  if not private.is_active_family_adult(v_family_id) then
    raise exception 'Permission denied' using errcode = '42501';
  end if;

  -- 4. ONLY AFTER authorization: inspect command_receipts for replay
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

  -- 5. Validate preconditions
  if v_redemption.status != 'pending_fulfillment' then
    raise exception 'Reward redemption is already in a terminal state: %', v_redemption.status using errcode = 'LW204';
  end if;

  -- Lock child_balances FOR UPDATE
  select rp_balance_minor into v_current_balance
  from public.child_balances
  where child_id = v_redemption.child_id
  for update;

  if not found then
    raise exception 'Child balance record not found' using errcode = 'P0002';
  end if;

  -- 6. State Mutation: cancel status and append compensating refund to rp_ledger
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

  -- 7. Record command receipt
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

  -- 8. Return cancelled redemption
  return v_redemption;
end;
$$;

revoke all on function public.cancel_reward_redemption(uuid, uuid, text) from public, anon;
grant execute on function public.cancel_reward_redemption(uuid, uuid, text) to authenticated;
