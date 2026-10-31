-- Phase 0 security baseline.
--
-- The `private` schema holds privileged helper functions (for example the
-- family-membership predicates used by RLS). It is not exposed through the
-- Data API. Later migrations add tables, grants and policies; this migration
-- only establishes the non-exposed namespace and removes default access.

create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon, authenticated;
