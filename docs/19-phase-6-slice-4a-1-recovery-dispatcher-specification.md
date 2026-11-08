# Phase 6 Slice 4A-1 Implementation Specification — Actor-Aware Recovery Dispatcher (Spin & Redeem)

> [!NOTE]
> **SUPERSEDED BY AUTHORITATIVE CONTRACT:**  
> This specification document is superseded by [20-phase-6-slice-4a-1-final-implementation-contract.md](20-phase-6-slice-4a-1-final-implementation-contract.md). All implementation details, ports, error policies, SQL predicates, and acceptance criteria A01–A24 follow `docs/20-...` exactly.

**Status:** SUPERSEDED BY CONTRACT 20 (REFERENCE ARCHITECTURE)  
**Date:** 2026-11-07  
**Target:** Phase 6 Slice 4A-1 — Core Actor-Aware Recovery Engine for `spinRewardWheel` and `redeemStoreReward`  
**Prerequisite:** [Phase 6 Slice 4A-0 Drift v6 Foundation Freeze](freezes/phase-6-slice-4a-0-drift-v6-foundation-freeze.md) (`FROZEN` @ `88908ac309cda0eddcd549121ea0638c6979a384`)  
**Upstream Contracts:**
- [ADR 0008 — Phase 6 Pilot Hardening](adr/0008-phase-6-pilot-hardening.md) (`ACCEPTED`)
- [Phase 6 Actor-Aware Offline Recovery Readiness Review](18-phase-6-actor-aware-offline-recovery-readiness-review.md) (`ACCEPTED`)
- [Phase 6 Slice 4A-1 Final Implementation Contract](20-phase-6-slice-4a-1-final-implementation-contract.md) (`AUTHORITATIVE`)

---

## 1. Executive Summary & Architectural Scope

Following the successful merge and freeze of **Slice 4A-0** (Drift schema v6, multi-version migration matrix, atomic CAS claim primitives, and stale-worker fencing), **Slice 4A-1** delivers the core runtime recovery dispatcher.

### 1.1 Strict Boundary Definition

| In Scope (Slice 4A-1) | Explicitly Excluded (Subsequent Slices) |
|---|---|
| • `spinRewardWheel` offline recovery and foreground claim unification | • `fulfillRewardRedemption` and `cancelRewardRedemption` (Slice 4A-2) |
| • `redeemStoreReward` offline recovery and foreground claim unification | • `local_assessment_drafts` submission & Storage 409 recovery (Slice 4B) |
| • Authenticated session actor verification before network calls | • Manual user recovery dialogs & error state widgets (Slice 4C) |
| • Atomic claim acquisition, token reuse, and fenced completion | • Post-archive read-only command reconciliation RPCs |
| • Durable exponential backoff with full jitter across app restarts | • Push notifications (APNs / FCM) |
| • Dual-state machine handling (`active`, `pending_original_actor`, `quarantined`) | • Automatic replay of `unknown_legacy` commands |
| • Distinguishing SQLSTATE `42501`, business errors (`LW201`–`LW206`), and device revocation | • Production migration deployments or binary distribution |

---

## 2. Core Dispatcher Capabilities (13 Invariants)

### 2.1 Unified Foreground/Background Claim Protocol
- **Single Execution Pipeline:** Foreground user actions (e.g. spinning wheel, tapping retry in banner) and background recovery drainage share the exact same underlying claim execution pipeline.
- **TOCTOU Elimination:** When a foreground action initiates:
  1. It attempts to acquire an atomic claim (`acquireClaim(commandId, actorUserId, leaseDuration)`).
  2. If the command is already leased by the background worker, the foreground caller awaits completion or gracefully observes the in-flight operation rather than initiating a duplicate concurrent RPC.
  3. If the background worker encounters an active foreground lease, it skips the command until the lease expires or completes.

### 2.2 Authenticated Original Actor Verification
- **Trusted Session Proof:** Before initiating any network RPC, the dispatcher requires proof of the *currently authenticated session* (`session.user.id` from `currentUserIdProvider`).
- **Never Trust Local Row as Auth Proof:** The dispatcher *never* assumes that because `command.actorUserId` is stored in the database, the caller is authorized. If `currentUserId != command.actorUserId`, network execution is strictly refused.
- **Fail-Closed Mismatch:** Mismatched commands are paused via `pauseMismatchedActorCommand` (`active` $\to$ `pending_original_actor`).

### 2.3 Atomic Claim Acquisition, Token Reuse & Fenced Completion
- **Claim Acquisition:** Uses `PendingRewardCommandStore.acquireClaim()`. Generates a unique cryptographically random `leaseToken` and commits `leaseExpiresAt = now + leaseDuration` (default: 30 seconds).
- **Token Reuse on Retry:** The acquired `leaseToken` is threaded through the execution lifecycle.
- **Fenced Completion:** Upon successful server commitment (HTTP 200/201), the command is deleted conditionally using `completeCommand(commandId, leaseToken)`. If a stale worker's lease expired and was reclaimed, the completion affects 0 rows and fails closed.
- **Fenced Release:** On retryable network failure, the command is released via `releaseClaim(commandId, leaseToken, nextAttemptAt, lastErrorMessage)`, atomically clearing the lease and advancing `retry_count`.

### 2.4 Invariant Command Identity on Replay
- **Exact UUID Replay:** Every authorized replay of an unresolved operation (`possibly_dispatched`) **MUST REUSE THE EXACT SAME `command_id`**.
- **Regeneration Prohibited:** Regenerating a command UUID for an existing pending command is prohibited, as it would defeat server-authoritative idempotency and trigger duplicate reward debits or spins.

### 2.5 Bounded Exponential Backoff with Full Jitter
To prevent thundering herds on recovery:
- $t_{\text{base}} = 2\text{ seconds}$
- Multiplier: $2^{\text{retry\_count}}$
- Ceiling: $t_{\max} = 60\text{ seconds}$
- Full Jitter Formula:
  $$\Delta t = \text{random}\left(0,\, \min\left(t_{\max},\, t_{\text{base}} \times 2^{\text{retry\_count}}\right)\right)$$
- `nextAttemptAt = now + Duration(seconds: Delta_t)` is persisted to SQLite via `releaseClaim()`.

### 2.6 Durable Retry Scheduling Across App Restart
- `next_attempt_at` and `retry_count` reside in SQLite.
- When the application process terminates, crashes, or is evicted by the OS:
  - On next boot, `listClaimableCommands(actorUserId: currentUserId, limit: 10, now: now)` evaluates `next_attempt_at <= now`.
  - Commands not yet due for retry remain safely dormant in SQLite without resetting their exponential backoff progress.

### 2.7 Response-Loss & Server-Committed Receipt Reconciliation
- **Pre-Dispatch Barrier:** `dispatch_state = 'possibly_dispatched'` is committed before invoking the remote RPC.
- **Lost Response Reconciliation:** If the server commits the transaction and writes to `public.command_receipts`, but the HTTP connection drops before the client receives the response:
  - On retry, the dispatcher re-sends the exact same `commandId`.
  - The server-side RPC detects the existing receipt in `command_receipts` and returns the committed outcome without re-executing business logic.
  - The client transitions the journal record to `confirmed_committed` and deletes it via `completeCommand(commandId, leaseToken)`.

### 2.8 Session Changes, Logout & Family-Switch Containment
- **Dispatcher Interruption:** On user logout or profile switch, any in-flight dispatcher timer is immediately cancelled, and in-memory execution queues are cleared.
- **Outbox Sweep on Auth Change:**
  - Upon user sign-in:
    1. `listMismatchedActiveCommands(familyId, currentUserId)` finds active commands belonging to previous actors in the family and atomically pauses them (`pending_original_actor`).
    2. `listPausedOriginalActorCommands(familyId, currentUserId)` discovers previously paused commands belonging to the newly signed-in actor and atomically resumes them (`active`).

### 2.9 Pending-Original-Actor Pause & Safe Resumption
- **Atomic Pause CAS:** Transition from `active` to `pending_original_actor` requires:
  - Authenticated user ID $\neq$ `command.actor_user_id`.
  - Command is in `active` state with valid dispatch provenance.
  - Active lease is either absent or expired.
  - Clears any lease metadata and sets `last_error_message`.
- **Atomic Resume CAS:** Transition from `pending_original_actor` to `active` requires:
  - Authenticated user ID $==$ `command.actor_user_id`.
  - Resets `last_error_message = NULL` and clears lease metadata.
- **Zero RPC:** Neither pause nor resume performs network I/O.

### 2.10 Archived-Child Fail-Closed Handling
- If a child profile is archived while a reward command is pending:
  - The server mutation RPC returns PostgreSQL error `42501` with message `Child profile is archived`.
  - The dispatcher catches this terminal condition, halts retry loops, transitions the command to `quarantined_unknown_outcome` (or deletes if definitely uncommitted), and logs a sanitized diagnostic message.

### 2.11 Error Classification (SQLSTATE 42501 vs. Revocation vs. Domain Errors)
- **Domain Errors (`LW201`–`LW206`):**
  - Definite business rule rejections (e.g. `LW201: Insufficient points`, `LW202: Daily spin limit reached`, `LW203: Insufficient eligible wheel pool`, `LW205: Reward unavailable`, `LW206: Wheel disabled`). Note: `LW204` is not on the terminal deletion whitelist.
  - Terminal $\implies$ complete command or stamp `terminal_error`, delete journal, display user-friendly error without retry.
- **SQLSTATE `42501` (Permission Denied):**
  - Step 1: For paired child devices, query `public.child_device_grants` (`SELECT status, revoked_at WHERE auth_user_id = auth.uid()`).
  - Step 2: If `status = 'revoked' AND revoked_at IS NOT NULL`, positively confirm `DEVICE_REVOKED` $\implies$ immediately transition pending commands to `quarantined_unknown_outcome`, halt dispatcher, and signal application containment.
  - Step 3: If grant is not revoked, treat as authorization failure (e.g. session token expired, child profile archived) $\implies$ pause command or quarantine; do **not** enter a tight retry loop.
- **Transient Network / 5xx / Socket / Timeout Errors:**
  - Transient $\implies$ release claim with backoff (`releaseClaim`).

### 2.12 No Duplicate RP Debit, Redemption, or Wheel Spin
- Guaranteed by:
  1. Durable pre-dispatch marker committed to SQLite before network transmission.
  2. Exact command ID reuse on retry.
  3. Server-authoritative idempotency in `public.command_receipts`.
  4. Atomic lease exclusivity preventing duplicate concurrent client RPC dispatches.

### 2.13 Legacy & Quarantined Command Invariant
- Commands with `dispatch_state = 'unknown_legacy'` or `recovery_state = 'quarantined_unknown_outcome'` are filtered out by `listClaimableCommands()` and rejected by `acquireClaim()`.
- They are **never** automatically dispatched over the network. They require manual resolution (Slice 4C).

---

## 3. Prerequisites & Foreground Path Refactoring (Before Dispatcher Enablement)

Before enabling the background recovery loop in `learnward_application`:

### 3.1 Lease-Aware Foreground Execution Refactor
Existing use cases (`SpinRewardWheel` in `spin_reward_wheel.dart` and `RedeemStoreReward` in `redeem_store_reward.dart`) currently write directly to `pendingCommandStore.savePendingCommand()`.
- **Refactoring:**
  1. Fresh command creation: Call `savePendingCommand()` with `dispatchState = CommandDispatchState.neverDispatched`.
  2. Dispatch preparation: Call `acquireClaim(commandId, actorUserId, leaseDuration)`.
  3. Commit pre-dispatch marker with lease token: Call `markPossiblyDispatched(commandId, leaseToken, authenticatedActorId, now)`. (Direct `savePendingCommand` is forbidden because active lease blocks generic overwrites).
  4. Remote RPC execution: Pass `commandId` to Supabase RPC.
  5. On Success: Call `completeCommand(commandId, leaseToken)`.
  6. On Retryable Failure: Call `releaseClaim(commandId, leaseToken, nextAttemptAt, lastErrorMessage)`.
  7. On Terminal Whitelisted Business Failure (`LW201`, `LW202`, `LW203`, `LW205`, `LW206`): Call `completeCommand(commandId, leaseToken)`.

### 3.2 Restricting Generic State Transitions
- Direct calls to `savePendingCommand` must not bypass active leases or scheduled retries.
- Any attempt to overwrite an active lease or mutate identity fields is already blocked with `StateError` (Slice 4A-0).

### 3.3 Session Authentication Proof Guarantee
- Refactor use cases to accept an authenticated `UserSession` or `currentUserIdProvider` reference rather than trusting an unverified caller string.

---

## 4. Integration & Concurrency Test Plan

Testing must run against **real SQLite databases** on disk (via `AppDatabase` with `NativeDatabase(File(...))`) combined with a **mocked server-authoritative idempotency RPC harness**:

| Test ID | Scenario | Expected Behavior |
|---|---|---|
| **T1: Foreground / Background Claim Race** | Foreground use case and background dispatcher attempt to claim the same command concurrently. | Exactly one worker receives a valid `leaseToken`; the other receives `null`. Zero duplicate network RPC calls. |
| **T2: Crash Before Dispatch** | Pre-dispatch marker committed to SQLite, then process abruptly terminates before network transmission. | On restart, command remains in SQLite with `possibly_dispatched`. Dispatcher reclaims command, reuses exact same `commandId`, and executes RPC. |
| **T3: Response Loss After Server Commit** | Server commits RPC and writes `command_receipts`, but client network drops before receiving HTTP response. | Dispatcher retries with exact same `commandId`. Server returns existing receipt. Dispatcher marks `confirmed_committed`, deletes journal entry. Exactly 1 ledger debit / 1 spin recorded. |
| **T4: Expired Lease Takeover** | Worker A acquires lease for 5s; network delays worker A for 6s. Worker B attempts claim at $t = 6\text{s}$. | Worker B successfully claims row with a new `leaseToken`. Worker A's subsequent attempts to complete fail (0 rows affected). |
| **T5: Stale Worker Fencing** | Worker A is delayed past expiration; Worker B claims and completes command. Worker A awakens and calls `completeCommand` or `releaseClaim`. | Worker A's calls return `false`; row is not erroneously mutated or resurrected. |
| **T6: Actor Switching & Automatic Pause** | User A queues commands and switches account to User B. User B's dispatcher runs outbox scan. | Commands for User A are discovered via `listMismatchedActiveCommands` and transitioned to `pending_original_actor` via atomic CAS. Zero network calls made. |
| **T7: Original Actor Sign-In & Resumption** | User A signs back in. Dispatcher runs resumption scan. | Commands are discovered via `listPausedOriginalActorCommands`, transitioned back to `active` via atomic CAS, and drained safely. |
| **T8: Bounded Backoff Persistence Across Restart** | Command fails with retryable error. `retryCount` incremented to 3; `nextAttemptAt` set to $t0 + 16\text{s}$. Database closed and reopened at $t0 + 5\text{s}$. | `listClaimableCommands` at $t0 + 5\text{s}$ returns empty list. At $t0 + 17\text{s}$, returns command. |
| **T9: Archived Child Handling** | Child profile is archived on server; dispatcher attempts replay. | Server returns `LW301` / `42501`. Dispatcher catches error, transitions command to `quarantined_unknown_outcome`, and stops retrying. |
| **T10: Paired Child Device Revocation** | Child device grant revoked on server (`status = 'revoked'`). Dispatcher encounters `42501`. | Dispatcher queries `child_device_grants`, confirms revocation, transitions pending commands to quarantine, halts outbox loop, and signals device containment. |

---

## 5. Prioritized Pilot Risk Register (Independent Pilot Blockers)

In accordance with independent audit guidelines, the following pilot blockers are tracked separately from Slice 4A-1:

| Priority | Risk / Blocker | Description | Target Slice / Milestone |
|---|---|---|---|
| **P1** | **Unsafe Local Evidence Deletion** | Local compressed photos deleted prior to verified server storage confirmation or after draft failure. | Slice 4B (Evidence Resumability) |
| **P2** | **Storage 409 Content Integrity & Uncertain Cleanup** | Upload conflicts when same evidence ID exists in bucket without verification of SHA-256 bit-level identity. | Slice 4B (Evidence Resumability) |
| **P3** | **Child Mode Session & Account Switching** | Device sharing between multiple children or parent/child without complete in-memory Riverpod provider invalidation. | Slice 4C (Session Lifecycle) |
| **P4** | **Parent PIN Strengthening** | Brute-force protection, failed-attempt lockout throttling, and argon2/pbkdf2 salt verification for Parent Gate. | Slice 4C (Session Lifecycle) |
| **P5** | **Production Configuration & Release Signing** | Secure CI/CD signing keys, environment variable validation, ProGuard rules, and strip debug flags for release binaries. | Phase 6 Release Gate |
| **P6** | **Accessibility & Privacy Readiness** | Screen reader navigation (TalkBack / VoiceOver), minimum touch targets, and COPPA/GDPR-K local log compliance. | Phase 6 Release Gate |

---

## 6. Recommended Next PR Boundary

- **PR #24:** Implement Phase 6 Slice 4A-1 — Actor-Aware Recovery Dispatcher for `spinRewardWheel` and `redeemStoreReward`.
- **Target Packages:** `packages/learnward_application` and `packages/learnward_data`.
- **Zero UI Changes:** Mobile screens and widgets remain untouched until Slice 4C.
