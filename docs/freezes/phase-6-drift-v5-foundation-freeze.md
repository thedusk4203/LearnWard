# Phase 6 Freeze Receipt — Drift v5 Client Persistence Foundation

**Status:** FROZEN  
**Target:** Phase 6 Drift v5 Client Persistence Foundation (`Drift Schema v5, Atomic Multi-Version Migration, Unknown-Legacy Quarantine, Nullable Provenance Invariance, Durable Pre-Dispatch Markers, Fail-Closed Actor Matching`)  
**Implementation PR:** [#21 — feat(phase-6): implement additive Drift schema v4 to v5 migration with legacy quarantine](https://github.com/thedusk4203/LearnWard/pull/21)  
**Approved Implementation HEAD:** `f3254d44baffcfec8f5ff306a449f5fda750ec3a`  
**Independent Implementation Audit:** PASS / APPROVED  
**Implementation Merge SHA:** `7b0d6ce9d179a7945bcb217f15dcd32274d649b0`  
**Post-Merge Main SHA:** `7b0d6ce9d179a7945bcb217f15dcd32274d649b0`  
**Post-Merge CI:** Run ID [`42337689222`](https://github.com/thedusk4203/LearnWard/actions/runs/42337689222) — **SUCCESS (4/4 green)**  
**Merge Timestamp:** `2026-11-07T04:16:03Z`  
**Freeze Date:** 2026-11-07  
**ADR:** [ADR 0008 — Phase 6 Pilot Hardening](../adr/0008-phase-6-pilot-hardening.md) (`ACCEPTED`)  
**Upstream Contracts:** [ADR 0001–0007](../adr/), [Phase 1–5.2 Freeze Receipts](.)  

---

## 1. Verified CI & Test Suite Totals

Final verified test totals from post-merge main CI run [`42337689222`](https://github.com/thedusk4203/LearnWard/actions/runs/42337689222):

| Test Suite / Job | Total Tests | Passed | Result | Duration |
|---|---|---|---|---|
| **Format, analyze and test** | All suites | All | **PASS** | 2m 16s |
| - *learnward_domain* | 196 | 196 | **PASS** | — |
| - *learnward_application* | 53 | 53 | **PASS** | — |
| - *learnward_data* | 38 | 38 | **PASS** | — |
| - *learnward_test_support* | 1 | 1 | **PASS** | — |
| - *learnward_design_system* | 2 | 2 | **PASS** | — |
| - *apps/mobile* widget & flow tests | 57 | 57 | **PASS** | — |
| - *Drift build_runner diff assertion* | Clean (0 diff) | Clean | **PASS** | — |
| **Supabase migrations & RLS security** | 659 pgTAP + 14 scripts | All | **PASS** | 2m 31s |
| - *pgTAP Test Files* (9 files) | 659 | 659 | **PASS** | — |
| - *Concurrency & Integration Scripts* | 14 | 14 | **PASS** | — |
| **iOS simulator compile** | Flutter build ios --simulator | Success | **PASS** | 2m 29s |
| **Android debug build** | Gradle assembleDebug | Success | **PASS** | 4m 36s |

---

## 2. Frozen Drift v5 Client Persistence Contract

### 2.1 Additive Schema Version 5 Declarations

1. **`pending_reward_commands` Table (v5 Additions):**
   - Preserves existing v4 nullable columns (`child_id`, `reward_id`, `redemption_id`, `cancellation_reason`).
   - `actor_user_id`: `TEXT NULL` — Bound to the authenticated user who initiated the economic command.
   - `actor_role`: `TEXT NULL` — Actor role (`parent`, `owner`, `child`).
   - `schema_version`: `INTEGER NOT NULL DEFAULT 1`.
   - `recovery_state`: `TEXT NOT NULL DEFAULT 'active'` — Lifecycle recovery state (`active`, `pending_original_actor`, `quarantined_unknown_outcome`, `terminal_error`).
   - `dispatch_state`: `TEXT NOT NULL DEFAULT 'unknown_legacy'` — Network dispatch marker (`unknown_legacy`, `never_dispatched`, `possibly_dispatched`, `confirmed_committed`).

2. **`local_assessment_drafts` Table (v5 Additions):**
   - Preserves existing v4 nullable columns (`create_command_id`, `submit_command_id`, `evidence_id`, `server_assessment_id`, `local_photo_path`).
   - `server_evidence_id`: `TEXT NULL` — Authoritative UUID from `public.assessment_evidence.id`.
   - `sha256_checksum`: `TEXT NULL` — Cryptographic hash of compressed JPEG payload.
   - `local_compressed_photo_path`: `TEXT NULL` — Durable local path to stably compressed JPEG.
   - `submission_status`: `TEXT NOT NULL DEFAULT 'draft'` (`draft`, `uploading_evidence`, `submitting_assessment`, `failed_retryable`, `terminal_error`).
   - `retry_count`: `INTEGER NOT NULL DEFAULT 0` — Execution attempt counter (never used to infer absence of network dispatch).
   - `dispatch_state`: `TEXT NOT NULL DEFAULT 'unknown_legacy'` — Network dispatch marker (`unknown_legacy`, `never_dispatched`, `possibly_dispatched`, `confirmed_committed`).
   - `last_error_message`: `TEXT NULL` — Sanitized, user-facing error message.
   - `actor_user_id`: `TEXT NULL` — Bound authenticated actor who initiated draft creation/submission.
   - `actor_role`: `TEXT NULL` — Bound actor role.

---

### 2.2 Atomic Multi-Version Migration Contract (`onUpgrade`)

1. **Atomic SQLite Transaction Wrapping:**
   - Every schema change and data backfill statement executes within an explicit SQLite `transaction()` with foreign keys safely toggled (`PRAGMA foreign_keys = OFF` during structural modification, restored `ON` in a strict `finally` block).
   - If an upgrade step is interrupted midway (power failure, process crash, exception), SQLite rolls back the transaction completely, leaving user database at its prior `user_version` with zero orphaned columns and zero corrupted records.
   - Reopening the database cleanly retries the migration from the prior version to v5.

2. **Supported Historical Upgrade Paths:**
   - **v1 $\to$ v5:** Creates `local_assessment_drafts` and `pending_reward_commands` with complete v5 schemas; preserves `local_metadata_entries`.
   - **v2 $\to$ v5:** Adds all missing v3 and v5 columns to `local_assessment_drafts` and creates `pending_reward_commands`; backfills legacy drafts to `unknown_legacy` and `quarantined`.
   - **v3 $\to$ v5:** Adds missing v5 columns to `local_assessment_drafts` without duplicate column collisions; creates `pending_reward_commands`; backfills legacy drafts to `unknown_legacy`.
   - **v4 $\to$ v5:** Atomically adds new v5 columns to both tables; sets `dispatch_state = 'unknown_legacy'` for all historical drafts and commands; sets `recovery_state = 'quarantined_unknown_outcome'` for pending reward commands without authenticated actor binding.

---

### 2.3 Legacy Unknown-Outcome Quarantine & Nullable Provenance Invariance

1. **Conservative Historical Limit:**
   - Frozen Drift v4 recorded no dispatch marker and no retry counter. A newly added default `retryCount == 0` does **not** prove an operation was never transmitted over the network.
   - All migrated v4 drafts and commands are permanently stamped `dispatchState = 'unknown_legacy'`.
   - Migrated v4 records are quarantined from automated network replay: `canAutoSubmit` returns `false` and `isEligibleForReplay` returns `false`.

2. **Strict NULL Preservation on Ordinary Local Edits:**
   - For an `unknown_legacy` draft, ordinary local editing (e.g. updating title, score, subject) and saving via `AddAssessmentScreen._saveLocalDraft()` preserves all existing fields:
     - `createCommandId` preserves `NULL` (no fallback to `generateUuid()`).
     - `submitCommandId` preserves `NULL` (no fallback to `generateUuid()`).
     - `actorUserId` preserves `NULL` (never backfills current user from `currentUserIdProvider`).
     - `evidenceId`, `serverAssessmentId`, and `localPhotoPath` remain intact.
     - `dispatchState` remains `unknownLegacy`.
   - Historical identities and command associations are never fabricated.

---

### 2.4 Stable Command IDs & Fail-Closed Actor Binding

1. **Fresh Draft Command Identity Generation:**
   - Fresh v5 drafts generate distinct, stable UUIDs for `createCommandId` and `submitCommandId` upon initial save or dispatch.
   - These command IDs remain immutable across retries, local edits, and network timeouts.

2. **Durable Pre-Dispatch Markers:**
   - **Before** invoking any remote mutating RPC (`createDraft`, `submitAssessment`, `spinWheel`, `redeemReward`), the client atomically writes `dispatchState = 'possibly_dispatched'` (and `possiblyDispatched = true`) to SQLite.
   - If the app crashes or network drops after SQLite commit but before server receipt, the operation remains durable in `possibly_dispatched`.
   - On retry, the client reuses the exact same command ID, relying on server-authoritative idempotent RPC replay contracts.

3. **Fail-Closed Actor Matching:**
   - Before executing or replaying any pending reward command or draft submission, the client verifies that:
     `command.actorUserId != null && currentUserId != null && command.actorUserId == currentUserId`
   - Commands with missing actor identity (`actorUserId == null`) or mismatched actor identity are strictly blocked from automated execution:
     - New command execution fails closed with `StateError` before any network or SQLite journaling.
     - Existing commands pause in `recoveryState = 'pending_original_actor'` without mutating remote state or regenerating command IDs.

---

### 2.5 Explicit Deferral Contract

The following components are **explicitly deferred** to subsequent Phase 6 client slices and are **not** included in this foundation:
1. Automated background outbox dispatcher with exponential backoff timers.
2. Manual user-facing recovery UI (Keep quarantined / Export unsynced work / Abandon local copy dialogs).
3. Dedicated post-archive read-only command reconciliation RPCs.
4. Push notifications and external APNs/FCM delivery.

---

## 3. Verified Architecture Invariants

- **Frozen Supabase Migrations:** All migrations in `supabase/migrations/` (Phase 0–5 and Phase 6 Slices 1–3) remain completely untouched and frozen.
- **Accepted ADR Compliance:** Complies with [ADR 0008](../adr/0008-phase-6-pilot-hardening.md) Decisions 1 and 2.
- **Economic Invariance:** Zero duplicate ledger debits, zero duplicate wheel spins, zero unverified learning event side effects.
- **Clean Toolchain:** Drift `build_runner` outputs 0 diff against checked-in code; `flutter analyze` reports 0 warnings/errors.
