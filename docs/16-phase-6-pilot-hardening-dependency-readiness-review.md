# Phase 6 Dependency & Readiness Review — Pilot Hardening

- **Status:** PASS FOR DESIGN (Implementation NOT AUTHORIZED / NOT STARTED)
- **Reviewed Baseline:** `main` @ `da0ad970d30d3a761640e0bc5eb1c320cebd4f27`
- **Sealing Audit Reference:** PR #11 Comment `6605235500` — **PASS / SEALED**
- **Upstream Contracts:**
  - Phase 1 — Family + Child Identity: **FROZEN** ([Phase 1 Freeze Receipt](freezes/phase-1-family-child-identity-freeze.md), [ADR 0002](adr/0002-phase-1-family-child-identity.md))
  - Phase 2 — Secure Assessment Capture: **FROZEN** ([Phase 2 Freeze Receipt](freezes/phase-2-secure-assessment-capture-freeze.md), [ADR 0003](adr/0003-phase-2-secure-assessment-capture.md))
  - Phase 3 — Growth Engine + Ledgers: **FROZEN** ([Phase 3 Freeze Receipt](freezes/phase-3-growth-engine-ledger-freeze.md), [ADR 0004](adr/0004-phase-3-growth-engine-ledger.md))
  - Phase 4 — Reward Economy & Wheel: **FROZEN** ([Phase 4 Freeze Receipt](freezes/phase-4-reward-economy-wheel-freeze.md), [ADR 0005](adr/0005-phase-4-reward-economy-wheel.md))
  - Phase 5.1 — Learning Engine & Mastery: **FROZEN** ([Phase 5.1 Freeze Receipt](freezes/phase-5-1-learning-mastery-foundation-freeze.md), [ADR 0006](adr/0006-phase-5-learning-engine-mastery.md))
  - Phase 5.2 — Skill Graph & Recommendations: **FROZEN** ([Phase 5.2 Freeze Receipt](freezes/phase-5-2-skill-graph-recommendation-foundation-freeze.md), [ADR 0007](adr/0007-phase-5-2-skill-graph-recommendation.md))
  - Phase 5 — Complete Learning Engine: **COMPLETE / SEALED**
- **Phase 6 Implementation Status:** **NOT STARTED**

> [!IMPORTANT]
> This document is a documentation-only readiness and dependency analysis. It does NOT authorize migrations, runtime code, SDK additions, notification provider configuration, release signing, or external distribution.

---

## 1. Phase 6 Scope & Pilot Exit Gate

### 1.1 Authoritative Phase 6 Scope
Per `docs/10-implementation-plan-v0.1.md` Section 19, `docs/08-mobile-architecture-v0.1.md`, and `docs/06-metrics-and-hypotheses.md`, Phase 6 delivers:
1. **Offline Queue & Sync Resilience:** Local persistence for capture, outbox synchronization, and conflict-free replay.
2. **Failure & Retry UX:** Actionable user-facing retry states without leaking technical database exceptions or creating duplicate server mutations.
3. **Pilot Notifications:** Focused asynchronous coordination for parent approvals and child reward fulfillment (zero engagement spam).
4. **Metric & Telemetry Instrumentation:** Privacy-preserving instrumentation for the North Star metric (**VLPE**) and pilot hypotheses H1–H8.
5. **Accessibility Pass:** Screen-reader semantics, dynamic type font scaling, touch target minimums, contrast, and reduced-motion support.
6. **Privacy & Data-Retention Controls:** Minimum data retention, local cache eviction, account cleanup policies, and resolution of the immutable ledger deletion tension.
7. **TestFlight & Android Internal Distribution:** Release signing, keystore/secret handling, CI build artifacts, and distribution track readiness.

### 1.2 Pilot Exit Gate
> **A small family pilot can run for four weeks without engineering intervention for normal daily usage.**

### 1.3 Explicitly Deferred Post-Pilot Scope
The following items remain strictly out of scope for Phase 6 and pilot execution:
- AI tutor / chatbot interfaces
- Automatic OCR grading at scale
- Full national or international curriculum databases (pilot remains on `pilot-v0.1` and test fixtures)
- Social networking, peer sharing, and sibling leaderboards
- Third-party commercial marketplace reward integrations
- Large virtual pet worlds, avatars, or cosmetic skin stores
- School LMS integrations (Google Classroom, Canvas, etc.)
- Advanced psychometric models (BKT, IRT, deep knowledge tracing)
- Subscription tiers, paywalls, and in-app purchase payment processing
- Web administrative portal or teacher/classroom product

---

## 2. Master Capability & Dependency Inventory

Each area below is evaluated against the actual codebase at baseline `da0ad970d30d3a761640e0bc5eb1c320cebd4f27`:

| Capability Area | Status | Existing Implementation Baseline | Phase 6 Requirement |
|---|---|---|---|
| **Local Database & Drift Schema** | `PARTIAL` | `AppDatabase` (schema v4) with `LocalMetadataEntries`, `LocalAssessmentDrafts`, `PendingRewardCommands` | Needs unified schema migration strategy, tenant scoping, and command status metadata |
| **Offline Command Queue** | `PARTIAL` | Specialized command journal for reward redemption and wheel spin in `PendingRewardCommands` | Generalization to all offline mutations (assessment submit, review, etc.) or clear feature-bounded outboxes |
| **Actor-Aware Command Recovery** | `MISSING` | `PendingRewardCommands` lacks `actor_user_id` / `actor_role`; server fail-closed but client cannot self-heal | Bind queued commands to authenticated actor identity; evict or reject on identity mismatch |
| **Offline Security & Containment** | `PARTIAL` | Server enforces strict RLS and immutable ledgers; zero offline RP/mastery generation | Local SQLite data persists across sign-out and device grant revocation; fail-closed local wipe needed |
| **Failure & Retry UX** | `PARTIAL` | `AddAssessmentScreen` maps network errors; `ChildWheelScreen` has retry banner; other screens leak raw exceptions | Unified user-friendly error mapper, actionable retry components, and offline banners across all screens |
| **Evidence & Media Reliability** | `PARTIAL` | `image_picker` used; 10 MiB limit; compensation deletion on DB error in `UploadAssessmentEvidence` | Missing iOS camera/photo permission strings (`Info.plist`); missing offline upload resumption and storage recovery |
| **Push Notifications** | `MISSING` | Zero push dependencies in `pubspec.yaml`; zero device token tables in schema | Notification abstraction, device token registration, family targeting, and deep-link routing |
| **Metric Telemetry (VLPE)** | `PARTIAL` | Core VLPE, results logged, trends, and economy balance metrics directly derivable from PostgreSQL DB | Client-side privacy-preserving event envelope for self-chosen challenge tracking and UX interaction timing |
| **Analytics Privacy Contract** | `BLOCKED BY DESIGN DECISION` | Database contains sensitive minors' academic evidence and photos | Strict sanitization contract forbidding PII, child names, and image URLs in telemetry payloads |
| **Privacy & Data Retention** | `BLOCKED BY DESIGN DECISION` | Immutable append-only triggers on ledgers, events, and revisions block database deletion | Architectural policy resolving right-to-erasure vs. immutable ledger auditability |
| **Accessibility & Semantics** | `MISSING` | Standard Flutter widgets; zero `Semantics` widgets; zero `Tooltip` labels across mobile app | Comprehensive semantics labeling, 48x48 dp touch target verification, and dynamic type overflow testing |
| **Reduced Motion / Wheel Safety** | `PARTIAL` | Wheel has 4-second spin animation; server outcome is deterministic and non-losing | Reduced-motion setting bypass (`MediaQuery.disableAnimationsOf`) with instant reveal preserving outcome |
| **Android Release Distribution** | `MISSING` | Debug APK built in CI; `build.gradle.kts` uses debug signing for release build type | Production keystore generation, CI secret injection, release signing, and internal track deployment |
| **iOS / TestFlight Distribution** | `MISSING` | iOS simulator compiled in CI; debug profile; missing camera usage strings | Team ID, provisioning profile, export options, release archive workflow, and TestFlight pipeline |
| **Environment Configuration** | `PARTIAL` | `dart_defines.json` supported (`APP_ENV`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`) | Staging vs. Production project isolation, CI secret management, and production deep link hosts |
| **Staging Migration & Verification** | `PARTIAL` | Local CI executes `supabase db reset` and 438 pgTAP tests | Automated remote migration execution and post-migration smoke verification pipeline |
| **Operational Diagnostics** | `MISSING` | Client exceptions logged to console; no diagnostic support screen or correlation IDs | Non-sensitive diagnostic payload screen for pilot parents and testers (correlation ID, sync state) |
| **Schema Version Compatibility** | `MISSING` | Local Drift schema at v4; queued commands have no payload versioning | Explicit schema versioning on queued local command payloads to survive client app updates |
| **Frozen Contracts Invariance** | `READY` | Phases 1–5 frozen, tested, and sealed with 438 pgTAP tests and 61-case parity | Must remain 100% green without modification throughout Phase 6 |

---

## 3. Offline Capability & Local Persistence Audit

### 3.1 Current Local Database Inventory
The local database is powered by Drift (`packages/learnward_data/lib/src/database/app_database.dart`), currently at `schemaVersion = 4`:
1. `local_metadata_entries`: Key-value text storage (`key`, `value`, `updated_at`).
2. `local_assessment_drafts`: Full draft assessment state (`localDraftId`, `familyId`, `childId`, `createCommandId`, `submitCommandId`, `evidenceId`, `serverAssessmentId`, `subjectKey`, `subject`, `title`, `assessmentType`, `difficulty`, `rawScore`, `maxScore`, `localPhotoPath`, `entryContext`, `occurredAt`, `updatedAt`).
3. `pending_reward_commands`: Specialized journal for Store and Wheel operations (`id`, `operation`, `commandId`, `familyId`, `childId`, `rewardId`, `redemptionId`, `cancellationReason`, `createdAt`).

### 3.2 Flow-by-Flow Offline Survival Analysis

| User Flow | Network Loss | App Restart | Device Restart | Offline Read | Offline Mutation |
|---|---|---|---|---|---|
| **Assessment Drafting** | **Survives** | **Survives** | **Survives** | Local draft readable | Saved to `local_assessment_drafts` |
| **Assessment Submission** | Fails (no auto-sync) | Manual retry | Manual retry | Draft preserved | Requires online RPC |
| **Evidence Upload** | Fails (compensation) | Local file kept | Local file kept | Local file visible | Upload requires online Storage |
| **Store Redemption** | **Survives** in journal | **Survives** in journal | **Survives** in journal | Provisional balance | Replays commandId on retry |
| **Wheel Spin** | **Survives** in journal | **Survives** in journal | **Survives** in journal | UI retry banner | Replays commandId on retry |
| **Parent Fulfillment** | **Survives** in journal | **Survives** in journal | **Survives** in journal | No local cache | Replays commandId on retry |
| **Learning Overview Read** | Fails (leaks error) | Blank / loading | Blank / loading | **Not cached** | N/A (read-only) |
| **Next Challenge Read** | Fails (leaks error) | Blank / loading | Blank / loading | **Not cached** | N/A (read-only) |
| **Child Balances Read** | Memory only | Refetched online | Refetched online | **Not cached** | N/A (read-only) |

### 3.3 Offline Queue Architecture Recommendation
The current `pending_reward_commands` table is **not** a generic outbox; it is hardcoded to reward operations (`redeemReward`, `spinWheel`, `fulfillReward`, `cancelReward`).
- **Finding:** Inventing an overly generic, dynamic polymorphic offline queue for all application actions introduces severe state-synchronization complexity.
- **Readiness Recommendation:** Adopt **bounded feature journals**:
  1. Retain and harden the existing `pending_reward_commands` journal.
  2. Implement an assessment submission outbox (or extend `local_assessment_drafts` with an explicit `submission_status` lifecycle: `draft -> queuing -> uploading -> submitting -> failed`).
  3. Keep learning overview and mastery as **read caches** with stale-while-revalidate semantics rather than mutable queues.

---

## 4. Actor-Aware Command Recovery Audit

### 4.1 Identified Vulnerability & Backlog Item
As documented in `docs/11-phase-4-reward-economy-wheel-design-v0.1.md` Section 20 and `docs/freezes/phase-4-reward-economy-wheel-freeze.md` Section 13.1, `pending_reward_commands` persists:
```text
commandId, operation, familyId, childId, rewardId, redemptionId, cancellationReason, createdAt
```
It does **not** persist `actor_user_id` or `actor_role`.

### 4.2 Multi-User Failure Scenarios
1. **Adult Identity Switch on Shared Device:**
   - Adult A queues a reward fulfillment command (`commandId = C1`). Network times out.
   - Adult A logs out. Adult B (co-parent) logs into the same device.
   - The app detects pending command `C1` and retries it under Adult B's Supabase session.
   - **Server behavior:** Server checks `command_receipts`. If `C1` was already committed by Adult A, the server raises `42501 (Command caller mismatch)`. The client catches this but cannot distinguish caller mismatch from family authorization failure. If `C1` never reached the server, it executes under Adult B, creating audit trail attribution drift.
2. **Revoked Child Grant:**
   - A dedicated child device queues a wheel spin command (`C2`). Network times out.
   - Parent revokes the child device grant in family settings.
   - The child device comes online and retries `C2`.
   - **Server behavior:** Server rejects with `42501 (Device grant revoked)`. The client journal retains `C2` indefinitely, causing repeated failing background attempts.

### 4.3 Readiness Requirement
Phase 6 detailed design must specify:
1. Addition of `actor_user_id` and `actor_role` to local command journal schemas.
2. An eviction / cancellation policy when the active session's `auth.uid()` does not match `actor_user_id`.
3. Clear error classification when server returns `42501` on replayed commands.

---

## 5. Offline Security & Local Containment Audit

### 5.1 Local Data Exposure Inventory
The local client persists:
- SQLite (`app_database.sqlite`): raw assessment scores, subject titles, child IDs, family IDs, local photo paths, reward titles, redemption IDs.
- Secure Storage / SharedPreferences: Supabase auth JWT, refresh tokens, active Child Mode PIN, selected active child profile ID.
- App Documents Directory: Uncompressed photo evidence JPEG/PNG files.

### 5.2 Revocation and Logout Deficiencies
- **Current Code Behavior:** Logging out or exiting Child Mode does **not** delete local assessment drafts, pending command journals, or cached local evidence images.
- **Security Implication:** If a child device is unlinked or a shared device is returned, local drafts and photos remain accessible on the file system.
- **Frozen Contract Invariant:** Offline state must **NEVER** manufacture verified evidence, XP, RP, mastery improvements, reward redemption results, or wheel outcomes. All authoritative calculations remain server-side.
- **Readiness Requirement:** Phase 6 detailed design must specify a **secure local cleanup lifecycle** triggered on `auth.signOut()`, family switching, or device pairing revocation.

---

## 6. User-Visible Async Flows & Failure/Retry UX Audit

The mobile application contains 15 primary asynchronous user flows. Their current resilience is cataloged below:

| # | User Flow | Loading State | Offline State | Timeout / Error State | Retry UX Available? |
|---|---|---|---|---|---|
| 1 | **Adult Magic Link Sign-In** | Spinner | Unhandled error | Technical message | Re-enter email |
| 2 | **Family Creation** | Spinner | Leaks raw exception | Generic error snackbar | Re-submit form |
| 3 | **Child Profile Creation** | Spinner | Leaks raw exception | Generic error snackbar | Re-submit form |
| 4 | **Child Device Pairing** | Spinner | Leaks raw exception | Raw error text | Re-enter code |
| 5 | **Assessment Draft Save** | None (instant) | **Survives** (local SQLite) | Unhandled SQLite error | Auto-saved |
| 6 | **Evidence Image Upload** | Inline progress | Fails; deletes remote | Generic upload error | Re-select file |
| 7 | **Assessment Submit** | Full-screen barrier | Friendly offline message | Maps error codes | Tap submit again |
| 8 | **Parent Verify / Reject** | Action spinner | Leaks Postgrest error | Raw exception string | Pull to refresh |
| 9 | **Growth Engine Delivery** | Handled in verify | Server-side trigger | Transaction rollback | Auto on verify |
| 10 | **Learning Catch-Up** | Non-blocking | Background worker | Silent catch block | Silent retry |
| 11 | **Reward Store Redemption** | Dialog spinner | Journaled; raw error | Raw exception text | Tap redeem again |
| 12 | **Celebration Wheel Spin** | Spin animation | Journaled; retry banner | **Dedicated retry banner** | **Actionable Banner** |
| 13 | **Reward Fulfillment** | Inbox spinner | Journaled; raw error | Raw exception text | Tap fulfill again |
| 14 | **Learning Overview Read** | Shimmer / loader | Leaks raw exception | Raw exception text | None (re-navigate) |
| 15 | **Next Challenge Generation** | Embedded spinner | Leaks raw exception | Raw exception text | None (re-navigate) |

### 6.1 Critical UX Gap
Only `ChildWheelScreen` provides an explicit, actionable retry banner for pending/interrupted operations. Screens like `ChildStoreScreen`, `LearningOverviewScreen`, and `ReviewAssessmentScreen` directly render `e.toString()`.
- **Readiness Requirement:** Introduce reusable failure/retry presentation primitives in `learnward_design_system` (e.g., `AppErrorStateWidget`, `AppOfflineBanner`, `RetryActionCard`).

---

## 7. Evidence & Media Reliability Audit

### 7.1 Existing Capture & Storage Path
1. Child selects photo via `image_picker` (Camera or Gallery) in `AddAssessmentScreen`.
2. Image bytes validated: max 10 MiB, format `image/jpeg` or `image/png`.
3. Object uploaded to private Supabase Storage bucket `assessment-evidence` at path:
   `{family_id}/{child_id}/{assessment_id}/{evidence_id}.{ext}`
4. Evidence registered via `public.register_assessment_evidence` RPC.
5. If registration RPC fails, `UploadAssessmentEvidence` invokes compensation cleanup to delete the storage object.

### 7.2 Storage Failure Scenarios & Edge Cases
- **Upload Succeeded, Response Lost:** Storage object exists, but client times out. Draft retains `localPhotoPath`. On retry, upload generates a new `evidence_id`, leaving an orphaned storage asset.
- **Draft Deleted While Upload In-Flight:** Server RLS fails closed (storage upload requires assessment in `draft` status).
- **Missing Platform Permissions:** `apps/mobile/ios/Runner/Info.plist` currently lacks `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription`. On iOS, launching the camera or photo gallery crashes the application immediately.
- **Readiness Requirement:** 
  1. Add required permission strings to `Info.plist`.
  2. Implement an idempotent evidence upload resumption protocol that verifies remote object existence before re-uploading.

---

## 8. Push Notification Architecture & Guardrails Audit

### 8.1 Approved Pilot Use Cases
Per `docs/08-mobile-architecture-v0.1.md` Section 13, notifications must support family coordination, not engagement farming:
1. **Parent Approval Required:** Triggered when a child submits an assessment (`assessments.status = 'pending_review'`).
2. **Reward Fulfilled:** Triggered when a parent marks a redemption fulfilled (`reward_redemptions.status = 'fulfilled'`).
3. **Optional Learner Reminder:** Self-selected goal reminder (if goals implemented) or promise date approaching.

### 8.2 Strict Product Anti-Patterns & Invariants
> [!CAUTION]
> **Product Invariant:** No notification may optimize generic engagement.
> Forbidden notification types:
> - Artificial urgency ("Your streak is in danger!")
> - Guilt / emotional manipulation ("Your wheel misses you!")
> - Random re-engagement spam ("Check out what's new in LearnWard!")
> - Competitive taunts between siblings

Notification clicks or app opens are **never** counted as learning progress (VLPE).

### 8.3 Technical Deficiencies
- Zero push notification packages exist in `apps/mobile/pubspec.yaml`.
- No database tables exist to store device push tokens (`fcm_tokens` / `apns_tokens`).
- No token rotation or multi-device fan-out mechanism exists.
- **Readiness Requirement:** Phase 6 detailed design must specify a provider-agnostic notification service port, token registration table with family/child foreign keys, and deep-link routing definitions.

---

## 9. Metric Instrumentation & Telemetry Audit

### 9.1 North Star Metric: VLPE
**Verified Learning Progress Events / Active Child / Week (VLPE)**
Source of truth: `docs/06-metrics-and-hypotheses.md`.
A VLPE requires: Real learning activity + Trusted evidence + Growth Engine update + Progress/mastery contribution.

### 9.2 Authoritative Database Derivability Analysis

| # | Metric from `docs/06` | Classification | Authoritative Source / Derivation Method |
|---|---|---|---|
| 1 | **VLPE / child / week** | `DERIVABLE FROM AUTHORITATIVE DB` | `COUNT(*) FROM public.verified_learning_events WHERE child_id = :id AND verified_at >= :start AND verified_at < :end` |
| 2 | **Results logged / child / week** | `DERIVABLE FROM AUTHORITATIVE DB` | `COUNT(*) FROM public.assessments WHERE child_id = :id AND created_at >= :start AND created_at < :end` |
| 3 | **% results logged by child** | `DERIVABLE FROM AUTHORITATIVE DB` | `COUNT(entry_context IN ('shared_child', 'paired_child')) / COUNT(*)` from `assessments` |
| 4 | **% goals chosen by child** | `NEEDS NEW PRODUCT INPUT` | Goals entity not implemented in Phases 1–5; requires Phase 6 goal or deferred |
| 5 | **4-week subject trend** | `DERIVABLE FROM AUTHORITATIVE DB` | Grouped `verified_learning_events` score trajectory by `subject_key` over 28 days |
| 6 | **Recovery completion rate** | `DERIVABLE FROM AUTHORITATIVE DB` | Replayed weak observations in `learning_evidence_events` reaching $\ge 70\%$ within 30 days |
| 7 | **Personal-best frequency** | `DERIVABLE FROM AUTHORITATIVE DB` | `growth_events.is_personal_best` flag or historical score comparison |
| 8 | **Parent approval latency** | `DERIVABLE FROM AUTHORITATIVE DB` | `EXTRACT(EPOCH FROM (vle.verified_at - a.created_at))` |
| 9 | **Parent admin minutes/day** | `NOT CURRENTLY MEASURABLE` | Requires client UI screen session timing or weekly qualitative pilot survey |
| 10 | **Reward fulfillment rate** | `DERIVABLE FROM AUTHORITATIVE DB` | `COUNT(status = 'fulfilled') / COUNT(status IN ('fulfilled', 'cancelled', 'pending_fulfillment'))` |
| 11 | **RP earned / week** | `DERIVABLE FROM AUTHORITATIVE DB` | `SUM(amount_minor) FROM public.rp_ledger WHERE amount_minor > 0` |
| 12 | **RP spent / week** | `DERIVABLE FROM AUTHORITATIVE DB` | `ABS(SUM(amount_minor)) FROM public.rp_ledger WHERE amount_minor < 0` |
| 13 | **Wheel vs Store spend share** | `DERIVABLE FROM AUTHORITATIVE DB` | `SUM(wheel_spins.spin_cost_minor)` vs. `SUM(reward_redemptions.cost_minor)` |
| 14 | **Self-chosen challenge rate** | `NEEDS NEW EVENT` | Requires tracking when an assessment is launched directly from a Next Challenge card |
| 15 | **Week 4 / Week 8 retention** | `DERIVABLE FROM AUTHORITATIVE DB` | Children with $\ge 1$ VLPE in week 4 and week 8 |
| 16 | **Parent study reminders / week** | `NEEDS NEW PRODUCT INPUT` | Parent Intervention Rate baseline vs. weekly qualitative check-in |

---

## 10. Analytics Privacy Contract & Minimum Safe Envelope

### 10.1 Principle of Data Minimization
`docs/10-implementation-plan-v0.1.md` Section 21 explicitly mandates:
> **"Do not begin with a large analytics platform."**

### 10.2 Minimum Safe Telemetry Envelope
Telemetry events sent from the mobile client must adhere to this strict schema:
```json
{
  "event_name": "next_challenge_tapped",
  "occurred_at": "2026-11-03T12:00:00Z",
  "family_pseudonym": "f_a8b9c0d1",
  "child_pseudonym": "c_e2f3g4h5",
  "app_version": "0.1.0+1",
  "platform": "android",
  "metadata": {
    "recommendation_reason": "developing",
    "subject_key": "math",
    "difficulty": "normal"
  }
}
```

### 10.3 Forbidden Telemetry Fields
Under no circumstances may client telemetry or third-party SDK payloads contain:
- Child's real name or nickname
- Parent's real name or email address
- School name or geographic location
- Raw photographic evidence, URLs, or storage paths
- Assessment titles or free-form user notes
- PIN codes, password hashes, or session tokens

---

## 11. Pilot Hypothesis Coverage (H1–H8) & Guardrail Monitoring

| Hypothesis | Quantitative Evidence (Telemetry / DB) | Qualitative Evidence Required | Cannot Be Inferred from Telemetry |
|---|---|---|---|
| **H1 — Progress Visibility** | Repeat VLPE rate after high baseline; Next Challenge engagement | Child spontaneous comments during study | Whether learner felt encouraged vs. pressured |
| **H2 — Growth-Aware Fairness** | VLPE consistency among children starting below 50% baseline | Parent survey on perceived fairness across siblings | Subjective feelings of resentment or parity |
| **H3 — Learner Autonomy** | Ratio of child-initiated drafts (`entry_context = 'shared_child'`) | Parent observation of study prompting frequency | Whether child initiated study without verbal cues |
| **H4 — Wheel vs. Store** | Spend ratio between `wheel_spins` and `reward_redemptions` | Child explanation of why they saved vs. spun | Delayed gratification cognitive intent |
| **H5 — Verification Friction** | Approval latency (`verified_at - created_at`); review event timestamps | Parent interview on approval fatigue | Household negotiation friction |
| **H6 — Reward Fulfillment Trust** | Fulfillment rate ($> 90\%$ target); cancellation rate | Child trust expressions during interview | Disappointment over delayed offline promises |
| **H7 — Novelty Resistance** | Weeks 3–4 VLPE trend vs. Week 1 spin frequency | Child interest in mastery badges after 3 weeks | Intrinsic motivation maturation |
| **H8 — External-Learning Advantage**| Variety of assessment types (`quiz`, `test`, `homework`, `practice`) | Parent satisfaction with multi-source logging | Tutor / teacher direct perception |

### 11.1 Guardrail Monitoring
The pilot must track telemetry guardrails to detect failure modes:
1. **Reward Dependency:** Refusal to study unless RP is attached (measured by parent weekly check-in).
2. **Farming:** Repeated below-level entries or rapid submission spam (detected via assessment submission frequency filters).
3. **Parent Burden:** Accumulation of $> 10$ pending reviews or $> 7$ days approval latency.
4. **Excessive Screen Time:** Client session duration exceeding 15 minutes per day for child mode.

---

## 12. Privacy & Data-Retention Audit

The repository handles 16 distinct data classes. Their pilot retention characteristics are summarized below:

| # | Data Class | Source of Truth | PII Level | Pilot Retention Policy | Deletion / Cleanup Behavior |
|---|---|---|---|---|---|
| 1 | **Auth Users** | Supabase Auth (`auth.users`) | High (Email) | Active during pilot | Managed via Supabase Auth Admin |
| 2 | **Family Tenancy** | `public.families` | Low (UUID) | Active during pilot | Cascade deletes memberships and children |
| 3 | **Child Profiles** | `public.child_profiles` | Medium (Name, Grade) | Active during pilot | Parent archives (`status = 'archived'`) |
| 4 | **Child Device Grants** | `public.child_device_grants` | Medium (Device secret) | Active during pilot | Parent revokes (`status = 'revoked'`) |
| 5 | **Assessment Drafts/Records** | `public.assessments` | Low (Metadata, scores) | 4 weeks pilot duration | Hard-delete allowed in `draft`; terminal in `verified` |
| 6 | **Evidence Images** | Storage `assessment-evidence` | High (Schoolwork photos) | 4 weeks pilot duration | Delete on draft cancel; parent retention delete |
| 7 | **Verified Learning Events** | `public.verified_learning_events` | Low (Immutable event) | Permanent audit trail | Immutable trigger blocks SQL DELETE |
| 8 | **Learning Evidence** | `public.learning_evidence_events` | Low (Mastery atom) | Permanent audit trail | Immutable trigger blocks SQL DELETE |
| 9 | **Mastery Projections** | `public.child_mastery_states` | None (Academic scores) | Rebuilt on demand | Upserted; cleared if child profile deleted |
| 10 | **XP/RP Ledgers** | `public.xp_ledger`, `rp_ledger` | None (Integer units) | Permanent audit trail | Immutable trigger blocks SQL DELETE |
| 11 | **Balance Projections** | `public.child_balances` | None (Integer units) | Permanent projection | Reconciled via `reconcile_child_balance` |
| 12 | **Reward Redemptions** | `public.reward_redemptions` | Low (Reward title) | Permanent audit trail | Status lifecycle (`pending -> fulfilled/cancelled`) |
| 13 | **Wheel Spins** | `public.wheel_spins` | Low (Snapshot) | Permanent audit trail | Immutable audit records |
| 14 | **Command Receipts** | `private.command_receipts` | None (Idempotency hashes) | 60-day operational TTL | Cleanup via server cron or maintenance |
| 15 | **Local SQLite Cache** | Device `app_database.sqlite` | Medium (Drafts, cache) | Client lifecycle | Cleared on sign-out / app data wipe |
| 16 | **Crash Logs & Telemetry** | Client memory / console | Low (Non-sensitive) | Operational debugging | Ephemeral; no PII |

---

## 13. Architectural Tension: Right to Erasure vs. Immutable Ledgers

### 13.1 The Conflict
In Phases 1–5, the database schema deliberately introduced unconditional immutability triggers:
```sql
create trigger trg_verified_learning_events_immutable
before update or delete on public.verified_learning_events
for each row execute function private.prevent_row_mutation();
```
Identical triggers guard `public.xp_ledger`, `public.rp_ledger`, `public.learning_evidence_events`, and `public.mastery_state_revisions`.
Furthermore, foreign keys enforce `ON DELETE RESTRICT` (e.g., `growth_events.verified_learning_event_id`).

If a pilot parent exercises a privacy request ("Delete my family and child's data completely"), executing `DELETE FROM public.families WHERE id = :id` will fail with error `LW102 (immutable row cannot be deleted)`.

### 13.2 Evaluated Resolution Strategies

| Approach | Mechanism | Pros | Cons / Contract Impact |
|---|---|---|---|
| **A. Hard Cascade Deletion** | Disable triggers or add bypass flag for owner deletion | Complete physical removal | Violates frozen append-only invariants; breaks auditability |
| **B. Pseudonymization / Scrubbing** | Redact names, emails, photos, and free text; retain numeric ledger rows | Preserves economic math and statistical trends | Retains orphaned rows; requires complex scrub routines |
| **C. Soft-Delete Tombstoning** | Set `status = 'archived'/'deleted'`; revoke RLS access; expire via retention job | Zero schema changes to frozen tables; fails closed | Data remains on disk until end-of-life purge |
| **D. Dedicated Tenant Purge RPC** | `SECURITY DEFINER` function with administrative override that purges in topological order | Controlled, audited, explicit deletion | Requires elevated database privileges and additive migration |

### 13.3 Readiness Recommendation
This tension **must be resolved during Phase 6 detailed design**. The pilot must not launch without an agreed deletion procedure. Strategy C (soft-delete archiving for users with a scheduled administrative purge protocol) is the recommended starting proposal for detailed design.

---

## 14. Local Data Cleanup & Isolation Audit

### 14.1 Identified Vulnerabilities
1. **Sign-Out Leakage:** Calling `client.auth.signOut()` clears the in-memory Supabase session, but leaves SQLite files (`app_database.sqlite`) and local photos untouched.
2. **Device Grant Revocation:** A parent revoking a dedicated child device on the server leaves the child's local device holding cached drafts and pending commands.
3. **Shared Device Child PIN Reset:** If a parent forgets their PIN, there is no safe local recovery mechanism without re-authenticating online.

### 14.2 Readiness Requirement
Phase 6 detailed design must specify a **Local Security Boundary Handler**:
- On `auth.onAuthStateChange` emitting `signedOut`, execute `AppDatabase.clearAllTables()`.
- On child mode unpairing or grant revocation (`42501`), purge local drafts and pending commands for that child ID.

---

## 15. Accessibility Readiness Audit

A thorough audit of `learnward_design_system` and `apps/mobile/lib/features/` reveals:

1. **Semantics:** Exactly **0** `Semantics` widgets exist across the entire Flutter codebase. Interactive custom cards, progress bars, and chips lack screen-reader labels.
2. **Dynamic Font Scaling:** Multiple screens use fixed-height containers (e.g., `SizedBox(height: 48)`) that will cause layout overflows when users enable large accessibility font sizes (e.g., 150%–200%).
3. **Touch Targets:** Some action chips and icon buttons in `learning_overview_screen.dart` and `next_challenge_section.dart` measure below the recommended minimum $48 \times 48\text{ dp}$ bounding box.
4. **Color-Only Status Indicators:** Mastery bands (`mastered`, `secure`, `developing`, `emerging`) and freshness states rely heavily on background colors. Text labels exist on most badges, but high-contrast border differentiation is missing.
5. **Screen Reader Live Regions:** Critical asynchronous events (wheel spin winning result, assessment submission success, error snackbars) lack semantic announcements (`SemanticsService.announce`).

---

## 16. Motion & Celebration Wheel Accessibility Safety

### 16.1 Reduced Motion Invariant
`child_wheel_screen.dart` contains a 4-second continuous rotation animation using `AnimationController`. Users with vestibular disorders or motion sensitivity have no mechanism to bypass or shorten this motion.

### 16.2 Mandatory Invariant
> [!IMPORTANT]
> **Accessibility / Motion Invariant:**
> Enabling reduced motion (`MediaQuery.disableAnimationsOf(context)` or system accessibility setting) may alter visual presentation only.
> It must produce the **exact same server-authoritative result**, consume the **same RP cost**, apply the **same daily cap**, and grant the **same positive reward**. Under no circumstances may an accessibility setting influence the random tier selection or outcome.

---

## 17. Android & iOS Distribution Readiness Audit

### 17.1 Android Distribution Readiness
- `applicationId`: `com.learnward.app` (configured in `apps/mobile/android/app/build.gradle.kts`).
- `minSdk`: Flutter default (21); `targetSdk`: Flutter default (34).
- **Blocker:** `build.gradle.kts` currently specifies:
  ```kotlin
  signingConfig = signingConfigs.getByName("debug")
  ```
  for release builds. No release keystore, key alias, or environment variable configuration exists.
- **Blocker:** Missing Google Play Console service account integration for closed testing track automation.

### 17.2 iOS & TestFlight Readiness
- `CFBundleIdentifier`: `com.learnward.app` (configured in `apps/mobile/ios/Runner/Info.plist`).
- **Blocker:** `Info.plist` lacks `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription`. Attempting to capture evidence on a physical iPhone will crash.
- **Blocker:** Missing Apple Developer Team ID, distribution provisioning profiles, and App Store Connect API keys for automated TestFlight deployment.

---

## 18. Multi-Environment Configuration & Secret Management

### 18.1 Current State
- The app uses compile-time environment variables injected via `--dart-define-from-file=dart_defines.json`.
- `dart_defines.example.json` documents `APP_ENV`, `SUPABASE_URL`, and `SUPABASE_PUBLISHABLE_KEY`.
- In `development` mode, demo in-memory repositories can be enabled. `staging` and `production` fail closed if required credentials are missing.

### 18.2 Pilot Requirement
- The pilot requires a **dedicated staging/pilot Supabase instance**, completely separated from development and production.
- CI/CD secrets (keystore base64, Apple distribution certificates, Supabase pilot URL) must be managed via GitHub Actions repository secrets and never checked into source control.

---

## 19. Staging Migration & Deployment Readiness

### 19.1 CI Database Verification
Current repository CI runs `supabase start`, applies all 8 migration files in sequence, and executes 438 pgTAP assertions. This validates schema validity on local Docker instances.

### 19.2 Missing Staging Gates
1. No automated migration script exists to apply migrations to a remote Supabase staging project (`supabase db push`).
2. No data verification smoke test exists to confirm that published catalog seeds (`pilot-v0.1`) and initial subject roots are intact after remote deployment.
3. No automated schema drift check exists between local migrations and the remote staging database.

---

## 20. Real-Device Validation Matrix

The 4-week pilot requires a rigorous physical device validation matrix before distributing builds to families:

| Test Case | Android Real Device | iPhone Real Device | Automated vs. Manual |
|---|---|---|---|
| **Camera Photo Capture** | Physical camera hardware | Physical camera hardware | Manual (requires hardware) |
| **Gallery Image Picker** | Photo picker intent | Photo library sheet | Manual (requires hardware) |
| **Network Disconnect & Reconnect** | Toggle Airplane Mode | Toggle Airplane Mode | Manual |
| **App Kill & Restart with Draft** | Force-stop app in recents | Swipe up in app switcher | Manual |
| **Interrupted Wheel Spin Replay** | Kill app during 4s spin | Kill app during 4s spin | Manual + Automated unit test |
| **Magic Link Deep Link Callback** | Email client redirect | Mail app redirect | Manual |
| **Parent PIN Containment** | Child mode exit attempt | Child mode exit attempt | Automated widget + Manual |
| **Font Scaling (200% dynamic type)**| System font size: Largest | Dynamic Type: Accessibility | Manual visual audit |
| **Screen Reader Navigation** | TalkBack enabled | VoiceOver enabled | Manual audio audit |
| **Reduced Motion Preference** | Remove animations enabled | Reduce Motion enabled | Manual visual audit |
| **Small vs. Large Screens** | Compact phone (< 360dp) | Large tablet / Plus iPhone | Automated golden + Manual |

---

## 21. Operational Resilience & Pilot Diagnostics

To satisfy the exit gate ("A small family pilot can run for four weeks without engineering intervention"), the application must be supportable when issues arise:

### 21.1 Support Diagnostics Screen
Phase 6 should introduce a hidden or parent-accessible **Diagnostic Info Card** showing:
- App build version and commit SHA (`0.1.0+1`)
- Active environment (`APP_ENV`)
- Local SQLite database version (`schemaVersion = 4`)
- Unsent draft count and pending command journal count
- Network connectivity status and last successful sync timestamp
- Non-sensitive diagnostic correlation ID for bug reporting

### 21.2 Logging Rules
- Application logs must use structured logging with correlation IDs.
- Never log raw photographic bytes, child names, parent emails, or authentication tokens.

---

## 22. App & Schema Version Compatibility

### 22.1 Client Upgrades During Pilot
If an updated client build (v0.1.1) is pushed to TestFlight or Google Play during the 4-week pilot:
1. **Local Drift Database:** Drift's `MigrationStrategy` handles schema upgrades incrementally. However, destructive column drops must be forbidden during pilot updates.
2. **Queued Commands:** If a user has a pending reward command queued in SQLite from v0.1.0 and upgrades to v0.1.1, the payload must remain deserializable.
3. **Payload Versioning Requirement:** Add `schema_version` (integer) to `PendingRewardCommands` and any future outbox tables.

---

## 23. Frozen-System Regression Obligations

Phase 6 pilot hardening touches cross-cutting concerns (offline, UI, release, security). It must explicitly guarantee that all frozen invariants from Phases 1–5 remain intact:

- [x] **Family Tenancy Boundary:** Cross-family access strictly blocked (`42501`). Sibling device isolation enforced.
- [x] **Assessment State Machine:** Score normalization via generated column; terminal state locking on `verified`/`rejected`.
- [x] **Evidence Immutability:** Append-only triggers on `verified_learning_events` and `learning_evidence_events` cannot be bypassed.
- [x] **Growth Engine Idempotency:** Exactly-once event processing via advisory locks and command receipts.
- [x] **RP/XP Ledger Invariants:** Integer minor units; dual append-only ledgers; single-snapshot balance reconciliation.
- [x] **Reward Store & Wheel Safety:** Server-authoritative RPCs; non-losing spins; local calendar day spin caps; truth-in-probabilities.
- [x] **Mastery & Confidence Engine:** EWMA calculations; 60-day rolling confidence window; sticky `mastery_attained_at`.
- [x] **Next Challenge Recommendation:** Mutually exclusive five-class partition (`Recovery > Refresh > Developing > Unlock > Explore`); positive developing qualification (`freshness IN ('recent', 'aging')`); deterministic tie-breaking.
- [x] **Economy Independence:** Recommendations, mastery reads, and offline capture remain completely decoupled from XP/RP balance mutation.

---

## 24. Carried-Forward Technical Debt Table

| Item | Originating Phase / Source | Still Applicable? | Required for Pilot? | Justification / Impact |
|---|---|---|---|---|
| **Actor-Aware Pending Command Journaling** | Phase 4 Freeze §13.1, Phase 4 Design §20 | **Yes** | **Yes** | Prevents caller mismatch errors when adult identity changes on shared device |
| **iOS Camera / Photo Permission Strings** | Phase 2 Audit | **Yes** | **Yes** | App crashes immediately on iOS without `Info.plist` usage descriptions |
| **Local Database Cleanup on Sign-Out** | Phase 1 Security Review | **Yes** | **Yes** | Prevents PII and drafts from lingering on shared or unlinked devices |
| **Android Release Keystore & Signing** | Phase 4 Freeze §13.5 | **Yes** | **Yes** | Cannot upload debug-signed APK to Google Play internal testing track |
| **Family-Scoped Catalog Stabilization Lock** | Phase 4 Freeze §13.2 | **Yes** | **No** | Global `LOCK TABLE rewards IN SHARE MODE` is harmless at pilot scale (< 50 families) |
| **Resource-Existence Confidentiality** | Phase 4 Freeze §13.3 | **Yes** | **No** | Distinguishing `P0002` from `42501` does not pose a threat in a closed trusted pilot |
| **Exact-Timestamp Growth Comparator Tie** | Phase 3 Backlog | **Yes** | **No** | Microsecond tie-break in rolling baseline occurs with negligible probability |
| **Unseen Skill Prerequisite DAG at Scale** | Phase 5.2 Design §4.4 | **Yes** | **No** | Pilot catalog has 12 nodes and 1 prerequisite edge; scale optimizations deferred |

---

## 25. Recommended Phase 6 Decomposition (Readiness Recommendation)

Phase 6 encompasses a substantial surface area (resilience, UX, push notifications, metrics, privacy, accessibility, and two mobile distribution pipelines). Attempting to deliver all of these in a single monolithic pull request creates extreme review risk.

### Recommended 3-Slice Decomposition:
```text
Phase 6.1 — Reliability, Offline Outbox, Actor Recovery & Failure UX
Phase 6.2 — Pilot Notifications, Telemetry Instrumentation & Privacy Controls
Phase 6.3 — Accessibility Pass, Distribution Hardening (Android/iOS) & Pilot Operations
```

- **Phase 6.1 Focus:** Make the app unbreakably stable under poor connectivity, app kills, and identity changes.
- **Phase 6.2 Focus:** Enable family coordination (approvals/fulfillment) and metric tracking without violating child privacy.
- **Phase 6.3 Focus:** Ensure the app is accessible to all learners, signed, packaged, and distributed to physical devices via TestFlight and Google Play.

> *Note: This decomposition is a readiness recommendation for planning. It does not create official phases until approved via detailed design.*

---

## 26. Blocker & Risk Matrix

| ID | Area | Severity | Current State | Required Decision | Affected Frozen Contracts | Implementation Dependency | Proceed in Parallel? |
|---|---|---|---|---|---|---|---|
| **B1** | **iOS Permissions** | `HIGH` | Missing `NSCameraUsageDescription` / photo strings | Exact user-facing explanation copy | None (iOS config only) | Image picker | Yes |
| **B2** | **Android Signing** | `HIGH` | Debug keys used for release build | Keystore generation and CI secret strategy | None (build config only) | Gradle build | Yes |
| **B3** | **Actor Recovery** | `HIGH` | Commands lack actor binding; replay can fail | Schema addition of `actor_user_id` + eviction | `PendingRewardCommands` Drift schema | Command store | No (blocks 6.1) |
| **B4** | **Ledger Deletion Tension** | `HIGH` | Immutable triggers block parent right-to-erasure | Adopt Soft-Delete Tombstoning / Purge RPC | `verified_learning_events`, ledgers | RLS / Admin RPC | No (blocks 6.2) |
| **B5** | **Local Cache Cleanup** | `MEDIUM`| SQLite persists across logout/unpair | Wipe database on sign-out transition | `AppDatabase` lifecycle | Auth listener | Yes |
| **B6** | **Notification Engine** | `HIGH` | Zero push packages or schema tables | Provider selection (FCM/APNs) & token schema | New additive table only | Push SDK | No (blocks 6.2) |
| **B7** | **Failure UX Polish** | `MEDIUM`| Raw exceptions rendered on store/overview screens | Implement design system error/retry components | Mobile UI screens | Design system | Yes |
| **B8** | **Accessibility Semantics**| `MEDIUM`| Zero Semantics widgets; no reduced motion check | Add Semantics labels & instant wheel reveal | Mobile presentation | Design system | Yes |

### Readiness Verdict
**PASS FOR DETAILED DESIGN.**
There are **zero BLOCKER-level dependencies** preventing the creation of the Phase 6 detailed design document and ADR. The `HIGH` items above represent well-defined design choices to be formally resolved in the detailed design phase.
Phase 6 implementation remains **NOT AUTHORIZED / NOT STARTED**.

---

## 27. Explicit Architectural Questions for Phase 6 Detailed Design

The future Phase 6 detailed design document and ADR must answer the following questions:

1. **Offline Outbox Architecture:** Should assessment submissions use an extended `LocalAssessmentDrafts` status lifecycle (`draft -> uploading -> submitting`) or a dedicated generic `PendingOperations` table?
2. **Actor Binding Contract:** What exact columns will be added to local command journals to represent `actor_user_id` and `actor_role`, and what is the exact client-side eviction logic on auth state change?
3. **Data Deletion Protocol:** How will family deletion requests be executed without violating the immutable database triggers on `verified_learning_events` and economic ledgers?
4. **Local Data Purge Lifecycle:** Exactly which local files, SQLite tables, and secure storage keys must be purged when a user signs out or a child device grant is revoked?
5. **Notification Provider & Token Schema:** Which push provider (e.g., Firebase Cloud Messaging vs. Supabase Edge Functions / APNs) will be integrated, and what is the schema of the device token table?
6. **Notification Deep-Link Routing:** How will incoming notification payloads safely navigate to `ReviewAssessmentScreen` or `ChildRedemptionHistoryScreen` when the app is backgrounded or killed?
7. **Client Telemetry Port:** How will the client record self-chosen challenge selections and screen timing without transmitting PII or relying on heavy third-party SDKs?
8. **Accessibility Standards:** What exact semantic labels, live announcements, and touch target adjustments are required for child mode and celebration wheel screens?
9. **Reduced Motion Wheel Reveal:** How will `ChildWheelScreen` detect reduced motion preferences and render an instantaneous, celebratory result while preserving server-authoritative outcomes?
10. **Release Pipeline Secrets:** How will Android upload keystores, Google Play service accounts, and Apple App Store Connect API keys be securely stored and injected in GitHub Actions?
11. **Diagnostic Card Surface:** Where and how will pilot diagnostic information (app version, pending command count, sync status) be exposed to parents and pilot administrators?
