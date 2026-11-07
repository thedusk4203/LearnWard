# Phase 6 Freeze Receipt — Drift v6 & Atomic Claim Foundation (Slice 4A-0)

**Status:** FROZEN  
**Target:** Phase 6 Slice 4A-0 — Durable Retry & Atomic Claim Foundation (`Drift Schema v6, Atomic Multi-Version Migration v1..v5 -> v6, Rollback Safety, Command Identity Immutability, Irreversible Legacy Quarantine & Dispatch Provenance, Actor-Aware Atomic Claims, Lease Token & Expiration Fencing, Atomic Retry Counter & Durable Scheduling, Multi-Connection SQLite Concurrency, Strictly Fenced Journal Deletion, In-Memory Store Parity`)  
**Implementation PR:** [#23 — feat(phase-6): implement Drift schema v6 and atomic CAS claim infrastructure](https://github.com/thedusk4203/LearnWard/pull/23)  
**Approved Implementation HEAD:** `d6861cbcc2c8bca0dee9f2a5b908d642a6cc6e56`  
**PR CI Run ID:** [`42361103373`](https://github.com/thedusk4203/LearnWard/actions/runs/42361103373) — **SUCCESS (4/4 green)**  
**Implementation Merge SHA:** `88908ac309cda0eddcd549121ea0638c6979a384`  
**Post-Merge Main SHA:** `88908ac309cda0eddcd549121ea0638c6979a384`  
**Post-Merge Main CI:** Run ID [`42366631328`](https://github.com/thedusk4203/LearnWard/actions/runs/42366631328) — **SUCCESS (4/4 green)**  
**Merge Timestamp:** `2026-11-07T11:04:40Z`  
**Freeze Date:** 2026-11-07  
**ADR:** [ADR 0008 — Phase 6 Pilot Hardening](../adr/0008-phase-6-pilot-hardening.md) (`ACCEPTED`)  
**Upstream Contracts:**
- [ADR 0001–0007](../adr/)
- [Phase 1–5.2 Freeze Receipts](.)
- [Phase 6 Drift v5 Foundation Freeze](phase-6-drift-v5-foundation-freeze.md)
- [Phase 6 Actor-Aware Offline Recovery Readiness Review](../18-phase-6-actor-aware-offline-recovery-readiness-review.md)

---

## 1. Verified CI & Test Suite Totals

Final verified test totals from post-merge main CI run [`42366631328`](https://github.com/thedusk4203/LearnWard/actions/runs/42366631328) on exact merge commit `88908ac309cda0eddcd549121ea0638c6979a384`:

| Test Suite / Job | Total Tests | Passed | Result | Duration |
|---|---|---|---|---|
| **Format, analyze and test** | All suites | All | **PASS** | 2m 3s |
| - *learnward_domain* | 196 | 196 | **PASS** | — |
| - *learnward_application* | 53 | 53 | **PASS** | — |
| - *learnward_data* | 58 | 58 | **PASS** | — |
| - *learnward_test_support* | 12 | 12 | **PASS** | — |
| - *learnward_design_system* | 2 | 2 | **PASS** | — |
| - *apps/mobile* widget & flow tests | 65 | 65 | **PASS** | — |
| - *Drift build_runner diff assertion* | Clean (0 diff) | Clean | **PASS** | — |
| **Supabase migrations & RLS security** | 659 pgTAP + 19 scripts | All | **PASS** | 2m 28s |
| - *pgTAP Test Files* (11 files) | 659 | 659 | **PASS** | — |
| - *Concurrency & Integration Scripts* | 19 | 19 | **PASS** | — |
| **iOS simulator compile** | Flutter build ios --simulator | Success | **PASS** | 3m 31s |
| **Android debug build** | Gradle assembleDebug | Success | **PASS** | 4m 26s |

---

## 2. Frozen Drift v6 Client Persistence Contract

### 2.1 Additive Schema Version 6 Declarations

1. **`pending_reward_commands` Table (v6 Additions):**
   - Preserves all v4 and v5 columns (`command_id`, `family_id`, `child_id`, `reward_id`, `redemption_id`, `operation`, `cancellation_reason`, `created_at`, `actor_user_id`, `actor_role`, `schema_version`, `recovery_state`, `dispatch_state`).
   - `retry_count`: `INTEGER NOT NULL DEFAULT 0` — Execution attempt counter (never used to infer absence of prior network transmission).
   - `next_attempt_at`: `DATETIME NULL` — Earliest timestamp eligible for next dispatch attempt (supports restart-safe exponential backoff).
   - `last_error_message`: `TEXT NULL` — User-facing error description from the most recent failed dispatch attempt.
   - `lease_token`: `TEXT NULL` — Unique claim ownership UUID protecting in-flight operations against concurrent workers.
   - `lease_expires_at`: `DATETIME NULL` — Timestamp after which an in-flight claim lease expires and may be reclaimed.

2. **`local_assessment_drafts` Table (v6 Additions):**
   - Preserves all v4 and v5 columns (`draft_id`, `child_id`, `title`, `subject_key`, `raw_score`, `max_score`, `calculated_percentage`, `evidence_id`, `server_assessment_id`, `created_at`, `updated_at`, `local_photo_path`, `create_command_id`, `submit_command_id`, `server_evidence_id`, `sha256_checksum`, `local_compressed_photo_path`, `submission_status`, `retry_count`, `dispatch_state`, `last_error_message`, `actor_user_id`, `actor_role`).
   - `next_attempt_at`: `DATETIME NULL` — Earliest timestamp eligible for next submission attempt.
   - `lease_token`: `TEXT NULL` — Unique claim ownership UUID for draft submission.
   - `lease_expires_at`: `DATETIME NULL` — Claim expiration timestamp for draft submission.

---

### 2.2 Atomic Multi-Version Migration Matrix (`onUpgrade`)

Every database schema upgrade executes within an explicit SQLite `transaction()` with foreign keys safely isolated (`PRAGMA foreign_keys = OFF` during structural modification, restored `ON` in a strict `finally` block).

| Source Version | Target Version | Migration Operations | Verified Invariants |
|---|---|---|---|
| **v1** | **v6** | Creates `local_assessment_drafts` and `pending_reward_commands` with full v6 schemas; creates `local_metadata_entries`. | Clean initialization; no duplicate table errors. |
| **v2** | **v6** | Adds missing v3, v5, and v6 columns to drafts; creates `pending_reward_commands` table directly with full v6 schema; backfills legacy drafts to `unknown_legacy`. | Preserves existing draft contents; sets quarantine markers. |
| **v3** | **v6** | Adds missing v5 and v6 columns to drafts without duplicate column collisions; creates `pending_reward_commands` table directly with full v6 schema; backfills legacy drafts to `unknown_legacy`. | Avoids SQLite `ALTER TABLE` collision errors. |
| **v4** | **v6** | Adds all missing v5 and v6 columns to both tables; sets `dispatch_state = 'unknown_legacy'` for historical drafts and commands; sets `recovery_state = 'quarantined_unknown_outcome'` for legacy reward commands with null actors. | Historical provenance and NULL identity preserved; defaults initialized. |
| **v5** | **v6** | Atomically adds `retry_count`, `next_attempt_at`, `last_error_message`, `lease_token`, `lease_expires_at` to `pending_reward_commands`; adds `next_attempt_at`, `lease_token`, `lease_expires_at` to `local_assessment_drafts`. | Additive column migration with zero data loss or rewrite. |

#### Rollback and Reopen Safety Evidence:
- Verified in `CrashingAppDatabase` (`drift_schema_v5_to_v6_migration_test.dart`): an injected Dart runtime exception during the v5 $\to$ v6 migration triggers a complete SQLite transaction rollback.
- The SQLite file remains at `user_version = 5` with 0 orphaned columns.
- Reopening the database cleanly restarts and completes the upgrade to v6 without schema corruption or lock contention.

---

### 2.3 Command Identity Immutability (HIGH 1 Resolution)

To ensure that a pending command ID represents exactly one invariant economic intent:
1. **8 Invariant Identity Fields:** `operation`, `family_id`, `child_id`, `reward_id`, `redemption_id`, `cancellation_reason`, `actor_user_id`, and `actor_role` are strictly immutable for an existing `command_id`.
2. **Atomic SQLite Predicate:** `AppDatabase.savePendingCommand()` enforces identity immutability using SQLite's null-safe `IS` operator:
   ```sql
   WHERE command_id = ?
     AND operation = ?
     AND family_id = ?
     AND (child_id IS ?)
     AND (reward_id IS ?)
     AND (redemption_id IS ?)
     AND (cancellation_reason IS ?)
     AND (actor_user_id IS ?)
     AND (actor_role IS ?)
   ```
3. **Fail-Closed Semantics:** Any attempt to mutate or backfill an identity field (e.g. changing target child, altering reward ID, or replacing a migrated NULL actor) causes 0 rows to be updated and throws `StateError`, leaving the persisted record completely untouched.
4. **Legitimate Retries:** Retries passing the exact original command identity succeed, safely updating `next_attempt_at` and `last_error_message` while clearing expired leases.

---

### 2.4 Irreversible Legacy Quarantine & Dispatch Provenance (HIGH 2 Resolution)

1. **Quarantine Protection:**
   - Records with `dispatch_state = 'unknown_legacy'` cannot be promoted, updated, or made replay-eligible via generic `savePendingCommand()` (fails closed with `StateError`).
   - Records with `dispatch_state = 'confirmed_committed'` cannot be updated, demoted, or replayed (fails closed with `StateError`).
   - Quarantined recovery states (`quarantined_unknown_outcome`, `pending_original_actor`, `terminal_error`) cannot be bypassed or reset to `active` via generic `savePendingCommand()`.
2. **Non-Regressing Dispatch Provenance:**
   - `possibly_dispatched` commands can never regress to `never_dispatched`.
   - Fresh commands safely progress from `never_dispatched` to `possibly_dispatched` upon initial dispatch.
   - Enforced both in atomic SQLite SQL (`WHERE dispatch_state NOT IN ('unknown_legacy', 'confirmed_committed') AND recovery_state NOT IN ('quarantined_unknown_outcome', 'pending_original_actor', 'terminal_error')`) and in-memory store implementations.

---

### 2.5 Actor-Aware Atomic Concurrency Claims (`acquireClaim`)

Before any foreground or background worker dispatches a command, it must acquire an atomic lease in SQLite:
```sql
UPDATE pending_reward_commands
SET lease_token = :newLeaseToken,
    lease_expires_at = :leaseExpiresAt
WHERE command_id = :commandId
  AND actor_user_id = :authenticatedActorId
  AND recovery_state = 'active'
  AND operation IN ('spin_wheel', 'redeem_reward')
  AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
  AND (next_attempt_at IS NULL OR next_attempt_at <= :now)
  AND (
    (lease_token IS NULL AND lease_expires_at IS NULL)
    OR
    (lease_token IS NOT NULL AND lease_expires_at <= :now)
  );
```
- **Actor Binding:** Rejects commands unless the caller's authenticated user ID positively matches `actor_user_id`.
- **Exclusivity:** Only unclaimed rows or rows whose active lease has expired can be claimed.
- **Token Generation:** A cryptographically random UUID (`lease_token`) is assigned per claim.

---

### 2.6 Stale-Worker Fencing & Atomic Retry Scheduling

1. **Fenced Release:** `releaseClaim(commandId, leaseToken, nextAttemptAt, lastErrorMessage)` updates the row only if `lease_token` matches. It atomically executes:
   ```sql
   UPDATE pending_reward_commands
   SET retry_count = retry_count + 1,
       next_attempt_at = :nextAttemptAt,
       last_error_message = :lastErrorMessage,
       lease_token = NULL,
       lease_expires_at = NULL
   WHERE command_id = :commandId
     AND lease_token = :leaseToken;
   ```
2. **Fenced Completion:** `completeCommand(commandId, leaseToken)` deletes the row conditionally:
   ```sql
   DELETE FROM pending_reward_commands
   WHERE command_id = :commandId
     AND lease_token = :leaseToken;
   ```
3. **Fenced State Transition:** `transitionRecoveryState(commandId, leaseToken, newState, lastErrorMessage)` conditionally updates `recovery_state` and clears lease metadata only when `lease_token` matches.
4. **Stale Worker Protection:** If worker A's lease expires and worker B acquires a new lease, worker A's subsequent attempts to complete, release, or transition the command affect 0 rows and return `false`.

---

### 2.7 Actor Mismatch & Resumption Non-Dispatch CAS

1. **Pause CAS (`active` $\to$ `pending_original_actor`):**
   ```sql
   UPDATE pending_reward_commands
   SET recovery_state = 'pending_original_actor',
       last_error_message = :mismatchReason,
       lease_token = NULL,
       lease_expires_at = NULL
   WHERE command_id = :commandId
     AND family_id = :familyId
     AND actor_user_id IS NOT NULL
     AND actor_user_id <> :authenticatedActorId
     AND recovery_state = 'active'
     AND operation IN ('spin_wheel', 'redeem_reward')
     AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
     AND (
       (lease_token IS NULL AND lease_expires_at IS NULL)
       OR
       (lease_token IS NOT NULL AND lease_expires_at <= :now)
     );
   ```
2. **Resume CAS (`pending_original_actor` $\to$ `active`):**
   ```sql
   UPDATE pending_reward_commands
   SET recovery_state = 'active',
       last_error_message = NULL,
       lease_token = NULL,
       lease_expires_at = NULL
   WHERE command_id = :commandId
     AND family_id = :familyId
     AND actor_user_id = :authenticatedActorId
     AND recovery_state = 'pending_original_actor'
     AND operation IN ('spin_wheel', 'redeem_reward')
     AND dispatch_state IN ('never_dispatched', 'possibly_dispatched')
     AND (
       (lease_token IS NULL AND lease_expires_at IS NULL)
       OR
       (lease_token IS NOT NULL AND lease_expires_at <= :now)
     );
   ```

---

### 2.8 Fenced Journal Deletion & Malformed Lease Protection

1. **Deletion Guard:** `deletePendingCommand(commandId)` enforces:
   ```sql
   DELETE FROM pending_reward_commands
   WHERE command_id = ?
     AND lease_token IS NULL
     AND lease_expires_at IS NULL;
   ```
   Rows with active leases, expired leases, or malformed leases are strictly protected from generic deletion. Deletion of claimed rows requires `completeCommand(commandId, leaseToken)`.
2. **Malformed Lease Fail-Closed:** If an existing persisted record has partial lease metadata (one null, one non-null):
   - `acquireClaim()` fails closed (returns `null`).
   - `savePendingCommand()` fails closed (throws `StateError`).
   - `deletePendingCommand()` refuses to delete.

---

### 2.9 In-Memory Store Parity & Nullable `copyWith` Semantics

1. **Parity:** `InMemoryPendingRewardCommandStore` (in both `packages/learnward_test_support` and `apps/mobile/lib/app/bootstrap/in_memory_repositories.dart`) strictly mirrors SQLite behavior:
   - Atomic identity immutability validation.
   - Strict 4-state lease availability predicate.
   - Irreversible provenance and legacy quarantine enforcement.
   - Non-dispatch CAS pause and resume methods.
2. **Explicit Nullable `copyWith` Semantics:** Introduces a `_Sentinel` token in `PendingRewardCommand.copyWith()` to allow explicitly setting nullable fields (`leaseToken`, `leaseExpiresAt`, `lastErrorMessage`, `nextAttemptAt`, etc.) to `null` while preserving backward compatibility for omitted arguments. Includes a dedicated `clearLease()` convenience helper.

---

## 3. Explicit Deferral Contract

The following components are **explicitly deferred** to subsequent sub-slices:
1. Automated background outbox timer loops and recovery drainage (`OutboxRecoveryDispatcher` $\to$ Slice 4A-1).
2. Instrumentation of adult reward operations (`fulfillRewardRedemption`, `cancelRewardRedemption` $\to$ Slice 4A-2).
3. Assessment draft resumability, adaptive JPEG compression, Storage 409 conflict handling, and database evidence registration (`register_assessment_evidence` $\to$ Slice 4B).
4. Manual user-facing recovery dialogs, error banners, and device containment UI (`apps/mobile` $\to$ Slice 4C).
5. Post-archive read-only command receipt reconciliation RPCs.

---

## 4. Architectural Invariance Verification

- **Frozen Supabase Migrations:** All migrations in `supabase/migrations/` remain completely untouched and frozen (0 diff).
- **Accepted ADR Compliance:** Complies with [ADR 0008](../adr/0008-phase-6-pilot-hardening.md) Decisions 1 and 2.
- **Economic Invariance:** Zero duplicate ledger debits, zero duplicate wheel spins, zero duplicate reward redemptions.
- **Toolchain Integrity:** Drift `build_runner` produces 0 diff against checked-in code; `flutter analyze` reports 0 warnings/errors.
