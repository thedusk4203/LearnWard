# learnward_test_support

Shared test-only helpers for LearnWard.

## Responsibility

- Deterministic clocks, builders, fixtures and fakes shared by multiple
  packages.
- Helpers that make domain and application tests readable without duplicating
  setup.

## Dependency rule

Test-only code. Never put production behavior here. This package may depend on
domain/application packages, but production packages must not depend on it.
