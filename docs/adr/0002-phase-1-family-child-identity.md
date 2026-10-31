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
`auth.uid()` as the owner. Unauthenticated execution (`anon`) is revoked; only
`authenticated` users may invoke it.

**Consequence:** clients must call the RPC instead of inserting directly into
`families`. Direct insert on `families` is not permitted by RLS.

## Decision 2 — Child profile is not an Auth user

`child_profiles` rows are family-owned domain records and do not correspond to
`auth.users` accounts. No email, phone number, password, or exact date of birth
is collected or stored. Only `display_name`, optional `school_grade`, optional
`birth_year`, and optional `avatar_key` are retained.

This preserves the privacy invariant required by COPPA/GDPR-K guidelines and
LearnWard product principles: children must not have standalone credentials or
trackable auth accounts for shared family use.

## Decision 3 — Row Level Security (RLS) & Private helper functions

Row Level Security is enabled on all tables exposed to PostgREST (`families`,
`family_memberships`, `child_profiles`, `child_device_grants`). Explicit table
grants are enforced (`auto_expose_new_tables = false`).

To avoid recursive RLS queries when evaluating membership, security functions
`is_active_family_adult`, `is_family_owner`, and `is_active_child_device` are
placed in the non-exposed `private` schema with `SECURITY DEFINER` and
`SET search_path = ''`. Only `authenticated` users are granted execute access.
Default privileges on `public` and `private` schemas are revoked from `PUBLIC`.

## Decision 4 — Shared-device child mode with local parent gate

For Phase 1, the primary child interaction model is shared-device Child Mode.
The child operates within the authenticated adult session on the parent's device,
constrained to a child-safe dashboard and active child context.

Transitioning back to Parent Mode requires answering a parent challenge (local
gate). The pairing data model (`child_device_grants`, `private.child_pairing_requests`)
is fully migrated and covered by RLS, but dedicated anonymous child device
onboarding and short-code pairing exchange are deferred until dedicated child device
UX is implemented.

## Decision 5 — Blocking Supabase CI with pgTAP RLS security tests

Supabase CI is activated in GitHub Actions. Every pull request and push to `main`
boots the local Supabase stack (`supabase start`), executes migrations and seed
(`supabase db reset`), and runs the pgTAP security test suite (`supabase test db`).

The pgTAP tests verify 28 security invariants including:
- Cross-family read isolation for adults;
- Cross-family mutation isolation (updates and deletes rejected);
- Child profile isolation;
- Privilege escalation prevention (malicious users cannot self-assign `owner` or `parent` roles);
- Unauthenticated rejection of `create_family` RPC.
