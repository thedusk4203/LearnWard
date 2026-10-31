# ADR 0002 — Phase 1 family and child identity decisions

- **Status:** Accepted
- **Date:** 2026-10-31
- **Context:** Phase 1 implements adult authentication, family creation, adult
  family membership, child profile management, family-scoped Row Level Security
  (RLS), and shared-device child mode.

## Decision 1 — Atomic family creation via `create_family` RPC

Creating a family requires inserting both a row in `public.families` and an
`owner` record in `public.family_memberships`. Allowing the client to execute
these as separate statements over the REST API risks leaving ownerless families
if the client disconnects or encounters an error mid-flight.

A Postgres RPC `public.create_family(p_name text, p_timezone text, p_locale text)`
is implemented with `SECURITY DEFINER` and `SET search_path = ''`. It inserts
both rows atomically within a single transaction, validating inputs and setting
`auth.uid()` as the owner.
The RPC enforces strict guards:
- Unauthenticated execution (`anon`) is rejected (`42501`);
- Child-device identities (`child_device_grants`) are barred from creating families (`LW007`);
- Anonymous sign-in identities are barred from acquiring adult authority (`LW008`).

**Consequence:** clients must call the RPC instead of inserting directly into
`families`. Direct insert on `families` is rejected by RLS.

## Decision 2 — Child profile is not an Auth user

`child_profiles` rows are family-owned domain records and do not correspond to
`auth.users` accounts. No email, phone number, password, or exact date of birth
is collected or stored. Only `display_name`, optional `school_grade`, optional
`birth_year`, and optional `avatar_key` are retained.

This architecture supports data-minimization and child-privacy goals: children do
not have standalone credentials or trackable auth accounts for shared family use.

## Decision 3 — Fail-closed default privileges & Row Level Security

Row Level Security is enabled on all tables exposed to PostgREST (`families`,
`family_memberships`, `child_profiles`, `child_device_grants`).
To eliminate accidental privilege exposure in future migrations, default privileges
created by the `postgres` migration role in schema `public` and `private` are
revoked upfront from `anon`, `authenticated`, and `PUBLIC`. All access requires
explicit role grants.

To avoid recursive RLS queries when evaluating membership, security functions
`is_active_family_adult`, `is_family_owner`, and `is_active_child_device` are
placed in the non-exposed `private` schema with `SECURITY DEFINER` and
`SET search_path = ''`. Only `authenticated` users are granted execute access.

## Decision 4 — Lock down `child_device_grants` while pairing is deferred

Dedicated child-device pairing is explicitly deferred to later phases.
To prevent clients from directly manufacturing or mutating authorization grants,
direct `INSERT` and `UPDATE` permissions on `public.child_device_grants` are revoked
from `authenticated` and `anon`. Grants are `SELECT`-only for active adults and
granted child devices.
When pairing is activated later, grants will be issued and revoked exclusively through
trusted, owner-authorized `SECURITY DEFINER` pairing RPCs.

## Decision 5 — Last active owner invariant & concurrency serialization

A family must never enter a state with zero active owners.
A database trigger `trg_ensure_last_active_owner` on `public.family_memberships`
enforces that the last active owner cannot self-revoke (`status = 'revoked'`),
self-demote to parent (`role = 'parent'`), or be deleted (`LW006`).
To prevent race conditions where concurrent transactions attempt to demote two co-owners
simultaneously, the trigger acquires an exclusive row-level lock on the parent family row
(`PERFORM 1 FROM public.families WHERE id = OLD.family_id FOR UPDATE`), serializing concurrent
owner mutations within the same family tenant. Multi-connection regression tests verify that
at least one active owner remains.

## Decision 6 — Tenant key immutability

To prevent cross-tenant child profile hijacking or accidental tenant reassignment,
a database trigger `trg_prevent_child_family_id_change` enforces that `family_id`
on `public.child_profiles` is immutable once created (`LW005`), even if a user is
an active member of both families.

## Decision 7 — Shared-device child mode containment, mandatory PIN setup & salted PIN gate

For Phase 1, the operational child interaction model is shared-device Child Mode.
- **Mandatory PIN Setup:** Before a parent can enter Child Mode, the app verifies if a
  Parent PIN has been configured. If none exists, a 4-digit PIN setup and confirmation
  dialog is required. Staging and production have no universal default PIN.
- **Persistence:** When a parent enters Child Mode, the active child profile session
  is persisted locally in SQLite (`AppDatabase` technical metadata). If the app is
  killed or restarted, the child session is reloaded before initial render, remaining
  locked in `/child`.
- **Router Guard:** The GoRouter guard intercepts all navigation while Child Mode
  is active, redirecting any attempt to access `/parent`, `/family/create`, or `/auth`
  back to `/child`.
- **Parent Gate:** Replaces simple arithmetic questions with parent-defined 4-digit
  PIN verification. The PIN is never stored in plaintext in SQLite or SharedPreferences;
  only a cryptographically salted SHA-256 digest is retained.
  **Threat model:** Defends against casual child tampering or accidental parent UI
  access on shared family devices. Server-side Postgres RLS remains the authoritative
  security boundary.

## Decision 8 — Fail-closed configuration outside development

Staging (`APP_ENV=staging`) and Production (`APP_ENV=production`) builds fail fast
with a `MissingSupabaseConfigurationException` if `SUPABASE_URL` or
`SUPABASE_PUBLISHABLE_KEY` is missing.
In-memory fake repositories are strictly confined to `APP_ENV=development` when
explicit demo mode (`ENABLE_LOCAL_DEMO=true`) or missing local configuration is set.
Misconfigured production builds will never silently operate with fake data.
