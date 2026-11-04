# ADR 0008 — Phase 6 Pilot Hardening Decisions

- **Status:** PROPOSED
- **Date:** 2026-11-04
- **Target:** Phase 6 — Pilot Hardening
- **Reviewed Baseline:** `main` @ `462a17e603b69456b9eb2e000cfa7a7424e0c719`
- **Upstream Contracts:**
  - [ADR 0001 — Engineering Foundation](0001-phase-0-foundation-decisions.md) (`ACCEPTED`)
  - [ADR 0002 — Family & Child Identity](0002-phase-1-family-child-identity.md) (`ACCEPTED`)
  - [ADR 0003 — Secure Assessment Capture](0003-phase-2-secure-assessment-capture.md) (`ACCEPTED`)
  - [ADR 0004 — Growth Engine & Ledgers](0004-phase-3-growth-engine-ledger.md) (`ACCEPTED`)
  - [ADR 0005 — Reward Economy & Wheel](0005-phase-4-reward-economy-wheel.md) (`ACCEPTED`)
  - [ADR 0006 — Learning Engine & Mastery](0006-phase-5-learning-engine-mastery.md) (`ACCEPTED`)
  - [ADR 0007 — Skill Graph & Recommendations](0007-phase-5-2-skill-graph-recommendation.md) (`ACCEPTED`)
- **Readiness Review:** [Phase 6 Dependency & Readiness Review](../16-phase-6-pilot-hardening-dependency-readiness-review.md) (`FROZEN`)
- **Metrics Contract:** [Metrics & Hypotheses v0.1](../06-metrics-and-hypotheses.md) (`FROZEN`)
- **Detailed Design Document:** [Phase 6 Detailed Design v0.1](../17-phase-6-pilot-hardening-design-v0.1.md)

This ADR is **`PROPOSED`**. Implementation remains **NOT AUTHORIZED** until this detailed design passes independent audit and merge review.

---

## Context

Phases 1 through 5 established the complete core learning and economic engine of LearnWard: family identity, secure assessment capture, integer append-only economic ledgers, guaranteed reward store, celebration wheel, EWMA mastery engine, and the 5-class Next Challenge recommendation model.

Phase 6 provides the operational, reliability, accessibility, and release hardening necessary to execute a successful 4-week closed family pilot without engineering intervention. Following the authoritative findings of the [Phase 6 Readiness Review](../16-phase-6-pilot-hardening-dependency-readiness-review.md), the frozen [Metrics Contract](../06-metrics-and-hypotheses.md), and independent detailed design audits, the architectural decisions below formally resolve all identified readiness dependencies and audit findings.

---

## Decision 1 — Bounded Outboxes and Conservative Drift v4 Recovery

1. Preserve all v4 nullable columns, original command UUIDs, existing server references and local photos. Add a durable `dispatchState` to **both** v5 journals: `unknown_legacy`, `never_dispatched`, `possibly_dispatched`, `confirmed_committed`.
2. Frozen v4 has **no** dispatch marker or retry counter; the newly added default `retryCount==0` cannot prove a migrated action was never sent. All legacy network outcomes are UNKNOWN/quarantined pending exact authorized reconciliation.
3. Explicitly insert new v5 entries as `never_dispatched`; persist `possibly_dispatched` to SQLite **before** remote RPC dispatch. Crashes and lost replies are unknown until authoritative confirmation.
4. Same-ID idempotent replay requires positively verified original authenticated actor and existing RPC guards. Missing receipts and approximate matches never prove absence. Unknown actor/outcome causes a hold, **not** auto-replay, regenerated ID or an economic reissue.
5. Parent may hold, export unsynced schoolwork or abandon local copy (warning: remote effects remain). Required migration tests use populated v4 databases and prove no data loss, no automatic replay and no double debit/spin/submission.

---


## Decision 2 — Per-Data-Class Local Security, Positive Revocation Proof & Authoritative RPC Replay

A blanket `clearAllTables()` wipe on sign-out is rejected because it destroys device-level security containment. Local data classes are governed by explicit lifecycle policies:
- **Parent PIN Hash & Salt:** Retained across adult logout to ensure device containment remains locked if the device is shared with children.
- **Active Child Session:** Immediately purged on sign-out, family switch, or Child Mode exit.
- **Assessment Drafts & Pending Commands:** Segregated by `family_id` and `actor_user_id`. State normalized to `pending_original_actor`.
- **Positive Revocation Proof & Error Disambiguation (`42501`):** PostgreSQL code `42501` (`insufficient_privilege`) is NOT treated as a blanket signal for device revocation. The client differentiates:
  1. *Caller mismatch:* Current authenticated user is not authorized for the row or operation. Action: pause command execution in `pending_original_actor` state.
  2. *Positive device grant revocation:* Revocation is confirmed ONLY upon positive proof from `public.child_device_grants` (`status = 'revoked'` AND `revoked_at IS NOT NULL`). A failed query or general `42501` does not infer revocation. When confirmed, active child session is cleared, but local drafts are preserved in quarantine for parental recovery.
  3. *General permission denied:* Action: mark command `failed_terminal` with actionable user diagnostic.
- **Authoritative Idempotent Server RPC Replay Contracts:**
  - Because `public.command_receipts` is restricted by RLS to active family adults (`private.is_active_family_adult(family_id)`), paired-child devices cannot select from `command_receipts`.
  - Authoritative recovery across all actor classes (adults, shared children, paired children) relies on the server's built-in idempotent RPC replay contracts (`SECURITY DEFINER` RPCs taking `p_command_id`). Replaying the mutation RPC with the exact same `p_command_id` safely retrieves the existing committed outcome without duplicating ledger debits or spins.
  - **Post-Archive Replay & Command Quarantine (Explicit Deferral):** When a target child profile is archived, server mutation RPCs fail closed with `42501` (`Child profile is archived`). Dedicated post-archive read-only command reconciliation RPCs are **explicitly deferred** post-pilot. Local outbox commands for archived children transition to `quarantined_unknown_outcome` and remain safely preserved in local SQLite without automated retry. Historical review is provided via `export_family_data_json`.

---

## Decision 3 — Byte-Verified Private Evidence Storage

1. Compress once and persist stable JPEG bytes, SHA-256, client UUID, separate authoritative evidence-row UUID and path across restarts.
2. Upload via Dart `uploadBinary` with `upsert:false`. After HTTP 409 or response loss, `storage.list()` custom metadata and matching size **do not prove equality** ([Supabase Storage #759](https://github.com/supabase/storage/issues/759)).
3. Download remote bytes as the authorized actor; matching SHA-256 and size verifies Storage content but **not** database registration. Frozen `register_assessment_evidence` requires assessment status `draft` **before** its same-path idempotency lookup. On lost registration response, query exact authorized assessment/evidence rows: if matching row exists, reconcile its server ID without mutation even after submission; if no row is visible and assessment is not draft, enter `registration_unresolved` without retrying registration or changing UUID. Unknown/hidden rows never prove absence. Digest mismatch remains `evidence_conflict`, unreadable object `verification_pending`.
4. Test same-size/different-bytes, missing metadata, committed registration/response lost/concurrent submit, uncommitted registration followed by submit, non-draft/archived/hidden evidence and restart. Never mutate terminal assessments or bypass private RLS with client service-role credentials.

---


## Decision 4 — In-App Coordination Notifications & Authoritative Query Reconciliation

For the 4-week pilot:
1. Notifications support family coordination only (pending parent review, reward fulfilled). Engagement farming (streaks, guilt, sibling taunts) is strictly prohibited.
2. In-app realtime notifications via Supabase Realtime provide immediate UI updates. However, because Realtime connections are transient, parent inbox badges and child review states must be backed by authoritative PostgreSQL queries on app launch, resume, and network reconnection.
3. Coordination badges clear naturally upon underlying PostgreSQL state transitions (`verified`, `rejected`, `fulfilled`); `markRead(eventId)` is omitted for the pilot.
4. A provider-agnostic `NotificationService` interface isolates application logic from future external push platforms (FCM/APNs), which remain deferred.
5. Deep link navigation routes through strict role authorization checks: child accounts attempting to navigate to adult review URLs are redirected to Child Mode home with an access notice.

---

## Decision 5 — Restored Canonical 16-Metric Contract & Canonical VLPE

1. **Restoration of Canonical Metric Contract:** The authoritative 16-metric inventory from [Metrics & Hypotheses v0.1](../06-metrics-and-hypotheses.md) and the Phase 6 Readiness Review is restored verbatim:
   - Exactly **12 of 16** metrics are directly derivable from PostgreSQL without third-party analytics SDKs:
     1. `VLPE / child / week`
     2. `Results logged / child / week`
     3. `% results logged by child`
     5. `4-week subject trend`
     6. `Recovery completion rate`
     7. `Personal-best frequency`
     8. `Parent approval latency`
     10. `Reward fulfillment rate`
     11. `RP earned / week`
     12. `RP spent / week`
     13. `Wheel vs Store spend share`
     15. `Week 4 / Week 8 retention`
   - Exactly **4 of 16** metrics are deferred or require client/qualitative inputs:
     4. `% goals chosen by child` (`NOT CURRENTLY MEASURABLE / DEFERRED`)
     9. `Parent admin minutes/day` (`NOT CURRENTLY MEASURABLE`)
     14. `Self-chosen challenge rate` (`NEEDS NEW CLIENT/UX EVENT`)
     16. `Parent study reminders / week` (`NEEDS NEW PRODUCT INPUT / SURVEY`)
2. **Canonical VLPE Definition:** The North Star metric **VLPE** is canonically defined as Verified Learning Progress Events per active child per calendar week, requiring that each event has completed both **Growth processing** (`public.growth_events`) and **Learning processing** (`public.learning_processing_events` with `status = 'processed'`).
3. Client UX telemetry uses a minimal, privacy-preserving envelope strictly scrubbed of child real names, parent emails, school names, geographic location, image URLs, or auth tokens.

---

## Decision 6 — Archived Child Isolation, Lifecycle Protection and Privacy Governance

1. A legal/privacy review is mandatory before external pilot families' child personal data is processed. Technical minimization is **not** proof of statutory erasure; historic immutable UUID-linked data may remain re-identifiable.
2. In new Phase 6 migrations, replace affected permissive SELECT policies without editing frozen SQL. Require `private.is_child_active_in_family(child_id,family_id)` **outside** adult/child-device authorization OR. A grant left active must never allow archived learning data.
3. **Child Profile Lifecycle Protection & Canonical Archival:** Direct Data API clients are prohibited from altering child lifecycle status (`status`, `archived_at`) or reactivating archived profiles (`archived -> active`). Archival is routed strictly through `archive_child_profile()`, which executes with Order 1 exclusive row locks and automatically cascades revocation to active device grants in `child_device_grants`. Parent editing of ordinary profile fields (`display_name`, `avatar_key`, `school_grade`) on active profiles is preserved via replacement of `child_profiles_update` and a trigger guard.
4. For evidence and review events, join to active child through assessments, preserving review's adult-only restriction. For targeted rewards, check active target child. For `command_receipts`, enforce adult-only access plus active child through the operation-specific resource join.
5. Preserve the narrowly scoped own-grant `child_device_grants` status read to prove positive revocation without exposing archived learning records. Keep `private.child_pairing_requests` client-inaccessible. Harden `private.validate_storage_evidence_access` with active-child condition on Storage SELECT/INSERT/DELETE while preserving draft/tenant restrictions and no-UPDATE.
6. **Family-wide reads:** Replace `family_wheel_settings_select` and `rewards_select` child branches to require an active grant **and** an active, same-family child profile, including untargeted rewards. Other active children remain eligible; an archived child's still-active grant does not. Audit `reconcile_child_balance` and every SECURITY DEFINER read RPC. The grant-holder's own status read remains a narrow operational exception, not a family-data permission.
7. **Archived-child mutations:** Through new Phase 6 migrations, add authoritative child-active checks inside the existing SECURITY DEFINER assessment, evidence, parent-review, RP redemption/fulfillment/cancellation, Growth/Learning processing and catch-up RPCs. Retain already-present checks in `create_assessment_draft` and `spin_reward_wheel`; preserve all frozen signatures, actor-bound command receipts, immutable ledgers and error contracts.
8. **Concurrent Archive, Monotonic Lock Hierarchy & Replay:** Child profile archival is serialized against all child mutations using a strict monotonic lock hierarchy (`Order 1: public.child_profiles FOR SHARE/UPDATE` -> `Order 2: public.assessments / public.rewards / public.reward_redemptions` -> `Order 3: public.child_balances / public.child_mastery_states` -> `Order 4: VLE and child-node advisory locks`). Archival requests `FOR UPDATE` while mutations request `FOR SHARE` at Order 1, guaranteeing that no mutation commits after archival and providing testable cycle-free concurrency guarantees without deadlock exceptions (`40P01`). Unprocessed VLEs remain frozen pending controlled resolution. Mutating replays after archive fail closed; custom read-only reconciliation RPCs are explicitly deferred post-pilot while commands remain quarantined in client SQLite.
9. Audit `pg_policies`, read RPCs, indirect tables, private Storage and all mutation paths. Add pgTAP and real-PostgreSQL tests for active/archived with active/revoked grants, foreign families, processing receipts, response-lost evidence, archive races and zero late ledger/mastery side effects. ADR remains PROPOSED pending independent approval.
10. **Implementation Scope Notice:** The locking protocols, RLS policy replacements, lifecycle trigger guards, and RPC hardening in this ADR and Detailed Design §4.3 are design specifications for implementation in Phase 6.1/6.2 migrations. They do not alter frozen Phase 0–5 migrations. ADR 0008 remains PROPOSED.

---


## Decision 7 — Accessible Semantic Tree, Touch Targets & Reduced-Motion Wheel Guarantee

1. Every interactive component is audited and provided with accessibility semantics, live announcements (`SemanticsService.announce`), minimum 48 x 48 dp touch targets, and dynamic type font scaling.
2. `ChildWheelScreen` checks `MediaQuery.disableAnimationsOf(context)`:
   - When reduced-motion is enabled, the 4-second spin animation is bypassed with an instantaneous celebratory reveal card.
   - The outcome evaluates the **exact same** server-authoritative pseudorandom tier selection, debits the **same RP cost**, consumes the **same daily cap**, and guarantees the **same positive reward**.

---

## Decision 8 — Manual Signed Release Artifact Distribution for Closed Pilot Track

1. Mobile application IDs are pinned: `com.learnward.app`.
2. Android builds release Android App Bundles (AAB) signed with production upload keystores.
3. iOS builds release TestFlight IPAs signed with distribution provisioning profiles.
4. Manually uploading signed release artifacts to Google Play Internal Testing and Apple TestFlight satisfies the 4-week pilot exit gate; automated cloud CI deployment credentials remain optional conveniences.
5. Exit gate definition: "A small family pilot can run for four consecutive weeks without engineering intervention for normal daily usage."

---

## Decision 9 — Static Schema-Contract Validation Obligation

Every detailed design, ADR, or implementation specification that references database tables, column names, constraints, RPC signatures, or RLS policies **must** be statically verified against the authoritative schema definitions in `supabase/migrations/` before submission. Proposing speculative, unverified, or renamed SQL identifiers is strictly prohibited.
