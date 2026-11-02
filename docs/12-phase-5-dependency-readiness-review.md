# Phase 5 Dependency & Readiness Review — Learning Engine / Mastery

**Status:** READY FOR DETAILED DESIGN; IMPLEMENTATION BLOCKED UNTIL DESIGN GATE IS APPROVED  
**Review Date:** 2026-11-02  
**Target Milestone:** Phase 5 — Mastery Engine, Skill Trees & Recommendation Foundation  
**Reviewed Main Baseline:** `5a3c7c75fd0f7c691ee8cd974b51b9cb165a4c2c`  
**Frozen Functional Baseline:** Phase 4 merge `6f1057409942a564691fac41509c17d6b602a3af`  

---

## 1. Review Objective

This review determines whether LearnWard is structurally ready to begin Phase 5 design and what must be resolved before any Phase 5 schema, RPC, domain-engine, or Flutter implementation begins.

Phase 5 exists to make LearnWard useful after reward novelty fades. Its exit gate remains:

> Verified evidence can update a visible learning state without being influenced by reward bonuses.

The planned Phase 5 capability set is:

- curriculum / knowledge hierarchy skeleton,
- assessment-to-learning-node evidence mapping,
- mastery score,
- confidence,
- freshness,
- recovery signal/state,
- prerequisite skill graph,
- up to three next-challenge candidates,
- parent/child learning-state presentation.

Phase 5 is **not** permission to build an in-app curriculum platform, automated teacher, AI tutor, or content-generation system.

---

## 2. Upstream Dependencies — Current State

### Phase 1 — Family + Child Identity: READY

Phase 5 can rely on the frozen family tenant boundary and child identity contract:

- `family_id` is the server security boundary,
- `child_profiles` are distinct from Auth users,
- active adults may act across children in their family,
- paired-child grants are scoped to one child,
- shared Child Mode remains UX containment under the adult session rather than a cryptographic sibling boundary.

Phase 5 must preserve these semantics. A paired child must never read a sibling's mastery/evidence state.

### Phase 2 — Verified Academic Evidence: READY

`public.verified_learning_events` already provides an immutable, append-only academic source with:

- family and child identity,
- assessment identity,
- canonical `subject_key`,
- assessment type and difficulty,
- raw/max score plus normalized score,
- evidence count,
- occurrence time,
- verification time and verifying adult,
- immutable review provenance.

This is the correct authoritative source boundary for Phase 5. Mastery must not be manufactured from local drafts, reward events, Wheel spins, or unverified assessment state.

### Phase 3 — Grade Provenance + Deterministic Engine Pattern: READY

Phase 3 added immutable `grade_level_snapshot` provenance to assessments and verified learning events. Unknown historical grade remains `NULL` rather than being fabricated from the child's current mutable grade.

Phase 3 also established patterns Phase 5 should reuse:

- pure Dart deterministic engine logic,
- server-authoritative processing,
- append-only calculation/audit records,
- mutable cached projection separated from immutable source history,
- idempotent command receipts,
- catch-up/recovery for interrupted processing,
- exact database/domain parity testing.

### Phase 4 — Reward Economy: READY AND MUST REMAIN DOWNSTREAM-ONLY

Phase 4 is frozen. Phase 5 may display XP/RP context in surrounding UI, but reward state must not enter Mastery Engine inputs.

Forbidden dependencies include:

- RP balance changing mastery,
- reward tier changing mastery,
- Wheel/Store behavior changing confidence,
- XP amount changing mastery,
- reward redemption history affecting next-challenge ranking.

The Learning Engine and Reward Economy may consume the same verified assessment source, but neither may feed the other.

---

## 3. Repository & Tooling Readiness

### Package boundaries: READY

Current dependency direction is appropriate:

```text
learnward_domain <- learnward_application <- learnward_data <- mobile
```

Recommended Phase 5 ownership:

- `learnward_domain`: mastery algorithm, confidence/freshness classification, recovery signal rules, recommendation ranking types.
- `learnward_application`: use cases and repository ports.
- `learnward_data`: Supabase/Drift adapters and DTO mapping.
- `apps/mobile`: parent/child learning-state and recommendation presentation.
- `learnward_test_support`: taxonomy/evidence/mastery fixtures.

No new package is justified for Phase 5 v0.1.

### CI/testing: READY

The current CI already verifies:

- formatting and analysis,
- domain/application/data/widget tests,
- generated Drift freshness,
- Supabase migration reset,
- pgTAP RLS/security tests,
- concurrency/integration scripts,
- Android debug build,
- iOS simulator compile.

Phase 5 should extend these existing jobs rather than create a parallel pipeline.

### Migration discipline: READY

Frozen Phase 1–4 migrations must not be rewritten. Phase 5 implementation must be additive through new versioned migrations.

---

## 4. Missing Dependencies / Design Gaps

The codebase is ready for design, but **not yet ready for implementation** until the following contracts are resolved.

### Gap A — No canonical knowledge taxonomy & catalog lifecycle provenance

Current academic identity stops at `subject_key`. There is no persisted:

```text
Subject -> Domain -> Topic -> Skill
```

Phase 5 needs a stable, curated, versioned hierarchy with stable node IDs and explicit prerequisite edges.

Furthermore, catalog-version provenance and lifecycle must be fully defined:
- **Legacy migration policy:** When the Phase 5 migration runs, all existing assessments and `verified_learning_events` that predate catalog-version provenance are deterministically assigned the initial frozen catalog version: `pilot-v0.1`. The migration must never infer a different version from execution time.
- **Catalog registry source of truth:** A dedicated catalog version registry (`learning_catalog_versions`) tracks version identifiers, lifecycle state (`draft | active | retired`), activation timestamp, and creation timestamp. Exactly ONE version has `status = 'active'` at any time.
- **Server-controlled active version:** The active version used for new assessment creation is strictly server-controlled; the caller/client cannot choose or override it. If no valid active catalog version exists, new assessment creation fails closed.
- **Published version immutability:** Published, active, and retired catalog versions are immutable. Node definitions, titles, parent links, and grade spans must never be modified in place within an existing version. Semantic changes require a new version.
- **Cross-version recommendation semantics:** Historical evidence and mastery remain permanently attached to their original catalog nodes and version. The recommendation engine evaluates candidates against the current active catalog. Phase 5 v0.1 does not perform automatic cross-version mastery migration; cross-version transfer requires a future explicit crosswalk policy.
- Exactly one Subject root node must exist per `(catalog_version, subject_key)`.
- Parent/child edges must maintain strict same-subject and same-version integrity.
- Detailed mappings must never cross subjects.
- Subsequent deactivation of a learning node (`is_active = false`) must not render already-verified historical evidence unprocessable.

### Gap B — No evidence-to-node mapping contract, mutable drafts & risk of overweighting

A verified total assessment score does not contain enough information to claim specific skill mastery.

The design must distinguish:

- broad assessment-total evidence,
- explicitly tagged domain/topic evidence,
- component/item-group evidence capable of supporting skill-level updates.

A broad score must never be silently sprayed across descendant skills.

Crucially, the mapping lifecycle must account for mutable assessment drafts:
- In Phase 2, `update_assessment_draft` permits changing `subject_key`, assessment type, difficulty, score, and dates while status is `draft`.
- Allowing authoritative learning mappings on drafts creates grave integrity risks (e.g. changing subject in draft leaves dangling cross-subject mappings).
- Therefore, authoritative `assessment_learning_mappings` may be created or replaced **ONLY when `assessment.status = 'pending_review'`**.
- Mapping mutation is strictly RPC-only; direct client `INSERT`, `UPDATE`, and `DELETE` on `assessment_learning_mappings` are denied.
- The trusted mapping RPC locks the assessment row `FOR UPDATE`, derives family identity, enforces active family adult authorization, requires `status = 'pending_review'`, validates subject/catalog consistency, and replaces the mapping set atomically.
- Assessment verification/rejection locks the same assessment row `FOR UPDATE`, ensuring mapping mutations and terminal transitions serialize deterministically: verification never observes a partial or racing mapping set.

Furthermore, one assessment must **never overweight** a learning node or bias EWMA ordering:
- At most ONE effective mastery observation may exist per `(verified_learning_event_id, learning_node_id)`.
- Multiple component or item-group mappings for the same node must be deterministically aggregated before feeding EWMA (by score mass for component scores: `sum(raw) / sum(max)`, or by count for item groups: `sum(correct) / sum(items)`).
- Within `(assessment_id, learning_node_id)`, duplicate component identities (`component_key`) are rejected.
- Mixing different score source types on the same node for one assessment is forbidden (fail-closed v0.1).
- Confidence counts the single effective observation once, preventing artificial confidence inflation from split mappings.

### Gap C — No deterministic late-evidence strategy & unsafe future timestamps

EWMA mastery is order-sensitive.

Real families may log or verify an older school assessment after a newer one. Furthermore, client-supplied timestamps can be future-dated due to device clock skew.

To prevent future timestamps from falsely granting permanent recency or bypassing confidence windows:
- The server derives an immutable `effective_occurred_at = least(occurred_at, verified_at)` (with fail-safe `least(..., as_of)`).
- Raw `occurred_at` is preserved for audit provenance.
- `effective_occurred_at` is used for ALL chronological and read-time Learning Engine semantics: canonical evidence ordering, the 60-day confidence window, freshness elapsed time, recovery recency, and recommendation ranking.
- Canonical chronology is: `effective_occurred_at ASC, verified_at ASC, learning_evidence_event.id ASC`.
- Rebuilds execute under first-write-safe child+node serialization locks so the final state is identical regardless of request/network order.

### Gap D — No authoritative mastery audit/projection model

There is no persisted separation between:

- immutable academic evidence,
- immutable mastery calculation/audit history,
- current cached mastery projection.

Phase 5 needs this separation before implementation begins. Effective evidence atoms must preserve immutable diagnostic counts (`item_count`, `correct_count`) required by downstream recovery.

### Gap E — Confidence and freshness require explicit deterministic time context

Confidence is based on a rolling 60-day evidence window, and freshness changes as time passes (14-day / 45-day boundaries). Persisting them as blindly incremented counters or scheduled state transitions would drift.

Furthermore, calling non-deterministic clocks throughout multiple queries or across Dart/PostgreSQL boundaries causes subtle boundary divergence.

The design must capture ONE server-authoritative `as_of` timestamp at request start (`v_as_of := transaction_timestamp();`) and pass it consistently through confidence, freshness, recovery recency, and next-challenge ranking. Pure Dart engines accept an explicit `DateTime asOf` parameter.

Confidence must enforce both lower and upper bounds:
```text
effective_occurred_at >= as_of - interval '60 days'
AND effective_occurred_at <= as_of
```
Freshness computes `elapsed = as_of - effective_occurred_at` without negative elapsed time.

### Gap F — Recovery lifecycle is underspecified & lacks diagnostic provenance and recency bounds

The product document describes recovery states, but Phase 5 v0.1 does not yet have a persistent challenge-execution system.

The design must distinguish a deterministic **recovery signal** from a future full Recovery Quest lifecycle:
- Topic/Skill recovery signal `review_suggested` must be driven by immutable diagnostic facts preserved directly on the evidence atom (`item_count >= 3 AND incorrect_count >= 2` for item groups; `performance_pct <= 50` for component scores).
- Broad `assessment_total` and Subject fallback evidence must never raise or clear Skill recovery.
- A later credible effective observation for the same node (`component_score` or `item_group`) with `performance_pct >= 70` clears the recovery signal immediately.
- **Recency and expiry contract:** A `review_suggested` signal is eligible only if the latest unresolved recovery observation is within **30 days** of `as_of` (`as_of - effective_occurred_at <= interval '30 days'`). If older than 30 days without newer confirming weakness, the recovery signal decays to `none`, preventing years-old weak results from permanently hijacking top-priority recommendations.

### Gap G — Recommendation ownership and persistence are undefined

"Next challenge" should be a recommendation, not an assignment. The design must define:

- deterministic ranking inputs,
- prerequisite eligibility,
- grade-aware filtering,
- up to three choices,
- whether candidates are persisted or generated read-only,
- explicit exclusion of reward/economy signals.

### Gap H — Parent classification burden

Detailed skill mapping can create unacceptable parent admin work. Phase 5 must degrade gracefully:

- subject-level learning state must work from every verified event,
- detailed mappings must remain optional,
- missing metadata must never block assessment verification,
- future machine suggestions may assist classification but cannot silently create authoritative mastery claims.

### Gap I — Concurrent command replay race and catch-up receipt semantics

The relationship between public RPC idempotency (`command_receipts`), logical processing events (`learning_processing_events`), and bulk catch-up needs explicit definition:
- Explicit operation `process_learning` with `resource_id = verified_learning_event_id`.
- **Post-lock re-check:** To prevent concurrent same-command calls from racing into primary-key collisions on `command_receipts`, the trusted processor must acquire the per-VLE serialization lock, re-read `command_receipts` and `learning_processing_events` in a fresh snapshot, and return a clean replay if committed by a concurrent caller.
- Replay with same command ID returns committed result cleanly without error.
- New command ID targeting an already-processed VLE binds a new command receipt to the same VLE and returns the committed result without duplicating evidence or revisions.
- Reusing a command ID for a different VLE is strictly rejected.
- Bulk catch-up discovers unprocessed VLEs and runs an internal trusted processor anchored on `unique(verified_learning_event_id)` without forging synthetic public command IDs.

---

## 5. Readiness Decisions Required Before Implementation

The accompanying detailed design resolves these as follows:

1. **Verified-only authoritative inputs.** Phase 5 v0.1 processes `verified_learning_events`; pre-verification photos/self-reports do not alter authoritative mastery.
2. **Platform-owned versioned taxonomy with immutable catalog provenance & registry.** The server snapshots the active catalog version at assessment creation into `assessments.learning_catalog_version`, copied into `verified_learning_events.learning_catalog_version` upon verification. A dedicated catalog version registry (`learning_catalog_versions`) ensures exactly one server-controlled active authoring catalog version exists at any time. Legacy Phase 2–4 records are deterministically migrated to `pilot-v0.1`. Delayed processing and catch-up use the VLE's snapshot only. Exactly one Subject root exists per `(catalog_version, subject_key)`; hierarchy edges and mappings maintain strict same-subject integrity; deactivating a node later does not invalidate historical evidence.
3. **One effective observation per VLE/node with deterministic aggregation.** At most one effective mastery observation exists per `(verified_learning_event_id, learning_node_id)`. Multiple mappings for the same node aggregate deterministically (by score mass for component scores: `sum(raw) / sum(max)`, or by counts for item groups: `sum(correct) / sum(items)`). Within one assessment/node, duplicate component identities (`component_key`) are rejected, and mixing score source types is disallowed. Confidence counts the single effective observation once.
4. **No automatic descendant propagation.** Evidence updates only the node whose granularity is actually supported. Subject fallback is automatic; detailed mappings are optional.
5. **Pending-review-only mapping lifecycle & granularity.** Authoritative detailed mappings may be set or replaced ONLY while `assessment.status = 'pending_review'`. Draft editing never leaves dangling mappings. Direct table mutations are revoked; mappings mutate strictly via trusted adult RPC serialized against assessment verification/rejection. A whole-test score cannot be relabeled as one specific skill score.
6. **Immutable evidence atoms preserve diagnostic counts.** Effective evidence rows snapshot `item_count` and `correct_count` (with derived `incorrect_count`), enabling downstream recovery signal evaluation without rereading raw media.
7. **Effective chronology + node rebuild.** Evidence is ordered by `effective_occurred_at ASC, verified_at ASC, learning_evidence_event.id ASC`, where `effective_occurred_at = least(occurred_at, verified_at)`. Rebuilds execute under transaction-scoped child+node serialization locks that work even before the first projection row exists.
8. **Mastery history remains auditable.** Rebuilds produce append-only mastery revision records; `child_mastery_states` is a server-controlled cached projection.
9. **Explainable EWMA with Option A initialization.** First credible observation initializes `M_1 = P_1` as a deliberate pilot hypothesis; level and specificity weights govern subsequent update alphas; constrained confidence prevents declaring `Mastered` prematurely on below-level work.
10. **Single server-authoritative `as_of` clock input.** Every read model captures one `as_of` timestamp at request start (`v_as_of := transaction_timestamp();`), passed through confidence, freshness, recovery, and recommendations. Pure Dart domain engines accept explicit `DateTime asOf`. Confidence bounds evidence between `as_of - interval '60 days'` and `as_of`. Freshness elapsed time cannot be negative.
11. **Confidence v0.1 in Phase 5.1 & `Mastered` declaration.** Confidence v0.1 is included in Phase 5.1 to enable valid evaluation of the `Mastered` band (`mastery_score >= 85`, `Confidence = High`, and at least two distinct recent verified assessments).
12. **Recovery v0.1 is a deterministic signal with 30-day recency window.** `review_suggested` is raised for Topic/Skill from diagnostic evidence counts (`item_count >= 3 AND incorrect_count >= 2` for item groups; `performance_pct <= 50` for component scores). Broad `assessment_total` cannot raise or clear Skill recovery. Signal expires to `none` after 30 days without confirming weakness. A later observation with `performance_pct >= 70` clears it immediately.
13. **Recommendations are read-only candidates.** Up to three choices are generated deterministically from learning state, graph prerequisites, and current grade context.
14. **Reward separation is structural and testable.** Mastery/recommendation inputs contain no XP/RP/reward fields.
15. **Strict idempotency, post-lock recheck, and catch-up contract.** `command_receipts.operation = process_learning` with `resource_id = verified_learning_event_id`. Inside the VLE lock, re-reading receipts and processing events prevents concurrent same-command replay collisions. Same-command replay returns the committed result. New command ID for an already-processed VLE binds a new command receipt to the same VLE and returns the committed result without duplicating evidence or revisions. Reusing a command ID for a different VLE is rejected. Bulk catch-up discovers unprocessed VLEs and executes an internal trusted processing routine anchored on `unique(verified_learning_event_id)` without forging synthetic public command IDs.

---

## 6. Risks and Mitigations

| Risk | Severity | Phase 5 mitigation |
|---|---:|---|
| Legacy assessments predate catalog version provenance | Critical | Phase 5 migration deterministically assigns `pilot-v0.1` to all pre-existing assessments and VLEs |
| Delayed catch-up resolves to newer/wrong catalog version | Critical | Server snapshots active `learning_catalog_version` from registry at assessment creation; copied to VLE; processing uses VLE snapshot only |
| Mutable drafts leave invalid/orphaned mappings | Critical | Authoritative mappings allowed ONLY when `assessment.status = 'pending_review'`; draft updates cannot desynchronize mappings |
| Multiple/overlapping mappings overweight node or inflate confidence | Critical | At most one effective observation per VLE/node via deterministic aggregation; `component_key` uniqueness; confidence counts effective observation once |
| Whole-test score falsely claims skill mastery | Critical | Granularity contract + skill evidence requires component/item mapping |
| Future-dated timestamps create permanent freshness / bypass confidence | Critical | Server derives `effective_occurred_at = least(occurred_at, verified_at)`; confidence requires `effective_occurred_at <= as_of`; elapsed cannot be negative |
| Late evidence changes result depending on request order | Critical | Canonical chronology + deterministic projection rebuild under first-write-safe locks |
| Child manipulates mastery input | High | Verified-event boundary; paired child denied mapping RPC; detailed mapping adult-confirmed in v0.1 |
| Recovery signal lacks diagnostic facts | High | Effective evidence atoms preserve immutable `item_count` and `correct_count` |
| Recovery signal remains active indefinitely | Medium | 30-day recency/expiry window relative to `as_of`; older unresolved signals decay to `none` |
| Clock drift across queries or Dart/DB boundary divergence | High | Single server-authoritative `as_of` captured at request start; pure Dart takes explicit `DateTime asOf` |
| Concurrent same-command calls collide on receipt primary key | High | Post-lock recheck of `command_receipts` inside VLE critical section returns clean replay |
| Concurrent processing or catch-up duplicates command IDs or records | High | Explicit operation `process_learning`, `resource_id = vle_id`, new command binds to existing VLE, catch-up uses internal trusted processor |
| Mastery becomes a disguised reward score | Critical | No economy fields in engine input; parity/invariance tests |
| Sparse data shown as precise | High | Separate mastery/confidence/freshness; `Unseen`/Low confidence states |
| Missing grade causes inappropriate next skill | High | Fail closed for grade-specific unlock/explore; still allow broad visible progress |
| Recommendation becomes coercive | Medium | Up to three candidates; no mandatory ordering in child UI |
| Curriculum scope explodes | High | Pilot taxonomy only; no full national curriculum prerequisite |
| Global taxonomy leaks tenant data | Low | Reference catalog contains no child/family data; client writes revoked |
| Parent workload rises sharply | High | Subject fallback automatic; richer mapping optional; no verification blockage |

---

## 7. Scope Recommendation

Implement Phase 5 in two bounded slices after design approval.

### Phase 5.1 — Knowledge + Mastery Foundation

- catalog version registry (`learning_catalog_versions`),
- deterministic legacy catalog migration (`pilot-v0.1`),
- versioned learning-node hierarchy,
- assessment-to-node mappings (`pending_review` only),
- immutable learning evidence atoms with diagnostic facts,
- pure Dart Mastery Engine v0.1 (EWMA, Option A initialization),
- **Confidence v0.1** (rolling 60-day window, confidence units, distinct-VLE rule),
- **Mastery bands including final `Mastered`**,
- append-only mastery revisions,
- current child mastery projection (`child_mastery_states`),
- exactly-once/recoverable VLE processing with post-lock receipt recheck,
- subject-level fallback from every verified event,
- parent/child basic mastery presentation.

### Phase 5.2 — Skill Graph + Interpretation + Recommendation

- prerequisite skill graph (`learning_prerequisites`),
- dynamic Freshness (14d/45d boundaries relative to `as_of`),
- deterministic Recovery signal (`review_suggested` with 30-day recency/expiry window),
- read-only next-challenge candidate engine (up to three candidates),
- child choice UI with candidate cards,
- parent explanation/coverage presentation.

Do not add full learning content delivery, AI tutoring, lesson generation, social comparison, or reward-linked recommendation ranking in Phase 5.

---

## 8. Readiness Verdict

### Dependency status

**PASS** — Frozen Phase 1–4 contracts provide the required identity, evidence, grade provenance, deterministic-engine pattern, security model, and CI foundation.

### Implementation status

**HOLD UNTIL PHASE 5 DESIGN IS APPROVED** — The implementation blockers are architectural rather than missing infrastructure. They are resolved in the accompanying Phase 5 detailed design and proposed ADR, which must be reviewed before any Phase 5 migration or runtime code is created.

### Required next gate

```text
Dependency/Readiness Review
        PASS
          |
          v
Phase 5 Detailed Design + Proposed ADR
          |
          v
Independent design review
          |
          v
Only then: Phase 5.1 implementation
```
