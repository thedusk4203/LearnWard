# learnward_design_system

Shared Flutter visual primitives for LearnWard.

## Responsibility

- Theme entry point (`AppTheme`).
- Spacing, radius and typography tokens.
- Reusable buttons, cards, progress components and accessibility helpers as
  later phases need them.

## Dependency rule

Flutter is allowed. Feature business logic, domain rules, Supabase and Drift are
not allowed here. Do not build full product screens in this package.
