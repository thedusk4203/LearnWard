# Phase 5.2 Detailed Design v0.1 — Skill Graph, Freshness, Recovery & Next Challenge

- **Status:** PROPOSED (Design Checkpoint — Implementation NOT Authorized)
- **Reviewed Baseline:** `main` @ `16568a99da157f296fdf30c3b5e28d902bee5fbc`
- **Upstream Contract:** Phase 5.1 — FROZEN ([freeze receipt](freezes/phase-5-1-learning-mastery-foundation-freeze.md)), [ADR 0006](adr/0006-phase-5-learning-engine-mastery.md) — ACCEPTED
- **Readiness Review:** [Phase 5.2 Dependency / Readiness Review](14-phase-5-2-dependency-readiness-review.md) (PR #9 comment `6594086334`, PR #10 audit `6594895418`)
- **Companion ADR:** [ADR 0007 — Phase 5.2 Skill Graph, Freshness, Recovery & Next Challenge Decisions](adr/0007-phase-5-2-skill-graph-recommendation.md) (`PROPOSED`)

---

## 1. Purpose, Scope & Non-Goals

Phase 5.2 is the second and final slice of Phase 5 ([Phase 5 Detailed Design v0.1](13-phase-5-learning-engine-mastery-design-v0.1.md) Section 4). Building strictly additively on the frozen Phase 5.1 knowledge catalog, immutable evidence ledger, EWMA mastery projections, and Confidence v0.1 foundation, Phase 5.2 delivers:

1. **Skill Graph traversal** across the active learning catalog's Skill-only prerequisite DAG for Unlock and Explore candidate eligibility and Node Detail prerequisite/dependent inspection;
2. **Freshness Engine v0.1** (`recent | aging | needs_refresh | unknown`) evaluated dynamically at read time relative to server-authoritative `as_of`;
3. **Recovery Engine v0.1** (`none | review_suggested`) evaluated deterministically via canonical chronology replay with dual temporal visibility (`effective_occurred_at <= as_of AND verified_at <= as_of`) and a 30-day recency window;
4. **Next Challenge Engine v0.1** producing at most **3** deterministic, explainable learning choices partitioned cleanly across `recovery > refresh > developing > unlock > explore`;
5. **Coverage-aware Learning Overview & Node State** read models and `SECURITY DEFINER` RPCs distinguishing observed vs unseen nodes without naive cross-skill percentage averaging;
6. **Parent overview / node detail & Child choice UI** presenting up to three clear academic options without reward-economy coupling.

### Explicit Non-Goals (Out of Scope for Phase 5.2)

- **No Phase 5.3 split:** Phase 5.2 completes Phase 5 v0.1.
- **No mutable recommendation tables:** No `recommendations`, `recovery_states`, `freshness_states`, or persisted challenge-assignment lifecycle tables are introduced.
- **No historical event-sourced numeric mastery reconstruction:** `private.*_at` helpers evaluate dynamic read projections (confidence, freshness, recovery, prerequisite satisfaction) at a parameterized evaluation clock over the **current committed projection**; they do NOT reconstruct historical numeric mastery before subsequent evidence was logged.
- **No `pilot-v0.1` mutation or `pilot-v0.2` promotion:** Published `pilot-v0.1` remains immutable; Phase 5.2 does not promote a new production catalog version or implement cross-version mastery carry-forward.
- **No economy coupling:** Recommendation, freshness, recovery, and overview reads never inspect or mutate Study XP, Reward Points (RP), `child_balances`, Reward Store items/redemptions, or Celebration Wheel state.
- **No forgetting-curve mastery decay:** Time passing changes Confidence and Freshness only; `mastery_score` and sticky `mastery_attained_at` never decay from elapsed time.
- **No AI/OCR auto-mapping or in-app quiz execution:** LearnWard recommends *what external learning challenge to tackle next*; academic state advances only when new external assessments are captured, verified, and processed through Phase 5.1.

---

## 2. Architectural Invariants & Zero-Persistence Rule

1. **Read-time projection only:** Freshness, Recovery, Prerequisite satisfaction, Dependents, Coverage counts, and Next Challenge rankings are pure deterministic projections over:
   - `public.learning_catalog_versions` (`status = 'active'`),
   - `public.learning_nodes`,
   - `public.learning_prerequisites`,
   - `public.child_mastery_states`,
   - `public.learning_evidence_events`, and
   - `public.child_profiles` (`status = 'active'`, `family_id`, `school_grade`).
2. **Zero side effects on read:** All Phase 5.2 SQL functions are `STABLE` read-only queries. Calling any Phase 5.2 RPC performs zero `INSERT`, `UPDATE`, or `DELETE` operations on any table.
3. **Consumer of Phase 5.1 Mastery & Confidence:** Phase 5.2 is strictly a consumer of frozen Phase 5.1 Mastery and Confidence semantics; it MUST NOT redefine, approximate, or fork them.
4. **Determinism & cross-platform parity:** Given identical catalog nodes, prerequisite edges, child mastery states, evidence events, `school_grade`, optional `subject_key` filter, `limit`, and `as_of` instant, pure Dart engines in `learnward_domain` and PostgreSQL RPCs in `supabase` MUST return byte-equivalent logical results and identical candidate ordering.
5. **Reward/economy invariance:** Mutating XP ledgers, RP ledgers, `child_balances`, reward catalog items, redemptions, or Wheel spins MUST produce zero change in Learning Overview, Node Learning State, or Next Challenge output.

---

## 3. Server-Authoritative `as_of`, Evaluation-Clock Semantics & Internal Pipeline

### 3.1 Request Clock in Client-Facing Public RPCs

Clients never supply an authoritative evaluation clock. Every client-facing Phase 5.2 RPC captures a single transaction-level clock once at entry:

```sql
v_as_of := transaction_timestamp();
```

That single `v_as_of` value is passed across all downstream derivations in the request:
- **Sticky mastery attainment check:** `mastery_attained_at IS NOT NULL AND mastery_attained_at <= v_as_of` (used for both `mastery_band = 'mastered'` and prerequisite satisfaction);
- **Confidence 60-day window:** `effective_occurred_at >= v_as_of - interval '60 days' AND effective_occurred_at <= v_as_of` (with authority visibility `verified_at <= v_as_of`);
- **Freshness 14d / 45d elapsed duration:** `greatest(interval '0 seconds', v_as_of - latest_effective_occurred_at)`;
- **Recovery replay upper bound & 30-day recency window:** `effective_occurred_at <= v_as_of AND verified_at <= v_as_of` and `v_as_of - latest_unresolved_weakness_at <= interval '30 days'`;
- **Response metadata:** echoed as `as_of` in every response payload.

### 3.2 Evaluation-Clock Contract for `private.*_at` Helpers

Following the frozen Phase 5.1 pattern (`public.get_child_mastery` delegating to `private.get_child_mastery_at(p_child_id, v_as_of)`), each Phase 5.2 public RPC delegates its computation to an internal `private` helper accepting an explicit `p_as_of timestamptz`:

- `private.get_child_learning_overview_at(p_child_id uuid, p_as_of timestamptz)`
- `private.get_node_learning_state_at(p_child_id uuid, p_learning_node_id uuid, p_as_of timestamptz)`
- `private.get_next_challenge_candidates_at(p_child_id uuid, p_subject_key text, p_limit integer, p_as_of timestamptz)`

`EXECUTE` on all `private.*_at` functions is revoked from `PUBLIC`, `anon`, and `authenticated`. Only the database owner / parity test harness (to test boundary shifts such as `+14d`, `+14d + 1s`, `+30d`, `+30d + 1s`, `+45d`, `+45d + 1s`, `+61d`) and the `SECURITY DEFINER` `public.*` wrappers can invoke them.

#### Exact Evaluation-Clock Boundary (Not a Database System-Time Snapshot)

```text
private.*_at helpers are deterministic evaluation-clock helpers
over the CURRENT COMMITTED Phase 5.1 projection.

They are NOT arbitrary historical snapshot reconstruction APIs.
```

- **What `p_as_of` varies:**
  - `confidence_band` & `confidence_units` (rolling 60-day window relative to `p_as_of`);
  - `freshness` (elapsed duration relative to `p_as_of`);
  - `recovery_signal` (replay over evidence visible at `p_as_of` and 30-day expiry relative to `p_as_of`);
  - `mastery_attained_at <= p_as_of` gate (determining whether `mastery_band = 'mastered'` and whether prerequisites are satisfied at `p_as_of`);
  - `is_prerequisite_satisfied` visibility at `p_as_of`.
- **What `p_as_of` does NOT do:** It does NOT reconstruct historical numeric EWMA `mastery_score` before subsequently processed VLEs. Full historical numeric mastery reconstruction would require replaying the entire immutable evidence ledger and is explicitly outside Phase 5.2 v0.1 scope.
- **Parity fixture precondition:** Parity fixtures evaluating at explicit `p_as_of` MUST establish the child's committed projection at or before `p_as_of`, then advance `p_as_of` forward to test temporal transitions (aging, expiry, sticky attainment), unless explicitly testing the temporal visibility guard.

### 3.3 Evidence Authority Visibility Rule (`verified_at <= as_of`)

Whenever Phase 5.2 queries `public.learning_evidence_events` (for Recovery replay, `latest_evidence`, and Confidence evaluation), it MUST enforce **dual temporal bounds**:

```sql
effective_occurred_at <= v_as_of
AND verified_at <= v_as_of
```

- **`effective_occurred_at`** = academic chronology (when the learning occurred).
- **`verified_at`** = authority visibility time (when the evidence was verified into the authoritative system).

An evidence event verified at `T3` MUST NOT participate in an evaluation at `T2` (`T2 < T3`) merely because its historical `effective_occurred_at = T1` was before `T2`. In production public RPCs where `v_as_of := transaction_timestamp()`, all committed rows already satisfy `verified_at <= v_as_of`. For internal `private.*_at` evaluation helpers, the `verified_at <= v_as_of` guard guarantees that future-verified evidence never leaks backward into historical evaluation frames.

### 3.4 Unified Internal Derivation Pipeline

Overview, Node State, and Next Challenge MUST NOT independently implement divergent node-state derivations. Phase 5.2 establishes a single, unified conceptual derivation pipeline:

```text
authorize child (family adult or exact active paired child device)
  ↓
resolve active catalog version (raises LW501 if none active)
  ↓
capture as_of clock (transaction_timestamp() in public RPCs)
  ↓
build active catalog universe (is_active = true along full ancestor chain)
  ↓
for observed nodes:
  consume frozen Phase 5.1 mastery & confidence semantics at as_of
  (mastery_score, mastery_band, confidence_units, confidence_band, distinct_recent_vles)
  ↓
apply evidence visibility (verified_at <= as_of AND effective_occurred_at <= as_of):
  - resolve latest_evidence summary
  - execute Recovery replay & 30-day recency expiry
  - evaluate Freshness relative to latest_effective_occurred_at
  ↓
derive prerequisite & dependent graph state:
  - prerequisites: check mastery_attained_at <= as_of for all active incoming edges
  - dependents: collect active-catalog outgoing dependent Skills with prerequisite/grade status
  ↓
derive grade compatibility (child_profiles.school_grade vs node bounds)
  ↓
derive Next Challenge priority class (mutually exclusive partition §7)
  ↓
apply deterministic total comparator (priority_rank, class key, catalog_sort_path, node_id)
  ↓
assemble canonical response payload
```

---

## 4. Candidate Universe, Active Catalog & Consumption of Phase 5.1 Mastery/Confidence

### 4.1 Active-Catalog Candidate Universe & Seen/Unseen Semantics

Phase 5.2 MUST NOT derive node states or Next Challenge candidates solely from `public.child_mastery_states`, because doing so omits unseen Skills required for Unlock and Explore.

Instead, every Phase 5.2 read resolves the single active catalog version:

```sql
select cv.version
into v_active_version
from public.learning_catalog_versions cv
where cv.status = 'active';

if v_active_version is null then
  raise exception 'No active learning catalog' using errcode = 'LW501';
end if;
```

The **active-catalog node universe** consists of all active nodes in `v_active_version` whose ancestor chain in `public.learning_nodes` is also active:

- **Subject root `R`:** `R.catalog_version = v_active_version AND R.node_type = 'subject' AND R.is_active = true`
- **Domain `D`:** `D.parent_id = R.id AND D.is_active = true` (with `R` in active universe)
- **Topic `T`:** `T.parent_id = D.id AND T.is_active = true` (with `D` in active universe)
- **Skill `S`:** `S.parent_id = T.id AND S.is_active = true` (with `T` in active universe)

Nodes with `is_active = false` (or an inactive ancestor) are excluded from overview coverage counts, node-state lookups (`P0002`), and Next Challenge candidate generation.

Each active-universe node `n` is `LEFT JOIN`ed to `public.child_mastery_states cms ON cms.child_id = p_child_id AND cms.learning_node_id = n.id`:

| Classification | Predicate | Derived Read-Time Defaults |
|---|---|---|
| **`seen` (`is_observed = true`)** | `cms.learning_node_id IS NOT NULL` (equivalently `cms.effective_evidence_count >= 1`) | `mastery_score = cms.mastery_score` (`0.00..100.00`), `mastery_band` in `{emerging, developing, secure, mastery_candidate, mastered}`, `confidence_band` in `{low, medium, high}`, `freshness` in `{recent, aging, needs_refresh}`, `latest_effective_occurred_at = cms.last_evidence_occurred_at` |
| **`unseen` (`is_observed = false`)** | `cms.learning_node_id IS NULL` (no authoritative child evidence/mastery on this node) | `mastery_score = null`, `mastery_band = null`, `confidence_band = null`, `confidence_units = 0.00`, `freshness = 'unknown'`, `recovery_signal = 'none'`, `latest_effective_occurred_at = null` |

**Invariants:**
- Unseen nodes represent **unknown** knowledge state, NEVER `0%` mastery and NEVER `low` confidence or `needs_refresh`.
- Unseen Skills may participate ONLY in `unlock` or `explore`, NEVER in `recovery`, `refresh`, or `developing`.
- Seen nodes may participate ONLY in `recovery`, `refresh`, or `developing`, NEVER in `unlock` or `explore`.
- Subject and Domain nodes are structural/overview levels and NEVER appear as Next Challenge candidates (`recovery`, `refresh`, `developing` consider `seen` `topic` and `skill` nodes; `unlock` and `explore` consider `unseen` `skill` nodes).

### 4.2 Exact Consumption of Phase 5.1 Mastery & Confidence Semantics

```text
Phase 5.2 is a consumer of Phase 5.1 Mastery/Confidence semantics.
It does not redefine them.
```

For every observed active-catalog node `n` at evaluation `v_as_of`, Phase 5.2 consumes the exact formulas frozen in Phase 5.1 (`private.get_child_mastery_at` / `ConfidenceEngine.evaluate`):

1. **`mastery_score`:** from `cms.mastery_score` (numeric `0.00..100.00`).
2. **`mastery_band`:**
   ```sql
   case
     when cms.mastery_attained_at is not null and cms.mastery_attained_at <= v_as_of then 'mastered'
     when cms.mastery_score >= 85.00 then 'mastery_candidate'
     when cms.mastery_score >= 70.00 then 'secure'
     when cms.mastery_score >= 50.00 then 'developing'
     else 'emerging'
   end
   ```
3. **`confidence_units` and `confidence_band`:**
   Evaluated over `learning_evidence_events` where `child_id = p_child_id AND learning_node_id = n.id AND effective_occurred_at >= v_as_of - interval '60 days' AND effective_occurred_at <= v_as_of AND verified_at <= v_as_of`:
   - `confidence_units = round(sum(specificity_weight * level_weight), 2)`
   - `distinct_recent_vle_count = count(distinct verified_learning_event_id)`
   - `confidence_band`:
     - `'high'` if `confidence_units > 3.50 AND distinct_recent_vle_count >= 2`
     - `'medium'` if `confidence_units >= 1.50` (and not high)
     - `'low'` otherwise (`confidence_units < 1.50` or `distinct_recent_vle_count < 2` when units > 3.50)

In pure Dart domain code, `ConfidenceEngine.evaluate` is reused directly; no separate confidence engine or altered thresholds exist in Phase 5.2.

### 4.3 Version-Scoped Node Identity & Historical Catalog Isolation

1. **Version-scoped node identity:** Every `learning_nodes.id` belongs permanently to one `catalog_version`. Even if a future catalog (`pilot-v0.2`) introduces a node with a similar `canonical_key` or `title`, it has a distinct `id` and distinct version scope.
2. **Active catalog only:** Phase 5.2 overview, node-state, and Next Challenge queries inspect ONLY `catalog_version = v_active_version`.
3. **No cross-version mastery carry-forward in v0.1:** Historical `child_mastery_states` and `learning_evidence_events` attached to nodes in a `retired` catalog version remain preserved in the database for historical auditability and `public.get_child_mastery`, but they MUST NOT satisfy prerequisites, mark nodes as `seen`, or suppress Unlock/Explore candidates in a newly promoted active catalog version. Cross-version lineage/equivalence mapping requires a separate future ADR and design gate.

### 4.4 Catalog Content Scope & Transactional Test Fixtures

- Published `pilot-v0.1` is immutable (`LW102` on mutation). Phase 5.2 implementation MUST NOT alter `pilot-v0.1` or promote `pilot-v0.2`.
- Existing `pilot-v0.1` content already contains all 5 canonical Subject roots (`math`, `english`, `literature`, `science`, `other`), Math hierarchy (`arithmetic -> addition -> {single_digit, double_digit}`) with prerequisite edge `single_digit -> double_digit`, and English hierarchy (`grammar -> punctuation -> end_marks`) with distinct bounded grade ranges.
- Multi-branch DAG topologies, multi-prerequisite fan-in, multi-domain proximity rankings, tie-breakers, and retired-vs-active catalog isolation are verified using **transactional test fixtures** (promoted inside `BEGIN ... ROLLBACK` test blocks in pgTAP / parity harnesses so production/seed `pilot-v0.1` state is never permanently altered). Any curated production catalog expansion beyond `pilot-v0.1` is a separate platform catalog-release task outside Phase 5.2.

---

## 5. Freshness Engine v0.1

### 5.1 Canonical Enum (`MasteryFreshness`)

```text
recent
aging
needs_refresh
unknown
```

### 5.2 Exact Boundary Contract

Given `latest_effective_occurred_at` (`cms.last_evidence_occurred_at` for a `seen` node, or `null` for an `unseen` node) and server-authoritative `as_of`:

1. If `latest_effective_occurred_at IS NULL` (`unseen` node):
   - `freshness = 'unknown'`
   - `days_since_last_evidence = null`
2. Otherwise, compute clamped non-negative elapsed duration:
   - PostgreSQL: `v_elapsed := greatest(interval '0 seconds', v_as_of - v_latest_effective_occurred_at)`
   - Dart: `final elapsed = asOf.isAfter(latestEffectiveOccurredAt) ? asOf.difference(latestEffectiveOccurredAt) : Duration.zero;`
   - Exact boundaries (evaluated at microsecond/second timestamp precision, where `14 days = 1,209,600 seconds` and `45 days = 3,888,000 seconds`):

| Condition | `freshness` |
|---|---|
| `latest_effective_occurred_at == null` | `unknown` |
| `elapsed <= 14 days` (inclusive of exact `14d 00:00:00`) | `recent` |
| `14 days < elapsed <= 45 days` (from `14d + 1µs/1s` through exact `45d 00:00:00`) | `aging` |
| `elapsed > 45 days` (from `45d + 1µs/1s` onward) | `needs_refresh` |

For display metadata (`days_since_last_evidence`), integer whole days are computed as `floor(extract(epoch from v_elapsed) / 86400)` in SQL and `elapsed.inDays` in Dart (`>= 0`). Classification boundaries MUST compare exact `Duration` / `interval` (not truncated integer days) so `14 days + 1 second` classifies as `aging` and `45 days + 1 second` classifies as `needs_refresh`.

### 5.3 Non-Decay Invariant

Time passing NEVER mutates `child_mastery_states.mastery_score` or clears `mastery_attained_at`. In particular:

```text
mastery_band = 'mastered' + elapsed > 45 days
=> mastery_band = 'mastered' AND freshness = 'needs_refresh'
```

No background cron or scheduled freshness mutation job exists.

---

## 6. Recovery Engine v0.1

### 6.1 Canonical Enum (`RecoverySignal`)

```text
none
review_suggested
```

### 6.2 Eligible Node Types & Evidence Sources

- **Node types:** Recovery applies ONLY to `node_type IN ('topic', 'skill')`. For `subject` and `domain` nodes (and all `unseen` nodes), `recovery_signal` is unconditionally `'none'` and `latest_unresolved_weakness_at` is `null`.
- **Allowed evidence sources:** Only `learning_evidence_events` rows for `(p_child_id, n.id)` with `score_source IN ('component_score', 'item_group')`, `effective_occurred_at <= v_as_of`, and `verified_at <= v_as_of` participate in Recovery replay.
- **Forbidden evidence source:** `score_source = 'assessment_total'` (including Subject-root fallback rows) is **completely ignored** by Recovery—it can neither raise `review_suggested` nor clear an active `review_suggested`.

### 6.3 Qualifying Weak & Qualifying Clear Predicates

For each eligible evidence event `ev` (`score_source IN ('component_score', 'item_group')`, `effective_occurred_at <= v_as_of`, `verified_at <= v_as_of`), let `incorrect_count = ev.item_count - ev.correct_count`:

1. **Qualifying weak observation (raises / refreshes `review_suggested`):**
   - `ev.score_source = 'item_group'` AND `ev.performance_pct < 70` AND `ev.item_count IS NOT NULL` AND `ev.correct_count IS NOT NULL` AND `ev.item_count >= 3` AND `(ev.item_count - ev.correct_count) >= 2`; **OR**
   - `ev.score_source = 'component_score'` AND `ev.performance_pct <= 50`.
2. **Qualifying clear observation (resets state to `none`):**
   - `ev.score_source IN ('component_score', 'item_group')` AND `ev.performance_pct >= 70`.
3. **Neutral observation (neither raises nor clears):**
   - Any other allowed-source event (for example, `component_score` with `50 < performance_pct < 70`, or `item_group` with `performance_pct < 70` but `item_count < 3` or `incorrect_count < 2`) leaves the current replay state unchanged. Qualifying weak and qualifying clear predicates are mutually disjoint because `< 70` / `<= 50` and `>= 70` cannot both hold.

### 6.4 Deterministic Canonical Replay Algorithm

For a seen `topic` or `skill` node `n` at `v_as_of`:

1. **Load** all rows from `public.learning_evidence_events` where `child_id = p_child_id`, `learning_node_id = n.id`, `score_source IN ('component_score', 'item_group')`, `effective_occurred_at <= v_as_of`, and `verified_at <= v_as_of`.
2. **Sort** in the frozen Phase 5 canonical academic chronology order:
   ```text
   effective_occurred_at ASC,
   verified_at ASC,
   verified_learning_event_id ASC
   ```
   (where `verified_learning_event_id` uses UUID order / lowercase canonical hyphenated UUID string order).
3. **Replay** sequentially from `state := 'none'`, `latest_weak_at := null`:
   - If `ev` is a **qualifying weak observation**:
     - `state := 'review_suggested'`
     - `latest_weak_at := ev.effective_occurred_at` (a subsequent qualifying weak observation updates `latest_weak_at` to the newer `effective_occurred_at`, extending the 30-day recency window from the latest unresolved weakness).
   - Else if `ev` is a **qualifying clear observation**:
     - `state := 'none'`
     - `latest_weak_at := null`
   - Else (neutral observation): keep `(state, latest_weak_at)` unchanged.
4. **Apply 30-day recency expiry window** relative to `v_as_of`:
   - If `state = 'review_suggested'` AND `v_as_of - latest_weak_at <= interval '30 days'` (inclusive of exact `30 days 00:00:00`, i.e. `latest_weak_at >= v_as_of - interval '30 days'`):
     - Return `(recovery_signal = 'review_suggested', latest_unresolved_weakness_at = latest_weak_at)`.
   - Otherwise (`state = 'none'` OR `v_as_of - latest_weak_at > interval '30 days'`):
     - Return `(recovery_signal = 'none', latest_unresolved_weakness_at = null)`.

---

## 7. Developing vs Refresh Resolution & Mutually Exclusive Recommendation Partition

### 7.1 Resolution of the Blocker

In the preliminary Phase 5 overview (`docs/13` Section 20), `Developing` (`50 <= mastery_score < 85`) was ranked ahead of `Refresh` (`mastery_score >= 70 AND freshness = 'needs_refresh'`), causing stale nodes with scores `70..84.99` to be permanently shadowed by `Developing`. In addition, sticky `Mastered` nodes (`mastery_attained_at <= as_of`) whose numeric `mastery_score` later dipped into `50..84.99` risked ambiguous classification, and 0-prerequisite vs `>= 1`-prerequisite unseen Skills needed an explicit boundary between `Unlock` and `Explore`.

Phase 5.2 resolves all three issues by freezing:
1. Priority order **`1. recovery > 2. refresh > 3. developing > 4. unlock > 5. explore`**; and
2. **Pairwise mutually exclusive eligibility predicates** so every active-catalog node belongs to **at most one** priority class before sorting or `p_limit` slicing.

### 7.2 Frozen Priority Classes & Disjoint Eligibility Predicates

When `p_subject_key IS NOT NULL`, the active-catalog candidate pool is filtered upfront to `node.subject_key = p_subject_key` (while prerequisite attainment and Explore proximity still observe the child's full active-catalog state; by schema invariant, all prerequisites and hierarchy ancestors of a node share its `subject_key`).

For each node `n` in the (optionally subject-filtered) active-catalog universe:

| Rank | `priority_class` | `reason_code` | Eligible `node_type` | Exact Eligibility Predicate |
|---:|---|---|---|---|
| **1** | `recovery` | `recovery_recent_errors` | `topic`, `skill` | `is_observed = true` AND `recovery_signal = 'review_suggested'` |
| **2** | `refresh` | `refresh_stale_secure_skill` | `topic`, `skill` | `is_observed = true` AND `recovery_signal = 'none'` AND `freshness = 'needs_refresh'` AND `mastery_score >= 70.00` |
| **3** | `developing` | `developing_keep_practicing` | `topic`, `skill` | `is_observed = true` AND `recovery_signal = 'none'` AND `freshness != 'needs_refresh'` (i.e. `recent` or `aging`) AND `mastery_score >= 50.00` AND `mastery_score < 85.00` AND `mastery_band != 'mastered'` |
| **4** | `unlock` | `unlock_prerequisites_mastered` | `skill` | `is_observed = false` AND `prerequisite_count >= 1` AND `is_prerequisite_satisfied = true` AND `is_grade_compatible = true` |
| **5** | `explore` | `explore_available_skill` | `skill` | `is_observed = false` AND `prerequisite_count = 0` AND `is_grade_compatible = true` |

### 7.3 Exhaustive Partition Verification (Zero Overlap / Zero Shadowing)

Every active-catalog `topic` or `skill` node falls into **at most one** class:

- **Seen vs Unseen:** Classes 1–3 require `is_observed = true`; Classes 4–5 require `is_observed = false`. Disjoint.
- **Recovery vs Refresh/Developing:** Class 1 requires `recovery_signal = 'review_suggested'`; Classes 2–3 require `recovery_signal = 'none'`. Disjoint.
- **Refresh vs Developing (`70..84.99` overlap resolved):** Class 2 requires `freshness = 'needs_refresh'`; Class 3 requires `freshness != 'needs_refresh'` (`recent` or `aging`). A seen non-mastered skill with `mastery_score = 75.00` practiced `<= 45 days` ago is `developing`; once `> 45 days` elapse without new evidence, it transitions cleanly to `refresh`. Disjoint.
- **Sticky `Mastered` node whose numeric `mastery_score` later dropped `< 85`:**
  - If recent diagnostic errors occurred within 30 days (`review_suggested`), it enters **`recovery`** (Rank 1).
  - Else if `> 45 days` stale and `mastery_score >= 70.00`, it enters **`refresh`** (Rank 2).
  - Else (`mastery_band = 'mastered'`), `mastery_band != 'mastered'` excludes it from **`developing`**, preventing a contradiction where an already-`Mastered` node is labeled `"developing_keep_practicing"`.
- **Fresh high-performing seen nodes (`mastery_score >= 85.00`, `freshness != 'needs_refresh'`, `recovery_signal = 'none'`):** Excluded from Next Challenge (no urgent remediation, refresh, or developing practice needed), freeing slots for `unlock` and `explore`.
- **Stale low-score seen nodes (`mastery_score < 70.00` with `freshness = 'needs_refresh'` and `recovery_signal = 'none'`, or `mastery_score < 50.00` with expired `> 30d` recovery):** Intentionally excluded from Next Challenge in v0.1 so abandoned/old low-score topics from prior terms do not permanently starve grade-appropriate `unlock` / `explore` recommendations once the 30-day Recovery and 45-day active-practice windows expire. Their state remains fully visible in Learning Overview and Node Detail.
- **Unlock vs Explore:** Class 4 requires `prerequisite_count >= 1` (with all prerequisites attained), whereas Class 5 requires `prerequisite_count = 0`. Every unseen, grade-compatible, prerequisite-satisfied Skill belongs to **exactly one** of `unlock` (truthfully unlocked by mastered prerequisites) or `explore` (available entry skill with zero prerequisites). Disjoint.
- **Topic + Child Skill coexistence:** If both a `topic` and one of its child `skill` nodes independently hold seen evidence and qualify (e.g. both have active recovery), both remain distinct node IDs in v0.1 and rank deterministically; ancestor/descendant deduplication is deferred beyond v0.1.

---

## 8. Skill Graph Prerequisite & Dependents Contract

Prerequisite edges exist only between Skills in the same `catalog_version` and `subject_key` (`public.learning_prerequisites`).

### 8.1 Prerequisite Evaluation for Dependent Skill `S`

For an active Skill `S` in `v_active_version`:

1. Let `P(S)` be all rows `lp` in `public.learning_prerequisites` where `lp.catalog_version = v_active_version AND lp.dependent_node_id = S.id`, joined to `prereq` in `public.learning_nodes` (`prereq.id = lp.prerequisite_node_id AND prereq.catalog_version = v_active_version`).
2. `prerequisite_count = count(P(S))`.
3. A prerequisite row `p ∈ P(S)` is **attained at `v_as_of`** if and only if:
   - `p.prereq` belongs to the active-catalog universe (`is_active = true` with active ancestor chain), **AND**
   - `public.child_mastery_states` has a row `cms_p` for `(p_child_id, p.prerequisite_node_id)` satisfying:
     ```sql
     cms_p.mastery_attained_at is not null
     and cms_p.mastery_attained_at <= v_as_of
     ```
4. `attained_prerequisite_count` is the count of rows in `P(S)` attained at `v_as_of`.
5. `is_prerequisite_satisfied` holds if and only if `attained_prerequisite_count = prerequisite_count` (every explicit prerequisite edge is attained at `v_as_of`).

#### Frozen Prerequisite Contract Rules

- **Sticky attainment is sufficient and necessary:** Prerequisite satisfaction does **NOT** require the prerequisite Skill's current 60-day `confidence_band` to remain `'high'`, and does **NOT** require the prerequisite Skill's current `mastery_score` to remain `>= 85.00` after historical attainment. Once `mastery_attained_at <= v_as_of`, the prerequisite remains satisfied permanently within that catalog version.
- **Mastery Candidate (`mastery_score >= 85` with `mastery_attained_at IS NULL` or `> v_as_of`) is NOT attained:** Unattained high scores do not unlock dependent Skills.
- **Inactive prerequisite fails closed:** If a draft catalog ever deactivated a prerequisite Skill (`is_active = false`) while leaving an incoming edge to `S`, that edge is not attained and `S` fails closed (`is_prerequisite_satisfied = false`).
- **Zero prerequisites (`prerequisite_count = 0`):** `attained_prerequisite_count = 0` and `is_prerequisite_satisfied = true`. The Skill is not blocked by the prerequisite DAG; grade filtering still applies, and when unseen and grade-compatible it classifies under **`explore`** (`explore_available_skill`).

### 8.2 Outgoing Dependents Contract (`prerequisite_state.dependents`)

In `get_node_learning_state`, the `prerequisite_state.dependents` array exposes Skills in the active catalog that depend directly on the inspected node:

1. **For a Skill node `S`:**
   `dependents` = all active-catalog Skills `D` in `v_active_version` where:
   - an edge exists in `public.learning_prerequisites`: `prerequisite_node_id = S.id AND dependent_node_id = D.id`,
   - `D` belongs to the active-catalog universe (`D.is_active = true` with active ancestor chain `R -> Domain -> Topic -> D`).
2. **Payload structure for each dependent item:**
   Each item in `dependents` contains exactly:
   ```json
   {
     "learning_node_id": "uuid",
     "canonical_key": "text",
     "title": "text",
     "grade_min": 2,
     "grade_max": 4,
     "is_observed": false,
     "is_grade_compatible": true,
     "prerequisite_count": 1,
     "attained_prerequisite_count": 1,
     "is_prerequisite_satisfied": true
   }
   ```
3. **Unlocked definition:** A dependent Skill is "unlocked" from the child's perspective if and only if:
   ```text
   is_observed = false
   AND is_grade_compatible = true
   AND is_prerequisite_satisfied = true
   ```
4. **Deterministic ordering:** `dependents` is ordered by:
   ```text
   catalog_sort_path ASC,
   learning_node_id ASC
   ```
5. **Non-Skill nodes (`subject`, `domain`, `topic`):**
   `prerequisite_state.applicable = false`, `prerequisites = []`, `dependents = []`.

---

## 9. Grade Filtering Contract

Grade filtering for `unlock` and `explore` uses the child's **current** profile grade:

```text
public.child_profiles.school_grade   -- smallint NULL CHECK (school_grade BETWEEN 1 AND 12)
```

It never infers current grade from historical `learning_evidence_events.grade_level_snapshot`.

For any node `n` with `grade_min` (`0..12` nullable) and `grade_max` (`0..12` nullable), `is_grade_compatible(school_grade, n.grade_min, n.grade_max)` is defined as:

1. **Unbounded node (`n.grade_min IS NULL AND n.grade_max IS NULL`):**
   - `is_grade_compatible = true` (always compatible, even when `school_grade IS NULL`).
2. **Grade-scoped node (`n.grade_min IS NOT NULL OR n.grade_max IS NOT NULL`):**
   - If `school_grade IS NULL`: `is_grade_compatible = false` (**fails closed**).
   - Otherwise:
     ```sql
     (n.grade_min is null or school_grade >= n.grade_min)
     and (n.grade_max is null or school_grade <= n.grade_max)
     ```
     (inclusive on both `grade_min` and `grade_max`).

**Scope of grade filter:**
- **`unlock` and `explore`:** Require `is_grade_compatible = true`.
- **`recovery`, `refresh`, and `developing`:** Evidence-driven; do **NOT** filter by `school_grade` and continue to operate normally when `school_grade IS NULL` or after a child's profile grade advances past a previously practiced skill's grade band.

---

## 10. Explore Eligibility & Deterministic Proximity Ranking

An active-catalog Skill `S` (with parent Topic `T`, grandparent Domain `D`, and Subject root `R` of `S.subject_key`) is **Explore-eligible** when:

- `S` is in the active-catalog universe (`is_active = true` with active ancestor chain `R -> D -> T -> S`),
- `is_observed = false` (`unseen`),
- `prerequisite_count = 0` (hence `is_prerequisite_satisfied = true` and disjoint from `unlock`),
- `is_grade_compatible = true`, and
- (`p_subject_key IS NULL OR S.subject_key = p_subject_key`).

To operationalize `"nearby Skill"` deterministically without randomness or fuzzy heuristics, every Explore-eligible Skill is assigned an integer **`explore_proximity_rank` in `{0, 1, 2, 3}`** computed against the child's `seen` active-catalog nodes (`cms.learning_node_id IS NOT NULL`):

| `explore_proximity_rank` | Meaning | Exact Predicate |
|---:|---|---|
| **`0`** | **Same Topic as a seen Skill** | At least one active `skill` node `s2` in `v_active_version` with `s2.parent_id = T.id` is `seen` by `p_child_id`. |
| **`1`** | **Same Domain as seen Topic/Domain/Skill evidence** | Not rank `0`, and within Domain `D` either `D` itself is `seen`, any active `topic` under `D` (including `T` itself when mapped at Topic level) is `seen`, or any active `skill` under any active `topic` of `D` is `seen`. |
| **`2`** | **Same Subject has seen evidence** | Not rank `0` or `1`, and at least one active node in `v_active_version` with `subject_key = S.subject_key` (including Subject root `R` from Subject-fallback verified assessments) is `seen`. |
| **`3`** | **Unexplored Subject (cold start)** | Zero active nodes in `v_active_version` with `subject_key = S.subject_key` are `seen` by `p_child_id`. |

Lower `explore_proximity_rank` sorts first (`0 < 1 < 2 < 3`). Ties within the same `explore_proximity_rank` fall through to the global catalog hierarchy sort order and `learning_node_id` tie-break (§11).

---

## 11. Next Challenge Priority, Reason Codes & Global Total Comparator

### 11.1 Result Cap & Reason Codes

- Maximum returned candidates: **`3`** (`p_limit` default `3`, valid range `1..3`).
- Frozen `priority_class` -> `reason_code` 1-to-1 mapping:
  - `recovery` -> `recovery_recent_errors`
  - `refresh` -> `refresh_stale_secure_skill`
  - `developing` -> `developing_keep_practicing`
  - `unlock` -> `unlock_prerequisites_mastered`
  - `explore` -> `explore_available_skill`

### 11.2 Hierarchy `catalog_sort_path`

Because `learning_nodes.sort_order` is a sibling ordinal within `parent_id` (for example, in `pilot-v0.1`, both Math `single_digit` and English `end_marks` have `node.sort_order = 1`, while Subject roots have `math = 1, english = 2, literature = 3, science = 4, other = 5`), every active-catalog node carries a canonical integer array **`catalog_sort_path`**:

- **Subject `R`:** `[R.sort_order]`
- **Domain `D`:** `[R.sort_order, D.sort_order]`
- **Topic `T`:** `[R.sort_order, D.sort_order, T.sort_order]`
- **Skill `S`:** `[R.sort_order, D.sort_order, T.sort_order, S.sort_order]`

`catalog_sort_path` is compared lexicographically element-by-element (`int` ascending), with a shorter prefix sorting before a longer extension (`[1, 1, 1] < [1, 1, 1, 1]`). This matches PostgreSQL native `integer[]` `<` comparison and reduces identically to `node.sort_order ASC` whenever two nodes share the same parent.

### 11.3 Frozen Global Total Comparator

All eligible candidates across the 5 disjoint classes are ordered by a single deterministic total comparator before taking `LIMIT p_limit`:

1. **`priority_rank ASC`:**
   `recovery (1) < refresh (2) < developing (3) < unlock (4) < explore (5)`
2. **Class-specific rank (evaluated when two candidates share `priority_rank`):**
   - `recovery`: **`latest_unresolved_weakness_at DESC`** (most recent diagnostic weakness first)
   - `refresh`: **`latest_effective_occurred_at ASC`** (oldest stale secure skill first)
   - `developing`: **`mastery_score_hundredths ASC`** (`round(mastery_score * 100)` integer comparison; lowest developing score `50.00..84.99` first)
   - `unlock`: **`0`** (no extra scalar key; orders directly by `catalog_sort_path ASC`, i.e. curriculum graph sort order)
   - `explore`: **`explore_proximity_rank ASC`** (`0 < 1 < 2 < 3`)
3. **`catalog_sort_path ASC`** (`[subject_sort_order, domain_sort_order, topic_sort_order, skill_sort_order]` lexicographic integer-array order, whose final element is `node.sort_order ASC`)
4. **`learning_node_id ASC`** (PostgreSQL `uuid` byte comparison, which is identical to lowercase canonical 36-character hyphenated UUID ASCII string comparison in Dart).

Because `learning_node_id` is a primary key, this comparator is a **strict total order**—no two distinct candidates can ever tie. Random shuffling is forbidden.

---

## 12. Recommended Difficulty Heuristic

Phase 5.2 reuses the frozen assessment difficulty vocabulary from Phase 2 / Phase 5.1 (`AssessmentDifficulty` / SQL `difficulty` check):

```text
below_level
normal
hard
challenge
```

No new difficulty strings are introduced.

### 12.1 Next Challenge Candidate Difficulty Mapping (Exact Deterministic Table)

Every Next Challenge candidate receives a non-null `recommended_difficulty` determined strictly by `(priority_class, mastery_score)`:

| `priority_class` | Condition | `recommended_difficulty` | Pedagogical Rationale |
|---|---|---|---|
| `recovery` | always | `below_level` | Step-down scaffolding to isolate and repair recent diagnostic errors |
| `refresh` | always (`mastery_score >= 70.00`, stale `> 45d`) | `normal` | Standard on-level retention check after > 45 days without evidence |
| `developing` | `50.00 <= mastery_score < 70.00` | `normal` | Consolidate developing accuracy at standard level |
| `developing` | `70.00 <= mastery_score < 85.00` | `hard` | Stretch a secure (`70..84.99`) skill toward the `85` mastery threshold |
| `unlock` | always (`unseen`, prerequisites mastered) | `normal` | First exposure to a newly unlocked dependent Skill |
| `explore` | always (`unseen`, 0 prerequisites) | `normal` | First exposure to an available entry Skill |

### 12.2 Node Detail Difficulty Mapping (`get_node_learning_state`)

In `get_node_learning_state`, `state.recommended_difficulty` is derived as follows:

```text
Subject / Domain:
  recommended_difficulty = null

Unseen Topic:
  recommended_difficulty = null

Unseen Skill:
  if eligible for unlock or explore:
    recommended_difficulty = 'normal'
  else:
    recommended_difficulty = null (e.g. locked or grade-incompatible unseen skill)

Observed Topic / Skill:
  if recovery:
    recommended_difficulty = 'below_level'
  else if refresh:
    recommended_difficulty = 'normal'
  else if developing (50.00 <= mastery_score < 70.00):
    recommended_difficulty = 'normal'
  else if developing (70.00 <= mastery_score < 85.00):
    recommended_difficulty = 'hard'
  else if fresh high mastery (score >= 85.00 OR mastery_band = 'mastered') with no recovery:
    challenge if score >= 90.00 AND confidence_band = 'high'
    hard otherwise
  else (observed topic/skill with score < 70.00, no recovery, e.g. stale < 70 or < 50 with expired recovery):
    recommended_difficulty = 'normal'
```

---

## 13. Read-Only RPC Signatures, Error Codes & Security Model

### 13.1 Exact Client-Facing RPC Signatures

```sql
public.get_child_learning_overview(
  p_child_id uuid
) returns jsonb

public.get_node_learning_state(
  p_child_id uuid,
  p_learning_node_id uuid
) returns jsonb

public.get_next_challenge_candidates(
  p_child_id uuid,
  p_subject_key text default null,
  p_limit integer default 3
) returns jsonb
```

All three functions are declared:
```sql
language plpgsql
stable
security definer
set search_path = ''
```
with every table and helper fully schema-qualified (`public.*`, `private.*`, `auth.uid()`).

### 13.2 Privileges & Grants

```sql
revoke all on function public.get_child_learning_overview(uuid) from public, anon;
grant execute on function public.get_child_learning_overview(uuid) to authenticated, service_role;

revoke all on function public.get_node_learning_state(uuid, uuid) from public, anon;
grant execute on function public.get_node_learning_state(uuid, uuid) to authenticated, service_role;

revoke all on function public.get_next_challenge_candidates(uuid, text, integer) from public, anon;
grant execute on function public.get_next_challenge_candidates(uuid, text, integer) to authenticated, service_role;

revoke all on function private.get_child_learning_overview_at(uuid, timestamptz) from public, anon, authenticated;
revoke all on function private.get_node_learning_state_at(uuid, uuid, timestamptz) from public, anon, authenticated;
revoke all on function private.get_next_challenge_candidates_at(uuid, text, integer, timestamptz) from public, anon, authenticated;
```

### 13.3 Validation & Authorization Order (Fail-Closed Contract)

Every `public.*` RPC executes checks in this exact deterministic sequence before reading learning state:

1. **Parameter validation (`SQLSTATE '22000'`):**
   - `p_child_id IS NULL` -> raise `'Child ID is required'` (`22000`).
   - (`get_node_learning_state`) `p_learning_node_id IS NULL` -> raise `'Learning node ID is required'` (`22000`).
   - (`get_next_challenge_candidates`) `p_limit IS NULL OR p_limit < 1 OR p_limit > 3` -> **reject** (never clamp): raise `'Candidate limit must be between 1 and 3'` (`22000`).
   - (`get_next_challenge_candidates`) `p_subject_key IS NOT NULL AND p_subject_key NOT IN ('math', 'english', 'literature', 'science', 'other')` -> **reject**: raise `'Invalid subject_key'` (`22000`).
2. **Authentication check (`SQLSTATE '42501'`):**
   - `IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501'; END IF;`
3. **Server-derived tenancy & active child check (`SQLSTATE 'P0002'`):**
   - Query `SELECT id, family_id, school_grade FROM public.child_profiles WHERE id = p_child_id AND status = 'active'`.
   - If not found -> raise `'Child profile not found'` (`P0002`). Caller-supplied `family_id` is never accepted.
4. **Family adult or exact paired-child authorization (`SQLSTATE '42501'`):**
   - Require `private.is_active_family_adult(v_child.family_id) OR private.is_active_child_device(v_child.family_id, p_child_id)`.
   - Otherwise -> raise `'Permission denied'` (`42501`).
   - This enforces **sibling isolation** (paired device for Child A is denied `42501` on Child B in the same family) and **cross-family isolation** (active adult in Family A is denied `42501` on Child in Family B).
5. **Active catalog check (`SQLSTATE 'LW501'`):**
   - Resolve `v_active_version` where `status = 'active'`; if absent -> raise `'No active learning catalog'` (`LW501`).
6. **Active node check (`get_node_learning_state` only, `SQLSTATE 'P0002'`):**
   - Verify `p_learning_node_id` belongs to the active-catalog universe (`catalog_version = v_active_version` and active ancestor chain `is_active = true`); if absent (including nodes from retired/draft catalogs or inactive nodes) -> raise `'Learning node not found in active catalog'` (`P0002`).
7. **Single clock capture & delegation:**
   - Capture `v_as_of := transaction_timestamp();` and invoke `private.*_at(..., v_as_of)`.

---

## 14. Canonical Response Schemas & Coverage Presentation

### 14.1 Coverage & Anti-Averaging Rule

- **Missing skills are unknown, NOT zero.** Unseen Topics and Skills carry `is_observed: false`, `mastery_score: null`, `mastery_band: null`, `confidence_band: null`, `freshness: "unknown"`.
- **No naive universal subject average:** None of the RPCs or UI surfaces may compute or display an arithmetic mean across child skills/topics (such as `"Math mastery = 73.42%"`).
- **Direct Subject-root state vs descendant coverage remain distinct:** Each Subject item exposes:
  1. `subject_state`: direct observation state on the Subject root node itself (populated by Phase 5.1 Subject-fallback or explicit Subject-level mappings), and
  2. `coverage`: explicit counts of `total_*`, `observed_*`, and `unseen_*` Domains, Topics, and Skills, observed Skill band breakdown (`mastered_skills`, `mastery_candidate_skills`, `secure_skills`, `developing_skills`, `emerging_skills`), `needs_refresh_count` (observed Topics + Skills in that Subject with `freshness = 'needs_refresh'`), and `active_recovery_count` (observed Topics + Skills in that Subject with `recovery_signal = 'review_suggested'`).

### 14.2 `public.get_child_learning_overview(p_child_id)` Canonical JSON Schema

```json
{
  "child_id": "c0000000-0000-0000-0000-000000000001",
  "school_grade": 2,
  "active_catalog_version": "pilot-v0.1",
  "as_of": "2026-11-03T03:00:00.000000Z",
  "overall_coverage": {
    "total_topics": 2,
    "observed_topics": 0,
    "unseen_topics": 2,
    "total_skills": 3,
    "observed_skills": 1,
    "unseen_skills": 2,
    "mastered_skills": 1,
    "mastery_candidate_skills": 0,
    "secure_skills": 0,
    "developing_skills": 0,
    "emerging_skills": 0,
    "needs_refresh_count": 0,
    "active_recovery_count": 0
  },
  "subjects": [
    {
      "subject_node_id": "uuid",
      "subject_key": "math",
      "canonical_key": "pilot-v0.1:subject:math",
      "title": "Mathematics",
      "sort_order": 1,
      "subject_state": {
        "is_observed": true,
        "mastery_score": 92.00,
        "mastery_band": "mastery_candidate",
        "confidence_band": "low",
        "confidence_units": 0.70,
        "freshness": "recent",
        "effective_evidence_count": 2,
        "distinct_assessment_count": 2,
        "latest_effective_occurred_at": "2026-11-02T10:00:00.000000Z",
        "mastery_attained_at": null
      },
      "coverage": {
        "total_domains": 1,
        "observed_domains": 0,
        "unseen_domains": 1,
        "total_topics": 1,
        "observed_topics": 0,
        "unseen_topics": 1,
        "total_skills": 2,
        "observed_skills": 1,
        "unseen_skills": 1,
        "mastered_skills": 1,
        "mastery_candidate_skills": 0,
        "secure_skills": 0,
        "developing_skills": 0,
        "emerging_skills": 0,
        "needs_refresh_count": 0,
        "active_recovery_count": 0
      },
      "topics": [
        {
          "learning_node_id": "b0000002-0000-0000-0000-000000000001",
          "domain_node_id": "b0000001-0000-0000-0000-000000000001",
          "domain_title": "Arithmetic & Numbers",
          "canonical_key": "pilot-v0.1:math:arithmetic:addition",
          "title": "Addition Operations",
          "grade_min": 1,
          "grade_max": 4,
          "sort_order": 1,
          "catalog_sort_path": [1, 1, 1],
          "is_observed": false,
          "mastery_score": null,
          "mastery_band": null,
          "confidence_band": null,
          "confidence_units": 0.00,
          "freshness": "unknown",
          "recovery_signal": "none",
          "latest_effective_occurred_at": null,
          "mastery_attained_at": null,
          "skill_coverage": {
            "total_skills": 2,
            "observed_skills": 1,
            "unseen_skills": 1,
            "mastered_skills": 1,
            "needs_refresh_skills": 0,
            "active_recovery_skills": 0
          },
          "skills": [
            {
              "learning_node_id": "b0000003-0000-0000-0000-000000000001",
              "canonical_key": "pilot-v0.1:math:arithmetic:addition:single_digit",
              "title": "Single Digit Addition",
              "grade_min": 1,
              "grade_max": 2,
              "sort_order": 1,
              "catalog_sort_path": [1, 1, 1, 1],
              "is_observed": true,
              "mastery_score": 92.00,
              "mastery_band": "mastered",
              "confidence_band": "high",
              "confidence_units": 4.00,
              "freshness": "recent",
              "recovery_signal": "none",
              "latest_effective_occurred_at": "2026-11-02T10:00:00.000000Z",
              "mastery_attained_at": "2026-11-02T10:05:00.000000Z",
              "prerequisite_count": 0,
              "attained_prerequisite_count": 0,
              "is_prerequisite_satisfied": true,
              "is_grade_compatible": true
            }
          ]
        }
      ]
    }
  ]
}
```

Ordering inside `get_child_learning_overview`:
- `subjects[]`: ordered by `subject.sort_order ASC, subject_node_id ASC` (all 5 active Subject roots always present).
- `topics[]` within each Subject: ordered by `catalog_sort_path ASC, learning_node_id ASC`.
- `skills[]` within each Topic: ordered by `catalog_sort_path ASC, learning_node_id ASC`.

### 14.3 `public.get_node_learning_state(p_child_id, p_learning_node_id)` Canonical JSON Schema

#### Example 1: Skill Node State (Showing Prerequisites and Dependents)

```json
{
  "child_id": "c0000000-0000-0000-0000-000000000001",
  "school_grade": 2,
  "active_catalog_version": "pilot-v0.1",
  "as_of": "2026-11-03T03:00:00.000000Z",
  "node": {
    "learning_node_id": "b0000003-0000-0000-0000-000000000001",
    "catalog_version": "pilot-v0.1",
    "node_type": "skill",
    "subject_key": "math",
    "canonical_key": "pilot-v0.1:math:arithmetic:addition:single_digit",
    "title": "Single Digit Addition",
    "parent_id": "b0000002-0000-0000-0000-000000000001",
    "parent_topic_id": "b0000002-0000-0000-0000-000000000001",
    "parent_topic_title": "Addition Operations",
    "parent_domain_id": "b0000001-0000-0000-0000-000000000001",
    "parent_domain_title": "Arithmetic & Numbers",
    "subject_node_id": "uuid",
    "grade_min": 1,
    "grade_max": 2,
    "sort_order": 1,
    "catalog_sort_path": [1, 1, 1, 1]
  },
  "state": {
    "is_observed": true,
    "mastery_score": 92.00,
    "mastery_band": "mastered",
    "mastery_attained_at": "2026-11-02T10:05:00.000000Z",
    "confidence_band": "high",
    "confidence_units": 4.00,
    "distinct_recent_vle_count": 2,
    "effective_evidence_count": 2,
    "distinct_assessment_count": 2,
    "freshness": "recent",
    "days_since_last_evidence": 0,
    "recovery_signal": "none",
    "latest_unresolved_weakness_at": null,
    "recommended_difficulty": "challenge",
    "is_grade_compatible": true
  },
  "latest_evidence": {
    "evidence_event_id": "uuid",
    "verified_learning_event_id": "uuid",
    "assessment_id": "uuid",
    "score_source": "component_score",
    "performance_pct": 95.00,
    "difficulty": "normal",
    "item_count": null,
    "correct_count": null,
    "effective_occurred_at": "2026-11-02T10:00:00.000000Z",
    "verified_at": "2026-11-02T10:05:00.000000Z"
  },
  "coverage": {
    "total_descendant_topics": 0,
    "observed_descendant_topics": 0,
    "unseen_descendant_topics": 0,
    "total_descendant_skills": 0,
    "observed_descendant_skills": 0,
    "unseen_descendant_skills": 0
  },
  "prerequisite_state": {
    "applicable": true,
    "prerequisite_count": 0,
    "attained_prerequisite_count": 0,
    "is_satisfied": true,
    "prerequisites": [],
    "dependents": [
      {
        "learning_node_id": "b0000003-0000-0000-0000-000000000002",
        "canonical_key": "pilot-v0.1:math:arithmetic:addition:double_digit",
        "title": "Double Digit Addition",
        "grade_min": 2,
        "grade_max": 4,
        "is_observed": false,
        "is_grade_compatible": true,
        "prerequisite_count": 1,
        "attained_prerequisite_count": 1,
        "is_prerequisite_satisfied": true
      }
    ]
  }
}
```

#### Example 2: Unseen Topic State (`recommended_difficulty = null`)

```json
{
  "child_id": "c0000000-0000-0000-0000-000000000001",
  "school_grade": 2,
  "active_catalog_version": "pilot-v0.1",
  "as_of": "2026-11-03T03:00:00.000000Z",
  "node": {
    "learning_node_id": "b0000002-0000-0000-0000-000000000001",
    "catalog_version": "pilot-v0.1",
    "node_type": "topic",
    "subject_key": "math",
    "canonical_key": "pilot-v0.1:math:arithmetic:addition",
    "title": "Addition Operations",
    "parent_id": "b0000001-0000-0000-0000-000000000001",
    "parent_topic_id": null,
    "parent_topic_title": null,
    "parent_domain_id": "b0000001-0000-0000-0000-000000000001",
    "parent_domain_title": "Arithmetic & Numbers",
    "subject_node_id": "uuid",
    "grade_min": 1,
    "grade_max": 4,
    "sort_order": 1,
    "catalog_sort_path": [1, 1, 1]
  },
  "state": {
    "is_observed": false,
    "mastery_score": null,
    "mastery_band": null,
    "mastery_attained_at": null,
    "confidence_band": null,
    "confidence_units": 0.00,
    "distinct_recent_vle_count": 0,
    "effective_evidence_count": 0,
    "distinct_assessment_count": 0,
    "freshness": "unknown",
    "days_since_last_evidence": null,
    "recovery_signal": "none",
    "latest_unresolved_weakness_at": null,
    "recommended_difficulty": null,
    "is_grade_compatible": true
  },
  "latest_evidence": null,
  "coverage": {
    "total_descendant_topics": 0,
    "observed_descendant_topics": 0,
    "unseen_descendant_topics": 0,
    "total_descendant_skills": 2,
    "observed_descendant_skills": 1,
    "unseen_descendant_skills": 1
  },
  "prerequisite_state": {
    "applicable": false,
    "prerequisite_count": 0,
    "attained_prerequisite_count": 0,
    "is_satisfied": true,
    "prerequisites": [],
    "dependents": []
  }
}
```

### 14.4 `public.get_next_challenge_candidates(p_child_id, p_subject_key, p_limit)` Canonical JSON Schema

```json
{
  "child_id": "c0000000-0000-0000-0000-000000000001",
  "school_grade": 2,
  "active_catalog_version": "pilot-v0.1",
  "subject_key_filter": null,
  "limit": 3,
  "as_of": "2026-11-03T03:00:00.000000Z",
  "candidates": [
    {
      "rank": 1,
      "learning_node_id": "b0000003-0000-0000-0000-000000000002",
      "catalog_version": "pilot-v0.1",
      "canonical_key": "pilot-v0.1:math:arithmetic:addition:double_digit",
      "title": "Double Digit Addition",
      "node_type": "skill",
      "subject_key": "math",
      "parent_topic_id": "b0000002-0000-0000-0000-000000000001",
      "parent_topic_title": "Addition Operations",
      "parent_domain_id": "b0000001-0000-0000-0000-000000000001",
      "parent_domain_title": "Arithmetic & Numbers",
      "grade_min": 2,
      "grade_max": 4,
      "sort_order": 2,
      "catalog_sort_path": [1, 1, 1, 2],
      "priority_class": "unlock",
      "reason_code": "unlock_prerequisites_mastered",
      "recommended_difficulty": "normal",
      "is_observed": false,
      "mastery_score": null,
      "mastery_band": null,
      "confidence_band": null,
      "freshness": "unknown",
      "recovery_signal": "none",
      "explanation": {
        "latest_effective_occurred_at": null,
        "days_since_last_evidence": null,
        "latest_unresolved_weakness_at": null,
        "prerequisite_count": 1,
        "attained_prerequisite_titles": ["Single Digit Addition"],
        "explore_proximity_rank": null
      },
      "as_of": "2026-11-03T03:00:00.000000Z"
    }
  ]
}
```

Note on `parent_topic_id`: for a `skill` candidate, `parent_topic_id` is `node.parent_id` and `parent_domain_id` is the Topic's `parent_id`; for a `topic` candidate (`recovery`, `refresh`, or `developing` on a Topic), `parent_topic_id` is `null` (`parent_topic_title = null`) and `parent_domain_id` is `node.parent_id`. `candidates` contains between `0` and `p_limit` (`<= 3`) distinct items ordered by `rank` (`1..k`).

---

## 15. Pure Dart Domain Model & Deterministic Engines

All Phase 5.2 domain additions live in `packages/learnward_domain/lib/src/learning/` with zero Flutter, Riverpod, Supabase, or Drift dependencies.

### 15.1 Enums (`learning_enums.dart`)

- **`MasteryFreshness`**: `recent('recent')`, `aging('aging')`, `needsRefresh('needs_refresh')`, `unknown('unknown')`
- **`RecoverySignal`**: `none('none')`, `reviewSuggested('review_suggested')`
- **`RecommendationPriority`**: `recovery('recovery', 1)`, `refresh('refresh', 2)`, `developing('developing', 3)`, `unlock('unlock', 4)`, `explore('explore', 5)`
- **`NextChallengeReason`**:
  - `recoveryRecentErrors('recovery_recent_errors')`
  - `refreshStaleSecureSkill('refresh_stale_secure_skill')`
  - `developingKeepPracticing('developing_keep_practicing')`
  - `unlockPrerequisitesMastered('unlock_prerequisites_mastered')`
  - `exploreAvailableSkill('explore_available_skill')`
- **`RecommendedDifficulty`**: reuses the frozen 4-value difficulty vocabulary (`belowLevel('below_level')`, `normal('normal')`, `hard('hard')`, `challenge('challenge')` — aligned 1:1 with `AssessmentDifficulty`).

### 15.2 Value Objects & Read Projections (`learning_recommendation_models.dart`)

- `FreshnessEvaluation`: `(MasteryFreshness freshness, int? daysSinceLastEvidence)`
- `RecoveryEvaluation`: `(RecoverySignal signal, DateTime? latestUnresolvedWeaknessAt)`
- `LearningCoverage`: observed vs unseen counts, Skill mastery-band counts, `needsRefreshCount`, `activeRecoveryCount`
- `LearningPrerequisiteItem`: `(String learningNodeId, String canonicalKey, String title, bool isObserved, double? masteryScore, MasteryBand? masteryBand, DateTime? masteryAttainedAt, bool isAttained)`
- `LearningDependentItem`: `(String learningNodeId, String canonicalKey, String title, int? gradeMin, int? gradeMax, bool isObserved, bool isGradeCompatible, int prerequisiteCount, int attainedPrerequisiteCount, bool isPrerequisiteSatisfied)`
- `NodePrerequisiteState`: `(bool applicable, int prerequisiteCount, int attainedPrerequisiteCount, bool isSatisfied, List<LearningPrerequisiteItem> prerequisites, List<LearningDependentItem> dependents)`
- `LatestLearningEvidenceSummary`: snapshot of latest canonical `LearningEvidenceEvent`
- `LearningNodeState`: canonical domain representation of `get_node_learning_state`, with `RecommendedDifficulty? recommendedDifficulty` (nullable for unseen non-Skills and locked unseen Skills)
- `LearningTopicOverview`, `LearningSubjectOverview`, `LearningOverview`: canonical domain representation of `get_child_learning_overview`
- `NextChallengeExplanation`, `NextChallengeCandidate`, `NextChallengeRecommendationSet`: canonical domain representation of `get_next_challenge_candidates`

### 15.3 Pure Deterministic Engines

1. **`FreshnessEngine` (`freshness_engine.dart`):**
   - `static FreshnessEvaluation evaluate({required DateTime? latestEffectiveOccurredAt, required DateTime asOf})`
   - Exact `Duration(days: 14)` and `Duration(days: 45)` boundaries with non-negative elapsed clamping.
2. **`RecoveryEngine` (`recovery_engine.dart`):**
   - `static RecoveryEvaluation evaluate({required LearningNodeType nodeType, required Iterable<LearningEvidenceEvent> evidence, required DateTime asOf})`
   - Filters `nodeType` to `{topic, skill}`, filters `evidence` to `scoreSource in {componentScore, itemGroup}`, `!effectiveOccurredAt.isAfter(asOf)`, and `!verifiedAt.isAfter(asOf)`, sorts via `MasteryEngine.sortCanonical`, replays weak/clear transitions, and enforces the 30-day recency window (`asOf.difference(latestWeakAt) <= const Duration(days: 30)`).
3. **`NextChallengeEngine` (`next_challenge_engine.dart`):**
   - Pure methods for:
     - active-catalog universe assembly & active-ancestor filtering,
     - `isGradeCompatible({required int? schoolGrade, required int? gradeMin, required int? gradeMax})`,
     - prerequisite satisfaction (`masteryAttainedAt != null && !masteryAttainedAt.isAfter(asOf)`),
     - dependents evaluation with deterministic sorting,
     - Explore proximity rank `0..3`,
     - Recommended difficulty mapping (§12),
     - candidate generation, total comparator sorting (§11.3), and `limit` (`1..3`) validation,
     - `buildOverview(...)` and `buildNodeState(...)` for full Dart/PostgreSQL parity across all three read models.

---

## 16. Application Ports, Use Cases & Data Layer

### 16.1 Repository Port Extension (`LearningRepository`)

Extend `packages/learnward_application/lib/src/ports/learning_repository.dart` with three read-only methods (without adding any dependency on `RewardRepository`, `WheelRepository`, or `GrowthRepository`):

```dart
Future<LearningOverview> getChildLearningOverview(ChildId childId);

Future<LearningNodeState> getNodeLearningState({
  required ChildId childId,
  required String learningNodeId,
});

Future<NextChallengeRecommendationSet> getNextChallengeCandidates({
  required ChildId childId,
  SubjectKey? subjectKey,
  int limit = 3,
});
```

### 16.2 Application Use Cases (`packages/learnward_application/lib/src/use_cases/learning/`)

- `GetChildLearningOverviewUseCase`
- `GetNodeLearningStateUseCase` (validates non-empty `learningNodeId`)
- `GetNextChallengeCandidatesUseCase` (validates `1 <= limit <= 3` fail-closed before calling port)

### 16.3 Data Adapter & In-Memory Parity (`packages/learnward_data` & `apps/mobile`)

- `SupabaseLearningRepository` invokes `public.get_child_learning_overview`, `public.get_node_learning_state`, and `public.get_next_challenge_candidates`, mapping JSON responses via strict DTO parsers.
- `InMemoryLearningRepository` (development demo mode only) and `FakeLearningRepository` (`learnward_test_support`) delegate directly to pure `NextChallengeEngine`, `FreshnessEngine`, and `RecoveryEngine` with an injectable clock so local widget tests and offline demo flows obey the exact same rules as PostgreSQL.

---

## 17. Flutter Presentation & Child Choice UI

Phase 5.2 adds calm, honest, non-manipulative UI surfaces in `apps/mobile/lib/features/learning/`:

1. **Parent Learning Overview Screen:**
   - Displays all 5 canonical Subjects from `getChildLearningOverview`.
   - Shows explicit coverage (`"Observed 1 of 2 tracked skills"` + `"1 unseen"`), direct Subject-root state when present, `Needs refresh` badge counts without score decay, and gentle `"Review suggested"` badges—never a naive subject-wide percentage average.
   - Tapping any Topic or Skill opens the **Node Learning Detail Screen**.
2. **Node Learning Detail Screen (Parent & Paired Child read-only):**
   - Calls `getNodeLearningState`.
   - Displays Mastery band & score (or `"Not yet observed"` when `isObserved == false`), Confidence band & explanation, Freshness badge (`Recent`, `Aging`, `Needs refresh` alongside preserved Mastery band, or `Unknown`), gentle Recovery notice (`"Recent errors suggest a short review"`), Recommended difficulty chip (or hidden when `recommended_difficulty == null`), Latest verified evidence summary, Skill Prerequisite checklist (`Mastered` checkmark vs `Locked — master <prerequisite> first`), and Outgoing Dependents list (`"Unlocks: <Skill Title>"`).
3. **Child Next Challenge Choice UI (Child Mode & Parent Preview):**
   - Calls `getNextChallengeCandidates` (with optional Subject filter chips: `All`, `Math`, `English`, `Literature`, `Science`, `Other`) and displays **at most 3** distinct choice cards.
   - Each card presents: Skill/Topic title, Subject & Topic breadcrumb, clear child-friendly explanation derived from `reason_code` + `explanation` metadata (e.g., `"Review suggested from recent questions"`, `"Keep this strong skill fresh"`, `"Keep practicing toward mastery"`, `"Newly unlocked — you mastered Single Digit Addition!"`, `"Ready to explore"`), and `recommended_difficulty` badge.
   - Selecting a card opens a read-only challenge brief / Node Detail sheet explaining what external practice to try next. Selecting a card performs **zero** server mutation and awards **zero** XP/RP; rewards and mastery update only when real external work is later captured and verified.
   - **Empty / No-Candidate State:** When `candidates` is empty (e.g., all grade-compatible skills in `pilot-v0.1` are fresh & `>= 85`, or `school_grade` is `null` so grade-scoped Unlock/Explore failed closed), renders an honest guidance state (prompting a parent to set `school_grade` if missing, or encouraging free external learning capture).
   - **Shared-device & sibling containment:** In Child Mode, navigation strictly binds `childId` to the active Child Mode / paired child profile; sibling profiles remain unreachable.

---

## 18. Cross-Platform Parity Fixture Matrix & Test Plan

Shared JSON parity fixtures (`fixtures/learning_v02_recommendation_parity_fixtures.json`) executed by both Dart (`packages/learnward_domain/test/next_challenge_parity_test.dart`) and PostgreSQL (`scripts/test_learning_recommendation_parity.mjs` calling `private.*_at` inside per-fixture `BEGIN ... ROLLBACK` transactions), complemented by pgTAP (`supabase/tests/database/11_phase5_2_recommendation_test.sql`), MUST cover at minimum:

### 18.1 Mastery & Confidence Reuse Parity (Phase 5.1 vs Phase 5.2)
1. Exact equality between Phase 5.1 `get_child_mastery` and Phase 5.2 node-state fields (`mastery_score`, `mastery_band`, `confidence_band`, `confidence_units`, `distinct_recent_vle_count`, `mastery_attained_at`) for identical child/node/as_of.
2. Low confidence state (< 1.5 units).
3. Medium confidence state (>= 1.5 units, or > 3.5 units with only 1 VLE).
4. High confidence state (> 3.5 units AND >= 2 distinct VLEs).
5. Mastery Candidate state (`mastery_score >= 85.00` without sticky attainment).
6. Sticky Mastered state (`mastery_attained_at <= as_of`).
7. Sticky Mastered with numeric score subsequent drop below 85 (e.g. `78.00`): remains `mastery_band = 'mastered'` in both Phase 5.1 and Phase 5.2.
8. 61-day confidence aging: evidence older than 60 days drops confidence units to 0.00 and band to Low, while sticky Mastered remains `mastered`.

### 18.2 Evaluation-Clock & Evidence Temporal Visibility (`verified_at <= as_of`)
9. **Authority visibility boundary:** Evidence event with `effective_occurred_at = Jan 1` and `verified_at = Jan 10`. Evaluated at `as_of = Jan 5`: event is **invisible** (does not appear in Recovery replay, does not appear in `latest_evidence`, does not contribute to Confidence units).
10. Evaluated at `as_of = Jan 10 00:00:00` or later: event is **visible** across Recovery, `latest_evidence`, and Confidence.
11. Bounded evaluation clock: `private.*_at` evaluates time-varying fields (freshness, recovery expiry, confidence window, sticky attainment) without attempting historical numeric EWMA rebuild.

### 18.3 Freshness Boundaries
12. `elapsed == 14 days` exact (`1,209,600s`) -> `recent`
13. `elapsed == 14 days + 1 second` -> `aging`
14. `elapsed == 45 days` exact (`3,888,000s`) -> `aging`
15. `elapsed == 45 days + 1 second` -> `needs_refresh`
16. Unseen node (`latest_effective_occurred_at == null`) -> `unknown`
17. Sticky `Mastered` node at `elapsed == 46 days` -> `mastery_band = 'mastered'` AND `freshness = 'needs_refresh'` (no score or band decay)

### 18.4 Recovery Replay & Boundaries
18. `item_group` qualifying weakness (`performance_pct = 60.00`, `item_count = 5`, `correct_count = 3`, `incorrect = 2`) -> `review_suggested`
19. `item_group` non-qualifying weakness (`performance_pct = 66.67`, `item_count = 3`, `correct_count = 2`, `incorrect = 1`; and `item_count = 2, correct_count = 0`) -> `none`
20. `component_score <= 50` (`performance_pct = 50.00`) -> `review_suggested` (`50.01` -> `none`)
21. `assessment_total` low score (`performance_pct = 20.00`) on Topic and Subject fallback -> ignored (`none`); `assessment_total` high score (`95.00`) after active weakness -> does NOT clear `review_suggested`
22. Later credible clear (`component_score` or `item_group` with `performance_pct = 70.00`) on same node -> resets to `none`
23. `30 days` exact boundary (`as_of - latest_weak_at == 30 days`) -> `review_suggested`
24. `30 days + 1 second` expiry (`as_of - latest_weak_at == 30 days + 1 second`) -> `none`
25. Same-timestamp canonical tie-break: weak observation and clear observation with identical `(effective_occurred_at, verified_at)` resolve strictly by `verified_learning_event_id ASC`

### 18.5 Skill Graph Prerequisites, Dependents & Catalog Versioning
26. All explicit prerequisites attained (`mastery_attained_at <= as_of`) -> dependent unseen Skill eligible for `unlock`
27. Multi-prerequisite Skill with 1 attained and 1 unattained (including `mastery_candidate` with score `90` but `mastery_attained_at IS NULL`) -> blocked (not eligible for `unlock` or `explore`)
28. Prerequisite attained historically, now `> 60 days` old so current `confidence_band = 'low'` -> still satisfied (`unlock` succeeds)
29. Prerequisite attained historically, later evidence lowered current `mastery_score` below `85` (`e.g. 72.00`) -> sticky `mastery_attained_at` still satisfies prerequisite (`unlock` succeeds)
30. Zero-prerequisite unseen grade-compatible Skill -> classified as `explore` (`explore_available_skill`), never `unlock`
31. **Dependents contract:** Skill with zero outgoing prerequisite edges returns `dependents = []`.
32. **Dependents contract:** Skill with 1 outgoing dependent (`single_digit -> double_digit`) returns dependent with exact structure, correct prerequisite counts, and grade compatibility.
33. **Dependents contract:** Multiple outgoing dependents sorted strictly by `catalog_sort_path ASC, learning_node_id ASC`.
34. **Dependents contract:** Inactive or retired-catalog dependent Skills excluded from `dependents`.
35. Non-Skill nodes (`subject`, `domain`, `topic`): `prerequisites = []`, `dependents = []`, `prerequisite_state.applicable = false`.
36. Cross-version isolation: promoting a transactional `pilot-v0.2-test` catalog isolates `pilot-v0.1` mastery; retired-version `mastery_attained_at` does not unlock `pilot-v0.2-test` skills or mark `pilot-v0.2-test` nodes as `seen`

### 18.6 Grade Filtering & Node Detail Difficulty
37. `school_grade` inside `[grade_min, grade_max]` (including exact `grade_min` and exact `grade_max` inclusive boundaries) -> eligible for `unlock` / `explore`
38. `school_grade < grade_min` (below range) -> excluded from `unlock` / `explore`
39. `school_grade > grade_max` (above range) -> excluded from `unlock` / `explore`
40. `school_grade IS NULL` -> grade-scoped `unlock` / `explore` fail closed; `recovery`, `refresh`, and `developing` still return normally
41. Unbounded node (`grade_min IS NULL AND grade_max IS NULL`) -> compatible even when `school_grade IS NULL`
42. **Unseen Topic difficulty:** `node_type = topic AND is_observed = false` -> `recommended_difficulty = null` in Node Detail.
43. Unseen Subject / Domain -> `recommended_difficulty = null`.
44. Locked unseen Skill -> `recommended_difficulty = null`.

### 18.7 Next Challenge Ranking, Overlap Resolution & Limits
45. `recovery` beats `refresh`, `developing`, `unlock`, and `explore`; multiple `recovery` nodes sort by `latest_unresolved_weakness_at DESC`
46. `refresh` vs `developing` overlap resolved: score `75.00` at `46d` (`needs_refresh`) classifies as `refresh` (`normal` difficulty) and ranks ahead of score `60.00` at `10d` (`developing`, `normal` difficulty), while score `75.00` at `10d` classifies as `developing` (`hard` difficulty); sticky `Mastered` node with score `78.00` at `10d` and no recovery is excluded from `developing`
47. `developing` orders lowest `mastery_score ASC` first (`55.00` before `72.00`)
48. `unlock` orders ahead of `explore` and sorts by `catalog_sort_path ASC`
49. `explore` orders by `explore_proximity_rank ASC` (`0` same Topic < `1` same Domain < `2` same Subject < `3` cold-start Subject)
50. Maximum `3` candidates enforced; invalid `p_limit` (`0`, `-1`, `4`, `null`) rejected with `22000`; invalid `p_subject_key` rejected with `22000`
51. Deterministic tie-break down to `catalog_sort_path ASC` then `learning_node_id ASC`
52. `p_subject_key` filter restricts returned candidates to that subject while respecting all eligibility rules
53. No-candidate scenario returns `"candidates": []` cleanly with valid envelope metadata

### 18.8 Security & Tenant Isolation (pgTAP)
54. Active family adult (`owner` and `parent`) succeeds on all 3 RPCs
55. Paired active child device succeeds for its exact `child_id` on all 3 RPCs
56. Paired sibling child device calling any of the 3 RPCs for another child in the same family is denied (`42501`)
57. Cross-family active adult calling any of the 3 RPCs is denied (`42501`)
58. Unauthenticated / `anon` caller is denied (`42501` / no `EXECUTE` grant); `authenticated` cannot `EXECUTE` `private.*_at` helpers

### 18.9 Economy Invariance
59. Recording Growth Engine awards, mutating `xp_ledger`, `rp_ledger`, `child_balances`, creating/redeeming/cancelling Reward Store items, and executing Celebration Wheel spins produce **identical** outputs (modulo `as_of` when using explicit `private.*_at(..., v_fixed_as_of)`), identical scores, and identical candidate rankings across all 3 Phase 5.2 read functions.

---

## 19. Additive Migration & Implementation Boundary

- **This design checkpoint creates NO migration and modifies NO runtime code.**
- Once this design PR passes independent design audit and is merged into `main`, Phase 5.2 implementation will add **one** additive SQL migration (e.g., `supabase/migrations/<timestamp>_phase5_2_skill_graph_recommendation.sql`) defining only the `private.*_at` helpers, the three `public.get_*` `SECURITY DEFINER` `STABLE` read RPCs, and their `REVOKE`/`GRANT` statements (plus at most read-only supporting B-tree index(es) on existing tables if query plans require them, without altering any existing table columns, constraints, triggers, policies, or `pilot-v0.1` rows).
- Frozen Phase 1–5.1 migration files and [ADR 0006](adr/0006-phase-5-learning-engine-mastery.md) MUST NOT be modified.
