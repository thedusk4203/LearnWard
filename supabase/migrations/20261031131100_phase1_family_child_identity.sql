-- Phase 1: Family and Child Identity Foundation
--
-- Implements family tenancy boundary, adult memberships, child profiles,
-- and child device pairing foundations with Row Level Security (RLS).

-- ---------------------------------------------------------------------------
-- 0. DEFAULT PRIVILEGES (FAIL-CLOSED)
-- ---------------------------------------------------------------------------

-- Revoke default automatic grants on future objects created by postgres role.
-- LearnWard strictly enforces explicit grants per role.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  revoke all on functions from anon, authenticated, service_role;

alter default privileges for role postgres
  revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------------

create table public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 100),
  timezone text not null check (char_length(trim(timezone)) > 0),
  locale text not null check (char_length(trim(locale)) > 0),
  created_by_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  archived_at timestamptz null
);

create index idx_families_created_by on public.families(created_by_user_id);

create table public.family_memberships (
  family_id uuid not null references public.families(id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'parent')),
  status text not null check (status in ('active', 'invited', 'revoked')),
  joined_at timestamptz not null default now(),
  revoked_at timestamptz null,
  primary key (family_id, auth_user_id)
);

create index idx_family_memberships_auth_user on public.family_memberships(auth_user_id);
create index idx_family_memberships_family_id on public.family_memberships(family_id);

create table public.child_profiles (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 50),
  school_grade smallint null check (school_grade between 1 and 12),
  birth_year smallint null check (birth_year between 1990 and 2035),
  avatar_key text null,
  status text not null default 'active' check (status in ('active', 'archived')),
  created_at timestamptz not null default now(),
  archived_at timestamptz null,
  constraint uq_child_profiles_id_family unique (id, family_id)
);

create index idx_child_profiles_family_id on public.child_profiles(family_id);

create table public.child_device_grants (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null,
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  device_label text null,
  status text not null default 'active' check (status in ('active', 'revoked')),
  paired_by_user_id uuid not null references auth.users(id) on delete restrict,
  paired_at timestamptz not null default now(),
  last_seen_at timestamptz null,
  revoked_at timestamptz null,
  foreign key (child_id, family_id) references public.child_profiles(id, family_id) on delete cascade
);

create index idx_child_device_grants_auth_user on public.child_device_grants(auth_user_id);
create index idx_child_device_grants_child on public.child_device_grants(child_id);
create index idx_child_device_grants_family on public.child_device_grants(family_id);

create table private.child_pairing_requests (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  child_id uuid not null,
  token_hash text not null,
  expires_at timestamptz not null,
  created_by_user_id uuid not null references auth.users(id) on delete cascade,
  consumed_at timestamptz null,
  foreign key (child_id, family_id) references public.child_profiles(id, family_id) on delete cascade
);

create index idx_pairing_requests_family on private.child_pairing_requests(family_id);

-- ---------------------------------------------------------------------------
-- 2. SECURITY HELPER FUNCTIONS (private schema)
-- ---------------------------------------------------------------------------

create or replace function private.is_active_family_adult(p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.family_memberships
    where family_id = p_family_id
      and auth_user_id = auth.uid()
      and status = 'active'
      and role in ('owner', 'parent')
  );
$$;

create or replace function private.is_family_owner(p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.family_memberships
    where family_id = p_family_id
      and auth_user_id = auth.uid()
      and status = 'active'
      and role = 'owner'
  );
$$;

create or replace function private.is_active_child_device(p_family_id uuid, p_child_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.child_device_grants
    where family_id = p_family_id
      and child_id = p_child_id
      and auth_user_id = auth.uid()
      and status = 'active'
  );
$$;

revoke all on function private.is_active_family_adult(uuid) from public;
revoke all on function private.is_family_owner(uuid) from public;
revoke all on function private.is_active_child_device(uuid, uuid) from public;

grant execute on function private.is_active_family_adult(uuid) to authenticated;
grant execute on function private.is_family_owner(uuid) to authenticated;
grant execute on function private.is_active_child_device(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. INVARIANT ENFORCEMENT TRIGGERS
-- ---------------------------------------------------------------------------

-- Invariant: Family must never have zero active owners.
-- Last active owner cannot be revoked, demoted, or deleted while family exists.
create or replace function private.ensure_last_active_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_remaining int;
begin
  if (TG_OP = 'DELETE' and OLD.role = 'owner' and OLD.status = 'active') or
     (TG_OP = 'UPDATE' and OLD.role = 'owner' and OLD.status = 'active' and (NEW.role != 'owner' or NEW.status != 'active')) then

    -- If parent family still exists (i.e. not in the middle of family deletion):
    if exists (select 1 from public.families where id = OLD.family_id) then
      -- Acquire an exclusive row-level lock on the parent family row to serialize
      -- concurrent owner demotions/revocations within the same family tenant.
      perform 1
      from public.families
      where id = OLD.family_id
      for update;

      select count(*) into v_remaining
      from public.family_memberships
      where family_id = OLD.family_id
        and role = 'owner'
        and status = 'active'
        and auth_user_id != OLD.auth_user_id;

      if v_remaining = 0 then
        raise exception 'Family must have at least one active owner' using errcode = 'LW006';
      end if;
    end if;
  end if;

  return coalesce(NEW, OLD);
end;
$$;

create trigger trg_ensure_last_active_owner
before update or delete on public.family_memberships
for each row
execute function private.ensure_last_active_owner();

-- Invariant: child.family_id is immutable across tenants once created.
create or replace function private.prevent_child_family_id_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if NEW.family_id != OLD.family_id then
    raise exception 'family_id on child_profiles is immutable' using errcode = 'LW005';
  end if;
  return NEW;
end;
$$;

create trigger trg_prevent_child_family_id_change
before update on public.child_profiles
for each row
execute function private.prevent_child_family_id_change();

-- ---------------------------------------------------------------------------
-- 4. ATOMIC FAMILY CREATION FUNCTION
-- ---------------------------------------------------------------------------

create or replace function public.create_family(
  p_name text,
  p_timezone text,
  p_locale text
)
returns public.families
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_family public.families;
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'Authentication required to create a family' using errcode = 'LW001';
  end if;

  -- Guard against child device identities creating families
  if exists (
    select 1 from public.child_device_grants
    where auth_user_id = v_user_id
  ) then
    raise exception 'Child device identities cannot create families' using errcode = 'LW007';
  end if;

  -- Guard against future anonymous identities creating families
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is true then
    raise exception 'Anonymous identities cannot create families' using errcode = 'LW008';
  end if;

  if trim(p_name) = '' or char_length(p_name) > 100 then
    raise exception 'Family name must be between 1 and 100 characters' using errcode = 'LW002';
  end if;

  if trim(p_timezone) = '' then
    raise exception 'Timezone cannot be empty' using errcode = 'LW003';
  end if;

  if trim(p_locale) = '' then
    raise exception 'Locale cannot be empty' using errcode = 'LW004';
  end if;

  insert into public.families (name, timezone, locale, created_by_user_id)
  values (trim(p_name), trim(p_timezone), trim(p_locale), v_user_id)
  returning * into v_family;

  insert into public.family_memberships (family_id, auth_user_id, role, status)
  values (v_family.id, v_user_id, 'owner', 'active');

  return v_family;
end;
$$;

revoke all on function public.create_family(text, text, text) from public;
grant execute on function public.create_family(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------

alter table public.families enable row level security;
alter table public.family_memberships enable row level security;
alter table public.child_profiles enable row level security;
alter table public.child_device_grants enable row level security;

-- families
create policy families_select on public.families
  for select
  to authenticated
  using (
    private.is_active_family_adult(id)
    or exists (
      select 1 from public.child_device_grants cdg
      where cdg.family_id = families.id
        and cdg.auth_user_id = auth.uid()
        and cdg.status = 'active'
    )
  );

create policy families_update on public.families
  for update
  to authenticated
  using (private.is_family_owner(id))
  with check (private.is_family_owner(id));

-- family_memberships
create policy family_memberships_select on public.family_memberships
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
  );

create policy family_memberships_insert on public.family_memberships
  for insert
  to authenticated
  with check (
    private.is_family_owner(family_id)
  );

create policy family_memberships_update on public.family_memberships
  for update
  to authenticated
  using (private.is_family_owner(family_id))
  with check (private.is_family_owner(family_id));

-- child_profiles
create policy child_profiles_select on public.child_profiles
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or (
      id = (
        select cdg.child_id
        from public.child_device_grants cdg
        where cdg.auth_user_id = auth.uid()
          and cdg.status = 'active'
      )
    )
  );

create policy child_profiles_insert on public.child_profiles
  for insert
  to authenticated
  with check (
    private.is_active_family_adult(family_id)
  );

create policy child_profiles_update on public.child_profiles
  for update
  to authenticated
  using (private.is_active_family_adult(family_id))
  with check (private.is_active_family_adult(family_id));

-- child_device_grants:
-- In Phase 1, pairing is deferred. Client roles cannot directly manufacture or
-- mutate device grants. Grants are SELECT-only for active adults or the granted device.
-- Creation/revocation will only be exposed through trusted, validated RPCs in later phases.
create policy child_device_grants_select on public.child_device_grants
  for select
  to authenticated
  using (
    private.is_active_family_adult(family_id)
    or auth_user_id = auth.uid()
  );

-- ---------------------------------------------------------------------------
-- 6. EXPLICIT GRANTS
-- ---------------------------------------------------------------------------

grant usage on schema public to authenticated, anon;

grant select, update on public.families to authenticated;
grant select, insert, update on public.family_memberships to authenticated;
grant select, insert, update on public.child_profiles to authenticated;
grant select on public.child_device_grants to authenticated;

-- Service role retains full administrative access for backend tasks
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant all on all functions in schema public to service_role;
