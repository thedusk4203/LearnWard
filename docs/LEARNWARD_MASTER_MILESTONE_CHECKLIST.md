# LEARNWARD — MASTER MILESTONE CHECKLIST

> **Snapshot:** 2026-11-05 (Asia/Bangkok)  
> **Repository:** https://github.com/thedusk4203/LearnWard  
> **Baseline inspected:** `main` @ `007abb72f9d0299873a432df5b8d2d5277a6093b` (PR #15 merge commit)  
> **Current gate:** Phase 6 detailed design ACCEPTED; Phase 6 implementation **PARTIAL / IN PROGRESS**  
> **Last verified implementation change on main:** PR #15 — child lifecycle + RLS hardening, merged  
> **Active development observed:** `feat/phase-6-2-child-archive-concurrency`, 3 commits ahead of the inspected main; **NOT MERGED / CI UNVERIFIED**  
> **Critical path:** complete & audit Phase 6 implementation slices → freeze 6.1/6.2/6.3 → signed Android/iOS builds → four-week family pilot  
> **Overall percentage:** NOT ASSIGNED; no approved effort-weighting model exists. Do not confuse completed foundational phases with product-release completion.

---

## Legend & evidence policy

- `[x]` — delivered **only for the exact item named** and supported by a repository artifact.
- `[ ]` — not yet evidenced as delivered; not necessarily zero engineering work.
- `FROZEN` — accepted final contract + implementation freeze evidence.
- `ACCEPTED DESIGN` — approved design; does not prove working code.
- `MERGED / AUDIT PENDING` — change appears on main but no exact-head final acceptance receipt verified here.
- `PARTIAL` — one or more sub-slices exist, parent milestone still open.
- `IN FLIGHT` — branch work exists but has not been counted as merged.
- `BLOCKED` — a mandatory dependency or release gate remains unsatisfied.
- `EXTERNAL BLOCKED` — billing/runner/infrastructure issue; never equate it to failing tests or passing CI.
- `UNVERIFIED` — evidence is not available in this snapshot; **do not infer PASS or FAIL**.
- A phase closes only with exact commit, independent audit result, CI on applicable head, required security/device checks and freeze receipt.
- Maintain `DESIGNED`, `MERGED`, `AUDITED`, `FROZEN`, and `PILOT VALIDATED` as separate states.

---

## 0. Executive status dashboard

| Area | Current state | Evidence / next gate |
|---|---|---|
| Phase 0 — Engineering Foundation | FROZEN | Pub workspace + Flutter + Supabase base |
| Phase 1 — Family & Child Identity | FROZEN | ADR 0002 + freeze |
| Phase 2 — Secure Assessment Capture | FROZEN | ADR 0003 + freeze |
| Phase 3 — Growth Engine & XP/RP Ledgers | FROZEN | ADR 0004 + freeze |
| Phase 4.1 — Reward Catalog + Store | FROZEN | Phase 4 freeze |
| Phase 4.2 — Celebration Wheel | FROZEN | Phase 4 freeze |
| Phase 5.1 — Mastery & Confidence | FROZEN | ADR 0006 + freeze |
| Phase 5.2 — Skill Graph & Recommendations | FROZEN | ADR 0007 + freeze |
| Phase 6 dependency/readiness | COMPLETE for design gate | PR #12; approved by subsequent design acceptance |
| Phase 6 detailed design | ACCEPTED | PR #13, ADR 0008 |
| Phase 6 implementation | **PARTIAL** | PR #15 on main; additional work on branch |
| 6.1 — Offline/outbox/actor recovery | PARTIAL foundational security slice only | RLS/lifecycle foundation merged; full 6.1 gate not closed |
| 6.2 — Notifications/telemetry/retention | NOT ACCEPTED AS COMPLETE | Some child lifecycle groundwork overlaps; final implementation not evidenced |
| 6.3 — Accessibility & distribution | NOT ACCEPTED AS COMPLETE | Signed builds and device proof outstanding |
| Pilot | NOT STARTED | Four consecutive weeks without normal-use engineering intervention required |

**Interpretation:** PR #15 is a merged security/lifecycle **slice**; it is not proof that 6.1 offline resilience, the complete 6.2 privacy subsystem, or any Phase 6 parent gate is frozen. Do not treat `feat/phase-6-2-child-archive-concurrency` as *Phase 6.2 complete* solely because of its branch name.

---

## 1. Delivered & frozen foundations

### Phase 0 — Engineering Foundation
- [x] Dart pub workspace, domain/application/data/design-system/test-support packages.
- [x] Flutter Android/iOS foundation.
- [x] Versioned Supabase/PostgreSQL migrations and test/CI foundation.
- [ ] Populate exact Phase 0 freeze receipt in evidence register (documentation enrichment only).

### Phase 1 — Family and Child Identity — FROZEN
- [x] Adult auth, family tenancy, child profiles and active memberships.
- [x] Shared-child mode, PIN containment and dedicated paired-child device authorization.
- [x] Family RLS and role isolation; ADR 0002 and freeze evidence.

### Phase 2 — Secure Assessment Capture — FROZEN
- [x] Offline-persistent assessment drafts, normalized scoring and private evidence.
- [x] Parent approval/rejection; immutable verified-learning event lifecycle.
- [x] Idempotent commands and tenant/security constraints; ADR 0003 and freeze.

### Phase 3 — Growth Engine + Ledgers — FROZEN
- [x] Deterministic Growth Engine and grade-aware anti-farming.
- [x] Append-only XP/RP ledgers, balance projections and replay safety.
- [x] Regression/parity coverage; ADR 0004 and freeze.

### Phase 4 — Reward Economy & Wheel — FROZEN
- [x] 4.1 parent reward catalog, Store redemption/fulfillment/cancellation/refund flow.
- [x] 4.2 non-losing, server-authoritative Wheel, daily caps, parent controls.
- [x] Durable local reward-command journal, no double-spend; ADR 0005 and freeze.

### Phase 5 — Learning Engine — COMPLETE / FROZEN
- [x] 5.1 learning catalog, weighted evidence, EWMA mastery, confidence and parity.
- [x] 5.2 Skill Graph, freshness, recovery, candidate ranking, authorization.
- [x] Frozen learning/economy separation; ADR 0006/0007 and freeze receipts.

---

## 2. Phase 6 design gates — complete, not implementation acceptance

- [x] Dependency/readiness review documented (PR #12).
- [x] Detailed design and ADR 0008 accepted in PR #13.
- [x] Three delivery groups defined: 6.1 offline/recovery, 6.2 notification/metrics/privacy, 6.3 accessibility/distribution.
- [x] Pilot exit criterion defined: four consecutive weeks of normal family use without engineering intervention.
- [ ] All Phase 6 implementation groups independently verified and frozen.
- [ ] Pilot approvals, device/distribution and operational readiness complete.

Historical note: PR #12's earlier correction receipt had billing-blocked CI. Later design acceptance should be recorded separately; do not overwrite historical failure/blocking details with a retrospective PASS.

---

## 3. Phase 6 implementation slice register — current critical path

| Slice / track | Evidence | What is objectively present | Current verdict |
|---|---|---|---|
| 6.1 security groundwork — Child lifecycle/RLS | PR #15, main `007abb72f9d0299873a432df5b8d2d5277a6093b` | `20261105000000_phase6_1_child_lifecycle_rls.sql`; active-child access boundaries, status transition guard, column privileges, Storage access helper, pgTAP additions | **MERGED / AUDIT + EXACT-HEAD CI UNVERIFIED** |
| Follow-on child archive/concurrency slice | branch `feat/phase-6-2-child-archive-concurrency`, head `19211e417a546ecc8cc042c1c17d002b466ef520` | `20261105120000_phase6_2_child_archive_concurrency.sql`, concurrency script, DB tests, CI workflow edit; 3 commits ahead of snapshot main | **IN FLIGHT — NOT MERGED** |
| Drift v5 + bounded outboxes | No implementation merge evidence in this snapshot | Data migration, command/actor binding, draft queues, recovery | **UNVERIFIED / OPEN** |
| Offline photo integrity + failure UX | No implementation merge evidence in this snapshot | Resumable evidence, camera permissions, safe 409 reconciliation, retry UI | **UNVERIFIED / OPEN** |
| Notification, telemetry & privacy completion | No full completion/freeze receipt in this snapshot | Coordination alerts, metrics, consent/retention/portability | **UNVERIFIED / OPEN** |
| Accessibility, release and devices | No full completion/freeze receipt in this snapshot | Semantics/reduced motion, signing, TestFlight and AAB, diagnostics | **UNVERIFIED / OPEN** |

### PR #15 — merged evidence and remaining checks
- [x] Main contains child lifecycle/RLS migration and a dedicated Phase 6 pgTAP test file.
- [x] Profile lifecycle guard and restricted column UPDATE permissions included.
- [x] New active-child read-boundary checks across relevant domain tables included.
- [x] Evidence Storage authorization helper tightened.
- [ ] Capture full PR #15 exact-head CI run ID, conclusion and job inventory; a status-API response with zero legacy statuses **does not prove checks passed or failed**.
- [ ] Record independent implementation audit and final scope acceptance; do not self-label the complete Phase 6.1 gate FROZEN.

### Follow-on branch — concurrency/archive (not yet on main)
- [x] Compare against main: 3 commits ahead, 0 behind at this snapshot.
- [x] Branch adds migration, PostgreSQL tests, Node concurrency test and workflow changes.
- [ ] Verify PR association, reviewer findings and exact-head CI.
- [ ] Audit archive RPC authorization, idempotency, concurrency race cases, RLS, rollback and data portability implications.
- [ ] Merge only after checks; freeze only the exact accepted scope with receipt.

---

## 4. Phase 6.1 — Offline Resilience, Bounded Outbox & Actor-Aware Recovery — PARENT GATE OPEN

### Local storage and replay
- [ ] Non-destructive Drift v4→v5 migration with fixture upgrade tests.
- [ ] Preserve nullable legacy fields, original command/evidence IDs and ambiguous v4 dispatch provenance.
- [ ] Quarantine legacy actor-unknown records; never replay them under a guessed actor.
- [ ] Actor-bound pending reward commands, bounded assessment submission outbox and stable command IDs.
- [ ] Durable pre-dispatch state, unknown-outcome reconciliation and exactly-once server side effects.
- [ ] Offline read caches for Learning Overview and Next Challenge.

### Security and local lifecycle
- [ ] Mismatched actor login/replay protection and revoked paired device behavior verified.
- [ ] Classify `42501` without mistaking every authorization rejection for revocation.
- [ ] Preserve unsynced work and enforce data-class cleanup across sign-out, family switch and unpair.
- [ ] Keep XP, RP, mastery, wheel result and approval effects strictly server-authoritative.
- [ ] Integrate PR #15 child lifecycle/RLS groundwork without weakening Phase 1–5 contracts.

### Evidence and presentation
- [ ] iOS camera/photo usage strings and real device permission checks.
- [ ] Stable compressed JPEG bytes, SHA-256 integrity and safe Storage 409 comparison.
- [ ] Handle upload/registration response loss without duplicate evidence or unsafe command regeneration.
- [ ] Friendly error, offline and retry UI instead of raw exception leakage.
- [ ] Crash, restart, network partition, identity switch and concurrent device integration tests.
- [ ] Exact-head CI, independent security audit and **6.1 FREEZE RECEIPT**.

**6.1 exit criterion:** every planned 6.1 slice verified, no actor cross-contamination or duplicate economic effect, robust offline recovery, platform permission paths, accepted freeze.

---

## 5. Phase 6.2 — Notifications, Metrics, Child Data Privacy — PARENT GATE OPEN

- [ ] In-app Realtime coordination notifications for parent approval and reward fulfillment.
- [ ] Server-authoritative reconciliation after reconnect; rate limiting and tenant isolation.
- [ ] Canonical VLPE from verified learning events with both Growth and processed Learning.
- [ ] 16-metric register (12 DB derivable; 4 deferred/requiring UX or other input per design).
- [ ] Explicit gross-vs-net RP spend metric policy and lifecycle regression checks.
- [ ] Privacy-minimized, allowlisted telemetry; no identifying data, evidence paths or secrets.
- [ ] Archive/erasure access revocation for all affected domain tables and Storage assets.
- [ ] Review archive concurrency slice without counting a branch as merged.
- [ ] Data export `public.export_family_data_json` verified against schema/RLS expectations.
- [ ] Pre-pilot privacy/legal approval and documented retention/deletion policy.
- [ ] Cross-family, sibling, revoked-grant and archive-after-submit regression tests.
- [ ] Exact-head CI, independent review and **6.2 FREEZE RECEIPT**.

**6.2 exit criterion:** reliable coordination, privacy-safe metrics, enforceable deletion/portability lifecycle, tested security boundaries and approved pilot data policy.

---

## 6. Phase 6.3 — Accessibility, Safety & Distribution — PARENT GATE OPEN

- [ ] Screen-reader Semantics, feedback announcements and meaningful labels.
- [ ] Font scaling, high contrast, non-color-only status indicators and 48×48 dp touch targets.
- [ ] Reduced-motion Wheel immediate reveal with identical authoritative outcomes and economy.
- [ ] Redacted diagnostics and correlation IDs without student data leakage.
- [ ] Android production keystore, signed AAB and internal distribution verification.
- [ ] iOS distribution signing/provisioning, archive/IPA and TestFlight installation verification.
- [ ] Real-device tests: permissions, deep links, resume, offline, font scaling and screen sizes.
- [ ] Staging/prod isolation, rollback and secret management verification.
- [ ] Exact-head CI, device acceptance and **6.3 FREEZE RECEIPT**.

---

## 7. Pilot & product validation — NOT STARTED

- [ ] All required 6.1/6.2/6.3 freeze receipts accepted.
- [ ] End-to-end loop: parent setup → child result → verify → Growth + Learning → RP → Store/Wheel.
- [ ] Android/iOS real-device signing, distribution, upload and reliability checks passed.
- [ ] Four-week family cohort, informed consent, privacy/erasure support and incident owner assigned.
- [ ] Baseline metrics and qualitative check-ins defined; avoid reward dependence and screen-time inflation.
- [ ] Run four consecutive weeks without normal daily usage engineering intervention.
- [ ] Pilot retrospective, quantitative/qualitative analysis and post-pilot backlog.

**Pilot pass is not equivalent to a successful build, a merged PR or an approved design.**

---

## 8. Gate matrix

| Gate | Evidence required | Snapshot |
|---|---|---|
| Upstream contracts | Phase 0–5 freezes | FROZEN |
| Phase 6 design | PR #13 merge + ADR 0008 | ACCEPTED |
| PR #15 implementation slice | Merge + tests + independent audit + exact-head CI | MERGED; full evidence UNVERIFIED |
| Archive/concurrency branch | Review + PR + CI + merge | IN FLIGHT |
| 6.1 parent gate | Full offline/outbox/replay, permissions, failure UX; audit + freeze | OPEN |
| 6.2 parent gate | Notification/metrics/privacy/erasure; legal/privacy approval | OPEN |
| 6.3 parent gate | Accessibility, signing and Android/iOS device evidence | OPEN |
| Pilot | 4-week normal-use acceptance and findings | NOT STARTED |

---

## 9. Risk & dependency register

| ID | Severity | Risk | Closure evidence |
|---|---|---|---|
| R1 | HIGH | Unknown-actor local commands replay under the wrong user | Drift v5 actor/dispatch migration + recovery tests |
| R2 | HIGH | Drafts, photos or cached data leak across family/session transitions | Per-class cleanup/isolation matrix |
| R3 | HIGH | Duplicate submissions or image corruption after retry | Stable-ID + SHA-256 + response-loss matrix |
| R4 | HIGH | Archive operations conflict with immutable ledgers and RLS | RPC/concurrency audit; policy + export validation |
| R5 | HIGH | Child academic data appears in telemetry | Allowlist, redaction, RLS and payload tests |
| R6 | HIGH | CI quota, runner availability, iOS Xcode/macOS costs | Exact-HEAD checks, compliant runner setup |
| R7 | HIGH | Missing Android/Apple production signing | Verified signed artifacts and installs |
| R8 | MEDIUM/HIGH | Accessibility and motion-sensitivity failures | Device + screen-reader + reduced-motion tests |
| R9 | HIGH | No representative family pilot evidence | Four-week real-use evaluation |

---

## 10. Immutable receipt register

| Milestone | Reference | CI as recorded in prior documentation | Status |
|---|---|---|---|
| Phase 3 | `c6721497bfbde7cb436467cccaad5b2234d23cc4` | `41293964415` | FROZEN |
| Phase 4.1 | `8ca9bbc47aa45b96e8ae441671ec57d57ce95dea` | `41332029263` | FROZEN |
| Phase 4.2 / Phase 4 | `6f1057409942a564691fac41509c17d6b602a3af` | `41380026423` | FROZEN |
| Phase 5.1 | `6bb663286746851993d9c66c551e85fe3b9b41a4` | `41558681324` | FROZEN |
| Phase 5.2 | `6dd00177b0d760bd77a34ec702ae34089adc4253` | `41630504285` | FROZEN |
| Phase 6 readiness | PR #12; historical corrected head `5719221ee539a2b535d8ca5dbec2c5d19d67ceee` | Prior `41676926134` was EXTERNAL BLOCKED | Design prerequisite accepted later |
| Phase 6 detailed design | PR #13 merge `fd0584cc01dcf0a36b5cc651455f6b33d20372b8` | `41831755532` SUCCESS per README | ACCEPTED |
| Phase 6 lifecycle/RLS slice | PR #15 merge `007abb72f9d0299873a432df5b8d2d5277a6093b` | **UNVERIFIED in this update** | MERGED |
| Child archive/concurrency slice | branch head `19211e417a546ecc8cc042c1c17d002b466ef520` | **UNVERIFIED** | IN FLIGHT |
| Phase 6.1/6.2/6.3 full freeze | TBD | TBD | OPEN |
| Family pilot | TBD | TBD | NOT STARTED |

An unchanged CI-status API returning an empty legacy status list is **not** equivalent to GitHub Actions check-run success or failure. Read actual workflow/job conclusions before recording CI PASS.

---

## 11. Standard Menuto-style update protocol

1. Before every update, fetch `main` SHA, open PRs, active feature branch heads and latest workflow/job conclusions.
2. Record historical merges, bounded implementation slices, dependency reviews, design approvals, independent audits and freezes separately.
3. Every `[x]` requires matched evidence; never infer completion from a branch name, green historical base CI or a design-only PR.
4. Update the scope-specific checklist before the parent milestone rollup.
5. For each accepted slice, record PR number, base SHA, reviewed HEAD SHA, merge SHA, migration changes, exact test count, pgTAP count, Android/iOS results, CI run ID and audit verdict.
6. Explicitly distinguish code failures from external runner/billing blocks.
7. Append a dated change-log entry; preserve immutable historical evidence and previous decisions.
8. Pick the **next bounded dependency gate** plus optional independent parallel preparation.
9. Do not merge implementation without required approvals; do not mark FROZEN without acceptance.
10. Calculate an overall completion percentage **only** when scope inventory, effort weights and estimation method are approved.

### Update receipt template

```markdown
### YYYY-MM-DD — PR #N — <bounded slice>
- Base / reviewed HEAD / merge SHA: `...`
- Scope: <docs, migration, runtime, test changes>
- Tests: <count, pgTAP, Dart/Flutter, platforms>
- CI: <run ID, outcome, exact commit>
- Audit: <PASS / CONDITIONAL / FAIL + evidence>
- State transition: <IN FLIGHT → MERGED → AUDITED → FROZEN>
- Parent gate impact: <specific checkbox only>
- Next smallest prerequisite: <next action>
```

---

## 12. Chronological updates

### 2026-11-05 — Tracker initialized from Phase 6 accepted design
- [x] Reconstructed frozen Phase 0–5 foundations and Phase 6 design approval.
- [x] Preserved receipt references and separated design from implementation.

### 2026-11-05 — Live GitHub refresh and first repository tracker PR
- [x] Inspected `main` `007abb72f9d0299873a432df5b8d2d5277a6093b`.
- [x] Found PR #15 lifecycle/RLS slice on main; upgraded Phase 6 implementation to PARTIAL.
- [x] Inspected `feat/phase-6-2-child-archive-concurrency`, 3 commits ahead of baseline main, not counted as merged.
- [x] Maintained every Phase 6 parent gate OPEN pending full audit/freeze.
- [ ] Verify PR #15 exact-head CI and independent audit receipts.
- [ ] Reconcile next branch PR/CI and choose next bounded acceptance gate.
- [ ] Review and merge this documentation PR before treating this file as main-branch source of truth.

---

## 13. Source-of-truth hierarchy

1. Merged GitHub commits and accepted freeze receipts for shipped scope.
2. Exact-head GitHub Actions jobs and independent audit receipts for verification.
3. `docs/17-phase-6-pilot-hardening-design-v0.1.md` and ADR 0008 for accepted Phase 6 requirements.
4. `docs/10-implementation-plan-v0.1.md`, original product/metrics/privacy contracts and prior ADRs.
5. `README.md` for summary status (may lag fresh implementation merges).
6. This tracker is a **derived progress index**, not an authority that can override frozen contracts.

**Permanent path:** `docs/LEARNWARD_MASTER_MILESTONE_CHECKLIST.md`.
