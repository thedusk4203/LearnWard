# Supabase (local development)

The `supabase/` directory is the schema source of truth. Migrations are
versioned and applied through the Supabase CLI; do not edit a linked remote
project by hand.

## Phase 0 contents

- `config.toml` — local stack configuration. `auto_expose_new_tables` is off, so
  every exposed object needs an explicit grant.
- `migrations/20261031000000_phase0_private_schema.sql` — creates the
  non-exposed `private` schema for privileged helpers.
- `functions/` — empty; Edge Functions arrive with the commands that need them.
- `seed.sql` — intentionally empty.

No application tables exist yet. The family/assessment/reward schema is
introduced phase by phase per `docs/09-data-and-authorization-model-v0.1.md`.

## Commands

```bash
npx supabase start
npx supabase status
npx supabase db reset
npx supabase stop
```

Use the publishable key from `supabase status` for local Flutter runs. Never
copy a `service_role` key into the app.

## Security rules for later migrations

1. RLS on every table reachable through the Data API.
2. Explicit grants; `TO authenticated` is never authorization by itself.
3. Family ownership predicates backed by `family_memberships` and
   `child_device_grants`.
4. Never authorize from editable `user_metadata`.
5. Private helper functions live in `private` with an empty `search_path`.
6. Evidence uses a private Storage bucket.
7. XP/RP/mastery/spin mutations remain server-authoritative and idempotent.

RLS allow and deny tests are mandatory before the pilot.
