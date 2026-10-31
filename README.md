# LearnWard

**LearnWard** is a family-centered learning motivation system that turns a child's real academic progress into visible growth, mastery, and meaningful rewards.

> **Product thesis:** Help children see themselves getting better.

LearnWard is not intended to be another curriculum platform, homework app, or generic chore/reward chart. It is designed as a **motivation layer over learning that already happens anywhere**: school tests, tutoring, worksheets, practice books, online learning platforms, homework, and self-study.

## Core loop

```text
LEARN ANYWHERE
     │
     ▼
CAPTURE RESULT
     │
     ▼
VERIFY EVIDENCE
     │
     ▼
GROWTH ENGINE
  ╱      │       ╲
 ▼       ▼        ▼
XP    Mastery     RP
 │       │         │
 │       │      ┌──┴───┐
 │       │      ▼      ▼
Level    │    Wheel   Store
 │       │      └──┬───┘
 │       │         ▼
 └───────┼──► Family Reward
         │
         ▼
   NEXT CHALLENGE
```

## Current product direction

- Initial target: children roughly **10–15 years old**, especially late-primary and middle-school learners.
- External-learning-first: LearnWard should understand progress from learning that happens outside the app.
- Reward **growth, mastery, recovery, and meaningful effort**, not obedience.
- Keep two primary resources:
  - **Study XP** — permanent progression; never spent or lost.
  - **Reward Points (RP)** — spendable on a random reward wheel or guaranteed reward store.
- The wheel is a celebration mechanic, not the product moat.
- The long-term moat is the **Growth Engine + longitudinal learning history + personalized mastery model**.
- Mastery must remain separate from reward: academic evidence updates learning state; RP/XP never inflate mastery directly.
- Mobile v1 targets **Android and iOS from one Flutter codebase**.
- Family is the tenant/security boundary; parent and paired-child access must be enforced server-side with RLS.
- Implementation is planned as a Dart pub-workspace monorepo with domain logic isolated from Flutter/Supabase infrastructure.

## Documentation

| Document | Purpose |
|---|---|
| [Product Definition](docs/00-product-definition.md) | Users, problem, JTBD, value proposition, scope and positioning |
| [Product Principles](docs/01-product-principles.md) | Non-negotiable product rules and safety constraints |
| [Competitive Landscape](docs/02-competitive-landscape.md) | Market map, competitors and identified white space |
| [Growth Engine v0.1](docs/03-growth-engine-v0.1.md) | Initial academic scoring and progress-recognition model |
| [Reward Economy v0.1](docs/04-reward-economy-v0.1.md) | XP/RP economy, wheel/store and anti-farming rules |
| [Pilot Plan v0.1](docs/05-pilot-plan-v0.1.md) | Four-week pre-build validation experiment |
| [Metrics & Hypotheses](docs/06-metrics-and-hypotheses.md) | North Star, secondary metrics and validation criteria |
| [Learning Engine & Mastery v0.1](docs/07-learning-engine-mastery-v0.1.md) | Subject/topic/skill model, mastery confidence, freshness and next-challenge logic |
| [Mobile Architecture v0.1](docs/08-mobile-architecture-v0.1.md) | Flutter Android/iOS architecture and platform delivery decisions |
| [Data & Authorization Model v0.1](docs/09-data-and-authorization-model-v0.1.md) | Family tenancy, schema, immutable ledgers, pairing, permissions, RLS and offline authority |
| [Implementation Plan v0.1](docs/10-implementation-plan-v0.1.md) | Monorepo layout, package boundaries, environments, migrations, CI/CD, testing and phased delivery |
| [Engineering Foundation ADR](docs/adr/0001-phase-0-foundation-decisions.md) | Phase 0 package, codegen, CI and local-Supabase decisions |
| [Phase 1 Family & Child Identity ADR](docs/adr/0002-phase-1-family-child-identity.md) | Phase 1 family and child identity decisions, atomic creation, RLS, and shared-device mode |
| [Toolchain Baseline](docs/toolchain-baseline.md) | Detected Flutter/Dart/Supabase versions and platform floors |

## Engineering

Phase 1 establishes the family and child identity foundation: adult authentication,
family creation, child profile management, family-scoped database RLS, and
shared-device Child Mode. Subsequent product features (assessments, Growth Engine,
rewards, wheel) are intentionally deferred to Phase 2+.

### Repository layout

```text
apps/mobile/                     Flutter app (Android + iOS)
packages/learnward_domain/       Pure Dart entities, value objects, engines
packages/learnward_application/  Use cases and ports
packages/learnward_data/         Drift, Supabase, DTOs, sync adapters
packages/learnward_design_system/ Theme and visual tokens
packages/learnward_test_support/ Test-only fixtures and fakes
supabase/                        Local schema and pgTAP test suite
scripts/                         Verification helpers
docs/                            Product and architecture source of truth
```

Dependency direction is one-way:

```text
domain <- application <- data <- mobile
design_system and test_support are side packages
```

`learnward_domain` has **zero** Flutter, Riverpod, Supabase, Drift or platform
plugin dependencies. See each package README before changing its dependencies.

### Prerequisites

- Flutter **3.47.1** (stable) with Dart **3.13.1**
- Android SDK 36 and a JDK compatible with the generated Gradle wrapper
- Xcode + CocoaPods on macOS for iOS builds
- Node.js (for `npx supabase`) and Docker Desktop for local Supabase
- Exact detected versions: [docs/toolchain-baseline.md](docs/toolchain-baseline.md)

The workspace uses native Dart pub workspaces. There is one root
`pubspec.lock`; do not add per-package lockfiles or Melos.

### Install dependencies

```bash
flutter pub get
```

### Configuration

The app reads compile-time values and never commits secrets:

| Variable | Purpose |
|---|---|
| `APP_ENV` | `development`, `staging` or `production` (default `development`) |
| `SUPABASE_URL` | Public Supabase project/local API URL |
| `SUPABASE_PUBLISHABLE_KEY` | Client-safe publishable key only |

Copy the example, then run with a defines file:

```bash
cp apps/mobile/dart_defines.example.json apps/mobile/dart_defines.json
cd apps/mobile
flutter run --dart-define-from-file=dart_defines.json
```

`dart_defines.json` is gitignored. The app shell also starts without Supabase
configuration using test fallbacks. Never put a `service_role`/secret key in Flutter.

### Run

```bash
cd apps/mobile
flutter run                 # Android or iOS device/simulator
```

Android and iOS are the only product targets. Web/desktop folders are not
generated.

### Tests

```bash
dart test packages/learnward_domain
dart test packages/learnward_application
dart test packages/learnward_data
dart test packages/learnward_test_support
flutter test apps/mobile
npx supabase test db
```

`apps/mobile/integration_test/` contains the on-device smoke test for later
device runs. Run everything at once with `bash scripts/verify.sh` or
`./scripts/verify.ps1` on Windows.

Test conventions: domain/application/data tests live in each package's `test/`;
Flutter widget tests in `apps/mobile/test/`; device journeys in
`apps/mobile/integration_test/`; database/RLS pgTAP tests live in
`supabase/tests/database/`.

### Analysis and formatting

```bash
dart format .                                      # write
dart format --output=none --set-exit-if-changed .  # CI check
flutter analyze
```

Analysis is configured once at the repository root. Generated `*.g.dart` files
are excluded from linting but are still formatted and committed.

### Code generation

Drift sources are committed. After changing a Drift table or database:

```bash
cd packages/learnward_data
dart run build_runner build
```

CI regenerates and fails if the committed output is stale. Do not hand-edit
`app_database.g.dart`.

### Build

```bash
cd apps/mobile
flutter build apk --debug
```

On macOS:

```bash
cd apps/mobile
flutter build ios --simulator --debug
```

Phase 1 uses one app identifier, `com.learnward.app`. Environment-specific
identifiers and signing are deferred until store distribution; see ADR 0001.

### Local Supabase

```bash
npx supabase start
npx supabase status
npx supabase db reset
npx supabase test db
npx supabase stop
```

Local ports are `45321` (API), `45322` (database), `45323` (Studio) and `45324`
(Mailpit) to avoid Windows reserved-port collisions. Analytics is disabled
because there are no production metrics to collect yet.
The API URL for the app is `http://127.0.0.1:45321`; take the publishable key
from `supabase status` and keep the secret/service-role key out of the app.

Phase 1 introduces the core family and child identity schema:
- `public.families`
- `public.family_memberships`
- `public.child_profiles`
- `public.child_device_grants`
- `private.child_pairing_requests`

Row Level Security is enabled on all tables, isolating family data and protecting
child profiles from cross-family access.
Run `npx supabase test db` to execute the automated pgTAP security suite (38 assertions
covering tenant isolation, mutation safety, default privileges, and privilege escalation prevention).
Run `node scripts/test_last_owner_concurrency.mjs` to execute the multi-session concurrency regression test.

### CI

`.github/workflows/ci.yml` runs on pull requests and pushes to `main`:

- format check, `flutter analyze`, package tests and widget tests;
- generated-Drift freshness check;
- Supabase migrations and pgTAP RLS security tests (`supabase start`, `supabase db reset`, `supabase test db`);
- Android debug APK build, uploaded as an artifact;
- iOS simulator compile on `macos-latest` (no signing).

## Product status

**Phase:** Phase 1 — Family + Child Identity complete  
**Code:** Domain entities, application use cases, Supabase repositories, RLS migrations, pgTAP tests, mobile UI (adult auth, family dashboard, child profile setup, shared-device child mode with parent challenge)  
**Mobile target:** Flutter → Android + iOS  
**Backend direction:** Supabase + Postgres + Storage  
**Next gate:** Phase 2 — Assessment vertical slice.

## Working rule

Do not add a feature merely because it increases engagement. New features should strengthen at least one of:

1. verified learning progress,
2. progress visibility,
3. learner autonomy,
4. mastery,
5. sustainable family motivation,
6. lower parent administrative burden.

If a feature mainly increases spins, screen time, or app dependency without strengthening learning, it should not be part of LearnWard.
