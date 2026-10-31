# Implementation Plan v0.1

This document converts the current LearnWard product and architecture decisions into an implementation sequence that an engineering agent can execute without having to invent core structure.

The plan assumes the current frozen direction:

- Flutter mobile app for Android and iOS,
- Supabase Auth + Postgres + Storage backend,
- local SQLite/Drift cache,
- family as tenant/security boundary,
- child profiles separated from adult identities,
- server-authoritative XP/RP/mastery/economy operations,
- Growth Engine and Learning Engine as deterministic domain logic,
- pilot-first delivery rather than immediately building a large production product.

This is an implementation plan, not permission to build every listed capability at once.

---

## 1. Repository strategy

Use a single monorepo.

Prefer native Dart **pub workspaces** rather than introducing an additional monorepo orchestrator unless a concrete need appears later.

Suggested structure:

```text
LearnWard/
├── apps/
│   └── mobile/
│       ├── android/
│       ├── ios/
│       ├── lib/
│       ├── integration_test/
│       └── test/
│
├── packages/
│   ├── learnward_domain/
│   ├── learnward_application/
│   ├── learnward_data/
│   ├── learnward_design_system/
│   └── learnward_test_support/
│
├── supabase/
│   ├── migrations/
│   ├── functions/
│   ├── seed.sql
│   └── config.toml
│
├── docs/
├── scripts/
├── .github/
│   └── workflows/
├── pubspec.yaml
├── pubspec.lock
└── README.md
```

The root should own the shared dependency resolution through a Dart pub workspace.

Do not introduce package boundaries merely for visual neatness. A package must have a clear responsibility and dependency direction.

---

## 2. Package responsibilities

### `learnward_domain`

Pure Dart. No Flutter and no Supabase dependency.

Contains:

- value objects,
- entities,
- Growth Engine rules,
- mastery calculations,
- reward-economy rules,
- anti-farming rules,
- ledger domain types,
- authorization-neutral business invariants.

Examples:

```text
NormalizedScore
AssessmentResult
GrowthBaseline
RewardPoints
StudyXp
SkillMastery
MasteryConfidence
MasteryFreshness
Goal
RewardDefinition
WheelDefinition
```

Requirement:

> The complete deterministic Growth Engine should be unit-testable without starting Flutter, a database, or a network connection.

### `learnward_application`

Application/use-case orchestration.

Examples:

```text
SubmitAssessment
ApproveAssessment
RejectAssessment
CalculateGrowth
UpdateMastery
CreateGoal
RedeemReward
SpinWheel
PairChildDevice
```

It depends on domain abstractions and repository interfaces but should not know Supabase implementation details.

### `learnward_data`

Infrastructure adapters.

Contains:

- Supabase repositories,
- Drift/local repositories,
- DTO mapping,
- sync/outbox implementation,
- Storage adapter,
- remote command/RPC clients.

This package may depend on `learnward_domain` and `learnward_application`, never the reverse.

### `learnward_design_system`

Reusable Flutter UI primitives:

- typography,
- spacing,
- semantic colors/tokens,
- buttons,
- cards,
- progress bars,
- mastery indicators,
- reward components,
- motion primitives,
- accessibility helpers.

Do not move feature business logic into the design system.

### `learnward_test_support`

Shared fixtures/builders for tests.

Examples:

```text
fakeChild()
fakeFamily()
assessmentBuilder()
growthScenario()
masteryScenario()
rewardLedgerFixture()
```

---

## 3. Mobile app structure

Within `apps/mobile/lib/` use feature-oriented organization over one giant technical-layer tree.

Suggested structure:

```text
lib/
├── app/
│   ├── bootstrap/
│   ├── routing/
│   ├── theme/
│   └── app.dart
│
├── features/
│   ├── auth/
│   ├── family/
│   ├── child_home/
│   ├── assessments/
│   ├── approvals/
│   ├── progress/
│   ├── mastery/
│   ├── goals/
│   ├── rewards/
│   ├── wheel/
│   └── settings/
│
└── shared/
    ├── presentation/
    └── platform/
```

Each feature may contain its own presentation/controller layer, but domain types should come from the shared domain packages.

Avoid a deep `data/domain/presentation` hierarchy repeated blindly for every tiny feature.

---

## 4. State management

Use Riverpod for application state and dependency injection.

Rules:

- business rules live in domain/application packages, not providers,
- providers expose/use application services,
- server data is treated separately from transient UI state,
- do not maintain parallel hand-written copies of the same entity in several providers,
- child mode and parent mode should resolve capabilities from authorization state rather than scattered UI booleans.

---

## 5. Navigation

Use `go_router`.

Top-level routing domains:

```text
/auth
/onboarding
/parent/...
/child/...
/pair/...
```

Navigation guards must be UX guards only.

They are never a substitute for backend authorization/RLS.

---

## 6. Environment model

Use three logical environments:

```text
Development
Staging
Production
```

### Development

- local Supabase whenever practical,
- local seed data,
- mock reward fulfillment acceptable,
- debug logging enabled,
- no production child data.

### Staging

- separate remote Supabase project,
- production-like RLS and Storage policies,
- TestFlight / Android internal testing target,
- synthetic or explicitly consenting pilot data only,
- migrations applied exactly as production would receive them.

### Production

- separate Supabase project,
- no ad-hoc schema editing,
- production signing identities,
- least-privilege secrets,
- release gates required.

Never point a debug build at production by default.

---

## 7. Flutter flavors / app identities

Create at least:

```text
dev
staging
prod
```

Each should have distinct app identifiers where practical.

Example conceptually:

```text
com.learnward.app.dev
com.learnward.app.staging
com.learnward.app
```

The production bundle/application ID should be treated as permanent once store distribution begins.

Environment-specific values must be injected through build configuration rather than committed secrets.

---

## 8. Supabase project layout

Use the repository `supabase/` directory as schema source-of-truth.

Expected assets:

```text
supabase/
├── config.toml
├── migrations/
├── functions/
│   ├── approve-assessment/
│   ├── spin-wheel/
│   ├── redeem-reward/
│   └── pair-child-device/
└── seed.sql
```

Exact function boundaries may change during implementation.

Important rule:

> The client must not be allowed to directly manufacture authoritative XP, RP, mastery, approvals, or spin outcomes.

Commands with economic/security consequences must execute inside a trusted database/server transaction.

---

## 9. Migration strategy

Schema changes must be reproducible from version-controlled migrations.

Workflow:

```text
1. Create/change schema locally
2. Test against local Supabase
3. Run database/RLS tests
4. Generate/review migration
5. Commit migration
6. Apply to staging
7. Run staging verification
8. Apply the exact migration to production
```

Rules:

- no undocumented production SQL edits,
- no rewriting already-applied production migrations,
- destructive migrations require explicit rollout/recovery plan,
- RLS policies and grants are versioned alongside table creation,
- indexes and constraints are treated as part of the feature, not cleanup work.

---

## 10. Authentication strategy

### Adult users

Start with a low-friction permanent identity such as:

- email OTP/magic link,
- Apple sign-in where required/appropriate,
- Google sign-in if needed later.

Avoid collecting more identity information than the product needs.

### Child users

A child remains a `child_profile` first.

V1 must not require child email, phone, or password.

Two operating modes:

```text
Shared-device child mode
Parent session → select child → constrained child UI
```

and:

```text
Paired child device
Parent generates short-lived QR/code
→ child device establishes restricted identity/grant
→ grant is scoped to one child profile
```

Pairing tokens must be:

- short lived,
- single use,
- revocable,
- rate limited,
- incapable of granting adult privileges.

---

## 11. Data API and RLS policy

All exposed tables require explicit grants and RLS.

Core rules:

- family membership is checked server-side,
- child grants are scoped to one child profile,
- sibling data is not implicitly visible to another paired child,
- parent mutation rights differ from child mutation rights,
- ledger tables are not generally client-updatable,
- Storage evidence uses private buckets and path/ownership-aware policies.

Never rely on editable user metadata for authorization.

Never treat `authenticated` alone as sufficient authorization.

---

## 12. Local/offline strategy

Use Drift/SQLite as:

1. local read cache,
2. draft storage,
3. pending command/outbox queue.

Offline state must distinguish:

```text
local draft
pending sync
server accepted
server rejected
server verified
```

Examples:

- a child may capture an assessment photo offline,
- the result can appear locally as pending,
- RP must not become spendable until server acceptance/verification,
- a wheel spin cannot be finalized offline.

The UI must never present pending local economy state as authoritative balance.

---

## 13. Command/idempotency model

Every server-authoritative mutation should support an idempotency key.

High-priority commands:

```text
submit_assessment
approve_assessment
reject_assessment
award_growth_result
redeem_reward
spin_wheel
pair_child_device
revoke_child_device
```

This protects against:

- double taps,
- retries after poor connectivity,
- duplicate offline queue delivery,
- race conditions across parent/child devices.

The same command with the same key must not generate duplicate ledger transactions or duplicate rewards.

---

## 14. Testing pyramid

### Layer A — Domain unit tests

Largest test layer.

Test Growth Engine and Mastery Engine exhaustively.

Examples:

- baseline calculations,
- high-performer protection,
- goal bonus,
- personal best,
- below-level reduction,
- RP rounding/minor units,
- anti-farming boundaries,
- mastery confidence/freshness,
- recovery behavior.

Prefer table-driven scenario tests.

### Layer B — Application tests

Test use cases against fake repositories.

Examples:

```text
Approve assessment → one ledger award
Duplicate approval → no second award
Reject assessment → no spendable RP
Spin → balance deducted exactly once
```

### Layer C — Database/RLS tests

Mandatory before pilot.

At minimum verify:

- cross-family reads fail,
- cross-family writes fail,
- child cannot approve itself,
- child cannot edit ledger,
- child A cannot read child B private evidence,
- revoked paired device loses access,
- duplicate command is idempotent,
- private Storage object is inaccessible without authorization.

### Layer D — Flutter widget tests

Focus on meaningful UI states rather than snapshotting every widget.

Examples:

- pending assessment,
- verified result,
- reward explanation,
- offline banner,
- parent approval state,
- accessibility labels.

### Layer E — Integration tests

Critical journeys:

```text
Parent onboarding
→ create child
→ child submits result
→ parent approves
→ Growth Engine award
→ RP visible
→ spin/redeem
```

Also test offline submission and sync recovery.

### Layer F — Device tests

Before public release, verify real Android and iOS devices for:

- camera/photo picker,
- notification permissions,
- deep links,
- background/resume behavior,
- network interruption,
- small/large screens,
- accessibility font scaling.

---

## 15. CI pipeline

Pull request CI should run without store credentials.

Suggested required checks:

```text
format
analyze
domain-unit-tests
application-tests
widget-tests
supabase-schema-tests
rls-tests
android-debug-build
```

Where practical, run independent checks in parallel.

### Main branch

After merge:

```text
all PR checks
+
staging migration validation
+
staging Android build
+
staging iOS build
```

### Release pipeline

Release should be an explicit workflow/tag, not every main push.

Targets:

- Android internal testing / closed testing,
- iOS TestFlight.

Production App Store / Play Store promotion remains manual or approval-gated during the pilot phase.

---

## 16. iOS CI constraint

The iOS build/sign/test path requires macOS/Xcode infrastructure.

Therefore CI should separate:

```text
Linux jobs
- Dart/Flutter analysis
- most unit tests
- Supabase tests
- Android build

macOS jobs
- iOS compile
- signing/archive when credentials are available
- iOS integration/device-specific validation as needed
```

Do not make every small PR depend on an expensive signed iOS archive unless necessary.

---

## 17. Secrets and signing

Never commit:

- Supabase secret/service-role keys,
- Apple signing certificates/private keys,
- App Store Connect private keys,
- Android keystores or passwords,
- production push credentials.

The Flutter client may contain only values intended for public clients, such as the Supabase project URL and publishable key.

Server secrets must stay in trusted server/CI secret stores.

---

## 18. Observability for the pilot

Do not begin with a large analytics platform.

Capture the product-validation events required by `docs/06-metrics-and-hypotheses.md`.

Minimum event vocabulary:

```text
assessment_created
assessment_submitted
assessment_verified
assessment_rejected
growth_calculated
mastery_updated
goal_created
goal_achieved
rp_awarded
wheel_spun
reward_redeemed
reward_fulfilled
child_device_paired
child_device_revoked
```

Events must avoid placing sensitive academic/evidence content directly into generic analytics payloads.

The authoritative product database remains the source for core metrics where possible.

---

## 19. Implementation phases

### Phase 0 — Engineering foundation

Deliver:

- Flutter workspace/bootstrap,
- pub workspace,
- package boundaries,
- dev/staging/prod configuration,
- Supabase local setup,
- lint/analyze/test pipeline,
- initial CI,
- design-system skeleton,
- app shell/routing,
- adult auth skeleton.

No wheel animation work yet.

Exit gate:

> Android and iOS app shells run, CI is green, local Supabase boots reproducibly.

### Phase 1 — Family + child identity

Deliver:

- family creation,
- adult membership,
- child profile creation,
- parent/child mode switching,
- initial RLS,
- basic child-device pairing/revocation if required for pilot.

Exit gate:

> A family can be created and cross-family access tests are green.

### Phase 2 — Assessment vertical slice

Deliver one complete vertical slice:

```text
Create assessment
→ attach evidence
→ submit
→ parent approve/reject
→ result history
```

Do not add mastery or rewards until this path is reliable.

Exit gate:

> A real assessment can move from child submission to verified academic evidence.

### Phase 3 — Growth Engine + ledger

Deliver:

- normalized score,
- comparable-result lookup,
- rolling baseline,
- Growth Engine v0.1,
- XP ledger,
- RP ledger,
- explainable award breakdown,
- idempotent approval/award transaction.

Exit gate:

> The same verified assessment always produces the expected deterministic award exactly once.

### Phase 4 — Reward loop

Deliver:

- parent-defined rewards,
- Reward Store,
- basic wheel,
- server-authoritative spin,
- redemption/fulfillment state,
- balance projection.

Animation should come after economy correctness.

Exit gate:

> RP can be earned and consumed without balance corruption or duplicate spins.

### Phase 5 — Learning Engine / mastery

Deliver:

- curriculum skeleton,
- assessment-to-skill evidence mapping,
- mastery score,
- confidence,
- freshness,
- recovery state,
- up to three next-challenge candidates.

Exit gate:

> Verified evidence can update a visible learning state without being influenced by reward bonuses.

### Phase 6 — Pilot hardening

Deliver:

- offline queue,
- failure/retry UX,
- notifications needed for approval/reward fulfillment,
- metric instrumentation,
- accessibility pass,
- privacy/data-retention controls required for pilot,
- TestFlight / Android internal distribution.

Exit gate:

> A small family pilot can run for four weeks without engineering intervention for normal daily usage.

---

## 20. What explicitly waits until after pilot evidence

Do not prioritize before the core pilot validates the behavior loop:

- AI tutor,
- automatic OCR grading at scale,
- full Vietnamese curriculum database,
- social network,
- sibling leaderboard,
- marketplace rewards,
- large virtual pet world,
- school LMS integrations,
- advanced BKT/IRT/deep knowledge tracing,
- complex subscription/paywall system,
- web admin portal,
- teacher product.

A feature can move earlier only when it is required to validate a specific pilot hypothesis.

---

## 21. Definition of done for an MVP feature

A feature is not done when the screen renders.

For any user-facing MVP capability, done means:

```text
Domain invariant defined
+ authorization defined
+ database migration committed
+ RLS/grants tested
+ offline behavior defined
+ error state implemented
+ analytics/metric event defined if needed
+ unit/application tests green
+ relevant integration path green
+ Android verified
+ iOS verified
+ documentation updated
```

---

## 22. Dependency direction

Keep the dependency graph one-way:

```text
Mobile UI
   ↓
Application
   ↓
Domain

Data/Infrastructure
   ├── implements Application/Domain interfaces
   ├── Supabase
   └── Drift
```

Forbidden direction examples:

```text
Domain → Flutter
Domain → Supabase
Growth Engine → Riverpod
Mastery Engine → Storage
```

This boundary is important because Growth/Mastery logic is expected to become core product IP and may eventually execute both client-side for preview and server-side for authority.

---

## 23. First implementation milestone

When coding starts, the first milestone should **not** be "build the reward wheel".

It should be:

> **One secure, tested, cross-platform assessment vertical slice.**

Specifically:

```text
Parent signs in
→ creates family
→ creates child
→ child enters a result
→ optionally attaches a photo
→ parent verifies it
→ verified result appears in history
```

Only after this path works correctly on Android and iOS should Growth Engine awards be connected.

This keeps implementation aligned with LearnWard's product thesis:

> learning evidence first; gamification second.
