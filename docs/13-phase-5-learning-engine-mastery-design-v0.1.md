# Phase 5 Detailed Design — Learning Engine, Mastery & Recommendation v0.1

**Status:** PROPOSED — DESIGN ONLY  
**Document Version:** `v0.1.0`  
**Date:** 2026-11-02  
**Target Milestone:** Phase 5 — Mastery Engine, Skill Trees & Recommendation Foundation  
**Design Base:** `5a3c7c75fd0f7c691ee8cd974b51b9cb165a4c2c`  
**No Phase 5 migration/runtime code is authorized by this document alone.**

---

## 1. Product Objective

Phase 5 turns verified academic evidence into an explainable, persistent learning state that helps a child understand:

1. what they are getting better at,
2. what is still developing,
3. what may need a refresh,
4. where recent mistakes suggest recovery work,
5. what useful challenge they could choose next.

The learning loop becomes:

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

The Learning Engine is deliberately independent from the Reward Economy.

```text
Verified academic evidence
       |                  |
       v                  v
 Growth Engine       Learning Engine
       |                  |
    XP / RP          Mastery / Next Challenge
```

RP, XP, reward pricing, Wheel tier, redemption history, and reward balance are not valid Learning Engine inputs.

---

## 2. Phase 5 Non-Goals

Phase 5 does **not** build:

- a full Vietnamese national curriculum database,
- an AI teacher or AI tutor,
- auto-generated lessons,
- automatic OCR skill diagnosis,
- a homework marketplace,
- teacher/school multi-tenant administration,
- social or sibling academic leaderboards,
- reward-driven recommendation ranking,
- a punitive remediation system,
- high-stakes educational placement decisions,
- a black-box predictive model.

The pilot must work with a small curated knowledge graph and partial classification.

---

## 3. Constitutional Invariants

### 3.1 Verified academic evidence is authoritative

Authoritative mastery updates originate only from immutable `verified_learning_events` plus explicitly supported, verified learning mappings.

The following must not directly update mastery:

- local assessment drafts,
- pending-review assessments,
- photos that have not been verified,
- self-reported claims that never become verified learning events,
- XP/RP ledger rows,
- reward redemptions,
- Wheel spins,
- app engagement events.

### 3.2 Evidence granularity limits claims

A whole-assessment score can support broad learning-state claims, but must not be silently interpreted as detailed skill mastery.

Example:

```text
Math exam: 8/10
```

may support:

```text
Mathematics — recent verified performance evidence
```

and, if explicitly classified by an adult:

```text
Mathematics -> Algebra
```

but must not automatically claim:

```text
Fractions = 80
Linear Equations = 80
Geometry = 80
```

### 3.3 Missing metadata never blocks verified-result capture

Phase 2 verification remains valid even when no domain/topic/skill mapping exists.

Every verified learning event can still contribute at the canonical subject root.

### 3.4 Mastery, confidence and freshness remain separate

A single high score can produce a high early estimate with Low confidence.

Time passing may make evidence stale, but time alone does not erase historical achievement.

### 3.5 No sibling comparison

Mastery state, evidence and recommendations are scoped to one child. The engine never ranks siblings or uses sibling performance as a baseline.

### 3.6 Learner autonomy

The recommendation layer returns up to three candidate choices. It does not issue mandatory commands.

---

## 4. Phase Structure

### Phase 5.1 — Knowledge + Mastery Foundation

Deliver:

- versioned knowledge hierarchy,
- optional assessment learning mappings,
- immutable learning evidence atoms,
- deterministic Mastery Engine v0.1,
- append-only mastery projection revisions,
- current mastery projection,
- recoverable VLE processing,
- broad subject fallback,
- basic mastery/progress UI.

### Phase 5.2 — Skill Graph + Recommendation Foundation

Deliver:

- explicit prerequisite graph,
- dynamic confidence,
- dynamic freshness,
- deterministic recovery signal,
- next-challenge candidate generation,
- explanation/coverage UI,
- child choice surface.

Phase 5 is frozen only after both slices pass independent review and post-merge CI.

---

## 5. Canonical Knowledge Model

The hierarchy is:

```text
Subject
  -> Domain
      -> Topic
          -> Skill
```

### 5.1 Platform-owned reference nodes

Phase 5 v0.1 uses a **platform-owned curated reference catalog**, not family-authored curriculum structure.

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

Recommended constraints:

- stable unique `(catalog_version, canonical_key)`,
- parent and child must share the same `catalog_version`,
- parent/child hierarchy types must be valid:
  - subject -> domain,
  - domain -> topic,
  - topic -> skill,
- a subject node has no parent,
- `grade_min <= grade_max` when both exist,
- `subject_key` remains aligned with the frozen canonical values.

### 5.2 Catalog versioning

Pilot graph version begins as a small explicit version such as:

```text
pilot-v0.1
```

Do not mutate the meaning of an existing node ID after evidence has referenced it.

If curriculum semantics change materially, create a new catalog version or new node IDs with an explicit migration/mapping policy.

### 5.3 Client permissions

Learning reference tables contain no child/family private data.

They are:

- readable by authenticated clients,
- not directly writable by clients,
- maintained through migrations/content releases,
- protected by explicit grants/RLS consistent with repository policy.

### 5.4 `subject_key = other`

The `other` subject root may receive broad verified evidence.

Phase 5 v0.1 does not attempt to create arbitrary family-authored skill graphs beneath `other`.

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

1. Both endpoints must be `skill` nodes.
2. Edges are explicit and curated.
3. Self-edges are forbidden.
4. Duplicate edges are forbidden.
5. The graph must be acyclic.
6. No ML/LLM-generated prerequisite edge becomes authoritative automatically.

Because clients cannot mutate the graph in v0.1, cycle validation can be enforced through content validation tests/scripts during migration/content review rather than expensive runtime graph mutation logic.

---

## 7. Assessment-to-Learning Mapping Contract

### 7.1 Mapping is optional

An assessment without detailed mappings still verifies normally and contributes subject-level evidence.

### 7.2 Mapping is confirmed before verification

Detailed authoritative mappings are attached to the assessment while it is still mutable and are frozen when the assessment becomes terminal.

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

### 7.3 Score-source rules

#### `assessment_total`

Uses the verified assessment total performance.

Allowed for:

- Subject
- Domain
- Topic

Not allowed for Skill.

This prevents a whole-test score from being relabeled as one precise skill measurement.

#### `component_score`

Uses an explicitly scored subcomponent:

```text
component_raw_score / component_max_score
```

May support Domain, Topic or Skill if the parent confirms that the component measures that node.

#### `item_group`

Uses a mapped group of assessment items:

```text
correct_count / item_count
```

Designed primarily for Topic/Skill evidence.

Validation requires:

```text
item_count > 0
0 <= correct_count <= item_count
```

### 7.4 Mapping authority in v0.1

Only an active family adult may create/replace authoritative detailed mappings.

A child may eventually suggest tags, but child suggestions are not authoritative mastery inputs until an adult confirms them.

### 7.5 Mapping mutation window

Mappings may be edited while the assessment remains non-terminal.

Once the assessment is `verified` or `rejected`, its authoritative mapping set is immutable.

A later correction workflow is intentionally deferred until there is evidence that post-verification mapping correction is common enough to justify an append-only revision model.

---

## 8. Immutable Learning Evidence Atoms

Mastery should not repeatedly reinterpret mutable assessment rows.

When a verified learning event is processed, Phase 5 materializes immutable evidence atoms.

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

Recommended uniqueness:

```text
unique (verified_learning_event_id, learning_node_id, score_source, mapping_id)
```

or an equivalent key that guarantees one logical evidence atom is not duplicated by retry.

### 8.1 Automatic subject evidence

Every processed VLE creates one subject-root evidence atom using the VLE's verified total score:

```text
performance_pct = normalized_score * 10
```

This requires no detailed mapping.

### 8.2 Optional richer evidence

Each frozen detailed mapping creates an additional evidence atom at the mapped node using the supported score source.

### 8.3 No automatic ancestor/descendant propagation

A skill evidence atom updates that skill's direct state only.

It does **not** automatically apply the same observation to:

- every ancestor,
- sibling skills,
- descendant skills.

Subject/topic summaries use explicit broad evidence plus coverage-aware aggregation/read models rather than duplicating one observation across the graph.

### 8.4 Verification weight in Phase 5 v0.1

The existing conceptual Learning Engine document lists lower weights for self-report/photo/unconfirmed evidence.

Phase 5 v0.1 deliberately narrows authoritative processing to verified learning events. Therefore:

```text
verification_weight = 1.00
```

for every authoritative Phase 5 mastery evidence atom.

Lower-trust pre-verification weighting is deferred; it must not create a second unofficial mastery state.

---

## 9. Mastery Engine v0.1

### 9.1 Scale

Mastery is represented internally on `0..100`.

### 9.2 First credible observation

The first evidence atom for a node initializes mastery to observed performance:

```text
M_1 = P_1
```

The learner does not start from zero merely because LearnWard has no prior data.

### 9.3 Subsequent observations

For every later canonical observation:

```text
M_new = M_old + alpha_effective * (P - M_old)
```

with:

```text
alpha_base = 0.35
```

### 9.4 Specificity weight

Frozen v0.1 starting values:

| Node type | Specificity weight |
|---|---:|
| Subject | 0.35 |
| Domain | 0.50 |
| Topic | 0.75 |
| Skill | 1.00 |

### 9.5 Difficulty / level diagnostic weight

Difficulty is not a mastery bonus.

For v0.1:

```text
normal      -> 1.00
hard        -> 1.00
challenge   -> 1.00
below_level -> 0.50
```

This prevents below-level work from dominating the estimate of current learning state while still preserving useful evidence.

Hard/challenge work does not receive an arbitrary mastery multiplier.

### 9.6 Effective alpha

Because Phase 5 authoritative evidence is verified-only:

```text
alpha_effective
= alpha_base
* specificity_weight
* level_weight
```

The calculation components must be captured in the mastery audit revision.

### 9.7 Mastery bands

| State | Rule |
|---|---|
| Unseen | no effective evidence |
| Emerging | score < 50 |
| Developing | 50 <= score < 70 |
| Secure | 70 <= score < 85 |
| Mastery candidate | score >= 85 but mastery declaration conditions not met |
| Mastered | score >= 85 AND High confidence AND at least two recent distinct verified assessments |

The child-facing UI should favor bands and explanation over false precision.

---

## 10. Canonical Evidence Ordering & Late Evidence

### 10.1 Why request order is invalid

EWMA is order-sensitive.

Example:

```text
Assessment A occurred Monday but verified Friday.
Assessment B occurred Thursday and verified Thursday.
```

If processing simply follows network arrival, the final mastery estimate depends on operational timing rather than academic chronology.

### 10.2 Canonical order

For one child + learning node, effective evidence is ordered by:

```text
occurred_at ASC,
verified_at ASC,
learning_evidence_event.id ASC
```

The immutable UUID tie-breaker guarantees a total order when timestamps are identical.

### 10.3 Projection rebuild rule

When a new effective evidence atom is inserted for a node, the server recomputes that node's current mastery projection from the complete canonical evidence sequence.

It does **not** assume the new atom is chronologically last.

Therefore:

```text
same immutable evidence set
=> same ordered sequence
=> same mastery projection
```

regardless of request arrival order, retry timing, or delayed verification.

### 10.4 Pilot performance trade-off

Full per-node rebuild is chosen deliberately for v0.1 because evidence volume per child/node is small and correctness/explainability are more important than incremental optimization.

If production volume later justifies snapshots/checkpoints, optimization must preserve canonical equivalence.

---

## 11. Mastery Audit & Current Projection

### 11.1 Append-only mastery revisions

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

The snapshot should contain enough deterministic inputs to explain the result, including canonical evidence IDs/order and alpha components, without copying sensitive evidence media.

Revisions are append-only and immutable.

### 11.2 Current projection

Conceptual table:

```text
public.child_mastery_states
```

Proposed primary key:

```text
(child_id, learning_node_id)
```

with composite family integrity.

Fields:

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

This table is a cache/projection, not the historical source of truth.

Direct client mutation is revoked.

---

## 12. Confidence v0.1

Confidence answers:

> How much recent, sufficiently specific verified evidence supports this estimate?

It is derived from immutable evidence at read time rather than blindly accumulated forever.

### 12.1 Confidence window

Use evidence with:

```text
occurred_at >= now() - interval '60 days'
```

### 12.2 Evidence units

For Phase 5 verified-only evidence:

```text
confidence_units = specificity_weight * level_weight
```

### 12.3 Bands

| Units | Confidence |
|---:|---|
| < 1.5 | Low |
| 1.5 through 3.5 | Medium |
| > 3.5 | High, subject to distinct-event rule |

High confidence additionally requires at least **two distinct verified learning events** in the confidence window.

If units exceed 3.5 but only one VLE contributed, confidence remains Medium.

### 12.4 Conflicting evidence

Phase 5 v0.1 does not invent a statistical variance confidence model.

The read model may expose a `recent_results_vary` explanation flag when recent observations differ materially, but must not silently fabricate mathematical certainty.

Calibration is deferred to pilot evidence.

---

## 13. Freshness v0.1

Freshness is derived from the latest credible evidence `occurred_at` timestamp.

| Elapsed time | Freshness |
|---:|---|
| <= 14 days | Recent |
| >14 and <=45 days | Aging |
| >45 days | Needs refresh |

Important:

```text
Mastered + time passes
!= mastery score silently decays
```

Instead:

```text
Mastered · Needs refresh
```

The stored mastery estimate remains unchanged until new evidence arrives.

No scheduled freshness mutation job is required.

---

## 14. Recovery Signal v0.1

A full Recovery Quest lifecycle is not yet part of Phase 5 foundation.

Phase 5 implements a deterministic **recovery signal**:

```text
none
review_suggested
```

### 14.1 Trigger rule

For a Topic/Skill node, `review_suggested` when the latest credible component/item-group evidence meets both:

```text
performance_pct < 70
```

and either:

```text
item_count >= 3 AND incorrect_count >= 2
```

or, when item counts are unavailable but a component score is present:

```text
performance_pct <= 50
```

Subject-total evidence alone does not create a skill recovery signal.

### 14.2 Clearing rule

A later credible evidence event for the same node clears the signal when:

```text
performance_pct >= 70
```

The historical low-performance evidence remains immutable.

### 14.3 Future lifecycle

The following states remain reserved for a later challenge-execution feature:

```text
recovery_active
recovery_verified
```

Phase 5 v0.1 must not pretend they exist operationally before there is a real persisted recovery activity lifecycle.

---

## 15. Topic & Subject Presentation

### 15.1 Subject view

Do not show a universal naive average such as:

```text
Math mastery = 73.42%
```

Subject presentation should combine:

- recent verified assessment trend,
- direct subject evidence state,
- tracked topic counts,
- child-owned topic distribution,
- needs-refresh count,
- evidence coverage.

### 15.2 Topic summary

A topic may summarize only observed descendant skills and must show coverage.

Example:

```text
Linear Equations
Secure
Evidence coverage: 3 of 4 tracked skills
```

Missing skills are unknown, not zero.

### 15.3 Direct evidence vs aggregate summary

The UI must distinguish:

- direct evidence at a node,
- roll-up summary from observed descendants.

A roll-up must not overwrite the direct mastery projection for that node.

---

## 16. Read Models / Query Functions

Phase 5 should provide server-authoritative read functions rather than forcing the mobile client to reproduce learning logic independently.

Suggested functions:

```text
get_child_learning_overview(child_id)
get_node_learning_state(child_id, learning_node_id)
get_next_challenge_candidates(child_id, subject_key?, limit default 3)
```

Read functions:

- authenticate,
- derive family from the child,
- authorize active adult or exact paired child device,
- read current mastery projections and immutable evidence,
- derive confidence/freshness/recovery interpretation,
- return explanations/coverage,
- perform no economy mutation.

They do not accept caller-supplied family IDs as authority.

---

## 17. Server Processing Contract

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
-> load verified_learning_event and derive family/child
-> authorize active family adult
-> inspect command receipt replay
-> lock source VLE or equivalent processing serialization point
-> check whether VLE already has a completed learning processing event
-> load frozen assessment mappings
-> materialize subject fallback + supported detailed evidence atoms
-> identify affected learning nodes
-> for each affected node in deterministic node-id order:
     lock/create current projection row
     load complete effective evidence in canonical chronology
     run Mastery Engine v0.1
     append mastery_state_revision
     upsert child_mastery_states projection
-> append immutable learning_processing_event
-> insert command_receipt
-> return processing result
```

### 17.2 Exactly-once logical processing

Conceptual table:

```text
public.learning_processing_events
```

with unique:

```text
verified_learning_event_id
```

Retrying the same VLE must not duplicate evidence atoms or audit revisions.

### 17.3 Command receipt operation

Phase 5 implementation may extend the command operation constraint with an operation such as:

```text
process_learning
```

Exact naming is frozen during implementation review, but it must remain explicit and backward-compatible with existing operations.

### 17.4 Delivery recovery

Provide the Phase 3-equivalent recovery path:

```text
get_unprocessed_learning_events(family_id)
catch_up_unprocessed_learning(family_id)
```

or an equivalent server-authoritative mechanism.

Network interruption after assessment verification must not permanently leave mastery unprocessed.

---

## 18. Concurrency Contract

### 18.1 Same VLE processed twice

Two concurrent calls for the same VLE must produce:

```text
1 logical learning_processing_event
1 set of evidence atoms
1 current projection outcome per affected node
```

The losing/retry transaction returns the committed logical result.

### 18.2 Different VLEs affecting the same node

Transactions must lock affected mastery projection rows in deterministic `learning_node_id ASC` order to reduce deadlock risk.

Because each transaction rebuilds from the complete immutable evidence set under serialization, the final projection must converge to the canonical result regardless of which request entered first.

### 18.3 Different children

Different child projections should proceed independently without a global mastery table lock.

---

## 19. Next Challenge Engine v0.1

The recommendation engine generates candidates, not assignments.

Maximum child-facing candidates:

```text
3
```

### 19.1 Priority order

```text
A. Recovery
B. Developing
C. Refresh
D. Unlock next skill
E. Exploration
```

### 19.2 Candidate type A — Recovery

Eligible when a Topic/Skill has `review_suggested`.

Prefer the most recent meaningful recovery signal.

### 19.3 Candidate type B — Developing

Eligible when:

```text
50 <= mastery_score < 85
```

with no higher-priority recovery signal.

### 19.4 Candidate type C — Refresh

Eligible when:

```text
mastery_score >= 70
AND freshness = Needs refresh
```

### 19.5 Candidate type D — Unlock

A dependent skill may be recommended when all explicit prerequisite skills are:

```text
Mastered
```

For grade-scoped nodes, the child's immutable/relevant grade context must be known and compatible.

Unknown grade fails closed for grade-specific Unlock/Explore logic rather than guessing.

### 19.6 Candidate type E — Exploration

May offer an unseen nearby skill when:

- there is no urgent recovery candidate,
- prerequisite requirements are satisfied,
- grade filtering is compatible when the node is grade-scoped.

### 19.7 Recommended difficulty heuristic

Use the latest relevant performance, not reward configuration:

```text
< 50        -> corrective / easier
50..69      -> normal practice
70..89      -> normal or hard
>= 90       -> harder / next-skill when confidence supports it
```

This remains a product heuristic, not a validated pedagogical law.

### 19.8 Deterministic ranking tie-breaks

Within the same priority class, order by explicit deterministic fields, for example:

1. recovery urgency / freshness class,
2. most recent evidence time where applicable,
3. lower mastery for Developing,
4. configured graph `sort_order`,
5. node ID as final stable tie-breaker.

The exact comparator must be implemented identically in domain/database parity tests.

---

## 20. Recommendation Persistence Policy

Phase 5 v0.1 does **not** persist every recommendation result as authoritative state.

Candidates are read-time projections because:

- freshness changes with time,
- new evidence may arrive,
- graph/catalog availability may change,
- the child should receive current choices.

If future analytics need recommendation exposure/click events, record lightweight product analytics separately without making those events mastery inputs.

---

## 21. Recommendation Explanation Contract

Every candidate includes an explanation reason code and child-safe text source.

Suggested reason codes:

```text
recovery_recent_errors
developing_keep_practicing
refresh_stale_secure_skill
unlock_prerequisites_mastered
explore_available_skill
```

The UI should be able to answer:

> Why is LearnWard suggesting this?

without exposing opaque model scores.

---

## 22. Security & RLS Contract

### 22.1 Private child learning data

The following are family/child-private:

- assessment mappings,
- learning evidence events,
- mastery revisions,
- mastery current state,
- processing events.

RLS rules:

- active family adult may read child learning state in the family,
- paired child may read only their exact child state,
- sibling paired devices cannot read one another,
- direct client mutation of authoritative evidence/mastery tables is revoked.

### 22.2 Platform reference data

Learning nodes/prerequisites are global reference data with no family PII.

Clients receive read-only access to active catalog content.

### 22.3 Trusted functions

Public Phase 5 trusted functions must follow existing repository hardening:

- `SECURITY DEFINER`,
- `SET search_path = ''`,
- exact signature grants,
- revoke execution from `PUBLIC`/`anon`,
- fully qualified object names,
- authorize before returning private replay/result data.

---

## 23. Offline & Client Behavior

### 23.1 Verification remains the authority boundary

Offline draft capture can continue as today.

The client must not display locally predicted mastery as authoritative before server processing.

### 23.2 Optional mapping drafts

If mapping editing requires offline support later, mappings may be stored locally as non-authoritative draft UI data.

Only server-accepted mappings that are frozen with the verified assessment influence mastery.

### 23.3 Processing delay UI

After verification, a temporary state such as:

```text
Updating learning progress...
```

is acceptable.

Do not fabricate a mastery update locally while the authoritative server processing is unresolved.

---

## 24. Domain/API Types

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

Domain types must not import Flutter, Supabase, Drift or reward-economy repositories.

---

## 25. UI Contract

### Child learning overview

Should emphasize understandable progress:

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

Avoid fake precision and coercive copy.

### Parent view

Should expose enough explanation to trust the system:

```text
Fractions
Mastery estimate: 64
Confidence: Medium
Freshness: Recent
Evidence: 3 verified results
Latest signal: Review suggested
```

The parent view may show internal numeric mastery, but the child-facing default should emphasize bands/progress.

---

## 26. Determinism & Parity Requirements

Phase 5 is not complete if the Dart engine and PostgreSQL processing can disagree.

Create canonical fixtures that cover:

- first evidence initialization,
- subject/domain/topic/skill specificity weights,
- below-level diagnostic weight,
- multiple chronological updates,
- exact timestamp tie-breaks,
- delayed older evidence arriving after newer evidence,
- confidence thresholds,
- two-distinct-VLE High-confidence requirement,
- freshness boundaries,
- recovery signal/clear,
- mastery declaration,
- recommendation priority/tie-breaks.

Expected result:

```text
Pure Dart engine output == PostgreSQL integration output
```

for canonical scenarios.

---

## 27. Required Database Tests

At minimum Phase 5 implementation must test:

1. cross-family mastery read denied,
2. paired child A cannot read child B mastery,
3. child cannot directly insert/update/delete learning evidence,
4. child cannot directly mutate mastery projection/revisions,
5. global taxonomy cannot be client-mutated,
6. whole-assessment score cannot produce skill evidence,
7. subject fallback is created without detailed mappings,
8. duplicate processing command is idempotent,
9. concurrent same-VLE processing produces one logical result,
10. late older evidence rebuilds to canonical result,
11. exact timestamp tie uses immutable ID tie-breaker,
12. missing grade does not fabricate grade-specific unlock,
13. reward/economy changes do not change mastery output,
14. catch-up processes interrupted/unprocessed VLEs,
15. append-only audit/history triggers reject mutation.

---

## 28. Required Domain/Application Tests

### Domain

Table-driven tests for:

- EWMA calculation,
- initialization,
- specificity weights,
- below-level weighting,
- mastery bands,
- confidence units,
- freshness,
- recovery signal,
- recommendation ranking,
- deterministic canonical sorting.

### Application

Use-case tests for:

- mapping validation,
- processing/retry,
- missing mapping subject fallback,
- recovery/catch-up,
- read model authorization assumptions at port boundaries,
- no dependency on reward repository.

---

## 29. Required Flutter Tests

At minimum:

- Unseen / Low-confidence state,
- Developing / Secure / Mastered presentation,
- Needs-refresh label without mastery-score decay,
- recovery suggestion copy,
- up to three recommendation choices,
- no recommendation available state,
- processing-pending state,
- coverage display,
- child cannot see sibling state through paired-child navigation,
- accessibility semantics/font scaling for mastery indicators.

---

## 30. Observability / Metrics Alignment

Phase 5 enables the intended North Star definition because a verified academic event can now contribute to progress/mastery state.

Authoritative/product events may include:

```text
learning_event_processed
mastery_projection_updated
recovery_signal_created
recovery_signal_cleared
next_challenge_viewed
next_challenge_selected
```

Do not put raw assessment evidence, image content, or sensitive child academic details into generic analytics payloads.

Relevant product metrics:

- VLPE / active child / week,
- recovery completion later when real recovery lifecycle exists,
- self-chosen challenge rate,
- interest in progress after reward novelty declines.

---

## 31. Migration Plan for Implementation Phase

This design PR creates **no migration**.

After approval, Phase 5.1 implementation should add a new migration rather than edit frozen Phase 1–4 files.

Expected additive database areas:

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

Exact names may be refined during implementation review, but the semantic boundaries above are design invariants.

---

## 32. Explicit Deferred Scope

Deferred beyond Phase 5 v0.1:

- full national curriculum coverage,
- family-created custom skill graphs,
- automatic AI/OCR authoritative classification,
- probabilistic/Bayesian mastery modeling,
- calibrated item difficulty / IRT,
- source-diversity confidence weighting,
- forgetting-curve mastery decay,
- teacher organization accounts,
- full Recovery Quest execution lifecycle,
- in-app lesson/content generation,
- recommendation reinforcement learning,
- sibling/peer benchmarks.

---

## 33. Phase 5 Exit Gates

### Phase 5.1 Exit Gate

> The same set of verified learning evidence always produces the same current mastery state regardless of request arrival order; subject-level progress works without detailed mappings; detailed skill claims never exceed evidence granularity.

### Phase 5.2 Exit Gate

> Confidence, freshness and recovery interpretations are explainable and deterministic, and the child can receive up to three useful next-challenge candidates without any reward/economy signal affecting academic recommendation ranking.

### Overall Phase 5 Freeze Gate

Phase 5 may be frozen only after:

- design/ADR approved,
- all additive migrations reviewed,
- domain/database parity green,
- RLS/adversarial tests green,
- concurrency/late-evidence tests green,
- Android/iOS CI green,
- independent implementation review passes,
- post-merge CI succeeds,
- freeze receipt accurately reflects actual code.
