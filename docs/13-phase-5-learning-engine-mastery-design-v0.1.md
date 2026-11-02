# Phase 5 Detailed Design — Learning Engine, Mastery & Recommendation v0.1

**Status:** PROPOSED — DESIGN ONLY  
**Document Version:** `v0.1.1`  
**Date:** 2026-11-02  
**Target Milestone:** Phase 5 — Mastery Engine, Skill Trees & Recommendation Foundation  
**Design Base:** `5a3c7c75fd0f7c691ee8cd974b51b9cb165a4c2c`  
**No Phase 5 migration/runtime code is authorized by this document alone.**

---

## 1. Product Objective

Phase 5 turns verified academic evidence into an explainable learning state that helps a child understand:

1. what they are getting better at,
2. what is still developing,
3. what may need a refresh,
4. where recent mistakes suggest recovery work,
5. what useful challenge they could choose next.

```text
Verified Learning Event
        |
        v
Supported Learning Evidence
        |
        v
Mastery Engine v0.1
        |
        +--> Mastery estimate
        +--> Confidence interpretation
        +--> Freshness interpretation
        +--> Recovery signal
        |
        v
Next Challenge Candidates
        |
        v
Child chooses what to tackle next
```

The Growth Engine and Learning Engine may consume the same immutable verified academic source, but their outputs are structurally independent:

```text
Verified academic evidence
       |                  |
       v                  v
 Growth Engine       Learning Engine
       |                  |
    XP / RP          Mastery / Next Challenge
```

XP, RP, reward configuration, Wheel outcomes, Store redemptions and reward balances are not valid Learning Engine inputs.

---

## 2. Phase 5 Non-Goals

Phase 5 does **not** build:

- a complete Vietnamese national curriculum database,
- an AI teacher/tutor,
- automatic lesson generation,
- automatic authoritative OCR/LLM skill diagnosis,
- teacher/school organization tenancy,
- social or sibling academic leaderboards,
- reward-driven recommendation ranking,
- high-stakes educational placement,
- a black-box predictive model,
- a full Recovery Quest execution lifecycle.

The pilot must work with a small curated graph and partial classification.

---

## 3. Constitutional Invariants

### 3.1 Verified academic evidence is authoritative

Authoritative mastery updates originate only from immutable `verified_learning_events` plus supported detailed mappings that were adult-confirmed before verification.

Local drafts, pending assessments, unverified photos, reward activity, XP/RP rows and engagement events do not update mastery.

### 3.2 Evidence granularity limits claims

A whole-assessment score may support broad learning-state claims, but it must not silently become detailed skill evidence.

A verified Math exam score may automatically support the Math subject root and, if explicitly mapped, a Domain/Topic. It must not automatically assign the same score to Fractions, Linear Equations, Geometry, or every descendant skill.

### 3.3 Missing metadata never blocks result capture

Assessment verification remains valid when no Domain/Topic/Skill mapping exists. Every VLE still contributes subject-root evidence.

### 3.4 Mastery, confidence and freshness remain separate

A high score can coexist with Low confidence. Time can make evidence stale without silently reducing historic mastery.

### 3.5 No sibling comparison

Mastery and recommendations are scoped to one child. Sibling performance is never an input or baseline.

### 3.6 Learner autonomy

The recommendation layer returns at most three candidate choices. It does not issue mandatory assignments.

---

## 4. Phase Structure

### Phase 5.1 — Knowledge + Mastery Foundation

Deliver:

- versioned learning hierarchy,
- optional assessment learning mappings,
- immutable learning evidence atoms,
- deterministic Mastery Engine v0.1,
- append-only mastery revisions,
- current mastery projection,
- exactly-once/recoverable VLE processing,
- automatic subject fallback,
- basic parent/child mastery presentation.

### Phase 5.2 — Skill Graph + Recommendation Foundation

Deliver:

- explicit prerequisite graph,
- dynamic confidence,
- dynamic freshness,
- deterministic recovery signal,
- next-challenge candidates,
- explanation/coverage presentation,
- child choice UI.

Phase 5 is frozen only after both slices pass independent implementation review and green post-merge CI.

---

## 5. Canonical Knowledge Model

The hierarchy is:

```text
Subject -> Domain -> Topic -> Skill
```

### 5.1 Platform-owned reference nodes

Conceptual table:

```text
public.learning_nodes
```

Proposed fields:

- `id uuid primary key`
- `catalog_version text not null`
- `node_type text not null` in `subject | domain | topic | skill`
- `subject_key text not null`
- `canonical_key text not null`
- `title text not null`
- `parent_id uuid null`
- `grade_min integer null`
- `grade_max integer null`
- `sort_order integer not null`
- `is_active boolean not null default true`
- `created_at timestamptz not null`

Required invariants:

- stable unique `(catalog_version, canonical_key)`,
- parent/child share one catalog version,
- valid type edges only: Subject→Domain, Domain→Topic, Topic→Skill,
- Subject has no parent,
- `grade_min <= grade_max` when both exist,
- `subject_key` matches the frozen canonical subject values.

### 5.2 Catalog versioning

Pilot catalog begins with an explicit small version such as `pilot-v0.1`.

Once evidence references a node ID, its semantic meaning must not be changed in place. Material curriculum changes require new node IDs and/or a new catalog version with an explicit migration policy.

### 5.3 Client permissions

Reference nodes contain no child/family private data. Authenticated clients may read active catalog data; direct client writes are revoked. Catalog changes occur through migrations/content releases.

### 5.4 `subject_key = other`

`other` may receive broad subject evidence. Phase 5 v0.1 does not create arbitrary family-authored authoritative skill graphs beneath it.

---

## 6. Explicit Skill Prerequisite Graph

Conceptual table:

```text
public.learning_prerequisites
```

Fields:

- `prerequisite_node_id uuid`
- `dependent_node_id uuid`
- `catalog_version text`
- `created_at timestamptz`

Rules:

1. both endpoints are Skill nodes,
2. edges are curated and explicit,
3. self-edges forbidden,
4. duplicates forbidden,
5. graph must be acyclic,
6. no ML/LLM suggestion becomes authoritative automatically.

Because clients cannot mutate this graph in v0.1, DAG validation may run as migration/content validation rather than an expensive public runtime mutation path.

---

## 7. Assessment-to-Learning Mapping Contract

### 7.1 Mapping is optional

An assessment without detailed mappings still verifies and contributes subject-root evidence.

### 7.2 Detailed mappings

Conceptual table:

```text
public.assessment_learning_mappings
```

Proposed fields:

- `id uuid primary key`
- `family_id uuid not null`
- `child_id uuid not null`
- `assessment_id uuid not null`
- `learning_node_id uuid not null`
- `score_source text not null`
- `component_raw_score numeric null`
- `component_max_score numeric null`
- `item_count integer null`
- `correct_count integer null`
- `confirmed_by_user_id uuid not null`
- `created_at timestamptz not null`
- `updated_at timestamptz not null`

Allowed `score_source` values:

```text
assessment_total
component_score
item_group
```

Detailed mapping targets are **Domain, Topic, or Skill only**. Explicit Subject mappings are disallowed because every processed VLE already creates exactly one automatic subject-root evidence atom.

### 7.3 Score-source rules

#### `assessment_total`

Uses the verified whole-assessment score.

Allowed targets:

- Domain
- Topic

Not allowed for Skill. Not used for explicit Subject mappings because Subject fallback is automatic.

#### `component_score`

Uses:

```text
component_raw_score / component_max_score
```

May support Domain, Topic or Skill when the active family adult confirms that the component measures that node.

Validation requires `component_max_score > 0` and `0 <= component_raw_score <= component_max_score`.

#### `item_group`

Uses:

```text
correct_count / item_count
```

Designed primarily for Topic/Skill evidence.

Validation requires:

```text
item_count > 0
0 <= correct_count <= item_count
```

### 7.4 Mapping authority

Only an active family adult may create/replace authoritative detailed mappings in v0.1. Child suggestions, if added later, remain non-authoritative until adult confirmation.

### 7.5 Mapping mutation window and verification race

Mappings may be changed only while the assessment is non-terminal.

The trusted mapping mutation path must lock the target assessment row `FOR UPDATE` (or an equivalently strong serialization point), re-check that it is non-terminal, then change the mapping set in the same transaction.

Assessment verification/rejection already serializes on the assessment row. Therefore mapping mutation and terminal transition cannot race into a state where verification observes a partially changed mapping set.

Once the assessment becomes `verified` or `rejected`, mappings are immutable.

Post-verification mapping correction is deferred until there is evidence that it needs a dedicated append-only correction workflow.

---

## 8. Immutable Learning Evidence Atoms

When a VLE is processed, Phase 5 materializes immutable evidence atoms rather than repeatedly interpreting mutable UI/draft state.

Conceptual table:

```text
public.learning_evidence_events
```

Proposed fields:

- `id uuid primary key`
- `family_id uuid not null`
- `child_id uuid not null`
- `verified_learning_event_id uuid not null`
- `assessment_id uuid not null`
- `learning_node_id uuid not null`
- `catalog_version text not null`
- `node_type text not null`
- `subject_key text not null`
- `grade_level_snapshot integer null`
- `assessment_type text not null`
- `difficulty text not null`
- `score_source text not null`
- `performance_pct numeric(5,2) not null`
- `specificity_weight numeric not null`
- `level_weight numeric not null`
- `occurred_at timestamptz not null`
- `verified_at timestamptz not null`
- `mapping_id uuid null`
- `created_at timestamptz not null`

A uniqueness contract must prevent retry from duplicating one logical evidence atom, for example an appropriate equivalent of:

```text
unique (verified_learning_event_id, learning_node_id, score_source, mapping_id)
```

with the automatic Subject fallback represented by a stable non-null logical source discriminator or equivalent uniqueness design.

### 8.1 Automatic subject evidence

Every processed VLE creates exactly one subject-root evidence atom:

```text
performance_pct = normalized_score * 10
```

### 8.2 Optional richer evidence

Each frozen detailed mapping creates one additional evidence atom at the mapped Domain/Topic/Skill using its supported score source.

### 8.3 No automatic propagation

Evidence updates only the node whose granularity is supported. It does not automatically copy itself to ancestors, descendants or sibling skills.

Roll-up summaries are separate coverage-aware read models.

### 8.4 Verification weight

Phase 5 v0.1 authoritative evidence is verified-only, therefore:

```text
verification_weight = 1.00
```

Lower-trust pre-verification weighting remains a future hypothesis and must not create a parallel authoritative mastery state.

### 8.5 Grade provenance

Every evidence atom preserves the immutable `grade_level_snapshot` captured at assessment/VLE creation. Historical evidence grade is never rewritten from the child's current profile grade.

---

## 9. Mastery Engine v0.1

### 9.1 Scale and initialization

Mastery is represented internally on `0..100`.

First credible observation:

```text
M_1 = P_1
```

The learner does not start from zero merely because LearnWard has no prior data.

### 9.2 Subsequent observations

```text
M_new = M_old + alpha_effective * (P - M_old)
```

with:

```text
alpha_base = 0.35
```

### 9.3 Specificity weights

| Node type | Weight |
|---|---:|
| Subject | 0.35 |
| Domain | 0.50 |
| Topic | 0.75 |
| Skill | 1.00 |

### 9.4 Level weights

Difficulty is not a mastery bonus.

```text
normal      -> 1.00
hard        -> 1.00
challenge   -> 1.00
below_level -> 0.50
```

Hard/challenge work receives no arbitrary mastery multiplier. Below-level evidence remains useful but has less influence on later updates.

### 9.5 Effective alpha

```text
alpha_effective
= 0.35
* specificity_weight
* level_weight
```

The calculation components are included in the audit revision snapshot.

### 9.6 Bands

| State | Rule |
|---|---|
| Unseen | no effective evidence |
| Emerging | score < 50 |
| Developing | 50 <= score < 70 |
| Secure | 70 <= score < 85 |
| Mastery candidate | score >= 85 but declaration conditions not met |
| Mastered | score >= 85 AND High confidence AND at least two recent distinct verified assessments |

Child-facing UI should favor bands and explanation over false precision.

---

## 10. Canonical Evidence Ordering & Late Evidence

EWMA is order-sensitive, so network/request arrival order is not an academic chronology.

For one child + node, evidence is ordered by:

```text
occurred_at ASC,
verified_at ASC,
learning_evidence_event.id ASC
```

The immutable evidence UUID is the final tie-breaker for exact timestamp equality.

Whenever new effective evidence is committed for a node, the server rebuilds that node's current mastery projection from the **complete immutable evidence set in canonical order**.

```text
same immutable evidence set
=> same canonical order
=> same mastery projection
```

This remains true when an older school result is logged/verified after a newer one.

Full per-node rebuild is intentionally correctness-first for pilot volume. Future checkpoint optimization must prove canonical equivalence.

---

## 11. Mastery Audit & Current Projection

### 11.1 Append-only revisions

Conceptual table:

```text
public.mastery_state_revisions
```

Proposed fields:

- `id uuid primary key`
- `family_id uuid not null`
- `child_id uuid not null`
- `learning_node_id uuid not null`
- `trigger_verified_learning_event_id uuid not null`
- `engine_version text not null` = `mastery-v0.1`
- `previous_mastery_score numeric null`
- `new_mastery_score numeric not null`
- `effective_evidence_count integer not null`
- `latest_evidence_at timestamptz not null`
- `calculation_snapshot jsonb not null`
- `created_at timestamptz not null`

The snapshot contains deterministic calculation inputs/order and alpha components without copying evidence media.

Revisions are immutable and append-only.

### 11.2 Current projection

Conceptual table:

```text
public.child_mastery_states
```

Suggested primary key:

```text
(child_id, learning_node_id)
```

plus composite family integrity.

Fields include:

- `family_id`
- `child_id`
- `learning_node_id`
- `engine_version`
- `mastery_score`
- `effective_evidence_count`
- `distinct_assessment_count`
- `last_evidence_event_id`
- `last_evidence_occurred_at`
- `last_verified_at`
- `latest_revision_id`
- `updated_at`

This is a server-controlled cache/projection, not historical source truth. Direct client mutation is revoked.

---

## 12. Confidence v0.1

Confidence answers: *How much recent, sufficiently specific verified evidence supports this estimate?*

It is derived at read time from evidence with:

```text
occurred_at >= now() - interval '60 days'
```

For verified-only v0.1 evidence:

```text
confidence_units = specificity_weight * level_weight
```

| Units | Confidence |
|---:|---|
| < 1.5 | Low |
| 1.5 through 3.5 | Medium |
| > 3.5 | High, only if >=2 distinct recent VLEs |

If units exceed 3.5 but only one VLE contributed, confidence remains Medium.

Phase 5 v0.1 does not invent a statistical variance model. A read model may expose a qualitative `recent_results_vary` explanation flag when recent observations materially disagree.

---

## 13. Freshness v0.1

Freshness is derived from latest credible academic `occurred_at`:

| Elapsed time | Freshness |
|---:|---|
| <= 14 days | Recent |
| >14 and <=45 days | Aging |
| >45 days | Needs refresh |

Time passing does not mutate the mastery score.

```text
Mastered + time passes
=> Mastered · Needs refresh
```

No scheduled freshness mutation job is required.

---

## 14. Recovery Signal v0.1

Phase 5 v0.1 supports only:

```text
none
review_suggested
```

For Topic/Skill, `review_suggested` is triggered by the latest credible component/item-group evidence when:

```text
performance_pct < 70
```

and either:

```text
item_count >= 3 AND incorrect_count >= 2
```

or, when item counts are unavailable but a component score exists:

```text
performance_pct <= 50
```

Subject-total evidence alone does not create a Skill recovery signal.

A later credible observation for the same node clears the signal when `performance_pct >= 70`.

Reserved future states such as `recovery_active` and `recovery_verified` are not implemented until LearnWard has a real persisted challenge-execution lifecycle.

---

## 15. Subject & Topic Presentation

Do not present a universal naive subject average such as `Math mastery = 73.42%`.

Subject presentation should combine:

- recent verified trend,
- direct subject-root state,
- tracked Topic counts,
- distribution of observed Topic states,
- needs-refresh count,
- evidence coverage.

A Topic may summarize observed descendant Skills only when coverage is shown, for example:

```text
Linear Equations
Secure
Evidence coverage: 3 of 4 tracked skills
```

Missing skills are unknown, not zero.

Direct node evidence and descendant roll-up summaries remain distinct and one never overwrites the other.

---

## 16. Read Models / Query Functions

Suggested server-authoritative read functions:

```text
get_child_learning_overview(child_id)
get_node_learning_state(child_id, learning_node_id)
get_next_challenge_candidates(child_id, subject_key?, limit default 3)
```

Read functions:

- validate IDs,
- authenticate,
- load child and derive family from database state,
- authorize active adult or exact paired child device,
- read current projections/immutable evidence,
- derive confidence/freshness/recovery interpretation,
- return explanation/coverage,
- perform no economy mutation.

Caller-supplied family IDs are never authoritative.

---

## 17. Trusted Server Processing Contract

Suggested trusted command:

```text
process_learning_event(
  p_verified_event_id uuid,
  p_command_id uuid
)
```

### 17.1 Ordering

```text
validate IDs
-> authenticate
-> load VLE and derive authoritative family/child
-> authorize active family adult
-> inspect and validate command receipt replay
-> serialize logical processing for this VLE
-> if already completed, return committed result
-> load frozen assessment mappings
-> materialize subject fallback + supported detailed evidence atoms
-> determine affected learning_node IDs
-> sort affected node IDs ASC
-> for each node in sorted order:
     acquire a transaction-scoped child+node serialization lock that works even when no projection row exists
-> after all required child+node locks are acquired:
     for each affected node in sorted order:
       read the complete immutable evidence set in canonical chronology
       run Mastery Engine v0.1
       append mastery_state_revision
       upsert child_mastery_states projection
-> append immutable learning_processing_event
-> insert command_receipt
-> return processing result
```

The per `(child_id, learning_node_id)` lock may be implemented with a transaction-scoped PostgreSQL advisory lock derived collision-safely from the pair, or an equivalently safe create-then-row-lock protocol. The implementation must prove that **the first-ever concurrent write to a node is serialized**, not merely later updates after a projection row already exists.

The rebuild evidence SELECT occurs **after** acquiring the child+node serialization lock. Under PostgreSQL READ COMMITTED, a transaction that waited for the lock then sees the prior transaction's committed evidence on its subsequent SELECT, allowing deterministic convergence.

### 17.2 Exactly-once logical processing

Conceptual table:

```text
public.learning_processing_events
```

with unique logical processing by `verified_learning_event_id`.

Retrying a VLE must not duplicate evidence atoms or economic-independent mastery effects.

### 17.3 Command receipt operation

Implementation may extend command receipt operation constraints with an explicit operation such as `process_learning`. Exact naming is frozen during implementation review and must remain backward-compatible with existing operations.

### 17.4 Delivery recovery

Provide the Phase-3-equivalent recovery mechanism, for example:

```text
get_unprocessed_learning_events(family_id)
catch_up_unprocessed_learning(family_id)
```

or an equivalent server-authoritative path. A lost client response after assessment verification must not permanently leave mastery unprocessed.

---

## 18. Concurrency Contract

### 18.1 Same VLE processed twice

Two concurrent calls for the same VLE produce one logical processing event and one logical evidence set. Retry/replay returns the committed result.

### 18.2 Different VLEs affecting the same child/node

This is the critical convergence case.

Implementation must acquire a transaction-scoped serialization lock for `(child_id, learning_node_id)` **before** reading the evidence set used for rebuild. The lock mechanism must work even if `child_mastery_states` has no row yet.

Affected node locks are acquired in deterministic `learning_node_id ASC` order to reduce deadlock risk.

After a waiter obtains the lock, its canonical evidence SELECT occurs in a new READ COMMITTED statement snapshot and therefore includes evidence committed by the previous holder.

Final state requirement:

```text
same committed evidence set
=> same canonical mastery projection
```

regardless of which VLE request entered first.

### 18.3 Different children

Different children proceed independently. No global mastery-table lock is justified.

### 18.4 Mapping vs verification

Mapping mutation and assessment terminal transition serialize on the assessment row. Exactly one stable mapping set is observed by verification and later learning processing.

---

## 19. Grade Semantics

Phase 5 uses **two deliberately different grade concepts**.

### 19.1 Evidence grade provenance

`learning_evidence_events.grade_level_snapshot` comes from the immutable assessment/VLE grade snapshot. It answers:

> At what known grade context did this historical evidence occur?

It never changes when the child's profile grade later changes.

### 19.2 Recommendation grade context

Unlock/Explore recommendations concern what is appropriate **now**, so grade-scoped candidate filtering uses current:

```text
child_profiles.school_grade
```

If current grade is `NULL`, grade-specific Unlock/Explore fails closed. The engine does not infer current grade from old evidence.

Broad mastery display and non-grade-specific Recovery/Developing/Refresh logic may still function when current grade is unknown.

---

## 20. Next Challenge Engine v0.1

Maximum child-facing candidates:

```text
3
```

Priority:

```text
A. Recovery
B. Developing
C. Refresh
D. Unlock
E. Exploration
```

### Recovery

Eligible when a Topic/Skill has `review_suggested`. Prefer the most recent meaningful recovery signal.

### Developing

Eligible when:

```text
50 <= mastery_score < 85
```

with no higher-priority Recovery candidate.

### Refresh

Eligible when:

```text
mastery_score >= 70
AND freshness = Needs refresh
```

### Unlock

A dependent Skill may be recommended only when all explicit prerequisite Skills are `Mastered` and current grade is compatible when the node is grade-scoped.

Unknown current grade fails closed for grade-specific Unlock.

### Exploration

May offer an unseen nearby Skill when no urgent recovery exists, prerequisite conditions are satisfied, and current grade is compatible for grade-scoped nodes.

Unknown current grade fails closed for grade-specific Explore.

### Recommended difficulty heuristic

```text
< 50        -> corrective / easier
50..69      -> normal practice
70..89      -> normal or hard
>= 90       -> harder / next-skill when confidence supports it
```

This is a product heuristic, not a validated pedagogical law.

### Deterministic tie-breaks

Within one priority class use explicit stable ordering such as:

1. recovery urgency/freshness class,
2. relevant evidence recency,
3. lower mastery for Developing,
4. graph `sort_order`,
5. node ID final tie-breaker.

Dart and database/read-model implementations must share canonical fixtures for this comparator.

---

## 21. Recommendation Persistence & Explanation

Recommendation results are read-time projections, not authoritative persisted learning state, because freshness, evidence and graph eligibility change over time.

If product analytics later records recommendation exposure/selection, those analytics remain separate and never feed mastery.

Every candidate includes a reason code, for example:

```text
recovery_recent_errors
developing_keep_practicing
refresh_stale_secure_skill
unlock_prerequisites_mastered
explore_available_skill
```

The UI must be able to answer *Why is LearnWard suggesting this?* without opaque model scores.

---

## 22. Security & RLS Contract

Private child learning data includes:

- assessment mappings,
- learning evidence events,
- mastery revisions,
- current mastery state,
- learning processing events.

Authorization:

- active family adult may read learning state for children in that family,
- paired child device may read only its exact child,
- sibling paired devices are denied,
- direct client mutation of authoritative evidence/mastery history/projection tables is revoked.

Global taxonomy/prerequisite data contains no child PII and is client read-only.

Trusted public Phase 5 functions follow repository hardening:

- `SECURITY DEFINER`,
- `SET search_path = ''`,
- fully qualified objects,
- exact signature grants,
- execution revoked from `PUBLIC`/`anon`,
- explicit authorization before private replay/result data is returned.

Shared Child Mode under an adult session remains UX containment, not a cryptographic sibling boundary.

---

## 23. Offline & Client Behavior

Offline assessment draft capture remains unchanged.

The client must not display locally predicted mastery as authoritative before server processing.

Optional local mapping drafts, if later needed, are non-authoritative until accepted server-side and frozen with verification.

A temporary post-verification state such as `Updating learning progress...` is acceptable.

---

## 24. Domain / Application Types

Suggested pure Dart domain types:

```text
LearningNode
LearningNodeType
LearningEvidence
MasteryObservation
MasteryState
MasteryBand
MasteryConfidence
MasteryFreshness
RecoverySignal
MasteryEngine
NextChallengeCandidate
NextChallengeReason
RecommendedDifficulty
```

Suggested application ports/use cases:

```text
LearningRepository
SetAssessmentLearningMappings
ProcessLearningEvent
GetChildLearningOverview
GetNodeLearningState
GetNextChallengeCandidates
CatchUpUnprocessedLearning
```

Domain code imports neither Flutter, Supabase, Drift nor reward repositories.

---

## 25. UI Contract

Child view emphasizes understandable state and choice:

```text
Mathematics

Linear Equations       Secure
Fractions              Developing
Geometry               Needs refresh

What do you want to tackle next?
[Fix recent fraction mistakes]
[Try another linear equations challenge]
[Refresh geometry]
```

Parent view may expose more diagnostic detail:

```text
Fractions
Mastery estimate: 64
Confidence: Medium
Freshness: Recent
Evidence: 3 verified results
Latest signal: Review suggested
```

Avoid fake precision, punitive language and sibling comparison.

---

## 26. Determinism & Parity Requirements

Create canonical fixtures for:

- first observation initialization,
- Subject/Domain/Topic/Skill specificity,
- below-level weighting,
- chronological updates,
- exact timestamp tie-breaks,
- delayed older evidence arriving after newer evidence,
- two concurrent first-ever updates to the same child/node,
- confidence thresholds and distinct-VLE rule,
- freshness boundaries,
- recovery signal/clear,
- Mastered declaration,
- recommendation priority/tie-breaks,
- unknown current grade filtering,
- reward/economy invariance.

Required invariant:

```text
Pure Dart canonical result == PostgreSQL integration/read-model canonical result
```

for the same academic inputs.

---

## 27. Required Database / Integration Tests

At minimum implementation must prove:

1. cross-family learning-state read denied,
2. paired child A cannot read child B,
3. direct client writes to evidence/revisions/projections denied,
4. taxonomy/prerequisites cannot be client-mutated,
5. explicit Subject mapping is rejected/unsupported because Subject fallback is automatic,
6. whole-assessment score cannot create Skill evidence,
7. subject fallback exists without detailed mapping,
8. mapping mutation cannot race verification into partial state,
9. duplicate VLE processing is idempotent,
10. concurrent same-VLE processing produces one logical result,
11. concurrent different VLEs on a previously unseen same child/node converge correctly,
12. late older evidence rebuilds to canonical result,
13. exact timestamp ties use immutable evidence ID,
14. missing current grade blocks grade-scoped Unlock/Explore without fabricating grade,
15. historic evidence retains immutable grade snapshot after profile grade changes,
16. reward/economy changes do not change mastery/recommendation output,
17. catch-up processes interrupted/unprocessed VLEs,
18. append-only audit/history mutation is rejected.

---

## 28. Domain / Application / Flutter Tests

### Domain

Table-driven tests for EWMA, initialization, specificity, level weighting, bands, confidence, freshness, recovery, canonical sorting and recommendation ranking.

### Application

Test mapping validation, retry, missing-mapping subject fallback, catch-up, repository boundaries, and absence of reward-repository dependency.

### Flutter

At minimum cover:

- Unseen/Low confidence,
- Developing/Secure/Mastered,
- Needs refresh without score decay,
- recovery suggestion copy,
- up to three choices,
- no-candidate state,
- processing-pending state,
- coverage display,
- paired-child sibling isolation through navigation,
- accessibility semantics/font scaling.

---

## 29. Observability / Metrics

Potential events:

```text
learning_event_processed
mastery_projection_updated
recovery_signal_created
recovery_signal_cleared
next_challenge_viewed
next_challenge_selected
```

Generic analytics payloads must not include raw evidence media or unnecessary child academic detail.

Relevant product metrics include VLPE/active child/week and self-chosen challenge rate. Recovery-completion metrics wait until a real recovery execution lifecycle exists.

---

## 30. Migration Plan for Implementation Phase

This design PR creates **no migration**.

After approval, Phase 5 implementation is additive. Frozen Phase 1–4 migration files are never rewritten.

Expected semantic database areas:

```text
learning_nodes
learning_prerequisites
assessment_learning_mappings
learning_evidence_events
mastery_state_revisions
child_mastery_states
learning_processing_events
Phase 5 RPCs / RLS / grants / triggers / indexes
```

Exact physical names may be refined during implementation review without changing the frozen semantic boundaries.

---

## 31. Explicit Deferred Scope

Deferred beyond Phase 5 v0.1:

- full curriculum coverage,
- family-authored authoritative skill graphs,
- automatic AI/OCR authoritative classification,
- Bayesian/IRT mastery models,
- forgetting-curve score decay,
- calibrated source-diversity confidence,
- post-verification mapping correction workflow,
- teacher/school organizations,
- full Recovery Quest execution,
- in-app learning content generation,
- recommendation reinforcement learning,
- sibling/peer benchmarks.

---

## 32. Exit Gates

### Phase 5.1

> The same committed verified evidence set always produces the same current mastery projection regardless of request arrival order; first-write concurrency is safe; subject-level progress works without detailed mappings; detailed claims never exceed evidence granularity.

### Phase 5.2

> Confidence, freshness and recovery interpretations are explainable/deterministic, and the child receives at most three useful next-challenge candidates without reward/economy signals affecting academic ranking.

### Overall Phase 5 freeze

Phase 5 may be frozen only after:

- design/ADR approval,
- additive migration review,
- domain/database parity green,
- RLS/adversarial tests green,
- late-evidence and first-write concurrency tests green,
- reward-independence tests green,
- Android/iOS CI green,
- independent implementation review passes,
- post-merge CI succeeds,
- freeze receipt matches actual code.
