# ADR 0006 — Phase 5 Learning Engine, Mastery & Recommendation Decisions

- **Status:** PROPOSED
- **Date:** 2026-11-02
- **Target:** Phase 5 — Mastery Engine, Skill Trees & Recommendation Foundation
- **Design Base:** `5a3c7c75fd0f7c691ee8cd974b51b9cb165a4c2c`

This ADR remains **PROPOSED** during the design gate. It must not be marked ACCEPTED until Phase 5 implementation has passed independent review and the final frozen contract is verified against actual code.

---

## Context

Phases 1–4 establish:

- family/child identity and tenant isolation,
- immutable verified academic events,
- immutable grade-at-assessment provenance,
- deterministic Growth Engine processing,
- append-only XP/RP ledgers,
- a frozen reward economy.

Phase 5 must answer a different question:

> What does verified academic evidence tell LearnWard about the learner's current knowledge state, and what useful learning choice should be offered next?

The central risk is false precision. A broad school-test score is not automatically evidence for every underlying skill, and an EWMA updated in network-arrival order is not deterministic when older assessments are logged late.

---

## Decision 1 — Learning Engine Is Structurally Independent from Reward Economy

Mastery and recommendations consume academic evidence only.

The following are forbidden Mastery Engine / recommendation inputs:

- Study XP,
- RP earned or balance,
- reward prices,
- Wheel tiers/outcomes,
- Store redemptions,
- reward fulfillment,
- engagement streaks intended only to drive app usage.

The Growth Engine and Learning Engine may share one immutable `VerifiedLearningEvent`, but outputs from either engine never feed the other.

**Consequence:** Changing reward configuration must not change mastery or next-challenge output for the same academic evidence set.

---

## Decision 2 — Verified-Only Authoritative Mastery Inputs in v0.1

Phase 5 authoritative mastery state is derived only from `verified_learning_events` and adult-confirmed detailed mappings frozen with the assessment.

Pre-verification/self-report/photo-only observations do not create a second unofficial mastery state.

For authoritative Phase 5 evidence:

```text
verification_weight = 1.00
```

**Consequence:** The conceptual lower trust weights in the early Learning Engine product document remain future hypotheses, not parallel production authority paths.

---

## Decision 3 — Platform-Owned Versioned Knowledge Hierarchy

Phase 5 introduces a curated reference hierarchy:

```text
Subject -> Domain -> Topic -> Skill
```

with stable IDs, explicit `catalog_version`, optional grade ranges, and an active flag.

The graph is platform-owned and read-only to clients in v0.1. Families do not create arbitrary authoritative curriculum nodes during Phase 5.

A full national curriculum is not required. The pilot starts with a small curated graph.

**Consequence:** Curriculum scope is bounded while evidence can still reference stable learning identities.

---

## Decision 4 — Evidence Granularity Caps Mastery Granularity

Every VLE creates broad subject-root evidence automatically.

Richer direct evidence is optional and requires explicit mapping.

Allowed detailed mapping targets are Domain, Topic, and Skill. Subject mapping is unnecessary because subject fallback is automatic.

A whole-assessment total may support Domain/Topic only when explicitly classified by an adult. A whole-assessment total may **not** become Skill evidence.

Skill evidence requires a supported component score or item group.

No evidence is automatically propagated to every ancestor, descendant, or sibling node.

**Consequence:** LearnWard never claims more diagnostic detail than the source evidence supports.

---

## Decision 5 — Detailed Mappings Are Adult-Confirmed and Frozen with Verification

Detailed assessment-to-learning mappings are optional.

An active family adult manages authoritative mappings while the assessment is non-terminal. Mapping mutation serializes on the assessment row so mapping changes cannot race the verification transition.

Once the assessment becomes `verified` or `rejected`, the mapping set is immutable.

Missing mappings never block assessment verification.

**Consequence:** Subject-level learning state works with low parent burden; detailed skill state is available when the family has enough information to support it.

---

## Decision 6 — Immutable Learning Evidence Atoms Separate Source from Projection

Processing a VLE materializes immutable `learning_evidence_events` containing only the academic facts needed by the Learning Engine, including:

- source VLE/assessment,
- child/family,
- learning node,
- grade snapshot,
- assessment type/difficulty,
- score source,
- 0–100 observed performance,
- specificity/level weights,
- academic occurrence and verification timestamps.

Evidence rows are append-only and directly non-mutable by clients.

**Consequence:** Mastery can be rebuilt deterministically without rereading mutable UI/draft state or media.

---

## Decision 7 — Mastery Engine v0.1 Uses Explainable EWMA

The internal mastery estimate uses `0..100`.

First credible observation:

```text
M_1 = P_1
```

Later observations:

```text
M_new = M_old + alpha_effective * (P - M_old)
```

with:

```text
alpha_base = 0.35
```

Specificity weights:

```text
Subject  0.35
Domain   0.50
Topic    0.75
Skill    1.00
```

Difficulty/level diagnostic weights:

```text
normal      1.00
hard        1.00
challenge   1.00
below_level 0.50
```

Therefore for subsequent observations:

```text
alpha_effective = 0.35 * specificity_weight * level_weight
```

Hard/challenge work receives no arbitrary mastery bonus.

**Consequence:** The model is deterministic, inspectable, conservative, and calibratable during pilots.

---

## Decision 8 — Canonical Chronology + Full Node Rebuild Eliminates Arrival-Order Bias

Mastery evidence for one child/node is ordered by:

```text
occurred_at ASC,
verified_at ASC,
learning_evidence_event.id ASC
```

When new evidence appears, the current projection is rebuilt from the complete immutable evidence sequence in this order.

The engine does not append blindly according to request arrival.

For concurrent processing, implementation must serialize each affected `(child_id, learning_node_id)` before reading the rebuild evidence set. The synchronization mechanism must also work when the projection row does not yet exist; an implementation may use a transaction-scoped advisory lock derived from the child/node pair or an equivalently safe create-then-row-lock protocol.

Affected node locks must be acquired in deterministic node-ID order.

**Consequence:** The same evidence set converges to the same mastery state even when an older assessment is verified later or two VLEs are processed concurrently.

---

## Decision 9 — Append-Only Revisions + Mutable Current Projection

Phase 5 separates:

1. immutable academic evidence,
2. append-only `mastery_state_revisions`,
3. current `child_mastery_states` projection.

Every rebuild records engine version and a deterministic calculation snapshot. Current projection rows are server-controlled caches and are never authoritative historical evidence.

Direct client mutation of revisions/projections is revoked.

**Consequence:** Current-state reads are efficient without sacrificing auditability or rebuild capability.

---

## Decision 10 — Confidence and Freshness Are Read-Time Interpretations

### Confidence

Use effective evidence from the last 60 days.

```text
confidence_units = specificity_weight * level_weight
```

Bands:

```text
< 1.5          Low
1.5 .. 3.5     Medium
> 3.5          High, only with >= 2 distinct recent verified events
```

### Freshness

Based on latest credible academic `occurred_at`:

```text
<= 14 days          Recent
>14 and <=45 days   Aging
>45 days            Needs refresh
```

Time passing does not mutate or silently decay the mastery score.

**Consequence:** No scheduled job is required merely to age labels, and historic achievement is preserved.

---

## Decision 11 — `Mastered` Is Stronger Than a High Numeric Estimate

Child-facing state:

```text
Unseen
Emerging
Developing
Secure
Mastery candidate
Mastered
```

`Mastered` requires:

```text
mastery_score >= 85
AND confidence = High
AND >= 2 distinct recent verified assessments
```

A high score with sparse evidence remains `Mastery candidate` rather than `Mastered`.

**Consequence:** One 10/10 worksheet cannot instantly declare durable mastery.

---

## Decision 12 — Phase 5 Recovery Is a Signal, Not a Fake Quest Lifecycle

Phase 5 v0.1 supports:

```text
none
review_suggested
```

A Topic/Skill can receive `review_suggested` from sufficiently diagnostic recent component/item evidence showing meaningful weakness.

The states:

```text
recovery_active
recovery_verified
```

remain reserved until LearnWard has a real persisted learning-challenge execution lifecycle.

**Consequence:** The product can point to recent mistakes without pretending that an unimplemented recovery workflow exists.

---

## Decision 13 — Current Grade Is Recommendation Context; Evidence Grade Remains Immutable Provenance

Mastery evidence retains the immutable `grade_level_snapshot` captured at assessment time.

Recommendation filtering for grade-scoped future skills uses the child's **current** `child_profiles.school_grade` as navigation context because the recommendation concerns what is appropriate now.

If current grade is unknown, grade-specific Unlock/Explore candidates fail closed rather than inferring a grade from old evidence.

**Consequence:** Historical evidence provenance is never rewritten, while recommendations remain anchored to the learner's current school context.

---

## Decision 14 — Next Challenge Is a Read-Only Deterministic Candidate Engine

Return at most three child-facing choices.

Priority:

```text
A Recovery
B Developing
C Refresh
D Unlock
E Exploration
```

Unlock requires explicit prerequisites to be `Mastered`.

Recommendations are generated from current academic state, graph prerequisites, current-grade compatibility and freshness. Reward/economy data is excluded.

Recommendation rows are not persisted as authoritative learning state in v0.1.

Every candidate includes a reason code/explanation.

**Consequence:** Recommendations stay current, explainable and choice-preserving rather than becoming coercive assignments.

---

## Decision 15 — Subject/Topic Summaries Must Show Coverage

A subject is not represented as the naive average of every possible skill.

Topic/subject presentation may summarize observed descendants but must expose evidence coverage, for example:

```text
Linear Equations — Secure
Evidence coverage: 3 of 4 tracked skills
```

Missing skills are unknown, not zero.

Direct node evidence and descendant roll-up summaries remain distinct.

**Consequence:** LearnWard avoids false precision caused by incomplete curriculum coverage.

---

## Decision 16 — Trusted Processing Is Idempotent and Recoverable

Phase 5 implementation introduces an explicit trusted processing operation for verified learning events, with:

- authenticated adult authorization,
- command receipt replay validation,
- unique logical processing per VLE,
- immutable evidence insertion,
- per-child/node serialization,
- deterministic projection rebuild,
- append-only audit revision,
- atomic receipt/processing result,
- catch-up for verified VLEs that were not processed due to network interruption.

Phase 5 does not rely on the client remaining online after verification.

**Consequence:** A lost response or app restart cannot duplicate mastery effects or permanently skip a verified learning event.

---

## Decision 17 — Security Model Reuses Existing Family/Paired-Child Boundary

Private learning state obeys the existing authorization contract:

- active adult: family-scoped child reads,
- paired child: exact child only,
- sibling paired device: denied,
- shared Child Mode under adult auth: UX containment only, not sibling cryptographic isolation.

Reference curriculum data is global/read-only and contains no child PII.

Trusted Phase 5 public functions use the repository's hardened `SECURITY DEFINER` pattern with empty search path, exact grants, and explicit authorization.

---

## Decision 18 — Phase 5 Is Additive; Frozen Migrations Are Not Rewritten

Phase 5 implementation adds new migrations and may replace function definitions only through new migrations where required.

Frozen Phase 1–4 migration files are immutable history.

The design PR itself contains no Phase 5 migration or runtime implementation.

---

## Consequences / Trade-offs

### Chosen trade-offs

- **Correctness over incremental optimization:** per-node rebuild is acceptable for pilot volume.
- **Explainability over predictive sophistication:** EWMA and explicit rules instead of black-box ML.
- **Partial usefulness over curriculum completeness:** broad subject state works immediately.
- **Adult-confirmed detailed evidence over untrusted auto-classification:** higher integrity at the cost of some parent effort.
- **Read-time freshness/confidence over scheduled mutation:** simpler and less drift-prone.
- **Choice over coercion:** recommendation candidates rather than assignments.

### Deferred concerns

- post-verification mapping correction/revision workflow,
- family-created knowledge graphs,
- automatic authoritative OCR/AI classification,
- full curriculum coverage,
- calibrated item difficulty / IRT,
- Bayesian mastery models,
- forgetting-curve score decay,
- full Recovery Quest execution,
- teacher/school organization features.

---

## Acceptance Conditions for This ADR

This ADR may move from **PROPOSED** to **ACCEPTED** only when the final implementation demonstrably satisfies:

1. verified-only authoritative mastery input,
2. evidence-granularity enforcement,
3. canonical late-evidence determinism,
4. concurrency-safe first-write and subsequent projection rebuild,
5. append-only audit + server-controlled projection,
6. confidence/freshness separation,
7. reward-independence invariance tests,
8. cross-family/sibling RLS tests,
9. domain/database parity,
10. recovery/catch-up behavior,
11. Android/iOS CI,
12. independent review + green post-merge CI.
