# learnward_application

Application/use-case layer for LearnWard.

## Responsibility

- Use cases such as submit assessment, approve assessment, calculate growth,
  redeem a reward or spin the wheel (later phases).
- Ports/interfaces that data adapters implement.
- Orchestration only: business rules stay in `learnward_domain`.

## Dependency rule

Depends on `learnward_domain` only. It must not import Flutter, Riverpod,
Supabase, Drift or platform plugins. Infrastructure is supplied through ports.
