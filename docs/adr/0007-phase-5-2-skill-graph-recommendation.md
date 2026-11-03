# ADR 0007 — Phase 5.2 Skill Graph, Freshness, Recovery & Next Challenge Decisions

- **Status:** PROPOSED
- **Date:** 2026-11-03 (Proposed)
- **Target:** Phase 5.2 — Skill Graph + Recommendation Foundation (completing Phase 5 v0.1)
- **Reviewed Baseline:** `main` @ `16568a99da157f296fdf30c3b5e28d902bee5fbc`
- **Upstream Contract:** [ADR 0006 — Phase 5 Learning Engine, Mastery & Recommendation Decisions](0006-phase-5-learning-engine-mastery.md) (`ACCEPTED`), [Phase 5.1 Freeze Receipt](../freezes/phase-5-1-learning-mastery-foundation-freeze.md) (`FROZEN`)
- **Readiness Gate:** PR #9 Comment `6594086334` (`PASS FOR DESIGN`), PR #10 Audits `6594895418`, `6595582324` (`REQUEST CHANGES`)
- **Detailed Design:** [docs/15-phase-5-2-skill-graph-recommendation-design-v0.1.md](../15-phase-5-2-skill-graph-recommendation-design-v0.1.md)

This ADR remains **`PROPOSED`** during the Phase 5.2 design review and implementation cycle. It may be marked `ACCEPTED` only after Phase 5.2 implementation passes independent audit, merges to `main`, and completes post-merge CI verification.

---

## Context

Phase 5.1 froze the versioned curriculum catalog (`learning_catalog_versions`, `learning_nodes`, `learning_prerequisites`), component-level assessment mappings, immutable evidence atoms (`learning_evidence_events`), deterministic EWMA mastery rebuild (`child_mastery_states`, `mastery_state_revisions`), rolling 60-day Confidence Engine v0.1, and server-authoritative sticky `mastery_attained_at`.

Phase 5.2 completes Phase 5 by delivering Skill Graph traversal, Freshness, Recovery, Next Challenge recommendation candidate generation, and coverage presentation. Following design audits `6594086334`, `6594895418`, and `6595582324`, the key architectural decisions below are frozen to ensure complete determinism and cross-platform parity between PostgreSQL RPCs and pure Dart domain engines.

---

## Decision 1 — Pure Read-Time Projections with Zero Recommendation Persistence

Freshness, Recovery, Skill Graph prerequisite satisfaction, Dependents, Coverage summaries, and Next Challenge candidates are evaluated strictly as **read-time deterministic projections** over frozen Phase 5.1 tables and `child_profiles`.

Phase 5.2 introduces **no** mutable recommendation, freshness, or recovery tables (`recommendations`, `recovery_states`, `freshness_states` are explicitly rejected for v0.1), **no** background cron jobs, and **no** writes inside any Phase 5.2 RPC (`STABLE` functions only).

**Consequence:** Time-dependent classifications (`recent -> aging -> needs_refresh`, 30-day Recovery expiry, 60-day Confidence aging) are always exact at the request's `v_as_of := transaction_timestamp()` without stale background caches or score decay.

---

## Decision 2 — Active-Catalog Universe, Version-Scoped Node Identity & No Cross-Version Carry-Forward

1. Every Phase 5.2 read resolves the single `status = 'active'` row in `public.learning_catalog_versions` (raising `LW501` if none exists) and builds its node universe from active nodes (`is_active = true` along the full `subject -> domain -> topic -> skill` ancestor chain) in that active catalog, `LEFT JOIN`ed to `public.child_mastery_states`.
2. **Seen vs Unseen:**
   - `seen` (`is_observed = true`): child has a `child_mastery_states` row (`effective_evidence_count >= 1`).
   - `unseen` (`is_observed = false`): no authoritative child evidence/mastery; `mastery_score = null`, `mastery_band = null`, `confidence_band = null`, `freshness = 'unknown'`, `recovery_signal = 'none'`. Unseen nodes represent unknown state, never `0%` mastery.
3. **Version-scoped node identity:** Node IDs belong permanently to their `catalog_version`. Historical mastery on `retired` catalog versions never satisfies prerequisites or marks nodes as `seen` in a newer active catalog version (`no cross-version mastery carry-forward` in v0.1).
4. **Catalog content constraint:** Published `pilot-v0.1` is never mutated, and `pilot-v0.2` is not promoted during Phase 5.2. Complex multi-branch graph topologies are verified via transactional (`BEGIN ... ROLLBACK`) test fixtures.

---

## Decision 3 — Phase 5.2 Reuses Exact Phase 5.1 Mastery & Confidence Semantics (Sticky-Only `mastery_band`)

```text
Phase 5.2 is a consumer of Phase 5.1 Mastery/Confidence semantics.
It does not redefine them.

Mastery declaration is a persisted server event.
Read-time evaluation consumes mastery_attained_at; it does not manufacture attainment.
```

For every observed active-catalog node, Phase 5.2 consumes the exact authoritative formulas frozen in Phase 5.1 (`private.get_child_mastery_at`) at the same authoritative `as_of`:
- `mastery_score`: from `child_mastery_states.mastery_score`.
- `mastery_band` (**sticky-attainment-only rule**): `'mastered'` if and only if `mastery_attained_at IS NOT NULL AND mastery_attained_at <= as_of`, else `'mastery_candidate'` (`>= 85.00`), `'secure'` (`>= 70.00`), `'developing'` (`>= 50.00`), `'emerging'` (`< 50.00`).
- `confidence_units`, `distinct_recent_vle_count`, & `confidence_band`: evaluated over the **exact** frozen Phase 5.1 60-day effective-occurrence window (`effective_occurred_at >= as_of - interval '60 days' AND effective_occurred_at <= as_of`, without adding a Phase-5.2-only `verified_at <= as_of` filter), where `confidence_units = round(sum(specificity_weight * level_weight), 2)`, `'high'` if `confidence_units > 3.50 AND distinct_recent_vle_count >= 2`, `'medium'` if `confidence_units >= 1.50`, and `'low'` otherwise.
- **Dart `ConfidenceEngine` boundary:** Because frozen Phase 5.1 `ConfidenceEngine.evaluate` contains a fallback branch that returns `MasteryBand.mastered` when `masteryAttainedAt == null` if `masteryScore >= 85 && confBand == ConfidenceBand.high && distinctCount >= 2`, Phase 5.2 Dart domain engines reuse `ConfidenceEngine.evaluate` **only** for `(confidenceUnits, distinctRecentVles, confidenceBand)` and **never** use `ConfidenceEngine.evaluate(...).masteryBand`. Both PostgreSQL and Dart derive `mastery_band` strictly from the sticky-attainment rule above (`mastery_attained_at IS NULL` with `mastery_score = 90` and High confidence yields `'mastery_candidate'`, never `'mastered'`).

---

## Decision 4 — Evaluation-Clock Semantics (`p_as_of`) over Current Committed Projection

Internal `private.*_at(..., p_as_of)` helpers are **deterministic evaluation-clock helpers over the CURRENT COMMITTED Phase 5.1 projection.**

They are NOT arbitrary historical snapshot reconstruction APIs. They vary time-parameterized derivations (60-day confidence window, visible-evidence freshness elapsed duration, recovery replay & 30-day expiry, sticky attainment visibility), but they do NOT reconstruct historical numeric EWMA `mastery_score` before subsequent assessments were processed. Full historical event-sourced reconstruction is explicitly outside scope for Phase 5.2 v0.1.

In production client-facing RPCs, `v_as_of := transaction_timestamp()` is captured once at request entry.

---

## Decision 5 — Dual Temporal Visibility Rule (`effective_occurred_at <= as_of AND verified_at <= as_of`) Scoped to Phase 5.2 Direct-Evidence Reads

Whenever Phase 5.2 derives **new Phase 5.2 direct-evidence read fields**—specifically **Recovery replay**, **`latest_evidence`**, and **Freshness (`latest_effective_occurred_at`)**—from `public.learning_evidence_events`, it requires:

```sql
effective_occurred_at <= as_of
AND verified_at <= as_of
```

- `effective_occurred_at` represents academic chronology (when the learning occurred).
- `verified_at` represents authority visibility time (when the evidence was verified into the authoritative system).

An event with `effective_occurred_at = T1` and `verified_at = T3` (`T1 < T2 < T3`) evaluated at `as_of = T2` is **invisible** to Recovery replay, `latest_evidence`, and Freshness (while Confidence continues to follow the exact frozen Phase 5.1 effective-occurrence window `[T2 - 60d, T2]`). At `as_of >= T3`, the event is visible across all derivations. In production public RPCs (`v_as_of := transaction_timestamp()`), all committed rows naturally satisfy `effective_occurred_at <= verified_at <= v_as_of`.

---

## Decision 6 — Freshness Engine v0.1 (`recent | aging | needs_refresh | unknown`) & Visible-Evidence Source

For any node at `as_of`, `latest_effective_occurred_at` is the maximum `effective_occurred_at` among Phase 5.2-visible evidence (`effective_occurred_at <= as_of AND verified_at <= as_of`):
- On public reads (`as_of = transaction_timestamp()`), this converges identically with `child_mastery_states.last_evidence_occurred_at`.
- On explicit historical `private.*_at` evaluations, deriving `latest_effective_occurred_at` from visible evidence ensures internal payload consistency: if no evidence is visible at `as_of`, `latest_effective_occurred_at = null`, `latest_evidence = null`, `recovery_signal = 'none'`, `freshness = 'unknown'`, and `days_since_last_evidence = null`.

With `elapsed = greatest(0, as_of - latest_effective_occurred_at)`:

- `latest_effective_occurred_at IS NULL` -> `unknown` (`days_since_last_evidence = null`)
- `elapsed <= 14 days` -> `recent`
- `14 days < elapsed <= 45 days` -> `aging`
- `elapsed > 45 days` -> `needs_refresh`

Time passing never mutates `mastery_score` or sticky `mastery_attained_at` (`Mastered + >45d => mastery_band = 'mastered', freshness = 'needs_refresh'`).

---

## Decision 7 — Recovery Engine v0.1 via Canonical Chronology Replay & 30-Day Expiry

Recovery (`none | review_suggested`) applies only to `topic` and `skill` nodes (`subject`, `domain`, and `unseen` nodes always yield `none`).

1. Filter same-child, same-node `learning_evidence_events` to `score_source IN ('component_score', 'item_group')`, `effective_occurred_at <= as_of`, and `verified_at <= as_of`. `assessment_total` is completely ignored (can neither raise nor clear).
2. Sort in canonical academic chronology order: `effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC`.
3. Replay from `(state = 'none', latest_weak_at = null)`:
   - **Qualifying weak** (`item_group` with `performance_pct < 70 AND item_count >= 3 AND (item_count - correct_count) >= 2`, OR `component_score` with `performance_pct <= 50`) sets `state = 'review_suggested'` and `latest_weak_at = ev.effective_occurred_at`.
   - **Qualifying clear** (`component_score` or `item_group` with `performance_pct >= 70`) resets `state = 'none'` and `latest_weak_at = null`.
   - Neutral observations leave `(state, latest_weak_at)` unchanged.
4. After replay, return `review_suggested` if and only if `state = 'review_suggested'` AND `as_of - latest_weak_at <= 30 days` (inclusive); otherwise return `none`.

---

## Decision 8 — Sticky Prerequisite Satisfaction, Outgoing Dependents Contract & Fail-Closed Grade Filtering

1. **Prerequisite contract:** For an active Skill `S`, every explicit incoming edge in `public.learning_prerequisites` (`catalog_version = v_active_version AND dependent_node_id = S.id`) must reference an active prerequisite Skill whose `child_mastery_states` row satisfies `mastery_attained_at IS NOT NULL AND mastery_attained_at <= as_of`. Current 60-day confidence `high` and current `mastery_score >= 85` are **not** required once sticky attainment has been declared.
2. **Outgoing Dependents contract (`prerequisite_state.dependents`):**
   - For a Skill node `S`: exposes all active-catalog Skills `D` in `v_active_version` where an edge `prerequisite_node_id = S.id AND dependent_node_id = D.id` exists and `D.is_active = true` (with active ancestor chain).
   - Each item includes `learning_node_id`, `canonical_key`, `title`, `grade_min`, `grade_max`, `is_observed`, `is_grade_compatible`, `prerequisite_count`, `attained_prerequisite_count`, and `is_prerequisite_satisfied`.
   - A dependent is "unlocked" iff `is_observed = false AND is_grade_compatible = true AND is_prerequisite_satisfied = true`.
   - Sorted deterministically by `catalog_sort_path ASC, learning_node_id ASC`.
   - Non-Skill nodes return `dependents = []` and `prerequisite_state.applicable = false`.
3. **Grade filtering (`child_profiles.school_grade`):**
   - Nodes with `grade_min IS NULL AND grade_max IS NULL` are always grade-compatible.
   - Grade-scoped nodes (`grade_min IS NOT NULL OR grade_max IS NOT NULL`) **fail closed** (`false`) when `school_grade IS NULL`, and otherwise require inclusive `(grade_min IS NULL OR school_grade >= grade_min) AND (grade_max IS NULL OR school_grade <= grade_max)`.
   - `unlock` and `explore` require grade compatibility; `recovery`, `refresh`, and `developing` are evidence-driven and do not filter by `school_grade`.

---

## Decision 9 — Mutually Exclusive Five-Class Partition & Priority (`Recovery > Refresh > Developing > Unlock > Explore`)

Every active-catalog node qualifies for **at most one** Next Challenge priority class:

1. **`recovery` (`recovery_recent_errors`):** seen `topic`/`skill` with `recovery_signal = 'review_suggested'`.
2. **`refresh` (`refresh_stale_secure_skill`):** seen `topic`/`skill` with `recovery_signal = 'none'`, `freshness = 'needs_refresh'`, and `mastery_score >= 70.00`.
3. **`developing` (`developing_keep_practicing`):** seen `topic`/`skill` with `recovery_signal = 'none'`, `freshness != 'needs_refresh'` (`recent` or `aging`), `50.00 <= mastery_score < 85.00`, and `mastery_band != 'mastered'`.
4. **`unlock` (`unlock_prerequisites_mastered`):** unseen `skill` with `prerequisite_count >= 1`, all explicit prerequisites attained at `as_of`, and `is_grade_compatible = true`.
5. **`explore` (`explore_available_skill`):** unseen `skill` with `prerequisite_count = 0` and `is_grade_compatible = true`.

**Consequence:** Stale `70..84.99` nodes route cleanly to `refresh` instead of being shadowed by `developing`; sticky `Mastered` nodes whose numeric score dipped below `85` are never mislabeled `developing`; and `unlock` (`>= 1` mastered prerequisite) vs `explore` (`0` prerequisites) partition unseen ready Skills cleanly with truthful reason codes.

---

## Decision 10 — Explore Proximity (`0..3`), Global Total Comparator & Recommended Difficulty

1. **Explore `explore_proximity_rank`:**
   - `0`: parent Topic has `>= 1` seen sibling Skill;
   - `1`: parent Domain (or any Topic/Skill within it) has seen evidence;
   - `2`: same `subject_key` (including Subject root fallback) has seen evidence;
   - `3`: zero seen nodes in `subject_key` (cold start).
2. **Global total comparator:**
   1. `priority_rank ASC` (`1..5`)
   2. Class key (`recovery`: `latest_unresolved_weakness_at DESC`; `refresh`: `latest_effective_occurred_at ASC`; `developing`: `round(mastery_score * 100) ASC`; `unlock`: `0`; `explore`: `explore_proximity_rank ASC`)
   3. `catalog_sort_path ASC` (`[subject, domain, topic(, skill)]` `sort_order` integer array, ending in `node.sort_order ASC`)
   4. `learning_node_id ASC` (UUID byte / lowercase canonical hyphenated string order).
3. **Recommended difficulty (`below_level | normal | hard | challenge`):**
   - Next Challenge candidates: `recovery -> below_level`, `refresh -> normal`, `developing (< 70) -> normal`, `developing (70..84.99) -> hard`, `unlock -> normal`, `explore -> normal`.
   - Node Detail:
     - Unseen non-Skill (Subject, Domain, unseen Topic) -> `recommended_difficulty = null`.
     - Locked or grade-incompatible unseen Skill -> `recommended_difficulty = null`.
     - Eligible unseen Skill -> `normal`.
     - Observed Topic / Skill -> derived per candidate rules, with fresh high-mastery extension (`>= 85` or sticky `mastered`, no recovery): `challenge` when `mastery_score >= 90 AND confidence_band = 'high'`, else `hard`.

---

## Decision 11 — Coverage-Aware Non-Averaging Read RPCs & Strict Tenant Authorization

1. `public.get_child_learning_overview(uuid)`, `public.get_node_learning_state(uuid, uuid)`, and `public.get_next_challenge_candidates(uuid, text default null, integer default 3)` are `SECURITY DEFINER`, `STABLE`, `SET search_path = ''`, granted only to `authenticated` and `service_role`.
2. Invalid inputs (`NULL` required IDs, `p_limit NOT BETWEEN 1 AND 3`, invalid `p_subject_key`) are **rejected** with `22000` (never silently clamped).
3. Family tenancy is derived exclusively from `public.child_profiles` (`status = 'active'`, else `P0002`) and authorized via `private.is_active_family_adult(family_id) OR private.is_active_child_device(family_id, p_child_id)` (`42501` on sibling, cross-family, or unauthenticated access).
4. Overview responses separate direct `subject_state` from explicit `observed_*` vs `unseen_*` descendant coverage counts and forbid naive cross-skill percentage averages.
5. Economy state (XP, RP, Store, Wheel) is structurally unreachable from all Phase 5.2 domain engines, application use cases, and SQL functions.
