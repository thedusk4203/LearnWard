-- Phase 6.1: Database Lifecycle Protection, Column Privileges & RLS Boundary Overhaul
--
-- Implements:
-- 1. Helper function private.is_child_active_in_family(uuid, uuid)
-- 2. Column-level UPDATE privilege restrictions on public.child_profiles
-- 3. Lifecycle invariant trigger trg_guard_child_profile_lifecycle
-- 4. RLS policy overhauls for child_profiles and child_device_grants
-- 5. Family-wide table RLS hardening (family_wheel_settings, rewards)
-- 6. Child-scoped domain tables RLS active-child barrier (assessments, evidence, reviews, VLEs,
--    receipts, growth, ledgers, balances, redemptions, wheel spins, mastery, processing)
-- 7. Storage evidence access helper hardening (private.validate_storage_evidence_access)
--
-- Architectural Invariant / Deployment Gate:
-- Direct Data API mutation of status, archived_at, and birth_year is revoked at the column level.
-- archive_child_profile() is NOT deployed in this slice; therefore NO production child profile can
-- transition to 'archived' until the SECURITY DEFINER mutation RPC barriers are deployed in Slice 2.

-- ---------------------------------------------------------------------------
-- 1. HELPER FUNCTION: private.is_child_active_in_family
-- ---------------------------------------------------------------------------

create or replace function private.is_child_active_in_family(p_child_id uuid, p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.child_profiles
    where id = p_child_id
      and family_id = p_family_id
      and status = 'active'
  );
$$;

revoke all on function private.is_child_active_in_family(uuid, uuid) from public;
grant execute on function private.is_child_active_in_family(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. COLUMN PRIVILEGE HARDENING & IMMUTABLE LIFECYCLE TRIGGER
-- ---------------------------------------------------------------------------

-- Revoke table-wide update on child_profiles; grant only permitted mutable fields
revoke update on public.child_profiles from authenticated;
grant update (display_name, avatar_key, school_grade, family_id) on public.child_profiles to authenticated;

-- Lifecycle guard trigger enforcing irrevocable archival, active->archived transition,
-- atomic Tier 3 pseudonymization, and core field immutability
create or replace function private.guard_child_profile_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 1. Irrevocable immutability for already-archived profiles
  -- Rejects all subsequent in-place edits and prevents any reactivation (archived -> active)
  if old.status = 'archived' then
    raise exception 'Archived child profile is immutable' using errcode = 'LW011';
  end if;

  -- 2. State transition & atomic Tier 3 pseudonymization enforcement
  if new.status is distinct from old.status or new.archived_at is distinct from old.archived_at then
    -- Transition must be strictly active -> archived
    if old.status != 'active' or new.status != 'archived' or new.archived_at is null then
      raise exception 'Invalid child profile lifecycle transition' using errcode = 'LW012';
    end if;

    -- Atomic Tier 3 pseudonymization requirement:
    -- Identifying attributes must be scrubbed in this exact same transition update
    if new.display_name != '[Archived Learner]'
       or new.avatar_key is not null
       or new.school_grade is not null
       or new.birth_year is not null then
      raise exception 'Archival transition requires atomic pseudonymization of identifying attributes'
        using errcode = 'LW013';
    end if;
  end if;

  -- 3. Core identity immutability (id, family_id, created_at)
  if new.id != old.id or new.family_id != old.family_id or new.created_at != old.created_at then
    raise exception 'family_id on child_profiles is immutable' using errcode = 'LW005';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_guard_child_profile_lifecycle on public.child_profiles;
create trigger trg_guard_child_profile_lifecycle
  before update on public.child_profiles
  for each row
  execute function private.guard_child_profile_lifecycle();

-- ---------------------------------------------------------------------------
-- 3. CHILD_PROFILES & CHILD_DEVICE_GRANTS RLS OVERHAUL
-- ---------------------------------------------------------------------------

drop policy if exists child_profiles_insert on public.child_profiles;
create policy child_profiles_insert on public.child_profiles
  for insert to authenticated
  with check (
    private.is_active_family_adult(family_id)
    and status = 'active'
    and archived_at is null
  );

drop policy if exists child_profiles_update on public.child_profiles;
create policy child_profiles_update on public.child_profiles
  for update to authenticated
  using (
    private.is_active_family_adult(family_id)
    and status = 'active'
  )
  with check (
    private.is_active_family_adult(family_id)
    and status = 'active'
  );

drop policy if exists child_profiles_select on public.child_profiles;
create policy child_profiles_select on public.child_profiles
  for select to authenticated
  using (
    status = 'active'
    and (
      private.is_active_family_adult(family_id)
      or id = (
        select cdg.child_id
        from public.child_device_grants cdg
        where cdg.auth_user_id = auth.uid()
          and cdg.status = 'active'
      )
    )
  );

drop policy if exists child_device_grants_select on public.child_device_grants;
create policy child_device_grants_select on public.child_device_grants
  for select to authenticated
  using (
    (
      private.is_active_family_adult(family_id)
      and private.is_child_active_in_family(child_id, family_id)
    )
    or auth_user_id = auth.uid()
  );

-- ---------------------------------------------------------------------------
-- 4. FAMILY-WIDE TABLES RLS HARDENING (WHEEL SETTINGS & REWARDS)
-- ---------------------------------------------------------------------------

drop policy if exists family_wheel_settings_select on public.family_wheel_settings;
create policy family_wheel_settings_select on public.family_wheel_settings
  for select to authenticated
  using (
    private.is_active_family_adult(family_id)
    or exists (
      select 1 from public.child_device_grants cdg
      join public.child_profiles cp on cp.id = cdg.child_id and cp.family_id = cdg.family_id
      where cdg.family_id = family_wheel_settings.family_id
        and cdg.auth_user_id = auth.uid()
        and cdg.status = 'active'
        and cp.status = 'active'
    )
  );

drop policy if exists rewards_select on public.rewards;
create policy rewards_select on public.rewards
  for select to authenticated
  using (
    (
      private.is_active_family_adult(family_id)
      and (target_child_id is null or private.is_child_active_in_family(target_child_id, family_id))
    )
    or (
      is_active = true
      and (store_enabled = true or wheel_enabled = true)
      and (
        (
          target_child_id is null and exists (
            select 1 from public.child_device_grants cdg
            join public.child_profiles cp on cp.id = cdg.child_id and cp.family_id = cdg.family_id
            where cdg.auth_user_id = auth.uid()
              and cdg.family_id = rewards.family_id
              and cdg.status = 'active'
              and cp.status = 'active'
          )
        )
        or (
          target_child_id is not null
          and private.is_child_active_in_family(target_child_id, family_id)
          and private.is_active_child_device(family_id, target_child_id)
        )
      )
    )
  );

-- ---------------------------------------------------------------------------
-- 5. CHILD-SCOPED DOMAIN TABLES RLS HARDENING
-- ---------------------------------------------------------------------------

-- assessments
drop policy if exists assessments_select on public.assessments;
create policy assessments_select on public.assessments
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- assessment_evidence
drop policy if exists assessment_evidence_select on public.assessment_evidence;
create policy assessment_evidence_select on public.assessment_evidence
  for select to authenticated
  using (
    exists (
      select 1 from public.assessments a
      where a.id = assessment_evidence.assessment_id
        and a.family_id = assessment_evidence.family_id
        and private.is_child_active_in_family(a.child_id, a.family_id)
        and (
          private.is_active_family_adult(a.family_id)
          or private.is_active_child_device(a.family_id, a.child_id)
        )
    )
  );

-- assessment_review_events
drop policy if exists assessment_review_events_select on public.assessment_review_events;
create policy assessment_review_events_select on public.assessment_review_events
  for select to authenticated
  using (
    private.is_active_family_adult(family_id)
    and exists (
      select 1 from public.assessments a
      where a.id = assessment_review_events.assessment_id
        and a.family_id = assessment_review_events.family_id
        and private.is_child_active_in_family(a.child_id, a.family_id)
    )
  );

-- verified_learning_events
drop policy if exists verified_learning_events_select on public.verified_learning_events;
create policy verified_learning_events_select on public.verified_learning_events
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- command_receipts
drop policy if exists command_receipts_select on public.command_receipts;
create policy command_receipts_select on public.command_receipts
  for select to authenticated
  using (
    private.is_active_family_adult(family_id)
    and (
      case
        when operation in ('create_draft', 'submit', 'verify', 'reject', 'submit_assessment', 'verify_assessment', 'reject_assessment') then
          exists (
            select 1 from public.assessments a
            where a.id = command_receipts.resource_id
              and a.family_id = command_receipts.family_id
              and private.is_child_active_in_family(a.child_id, a.family_id)
          )
        when operation in ('redeem_reward', 'fulfill_reward', 'cancel_reward') then
          exists (
            select 1 from public.reward_redemptions rr
            where rr.id = command_receipts.resource_id
              and rr.family_id = command_receipts.family_id
              and private.is_child_active_in_family(rr.child_id, rr.family_id)
          )
        when operation = 'spin_wheel' then
          exists (
            select 1 from public.wheel_spins ws
            where ws.id = command_receipts.resource_id
              and ws.family_id = command_receipts.family_id
              and private.is_child_active_in_family(ws.child_id, ws.family_id)
          )
        when operation in ('process_growth', 'process_learning') then
          exists (
            select 1 from public.verified_learning_events vle
            where vle.id = command_receipts.resource_id
              and vle.family_id = command_receipts.family_id
              and private.is_child_active_in_family(vle.child_id, vle.family_id)
          )
        else false
      end
    )
  );

-- growth_events
drop policy if exists growth_events_select on public.growth_events;
create policy growth_events_select on public.growth_events
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- xp_ledger
drop policy if exists xp_ledger_select on public.xp_ledger;
create policy xp_ledger_select on public.xp_ledger
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- rp_ledger
drop policy if exists rp_ledger_select on public.rp_ledger;
create policy rp_ledger_select on public.rp_ledger
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- child_balances
drop policy if exists child_balances_select on public.child_balances;
create policy child_balances_select on public.child_balances
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- reward_redemptions
drop policy if exists reward_redemptions_select on public.reward_redemptions;
create policy reward_redemptions_select on public.reward_redemptions
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- wheel_spins
drop policy if exists wheel_spins_select on public.wheel_spins;
create policy wheel_spins_select on public.wheel_spins
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- assessment_learning_mappings
drop policy if exists assessment_learning_mappings_select on public.assessment_learning_mappings;
create policy assessment_learning_mappings_select on public.assessment_learning_mappings
  for select to authenticated
  using (
    exists (
      select 1 from public.assessments a
      where a.id = assessment_learning_mappings.assessment_id
        and a.family_id = assessment_learning_mappings.family_id
        and private.is_child_active_in_family(a.child_id, a.family_id)
        and (
          private.is_active_family_adult(a.family_id)
          or private.is_active_child_device(a.family_id, a.child_id)
        )
    )
  );

-- learning_evidence_events
drop policy if exists learning_evidence_events_select on public.learning_evidence_events;
create policy learning_evidence_events_select on public.learning_evidence_events
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- mastery_state_revisions
drop policy if exists mastery_state_revisions_select on public.mastery_state_revisions;
create policy mastery_state_revisions_select on public.mastery_state_revisions
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- child_mastery_states
drop policy if exists child_mastery_states_select on public.child_mastery_states;
create policy child_mastery_states_select on public.child_mastery_states
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- learning_processing_events
drop policy if exists learning_processing_events_select on public.learning_processing_events;
create policy learning_processing_events_select on public.learning_processing_events
  for select to authenticated
  using (
    private.is_child_active_in_family(child_id, family_id)
    and (
      private.is_active_family_adult(family_id)
      or private.is_active_child_device(family_id, child_id)
    )
  );

-- ---------------------------------------------------------------------------
-- 6. STORAGE EVIDENCE ACCESS HELPER HARDENING
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

  -- Verify child is active in family (Phase 6 hardening)
  if not private.is_child_active_in_family(v_child_id, v_family_id) then
    return false;
  end if;

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

revoke all on function private.validate_storage_evidence_access(text, boolean) from public;
grant execute on function private.validate_storage_evidence_access(text, boolean) to authenticated;
grant execute on function private.validate_storage_evidence_access(text, boolean) to anon;
grant execute on function private.validate_storage_evidence_access(text, boolean) to service_role;
