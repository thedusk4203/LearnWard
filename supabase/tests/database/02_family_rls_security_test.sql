begin;
select plan(26);

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

-- Setup Paired Child Device for Child A1
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
insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
  ('a3000000-0000-0000-0000-000000000003'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Child A3', 4, 2016);

select is(
  (select count(*)::int from public.child_profiles where id = 'a3000000-0000-0000-0000-000000000003'::uuid),
  1,
  'Parent A can create Child A3 under Family A'
);

-- Parent A attempts to create child under Family B (must fail RLS check)
prepare bad_child_insert as
  insert into public.child_profiles (id, family_id, display_name, school_grade, birth_year) values
    ('b2000000-0000-0000-0000-000000000002'::uuid, 'b0000000-0000-0000-0000-000000000001'::uuid, 'Infiltrator', 4, 2016);

select throws_ok(
  'bad_child_insert',
  '42501',
  null,
  'Parent A cannot create child under Family B'
);

-- Switch to Outsider
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000005", "role": "authenticated"}', true);

-- Outsider attempts to update Family A
update public.families set name = 'Hacked Name' where id = 'a0000000-0000-0000-0000-000000000001'::uuid;

select is(
  (select name from public.families where id = 'a0000000-0000-0000-0000-000000000001'::uuid),
  null,
  'Outsider cannot read or update Family A'
);

-- Switch to Revoked Member A
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000006", "role": "authenticated"}', true);

select is(
  (select count(*)::int from public.families where id = 'a0000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Revoked member cannot read Family A'
);

prepare revoked_create_child as
  insert into public.child_profiles (id, family_id, display_name) values
    ('a4000000-0000-0000-0000-000000000004'::uuid, 'a0000000-0000-0000-0000-000000000001'::uuid, 'Child A4');

select throws_ok(
  'revoked_create_child',
  '42501',
  null,
  'Revoked member cannot mutate or add children to Family A'
);

-- ---------------------------------------------------------------------------
-- 3. CHILD IDENTITY ISOLATION TESTS
-- ---------------------------------------------------------------------------

-- Switch to Child A1 paired device
select set_config('request.jwt.claims', '{"sub": "10000000-0000-0000-0000-000000000003", "role": "authenticated"}', true);

select is(
  (select count(*)::int from public.child_profiles where id = 'a1000000-0000-0000-0000-000000000001'::uuid),
  1,
  'Child A1 device can read permitted A1 profile'
);

select is(
  (select count(*)::int from public.child_profiles where id = 'a2000000-0000-0000-0000-000000000002'::uuid),
  0,
  'Child A1 device CANNOT access sibling A2 profile'
);

select is(
  (select count(*)::int from public.child_profiles where id = 'b1000000-0000-0000-0000-000000000001'::uuid),
  0,
  'Child A1 device CANNOT access Child B1 profile'
);

-- Child A1 attempts to create adult membership (must fail)
prepare child_elevate_membership as
  insert into public.family_memberships (family_id, auth_user_id, role, status) values
    ('a0000000-0000-0000-0000-000000000001'::uuid, '10000000-0000-0000-0000-000000000003'::uuid, 'owner', 'active');

select throws_ok(
  'child_elevate_membership',
  '42501',
  null,
  'Child A1 device cannot create adult membership'
);

-- Child A1 attempts to mutate child device grant
update public.child_device_grants
set child_id = 'a2000000-0000-0000-0000-000000000002'::uuid
where id = 'c1000000-0000-0000-0000-000000000001'::uuid;

select is(
  (select child_id from public.child_device_grants where id = 'c1000000-0000-0000-0000-000000000001'::uuid),
  'a1000000-0000-0000-0000-000000000001'::uuid,
  'Child A1 device cannot change its grant child_id'
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
  '42501',
  null,
  'Parent A cannot change child family_id to Family B'
);

-- Parent A attempts to elevate self to owner in family_memberships (0 rows updated because non-owner cannot update)
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

-- Finish pgTAP tests
select * from finish();
rollback;
