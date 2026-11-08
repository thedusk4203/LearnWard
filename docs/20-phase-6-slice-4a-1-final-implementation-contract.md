# LearnWard — Phase 6 Slice 4A-1 Final Implementation Contract

**Status:** IMPLEMENTATION-READY DESIGN — independent planning handoff, **not implemented**  
**Plan date:** 2026-11-07  
**Repository:** https://github.com/thedusk4203/LearnWard  
**Authoritative baseline `main`:** `7584147a3ca906c87dccb6daf52f5b7415ba8a54`  
**4A-0 implementation merge:** `88908ac309cda0eddcd549121ea0638c6979a384`  
**Verified CI:** `42366631328` (merge) and `42368090260` (docs), 4/4 passed each.  
**Supersedes:** unsafe execution steps and inaccurate error descriptions in `docs/19-phase-6-slice-4a-1-recovery-dispatcher-specification.md`, while preserving frozen ADR 0008 and the Drift v6 contract.  
**Implementation owner:** coding agent. **Design/acceptance owner:** independent reviewer/user.  
**Scope:** actor-aware, restart-safe command recovery for `spin_wheel` and `redeem_reward` only.

## 1. Baseline verified against source

- `AppDatabase` at Drift schema **v6** implements lease CAS, `releaseClaim`, `completeCommand`, actor pause/resume, discovery and strict `savePendingCommand`. It is **frozen**. Its `savePendingCommand` rejects a write to an actively leased row. Consequently **`acquireClaim -> savePendingCommand(possiblyDispatched)` is impossible**. A token-fenced pre-dispatch marker API is mandatory.
- `SpinRewardWheel` and `RedeemStoreReward` currently call `savePendingCommand` and then RPC, with generic `deletePendingCommand`. Neither currently acquires a claim. Existing UI entry points in `apps/mobile/lib/features/rewards/presentation/child_wheel_screen.dart` and `child_store_screen.dart` instantiate the use cases directly.
- `currentUserIdProvider` currently reads `authState.value?.session?.user.id ?? client?.auth.currentUser?.id`. It is an **identity display convenience**, not sufficient proof that a current session is valid and authorized to mutate.
- The server mutation RPCs `public.spin_reward_wheel` and `public.redeem_store_reward` are authoritative; they implement same-command-ID receipt checks **after authorization**. They may reject a replay following archival or revoked authorization even if the historical operation committed. **Do not interpret such rejection as non-execution.**
- `child_device_grants_select` RLS allows a paired child actor to read **its own** grant, including a revoked row, using `auth_user_id = auth.uid()`; lack of a row or failed SELECT is not proof of revocation.
- `LW201` = insufficient RP; `LW202` = wheel daily cap; `LW203` = insufficient eligible wheel pool; `LW205` = reward unavailable; `LW206` = wheel disabled. **`LW301` is not defined by the reviewed SQL.** Archived-child mutation paths use `42501` with relevant messages; **42501 alone is ambiguous**.

## 2. Locked scope and non-goals

**Implement:** application execution coordinator, auth-session port, app-level scheduler triggered by startup/sign-in/resume/connectivity, token-fenced SQLite pre-dispatch marker, shared Spin/Redeem foreground path, deterministic backoff, family-bound discovery, typed error classifier, mobile provider/call-site wiring (minimum necessary), in-memory parity, tests.

**Do not implement:** Fulfill/Cancel (4A-2), assessment upload/recovery/Storage 409 (4B), manual resolution widgets/Parent PIN/Child Mode UX (4C), APNs/FCM/background OS service, new economic formulas/RPC signatures, server migrations, new Drift version, release/distribution. **No pilot launch.**

**App lifecycle wording:** "background" refers to an **in-process recovery dispatcher** while the app is active; not guaranteed headless processing when Android/iOS suspends the app. Existing journal enables next-launch recovery.

## 3. Ownership and dependency graph

```text
Supabase Auth / family+child read-only verification
        |   (validated session + session generation, family authorization)
        v
AuthSessionPort + RecoveryAuthorizationPort (application contracts)
        |
App Session Adapter (Supabase) + app provider wiring
        |
        v
RecoveryCoordinator (shared FG/BG workflow)
        +--> PendingRewardCommandStore (v6 CAS + NEW markPossiblyDispatched)
        +--> RewardRepository / WheelRepository (existing RPCs)
        +--> Clock, Jitter, NetworkState, Lifecycle hooks
        |
        v
Command execution outcome (success / retryable / paused / quarantined / rejected)
```

All execution must pass through one coordinator. UI triggers execution but must not call raw mutation repositories in parallel with it.

## 4. Application ports and typed contracts (DESIGN, not implementation)

1. `AuthSessionPort.validateForMutation()` yields either `ValidatedActorContext` or a typed fail-closed failure. Context contains `userId`, session-generation identity, validity observation time and (internal only) refresh-safe session handle. It **must not expose tokens to logs**. A second check runs immediately before remote RPC.
2. `RecoveryAuthorizationPort.verifyTarget({context, familyId, childId, operation})` returns `authorized`, `definitelyDenied`, or `unverified` (network/ambiguous). Adults require active membership of the target family; paired child actors require active grant for the exact child and family. Archived child is not eligible. Never use `user_metadata` as authorization. Server RPC remains final authority; preflight is an extra safety boundary, not a substitute.
3. `RecoveryCoordinator.execute({operation, familyId, childId, rewardId?, requestedCommandId?, trigger})` is the **only** application-facing Spin/Redeem mutation path. Trigger is `foreground` or `recovery`; both follow the same claim/mark/RPC flow. Results are typed (`committed`, `alreadyInFlight`, `scheduled`, `pendingOriginalActor`, `quarantined`, `terminalRejection`, `authUnavailable`). Existing foreground API return types can use a thin compatibility wrapper, with explicit, non-silent mapping of non-success states.
4. `OutboxRecoveryDispatcher.drainOnce({validatedContext, activeFamilyId, limit})` scans eligible commands once, executes bounded work, and returns a report. A small lifecycle adapter schedules `drainOnce` on app resume, authenticated sign-in, explicit user retry and reasonable in-app timer/connectivity signals. No unbounded or headless loop.
5. `Clock` and `JitterSource` are injectable. `RecoveryErrorClassifier` operates on typed PostgREST/network exceptions (code, message, HTTP status, stack-free detail) instead of unstructured `toString().contains` checks wherever typed fields exist.
6. **Store port extension:**

```dart
Future<bool> markPossiblyDispatched({
  required String commandId,
  required String leaseToken,
  required String authenticatedActorId,
  required DateTime now,
});
```

7. **Family-scoped query:** extend `listClaimableCommands` with optional `familyId` at the store-port boundary (without breaking old callers), but dispatcher **must** pass nonempty active `familyId`. Apply in SQLite, application fake and mobile in-memory implementations. Discovery for pause/resume is already family-scoped.
8. A `ValidatedActorContext` is not a durable identity credential. It is invalidated on auth sign-out/switch and rechecked before RPC. It cannot be derived solely from a queued record's `actorUserId`.

## 5. Mandatory token-fenced pre-dispatch CAS

The additional SQLite store method must atomically update **only** dispatch provenance. Example query (adapt names/SQLite DateTime encoding to actual Drift code; validate SQL in tests):

```sql
UPDATE pending_reward_commands
SET dispatch_state = 'possibly_dispatched'
WHERE command_id = :commandId
  AND lease_token = :leaseToken
  AND lease_expires_at > :now
  AND actor_user_id = :authenticatedActorId
  AND recovery_state = 'active'
  AND operation IN ('spin_wheel', 'redeem_reward')
  AND dispatch_state IN ('never_dispatched', 'possibly_dispatched');
```

**Expected:** exactly one updated row; otherwise return `false`, **never send RPC**. The state must be committed in SQLite before making a **remote mutating RPC**. The method must not clear lease token/expiry or alter identity/recovery/retry fields. Matching `leaseToken` protects against replacement owner; expiration check disallows an already-expired owner from opening a *new* RPC. For an in-flight RPC that finishes after expiry, existing token-fenced completion/release remains safe when token is still current; if a newer token has replaced it, old mutation affects 0 rows. Do not change frozen generic save behavior to make the marker work. Mirror logic in both in-memory stores.

## 6. Exact execution algorithm — foreground and recovery

**Step 0 — Gate:** refuse if there is no valid, current authenticated actor context, active authorized family/child, or the requested operation is out of scope. A network timeout on preflight yields `unverified` with **zero mutation RPC**, not guessed authorization. App demo mode uses an explicit fake session adapter **only** in development/test (no production fallback).

**Step 1 — Select identity:**
- Fresh foreground intent: if an unresolved command already exists for the same operation target, **reuse only the exact eligible original command**; otherwise surface blocked/recovery-required. If genuinely new, generate ONE UUID and INSERT a `never_dispatched` command with complete original actor, family, child, operation, target, role; never silently overwrite existing ID.
- Recovery: load exact existing command. Reject `unknown_legacy`, `confirmed_committed`, quarantined, `terminal_error`, missing actor, mismatched actor, wrong family/child, unsupported operation, wrong target or not-yet-due command. Reuse original ID and arguments unchanged.
- `requestedCommandId` from a UI retry is a lookup key, not permission to create a new ID if the matching row is missing or ineligible. Explicit brand-new user intent is a distinct path.

**Step 2 — Atomically acquire claim:** `acquireClaim` with authenticated actor, 30s lease and injected clock. Claim failure => skip/yield `alreadyInFlight` or `scheduled`; never send RPC. Do not bypass durable `next_attempt_at` for manual retry without an explicit authorized override design (not in this slice).

**Step 3 — Revalidate auth/authorization:** check actual current session user and session generation, target family/child and server authorization; if unavailable or mismatched, do **not** send RPC. Leave journal untouched except permitted fenced transition/release; do not label ambiguous auth as revocation. Do not log token or child's personal data.

**Step 4 — Durable pre-send marker:** invoke `markPossiblyDispatched(commandId, leaseToken, authenticatedActorId, now)`. If false, abandon attempt with zero mutation RPC. If successful, journal is durable `possibly_dispatched` even if app crashes before sending.

**Step 5 — Final session gate:** immediately before RPC, compare live session actor and auth-generation to the validated context; revalidate after asynchronous gap. If changed, no RPC; retain journal, let lease expire/authorized recovery handle it. Do not use stored actor as session proof. Existing `currentUserIdProvider` alone is not the auth port.

**Step 6 — RPC:** call frozen `spin_reward_wheel`/`redeem_store_reward` through existing repository with **exact same commandId and target arguments**. Adopt a network timeout shorter than claim lease where feasible, while acknowledging in-flight calls may outlive leases. Server-side receipt semantics ensure economic at-most-once when authorization still permits replay.

**Step 7 — Outcome under the current lease:**
- Definitive server-committed result: call `completeCommand(commandId, leaseToken)`; no extra generic `confirmed_committed` save is required. If completion fails (new owner), do not delete/replace journal; server idempotency will reconcile.
- **Definitive, server-authoritative `LW201`, `LW202`, `LW203`, `LW205` or `LW206` rejection** of this same Spin/Redeem command under the unchanged validated actor: use token-fenced `completeCommand(commandId, leaseToken)` to clear the rejected intent, and return/display the correctly typed error. This preserves the existing behavior so a later, **distinct** user intent can generate a new UUID. If the definitive response is not verified, **do not delete**. `42501`, `LW204`, `P0002`, unknown code, timeout or missing receipt are NOT on this delete whitelist; quarantine ambiguous outcomes instead.
- Socket timeout/5xx/disconnection: calculate backoff; `releaseClaim` increments retry count atomically and persists schedule; no new UUID. If release returns false, old worker must not try again.
- Actor/session mismatch before RPC: no RPC. For a different current actor, pause only via pre-existing `pauseMismatchedActorCommand` after lease is relinquished/expired. The owner must not fabricate a new actor or change identity. Do not delete.
- 42501 / insufficient authorization / archived child: stop automatic retries, use token-fenced `transitionRecoveryState(...quarantinedUnknownOutcome)` or safe non-dispatch pause depending on verified cause, retain original command. If the original RPC committed earlier but the child is now archived, 42501 cannot rule it out.
- Confirmed revoked paired-child grant (`status='revoked'` **and** `revoked_at IS NOT NULL` from an authorized own-grant SELECT): quarantine and signal containment to later 4C UI. Empty/forbidden/failed SELECT => **NOT confirmed revoked**.

**Session changed while network RPC already in flight:** cancel if possible; do not claim the RPC could be undone. Prefer retaining the unresolved journal if the auth epoch changed before processing the response; later original-actor same-ID replay performs reconciliation. Never issue another RPC under the new actor.

## 7. Retry/scheduling policy — fixed defaults for implementation

| Parameter | Contract |
|---|---|
| In-flight command claim | 30 seconds (`leaseDuration`), adjustable via injected settings for tests |
| RPC timeout | 15 seconds when supported by HTTP/RPC adapter; timeout is unknown-outcome, not failure proof |
| Base retry delay | 2 seconds |
| Backoff cap | 60 seconds |
| Backoff formula | For failure number `n = persistedRetryCount + 1`: `cap = min(60s, 2s * 2^(n-1))`, then full jitter sampled uniformly `[0, cap]` |
| Scheduler flood guard | At most one drain for a family+actor at a time, max 10 commands scanned and max 2 mutation RPCs in flight. Avoid tight immediate retry loops even if jitter is near zero; next sweep is event-driven or at least 1s later |
| Authorization uncertainty | Do **not** retry mutating RPC until valid session/authorization can be established; preserve journal |
| Process death | Persist retry and lease; await lease expiry on next launch, never force-clear a live claim |
| Network availability | No remote mutation RPC while offline; no speculative receipt inference |

Only SQLite owns `retry_count` increments. Read latest count *after claim* if calculating next delay; the caller supplies a deadline, never a new retry count. `next_attempt_at` can never be overridden by generic foreground saves. Retain exact time-zone-neutral UTC instant semantics.

## 8. Error taxonomy — based on reviewed backend, not invented codes

| Condition | Trusted signal | Action |
|---|---|---|
| Confirmed successful spin/redeem or same-ID idempotent replay | Typed RPC success under original actor | Token-fenced `completeCommand`; refresh read models |
| Transient network, timeout, 5xx | Typed transport/network error | Token-fenced `releaseClaim` and durable jitter backoff |
| `LW201` insufficient RP | Verified typed PostgreSQL rejection, same actor and command | Token-fenced `completeCommand`, return terminal error; new intent later uses a separate UUID |
| `LW202` daily wheel cap | Verified typed PostgreSQL rejection | Token-fenced `completeCommand`, return terminal error |
| `LW203` eligible wheel pool below 3 | Verified typed PostgreSQL rejection | Token-fenced `completeCommand`, return terminal error |
| `LW205` reward no longer available | Verified typed PostgreSQL rejection | Token-fenced `completeCommand`, return terminal error |
| `LW206` wheel disabled | Verified typed PostgreSQL rejection | Token-fenced `completeCommand`, return terminal error |
| `LW204`, `P0002`, `22000`, unknown `LW*` | Not part of the verified Spin/Redeem terminal-deletion whitelist | Quarantine unknown outcome, preserve original journal and request independent review; no auto retry |
| `42501` | Permission/authorization, ambiguous | Stop automatic retry; quarantine unknown outcome or pause on positively confirmed actor mismatch; preserve journal |
| Archive | Trusted RPC message `Child profile is archived` + 42501, or positive authorized verification | Quarantine pending unresolved journal; do not assert transaction absent |
| Paired child grant revoked | Own-grant authorized SELECT returns `revoked` and non-null `revoked_at` | Quarantine and containment signal; no automatic replay |
| Missing grant / RLS-empty / query timeout | Unverified | Treat as unknown, not revoked; do not delete or mutate remotely |
| Session is missing, changed or unverified | Auth port typed failure | No RPC; preserve command; actor pause/resume only through existing CAS |
| `unknown_legacy` or quarantined | Persisted dispatch/recovery state | Zero RPC; manual reconciliation deferred to 4C |

**Caution:** Use operation-aware classification; `LW201`–`LW206` is not a universal list for every RPC. `LW203` is **not** an inventory/out-of-stock code. There is no established `LW301` backend code in reviewed migrations. Do not parse `toString()` when structured PostgREST exception fields are accessible.

## 9. Family, child and session boundaries

- `drainOnce` requires **current active family** in addition to validated actor. Query only that family in the store, *before* taking the 10-row limit. Family switch while an operation is pending cancels future mutation dispatch, and final pre-RPC gate rechecks current family; records for another family remain durable and dormant.
- Adult: verify active family membership and target child active via authorized read. Paired child: verify own active grant for matching family+child and child active. Shared Child Mode uses the parent's authenticated actor; Parent PIN / device session containment is addressed further in 4C; this dispatcher must not infer authorization from child-mode UI state.
- Actor A -> actor B: halt all A execution, clear in-memory work; B may pause A's rows only for a family B is allowed to access; otherwise simply leave A's records untouched. Actor A returning can safely resume A's paused rows, then claim again.
- No `clearAllTables()` on logout. Do not erase original actor, command ID, evidence paths or unresolved operations.
- Auth session-generation should be invalidated on `signedOut`, actual user change, account deletion and local auth failure; token refresh for the same user can update credentials without changing actor identity. Observe `onAuthStateChange` **with `onError`**, handling offline refresh errors fail closed.
- Supabase Dart adapter must use methods compatible with locked `supabase_flutter: ^2.18.3`; do not assume future SDK APIs without checking. `currentSession` by itself is a locally stored value; if verification needs network, `getUser(accessToken)` (or version-supported equivalent) provides server-confirmed identity. Offline verification unavailable => no remote mutation; preserve journal.

## 10. Implementation work packages — **agent executes code, no new design phase**

| Order | Work package | Concrete output | Gate before next |
|---|---|---|---|
| WP0 | Baseline + documentation alignment | Update existing `docs/19-...` implementation spec to reference this locked contract; do not rewrite accepted ADR | No contradictions with frozen v6 |
| WP1 | Store contract | Add token-fenced `markPossiblyDispatched`; optional family-scoped claim list; implement SQLite + two in-memory parity paths | SQLite CAS tests green |
| WP2 | Auth + target authorization port | Application interfaces, Supabase mobile adapter and fake ports; session epoch/change subscription; family+child preflight | Missing/stale actor gates tested |
| WP3 | Coordinator | One Spin/Redeem command execution state machine, error classifier, retry schedule with injected Clock/Jitter | Mock-server same-ID tests green |
| WP4 | Foreground integration | Refactor Spin/Redeem use cases and minimal mobile providers/screens to call shared coordinator; preserve public UI | Widget/use-case tests green |
| WP5 | App-active dispatcher | `drainOnce`, bounded scheduler, lifecycle triggers; feature switch OFF until all gates pass | Restart/actor-switch concurrency tests green |
| WP6 | Final verification and PR | CI, docs, branch changes, PR #24, report precise SHAs and test matrix | Independent review; **do not merge** |

Files likely touched: `packages/learnward_application/lib/src/ports/*`, `.../use_cases/spin_reward_wheel.dart`, `.../use_cases/redeem_store_reward.dart`, new `.../services/recovery_*` files, `packages/learnward_data/lib/src/database/app_database.dart`, `apps/mobile/lib/app/bootstrap/app_providers.dart`, `apps/mobile/lib/features/rewards/presentation/child_wheel_screen.dart`, `.../child_store_screen.dart`, `.../app/bootstrap/in_memory_repositories.dart`, `packages/learnward_test_support/...`, relevant tests, and `docs/19-*`. Do not arbitrarily expand scope.

## 11. Acceptance test matrix (mandatory, deterministic)

All tests use injected clock/jitter, a fake auth-session lifecycle and a mocked server that keeps authoritative receipt state. SQLite tests use real file-backed databases with two independent connections where concurrency matters.

| ID | Scenario | Required assertion |
|---|---|---|
| A01 | Fresh Spin and Redeem | Insert never-dispatched, claim, durable mark, then exactly one RPC and one server side effect |
| A02 | Claim -> marker rejects wrong token | `false`, no RPC, row unchanged |
| A03 | Claim -> marker rejects expired/replaced token | `false`, no RPC, preserve new owner's lease |
| A04 | Crash immediately after pre-dispatch SQLite commit | Reopen: `possibly_dispatched`, same ID, no fabricated new ID |
| A05 | Response lost after authoritative server commit | Original actor retries same ID; one debit/spin; second RPC returns receipt |
| A06 | Two SQLite connections claim concurrently | Exactly one claimant; no parallel foreground/background mutation |
| A07 | Slow A / expired lease / B takeover | A cannot release, complete, mark or delete B's row |
| A08 | Same actor switches active family mid-flow | No RPC for inactive family; command retained dormant |
| A09 | A logs out before final RPC | No RPC; journal retained; later A resumes |
| A10 | A logs out while RPC in-flight | Never switch credentials and replay as B; retain unresolved outcome if session generation changed |
| A11 | Actor B sign-in on shared device | A's eligible commands paused without RPC only if B authorized family; other-family data untouched |
| A12 | Original actor A returns | Resume via CAS, claim separately, replay exact ID |
| A13 | Paired child grant `revoked` + revoked_at set | Positive revocation -> quarantine; no further RPC |
| A14 | 42501 without positive revocation evidence | Ambiguous/quarantined, not labelled `DEVICE_REVOKED`, no busy retry |
| A15 | Child archived after command may have committed | 42501 remains unknown outcome; no false terminal delete or changed ID |
| A16 | Backoff after 1, 2, 3 failures and restart | persisted schedule and increment; no retry before due |
| A17 | Daily cap/insufficient RP/disabled wheel/pool | Correct `LW201`/`LW202`/`LW203`/`LW206` operation-specific terminal classification |
| A18 | Reward unavailable | `LW205` terminal only on definitive backend response |
| A19 | Legacy v4/v5 unknown actor and unknown_legacy | Zero claim/RPC; preservation |
| A20 | Existing foreground wheel/store flows | Same observable result and UI compatibility; no direct RPC bypass |
| A21 | Auth stream emits error on offline refresh | Handled without crash; no mutation RPC |
| A22 | 10-row queue limit with wrong-family rows first | Active-family commands are not starved by other-family rows |
| A23 | Crash/kill with live claim | Reopen does not force-clear claim; reclaims only after lease expiry |
| A24 | Definite success response with stale token | Old completion affects 0 rows; no overwrite/deletion |

Negative tests: no network mutation before durable marker, no claim for `unknown_legacy`/quarantined/confirmed, no raw service-role key, no global queue wipe, no new Supabase migration, no direct `savePendingCommand()` after claim for marker.

**CI gates:** Dart format, Flutter analyze 0 issues, application/data/test-support/mobile suites, Drift codegen check (no unintended schema changes), all SQLite CAS + server-mock tests, pgTAP 659 and integration/concurrency scripts, iOS simulator compile, Android debug build. CI success alone is necessary **not sufficient**; audit exact implementation of A01–A24.

## 12. Observability, rollout and stopping rules

- Log sanitized `(commandId hash/short prefix, operation, actor-class, family hash, dispatch/recovery state, retryCount, error category, lease result)`; never full names, school data, emails, photo paths, access/refresh tokens, or raw sensitive Supabase errors.
- Feature flag `RECOVERY_DISPATCHER_ENABLED` defaults **false in all builds** until reviewed end-to-end; foreground path must become safe regardless. Turning on the flag for staging is a separate explicit action following review.
- Stop and report instead of inventing backend SQL, altering frozen RPC signatures, relaxing RLS, silently deleting uncertain commands, or bypassing claim ownership to make tests pass.
- If a real immutable v6 contract is insufficient, present a minimal deviation and proof; do not change it unilaterally.

## 13. Definition of Done / acceptance

**Ready for merge review only if:** A01–A24 pass; all prior tests and CI green on exact PR head; app-auth/family lifecycle integrated; all RPC calls are behind shared coordinator; no background work enabled without gates; app UI visually unchanged; no backend migrations changed; immutable original command and actor intact; agent submits PR #24 and waits for independent sign-off.

**Not DONE by this slice:** pilot release, fulfillment/cancellation recovery, evidence byte reconciliation, shared-device Parent PIN lifecycle, manual recovery UI, production signing or privacy review.

## 14. Source references and verification notes

- GitHub baseline: https://github.com/thedusk4203/LearnWard/tree/7584147a3ca906c87dccb6daf52f5b7415ba8a54
- Pre-existing contract: `docs/18-phase-6-actor-aware-offline-recovery-readiness-review.md`; `docs/19-phase-6-slice-4a-1-recovery-dispatcher-specification.md`; freeze `docs/freezes/phase-6-slice-4a-0-drift-v6-foundation-freeze.md`.
- DB: `packages/learnward_data/lib/src/database/app_database.dart`.
- Use cases: `packages/learnward_application/lib/src/use_cases/spin_reward_wheel.dart`, `redeem_store_reward.dart`.
- Auth provider: `apps/mobile/lib/app/bootstrap/app_providers.dart`.
- Backend: `supabase/migrations/20261105120000_phase6_2_child_archive_concurrency.sql`, `20261105000000_phase6_1_child_lifecycle_rls.sql` and frozen reward/wheel migrations.
- Supabase Dart SDK: https://supabase.com/docs/reference/dart/auth-onauthstatechange ; https://supabase.com/docs/reference/dart/auth-refreshsession ; https://supabase.com/docs/guides/auth/sessions . APIs must be validated against project's locked version before coding.
