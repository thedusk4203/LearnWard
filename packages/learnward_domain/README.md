# learnward_domain

Pure Dart domain package for LearnWard.

## Responsibility

- Entities, value objects and domain errors.
- Growth Engine, mastery rules, reward-economy rules, anti-farming rules and
  ledger domain types as later phases implement them.
- Deterministic product invariants that can run in tests without Flutter, a
  database or a network connection.

## Dependency rule

This package must stay free of Flutter, Riverpod, Supabase, Drift, Firebase,
HTTP clients and platform plugins. If a rule needs infrastructure, define a
domain concept or application port instead of importing the adapter.
