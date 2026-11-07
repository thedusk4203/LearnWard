# LearnWard — Coding Agent Build-Only Handoff

**Role split:** The planning/specification work is complete. You are the implementation and testing agent; do **not** create another strategy document, reorder the roadmap, or reopen frozen contracts. Report only concrete conflicts backed by source/test evidence. **Do not merge or deploy.**

**Repository:** https://github.com/thedusk4203/LearnWard  
**Baseline main SHA:** `7584147a3ca906c87dccb6daf52f5b7415ba8a54`  
**Planning delivery:** These three Markdown files are attached externally. Copy them unchanged to `docs/` as the first implementation-branch commit; implementation PR targets `main`.  
**Approved freeze:** PR #23 merge `88908ac309cda0eddcd549121ea0638c6979a384`, 4A-0.  
**Implement next:** Slice 4A-1 Spin/Redeem Actor-Aware Recovery in a focused PR (nominally #24).

## Read these three files, in order

1. `docs/20-phase-6-slice-4a-1-final-implementation-contract.md` — **AUTHORITATIVE implementation algorithm, ports, SQL, error policy, gates, tests A01–A24**.
2. `docs/21-phase-6-master-delivery-and-pilot-gates.md` — dependency order, cross-cutting invariants, deferred work, pilot blockers.
3. `docs/19-phase-6-slice-4a-1-recovery-dispatcher-specification.md` — historical planning. Where it conflicts with #1, **#1 wins**. Update #3 within your implementation PR to remove contradictory instructions; do not propose a separate design PR.

## Execute (no re-planning)

1. Verify GitHub `main` HEAD. Create the implementation branch from current `main`; copy the three supplied planning Markdown files into `docs/` unchanged before coding; keep the code scope to 4A-1, with PR base `main`. Do not spend time planning anew.
2. Implement WP1: token-fenced `markPossiblyDispatched()` in SQLite + in-memory parity and family-scoped claimable query. Show it cannot be replaced by generic `savePendingCommand()` under lease.
3. Implement WP2: typed AuthSessionPort and RecoveryAuthorizationPort, Supabase mobile adapters, safe auth-event handling and test fakes. Bind original actor and active family/child before network RPC.
4. Implement WP3: one coordinator for Spin and Redeem foreground + recovery, exact UUID reuse, typed errors, restart-safe backoff.
5. Implement WP4: wire existing wheel and store entry points and providers through shared pipeline with no visual UI redesign.
6. Implement WP5: bounded app-active dispatcher, triggers and feature flag **OFF until all gates pass**. No native background service, no assessment/fulfill/cancel auto replay.
7. Run A01–A24 acceptance tests with file-backed SQLite, two connections and mock server receipts; then the complete repository CI.
8. Commit and open a focused implementation PR; report exact HEAD, changed files, A01–A24 matrix, CI URL/result and deviations. **Stop; do not merge.**

## Hard prohibitions

- No new Supabase migration, server RPC/RLS/economic changes, database schema bump, release deployment, production credentials or service-role keys.
- No RPC before durable token-fenced `possibly_dispatched` state; no dispatch under another actor or inactive family.
- No unknown_legacy/quarantined auto replay, guessed device revocation, deletion after 42501, or new UUID on pending operation.
- No direct UI-to-RPC bypass once dispatcher is enabled; no unsafe generic save or delete of active leased journal.
- No scope creep into 4A-2/4B/4C; separate PRs already planned.

## Completion report format

```
PR URL:
Base SHA / HEAD SHA:
Work packages WP1-WP6 status:
CAS SQL used for pre-dispatch:
Auth and family verification adapters:
Foreground call-site changes:
A01-A24 acceptance table (test file + PASS/FAIL):
CI run ID and all job conclusions:
Frozen contract diff = none? (prove):
Feature flag = OFF? (prove):
Remaining blockers with exact reproduction:
Merge/deploy = NOT PERFORMED.
```

**Only report a design blocker when the approved contract is objectively impossible under real source or frozen server API. Otherwise implement and test.**
