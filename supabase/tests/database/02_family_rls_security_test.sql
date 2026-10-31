begin;
select plan(36);

-- ---------------------------------------------------------------------------
-- 0. TEST FIXTURES SETUP (superuser context)
-- ---------------------------------------------------------------------------

-- Setup auth.users test identities
insert into auth.users (id, aud, role, email) values
  ('10000000-0000-0000-0000-000000000001'::uuid, 'authenticated', 'authenticated', 'owner_a@test.com'),
  ('10000000-0000-0000-0000-000000000002'::uuid, 'authenticated', 'authenticated', 'parent_a@test.com'),
  ('10000000-0000-0000-0000-000000000003'::uuid, 'authenticated', 'authenticated', 'child_a1_device@test.com'),
  ('10000000-0000-0000-0000-000000000004'::uuid, 'authenticated', 'authenticated', 'owner_b@test.com'),
  ('10000000-0000-0000-0000-000000000005'::uuid, 'authenticated', 'authenticated', 'outsider@test.com'),
  ('10000000-0000-0000-0000-000000000006'::uuid, 'authenticated', 'authenticated', 'revoked_a@test.com')
on conflict (id) do nothing;

-- Setup Family A and Family B
insert into public.families (id, name, timezone, locale, created_by_user_id) values
  ('a0000000-0000-0000-0000-000000000001'::uuid, 'Family A', 'America/New_York', 'en_US', '10000000-0000-0000-0000-000000000001'::uuid),
  ('b0000000-0000-0000-0000-000000000001'::uuid, 'Family B', 'America/Chicago', 'en_US', '10000000-0000-0000-0000-000000000004'::uuid);

-- Setup Memberships for Family A
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('a0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000001'::uuid, 'owner', 'active'),
  ('a0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000002'::uuid, 'parent', 'active'),
  ('a0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000006'::uuid, 'parent', 'revoked');

-- Setup Memberships for Family B
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('b0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000004'::uuid, 'owner', 'active');

-- Setup Children for Family A
insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
  ('a1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Child A1', 5, 2015),
  ('a2000000-0000-0000-0000-000000000002'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Child A2', 7, 2013);

-- Setup Children for Family B
insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
  ('b1000000-0000-0000-0000-000000000001'::uuid, 'b0000000-0000-0000-0000-000000000001'::uuid, 'Child B1', 6, 2014);

-- Setup Paired Child Device for Child A1 (inserted via superuser as test fixture)
insert into public.child_device_grants (id, family_id, child_id, auth_user_id, status, paired_by_user_id) values
  ('c1000000-0000-0000-0000-000000000001'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000003'::uuid, 'active', '10000000-0000-0000-0000-000000000001'::uuid);

-- ---------------------------------------------------------------------------
-- 1. ADULT ISOLATION TESTS
-- ---------------------------------------------------------------------------

-- Switch to Owner A
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select is(
  (select count(*)::int from public.families where id = 'a0000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Owner A can read Family A'
);

select is(
  (select count(*)::int from public.families where id = 'b0000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Owner A cannot read Family B'
);

select is(
  (select count(*)::int from public.child_profiles where family_id = 'a0000000-0000-0000-0000-000000000001'::uuid),
  2,
  'Owner A can read Child A1 and A2'
);

select is(
  (select count(*)::int from public.child_profiles where id = 'b1000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Owner A cannot read Child B1'
);

-- Switch to Owner B
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000004", "role": "authenticated"}', true);

select is(
  (select count(*)::int from public.families where id = 'a0000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Owner B cannot read Family A'
);

select is(
  (select count(*)::int from public.child_profiles where id = 'b1000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Owner B can read Child B1'
);

-- ---------------------------------------------------------------------------
-- 2. MUTATION ISOLATION TESTS
-- ---------------------------------------------------------------------------

-- Switch to Parent A
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Parent A creates child under Family A
insert into public.child_profiles (id, family_id, display_name, school_grade) values
  ('a3000000-0000-0000-0000-000000000003'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Child A3', 8);

select is(
  (select count(*)::int from public.child_profiles where id = 'a3000000-0000-0000-0000-000000000003'::uuid),
  1,
  'Parent A can insert child profile into Family A'
);

-- Parent A attempts to insert child into Family B (violates RLS)
prepare parent_insert_child_family_b as
  insert into public.child_profiles (id, family_id, display_name, school_grade) values
    ('b2000000-0000-0000-0000-000000000002'::uuid, 'b0000000-0000-0000-0000-000000000001'::uuid, 'Child B2', 4);

select throws_ok(
  'parent_insert_child_family_b',
  '42501',
  null,
  'Parent A cannot insert child into Family B'
);

-- Parent A attempts to update Child B1
update public.child_profiles
set display_name = 'Hacked Name'
where id = 'b1000000-0000-0000-0000-000000000001'::uuid;

select is(
  (select display_name from public.child_profiles where id = 'b1000000-0000-0000-0000-000000000001'::uuid),
  null,
  'Parent A cannot update Child B1 (invisible via RLS)'
);

-- Parent A attempts to update Family B details
update public.families
set name = 'Hacked Family B'
where id = 'b0000000-0000-0000-0000-000000000001'::uuid;

select is(
  (select name from public.families where id = 'b0000000-0000-0000-0000-000000000001'::uuid),
  null,
  'Parent A cannot update Family B'
);

-- ---------------------------------------------------------------------------
-- 3. CHILD IDENTITY AND DEVICE GRANT ISOLATION
-- ---------------------------------------------------------------------------

-- Switch to Child A1 device identity
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

select is(
  (select count(*)::int from public.child_profiles where id = 'a1000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Child A1 device can read own child profile'
);

select is(
  (select count(*)::int from public.child_profiles where id = 'a2000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Child A1 device cannot read sibling Child A2 profile'
);

select is(
  (select count(*)::int from public.family_memberships where family_id = 'a0000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Child A1 device cannot read adult memberships'
);

prepare child_elevate_membership as
  insert into public.family_memberships (family_id, auth_user_id, role, status) values
    ('a0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000003'::uuid, 'owner', 'active');

select throws_ok(
  'child_elevate_membership',
  '42501',
  null,
  'Child A1 device cannot create adult membership'
);

-- Child A1 attempts to mutate child device grant (direct UPDATE permission revoked)
prepare child_update_grant as
  update public.child_device_grants
  set child_id = 'a2000000-0000-0000-0000-000000000002'::uuid
  where id = 'c1000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'child_update_grant',
  '42501',
  null,
  'Paired child device cannot mutate child_device_grant'
);

-- Revoke Child A1 grant (as superuser)
set local role postgres;
update public.child_device_grants
set status = 'revoked'
where id = 'c1000000-0000-0000-0000-000000000001'::uuid;

-- Switch back to Child A1 device
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

select is(
  (select count(*)::int from public.child_profiles where id = 'a1000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Revoked Child A1 grant immediately loses access to child profile'
);

-- ---------------------------------------------------------------------------
-- 4. PRIVILEGE ESCALATION AND MALICIOUS PAYLOAD TESTS
-- ---------------------------------------------------------------------------

-- Switch to Parent A
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);

-- Parent A attempts to change child family_id to Family B (composite FK + RLS check)
prepare change_child_family as
  update public.child_profiles
  set family_id = 'b0000000-0000-0000-0000-000000000001'::uuid
  where id = 'a1000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'change_child_family',
  'LW005',
  'family_id on child_profiles is immutable',
  'Parent A cannot change child family_id to Family B'
);

-- Parent A attempts to elevate self to owner in family_memberships
update public.family_memberships
set role = 'owner'
where family_id = 'a0000000-0000-0000-0000-000000000001'::uuid
  and auth_user_id = '10000000-0000-0000-0000-000000000002'::uuid;

select is(
  (select role from public.family_memberships where auth_user_id = '10000000-0000-0000-0000-000000000002'::uuid and family_id = 'a0000000-0000-0000-0000-000000000001'::uuid),
  'parent',
  'Parent A cannot elevate self to owner (role unchanged)'
);

-- Outsider attempts to insert membership for self in Family A
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated"}', true);

prepare outsider_join_family as
  insert into public.family_memberships (family_id, auth_user_id, role, status) values
    ('a0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000005'::uuid, 'owner', 'active');

select throws_ok(
  'outsider_join_family',
  '42501',
  null,
  'Outsider cannot insert membership into Family A'
);

-- Revoked member attempts to revive own membership
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000006", "role": "authenticated"}', true);

update public.family_memberships
set status = 'active'
where family_id = 'a0000000-0000-0000-0000-000000000001'::uuid
  and auth_user_id = '10000000-0000-0000-0000-000000000006'::uuid;

select is(
  (select count(*)::int from public.family_memberships where auth_user_id = '10000000-0000-0000-0000-000000000006'::uuid and status = 'active'),
  0,
  'Revoked member cannot revive own membership (status remains revoked)'
);

-- ---------------------------------------------------------------------------
-- 5. ATOMIC RPC TESTS (create_family)
-- ---------------------------------------------------------------------------

-- Switch to Outsider who will create their own family
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated"}', true);

select lives_ok(
  $$ select public.create_family('Outsider Clan', 'Europe/London', 'en_GB') $$,
  'Authenticated user can invoke create_family'
);

select is(
  (select count(*)::int from public.families where created_by_user_id = '10000000-0000-0000-0000-000000000005'::uuid),
  1,
  'create_family successfully created family record'
);

select is(
  (
    select count(*)::int
    from public.family_memberships
    where auth_user_id = '10000000-0000-0000-0000-000000000005'::uuid
      and role = 'owner'
      and status = 'active'
  ),
  1,
  'create_family atomically created active owner membership'
);

-- Unauthenticated anon caller cannot create family (permission denied on function)
set local role anon;
select set_config('request.jwt.claims', '', true);

select throws_ok(
  $$ select public.create_family('Anon Family', 'UTC', 'en_US') $$,
  '42501',
  null,
  'Unauthenticated anon caller has no execute permission on create_family'
);

-- Direct client INSERT on families is rejected (must use create_family RPC)
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated"}', true);

prepare direct_family_insert as
  insert into public.families (name, timezone, locale, created_by_user_id) values
    ('Illegal Direct Family', 'UTC', 'en_US', '10000000-0000-0000-0000-000000000005'::uuid);

select throws_ok(
  'direct_family_insert',
  '42501',
  null,
  'Direct client insert into families is rejected by RLS / grant boundary'
);

-- ---------------------------------------------------------------------------
-- 6. PHASE 1 SECURITY HARDENING INVARIANTS (SECTIONS 6-12)
-- ---------------------------------------------------------------------------

-- 6.1 Parent cannot directly create child_device_grant
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
prepare parent_create_grant as
  insert into public.child_device_grants (family_id, child_id, auth_user_id, paired_by_user_id) values
    ('a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000005'::uuid, '10000000-0000-0000-0000-000000000002'::uuid);

select throws_ok(
  'parent_create_grant',
  '42501',
  null,
  'Parent cannot directly create child_device_grant'
);

-- 6.2 Owner cannot directly manufacture grant while pairing is deferred
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
prepare owner_create_grant as
  insert into public.child_device_grants (family_id, child_id, auth_user_id, paired_by_user_id) values
    ('a0000000-0000-0000-0000-000000000001'::uuid, 'a1000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000005'::uuid, '10000000-0000-0000-0000-000000000001'::uuid);

select throws_ok(
  'owner_create_grant',
  '42501',
  null,
  'Owner cannot directly create child_device_grant while pairing is deferred'
);

-- 6.3 Last active owner cannot self-revoke
prepare owner_self_revoke as
  update public.family_memberships
  set status = 'revoked'
  where family_id = 'a0000000-0000-0000-0000-000000000001'::uuid
    and auth_user_id = '10000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'owner_self_revoke',
  'LW006',
  'Family must have at least one active owner',
  'Last active owner cannot self-revoke'
);

-- 6.4 Last active owner cannot self-demote
prepare owner_self_demote as
  update public.family_memberships
  set role = 'parent'
  where family_id = 'a0000000-0000-0000-0000-000000000001'::uuid
    and auth_user_id = '10000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'owner_self_demote',
  'LW006',
  'Family must have at least one active owner',
  'Last active owner cannot self-demote to parent'
);

-- 6.5 Last active owner cannot be deleted (tested under privileged role to reach trigger)
set local role postgres;
prepare owner_delete as
  delete from public.family_memberships
  where family_id = 'a0000000-0000-0000-0000-000000000001'::uuid
    and auth_user_id = '10000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'owner_delete',
  'LW006',
  'Family must have at least one active owner',
  'Last active owner cannot be deleted'
);

-- 6.6 Child tenant key family_id cannot change even if user belongs to both families
set local role postgres;
insert into public.family_memberships (family_id, auth_user_id, role, status) values
  ('b0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000001'::uuid, 'parent', 'active');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000001", "role": "authenticated"}', true);

prepare move_child_dual_member as
  update public.child_profiles
  set family_id = 'b0000000-0000-0000-0000-000000000001'::uuid
  where id = 'a1000000-0000-0000-0000-000000000001'::uuid;

select throws_ok(
  'move_child_dual_member',
  'LW005',
  'family_id on child_profiles is immutable',
  'Child tenant key cannot change even when user belongs to both families'
);

-- 6.7 Default privileges: new table has no unintended authenticated or anon access
set local role postgres;
create table public.probe_security_table (id int);

select ok(
  not has_table_privilege('anon', 'public.probe_security_table', 'select'),
  'Default privileges: anon has no select on probe table'
);

select ok(
  not has_table_privilege('authenticated', 'public.probe_security_table', 'select'),
  'Default privileges: authenticated has no select on probe table'
);

-- 6.8 Default privileges: new function is not executable by PUBLIC
create function public.probe_security_fn() returns int language sql as 'select 1';

select ok(
  not has_function_privilege('public', 'public.probe_security_fn()', 'execute'),
  'Default privileges: PUBLIC cannot execute probe function'
);

-- 6.9 Child device identity cannot create family
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

prepare child_device_create_family as
  select public.create_family('Child Device Family', 'UTC', 'en_US');

select throws_ok(
  'child_device_create_family',
  'LW007',
  'Child device identities cannot create families',
  'Child device identity cannot execute create_family'
);

-- 6.10 Anonymous identity cannot create family
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000099", "role": "authenticated", "is_anonymous": true}', true);

prepare anon_jwt_create_family as
  select public.create_family('Anonymous Family', 'UTC', 'en_US');

select throws_ok(
  'anon_jwt_create_family',
  'LW008',
  'Anonymous identities cannot create families',
  'Anonymous identity cannot execute create_family'
);

-- Finish pgTAP tests
select * from finish();
rollback;
