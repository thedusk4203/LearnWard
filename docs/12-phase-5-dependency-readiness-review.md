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

### Gap A — No canonical knowledge taxonomy

Current academic identity stops at `subject_key`. There is no persisted:

```text
Subject -> Domain -> Topic -> Skill
```

Phase 5 needs a stable, curated, versioned hierarchy with stable node IDs and explicit prerequisite edges.

### Gap B — No evidence-to-node mapping contract

A verified total assessment score does not contain enough information to claim specific skill mastery.

The design must distinguish:

- broad assessment-total evidence,
- explicitly tagged domain/topic evidence,
- component/item-group evidence capable of supporting skill-level updates.

A broad score must never be silently sprayed across descendant skills.

### Gap C — No deterministic late-evidence strategy

EWMA mastery is order-sensitive.

Real families may log or verify an older school assessment after a newer one. Therefore Phase 5 cannot define mastery as "apply updates in request arrival order".

The engine needs a canonical chronology and a deterministic projection rebuild strategy so the final state is the same regardless of request/network order.

### Gap D — No authoritative mastery audit/projection model

There is no persisted separation between:

- immutable academic evidence,
- immutable mastery calculation/audit history,
- current cached mastery projection.

Phase 5 needs this separation before implementation begins.

### Gap E — Confidence and freshness are time-windowed

Confidence is based on recent evidence and freshness changes as time passes. Persisting them as blindly incremented counters or scheduled state transitions would drift.

The design must define which values are stored and which are derived at read time.

### Gap F — Recovery lifecycle is underspecified

The product document describes recovery states, but Phase 5 v0.1 does not yet have a persistent challenge/quest execution system.

The design must distinguish a deterministic **recovery signal** from a future full Recovery Quest lifecycle.

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

---

## 5. Readiness Decisions Required Before Implementation

The accompanying detailed design resolves these as follows:

1. **Verified-only authoritative inputs.** Phase 5 v0.1 processes `verified_learning_events`; pre-verification photos/self-reports do not alter authoritative mastery.
2. **Platform-owned curated taxonomy.** Stable global learning nodes are read-only to clients and seeded/versioned by migrations/content releases.
3. **Partial classification is first-class.** Every verified event contributes at least subject-level evidence; richer mappings are optional.
4. **No automatic descendant propagation.** Evidence updates only the node whose granularity is actually supported.
5. **Skill-level evidence requires component/item-group support.** A whole-test score cannot be relabeled as one specific skill score.
6. **Canonical chronology.** Evidence is ordered by academic occurrence, verification time, then immutable evidence ID.
7. **Projection rebuild, not arrival-order mutation.** When new evidence is committed, affected mastery projections are recomputed from immutable effective evidence in canonical order.
8. **Mastery history remains auditable.** Rebuilds produce append-only mastery revision records; the current state is a projection.
9. **Confidence/freshness are read-time interpretations.** Mastery score is persisted; recent confidence/freshness are derived from evidence timestamps and the current clock.
10. **Recovery v0.1 is a signal.** `review_suggested` is supported now; full `recovery_active` / `recovery_verified` quest execution is deferred until a challenge-execution lifecycle exists.
11. **Recommendations are read-only candidates.** They are generated deterministically from learning state and graph prerequisites; they do not mutate mastery or economy.
12. **Reward separation is structural and testable.** Mastery/recommendation inputs contain no XP/RP/reward fields.

---

## 6. Risks and Mitigations

| Risk | Severity | Phase 5 mitigation |
|---|---:|---|
| Whole-test score falsely claims skill mastery | Critical | Granularity contract + skill evidence requires component/item mapping |
| Late evidence changes result depending on request order | Critical | Canonical chronology + deterministic projection rebuild |
| Child manipulates mastery input | High | Verified-event boundary; detailed authoritative mapping adult-confirmed in v0.1 |
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

- versioned learning-node hierarchy,
- optional assessment-to-node mappings,
- immutable learning evidence atoms,
- pure Dart Mastery Engine v0.1,
- append-only mastery revisions,
- current child mastery projection,
- exactly-once/recoverable VLE processing,
- subject-level fallback from every verified event,
- parent/child basic mastery presentation.

### Phase 5.2 — Skill Graph + Interpretation + Recommendation

- prerequisite edges,
- dynamic confidence,
- dynamic freshness,
- deterministic recovery signal,
- read-only next-challenge candidate engine,
- child choice UI with up to three candidates,
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
