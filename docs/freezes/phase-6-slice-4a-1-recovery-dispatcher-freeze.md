# Phase 6 Freeze Receipt — Actor-Aware Spin/Redeem Recovery Runtime (Slice 4A-1)

**Status:** FROZEN  
**Target:** Phase 6 Slice 4A-1 — Actor-Aware Spin/Redeem Recovery Runtime (`Shared Foreground/Background Recovery Coordinator, Token-Fenced markPossiblyDispatched CAS, Strict Authenticated Actor & Family Fencing, Session Generation Invalidation, Typed Recovery Error Classifier, Jittered Exponential Backoff, App-Active Recovery Dispatcher, Multi-Connection SQLite Concurrency Protection, Drift Schema v6 Immutability Preservation, Acceptance Criteria A01–A24, Concurrency Hardening R24-4/R24-5/R24-6`)  
**Implementation PR:** [#24 — feat(phase-6): implement actor-aware recovery dispatcher (Slice 4A-1)](https://github.com/thedusk4203/LearnWard/pull/24)  
**Approved Implementation HEAD:** `bd33f21415676ca745c5a8651cf54ab8c85815ca`  
**PR CI Run ID:** [`42506788697`](https://github.com/thedusk4203/LearnWard/actions/runs/42506788697) — **SUCCESS (4/4 green)**  
**Implementation Merge SHA:** `6b1d4da03254264ac180e4b1503de93e146c963e`  
**Post-Merge Main SHA:** `6b1d4da03254264ac180e4b1503de93e146c963e`  
**Post-Merge Main CI:** Run ID [`42509975267`](https://github.com/thedusk4203/LearnWard/actions/runs/42509975267) — **SUCCESS (4/4 green)**  
**Merge Timestamp:** `2026-11-08T18:25:44Z`  
**Freeze Date:** `2026-11-09`  
**ADR:** [ADR 0008 — Phase 6 Pilot Hardening](../adr/0008-phase-6-pilot-hardening.md) (`ACCEPTED`)  
**Upstream Contracts:**
- [ADR 0001–0007](../adr/)
- [Phase 1–5.2 Freeze Receipts](.)
- [Phase 6 Drift v5 Foundation Freeze](phase-6-drift-v5-foundation-freeze.md)
- [Phase 6 Slice 4A-0 Drift v6 Foundation Freeze](phase-6-slice-4a-0-drift-v6-foundation-freeze.md)
- [Phase 6 Slice 4A-1 Final Implementation Contract](../20-phase-6-slice-4a-1-final-implementation-contract.md)
- [Phase 6 Master Delivery and Pilot Gates](../21-phase-6-master-delivery-and-pilot-gates.md)

---

## 1. Verified CI & Test Suite Totals

Final verified test totals from post-merge main CI run [`42509975267`](https://github.com/thedusk4203/LearnWard/actions/runs/42509975267) on exact merge commit `6b1d4da03254264ac180e4b1503de93e146c963e`:

| Test Suite / Job | Total Tests | Passed | Result | Duration |
|---|---|---|---|---|
| **Format, analyze and test** | All suites | All | **PASS** | 2m 29s |
| - *learnward_domain* | 196 | 196 | **PASS** | — |
| - *learnward_application* | 75 | 75 | **PASS** | — |
| - *learnward_data* | 111 | 111 | **PASS** | — |
| - *learnward_test_support* | 14 | 14 | **PASS** | — |
| - *learnward_design_system* | 2 | 2 | **PASS** | — |
| - *apps/mobile* widget & flow tests | 81 | 81 | **PASS** | — |
| - *Drift build_runner diff assertion* | Clean (0 diff) | Clean | **PASS** | — |
| **Supabase migrations & RLS security** | 659 pgTAP + 19 scripts | All | **PASS** | 2m 31s |
| - *pgTAP Test Files* (11 files) | 659 | 659 | **PASS** | — |
| - *Concurrency & Integration Scripts* | 19 | 19 | **PASS** | — |
| **iOS simulator compile** | Flutter build ios --simulator | Success | **PASS** | 3m 24s |
| **Android debug build** | Gradle assembleDebug | Success | **PASS** | 5m 12s |

---

## 2. Verified Acceptance Criteria Matrix (A01–A24)

Every acceptance scenario defined in `docs/20-phase-6-slice-4a-1-final-implementation-contract.md` is covered by deterministic regression tests in `packages/learnward_data/test/actor_aware_recovery_acceptance_test.dart` and application unit suites:

| ID | Specification Requirement | Verification Evidence / Test Assertion | Status |
|---|---|---|---|
| **A01** | Fresh Spin and Redeem: Insert `never_dispatched`, acquire claim, durable `possibly_dispatched` mark, then exactly one mutating RPC. | Verified: DB records 1 row in `never_dispatched`, transitions to `possibly_dispatched` with active lease, fires 1 RPC, then marks `confirmed_committed`. | **PASS** |
| **A02** | Marker rejects wrong token: Attempting pre-dispatch CAS with mismatched token fails closed. | Verified: Returns `false`, zero mutating RPC executed, DB record preserved with existing lease token and status. | **PASS** |
| **A03** | Marker rejects expired/replaced token: Lease expired or stolen by newer claimant rejects pre-dispatch write. | Verified: Returns `false`, zero RPC, newly acquired claim lease and token on DB row completely untouched. | **PASS** |
| **A04** | Crash immediately after pre-dispatch SQLite commit: Restart recovers `possibly_dispatched` record without generating a new UUID. | Verified: On reopen, exact original `command_id` is reloaded; no duplicate UUID generated; idempotently reconciled. | **PASS** |
| **A05** | Response lost after authoritative server commit: Network drops after RPC succeeds. | Verified: Retry executes with exact original `command_id`; server returns prior receipt; zero duplicate debits or spins. | **PASS** |
| **A06** | Two SQLite connections claim concurrently: Multi-connection race for same pending command. | Verified: Exactly one connection successfully acquires exclusive lease; second claimant receives `false`; zero parallel RPCs. | **PASS** |
| **A07** | Slow worker A / expired lease / Worker B takeover: Worker A cannot release, complete, or mutate Worker B's claimed row. | Verified: CAS predicates reject Worker A's stale lease token; Worker B's active lease and data remain invariant. | **PASS** |
| **A08** | Same actor switches active family mid-flow: Execution checks target family match. | Verified: Preflight detects family mismatch; zero mutating RPC sent; command row preserved dormant for original family. | **PASS** |
| **A09** | Actor logs out before final RPC: Session invalidated before network dispatch. | Verified: Live session check fails closed; zero RPC sent; journal command preserved for original actor upon return. | **PASS** |
| **A10** | Actor logs out while RPC in-flight: Session generation changes before response handling. | Verified: RPC response discarded; journal left unresolved; Worker B cannot inherit command; reconciled on A's return. | **PASS** |
| **A11** | Actor B signs in on shared device: A's commands exist in local store. | Verified: Worker B drains only B's authorized family; A's commands paused via CAS if authorized or left dormant; zero RPC for A. | **PASS** |
| **A12** | Original actor A returns: Resumes paused command via CAS. | Verified: Actor A re-authenticates, atomically resumes paused command, acquires exclusive claim, and replays exact original ID. | **PASS** |
| **A13** | Paired child grant revoked (`status='revoked'` & `revoked_at IS NOT NULL`): Positive revocation verified. | Verified: Fails closed, marks command quarantined with `revocationEvidence`, and halts automatic dispatch. | **PASS** |
| **A14** | `42501` without positive revocation evidence: Ambiguous authorization failure. | Verified: Ambiguous permission error stops automatic retries; transitions to `quarantined_unknown_outcome`; zero journal deletion. | **PASS** |
| **A15** | Child archived after command may have committed: Server returns 42501 / archive notice. | Verified: Unresolved command quarantined as unknown outcome; original command ID preserved; no false terminal deletion. | **PASS** |
| **A16** | Backoff after 1, 2, 3 failures: Persisted schedule and retry increment. | Verified: SQLite atomically increments `retry_count`; `next_attempt_at` persisted with full jitter; dispatcher skips until due. | **PASS** |
| **A17** | Daily cap / insufficient RP / disabled wheel: Operation-specific terminal classification. | Verified: `LW201`, `LW202`, `LW203`, `LW206` definitively classified as terminal rejections; journal safely completed. | **PASS** |
| **A18** | Reward unavailable: Definitive `LW205` handling. | Verified: `LW205` verified from typed PostgREST error; journal safely completed; distinct future intent permitted. | **PASS** |
| **A19** | Legacy v4/v5 unknown actor and `unknown_legacy`: Historical migration safety. | Verified: Claim CAS excludes `unknown_legacy` and null actors; zero claim, zero RPC, 100% journal preservation. | **PASS** |
| **A20** | Existing foreground wheel/store flows: UI backward compatibility. | Verified: `SpinRewardWheel` and `RedeemStoreReward` route through `RecoveryCoordinator`; identical UI feedback; zero bypass. | **PASS** |
| **A21** | Auth stream emits error on offline refresh: Stream listener resilience. | Verified: Auth session adapter handles `onError` without uncaught crash; fails closed; prevents speculative mutation. | **PASS** |
| **A22** | 10-row queue limit with wrong-family rows first: Family starvation protection. | Verified: Store query filters by `familyId` before applying limit; active family commands dispatched without starvation. | **PASS** |
| **A23** | Crash/kill with live claim: Reopening database with unexpired lease. | Verified: Live lease respected; zero force-clearing; claimant waits for natural lease expiration before reclaim. | **PASS** |
| **A24** | Definite success response with stale token: Completion response arrives after lease expiry. | Verified: Token-fenced completion matches zero rows; does not overwrite or delete newly claimed ownership. | **PASS** |

---

## 3. Concurrency Hardening & State Matrix Verification (R24-4, R24-5, R24-6)

During rounds 4, 5, and 6 of independent architecture audit, several critical edge cases were identified, hardened, and verified with dedicated multi-connection SQLite regression suites:

### 3.1 R24-4-01: Atomic Fresh-Command Creation across Concurrent Writers
- **Problem:** A check-then-insert race allowed two concurrent foreground calls (e.g. rapid double-tap on Spin/Redeem) to allocate distinct UUIDs before either inserted.
- **Hardening:** `RecoveryCoordinator.execute()` implements atomic check-or-insert synchronization across independent threads and connections.
- **Evidence:** Tested with 2 independent SQLite connections calling concurrent execute for identical operation target: exactly 1 command is inserted, exactly 1 mutating RPC is dispatched, and the second caller receives `alreadyInFlight` or awaits existing receipt.

### 3.2 R24-4-02: Exclusive Claim Ownership
- **Problem:** Preexisting unexpired leases could be reused by independent execution attempts merely because they belonged to the same actor.
- **Hardening:** Removed caller lease adoption. Every independent execution attempt must acquire its own exclusive claim token via atomic CAS. Preexisting unexpired leases held by another worker yield `alreadyInFlight`.
- **Evidence:** Concurrent worker tests prove an in-flight worker cannot be hijacked or piggybacked by another worker without lease expiration.

### 3.3 R24-5-01 & R24-5-02: Preflight Lease Protection & Fail-Closed Mismatch
- **Problem:** Pre-claim family or actor mismatch preflight in `RecoveryCoordinator` read an existing command's lease token and called `releaseClaim()` without owning that lease.
- **Hardening:** Strictly enforced lease fencing: only the execution context that successfully acquired an exclusive lease is permitted to release it. Family or actor mismatches return fail-closed without mutating or releasing journal claims.
- **Evidence:** Worker A owns an unexpired lease; Worker B attempts execution with mismatched family: Worker A's lease token, expiry, and retry count remain completely unchanged; zero mutating RPC from Worker B.

### 3.4 R24-6-01: 16-State Golden State Matrix & Explicit Precedence
- **Hardening:** Verified in `pending_reward_commands_atomic_cas_test.dart` against all 16 combinations of journal states. Conflicting or ambiguous states (`quarantined_unknown_outcome`, `unknown_legacy`) strictly fail closed, taking precedence over tentative flags and preventing duplicate UUID allocation.

---

## 4. Zero-Diff Contracts & Schema Immutability Confirmation

| Asset / Boundary | Verification Result | Confirmation Details |
|---|---|---|
| **Drift Schema v6** | **0 diff (100% frozen)** | `packages/learnward_data/lib/src/database/app_database.dart` generated schema `app_database.g.dart` matches baseline identically. |
| **SQLite Migrations** | **0 diff (100% frozen)** | Multi-version migration matrix (`v1..v5 -> v6`) remains structurally unchanged. |
| **Supabase Migrations** | **0 diff (100% frozen)** | `supabase/migrations/` has zero diff; no new tables, triggers, or functions. |
| **Server-Authoritative Economics** | **0 diff (100% frozen)** | `spin_reward_wheel`, `redeem_store_reward`, and ledger idempotency contracts unchanged. |
| **RLS Policies** | **0 diff (100% frozen)** | 659 pgTAP tests and 19 concurrency scripts pass with zero modifications. |

---

## 5. Deployment Safety & Feature Flag Confirmation

1. **Feature Flag Default:**
   - In `apps/mobile/lib/app/bootstrap/app_config.dart`:
     ```dart
     const bool kRecoveryDispatcherEnabledDefault = false;
     ```
   - Confirmed: `RECOVERY_DISPATCHER_ENABLED=false` is enforced by default in all application configurations.
2. **Production Deployment:**
   - No production deployment, store release, or external pilot has been executed.
   - The in-process recovery dispatcher is strictly gated behind this configuration flag.

---

## 6. Operational Limitations Remaining for Slice 4A-2 & Beyond

1. **Adult Fulfill/Cancel Operations:**
   - `fulfill_reward` and `cancel_reward` remain excluded from the v6 claim predicate (`AppDatabase.claimCommandForExecution`). Slice 4A-2 must implement the scoped claim CAS extension for adult mutations.
2. **Child Archive Handling during Fulfill/Cancel:**
   - Handling of commands targeting children archived after mutation issuance remains for Slice 4A-2.
3. **No Native OS Headless Background Execution:**
   - The recovery dispatcher runs strictly within the active Flutter app lifecycle (`AppLifecycleState.resumed`). Headless OS background execution (WorkManager / BGTaskScheduler) is out of scope and not guaranteed.
4. **Assessment Evidence Recovery:**
   - Assessment photo drafts, upload resumability, and Storage 409 reconciliation are deferred to Slice 4B-0 and 4B-1.
