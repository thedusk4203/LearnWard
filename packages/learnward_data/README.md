# learnward_data

Infrastructure adapters for LearnWard.

## Responsibility

- Drift/SQLite local database, migrations and generated schema code.
- Supabase repositories, DTOs, mappers and RPC clients (later phases).
- Evidence storage adapters and sync/outbox implementation (later phases).

## Authority rule

The server is authoritative. SQLite is a cache, draft store and command
outbox. Never treat locally computed XP, RP, mastery or approval state as
authoritative.

## Dependency rule

May depend on `learnward_domain`, `learnward_application`, Drift and the
Supabase Dart client. Domain rules must not be implemented here.
