# Phase 5 Detailed Design — Learning Engine, Mastery & Recommendation v0.1

**Status:** PROPOSED — DESIGN ONLY  
**Document Version:** `v0.1.2`  
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

### 3.7 Authoritative catalog-version provenance

Every verified learning event must belong to an immutable, server-snapshotted catalog version. Delayed processing or platform catalog upgrades must never cause an immutable historical event to resolve to a different catalog version or Subject root. Legacy records are backfilled via additive DDL (`DEFAULT 'pilot-v0.1' NOT NULL` then `DROP DEFAULT`) without row updates or disabling frozen Phase 2 triggers (`LW102`, `LW103`). Steady-state assessment creation snapshots the active catalog version via `BEFORE INSERT` trigger ignoring caller input; VLE creation copies assessment snapshot via `BEFORE INSERT` trigger. `pilot-v0.1` contains Subject roots for all canonical subjects (`math`, `english`, `literature`, `science`, `other`). Catalog authoring and promotion is strictly a platform-level deployment concern; family adults are tenant admins, not curriculum admins, and promotion execution is revoked from `PUBLIC`, `anon`, and `authenticated`. Published catalog content is completely immutable; registry lifecycle metadata transitions strictly `draft -> active -> retired` through a trusted promotion procedure that guarantees exactly one active catalog before commit (raising SQLSTATE `LW501` if missing).

### 3.8 Single effective observation per VLE/node

At most one effective mastery observation may exist per `(verified_learning_event_id, learning_node_id)`. Multiple mappings for the same node must aggregate deterministically into one effective observation before feeding EWMA, and confidence counts the effective observation once. One assessment must never feed multiple sequential EWMA updates into the same node.

### 3.9 Time determinism via server `as_of` context

Read-time derivations (60-day confidence window, 14d/45d freshness, recovery recency, next-challenge ranking) evaluate against a single server-authoritative `as_of` timestamp captured once at request start. Pure Dart engines accept an explicit `DateTime asOf` parameter.

### 3.10 Diagnostic fact preservation

Downstream recovery signals must be driven by immutable diagnostic facts (`item_count`, `correct_count`, and derived `incorrect_count`) preserved directly on the evidence atom, not re-inferred from raw media or unverified drafts.

### 3.11 Pending-review-only mapping lifecycle

Authoritative assessment-to-learning mappings may be created or modified only while an assessment is in `pending_review` status. Draft assessments remain freely editable without risking dangling or corrupted mappings.

### 3.12 Effective chronological ordering

Chronological and recency calculations use an immutable effective timestamp `effective_occurred_at = least(occurred_at, verified_at)` to eliminate client clock skew into the future. Canonical evidence order uses `effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC`, anchoring tie-breaks to the immutable source VLE rather than a runtime generated UUID.

---

## 4. Phase Structure

### Phase 5.1 — Knowledge + Mastery Foundation

Deliver:

- catalog version registry (`learning_catalog_versions`),
- deterministic legacy catalog migration (`pilot-v0.1`),
- versioned learning hierarchy (`learning_nodes`),
- prerequisite skill graph schema & catalog publication validation (`learning_prerequisites` with composite version+subject FKs, Skill-only and DAG promotion gate; empty prerequisite graph is valid in 5.1),
- assessment learning mappings (`pending_review` only),
- immutable learning evidence atoms with diagnostic facts (`item_count`, `correct_count`),
- deterministic Mastery Engine v0.1 (EWMA, Option A initialization),
- **Confidence v0.1** (rolling 60-day window, confidence units, distinct-VLE rule),
- **Mastery bands including final `Mastered`**,
- append-only mastery revisions (`mastery_state_revisions`),
- current mastery projection (`child_mastery_states`),
- exactly-once/recoverable VLE processing with post-lock receipt recheck,
- automatic subject fallback,
- basic parent/child mastery presentation.

### Phase 5.2 — Skill Graph + Recommendation Foundation

Deliver:

- prerequisite graph traversal for Unlock/Explore candidate selection,
- dynamic Freshness (14d/45d boundaries relative to `as_of`),
- deterministic Recovery signal (`review_suggested` with 30-day recency/expiry window),
- next-challenge candidate engine (up to three candidates),
- explanation/coverage presentation,
- child choice UI.

Phase 5 is frozen only after both slices pass independent implementation review and green post-merge CI.

---

## 5. Canonical Knowledge Model

The hierarchy is:

```text
Subject -> Domain -> Topic -> Skill
```

### 5.1 Platform-owned reference nodes & Catalog Registry

Conceptual tables:

```sql
CREATE TABLE public.learning_catalog_versions (
  version text primary key,
  status text not null check (status in ('draft', 'active', 'retired')),
  activated_at timestamptz null,
  created_at timestamptz not null default clock_timestamp()
);

CREATE UNIQUE INDEX uq_learning_catalog_versions_single_active 
  ON public.learning_catalog_versions (status) 
  WHERE status = 'active';
```

Atomic promotion contract & lifecycle metadata:
- Exactly ONE version has `status = 'active'` at any time.
- Catalog authoring and promotion is strictly a **platform administration / deployment concern**, NOT an application tenant capability. Family adults, shared-child sessions, and paired-child identities have zero catalog administration privileges. Family membership is irrelevant to global curriculum administration.
- Draft catalogs and their content (`draft learning_catalog_versions`, `learning_nodes`, `learning_prerequisites`) are platform-owned and authored solely via migrations, controlled seed/content-release tooling, or privileged platform administrative paths. Direct client writes (`INSERT`, `UPDATE`, `DELETE`) remain revoked from all client roles (`anon`, `authenticated`, `public`).
- Generic DML on `learning_catalog_versions` is revoked from `service_role` (which receives `SELECT` only); direct `INSERT`, `UPDATE`, or `DELETE` on `learning_catalog_versions` by `service_role` strictly fails with `42501` (permission denied).
- Draft creation occurs exclusively through `public.create_learning_catalog_draft(p_version text)` with `SECURITY DEFINER` (granted only to `service_role`), and catalog promotion occurs solely via `public.promote_learning_catalog_version(p_new_version text)` with `SECURITY DEFINER` (granted only to `service_role`).
- Ambient caller-settable GUCs (e.g. `learnward.in_catalog_promotion` or `learnward.bootstrap`) are strictly eliminated and never used as authorization tokens. The migration bootstraps `pilot-v0.1` as `draft` and invokes `public.promote_learning_catalog_version('pilot-v0.1')` within the migration transaction itself.
- Registry lifecycle metadata transitions strictly `draft -> active -> retired` through the trusted promotion procedure; `retired` is terminal.
- Promoting a `draft` version to `active` executes a trusted serialized promotion routine (`promote_learning_catalog_version(p_new_version text)`):
  ```sql
  REVOKE EXECUTE ON FUNCTION public.promote_learning_catalog_version(text) FROM PUBLIC;
  REVOKE EXECUTE ON FUNCTION public.promote_learning_catalog_version(text) FROM anon;
  REVOKE EXECUTE ON FUNCTION public.promote_learning_catalog_version(text) FROM authenticated;
  GRANT EXECUTE ON FUNCTION public.promote_learning_catalog_version(text) TO service_role;
  ```
  Only trusted platform/service-role execution or release migrations may invoke it. Execution is explicitly granted to `service_role` while revoked from `PUBLIC`, `anon`, and `authenticated`.
  When executed, the trusted promotion routine:
  1. Serializes promotion attempts via coordination locking (e.g. advisory or table lock on `learning_catalog_versions`);
  2. Locks and validates that `p_new_version` exists and has `status = 'draft'` before retiring the current active catalog;
  3. Validates the candidate catalog is publishable (all five canonical Subject roots exist, valid hierarchy edges, and valid Skill-only acyclic DAG prerequisite graph);
  4. Retires the previous active version (`status = 'retired'`) and activates the candidate (`status = 'active'`, `activated_at = clock_timestamp()`) atomically;
  5. Asserts that exactly one active catalog exists before commit:
     ```sql
     IF (SELECT count(*) FROM public.learning_catalog_versions WHERE status = 'active') <> 1 THEN
       RAISE EXCEPTION USING ERRCODE = 'LW501', MESSAGE = 'No active learning catalog';
     END IF;
     ```
     Any failure raises an exception and rolls back the entire transaction.
- If no active version is configured or valid when a new assessment is created, the server fails closed with SQLSTATE `LW501` (message 'No active learning catalog', application reason code `LW501_NO_ACTIVE_CATALOG`).
- Direct client writes (`INSERT`, `UPDATE`, `DELETE`) on `learning_catalog_versions` are revoked.

```sql
CREATE TABLE public.learning_nodes (
  id uuid primary key default gen_random_uuid(),
  catalog_version text not null references public.learning_catalog_versions(version),
  node_type text not null check (node_type in ('subject', 'domain', 'topic', 'skill')),
  subject_key text not null,
  canonical_key text not null,
  title text not null,
  parent_id uuid null references public.learning_nodes(id),
  grade_min integer null,
  grade_max integer null,
  sort_order integer not null,
  is_active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  CONSTRAINT uq_learning_nodes_version_id UNIQUE (catalog_version, id),
  CONSTRAINT uq_learning_nodes_version_subject_id UNIQUE (catalog_version, subject_key, id),
  CONSTRAINT uq_learning_nodes_version_key UNIQUE (catalog_version, canonical_key)
);
```

Required invariants:

- **Complete pilot catalog bootstrap:** The initial `pilot-v0.1` catalog MUST contain exactly one Subject root node for every frozen canonical subject key (`math`, `english`, `literature`, `science`, `other`). Missing subject roots would cause unmapped VLE fallback processing to fail closed.
- **Subject root uniqueness:** Exactly one Subject root per `(catalog_version, subject_key)`. Subject root has `node_type = 'subject'` and `parent_id IS NULL`. Enforced via unique partial index:
  ```sql
  CREATE UNIQUE INDEX uq_learning_nodes_subject_root 
    ON public.learning_nodes (catalog_version, subject_key) 
    WHERE parent_id IS NULL;
  ```
  Duplicate Subject roots within the same catalog version and subject are strictly rejected.
- **Hierarchy subject integrity:** For every parent/child edge:
  - `Domain -> parent Subject`
  - `Topic -> parent Domain`
  - `Skill -> parent Topic`
  child and parent MUST have identical `catalog_version` AND `subject_key`. Cross-subject and cross-version parent edges are strictly rejected.
- **Valid type edges only:** Subject→Domain, Domain→Topic, Topic→Skill.
- **Subject has no parent:** `parent_id IS NULL` if and only if `node_type = 'subject'`.
- **Grade range validity:** `grade_min <= grade_max` when both exist.
- **Subject key validity:** `subject_key` matches the frozen canonical subject values.
- **Published version immutability:** Published catalog versions (`active` and `retired`) are completely immutable. All nodes in published versions have `is_active = true`. In-place updates, deactivations (`is_active = false`), and reparenting are strictly forbidden and rejected. Semantic or availability changes require publishing a new catalog version.

### 5.2 Catalog versioning, Lifecycle & Authoritative Provenance

Pilot catalog begins with an explicit frozen version: `pilot-v0.1`.

#### Legacy migration policy, DDL-safe bootstrap & write-path integration
When the Phase 5 migration is installed:
1. Seed `pilot-v0.1` registry record and required roots/graph.
2. Add columns with `DEFAULT 'pilot-v0.1' NOT NULL` to populate all existing assessments and `verified_learning_events` instantaneously without executing row-level `UPDATE` statements or firing frozen Phase 2 immutability triggers (`LW103` preventing verified/rejected assessment modification and `LW102` preventing VLE modification).
3. Execute `ALTER TABLE ... ALTER COLUMN learning_catalog_version DROP DEFAULT` on both `assessments` and `verified_learning_events` so subsequent writes cannot silently rely on a static default.
4. Install `BEFORE INSERT` trigger on `assessments` to derive `NEW.learning_catalog_version := (SELECT version FROM public.learning_catalog_versions WHERE status = 'active')`. If NULL, raise SQLSTATE `LW501` ('No active learning catalog'). Caller input is ignored and overwritten.
5. Install `BEFORE INSERT` trigger on `verified_learning_events` to derive `NEW.learning_catalog_version := (SELECT learning_catalog_version FROM public.assessments WHERE id = NEW.assessment_id)`. Version is copied directly from assessment provenance snapshot, never from current active catalog and never from a static default.

#### Academic flow for catalog provenance:
1. **Assessment creation:** The server snapshots the active platform learning catalog version from `learning_catalog_versions` into `assessments.learning_catalog_version` via trigger. The client/caller cannot select or override this version. If no active catalog version is configured or valid when a new assessment is created, the server fails closed with SQLSTATE `LW501` (message 'No active learning catalog', application reason code `LW501_NO_ACTIVE_CATALOG`).
2. **Adult verification:** The immutable catalog version snapshot is copied directly into `verified_learning_events.learning_catalog_version` via trigger.
3. **Learning processing:** Immediate processing, delayed processing, and bulk catch-up use `verified_learning_events.learning_catalog_version` exclusively. Catch-up never infers historical catalog version from the currently active platform catalog.

#### Published version immutability:
Published, active, and retired catalog versions are completely immutable:
- Node definitions, titles, parent links, grade spans, and node availability (`is_active = true`) must never be modified or deactivated in place within an existing version.
- Semantic changes require publishing a new catalog version.

#### Cross-version recommendation semantics & scoped authoring:
- Historical evidence and mastery remain permanently attached to their original catalog nodes and version.
- The recommendation engine evaluates candidates against the current active catalog.
- Phase 5 v0.1 does not perform automatic cross-version mastery migration; cross-version transfer requires a future explicit crosswalk policy.
- Furthermore, an assessment authored under `pilot-v0.1` that is in `pending_review` when `pilot-v0.2` becomes active remains fully map-able and verifiable against `pilot-v0.1` via catalog version-scoped reads. Reading the catalog for mapping authoring queries by `assessment.learning_catalog_version`, preventing old-version pending assessments from being stranded.

### 5.3 Client permissions

Reference nodes and catalog version records contain no child/family private data. Authenticated clients may read active catalog data; direct client writes (`INSERT`, `UPDATE`, `DELETE`) are revoked on `learning_catalog_versions` and `learning_nodes`. Catalog changes occur through migrations/content releases.

### 5.4 `subject_key = other`

`other` may receive broad subject evidence. Phase 5 v0.1 does not create arbitrary family-authored authoritative skill graphs beneath it.

---

## 6. Explicit Skill Prerequisite Graph

Conceptual table:

```sql
CREATE TABLE public.learning_prerequisites (
  id uuid primary key default gen_random_uuid(),
  catalog_version text not null,
  subject_key text not null,
  prerequisite_node_id uuid not null,
  dependent_node_id uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  CONSTRAINT uq_learning_prerequisites_pair UNIQUE (catalog_version, prerequisite_node_id, dependent_node_id),
  CONSTRAINT chk_learning_prerequisites_no_self CHECK (prerequisite_node_id <> dependent_node_id),
  FOREIGN KEY (catalog_version, subject_key, prerequisite_node_id) 
    REFERENCES public.learning_nodes(catalog_version, subject_key, id) ON DELETE CASCADE,
  FOREIGN KEY (catalog_version, subject_key, dependent_node_id) 
    REFERENCES public.learning_nodes(catalog_version, subject_key, id) ON DELETE CASCADE
);
```

Integrity and traversal rules:

1. **Both endpoints are Skill nodes:** prerequisite and dependent must have `node_type = 'skill'`.
2. **Matching catalog version:** both endpoints MUST belong to the row's `catalog_version` (enforced via composite foreign keys).
3. **Strict same-subject integrity:** both endpoints MUST belong to the exact same `subject_key`. Cross-subject prerequisites are strictly forbidden in v0.1 (enforced via catalog validation check or composite FK).
4. **Active catalog recommendation traversal:** candidate search in the recommendation engine traverses edges exclusively where `catalog_version = current_active_catalog_version`.
5. **Acyclic graph (DAG):** self-edges and circular dependency cycles are forbidden (validated upon catalog authoring/release).
6. **No synthetic ML edges:** edges are curated and explicit.
7. **Direct client mutation revoked:** direct client writes (`INSERT`, `UPDATE`, `DELETE`) are denied via RLS.

Because clients cannot mutate this graph in v0.1, DAG validation may run as migration/content validation rather than an expensive public runtime mutation path.

### Delivery alignment across Phase 5 slices
The schema for `learning_prerequisites`, its composite foreign keys, and the promotion gate validating Skill-only endpoints and acyclic DAG invariants belong to **Phase 5.1**. This ensures that `promote_learning_catalog_version` and the published catalog immutability contract are fully grounded from Day 1. The initial `pilot-v0.1` catalog may contain an empty prerequisite graph; an empty graph is explicitly valid and DAG validation treats empty as valid. Prerequisite graph traversal for Unlock/Explore candidate selection is consumed in **Phase 5.2**.

---

## 7. Assessment-to-Learning Mapping Contract

### 7.1 Mapping lifecycle vs mutable assessment drafts

An assessment without detailed mappings still verifies and contributes subject-root evidence.

#### Authoritative mappings allowed ONLY in `pending_review`
- In Phase 2, `update_assessment_draft` permits changing `subject_key`, assessment type, difficulty, score, and dates while status is `draft`.
- Allowing authoritative learning mappings on drafts creates grave integrity risks (e.g. changing subject in draft leaves dangling cross-subject mappings).
- Therefore, authoritative `assessment_learning_mappings` may be created or replaced **ONLY when `assessment.status = 'pending_review'`**.
- While an assessment is in `draft` status, mapping calls are rejected.
- Once an assessment is in `verified` or `rejected` status, mappings are immutable and further mapping changes are rejected.

#### Direct table mutations denied
Direct client `INSERT`, `UPDATE`, and `DELETE` on `assessment_learning_mappings` are revoked. Authoritative mappings may be mutated solely through a trusted server RPC. Paired child identities cannot author mappings.

#### Concurrency and verification serialization
The trusted mapping mutation RPC:
1. Authenticates caller.
2. Locks the target assessment row `FOR UPDATE`.
3. Derives family identity and verifies active family adult authorization.
4. Validates that `assessment.status = 'pending_review'`.
5. Validates that all mapped node IDs exist in the assessment's `learning_catalog_version` and share the assessment's `subject_key`.
6. Validates component keys and non-overlapping score sources.
7. Replaces the assessment's mapping set atomically in the same transaction.

Because assessment verification and rejection also lock the assessment row `FOR UPDATE`, mapping mutation and terminal verification serialize deterministically. Either mapping completes before verification begins, or verification wins and the mapping call fails closed. Verification can never observe a partially updated mapping set.

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
- `component_key text not null`
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

#### Mapping integrity rules
1. **Catalog version match:** `learning_node_id` must point to a node whose `catalog_version == assessment.learning_catalog_version`. Mappings to other catalog versions are rejected.
2. **Subject match:** `learning_node_id` must point to a node whose `subject_key == assessment.subject_key`. Cross-subject mapping (e.g. Math assessment mapped to English node) is strictly rejected.
3. **Component key uniqueness:** Within one `(assessment_id, learning_node_id)`, duplicate `component_key` values are rejected via unique constraint:
   ```text
   unique (assessment_id, learning_node_id, component_key)
   ```
   For `score_source = 'assessment_total'`, the component key is canonically reserved as `'assessment_total'`, preventing multiple whole-test mappings to the same node. If parent authoring cannot prove components/item groups are non-overlapping, they must be represented as one aggregate mapping rather than allowing silent double counting.

### 7.3 Score-source rules & Deterministic Aggregation

#### The single effective observation invariant
At most **one** effective mastery observation may exist per:

```text
(verified_learning_event_id, learning_node_id)
```

One assessment must never feed multiple sequential EWMA updates into the same node or overweight confidence.

When an assessment contains multiple component or item-group mappings for the same node, they must be deterministically aggregated before creating the immutable evidence atom:

#### `assessment_total`

Uses the verified whole-assessment score:
```text
performance_pct = normalized_score * 10
```

Allowed targets:
- Domain
- Topic

Not allowed for Skill. Not used for explicit Subject mappings because Subject fallback is automatic. Cannot be repeated for the same node on one assessment (guaranteed by canonical `component_key = 'assessment_total'`).

#### `component_score`

Uses:
```text
performance_pct = (component_raw_score / component_max_score) * 100
```

May support Domain, Topic or Skill when the active family adult confirms that the component measures that node. Validation requires `component_max_score > 0` and `0 <= component_raw_score <= component_max_score`.

**Deterministic aggregation for multiple components:**
If multiple distinct non-overlapping components map to the same node:
```text
performance_pct = (sum(component_raw_score) / sum(component_max_score)) * 100
```
Aggregated by score mass.

#### `item_group`

Uses:
```text
performance_pct = (correct_count / item_count) * 100
```

Designed primarily for Topic/Skill evidence. Validation requires:
```text
item_count > 0
0 <= correct_count <= item_count
```

**Deterministic aggregation for multiple item groups:**
If multiple distinct non-overlapping item groups map to the same node:
```text
item_count = sum(item_count)
correct_count = sum(correct_count)
performance_pct = (sum(correct_count) / sum(item_count)) * 100
```

#### Mixed source types fail closed (v0.1)
Within one `(assessment_id, learning_node_id)`, mixing different `score_source` types (`assessment_total`, `component_score`, `item_group`) is strictly disallowed. The author must choose one consistent detailed source model per node per assessment.

#### Insertion order invariance
Because aggregation is defined by mathematical sums (`sum(raw)/sum(max)` or `sum(correct)/sum(items)`), the aggregated effective observation is strictly invariant to mapping insertion order.

### 7.4 Mapping authority

Only an active family adult may create/replace authoritative detailed mappings in v0.1. Child suggestions, if added later, remain non-authoritative until adult confirmation.

---

## 8. Immutable Learning Evidence Atoms

When a VLE is processed, Phase 5 materializes immutable evidence atoms representing the effective observations rather than repeatedly interpreting mutable UI/draft state.

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
- `item_count integer null`
- `correct_count integer null`
- `occurred_at timestamptz not null`
- `effective_occurred_at timestamptz not null`
- `verified_at timestamptz not null`
- `created_at timestamptz not null`

### Effective occurrence timestamp
To eliminate client clock skew into the future:
```text
effective_occurred_at = least(occurred_at, verified_at)
```
Raw `occurred_at` is preserved for audit provenance. All Learning Engine ordering, confidence, freshness, recovery, and recommendation evaluations use `effective_occurred_at`.

### Uniqueness contract
Every VLE produces at most one effective evidence atom per learning node:

```text
unique (verified_learning_event_id, learning_node_id)
```

Subject fallback produces the single effective observation for the Subject root node. Detailed mappings produce the single aggregated effective observation for each mapped node. Retrying processing or replaying commands never duplicates evidence atoms.

### Diagnostic counts contract
- **`item_group` observations:** `item_count` and `correct_count` are populated (summed across groups if aggregated). Validation requires `item_count > 0` and `0 <= correct_count <= item_count`. `incorrect_count` is derived on demand as:
  ```text
  incorrect_count = item_count - correct_count
  ```
  Redundant incorrect counts are not stored.
- **`component_score` and `assessment_total` observations:** `item_count` and `correct_count` are `NULL`.

### 8.1 Automatic subject evidence

Every processed VLE creates exactly one subject-root evidence atom:

```text
learning_node_id = authoritative Subject root node for (catalog_version, subject_key)
node_type = 'subject'
score_source = 'assessment_total'
performance_pct = normalized_score * 10
item_count = NULL
correct_count = NULL
```

### 8.2 Optional richer evidence

Each mapped node creates one aggregated effective evidence atom at the mapped Domain/Topic/Skill using its aggregated performance percentage and diagnostic counts.

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

### 9.1 Scale and initialization (Option A)

Mastery is represented internally on `0..100`.

First credible observation:

```text
M_1 = P_1
```

The learner does not start from zero merely because LearnWard has no prior data.

**Deliberate pilot hypothesis (Option A):**
Level and specificity weights govern update influence (`alpha_effective`) on subsequent observations, not the initial estimate. If first evidence is below-level with a 100% score, initial mastery estimate is 100, but confidence units remain constrained:
```text
confidence_units = 1.00 * 0.50 = 0.50 < 1.5 (Low confidence)
```
Because `Mastered` requires `Confidence = High` and at least two distinct recent verified assessments, below-level work cannot declare a node `Mastered` prematurely.

### 9.2 Subsequent observations

At most one effective observation exists per assessment/node. For subsequent effective observations:

```text
M_new = M_old + alpha_effective * (P - M_old)
```

with:

```text
alpha_base = 0.35
```

One assessment must never feed multiple sequential EWMA steps into the same node.

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

### 9.1 Sticky Mastery Attainment & Temporal Declaration Semantics
- **Chronology vs. Declaration Distinction:**
  - `numeric mastery history = canonical academic chronology`: EWMA numeric mastery is rebuilt deterministically from the complete immutable evidence set sorted by `(effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC)`.
  - `mastery attainment declaration = server-authoritative processing/read timeline event`: `mastery_attained_at` represents the authoritative instant LearnWard actually declares mastery. It does not represent retrospective historical evidence timestamps.
- **Server-Authoritative Declaration Instant (`v_processing_as_of`):** During learning processing, the engine captures one `v_processing_as_of := transaction_timestamp()`. Initial attainment criteria (`final mastery_score >= 85 AND confidence = High AND >= 2 distinct recent verified assessments`) are evaluated strictly at `as_of = v_processing_as_of` over the rolling 60-day window `[v_processing_as_of - interval '60 days', v_processing_as_of]`. If satisfied, `mastery_attained_at` is stamped with `v_processing_as_of`.
- **Stale Evidence Prohibition:** Historical evidence may influence current numeric mastery, but stale historical evidence (>60 days old at declaration time) cannot retroactively manufacture a current Mastered declaration.
- **Schema Persistence:** Both `child_mastery_states` and `mastery_state_revisions` persist `mastery_attained_at timestamptz NULL`. Once non-null, prior attainment is preserved across rebuilds.
- **Read-Time Temporal Semantics (`mastery_attained_at <= as_of`):** `mastery_attained_at` applies to reads only when `mastery_attained_at <= as_of`. For historical reads where `as_of < mastery_attained_at`, the read must NOT expose `mastery_band = 'mastered'`, as attainment had not occurred yet at that historical time.
- **Sticky Retention Against Time Decay:** Once attained at $T_{\text{attained}}$, for all reads with `as_of >= T_attained`, `mastery_band` remains `mastered` even if elapsed time (e.g. 61+ days) drops read-time `confidence_band` from `high` to `low`. The system distinguishes between "historical mastery attained" and "recency/confidence of current evidence".
- **Preservation Across Lower-Scoring Evidence:** If subsequent verified assessments yield lower performance, the numeric `mastery_score` updates downwards via EWMA, but `mastery_attained_at` is preserved and `mastery_band` remains `mastered` for `as_of >= T_attained`.
- **Prerequisite Unlock Safety:** A prerequisite skill that was attained retains its attained status across time decay, guaranteeing that downstream dependent skills maintain prerequisite satisfaction for Phase 5.2 unlock eligibility.

---

## 10. Canonical Evidence Ordering & Late Evidence

EWMA is order-sensitive, so network/request arrival order is not an academic chronology.

For one child + node, evidence is ordered by:

```text
effective_occurred_at ASC,
verified_at ASC,
verified_learning_event_id ASC
```

Using the immutable source `verified_learning_event_id` as the final tie-breaker (rather than a runtime processing-generated evidence UUID) guarantees that the canonical sequence is 100% deterministic and invariant to processing execution or insertion order. For any given child and learning node, each VLE contributes at most one effective observation. Thus `(effective_occurred_at, verified_at, verified_learning_event_id)` is strictly unique and immutable prior to Phase 5 processing.

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
- `mastery_attained_at timestamptz null`
- `calculation_snapshot jsonb not null`
- `created_at timestamptz not null`

The snapshot contains deterministic calculation inputs/order and alpha components without copying evidence media.

Revisions are immutable and append-only. Direct client writes are revoked.

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
- `mastery_attained_at`
- `updated_at`

This is a server-controlled cache/projection, not historical source truth. Direct client mutation is revoked.

---

## 12. Confidence v0.1 (Delivered in Phase 5.1)

Confidence answers: *How much recent, sufficiently specific verified evidence supports this estimate?*

Because `Mastered` band evaluation requires `Confidence = High`, Confidence v0.1 is delivered in Phase 5.1 alongside the Mastery Engine.

It is derived at read time from effective evidence with strict lower and upper bounds relative to the server-authoritative `as_of` timestamp:

```text
effective_occurred_at >= as_of - interval '60 days'
AND effective_occurred_at <= as_of
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

Confidence units count each effective VLE/node observation once. Splitting an assessment across multiple mappings never increases confidence.

If units exceed 3.5 but only one VLE contributed, confidence remains Medium.

Phase 5 v0.1 does not invent a statistical variance model. A read model may expose a qualitative `recent_results_vary` explanation flag when recent observations materially disagree.

---

## 13. Freshness v0.1 (Delivered in Phase 5.2)

Freshness is derived at read time from latest credible academic `effective_occurred_at` relative to `as_of`:

```text
elapsed = as_of - latest_effective_occurred_at
```

| Elapsed time | Freshness |
|---:|---|
| <= 14 days | Recent (elapsed <= 14 days) |
| > 14 and <= 45 days | Aging (14 days < elapsed <= 45 days) |
| > 45 days | Needs refresh (elapsed > 45 days) |

Because `effective_occurred_at <= verified_at <= as_of`, elapsed time is always non-negative under normal operation. If server clock anomaly produces `verified_at > as_of`, fail-safe `effective_occurred_at = least(occurred_at, least(verified_at, as_of))` ensures `elapsed >= 0`.

Time passing does not mutate the mastery score.

```text
Mastered + time passes
=> Mastered · Needs refresh
```

No scheduled freshness mutation job is required.

---

## 14. Recovery Signal v0.1 (Delivered in Phase 5.2)

Phase 5 v0.1 supports only:

```text
none
review_suggested
```

The recovery signal is evaluated at read time for Topic and Skill nodes using immutable diagnostic facts preserved on effective evidence atoms:

### Raise rules (Topic/Skill only)
- **`item_group` observation:** raised when:
  ```text
  performance_pct < 70
  AND item_count >= 3
  AND incorrect_count >= 2
  ```
  where `incorrect_count = item_count - correct_count`.
- **`component_score` observation:** raised when:
  ```text
  performance_pct <= 50
  ```
- **Forbidden sources:** `assessment_total` and Subject fallback MUST NOT raise Skill or Topic recovery. Subject fallback must never create Skill recovery.

### Recency and expiry contract (30-day window)
A `review_suggested` signal is eligible only if the latest unresolved recovery observation is within **30 days** of `as_of`:

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

### Deterministic time context (`as_of`)
Every server-authoritative read function captures ONE `as_of` timestamp at request start:

```text
v_as_of := transaction_timestamp();
```

That single `as_of` instant is passed through:
- the 60-day Confidence window (`effective_occurred_at >= v_as_of - interval '60 days' AND effective_occurred_at <= v_as_of`),
- the 14-day and 45-day Freshness boundary checks,
- Recovery recency comparisons (30-day window),
- Next Challenge ranking.

The client does not supply or choose the authoritative `as_of`. The response payload includes `as_of` for explanation, debugging and UI audit. Pure Dart domain engines accept an explicit `DateTime asOf` parameter; direct calls to `DateTime.now()` are forbidden inside deterministic calculation logic.

Read functions:

- validate IDs,
- authenticate,
- load child and derive family from database state,
- authorize active adult or exact paired child device,
- capture single `as_of`,
- read current projections/immutable evidence,
- derive confidence/freshness/recovery interpretation using `as_of`,
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
-> authenticate caller
-> load VLE and derive authoritative family/child
-> authorize active family adult (paired child denied)
-> inspect initial command receipt replay
-> acquire per-VLE serialization lock
-> POST-LOCK RECHECK:
     re-read command_receipts and learning_processing_events in fresh snapshot:
     - if same command committed by racing caller: return committed result cleanly
     - if VLE committed under different command: bind new command receipt, return committed result
     - if unprocessed: continue with processing
-> load frozen assessment mappings (verified status guarantees pending_review mappings are frozen)
-> aggregate mappings per node into single effective observations
-> materialize subject fallback + aggregated detailed evidence atoms with unique (verified_learning_event_id, learning_node_id)
-> determine affected learning_node IDs
-> sort affected node IDs ASC
-> for each node in sorted order:
     acquire a transaction-scoped child+node serialization lock that works even when no projection row exists
-> after all required child+node locks are acquired:
     for each affected node in sorted order:
       read the complete immutable evidence set in canonical chronology (effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC)
       run Mastery Engine v0.1
       append mastery_state_revision
       upsert child_mastery_states projection
-> append immutable learning_processing_event
-> insert command_receipt (operation = 'process_learning', resource_id = verified_learning_event_id)
-> return processing result
```

The per `(child_id, learning_node_id)` lock may be implemented with a transaction-scoped PostgreSQL advisory lock derived collision-safely from the pair, or an equivalently safe create-then-row-lock protocol. The implementation must prove that **the first-ever concurrent write to a node is serialized**, not merely later updates after a projection row already exists.

The rebuild evidence SELECT occurs **after** acquiring the child+node serialization lock. Under PostgreSQL READ COMMITTED, a transaction that waited for the lock then sees the prior transaction's committed evidence on its subsequent SELECT, allowing deterministic convergence.

### 17.2 Command receipt operation & idempotency semantics

```text
command_receipts.operation = process_learning
resource_id = verified_learning_event_id
```

#### Additive `command_receipts` migration for `process_learning`
Frozen Phase 4.2 currently constrains `command_receipts.operation` to:
```text
create_draft, submit, verify, reject, process_growth, redeem_reward, fulfill_reward, cancel_reward, spin_wheel
```
Phase 5 design requires inserting receipts with `operation = 'process_learning'`.
Therefore, Phase 5 implementation MUST explicitly include an additive migration that replaces the existing CHECK constraint (`command_receipts_operation_check`), preserving all 9 frozen Phase 1–4 operations while adding `process_learning`:
```sql
ALTER TABLE public.command_receipts
  DROP CONSTRAINT IF EXISTS command_receipts_operation_check,
  ADD CONSTRAINT command_receipts_operation_check
    CHECK (operation IN (
      'create_draft', 'submit', 'verify', 'reject', 'process_growth',
      'redeem_reward', 'fulfill_reward', 'cancel_reward', 'spin_wheel',
      'process_learning'
    ));
```
Canonical future operation set:
`create_draft`, `submit`, `verify`, `reject`, `process_growth`, `redeem_reward`, `fulfill_reward`, `cancel_reward`, `spin_wheel`, `process_learning`.
Frozen Phase 1–4 migrations are never rewritten.
Crucially, **`process_learning_event` cannot ship until `command_receipts.operation` accepts `process_learning`**.

#### Immutable processing result snapshot
Logical processing events are tracked in:
```sql
CREATE TABLE public.learning_processing_events (
  id uuid primary key default gen_random_uuid(),
  verified_learning_event_id uuid not null unique references public.verified_learning_events(id),
  assessment_id uuid not null references public.assessments(id),
  family_id uuid not null references public.families(id),
  child_id uuid not null,
  processed_at timestamptz not null default clock_timestamp(),
  evidence_count integer not null,
  affected_node_ids uuid[] not null,
  status text not null check (status = 'processed'),
  FOREIGN KEY (child_id, family_id) REFERENCES public.child_profiles(id, family_id)
);
```

The idempotency contract guarantees:
- **Sorted node IDs in result snapshot:** `affected_node_ids` in `learning_processing_events` is stored in canonical sorted node-ID order (ascending) to guarantee that historical replay responses are byte- and logically stable.
- **Immutable result source:** `process_learning_event` returns an immutable `process_learning_result` payload:
  - `processing_event_id`
  - `verified_learning_event_id`
  - `assessment_id`
  - `child_id`
  - `family_id`
  - `processed_at`
  - `evidence_count`
  - `affected_node_ids`
  - `status` ('processed')
  When replaying an already-processed command (or executing a new command against an already-processed VLE), the function constructs this result directly from `learning_processing_events`. It is NEVER recomputed from mutable `child_mastery_states`, guaranteeing that subsequent VLEs altering current mastery do not alter historical replay responses.
- **Same command replay:** If a command is replayed with identical `(command_id, actor_user_id, operation = 'process_learning', family_id, resource_id = verified_learning_event_id)`, the server returns the already-committed processing result snapshot without duplicating evidence or revisions. Any mismatch on actor, family, operation, or resource is rejected with a validation error.
- **Concurrent same-command calls:** Both calls acquire the VLE lock in order. Winner processes and records receipt; waiter re-reads `command_receipts` and `learning_processing_events` in fresh snapshot, identifies committed replay, and returns clean result snapshot without primary-key collision.
- **Same VLE, new command ID:** If target VLE has already produced its unique `learning_processing_event`, a new `command_id` binds and records a valid command receipt for that command pointing `resource_id = verified_learning_event_id` and returns the committed processing result snapshot. It creates NO new evidence and NO new mastery revisions.
- **Reused command ID, different VLE:** Strictly rejected.
- **Logical uniqueness:** `learning_processing_events` enforces `unique(verified_learning_event_id)`.
- **Evidence uniqueness:** `learning_evidence_events` enforces `unique (verified_learning_event_id, learning_node_id)`.

### 17.3 Bulk catch-up contract

```text
catch_up_unprocessed_learning(family_id)
```

Bulk catch-up must never weaken idempotency or forge synthetic public command receipts:
1. **Explicit authorization:** `catch_up_unprocessed_learning(family_id)` requires explicit caller authentication and authorization: the caller must be an active family adult in that family. Paired child calls and cross-family calls are denied (`42501` / `LW002`).
2. **Discovery:** Discovers verified learning events for `family_id` lacking a corresponding `learning_processing_event`.
3. **Execution:** For each discovered VLE, executes the internal trusted processing routine anchored directly on `unique(verified_learning_event_id)`.
4. It does NOT invent dummy public command IDs or insert artificial command receipts.
5. If catch-up audit is needed, an independent batch run identifier (`batch_id`) is recorded on the catch-up log rather than pretending one command receipt represents many VLEs.
6. Repeated catch-up calls are safe no-ops (0 VLEs processed).

#### Concurrency and idempotency behavior matrix:

| Scenario | Behavior |
|---|---|
| **Same VLE + same command** | Replay returns committed processing result; no duplicate evidence/revisions. |
| **Same VLE + new command** | Binds new command receipt to existing VLE; returns committed result; no duplicate evidence/revisions. |
| **Same command + different VLE** | Rejected as illegal command reuse. |
| **Catch-up after lost response** | Internal catch-up processes VLE anchored on `unique(verified_learning_event_id)`. Subsequent client command replay binds receipt and sees committed result. |
| **Concurrent catch-up + manual process** | Serialized on VLE. Winner performs processing; loser observes existing `learning_processing_event` and returns committed result safely. |
| **Two concurrent catch-up workers** | Serialized on VLE. Winner processes; second worker skips already-processed VLE without error or duplication. |

---

## 18. Concurrency Contract

### 18.1 Same VLE processed twice

Two concurrent calls for the same VLE produce one logical processing event and one logical evidence set. Retry/replay returns the committed result without primary key errors.

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

Mapping mutation and assessment terminal transition serialize on the assessment row `FOR UPDATE`. Exactly one stable mapping set is observed by verification and later learning processing.

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

Eligible when a Topic/Skill has `review_suggested` within the 30-day recency window. Prefer the most recent meaningful recovery signal.

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
2. relevant evidence recency (`effective_occurred_at`),
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

- assessment mappings (`assessment_learning_mappings`),
- learning evidence events (`learning_evidence_events`),
- mastery revisions (`mastery_state_revisions`),
- current mastery state (`child_mastery_states`),
- learning processing events (`learning_processing_events`).

Authorization:

- active family adult may read learning state for children in that family,
- paired child device may read only its exact child,
- sibling paired devices are denied,
- direct client writes (`INSERT`, `UPDATE`, `DELETE`) are revoked on:
  - `assessment_learning_mappings`,
  - `learning_catalog_versions`,
  - `learning_nodes`,
  - `learning_prerequisites`,
  - `learning_evidence_events`,
  - `mastery_state_revisions`,
  - `child_mastery_states`,
  - `learning_processing_events`.

Global taxonomy/prerequisite data contains no child PII and is client read-only.

Phase 5 strictly separates client-facing trusted functions from platform-only administration:

### Client-Facing Trusted Phase 5 Functions
Client-facing functions (`set_assessment_learning_mappings`, `process_learning_event`, `catch_up_unprocessed_learning`, and learning read RPCs) follow repository hardening:
- `SECURITY DEFINER`,
- `SET search_path = ''`,
- fully qualified objects,
- exact signature grants to `authenticated`,
- execution revoked from `PUBLIC` and `anon`,
- explicit family/child tenant authorization before private replay/result data is accessed or returned.

### Platform-Only Administration
Global curriculum administration functions (such as catalog publication, content releases, and `promote_learning_catalog_version`) are strictly platform deployment/administration concerns:
- `EXECUTE` is revoked from `PUBLIC`, `anon`, and `authenticated`,
- `EXECUTE` is explicitly granted to `service_role`:
  ```sql
  GRANT EXECUTE ON FUNCTION public.promote_learning_catalog_version(text) TO service_role;
  ```
- active family adults and children have zero curriculum administration privileges,
- callable exclusively by release migrations and trusted platform/service-role execution.

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
LearningCatalogVersion
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

- first observation initialization (Option A),
- Subject/Domain/Topic/Skill specificity,
- below-level weighting and constrained confidence,
- multiple-mapping deterministic aggregation (score mass and item count sums),
- chronological updates using `effective_occurred_at`,
- exact timestamp tie-breaks using immutable source verified_learning_event_id,
- delayed older evidence arriving after newer evidence,
- two concurrent first-ever updates to the same child/node,
- confidence thresholds and distinct-VLE rule,
- time determinism with explicit `as_of` / `asOf` instant,
- freshness exact boundaries:
  - exactly 14 days vs just over 14 days (14 days + 1 second),
  - exactly 30 days vs just over 30 days (recovery expiry),
  - exactly 45 days vs just over 45 days (45 days + 1 second),
  - exactly 60 days vs just over 60 days (60 days + 1 second),
- future-dated evidence effective timestamp bounding (`least(occurred_at, verified_at)` and `effective_occurred_at <= as_of`),
- recovery signal raise (`item_group` and `component_score`) and clear (`performance_pct >= 70`),
- recovery source granularity enforcement (broad assessment total cannot clear skill recovery),
- Mastered declaration in Phase 5.1,
- recommendation priority/tie-breaks,
- unknown current grade filtering,
- reward/economy invariance.

Required invariant:

```text
Pure Dart canonical result == PostgreSQL integration/read-model canonical result
```

for the same academic inputs and evaluation timestamp.

---

## 27. Required Database / Integration Tests

At minimum implementation must prove:

### Catalog provenance, registry & hierarchy integrity
1. **Legacy catalog migration & write path integration (DDL-safe bootstrap):** All pre-existing assessments and VLEs are deterministically assigned `pilot-v0.1` upon migration via additive DDL (`DEFAULT 'pilot-v0.1' NOT NULL` then `DROP DEFAULT`); terminal assessment mutation guard (`LW103`) and VLE mutation guard (`LW102`) remain enabled, untouched, and reject subsequent UPDATE attempts on legacy rows.
2. **Promote `pilot-v0.2` then create new assessment:** Assessment creation stamps exactly `pilot-v0.2` via `BEFORE INSERT` trigger ignoring caller input.
3. **Caller cannot override catalog version:** Caller supplying an obsolete or arbitrary catalog version to assessment creation is ignored, and active catalog version is stamped.
4. **Verifying assessment copies catalog snapshot:** Verifying an assessment created under `pilot-v0.2` copies `pilot-v0.2` into VLE via `BEFORE INSERT` trigger, never current active or static default.
5. **Old `pilot-v0.1` assessment verified after rollout:** An assessment created under `pilot-v0.1` verified after `pilot-v0.2` promotion copies `pilot-v0.1` into the VLE.
6. **Pilot catalog completeness:** `pilot-v0.1` contains exactly one Subject root node for every canonical subject key (`math`, `english`, `literature`, `science`, `other`).
7. **Catalog registry promotion procedure:** Trusted promotion locks, validates `draft` target exists, validates publishability (all 5 roots, valid hierarchy, Skill-only acyclic DAG), atomically retires previous active and activates candidate, and asserts exactly one active row exists before commit; failure rolls back and raises SQLSTATE `LW501` ('No active learning catalog'). Rejects invalid target, already-active target, retired target, incomplete draft catalog, and concurrent promotions. None leaves zero active catalogs.
8. **Prerequisite composite schema & validation:** `learning_prerequisites` carries `subject_key` with composite FKs to `learning_nodes(catalog_version, subject_key, id)`, enforcing same version and same subject at schema level. Edge linking nodes across subjects or versions is rejected at INSERT. Promotion to active rejects draft catalog if edges link non-Skill nodes or form a cycle; an empty prerequisite graph is explicitly valid.
9. **Processing events identity & sorted order:** `learning_processing_events` enforces composite FK to `child_profiles(id, family_id)` and stores `affected_node_ids` in canonical sorted order (`ASC`).
10. **Published version immutability:** Published catalog versions (`active` or `retired`) are strictly immutable; client writes and in-place deactivations (`is_active = false`) are denied.
11. **Pending-review mapping with older catalog version:** A `pending_review` assessment created under `pilot-v0.1` remains map-able and verifiable against `pilot-v0.1` even after `pilot-v0.2` is promoted to active.
12. **Catalog changes before delayed catch-up:** When platform rolls from `pilot-v0.1` to `pilot-v0.2`, delayed processing of a VLE authored under `pilot-v0.1` preserves `pilot-v0.1` and resolves to the `pilot-v0.1` Subject root.
13. **Old VLE uses old version:** VLE processing strictly uses `vle.learning_catalog_version`.
14. **Subject root uniqueness:** Exactly one Subject root per `(catalog_version, subject_key)`; duplicate Subject root insert is rejected.
15. **Hierarchy subject integrity:** Parent/child edges across different subjects (e.g. Domain in Math pointing to parent Subject in English) are strictly rejected.
16. **Hierarchy version integrity:** Parent/child edges across different catalog versions are rejected.
17. **Mapping subject integrity:** Mapping a Math assessment to an English node is rejected.
18. **Mapping version integrity:** Mapping an assessment to a node in a different catalog version is rejected.
19. **Cross-version recommendation isolation:** Recommendations evaluate against the current active catalog without treating old-version mastery as active-catalog mastery.

### Mapping lifecycle & security
20. **Cannot map while draft:** Mapping RPC rejects calls when `assessment.status = 'draft'`.
21. **Cannot map after terminal:** Mapping RPC rejects calls when `assessment.status` is `verified` or `rejected`.
22. **Paired child mapping denied:** Paired child identity cannot call mapping RPC.
23. **Cross-family mapping denied:** Active adult from Family A cannot set mappings for Family B.
24. **Direct table mutation denied:** Direct client `INSERT`, `UPDATE`, `DELETE` on `assessment_learning_mappings` are denied.
25. **Mapping vs verification concurrency:** Concurrent mapping and verification calls serialize on assessment row; verification never observes partial mapping set.
26. **Mapping vs rejection concurrency:** Concurrent mapping and rejection serialize safely.

### Observation aggregation & evidence uniqueness
27. **One effective observation per VLE/node:** Every processed VLE produces at most one effective mastery observation per mapped node; multiple mappings for the same node aggregate deterministically.
28. **Duplicate component key rejected:** Mapping two components with the same `component_key` on the same assessment is rejected.
29. **Assessment total single mapping:** `assessment_total` cannot be mapped more than once on the same assessment.
30. **Component score aggregation:** Multiple component mappings for the same node aggregate by score mass: `sum(raw_score) / sum(max_score)`.
31. **Item group aggregation:** Multiple item groups for the same node aggregate by item counts: `sum(correct_count) / sum(item_count)`.
32. **Mixed score sources rejected:** An assessment mapping both `component_score` and `item_group` to the same node is rejected.
33. **Insertion order invariance:** Aggregating mappings in different insertion sequences produces identical aggregate scores and identical EWMA inputs.
34. **No confidence inflation:** Split mappings produce only one effective observation and contribute one observation to confidence count.
35. **Subject fallback:** Every verified event creates exactly one Subject root evidence atom even if detailed mappings are omitted.

### Effective chronology & future timestamp bounds
36. **Effective occurred calculation:** Server derives `effective_occurred_at = least(occurred_at, verified_at)`.
37. **Future timestamp cannot extend confidence:** Far-future raw `occurred_at` is clamped to `verified_at` and bounded by `as_of`.
38. **Future timestamp cannot dominate recency:** Freshness elapsed time cannot be negative.

### Recovery diagnostic provenance & recency
39. **Diagnostic counts preserved:** Effective evidence rows snapshot `item_count` and `correct_count` for `item_group`.
40. **Item group recovery raise:** `performance_pct < 70 AND item_count >= 3 AND incorrect_count >= 2` raises `review_suggested`.
41. **Component score recovery raise:** `performance_pct <= 50` raises `review_suggested`.
42. **Assessment total cannot raise skill recovery:** Whole-test score never creates Skill recovery.
43. **Recovery expiry at 30 days:** Unresolved recovery signal older than 30 days decays to `none`.
44. **Allowed source clear:** A later observation with `performance_pct >= 70` from `component_score` or `item_group` clears `review_suggested`.
45. **Broad evidence cannot clear skill recovery:** An `assessment_total` observation never clears a Skill recovery signal.

### Time determinism & boundaries
46. **Single `as_of` clock:** Read model evaluation captures `v_as_of := transaction_timestamp();` and passes it across confidence, freshness, and recovery.
47. **Boundary parity:** 14-day, 30-day, 45-day, and 60-day boundary fixtures yield identical classifications in Dart and PostgreSQL.
48. **Canonical chronology source tie-break:** Two VLEs with identical `(effective_occurred_at, verified_at)` produce identical EWMA ordering and mastery projections regardless of evidence UUID assignment or insertion sequence, because ordering is tied to `verified_learning_event_id ASC`.

### Idempotency, concurrency & command receipts
49. **Command receipts migration preserves Phase 1–4 operations:** After the additive migration, existing operations `create_draft`, `submit`, `verify`, `reject`, `process_growth`, `redeem_reward`, `fulfill_reward`, `cancel_reward`, and `spin_wheel` remain valid and accepted.
50. **Command receipts migration accepts `process_learning`:** Receipts with `operation = 'process_learning'` are successfully inserted and validated.
51. **Command receipts rejects unknown operation:** Attempting to insert a receipt with an unknown operation (e.g. `'unknown_op'`) fails the CHECK constraint.
52. **Existing command receipt rows preserved:** Pre-existing command receipts from Phases 1–4 survive the constraint replacement migration unmodified.
53. **Same command replay:** Calling `process_learning_event` with the same `command_id` and VLE replays committed result snapshot from immutable `learning_processing_events` without duplicating evidence or revisions.
54. **Concurrent same-command replay:** Two concurrent calls with identical `command_id` and VLE serialize on lock, recheck receipts, and return clean replays without primary-key collisions.
55. **Replay invariant to subsequent VLEs:** Replaying `process_learning_event` for VLE 1 after VLE 2 has altered `child_mastery_states` returns the identical committed result snapshot from `learning_processing_events` without reflecting VLE 2's mutations.
56. **New command on processed VLE:** Calling with a new `command_id` on an already-processed VLE binds a new command receipt pointing `resource_id = verified_learning_event_id` and returns the committed result snapshot without duplicate evidence or revisions.
57. **Reused command on different VLE:** Calling with an existing `command_id` targeting a different VLE is rejected.
58. **Concurrent same-VLE processing:** Two concurrent calls produce one logical processing event and one evidence set.
59. **Concurrent different-VLE processing:** Two concurrent VLEs affecting the same previously unseen child/node serialize on child+node locks and converge to identical canonical mastery projection.
60. **Late older evidence rebuild:** Late-arriving older evidence rebuilds projection to canonical chronology order.
61. **Catch-up idempotency & authorization:** `catch_up_unprocessed_learning` requires active family adult authorization; paired child identity is denied (`42501`); cross-family adult is denied (`42501`); processes unprocessed VLEs anchored on `unique(verified_learning_event_id)`; re-running catch-up is a safe no-op.
62. **Concurrent catch-up and manual process:** Safe convergence without double evidence or revision duplication.
63. **Two concurrent catch-up workers:** Safe convergence without double evidence or revision duplication.

### Security, isolation, audit immutability & platform administration
64. **Cross-family read denied:** Active adult from Family A cannot read child learning state in Family B.
65. **Paired child sibling isolation:** Paired child A cannot read learning state for sibling child B.
66. **Direct client writes denied:** Client cannot INSERT/UPDATE/DELETE `learning_nodes`, `learning_prerequisites`, `learning_evidence_events`, `mastery_state_revisions`, `child_mastery_states`, or `learning_processing_events`.
67. **Active family adult catalog promotion denied:** Active family adult calling `promote_learning_catalog_version` is denied (`EXECUTE` permission denied).
68. **Paired child catalog promotion denied:** Paired child calling `promote_learning_catalog_version` is denied (`EXECUTE` permission denied).
69. **Anonymous catalog promotion denied:** Anon calling `promote_learning_catalog_version` is denied (`EXECUTE` permission denied).
70. **Normal authenticated user draft mutation denied:** Normal authenticated user cannot `INSERT`, `UPDATE`, or `DELETE` draft catalog versions or draft nodes/prerequisites.
71. **Platform service-role promotion succeeds:** Trusted service_role execution with explicit GRANT EXECUTE successfully promotes a valid publishable draft catalog (with valid 5 roots, hierarchy, and acyclic Skill-only DAG; empty DAG valid) to active, while normal authenticated users cannot invoke it.
72. **Invalid platform promotion rolls back:** Candidate draft missing canonical roots, containing cycles, or lacking draft status fails validation and rolls back atomically, preserving existing active catalog.
73. **Audit tables append-only:** UPDATE and DELETE are rejected on `learning_evidence_events`, `mastery_state_revisions`, and `learning_processing_events`.
74. **Grade snapshot provenance:** Historical evidence retains immutable `grade_level_snapshot` after profile grade changes; missing current profile grade fails closed for grade-scoped Unlock/Explore.
75. **Reward/economy invariance:** Mutating XP, RP balances, reward tiers, redemptions, or Wheel outcomes produces zero change in mastery scores, confidence, freshness, recovery signals, or next-challenge candidate rankings.

---

## 28. Domain / Application / Flutter Tests

### Domain

Table-driven tests for:
- EWMA calculation and effective alpha,
- Option A initialization (`M_1 = P_1`), including below-level 100% initializing score to 100 with constrained confidence (<1.5 Low),
- specificity weights (Subject 0.35, Domain 0.50, Topic 0.75, Skill 1.00),
- level weights (normal 1.00, hard 1.00, challenge 1.00, below_level 0.50),
- deterministic aggregation of multiple component scores (`sum(raw)/sum(max)`) and item groups (`sum(correct)/sum(items)`),
- fail-closed rejection of mixed score sources on the same node,
- mastery bands classification, including `Mastered` band evaluation in Phase 5.1,
- confidence calculation relative to explicit `DateTime asOf` with distinct-VLE threshold and upper/lower bounds,
- freshness boundaries relative to `asOf` (14 days, 45 days) using `effective_occurred_at`,
- recovery signal raise rules (item count >= 3 & incorrect count >= 2, component score <= 50), 30-day expiry, and clear rule (>= 70),
- canonical evidence sorting comparator (`effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC`),
- next challenge candidate ranking priority (Recovery -> Developing -> Refresh -> Unlock -> Exploration) and tie-breakers.

### Application

Test mapping validation (requiring `pending_review`), duplicate `component_key` rejection, score aggregation, retry handling, post-lock receipt recheck, new command binding on processed VLE, missing-mapping subject fallback, catch-up service, repository boundaries, and complete absence of reward-repository dependencies.

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

Phase 5.1 migration work includes at minimum:

```text
ALTER assessments
  + learning_catalog_version provenance (DDL-safe DEFAULT 'pilot-v0.1' NOT NULL, then DROP DEFAULT, Before Insert trigger)

ALTER verified_learning_events
  + learning_catalog_version provenance (DDL-safe DEFAULT 'pilot-v0.1' NOT NULL, then DROP DEFAULT, Before Insert trigger)

ALTER command_receipts
  operation CHECK constraint replaced to add 'process_learning' while preserving all 9 frozen operations

CREATE learning_catalog_versions
CREATE learning_nodes
CREATE learning_prerequisites
CREATE assessment_learning_mappings
CREATE learning_evidence_events
CREATE mastery_state_revisions
CREATE child_mastery_states
CREATE learning_processing_events
Phase 5.1 functions / triggers / RLS / grants / indexes
```

Phase 5.2 includes:

```text
Freshness / Recovery / recommendation functions and read models (including prerequisite graph traversal for Unlock/Explore)
```

Exact physical migration files and names may be refined during implementation review without changing these frozen semantic boundaries.

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

> The same committed verified evidence set always produces the same current mastery projection regardless of request arrival order; first-write concurrency is safe; catalog promotion enforces publishability (all 5 Subject roots, valid hierarchy, and Skill-only acyclic prerequisite DAG; empty graph treated as valid) and platform-only authorization; subject-level progress works without detailed mappings; detailed claims never exceed evidence granularity; Confidence v0.1 supports valid evaluation of the Mastered band.

### Phase 5.2

> Freshness and recovery interpretations (with 30-day recency window) are explainable/deterministic, prerequisite traversal generates valid next-challenge candidates without reward/economy signals affecting academic ranking, and the child receives at most three useful choices.

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
