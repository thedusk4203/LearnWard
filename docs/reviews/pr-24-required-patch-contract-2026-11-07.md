# LearnWard — PR #24 Independent Implementation Audit and Required Patch Contract

**Date:** 2026-11-07 (Asia/Bangkok)  
**Repository:** https://github.com/thedusk4203/LearnWard  
**PR:** https://github.com/thedusk4203/LearnWard/pull/24  
**Audited HEAD:** `55e306c49fea086c9fd6bad447b37de19a1459a5`  
**Base SHA:** `7584147a3ca906c87dccb6daf52f5b7415ba8a54`  
**CI:** https://github.com/thedusk4203/LearnWard/actions/runs/42378782937 — success, 4/4 jobs  
**Verdict:** REQUEST CHANGES; do not merge or enable automatic dispatcher.

## Audit boundary

Reviewed the real PR source: `RecoveryCoordinator`, `OutboxRecoveryDispatcher`, `RecoveryErrorClassifier`, Supabase auth and authorization adapters, public Spin/Redeem use cases, mobile providers/foreground callers, Drift token-fenced pre-dispatch CAS, tests A01–A24, the merged Supabase schema, and the locked Slice 4A-1 contract. CI passing confirms build/test execution, **not** production authorization or completeness of acceptance scenarios. Frozen server migrations were not changed in this PR.

## Verified blockers

### H01 — Production authorization adapter queries nonexistent relations (HIGH)

**Source:** `apps/mobile/lib/app/bootstrap/supabase_recovery_authorization_adapter.dart` lines 42–81. Uses `.from('family_members')` with `.eq('user_id', ...)` and `.from('paired_child_grants')` with `.eq('user_id', ...)`; actual frozen tables are `public.family_memberships(auth_user_id, family_id, role, status)` and `public.child_device_grants(auth_user_id, family_id, child_id, status, revoked_at)`. These names are established by `supabase/migrations/20261031131100_phase1_family_child_identity.sql`. Its final `return authorized` is also fail-open absent positive membership/grant evidence.

**Runtime impact:** With the frozen schema, the authorization query throws and the adapter returns `unverified`, blocking real foreground Spin/Redeem. A future refactor could also accidentally accept unauthorized callers through the unconditional fallback.

**Prescribed fix:** Query only the actual frozen relations and column names. Require positive active adult membership **or** positive active paired-child grant for the exact family and child, plus active-child visibility/verification; never return `authorized` on null/empty/error. An RLS-filtered missing row is `unverified`, not positive proof of revocation or archival. For own revoked grant, `status='revoked' AND revoked_at IS NOT NULL` is positive revocation evidence. Use exact actor ID from current validated session. No new Supabase migration.

**Mandatory tests:** Real local-Supabase integration or request-level adapter tests covering actual table/column names, adult owner/parent, valid paired child, revoked grant, cross-family/child, archived/hidden child, missing row and network/permission failure. Verify production adapters, not only fake ports.

### H02 — Public use-case fallbacks bypass trusted authentication and target authorization (HIGH)

**Source:** `packages/learnward_application/lib/src/use_cases/spin_reward_wheel.dart` lines 76–96, 136–180, and `redeem_store_reward.dart` analogous sections. If the coordinator and ports are omitted, `_DirectActorSessionPort` turns a caller-provided string into a “validated” session and `_PermissiveAuthorizationPort` always returns `authorized`.

**Impact:** A legitimate un-updated caller can bypass the client-side provenance boundary and persist a command bound to the wrong actor relative to the actual Supabase RPC caller. Server-side RLS remains authoritative but does not repair an incorrectly attributed local journal.

**Prescribed fix:** Fail closed if a trusted coordinator (or both non-permissive auth and authorization ports) is absent. Remove production-reachable `_DirectActorSessionPort` / `_PermissiveAuthorizationPort`. Tests needing synthetic users must inject explicit fakes. Preserve current Flutter call signatures where possible, but make test-only injection explicit. Assert zero mutation RPC when only an arbitrary actor ID is supplied.

### H03 — Production retries use deterministic zero jitter and stale start time (HIGH)

**Source:** `RecoveryCoordinator` constructor line 153 defaults to `DeterministicJitterSource()` whose default fraction is `0.0` (`jitter_source.dart` lines 18–24); `recoveryCoordinatorProvider` does not override it; coordinator lines 463–483 calculate `nextAttemptAt` from `now` captured at method entry before network/authorization/RPC latency.

**Impact:** Repeated transient failures may become immediately eligible for another attempt; a slow failed request can even persist an already-past retry deadline. This defeats the specified backoff and can flood the server after repeated triggers.

**Prescribed fix:** Default production construction to `RandomJitterSource`; deterministic jitter must only be explicitly injected into tests. Compute retry deadline from a fresh `_clock.now().toUtc()` **after** failure. Enforce a scheduler flood guard of at least 1 second between automatic drain triggers while respecting the documented full-jitter cap; ensure no tight loop if a sample equals zero. Preserve SQLite-owned retry counter increment. Test production default choice and simulated long-duration RPC.

### H04 — Existing-command payload not validated against requested operation/target; missing retry ID can be recreated (HIGH)

**Source:** `RecoveryCoordinator.execute()` lines 217–309 and 364–411. When `requestedCommandId` resolves to a row, the coordinator does not compare stored `operation`, `familyId`, `childId`, `rewardId` to the method arguments. It then invokes the RPC with the method arguments rather than the immutable stored command payload. If a `requestedCommandId` is absent during a foreground call, it creates a new row using that ID.

**Impact:** A previously queued ID may be used for a different economic intent if no receipt was committed yet. A stale UI retry can inadvertently create a command under its old UUID instead of reporting that the journal row is missing.

**Prescribed fix:** On existing command, validate exact operation/family/child/reward target and original actor; any mismatch returns fail-closed before claim and before RPC. Execute using the validated **stored** immutable payload. `requestedCommandId` is a strict lookup key; if missing, fail closed for foreground and recovery. Only a distinct *fresh* foreground request with no supplied command ID may create a new UUID. Check `canAutoReplay` and do not report a confirmed commit solely from an unverified local `confirmed_committed` record.

**Mandatory tests:** Same UUID with altered operation, child, family, reward; retry ID missing; explicit fresh intent with generated ID; same-ID response-loss replay preserves the exact targets and actor.

### H05 — Device revocation can be inferred from error strings; positive grant evidence missing (HIGH)

**Source:** `recovery_error_classifier.dart` lines 97–105: `DEVICE_REVOKED` and textual `grant` + `revoked` lead to `deviceRevoked` without querying the original actor's own grant. `SupabaseRecoveryAuthorizationAdapter` does not currently provide a strongly differentiated positive-revocation result.

**Impact:** Ambiguous permissions or string contents can falsely label the device revoked. This violates ADR 0008 and the locked `docs/20-...` contract.

**Prescribed fix:** Treat 42501 and strings as ambiguous authorization failures; **never** grant `DEVICE_REVOKED` from a message alone. Provide a positive typed result (e.g., `TargetAuthorizationStatus.confirmedRevoked` or separate grant verification port) only when the *current authenticated paired-child session* can read its own `child_device_grants` row with `status='revoked' AND revoked_at IS NOT NULL`. On unavailable/hidden/empty result, preserve `unverified`. Add separate typed error disposition tests.

## Additional implementation completion gaps

### M01 — Preflight definitive denial does not persist quarantine

**Source:** `RecoveryCoordinator.execute()` lines 197–215 returns `CommandQuarantinedResult` immediately on `definitelyDenied`; an existing eligible command is left unchanged in SQLite. Repeated drains may repeatedly scan it and starve valid commands. Fix with a non-RPC, token-fenced or narrowly scoped CAS transition that safely quarantines an existing command after **positively verified** denial. No general generic-save override. Tests must assert persisted `recovery_state`, not only the returned result.

### M02 — Final live auth and active-family gate not implemented

**Source:** Coordinator lines 334–361 only compare `currentSessionGeneration` to the earlier context. It does not call `validateForMutation()` or check active family again immediately before remote RPC. `OutboxRecoveryDispatcher.drainOnce` accepts caller-provided `validatedContext` and `activeFamilyId` and can pause/resume journal state using stale context.

**Prescribed fix:** Re-read the current authenticated session and active family/child execution scope after claim and immediately before RPC; compare actor ID, session epoch and selected/authorized family. Treat any loss/change as zero RPC with durable journal preserved. Dispatcher must obtain/revalidate trusted current context itself rather than relying on an arbitrary caller-provided snapshot. Do not equate the `currentUserIdProvider` string with session proof. Tests need true interleaving at the pre-RPC gate, not merely a false context before execution starts.

### M03 — Dispatcher flag and app-active triggers not connected

**Source:** `AppConfig.recoveryDispatcherEnabled` exists but `outboxRecoveryDispatcherProvider` only constructs a dispatcher. No app-active scheduler/lifecycle wiring consumes the flag in changed code. The flag remaining OFF is correct at review time, but setting it ON currently does not constitute a functioning app-active recovery loop. Implement explicitly feature-gated lifecycle/network/auth-change triggers and bounded drain scheduling, or report this component as unimplemented and defer activation rather than claiming WP5 complete. No UI redesign.

### M04 — Acceptance tests simulate narrower scenarios than titles

- A08 passes a different `activeFamilyId` to an idle dispatcher; it does **not** switch the family while a command is already claimed.
- A10 changes session generation before RPC and asserts no RPC; it does **not** log out during an in-flight network call.
- A13 injects `FakeRecoveryAuthorizationPort(defaultStatus: definitelyDenied)`; it does **not** verify `child_device_grants` or persist quarantine.
- A21 invalidates a fake session explicitly; it does **not** establish the production `SupabaseAuthSessionAdapter.onError` is fail-closed.
- A24 tests the store CAS return value in isolation; it does **not** verify that the coordinator surfaces a stale completion without incorrectly treating journal deletion as successful.

**Prescribed fix:** Keep all 24 tests and add/strengthen true production adapter, in-flight logout, family-switch, revoked grant, and coordinator stale-token tests. Track each acceptance ID with observed assertions, not merely test titles. Handle `completeCommand`/`releaseClaim` returning false as lost-ownership outcomes in the coordinator rather than claiming durable completion/scheduling.

## Patch execution order (agent IMPLEMENTATION ONLY)

1. **W1:** Fix production Supabase authorization tables/columns, fail-closed semantics and own-grant positive revocation; production integration tests.
2. **W2:** Eliminate direct actor/permissive fallback use-case paths; explicit trusted dependency injection and fail-closed tests.
3. **W3:** Enforce immutable command target and strict requested-ID lookup; regression tests.
4. **W4:** Correct jitter source, deadline timebase, scheduling and stale-token return handling; deterministic race tests.
5. **W5:** Revalidate current auth, actor, active family before RPC; persist positive-denial quarantine, remove textual revocation inference; auth race and revoked-device tests.
6. **W6:** Complete feature-gated app-active triggers or explicitly retain disabled status with tracked unfinished work; strengthen A08/A10/A13/A21/A24; full CI.

## Merge gate

- All production authorization queries use existing schema and verified RLS.
- No permissive authentication or authorization fallback in production-reachable public use cases.
- No mutation RPC from a mismatched command payload or after session/family switch.
- No new row created for a missing explicit retry ID.
- No `DEVICE_REVOKED` without positive own-grant evidence.
- Real random jitter in production; persistent retry deadline anchored after failure; no retry flood.
- Positive denial persists safe quarantine; stale token does not report successful journal completion.
- A01–A24 still pass, enhanced adapter/negative tests pass, no frozen Supabase migrations changed, full 4/4 GitHub CI green on the new PR HEAD.
- Keep `RECOVERY_DISPATCHER_ENABLED=false` and do not merge, deploy, or enable it until independent approval.

**Architectural ownership:** ChatGPT provides this locked correction plan. Coding agent implements, runs tests, and reports precise results. Do not open another planning-only PR or redesign frozen Phase 6 contracts.