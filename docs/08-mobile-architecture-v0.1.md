# Mobile Architecture v0.1

This document records the initial mobile delivery decision for LearnWard.

## 1. Decision

LearnWard v1 will target:

- **Android**
- **iOS**

using a **single Flutter codebase**.

The application should be mobile-first. A web admin or desktop client is not part of the initial product scope.

## 2. Why Flutter

LearnWard has several characteristics that favor Flutter:

- one small product team should own Android and iOS together,
- the child experience will rely on custom progress visualizations, reward-wheel animation, mastery maps, celebrations, and other branded UI,
- parent and child flows should remain feature-equivalent across platforms,
- the app needs camera/photo evidence, local storage, notifications, secure authentication, deep links, and background-safe syncing,
- implementation should remain friendly to AI-assisted development and automated testing,
- native Kotlin/Swift escape hatches should remain available when a platform-specific capability is required.

Flutter currently supports production deployment to both Android and iOS from a shared codebase and provides direct mechanisms for platform-specific Kotlin/Java and Swift/Objective-C integration.

## 3. Alternatives considered

### Kotlin Multiplatform + Compose Multiplatform

KMP/Compose is a valid production-ready option for Android and iOS and is the strongest alternative.

Advantages:

- excellent native interoperability,
- Kotlin ecosystem,
- direct path to platform APIs,
- shared business logic and optionally shared UI,
- especially attractive for Android-heavy teams.

Why it is not the v1 choice:

- LearnWard benefits more from minimizing total implementation surface than from maximum native flexibility,
- Flutter provides a simpler single UI/runtime model for the highly visual child experience,
- the initial team is expected to be small and heavily AI-assisted.

This decision can be revisited before implementation if platform-specific requirements materially change.

### React Native

React Native is mature and viable, especially for teams already centered on TypeScript/React.

It is not preferred for LearnWard v1 because there is no existing React codebase to reuse, and Flutter's rendering model is a better fit for a highly custom, animated interface.

### Separate native Android and iOS apps

Not recommended for v1.

Two native codebases would duplicate:

- feature implementation,
- testing,
- release work,
- Growth Engine integration,
- state synchronization logic,
- UI iteration.

Native modules remain acceptable where a cross-platform abstraction is insufficient.

## 4. Initial platform floor

Use the supported Flutter mobile baseline at implementation time.

Current planning floor:

```text
Android: Android 7.0 / API 24 or newer
iOS:     iOS 15 or newer
```

These are planning constraints, not immutable product requirements. Re-evaluate against the target-family device distribution before release.

## 5. One app, multiple roles

Do not create separate Parent and Child applications for the first release.

Use one LearnWard app with role-aware experiences:

```text
LearnWard
   │
   ├── Parent mode
   │     ├── family setup
   │     ├── evidence approval
   │     ├── reward configuration
   │     ├── budget / fulfillment
   │     └── progress overview
   │
   └── Child mode
         ├── home / next challenge
         ├── add result
         ├── progress / mastery
         ├── goals
         ├── RP balance
         ├── wheel
         └── reward store
```

A household may later use different physical devices, but both roles should be backed by the same family data model.

Separate apps should only be considered if store policy, device ownership patterns, or materially different security requirements make the single-app model problematic.

## 6. Client architecture

Use clear dependency boundaries:

```text
Presentation
    │
    ▼
Application / Use Cases
    │
    ▼
Domain
    │
    ▼
Data / Repositories
    │
    ├── Local database
    ├── Remote API
    ├── File storage
    └── Platform services
```

### Presentation

Responsible for:

- Flutter widgets,
- navigation,
- animations,
- accessibility,
- parent/child visual modes,
- presentation state.

No Growth Engine formula should live inside UI widgets.

### Application layer

Responsible for use cases such as:

- submit assessment,
- verify evidence,
- compute/update progress,
- create goal,
- spend RP,
- spin reward wheel,
- fulfill reward,
- request next challenge.

### Domain layer

Contains deterministic product logic:

- Growth Engine,
- mastery updates,
- reward eligibility,
- RP accounting rules,
- anti-farming rules,
- goal rules,
- reward-wheel selection policy.

This layer should have minimal framework dependencies and extensive unit tests.

### Data layer

Responsible for:

- persistence,
- authentication/session data,
- remote synchronization,
- evidence files,
- caching,
- repository implementations.

## 7. Recommended Flutter structure

Initial repository structure after coding begins:

```text
/
├── README.md
├── docs/
├── app/
│   ├── android/
│   ├── ios/
│   ├── lib/
│   │   ├── app/
│   │   ├── core/
│   │   ├── domain/
│   │   ├── data/
│   │   ├── features/
│   │   │   ├── auth/
│   │   │   ├── family/
│   │   │   ├── assessments/
│   │   │   ├── progress/
│   │   │   ├── mastery/
│   │   │   ├── goals/
│   │   │   ├── rewards/
│   │   │   └── approvals/
│   │   └── main.dart
│   └── test/
└── tooling/
```

Do not create this structure until implementation is intentionally started.

## 8. State management

Preferred v1 direction:

- **Riverpod** for application/presentation state,
- immutable domain objects,
- explicit async states,
- repository interfaces between domain/application logic and persistence.

Avoid placing business rules inside state-management providers.

## 9. Navigation

Preferred v1 direction:

- **go_router** or an equivalent declarative router,
- route guards for authentication and role access,
- deep-link support for parent invitations and future notification targets.

Navigation should remain a UI concern rather than a domain concern.

## 10. Backend direction

The initial backend candidate is **Supabase**, because LearnWard's model is naturally relational and benefits from:

- PostgreSQL,
- authentication,
- Row Level Security,
- file/object storage for evidence,
- realtime updates where useful,
- server-side functions/jobs,
- straightforward Flutter support.

This is a **provisional architecture choice**, not yet a build commitment.

Likely high-level model:

```text
Family
 ├── Memberships
 ├── Learners
 │    ├── Subjects
 │    ├── Assessments
 │    ├── Evidence
 │    ├── Skill states
 │    ├── Goals
 │    ├── XP ledger
 │    └── RP ledger
 ├── Rewards
 ├── Wheel configuration
 └── Reward fulfillments
```

Prefer immutable ledgers for XP/RP transactions rather than storing only mutable balances.

## 11. Offline-first expectations

LearnWard should remain usable during temporary network loss.

At minimum, the child should be able to:

- open recent progress,
- capture a result,
- attach a photo,
- create a pending submission,
- view cached rewards/goals.

Pending mutations should synchronize when connectivity returns.

Likely local persistence candidate:

- SQLite via Drift or an equivalent typed local database.

Do not silently award remotely authoritative RP while an assessment is still pending verification.

## 12. Evidence and media

Evidence capture may include:

- camera photo,
- gallery image,
- manually entered score,
- later: imported platform result or OCR-derived metadata.

Original evidence and derived metadata must be treated separately.

Example:

```text
Evidence image
      │
      ├── original immutable object
      │
      └── derived interpretation
            ├── detected subject
            ├── detected score
            └── confidence
```

An OCR/AI interpretation must never silently overwrite the learner's original evidence.

## 13. Notifications

Notifications should support learning and family coordination, not engagement farming.

Acceptable examples:

- parent: evidence waiting for approval,
- child: reward fulfilled,
- child: self-selected goal reminder,
- parent: promised reward approaching fulfillment date.

Avoid:

- "Your wheel misses you",
- artificial urgency,
- random re-engagement spam,
- streak-loss threats.

Implementation may use Firebase Cloud Messaging/APNs or an equivalent provider behind a notification abstraction.

## 14. Security model

Because LearnWard handles children's learning records, security boundaries are product requirements.

Minimum principles:

- family-scoped authorization,
- parent/admin controls household membership,
- child account receives least privilege,
- server-side authorization does not trust hidden UI controls,
- evidence objects are private by default,
- no public learner profiles,
- no public leaderboard,
- no child-to-stranger messaging,
- auditable RP/reward transactions,
- parent-visible important account changes.

If Supabase is used, Row Level Security policies must enforce these boundaries at the database layer.

## 15. Privacy and data minimization

Do not collect data merely because it may be useful later.

Initial data should be limited to what is required for:

- family relationships,
- learning evidence,
- progress/mastery,
- goals,
- rewards,
- product operation/security.

Evidence retention should eventually be configurable. Derived learning records may not need the original image indefinitely.

Legal/privacy requirements for child-directed products must be reviewed before public launch in each target market.

## 16. Growth Engine portability

Growth and mastery algorithms should be written as deterministic domain functions with test vectors.

Example boundary:

```text
AssessmentEvidence
      │
      ▼
GrowthEngine.evaluate(...)
      │
      ├── recognition breakdown
      ├── RP proposal
      ├── XP proposal
      └── goal events

MasteryEngine.update(...)
      │
      ├── mastery value
      ├── confidence
      ├── freshness
      └── next-challenge candidates
```

This allows future reuse on:

- server validation,
- analytics tooling,
- web/admin tools,
- migration to another client architecture if necessary.

Never make UI animation state part of these engines.

## 17. Testing strategy

Priority order:

1. **Domain unit tests** — Growth Engine, Mastery Engine, ledgers, eligibility rules.
2. **Repository tests** — local/remote synchronization and permissions.
3. **Widget tests** — core parent/child screens.
4. **Integration tests** — submit → approve → progress → reward.
5. **Golden/visual tests** — high-value custom UI where appropriate.

The most heavily tested code should be the least visually exciting code: scoring, mastery, authorization, and currency accounting.

## 18. Build and release constraints

Android development/builds can be performed on supported desktop environments.

For iOS:

- macOS is required for the normal iOS toolchain,
- Xcode is required for simulator/device builds and App Store submission/signing,
- CI should eventually include a macOS runner for iOS builds.

Do not assume a Windows-only development setup can produce final signed iOS releases locally.

## 19. CI/CD direction

When implementation begins:

```text
Pull request
   │
   ├── format / analyze
   ├── unit tests
   ├── widget tests
   └── build smoke checks

main
   │
   ├── Android internal build
   └── iOS TestFlight build
```

Use separate development/staging/production environments before handling real family data.

## 20. Technical non-goals for v1

Do not begin with:

- microservices,
- custom ML infrastructure,
- Kubernetes,
- a Rust native core without demonstrated need,
- two separate native UI codebases,
- complex event streaming,
- custom realtime infrastructure,
- a full web application.

The product's difficult problems are motivation, learning-state inference, trust, and family behavior—not distributed-systems novelty.

## 21. Implementation gate

Choosing Flutter does **not** mean implementation should start immediately.

Before writing production code, the product should still validate:

1. children care about visible growth beyond the novelty of the wheel,
2. parents can sustain reward fulfillment,
3. evidence/approval friction remains low,
4. the Growth Engine feels fair,
5. the Mastery model is understandable and useful.

If the pilot invalidates the product loop, the technology decision should not become sunk-cost pressure.

## 22. Current architecture status

```text
Mobile targets             FROZEN: Android + iOS
Client framework           FROZEN for v1: Flutter
Single vs separate apps    FROZEN for v1: one role-aware app
Backend                    PROVISIONAL: Supabase
Local database             PROVISIONAL: SQLite/Drift
State management           PROVISIONAL: Riverpod
Navigation                 PROVISIONAL: go_router
Push                       PROVISIONAL: FCM/APNs abstraction
Implementation             NOT STARTED
```

The next architecture work should define the **data model and trust/authorization model** in enough detail to support the pilot-to-MVP transition without prematurely implementing the app.
