# Phase 5.2 Freeze Receipt — Skill Graph + Recommendation Foundation

**Status:** FROZEN  
**Target:** Phase 5.2 — Skill Graph + Recommendation Foundation (`Skill Graph traversal, Freshness, Recovery, Next Challenge & Coverage Presentation`)  
**Design PR:** [#10 — docs(phase-5.2): Phase 5.2 dependency review, detailed design & ADR 0007](https://github.com/thedusk4203/LearnWard/pull/10) (Merged @ `80784091d58ce8c29fa31cd166291a5cd1e8268b`)  
**Implementation PR:** [#11 — feat(phase-5.2): implement skill graph, freshness, recovery and next challenge](https://github.com/thedusk4203/LearnWard/pull/11)  
**Approved Implementation HEAD:** `f76f59bf5dc0a4ccd57396d247752ab08a03eb45`  
**Independent Implementation Audit:** PASS / MERGE READY (Comment `6602872658`)  
**Implementation Merge SHA:** `6dd00177b0d760bd77a34ec702ae34089adc4253`  
**Post-Merge Main SHA:** `6dd00177b0d760bd77a34ec702ae34089adc4253`  
**Post-Merge CI:** Run ID [`41630504285`](https://github.com/thedusk4203/LearnWard/actions/runs/41630504285) — **SUCCESS (4/4 green)**  
**Merge Timestamp:** `2026-11-03T11:48:34Z`  
**Freeze Date:** 2026-11-03  
**ADR:** 0007 (ACCEPTED)  
**Upstream Contract:** [ADR 0006](file:///c:/PERSONAL1/LearnWard/docs/adr/0006-phase-5-learning-engine-mastery.md) (ACCEPTED), [Phase 5.1 Freeze Receipt](file:///c:/PERSONAL1/LearnWard/docs/freezes/phase-5-1-learning-mastery-foundation-freeze.md) (FROZEN)  

---

## 1. Test Suite Verification Totals

Final verified test totals from post-merge CI run [`41630504285`](https://github.com/thedusk4203/LearnWard/actions/runs/41630504285):

| Test Suite | Total Tests | Passed | Result |
|---|---|---|---|
| **Database & RLS pgTAP** (8 files) | 438 | 438 | **PASS** |
| - *Phase 5.2 Skill Graph & Next Challenge* (`08_phase5_2_skill_graph_recommendation_test.sql`) | 61 | 61 | **PASS** |
| - *Phase 5.1 Mastery Foundation* (`07_learning_mastery_foundation_test.sql`) | 135 | 135 | **PASS** |
| - *Phase 4 Reward & Wheel* (`06_reward_economy_wheel_test.sql`) | 114 | 114 | **PASS** |
| - *Phase 3 Growth Engine* (`05_growth_engine_ledger_test.sql`) | 71 | 71 | **PASS** |
| - *Phase 1–2 Tests* (`01`–`04`) | 57 | 57 | **PASS** |
| **Domain Tests** (`packages/learnward_domain`) | 196 | 196 | **PASS** |
| **Application Tests** (`packages/learnward_application`) | 43 | 43 | **PASS** |
| **Data Tests** (`packages/learnward_data`) | 29 | 29 | **PASS** |
| **Test Support Tests** (`packages/learnward_test_support`) | 1 | 1 | **PASS** |
| **Design System Tests** (`packages/learnward_design_system`) | 2 | 2 | **PASS** |
| **Flutter Widget Tests** (`apps/mobile`) | 54 | 54 | **PASS** |
| **Phase 5.2 Cross-Platform Parity Fixtures** (PostgreSQL <-> Dart, 61 cases) | 61 | 61 | **PASS** |
| **Phase 5.1 Learning Mastery Parity Fixtures** (PostgreSQL <-> Dart, 13 cases) | 13 | 13 | **PASS** |
| **Phase 5.2 Skill Graph Vertical Slice Integration** (`scripts/test_learning_recommendation_vertical_slice.mjs`) | All | All | **PASS** |
| **Learning Mastery Vertical Slice Integration** (`scripts/test_learning_vertical_slice.mjs`) | All | All | **PASS** |
| **Learning Mastery Concurrency Regression** (`scripts/test_learning_concurrency.mjs`) | All | All | **PASS** |
| **Phase 1–4 Regression Tests** (Concurrency, Storage, Ledger, Store, Wheel) | All | All | **PASS** |

---

## 2. Authoritative Phase 5.2 Contract Summary

### 2.1 Read Model
1. **Active-Catalog-Only Universe:**
   - Every Phase 5.2 read RPC resolves the single active catalog version (`status = 'active'` in `public.learning_catalog_versions`, raising `LW501` if absent) and constructs its node universe strictly from active nodes (`is_active = true` along the full subject -> domain -> topic -> skill ancestor chain) in that catalog, `LEFT JOIN`ed to `public.child_mastery_states`.
2. **Unseen State Represents Unknown, Never Zero:**
   - Nodes without authoritative child evidence (`effective_evidence_count = 0` / no mastery row) report `is_observed = false`, `mastery_score = NULL`, `mastery_band = NULL`, `confidence_band = NULL`, `freshness = 'unknown'`, and `recovery_signal = 'none'`. Unseen nodes are strictly unknown, never manufactured as `0%` mastery.
3. **Current Committed Projection Consumer:**
   - Internal `private.*_at(..., p_as_of)` helpers are deterministic evaluation-clock helpers operating over the **current committed Phase 5.1 projection**. They do not reconstruct arbitrary historical numeric EWMA scores before subsequent assessments occurred.
4. **Single Server-Authoritative Request `as_of`:**
   - Public client-facing RPCs capture `v_as_of := transaction_timestamp()` once at entry, propagating this identical instant across all derivations.
5. **Zero Recommendation Persistence:**
   - Freshness, Recovery, Skill Graph traversal, Dependents, Coverage summaries, and Next Challenge recommendations are computed purely on-the-fly via `STABLE` functions.
   - Zero recommendation persistence tables exist (`recommendations`, `recovery_states`, `freshness_states` are rejected for v0.1). Zero cron jobs or background mutation workers are required.

### 2.2 Mastery & Confidence Reuse
1. **Consumer of Frozen Phase 5.1 Semantics:**
   - Phase 5.2 reuses exact frozen Phase 5.1 mastery and confidence formulas. It does not invent a secondary confidence or mastery engine.
2. **Rolling 60-Day Occurrence Window:**
   - Confidence units, distinct recent VLE count, and confidence bands are evaluated strictly over the frozen Phase 5.1 window:
     `effective_occurred_at >= as_of - interval '60 days' AND effective_occurred_at <= as_of`.
   - Confidence does not apply an extra `verified_at <= as_of` filter.
3. **Sticky Attainment Sole Route to Mastered:**
   - A node reports `mastery_band = 'mastered'` if and only if `mastery_attained_at IS NOT NULL AND mastery_attained_at <= as_of`.
   - Read-time evaluation never manufactures mastery attainment (`mastery_attained_at IS NULL` with score `90.00` and High confidence reports `mastery_candidate`, never `mastered`).

### 2.3 Freshness Engine v0.1
1. **Freshness Classifications:**
   - `recent`: elapsed duration $\le$ 14 days.
   - `aging`: elapsed duration > 14 days and $\le$ 45 days.
   - `needs_refresh`: elapsed duration > 45 days.
   - `unknown`: no visible evidence exists.
2. **Visible-Evidence Source:**
   - Freshness evidence requires dual temporal qualification:
     `effective_occurred_at <= as_of AND verified_at <= as_of`.
   - `latest_effective_occurred_at` is the maximum `effective_occurred_at` among visible evidence.
   - Elapsed duration is calculated as `greatest(0, as_of - latest_effective_occurred_at)`.
3. **Invariance:**
   - Time passing never mutates numeric `mastery_score` or sticky `mastery_attained_at`. Mastered skills older than 45 days retain `mastery_band = 'mastered'` and transition to `freshness = 'needs_refresh'`.

### 2.4 Recovery Engine v0.1
1. **Topic and Skill Nodes Only:**
   - Evaluated strictly for `topic` and `skill` nodes; Subject, Domain, and unseen nodes always return `recovery_signal = 'none'`.
2. **Component Score & Item Group Only:**
   - Only `score_source IN ('component_score', 'item_group')` participates in Recovery replay.
   - `assessment_total` is completely ignored (it can neither trigger nor clear a recovery signal).
3. **Canonical Chronology Replay:**
   - Visible evidence (`effective_occurred_at <= as_of AND verified_at <= as_of`) is replayed in canonical academic order:
     `ORDER BY effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC`.
   - **Qualifying Weakness:** `item_group` with `performance_pct < 70 AND item_count >= 3 AND (item_count - correct_count) >= 2`, OR `component_score` with `performance_pct <= 50`. Sets `state = 'review_suggested'` and stamps `latest_weak_at`.
   - **Qualifying Clear:** `component_score` or `item_group` with `performance_pct >= 70`. Resets `state = 'none'` and clears `latest_weak_at`.
   - **Neutral Observations:** Do not alter current `(state, latest_weak_at)`.
4. **30-Day Unresolved Weakness Window:**
   - `review_suggested` is returned if and only if `state = 'review_suggested'` AND `as_of - latest_weak_at <= 30 days` (inclusive). Beyond 30 days, unresolved signals expire to `none`.

### 2.5 Recommendation Partition & Priority
1. **Exact Priority Hierarchy:**
   $$\text{Recovery (1)} > \text{Refresh (2)} > \text{Developing (3)} > \text{Unlock (4)} > \text{Explore (5)}$$
2. **Mutually Exclusive Reason Predicates:**
   - `recovery` (`recovery_recent_errors`): observed topic/skill with `recovery_signal = 'review_suggested'`.
   - `refresh` (`refresh_stale_secure_skill`): observed topic/skill with `recovery_signal = 'none'`, `freshness = 'needs_refresh'`, and `mastery_score >= 70.00`.
   - `developing` (`developing_keep_practicing`): observed topic/skill with:
     ```sql
     is_observed = true
     AND recovery_signal = 'none'
     AND freshness IN ('recent', 'aging')
     AND mastery_score >= 50.00
     AND mastery_score < 85.00
     AND mastery_band <> 'mastered'
     ```
   - `unlock` (`unlock_prerequisites_mastered`): unseen skill with `prerequisite_count >= 1`, all explicit prerequisites attained at `as_of`, and `is_grade_compatible = true`.
   - `explore` (`explore_available_skill`): unseen skill with `prerequisite_count = 0` and `is_grade_compatible = true`.
3. **Developing Freshness Invariant (Audited Case 61):**
   - Developing requires positive membership `freshness IN ('recent', 'aging')`. It is strictly forbidden to use `freshness <> 'needs_refresh'`.
   - When evidence occurred at $T_1$ with committed score 60, but was verified into the authority at $T_3$, evaluating at $T_2$ ($T_1 < T_2 < T_3$) yields `freshness = 'unknown'`, which strictly excludes the node from `developing`. At $T_3$, `freshness = 'recent'` and `developing` qualifies.

### 2.6 Prerequisites
1. **Skill-Only Active-Catalog DAG:**
   - Prerequisite relationships exist strictly between Skill nodes within the active catalog version (`learning_prerequisites.catalog_version = active_version`).
2. **Sticky Mastery Prerequisite Satisfaction:**
   - Every explicit incoming prerequisite edge requires the referenced Skill to satisfy `mastery_attained_at IS NOT NULL AND mastery_attained_at <= as_of`.
   - Current confidence High and current mastery score $\ge 85$ are **not** required after attainment has been declared.
3. **Zero Prerequisites Route to Explore:**
   - Unseen Skills with zero explicit incoming prerequisite edges route exclusively to `explore`, never `unlock`.

### 2.7 Ranking & Candidate Generation
1. **Deterministic Global Comparator:**
   - Class Priority Rank ASC (`1..5`).
   - Class-specific secondary ordering:
     - `recovery`: `latest_unresolved_weakness_at DESC`
     - `refresh`: `latest_effective_occurred_at ASC`
     - `developing`: `round(mastery_score * 100) ASC`
     - `unlock`: `0`
     - `explore`: `explore_proximity_rank ASC` (`0` same Topic < `1` same Domain < `2` same Subject < `3` cold start)
   - Canonical tie-break: `catalog_sort_path ASC`, then `learning_node_id ASC`.
2. **Recommendation Limits:**
   - Public RPC `get_next_challenge_candidates` returns at most **3** candidates.
   - Zero randomness or stochastic jitter is used.

### 2.8 Grade Compatibility & Filtering
1. **Source of Truth:**
   - Child's current grade is retrieved from `child_profiles.school_grade`.
2. **Inclusive Grade Bounds:**
   - Compatible iff `(grade_min IS NULL OR school_grade >= grade_min) AND (grade_max IS NULL OR school_grade <= grade_max)`.
3. **Fail-Closed Grade Scoping:**
   - Grade-scoped unseen Skills (`grade_min IS NOT NULL OR grade_max IS NOT NULL`) fail closed (`is_grade_compatible = false`) when `school_grade IS NULL`.
   - Grade filtering applies strictly to unseen candidates (`unlock` and `explore`). Evidence-driven recommendations (`recovery`, `refresh`, `developing`) remain available regardless of grade.

### 2.9 Tenant Isolation & Security
1. **Authorization Matrix:**
   - Access permitted to active family adult (`private.is_active_family_adult(family_id)`) or exact paired child device (`private.is_active_child_device(family_id, p_child_id)`).
   - Cross-family adults, sibling child devices, and unauthenticated callers are denied with SQL state `42501`.
2. **Server-Side Tenancy Derivation:**
   - Public RPCs (`get_child_learning_overview`, `get_node_learning_state`, `get_next_challenge_candidates`) derive family membership server-side from active `child_profiles`.
   - Evaluation-clock `private.*_at` helpers are locked in schema `private` with no grants to application roles (`authenticated`, `anon`).

### 2.10 Economy Independence
1. **Strict Separation of Concerns:**
   - Phase 5.2 domain engines, application use cases, and SQL RPCs have zero dependencies on `xp_ledger`, `rp_ledger`, `child_balances`, `reward_items`, or `celebration_wheel_spins`.
   - Selecting, reviewing, or exploring next challenges performs zero economic or mastery mutation.

---

## 3. Preservation of Frozen Implementation History

1. **Phase 0–5.1 Migrations Untouched:**
   - All migrations from `20261031000000_phase0_private_schema.sql` through `20261102140000_phase5_1_learning_mastery_foundation.sql` remain unaltered.
2. **Phase 5.2 Migration Frozen:**
   - `supabase/migrations/20261103060000_phase5_2_skill_graph_recommendation.sql` is committed and frozen on `main`. Future schema modifications require a new additive migration.
3. **Published Pilot Catalog Preserved:**
   - Published catalog `pilot-v0.1` remains untouched with exactly 12 learning nodes and 1 prerequisite edge. No in-place mutations or unreviewed promotions occurred.

---

## 4. Phase 5 Completion Milestone

With Phase 5.1 (`Learning Engine, Mastery & Confidence Foundation`) and Phase 5.2 (`Skill Graph + Recommendation Foundation`) both merged, verified, and frozen:

```text
Phase 1 — Family + Child Identity Foundation:            FROZEN
Phase 2 — Secure Assessment Capture Vertical Slice:      FROZEN
Phase 3 — Growth Engine + XP/RP Ledger Foundation:       FROZEN
Phase 4 — Reward Economy & Celebration Wheel:            FROZEN
Phase 5.1 — Learning Engine, Mastery & Confidence:       FROZEN
Phase 5.2 — Skill Graph + Recommendation Foundation:     FROZEN
----------------------------------------------------------------
Phase 5 — Learning Engine, Mastery & Recommendations:   COMPLETE / FROZEN
Phase 6 — Next Phase:                                    NOT STARTED
```
