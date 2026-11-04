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

Phase 6 provides the operational, reliability, accessibility, and release hardening necessary to execute a successful 4-week closed family pilot without engineering intervention. Following the authoritative findings of the [Phase 6 Readiness Review](../16-phase-6-pilot-hardening-dependency-readiness-review.md) and the independent detailed design audit, the architectural decisions below formally resolve all identified readiness dependencies and audit findings.

---

## Decision 1 — Bounded Feature Outboxes & Drift Schema v5 Actor Binding

Rather than implementing a complex, dynamically polymorphic offline sync queue, LearnWard adopts **bounded, domain-specific command journals** with strict Drift v4-to-v5 backward compatibility:
1. Retains and hardens `pending_reward_commands` for reward redemptions and wheel spins.
2. Extends `local_assessment_drafts` with an explicit submission lifecycle (`draft -> uploading_evidence -> submitting_assessment -> failed_retryable -> terminal_error`).
3. Local database schema migrates to `schemaVersion = 5` in Drift:
   - Existing v4 nullable columns (`pending_reward_commands.childId`, `local_assessment_drafts.createCommandId`, `local_assessment_drafts.submitCommandId`) remain strictly nullable to guarantee zero migration regressions on existing client rows.
   - Newly added columns (`actor_user_id` UUID, `actor_role` text, and `schema_version` integer) are declared nullable in Drift/SQLite table definitions so that SQLite `ALTER TABLE ADD COLUMN` statements succeed on existing v4 local databases without requiring non-null constant defaults.
4. Legacy v4 rows where `actor_user_id IS NULL` enter a safe `quarantined_legacy_v4` state:
   - The engine does NOT fabricate dummy or guessed actor identities.
   - Quarantined drafts and commands require explicit adult re-authorization or reassignment before execution.
   - Automated migration tests must execute against pre-populated v4 SQLite database fixtures to verify that zero drafts, pending commands, or local evidence photo paths are lost or corrupted.
5. On shared family devices, if an queued command's `actor_user_id` does not match the active authenticated session, re-execution is paused in a `pending_original_actor` state until the matching user logs in, preventing identity drift and server caller mismatch errors.

---

## Decision 2 — Per-Data-Class Local Security & Device Revocation Lifecycle

A blanket `clearAllTables()` wipe on sign-out is rejected because it destroys device-level security containment. Local data classes are governed by explicit lifecycle policies:
- **Parent PIN Hash & Salt:** Retained across adult logout to ensure device containment remains locked if the device is shared with children.
- **Active Child Session:** Immediately purged on sign-out, family switch, or Child Mode exit.
- **Assessment Drafts & Pending Commands:** Segregated by `family_id` and `actor_user_id`.
- **Error Disambiguation (`42501`):** PostgreSQL code `42501` (`insufficient_privilege`) is NOT treated as a blanket signal for device revocation. The client differentiates:
  1. *Caller mismatch:* Current authenticated user is not authorized for the row or operation. Action: pause command execution in `pending_original_actor` state.
  2. *Device grant revocation:* Specifically verified via a dedicated lightweight RPC `public.verify_device_grant(p_grant_id)` or checking `child_device_grants.revoked_at`. Action: securely purge child session and local child credentials.
  3. *General permission denied:* Action: mark command `failed_terminal` with actionable user diagnostic.
- **Response-Lost Reconciliation:** When a network timeout or connection reset occurs during command submission, the client queries `public.command_receipts` or the target table before retrying, preventing duplicate ledger debits or duplicate assessment submissions.

---

## Decision 3 — Client-Side Evidence Compression & Idempotent Resumption

To ensure evidence capture reliability over poor mobile network connections without external AWS dependencies:
1. `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` are added to iOS `Info.plist`.
2. Raw camera images are resized client-side to a maximum resolution of `2048 x 1536` pixels with adaptive JPEG compression (target quality 85%, minimum 70%). Compression strictly prioritizes handwriting and diagram legibility over file size; the 1.5 MB threshold is an adaptive compression target, not a hard-fail rejection cap.
3. Storage upload uses deterministic paths (`{family_id}/{child_id}/{assessment_id}/{evidence_id}.jpg`) via the official Supabase Dart Storage SDK:
   - Uses `supabase.storage.from('assessment-evidence').list(path: ...)` to verify pre-existing uploads prior to re-upload.
   - Uploads via `uploadBinary(...)` with `FileOptions(upsert: false)`.
   - Handles `409 Conflict` gracefully by verifying remote object existence and size.
   - S3-specific primitives (`headBucket`, `getObject`) are not used.

---

## Decision 4 — In-App Coordination Notifications & Authoritative Query Reconciliation

For the 4-week pilot:
1. Notifications support family coordination only (pending parent review, reward fulfilled). Engagement farming (streaks, guilt, sibling taunts) is strictly prohibited.
2. In-app realtime notifications via Supabase Realtime provide immediate UI updates. However, because Realtime connections are transient, parent inbox badges and child review states must be backed by authoritative PostgreSQL queries on app launch, resume, and network reconnection.
3. A provider-agnostic `NotificationService` interface isolates application logic from future external push platforms (FCM/APNs), which remain deferred.
4. Deep link navigation routes through strict role authorization checks: child accounts attempting to navigate to adult review URLs are redirected to Child Mode home with an access notice.

---

## Decision 5 — Canonical VLPE Enforcement & Zero-PII Minimal Telemetry Envelope

1. The North Star metric **VLPE** is canonically defined as a verified event that has completed both **Growth processing** (`public.growth_events`) and **Learning processing** (`public.learning_processing_events` with `status = 'processed'`).
2. Exactly **12 of 16** pilot metrics are directly derivable from PostgreSQL without third-party analytics SDKs.
3. Metric 4 (% goals chosen by child) remains deferred; no Goals subsystem is authorized for Phase 6.
4. Client UX telemetry uses a minimal, privacy-preserving envelope strictly scrubbed of child real names, parent emails, school names, geographic location, image URLs, or auth tokens.

---

## Decision 6 — Four-Tier Right-to-Erasure Lifecycle & Hardened Data Portability

To resolve the tension between immutable database triggers and parental right-to-erasure requests across all 19 child-linked database tables and Supabase Storage:
1. Hard-deleting immutable ledger rows (`verified_learning_events`, `xp_ledger`, `rp_ledger`, `growth_events`, `command_receipts`) is rejected to preserve mathematical and economic integrity. These records are retained under lawful legitimate interest for audit and accounting consistency.
2. LearnWard implements a formal **Four-Tier Erasure and Archival Lifecycle**:
   - **Tier 1 (Access Revocation & Soft Archival):** Setting `child_profiles.status = 'archived'` revokes active child device grants. RLS read policies for active family adults are updated with an explicit check (`private.is_child_active_in_family(child_id, auth.uid())`) ensuring archived child records are completely excluded from active adult dashboard queries.
   - **Tier 2 (Child PII Anonymization):** Child identifying details in `child_profiles` (display name, birth year/month, avatar URL) are overwritten with pseudonymous values (`[Redacted Child]`, `null`), severing the link between real identity and historic records.
   - **Tier 3 (Evidence File Purging):** All uploaded assessment evidence photos in the `assessment-evidence` Supabase Storage bucket under the child's prefix are physically purged.
   - **Tier 4 (Ephemeral Record Cleanup):** Non-ledger, mutable child records (`child_device_grants`, `local_assessment_drafts`) are deleted.
3. Data Portability RPC `public.export_family_data_json(p_family_id uuid)`:
   - Security-hardened with `REVOKE EXECUTE ON FUNCTION public.export_family_data_json FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.export_family_data_json TO authenticated;`.
   - Strictly enforces that the caller is an active adult in the specified family via `private.is_family_adult(p_family_id, auth.uid())`.
   - Uses an explicit column allowlist (excluding password salts, PIN hashes, internal system state).
   - Generates short-lived (15-minute) signed download URLs for evidence images rather than massive base64 payloads.

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
