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

## Decision 3 — Platform-Owned Versioned Knowledge Hierarchy & Authoritative Catalog Provenance

Phase 5 introduces a curated reference hierarchy:

```text
Subject -> Domain -> Topic -> Skill
```

with stable IDs, explicit `catalog_version`, optional grade ranges, and an active flag.

The graph is platform-owned and read-only to clients in v0.1. Families do not create arbitrary authoritative curriculum nodes during Phase 5.

A full national curriculum is not required. The pilot starts with a small curated graph.

### Catalog-version provenance & lifecycle
To guarantee deterministic processing across time and platform updates:
- **Legacy migration policy & immutability preservation (DDL-safe bootstrap):** When the Phase 5 migration runs, all existing assessments and `verified_learning_events` that predate catalog-version provenance are deterministically assigned the initial frozen catalog version: `pilot-v0.1`. Crucially, this is accomplished via additive DDL (`ADD COLUMN ... DEFAULT 'pilot-v0.1' NOT NULL`) without executing row-level `UPDATE` statements or disabling/weakening frozen Phase 2 immutability triggers (`LW103` preventing verified/rejected assessment modification and `LW102` preventing VLE modification).
- **Catalog registry source of truth & atomic promotion:** A dedicated catalog version registry (`learning_catalog_versions`) tracks version identifiers, lifecycle state (`draft | active | retired`), activation timestamp, and creation timestamp. Promoting a new catalog version to `active` automatically retires the previous active version in the same atomic transaction, ensuring exactly ONE version has `status = 'active'` at commit time.
- **Server-controlled active version:** When an assessment is created, the server snapshots the active platform catalog version into `assessments.learning_catalog_version`. The client/caller cannot select or override this version. If no valid active catalog version exists at assessment creation, the server fails closed (`LW501_NO_ACTIVE_CATALOG`).
- **Complete pilot catalog bootstrap:** The initial `pilot-v0.1` catalog MUST contain exactly one Subject root node for every frozen canonical subject key (`math`, `english`, `literature`, `science`, `other`). Missing subject roots would cause unmapped VLE fallback processing to fail closed.
- **Verification snapshot:** Upon adult verification, that version snapshot is copied directly into `verified_learning_events.learning_catalog_version`.
- **Processing isolation:** Immediate learning processing, delayed processing, and bulk catch-up use the VLE's immutable snapshot version exclusively. Catch-up never infers historical catalog version from the currently active platform catalog.
- **Published version immutability:** Published, active, and retired catalog versions are completely immutable. Node definitions, titles, parent links, grade spans, and node availability (`is_active = true`) must never be modified or deactivated in place within an existing version. Deactivations and semantic changes require publishing a new catalog version.
- **Cross-version recommendation semantics & scoped authoring:** Historical evidence and mastery remain permanently attached to their original catalog nodes and version. The recommendation engine evaluates candidates against the current active catalog. Phase 5 v0.1 does not perform automatic cross-version mastery migration; cross-version transfer requires a future explicit crosswalk policy. Furthermore, an assessment authored under `pilot-v0.1` that is in `pending_review` when `pilot-v0.2` becomes active remains fully map-able and verifiable against `pilot-v0.1` via catalog version-scoped reads.

### Graph & mapping integrity
- **Subject root uniqueness:** Exactly one Subject root exists per `(catalog_version, subject_key)`, with `node_type = 'subject'` and `parent_id IS NULL`. Enforced via unique constraint/index: `unique (catalog_version, subject_key) where parent_id is null`.
- **Hierarchy subject integrity:** For every parent/child edge (`Domain -> Subject`, `Topic -> Domain`, `Skill -> Topic`), child and parent must have identical `catalog_version` AND `subject_key`. Cross-subject or cross-version edges are rejected.
- **Prerequisite graph cross-version & cross-subject integrity:** `learning_prerequisites` requires both prerequisite and dependent nodes to be Skill nodes belonging to the exact SAME `catalog_version` and the exact SAME `subject_key`. Cross-subject and cross-version edges are strictly forbidden. Traversal in recommendations filters strictly by `catalog_version = current_active_catalog_version`.
- **Mapping integrity:** `assessment_learning_mappings.learning_node_id` must point to a node whose `catalog_version == assessment.learning_catalog_version` and `subject_key == assessment.subject_key`. Mappings must never cross subjects.

**Consequence:** Curriculum scope is bounded, evidence references stable learning identities, and delayed catch-up resolves to the exact catalog version under which the assessment was authored.

---

## Decision 4 — Evidence Granularity Caps Mastery Granularity & Effective Observation Invariant

Every VLE creates broad subject-root evidence automatically.

Richer direct evidence is optional and requires explicit mapping.

Allowed detailed mapping targets are Domain, Topic, and Skill. Subject mapping is unnecessary because subject fallback is automatic.

A whole-assessment total may support Domain/Topic only when explicitly classified by an adult. A whole-assessment total may **not** become Skill evidence.

Skill evidence requires a supported component score or item group.

No evidence is automatically propagated to every ancestor, descendant, or sibling node.

### Effective observation invariant
At most **one** effective mastery observation exists per:

```text
(verified_learning_event_id, learning_node_id)
```

Subject fallback naturally produces one Subject-root observation. For detailed nodes, multiple mappings/components for the same node must be deterministically aggregated into one effective observation prior to EWMA evaluation. One assessment must never feed multiple sequential EWMA steps into the same node.

**Consequence:** LearnWard never claims more diagnostic detail than the source evidence supports, and one assessment cannot overweight a node or bias EWMA ordering.

---

## Decision 5 — Detailed Mappings Are Authoritative in `pending_review` Only, RPC-Controlled & Deterministically Aggregated

Detailed assessment-to-learning mappings are optional.

### Mapping lifecycle vs mutable drafts
- In Phase 2, `update_assessment_draft` allows editing `subject_key`, assessment type, difficulty, score, and dates while status is `draft`.
- Allowing authoritative mappings on drafts risks corrupt or dangling mappings when draft attributes change.
- Therefore, authoritative `assessment_learning_mappings` may be created or replaced **ONLY when `assessment.status = 'pending_review'`**.
- Direct client `INSERT`, `UPDATE`, and `DELETE` on `assessment_learning_mappings` are revoked.
- An active family adult manages authoritative mappings exclusively through a trusted mapping RPC. Paired child identities cannot author mappings.
- The mapping RPC locks the assessment row `FOR UPDATE`, verifies `status = 'pending_review'`, validates subject/catalog consistency, and replaces the mapping set atomically.
- Assessment verification/rejection locks the same assessment row `FOR UPDATE`, ensuring mapping mutations and terminal transitions serialize deterministically.
- Once the assessment becomes `verified` or `rejected`, mappings are immutable.
- Missing mappings never block assessment verification.

### Component identity & non-overlapping authoring
Each detailed mapping requires a stable component identity:

```text
component_key text not null
```

Within one `(assessment_id, learning_node_id)`, duplicate `component_key` values are strictly rejected via unique constraint `unique (assessment_id, learning_node_id, component_key)`. For `assessment_total`, a reserved component key (`'assessment_total'`) enforces that a whole-assessment score is never mapped more than once to the same node. If parent authoring cannot prove components/item groups are non-overlapping, they must be represented as one aggregate mapping.

### Deterministic aggregation
When multiple mappings target the same `learning_node_id` on one assessment:
- **`component_score`**: aggregated by score mass:
  ```text
  performance_pct = (sum(component_raw_score) / sum(component_max_score)) * 100
  ```
- **`item_group`**: aggregated by item and correct counts:
  ```text
  item_count = sum(item_count)
  correct_count = sum(correct_count)
  performance_pct = (sum(correct_count) / sum(item_count)) * 100
  ```
- **Mixed source types fail-closed:** Mixing different `score_source` types (`assessment_total`, `component_score`, `item_group`) on the same node for one assessment is strictly forbidden.
- **Confidence:** Confidence units count the single effective observation once (`confidence_units = specificity_weight * level_weight`), preventing artificial confidence inflation from split mappings.

**Consequence:** Subject-level learning state works with low parent burden; detailed skill state is available when supported; draft editing never desynchronizes mappings; aggregation is deterministic and independent of mapping insertion order.

---

## Decision 6 — Immutable Learning Evidence Atoms Preserve Diagnostic Facts

Processing a VLE materializes immutable `learning_evidence_events` containing the academic facts needed by the Learning Engine:

- source VLE/assessment,
- child/family,
- learning node,
- catalog version,
- node type and subject key,
- grade snapshot,
- assessment type/difficulty,
- score source,
- 0–100 observed performance,
- specificity/level weights,
- immutable diagnostic facts: nullable `item_count` and `correct_count` (with derived `incorrect_count = item_count - correct_count`),
- raw `occurred_at` and `effective_occurred_at`,
- verification timestamp.

Evidence rows are append-only and directly non-mutable by clients.

Uniqueness enforces the effective observation contract:

```text
unique (verified_learning_event_id, learning_node_id)
```

Diagnostic counts are validated (`item_count > 0`, `0 <= correct_count <= item_count`) and populated for `item_group` (summed if aggregated); they are `NULL` for `component_score` and `assessment_total`.

**Consequence:** Mastery and recovery can be evaluated deterministically from immutable evidence without rereading mutable UI/draft state or media.

---

## Decision 7 — Mastery Engine v0.1 Uses Explainable EWMA with Option A Initialization

The internal mastery estimate uses `0..100`.

### First credible observation (Option A)
```text
M_1 = P_1
```

First credible evidence initializes the estimate directly to observed performance `P_1`.

Level and specificity weights govern update influence (`alpha_effective`) on subsequent observations, not the initial score. As a deliberate pilot hypothesis: if first evidence is below-level with 100% score, initial mastery estimate is 100, but confidence units remain constrained (`confidence_units = 1.00 * 0.50 = 0.50 < 1.5` -> Low confidence), preventing `Mastered` declaration until declaration conditions (High confidence and >= 2 distinct recent verified assessments) are met.

### Subsequent observations
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

**Consequence:** The model is deterministic, inspectable, conservative, and calibratable during pilots without premature mastery declaration.

---

## Decision 8 — Effective Chronology + Full Node Rebuild Eliminates Arrival-Order Bias and Future Skew

To prevent future timestamps from falsely granting permanent recency or bypassing confidence windows, the server derives an immutable effective timestamp:

```text
effective_occurred_at = least(occurred_at, verified_at)
```

(with fail-safe `least(..., as_of)` in read contexts). Raw `occurred_at` is preserved for audit provenance.

Mastery evidence for one child/node is ordered by:

```text
effective_occurred_at ASC,
verified_at ASC,
verified_learning_event_id ASC
```

Using the immutable source `verified_learning_event_id` as the final tie-breaker (rather than a runtime processing-generated evidence UUID) guarantees that the canonical sequence is 100% deterministic and invariant to processing execution or insertion order.

When new evidence appears, the current projection is rebuilt from the complete immutable evidence sequence in this order.

The engine does not append blindly according to request arrival.

For concurrent processing, implementation must serialize each affected `(child_id, learning_node_id)` before reading the rebuild evidence set. The synchronization mechanism must also work when the projection row does not yet exist; an implementation may use a transaction-scoped advisory lock derived from the child/node pair or an equivalently safe create-then-row-lock protocol.

Affected node locks must be acquired in deterministic node-ID order.

**Consequence:** The same evidence set converges to the same mastery state even when an older assessment is verified later, two VLEs are processed concurrently, or device clocks skew into the future.

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

## Decision 10 — Confidence v0.1 in Phase 5.1 & Freshness Interpretation with Explicit Time Context

### Scope alignment: Confidence v0.1 belongs to Phase 5.1
Because the final `Mastered` band requires `Confidence = High`, Confidence v0.1 is included in Phase 5.1 alongside the Mastery Engine. Freshness, Recovery signal, and Next Challenge recommendations remain in Phase 5.2.

### Time determinism & single `as_of` clock
Confidence, freshness, recovery recency, and next-challenge ranking depend on current time. To prevent boundary divergence across query layers and ensure exact Dart/PostgreSQL parity:
- Every server-authoritative learning read captures ONE `as_of timestamptz` at request start (`v_as_of := transaction_timestamp();`).
- The client does not supply or choose the authoritative `as_of`. The response may include `as_of` for explanation and UI audit.
- Pure Dart domain engines accept an explicit `DateTime asOf` parameter; direct calls to `DateTime.now()` are forbidden inside deterministic calculation logic.

### Confidence (Phase 5.1)
Derived at read time from effective evidence with strict lower and upper bounds:

```text
effective_occurred_at >= as_of - interval '60 days'
AND effective_occurred_at <= as_of
```

For verified-only v0.1 evidence:

```text
confidence_units = specificity_weight * level_weight
```

Bands:

```text
< 1.5          Low
1.5 .. 3.5     Medium
> 3.5          High, only with >= 2 distinct recent verified assessments
```

Confidence units count each effective VLE/node observation once. Splitting an assessment across multiple mappings never increases confidence.

### Freshness (Phase 5.2)
Based on elapsed time from the latest credible academic `effective_occurred_at` relative to `as_of`:

```text
elapsed = as_of - latest_effective_occurred_at

<= 14 days          Recent (elapsed <= 14 days)
> 14 and <= 45 days Aging (14 days < elapsed <= 45 days)
> 45 days           Needs refresh (elapsed > 45 days)
```

No negative elapsed time can occur. Time passing does not mutate or silently decay the mastery score.

**Consequence:** No scheduled job is required merely to age labels, historic achievement is preserved, and parity between database functions and Dart is provably exact.

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

A high score with sparse evidence remains `Mastery candidate` rather than `Mastered`. Because Confidence v0.1 is delivered in Phase 5.1, the `Mastered` band is legitimately evaluable and valid in Phase 5.1.

**Consequence:** One 10/10 worksheet cannot instantly declare durable mastery.

---

## Decision 12 — Phase 5 Recovery Is a Deterministic Signal with 30-Day Recency Window

Phase 5 v0.1 supports:

```text
none
review_suggested
```

The recovery signal is evaluated at read time for Topic and Skill nodes using immutable diagnostic facts preserved on evidence atoms:

### Raise rules (Topic/Skill only)
- **`item_group` observation:** raised when:
  ```text
  performance_pct < 70
  AND item_count >= 3
  AND incorrect_count >= 2
  ```
- **`component_score` observation:** raised when:
  ```text
  performance_pct <= 50
  ```
- **Forbidden sources:** `assessment_total` and Subject fallback MUST NOT raise Skill or Topic recovery.

### Recency and expiry contract
A `review_suggested` signal is eligible only if the latest unresolved recovery-triggering observation is within **30 days** of `as_of`:

```text
as_of - effective_occurred_at <= interval '30 days'
```

If older than 30 days without newer confirming weakness, the recovery signal decays to `none`. This does not mutate historical evidence, but prevents stale errors from indefinitely hijacking top-priority recommendations.

### Clear rule
An existing `review_suggested` signal on a node is cleared immediately when a later credible effective observation for the SAME node achieves:

```text
performance_pct >= 70
```

Allowed clearing sources are `component_score` and `item_group`. Broad `assessment_total` cannot clear a Skill recovery signal because it lacks matching granularity.

The states `recovery_active` and `recovery_verified` remain reserved until LearnWard has a real persisted learning-challenge execution lifecycle.

**Consequence:** The product highlights actionable recent mistakes without faking an interactive quest system or allowing year-old errors to permanently block progress.

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

Recommendations are generated from current academic state, graph prerequisites, current-grade compatibility and freshness relative to `as_of`. Reward/economy data is excluded.

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

## Decision 16 — Trusted Processing Is Idempotent, Command-Bound and Recoverable

Phase 5 implementation introduces an explicit trusted processing operation for verified learning events:

```text
command_receipts.operation = process_learning
resource_id = verified_learning_event_id
```

### Authorization, locking & post-lock recheck ordering
1. Authenticate caller.
2. Load VLE and derive family and child from server database state.
3. Authorize active family adult (paired children cannot trigger manual processing).
4. Inspect command receipt replay.
5. Acquire per-VLE serialization lock.
6. **Post-lock recheck:** In a fresh statement snapshot inside the lock, re-read both `command_receipts` and `learning_processing_events`.
   - If the same command was committed by a racing caller, return the committed result cleanly.
   - If the VLE was committed under a different command, bind the new command receipt and return the committed result without duplicate processing.
   - If unprocessed, proceed with evidence materialization and projection rebuild.

### Idempotency, replay result snapshot & command receipt semantics
- **Immutable replay result snapshot:** `learning_processing_events` preserves an immutable processing result summary (`id`, `verified_learning_event_id UNIQUE`, `assessment_id`, `child_id`, `family_id`, `processed_at`, `evidence_count`, `affected_node_ids`, `status = 'processed'`).
- **Same command replay:** If the same `command_id` is replayed with identical `actor_user_id`, `operation = 'process_learning'`, `family_id`, and `resource_id = verified_learning_event_id`, return the committed processing result snapshot directly from `learning_processing_events`. The result is NEVER recomputed from mutable `child_mastery_states`, ensuring that subsequent VLEs for the child do not alter the historical command response. Any mismatch on actor, family, operation, or resource is rejected.
- **Same VLE, new command ID:** If the target VLE has already completed logical processing (`learning_processing_events`), a new command ID binds and records a valid command receipt for that command with `resource_id = verified_learning_event_id` and returns the committed processing result snapshot. It creates NO new evidence and NO new revisions.
- **Reused command ID, different VLE:** Strictly rejected.
- **Logical uniqueness:** `learning_processing_events` enforces `unique(verified_learning_event_id)`.

### Bulk catch-up contract
`catch_up_unprocessed_learning(family_id)` requires explicit caller authentication and authorization: the caller must be an active family adult in that family. Paired child calls and cross-family calls are denied (`42501` / `LW002`). It discovers VLEs lacking `learning_processing_events`. For each discovered VLE, it invokes an internal trusted processing routine whose idempotency is anchored directly by `unique(verified_learning_event_id)`. It does not invent synthetic public command IDs. If catch-up audit is needed, it uses an independent batch run identifier.

**Consequence:** Lost responses or network failures replay cleanly, concurrent calls with identical command IDs return clean replays without primary-key collisions, and bulk catch-up never bypasses or corrupts command receipt semantics.

---

## Decision 17 — Security Model Reuses Existing Family/Paired-Child Boundary

Private learning state obeys the existing authorization contract:

- active adult: family-scoped child reads,
- paired child: exact child only,
- sibling paired device: denied,
- shared Child Mode under adult auth: UX containment only, not sibling cryptographic isolation.

Reference curriculum data is global/read-only and contains no child PII. Direct client mutations on `learning_nodes`, `learning_catalog_versions`, `learning_prerequisites`, and `assessment_learning_mappings` are revoked.

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

1. **Catalog provenance, registry & hierarchy integrity:**
   - legacy assessments and VLEs predating catalog version provenance are deterministically assigned `pilot-v0.1` via additive DDL (`DEFAULT 'pilot-v0.1' NOT NULL`) without row updates or disabling frozen Phase 2 immutability triggers (`LW102`, `LW103`);
   - `pilot-v0.1` contains exactly one Subject root node for every canonical subject key (`math`, `english`, `literature`, `science`, `other`);
   - catalog version registry enforces exactly one active catalog version at a time via atomic promotion transactions;
   - new assessment creation fails closed if no active catalog exists (`LW501_NO_ACTIVE_CATALOG`);
   - caller cannot choose or override catalog version;
   - published catalog versions are completely immutable (no in-place deactivations or mutations) and client writes are denied;
   - `pending_review` assessments remain map-able to their authored catalog version even after a newer version is activated;
   - delayed catch-up after catalog rollout preserves original VLE catalog version;
   - exactly one Subject root exists per `(catalog_version, subject_key)`;
   - duplicate Subject root is rejected;
   - cross-subject or cross-version hierarchy parent edges are rejected;
   - `learning_prerequisites` enforces composite FKs to same `catalog_version` and strict same-`subject_key` constraint (cross-subject and cross-version edges rejected);
   - mapping to a node with mismatched subject or catalog version is rejected;
   - recommendations evaluate against active catalog without silent cross-version mastery transfer.
2. **Mapping lifecycle & direct-mutation security:**
   - authoritative mappings permitted ONLY when `assessment.status = 'pending_review'`;
   - draft assessment editing freely updates subject/score without desynchronizing mappings;
   - cannot map while in `draft` status; cannot map after `verified` or `rejected`;
   - direct client `INSERT`, `UPDATE`, and `DELETE` on `assessment_learning_mappings` are denied;
   - paired child cannot set or replace mappings;
   - cross-family mapping attempt is denied;
   - mapping mutation racing verification produces either complete mapping set before verify or verification wins and mapping fails closed.
3. **Observation aggregation & single-observation invariant:**
   - at most one effective mastery observation per `(verified_learning_event_id, learning_node_id)`;
   - duplicate same-node component mapping identity (`component_key`) is rejected;
   - `assessment_total` mapping cannot be duplicated on the same node;
   - multiple component mappings aggregate deterministically by score mass;
   - multiple item groups aggregate deterministically by item/correct counts;
   - mixed score source types on the same node fail closed;
   - aggregation result is invariant to mapping insertion order;
   - confidence counts each effective observation once without inflation from split mappings.
4. **Effective chronology & future timestamp bounds:**
   - server derives `effective_occurred_at = least(occurred_at, verified_at)`;
   - canonical chronology orders by `effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC`;
   - confidence requires `effective_occurred_at >= as_of - interval '60 days' AND effective_occurred_at <= as_of`;
   - future raw timestamps cannot extend confidence window indefinitely;
   - future raw timestamps cannot dominate freshness or recommendation recency;
   - freshness elapsed time cannot be negative.
5. **Recovery diagnostic provenance & 30-day recency:**
   - immutable diagnostic facts (`item_count`, `correct_count`) are preserved on evidence atoms;
   - item-group weakness raises `review_suggested` when `performance_pct < 70 AND item_count >= 3 AND incorrect_count >= 2`;
   - component-score weakness raises `review_suggested` when `performance_pct <= 50`;
   - broad `assessment_total` and Subject fallback never raise or clear Skill recovery;
   - recovery signal expires to `none` when latest unresolved weak observation is older than 30 days from `as_of`;
   - subsequent observation with `performance_pct >= 70` clears recovery immediately.
6. **Time determinism & boundary parity:**
   - single server-authoritative `as_of` timestamp captured at request start;
   - pure Dart domain engines accept explicit `DateTime asOf` parameter;
   - exact boundary fixtures (14 days, 30 days, 45 days, 60 days) yield identical outputs in Dart and PostgreSQL.
7. **Idempotency, post-lock recheck & catch-up contract:**
   - same command and same VLE replay returns committed result snapshot directly from immutable `learning_processing_events` without recomputing from mutable `child_mastery_states`, proving replay invariance after subsequent VLEs mutate current projection;
   - concurrent same-command calls serialize on VLE lock, recheck receipts, and return clean replays without primary-key collisions;
   - new command ID targeting an already-processed VLE binds a new command receipt and returns committed result without duplicating evidence or revisions;
   - reused command ID targeting a different VLE is denied;
   - `catch_up_unprocessed_learning(family_id)` requires active family adult authorization; paired child and cross-family calls are denied; repeated catch-up calls are safe no-ops;
   - concurrent manual processing and catch-up converge safely;
   - concurrent catch-up workers converge without race conditions;
   - exactly one logical processing event and effective evidence set per VLE.
8. **First-observation initialization:**
   - first observation initializes `M_1 = P_1` (Option A);
   - below-level 100% initializes score to 100 while confidence remains constrained (<1.5 Low), preventing premature `Mastered` declaration.
9. **Concurrency & rebuild determinism:**
   - first-write and subsequent projection rebuilds execute under transaction-scoped child+node serialization locks;
   - late-arriving older evidence rebuilds to identical canonical mastery projection.
10. **Audit & security integrity:**
   - direct client mutation denied for `learning_prerequisites`, `learning_catalog_versions`, and published `learning_nodes`;
   - append-only mutation rejection on `learning_processing_events`, `learning_evidence_events`, and `mastery_state_revisions`;
   - direct projection mutation denied;
   - cross-family process/read denied;
   - paired-child sibling isolation verified;
   - reward-independence invariance tests prove no XP/RP/reward input affects mastery or recommendations.
11. **Build & review gates:**
   - Android debug build and iOS simulator compile succeed in CI;
   - independent review passes and post-merge CI on `main` succeeds.
