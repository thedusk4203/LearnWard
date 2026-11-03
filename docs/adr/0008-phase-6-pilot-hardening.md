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
- **Detailed Design Document:** [Phase 6 Detailed Design v0.1](../17-phase-6-pilot-hardening-design-v0.1.md)

This ADR is **`PROPOSED`**. Implementation remains **NOT AUTHORIZED** until this detailed design passes independent audit and merge review.

---

## Context

Phases 1 through 5 established the complete core learning and economic engine of LearnWard: family identity, secure assessment capture, integer append-only economic ledgers, guaranteed reward store, celebration wheel, EWMA mastery engine, and the 5-class Next Challenge recommendation model.

Phase 6 provides the operational, reliability, accessibility, and release hardening necessary to execute a successful 4-week closed family pilot without engineering intervention. Following the authoritative findings of the [Phase 6 Readiness Review](../16-phase-6-pilot-hardening-dependency-readiness-review.md), the architectural decisions below formally resolve all identified readiness dependencies.

---

## Decision 1 — Bounded Feature Outboxes & Drift Schema v5 Actor Binding

Rather than implementing a complex, dynamically polymorphic offline sync queue, LearnWard adopts **bounded, domain-specific command journals**:
1. Retains and hardens `pending_reward_commands` for reward redemptions and wheel spins.
2. Extends `local_assessment_drafts` with an explicit submission lifecycle (`draft -> uploading_evidence -> submitting_assessment -> failed_retryable -> terminal_error`).
3. Local database schema migrates to `schemaVersion = 5` in Drift, adding `actor_user_id` (UUID), `actor_role` (text), and `schema_version` (integer) to local command queues.
4. If a replayed command's `actor_user_id` does not match the active authenticated session, re-execution is halted, preventing identity drift and `42501` server caller mismatch errors on shared family devices.

---

## Decision 2 — Per-Data-Class Local Security & Device Revocation Lifecycle

A blanket `clearAllTables()` wipe on sign-out is rejected because it destroys device-level security containment. Local data classes are governed by explicit lifecycle policies:
- **Parent PIN Hash & Salt:** Retained across adult logout to ensure device containment remains locked if the device is shared with children.
- **Active Child Session:** Immediately purged on sign-out, family switch, or Child Mode exit.
- **Assessment Drafts & Pending Commands:** Segregated by `family_id` and `actor_user_id`; purged immediately upon family switch or when a child device grant is revoked (`42501`).
- **Local Photo Files:** Deleted when drafts are submitted, cancelled, or purged.
- **Cached Read Models:** Evicted on family switch.

---

## Decision 3 — Client-Side Evidence Compression & Idempotent Resumption

To ensure evidence reliability over poor mobile network connections:
1. `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` are added to iOS `Info.plist`.
2. Raw camera images are resized client-side to a maximum resolution of $1920 \times 1080$ pixels and compressed to JPEG @ 80% quality ($< 1.5\text{ MB}$) before storage upload.
3. Storage upload uses deterministic paths (`{family_id}/{child_id}/{assessment_id}/{evidence_id}.jpg`) with pre-upload existence checks to make retries idempotent and prevent orphaned media objects.

---

## Decision 4 — In-App Coordination Notifications & Provider-Agnostic Port

For the 4-week pilot:
1. Notifications support family coordination only (pending parent review, reward fulfilled). Engagement farming (streaks, guilt, sibling taunts) is strictly prohibited.
2. In-app realtime notifications and badges via Supabase Realtime satisfy pilot coordination, eliminating external push provider dependencies and costs.
3. A provider-agnostic `NotificationService` interface isolates application logic from future external push platforms (FCM/APNs), which remain deferred.

---

## Decision 5 — Canonical VLPE Enforcement & Zero-PII Minimal Telemetry Envelope

1. The North Star metric **VLPE** is canonically defined as a verified event that has completed both **Growth processing** (`public.growth_events`) and **Learning processing** (`public.learning_processing_events` with `status = 'processed'`).
2. Exactly **12 of 16** pilot metrics are directly derivable from PostgreSQL without third-party analytics SDKs.
3. Metric 4 (% goals chosen by child) remains deferred; no Goals subsystem is authorized for Phase 6.
4. Client UX telemetry uses a minimal, privacy-preserving envelope strictly scrubbed of child real names, parent emails, school names, geographic location, image URLs, or auth tokens.

---

## Decision 6 — Soft-Delete Archival & Parent Data Portability for Right-to-Erasure

To resolve the tension between immutable database triggers and parental right-to-erasure requests:
1. Hard-deleting immutable ledger rows (`verified_learning_events`, `xp_ledger`, `rp_ledger`) is rejected to preserve mathematical and economic integrity.
2. LearnWard adopts **Strategy C: Soft-Delete Archiving + RLS Revocation**. On parental deletion, `child_profiles.status` transitions to `'archived'`, device grants are revoked, RLS denies access, and storage photos are deleted.
3. A `SECURITY DEFINER` function `public.export_family_data_json(p_family_id uuid)` provides complete parental data portability prior to archival.

---

## Decision 7 — Accessible Semantic Tree, Touch Targets & Reduced-Motion Wheel Guarantee

1. Every interactive component is audited and provided with accessibility semantics, live announcements (`SemanticsService.announce`), minimum $48 \times 48\text{ dp}$ touch targets, and dynamic type font scaling.
2. `ChildWheelScreen` checks `MediaQuery.disableAnimationsOf(context)`:
   - When reduced-motion is enabled, the 4-second spin animation is bypassed with an instantaneous celebratory reveal card.
   - The outcome evaluates the **exact same** server-authoritative pseudorandom tier selection, debits the **same RP cost**, consumes the **same daily cap**, and guarantees the **same positive reward**.

---

## Decision 8 — Manual Signed Release Artifact Distribution for Closed Pilot Track

1. Mobile application IDs are pinned: `com.learnward.app`.
2. Android builds release Android App Bundles (AAB) signed with production upload keystores.
3. iOS builds release TestFlight IPAs signed with distribution provisioning profiles.
4. Manually uploading signed release artifacts to Google Play Internal Testing and Apple TestFlight satisfies the 4-week pilot exit gate; automated cloud CI deployment credentials remain optional conveniences.
