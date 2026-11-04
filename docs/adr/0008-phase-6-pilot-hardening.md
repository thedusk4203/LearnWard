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

## Decision 1 — Bounded Feature Outboxes, Drift Schema v5 & Provably Safe Command Recovery

Rather than implementing a complex, dynamically polymorphic offline sync queue, LearnWard adopts **bounded, domain-specific command journals** with strict Drift v4-to-v5 backward compatibility:
1. Retains and hardens `pending_reward_commands` for reward redemptions and wheel spins.
2. Extends `local_assessment_drafts` with an explicit submission lifecycle (`draft -> uploading_evidence -> submitting_assessment -> failed_retryable -> terminal_error`).
3. Local database schema migrates to `schemaVersion = 5` in Drift:
   - Existing v4 nullable columns (`pending_reward_commands.childId`, `local_assessment_drafts.createCommandId`, `local_assessment_drafts.submitCommandId`, `local_assessment_drafts.evidenceId`, `local_assessment_drafts.serverAssessmentId`, `local_assessment_drafts.localPhotoPath`) remain strictly nullable to guarantee zero migration regressions on existing client rows.
   - Newly added columns (`server_evidence_id`, `sha256_checksum`, `local_compressed_photo_path`, `actor_user_id`, `actor_role`, `schema_version`, `recovery_state`) are declared nullable in Drift/SQLite table definitions so that SQLite `ALTER TABLE ADD COLUMN` statements succeed on existing v4 databases without requiring non-null constant defaults.
4. **Provably Safe Legacy v4 Command Recovery:**
   - Unsent local actions (`retry_count == 0`) are distinguished from dispatched commands with unknown outcomes (`retry_count > 0`).
   - Legacy v4 rows where `actor_user_id IS NULL` enter `quarantined_legacy_v4` or `quarantined_unknown_outcome`.
   - **Original Command IDs are Preserved:** The unique `command_id` is never discarded or regenerated automatically merely because an approximate search finds no match.
   - **Exact Server-Authoritative Reconciliation:** Adults query `public.command_receipts` to determine if a command committed; paired child commands rely on server-side idempotent RPC replay contracts with the exact same `original_command_id`.
   - **Safe Manual Resolution:** When outcome cannot be established, the command remains in quarantine for parent review in Parent Settings (choice to mark resolved from history, cancel/discard, or explicitly re-authorize under the active parent).
   - Automated migration tests must execute against pre-populated v4 SQLite database fixtures to verify that zero drafts, pending commands, or local evidence photo paths are lost or corrupted.
5. On shared family devices, if a queued command's `actor_user_id` does not match the active authenticated session, re-execution is paused in a `pending_original_actor` state until the matching user logs in, preventing identity drift and server caller mismatch errors.

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

---

## Decision 3 — Evidence Persistence, Content-Integrity Hashing & Resumable Storage

To ensure evidence capture reliability over poor mobile network connections without external AWS dependencies:
1. `NSCameraUsageDescription` and `NSPhotoLibraryUsageDescription` are added to iOS `Info.plist`.
2. Raw camera images are resized client-side to a maximum resolution of `2048 x 1536` pixels with adaptive JPEG compression (target quality 85%, minimum 70%). Compression strictly prioritizes handwriting and diagram legibility over file size; the 1.5 MB threshold is an adaptive compression target, not a hard-fail rejection cap.
3. **Content-Integrity Hashing & Stable Compression:**
   - Image is compressed once upon capture and saved to `localCompressedPhotoPath`; its SHA-256 hash is computed and stored in `sha256Checksum`.
   - Across retries and restarts, the compressor is NEVER re-invoked, preventing byte drift or generation loss.
4. **Safe Storage Upload & HTTP 409 Conflict Policy:**
   - Uploads via Supabase Dart Storage SDK to deterministic path `{family_id}/{child_id}/{assessment_id}/{clientEvidenceUuid}.jpg` with custom metadata containing the SHA-256 hash.
   - On HTTP 409 Conflict: Client verifies remote file existence, byte size, and SHA-256 hash.
     * If content matches: Upload is verified; proceed to registration RPC.
     * If content differs (mismatched hash/size or corrupted 0-byte file): Client generates a fresh unique `clientEvidenceUuid`, updates the local draft path, and uploads to the new path to prevent overwriting unrelated evidence.
   - Authoritative database registration calls `public.register_assessment_evidence(...)`, and the returned database primary key UUID (`id`) is stored in `LocalAssessmentDrafts.serverEvidenceId`.

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

## Decision 6 — Complete RLS Read-Boundary Overhaul, Pre-Pilot Legal Review & Data Portability

To resolve the tension between immutable database triggers and parental right-to-erasure requests across all 20 child-linked database tables and Supabase Storage:
1. **Mandatory Legal & Privacy Review Obligation:**
   - A formal legal and privacy review (covering COPPA verifiable parental consent, GDPR/CCPA data minimization, and lawful bases) **MUST be completed prior to onboarding external pilot families** and processing real children's personal data.
   - Internal operational minimization (the 4-tier technical lifecycle) is explicitly distinguished from statutory regulatory compliance.
2. **Complete RLS Read-Boundary Overhaul:**
   - In PostgreSQL, multiple permissive policies combine with `OR`. To prevent existing permissive policies from bypassing archived-child restrictions, Phase 6 **drops and replaces** existing SELECT policies across all child-linked tables.
   - For tables with direct `child_id`: Normal adult access requires `(private.is_active_family_adult(family_id) AND private.is_child_active_in_family(child_id, family_id))`.
   - For tables without direct `child_id` (`assessment_evidence`, `assessment_review_events`, `rewards`): Access follows the authoritative join path through `public.assessments.child_id` or `rewards.target_child_id` with active child verification.
   - Paired child device access is strictly restricted to active devices matching the child's own profile: `private.is_active_child_device(family_id, child_id)`.
3. **Technical Constraint on Review Notes:** `assessment_review_events` is protected by the immutable trigger `trg_prevent_assessment_review_event_mutation`, prohibiting in-place UPDATE or DELETE of `review_notes`. Historical review notes remain protected by the trigger; access is severed at the RLS read boundary.
4. **Schema-Verified Data Portability RPC `public.export_family_data_json(p_family_id uuid)`:**
   - Strictly verified against all frozen migrations (Phases 1–5).
   - Enforces adult authorization using existing security definer helper: `private.is_active_family_adult(p_family_id)`.
   - Uses verified schema columns: `family_memberships.auth_user_id`, `xp_ledger.reason_code`, `rp_ledger.reason_code`; excludes nonexistent `child_mastery_states.mastery_band`.
   - Revokes execution from `public, anon`; grants execution to `authenticated`.

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
