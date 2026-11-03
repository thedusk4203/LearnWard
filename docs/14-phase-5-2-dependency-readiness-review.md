# Phase 5.2 Dependency / Readiness Review — Skill Graph + Recommendation Foundation

- **Status:** READY FOR DESIGN (implementation NOT authorized)
- **Reviewed baseline:** `main` @ `16568a99da157f296fdf30c3b5e28d902bee5fbc`
- **Readiness gates:** PR #9 comment `6594086334` — PASS FOR DESIGN; PR #10 audit `6594895418` — REQUEST CHANGES (resolved in current checkpoint)
- **Upstream contract:** Phase 5.1 — FROZEN ([freeze receipt](freezes/phase-5-1-learning-mastery-foundation-freeze.md)), [ADR 0006](adr/0006-phase-5-learning-engine-mastery.md) — ACCEPTED
- **Detailed design produced by this checkpoint:** [Phase 5.2 Detailed Design v0.1](15-phase-5-2-skill-graph-recommendation-design-v0.1.md), [ADR 0007](adr/0007-phase-5-2-skill-graph-recommendation.md) — PROPOSED

This review is documentation only. It does not authorize migrations, runtime code, catalog promotion or any change to frozen Phase 1–5.1 artifacts.

---

## 1. Scope of Phase 5.2

Phase 5.2 is the second and final slice of Phase 5 (`docs/13-phase-5-learning-engine-mastery-design-v0.1.md` Section 4). It delivers:

- prerequisite graph traversal for Unlock / Explore candidate selection,
- dynamic Freshness (14d / 45d relative to server `as_of`),
- deterministic Recovery signal (`review_suggested`, dual visibility, 30-day recency window),
- Next Challenge candidate engine (at most three candidates),
- learning overview, node state, explanation and coverage presentation,
- child choice UI.

There is no Phase 5.3. Any further split requires a new, independently reviewed design gate.

---

## 2. Dependencies Already Provided by Frozen Phase 5.1

Each item below was verified against the frozen migration `supabase/migrations/20261102140000_phase5_1_learning_mastery_foundation.sql` and the Phase 1 identity migration at the reviewed baseline.

| # | Dependency | Frozen artifact | Phase 5.2 use |
|---|---|---|---|
| D1 | Immutable, version-scoped `learning_nodes` | `learning_nodes(id, catalog_version, node_type, subject_key, canonical_key, title, parent_id, grade_min, grade_max, sort_order, is_active)`; strict `subject -> domain -> topic -> skill` parent chain; same-version / same-subject parent edges; published (`active`/`retired`) content immutable (`LW102`) | Candidate universe, hierarchy, coverage, catalog path ordering, grade bounds |
| D2 | Skill-only, same-version, same-subject prerequisite DAG | `learning_prerequisites(catalog_version, subject_key, prerequisite_node_id, dependent_node_id)` with composite FKs to `learning_nodes(catalog_version, subject_key, id)`; no self edges; Skill-only + acyclic validated at promotion | Unlock eligibility and prerequisite state |
| D3 | Single active catalog | `learning_catalog_versions` with partial unique index on `status = 'active'`; `LW501` when none active; platform-only draft/promotion | Phase 5.2 reads only the active catalog |
| D4 | Immutable learning evidence atoms | `learning_evidence_events` (append-only, mutation trigger) with `node_type`, `subject_key`, `score_source`, `performance_pct`, `difficulty`, `specificity_weight`, `level_weight`, `effective_occurred_at`, `verified_at`, `verified_learning_event_id`; `UNIQUE(verified_learning_event_id, learning_node_id)` | Freshness, Recovery replay, latest evidence |
| D5 | Diagnostic facts | `learning_evidence_events.item_count`, `correct_count` (derived `incorrect_count = item_count - correct_count`) | Item-group Recovery raise rule |
| D6 | Deterministic canonical evidence order | `effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC` (Dart `MasteryEngine.sortCanonical`, PostgreSQL rebuild) | Recovery replay order and tie-breaks |
| D7 | Current mastery projection | `child_mastery_states(child_id, learning_node_id, family_id, mastery_score, effective_evidence_count, distinct_assessment_count, last_evidence_event_id, last_evidence_occurred_at, last_verified_at, mastery_attained_at)` | Seen/unseen classification, bands, latest evidence |
| D8 | Sticky attainment | `mastery_attained_at` stamped once at the server declaration instant; Mastered band requires `mastery_attained_at <= as_of` | Prerequisite satisfaction contract |
| D9 | Server-authoritative `as_of` | `public.get_child_mastery` captures `transaction_timestamp()` once and delegates to `private.get_child_mastery_at(p_child_id, p_as_of)` | Single request clock for all Phase 5.2 derivations |
| D10 | Current grade context | `child_profiles.school_grade smallint NULL CHECK (school_grade BETWEEN 1 AND 12)` | Grade filtering for Unlock / Explore |
| D11 | Authorization helpers | `private.is_active_family_adult(p_family_id)` (active `owner`/`parent` membership), `private.is_active_child_device(p_family_id, p_child_id)` (active exact-child device grant); active-child filter `child_profiles.status = 'active'` | Read RPC authorization, sibling isolation |
| D12 | Dart/PostgreSQL parity infrastructure | `fixtures/learning_v01_parity_fixtures.json`, `packages/learnward_domain/test/mastery_parity_test.dart`, `scripts/test_learning_parity.mjs` (owner-role calls to `private.*_at` with explicit `as_of`) | Template for Phase 5.2 recommendation parity |
| D13 | Reward / economy independence | Learning Engine has no read or write path to XP/RP ledgers, balances, rewards, redemptions or Wheel | Recommendations must stay economy-blind |

Verdict: **all upstream dependencies required by Phase 5.2 exist and are frozen.** No Phase 5.1 schema, function, trigger or seed change is needed.

### 2.1 Active catalog content at baseline

The active catalog is `pilot-v0.1` (immutable). Relevant content:

| Node | Type | Grades | Prerequisites |
|---|---|---|---|
| `pilot-v0.1:subject:{math,english,literature,science,other}` | subject | — | — |
| `pilot-v0.1:math:arithmetic` | domain | 1–6 | — |
| `pilot-v0.1:math:arithmetic:addition` | topic | 1–4 | — |
| `pilot-v0.1:math:arithmetic:addition:single_digit` | skill | 1–2 | none |
| `pilot-v0.1:math:arithmetic:addition:double_digit` | skill | 2–4 | `single_digit` |
| `pilot-v0.1:english:grammar` | domain | 1–8 | — |
| `pilot-v0.1:english:grammar:punctuation` | topic | 1–5 | — |
| `pilot-v0.1:english:grammar:punctuation:end_marks` | skill | 1–3 | none |

This is sufficient to prove prerequisite traversal (one edge), Unlock (`double_digit`), Explore (`single_digit`, `end_marks`), grade filtering (distinct bounded ranges), Freshness, Recovery and Next Challenge. Richer graph scenarios are exercised through transactional test fixtures (Section 4.4 of the detailed design), never by mutating `pilot-v0.1`.

---

## 3. What Phase 5.2 Must Add

| # | Addition | Kind |
|---|---|---|
| A1 | `FreshnessEngine` (Dart) + SQL equivalent | Pure read-time derivation |
| A2 | `RecoveryEngine` (Dart) + SQL equivalent (canonical replay, dual visibility) | Pure read-time derivation |
| A3 | Learning node state derivation over the **active catalog** (seen + unseen nodes, consuming Phase 5.1 mastery/confidence) | Pure read-time derivation |
| A4 | `NextChallengeEngine` (Dart) + SQL equivalent: partition, eligibility, comparator, limit | Pure read-time derivation |
| A5 | Coverage-aware learning overview (no naive averages) | Pure read-time derivation |
| A6 | `public.get_child_learning_overview(uuid)`, `public.get_node_learning_state(uuid, uuid)`, `public.get_next_challenge_candidates(uuid, text, integer)` | `SECURITY DEFINER`, `STABLE`, read-only RPCs |
| A7 | Owner-only `private.*_at(..., p_as_of)` evaluation-clock helpers for parity tests | Internal functions, no app-role grant |
| A8 | Domain types, repository port extensions, application use cases | Dart packages |
| A9 | Supabase data adapter + fakes + in-memory dev repository | Dart packages |
| A10 | Parent learning overview, node detail, child Next Challenge choice UI | Flutter |
| A11 | pgTAP suite, recommendation parity fixtures/script, security and economy-invariance tests | Tests / CI |

Phase 5.2 adds **no tables**, no mutable recommendation/freshness/recovery state, no catalog content, and no change to Phase 5.1 functions.

---

## 4. Readiness Blockers and Resolution

The blockers raised in gates `6594086334` and `6594895418` are resolved in the detailed design:

| Blocker | Resolution (design section) |
|---|---|
| 1. Developing vs Refresh overlap | Total, mutually exclusive partition with priority Recovery > Refresh > Developing > Unlock > Explore (§7) |
| 2. Unseen Freshness / candidate universe | Universe = active-catalog `learning_nodes` left-joined to child state; unseen Freshness = `unknown` (§4.1, §5) |
| 3. Recovery canonical scan & dual visibility | Deterministic canonical replay with 30-day expiry and `effective_occurred_at <= as_of AND verified_at <= as_of` (§6) |
| 4. Explore `nearby` + tie-breaks | Proximity ranks 0–3 and global total comparator ending in `learning_node_id` (§10, §11) |
| 5. Catalog rollout / content scope | Active catalog only, version-scoped node identity, no cross-version carry-forward, no `pilot-v0.1` mutation, no promotion in Phase 5.2 (§4.3, §4.4) |
| 6. Stale Phase 5.1 test requirement | `docs/13` Section 27 tests 28–29 corrected to the frozen `UNIQUE(assessment_id, learning_node_id, component_key)` contract |
| 7. RPC / payload contracts | Exact signatures, error codes and canonical response schemas (§13, §14) |
| 8. Exact source of mastery / confidence semantics | Explicitly frozen: Phase 5.2 is a consumer of Phase 5.1 Mastery/Confidence; reuses exact `private.get_child_mastery_at` / `ConfidenceEngine.evaluate` formulas at same `as_of` (§4.2) |
| 9. `recommended_difficulty` for unseen Topic | Explicitly frozen: `null` for unseen Topic, unseen Subject/Domain, and locked/incompatible unseen Skills (§12.2) |
| 10. `prerequisite_state.dependents` contract | Explicitly frozen: active-catalog Skills depending directly on inspected node with prerequisite/grade status, sorted deterministically by `catalog_sort_path ASC, learning_node_id ASC` (§8.2) |
| 11. `private.*_at` evaluation-clock semantics | Explicitly frozen: evaluation clock over current committed projection (not arbitrary historical event-sourced reconstruction) with dual evidence visibility `verified_at <= as_of AND effective_occurred_at <= as_of` (§3.2, §3.3) |

---

## 5. Risks Carried Into Implementation

| Risk | Mitigation |
|---|---|
| Dart/PostgreSQL divergence in ordering (UUID, arrays, numerics) | Comparator specifies UUID byte order = lowercase canonical string order, integer-array lexicographic order, scores compared at 2-decimal precision |
| Future-verified evidence leaking into historical evaluation frames | Dual visibility filter requires `effective_occurred_at <= as_of AND verified_at <= as_of` |
| Attempting full historical mastery reconstruction | Clarified boundary: `private.*_at` evaluates time-varying read fields over current committed projection; full historical reconstruction is deferred |
| Sparse pilot catalog limits UX realism | Transactional fixtures for richer graphs; content expansion deferred to a separate platform catalog-release gate |
| Redundant Topic + child Skill candidates | Accepted in v0.1 (distinct node IDs, deterministic); ancestor/descendant suppression deferred |

---

## 6. Verdict

```text
Phase 5.1 dependencies          SATISFIED (frozen, unchanged)
Phase 5.2 design blockers       RESOLVED IN DESIGN (pending independent audit)
Phase 5.2 implementation        NOT AUTHORIZED / NOT STARTED
```

Implementation may begin only after the design PR receives an independent PASS / MERGE READY and is merged with green CI.
