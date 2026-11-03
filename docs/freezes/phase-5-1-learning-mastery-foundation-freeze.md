# Phase 5.1 Freeze Receipt — Learning Engine, Mastery & Confidence Foundation

**Status:** FROZEN  
**Target:** Phase 5.1 — Learning Engine, Mastery & Confidence Foundation  
**PR:** [#9 — feat(phase-5.1): implement learning engine, mastery and confidence foundation](https://github.com/thedusk4203/LearnWard/pull/9)  
**Approved Implementation HEAD:** `7cf8661444212a3e891fe152f855d160b27cccc2`  
**Independent Audit:** PASS / MERGE READY (Comment `6592730362`)  
**Merge Commit SHA:** `6bb663286746851993d9c66c551e85fe3b9b41a4`  
**Post-merge Main CI Run ID:** `41558681324` — **SUCCESS (4/4 green)**  
**Merge Timestamp:** `2026-11-03T01:16:43Z`  
**Freeze Date:** 2026-11-03  
**Freeze Receipt PR Comment:** [Issue Comment 6592996483](https://github.com/thedusk4203/LearnWard/pull/9#issuecomment-6592996483)  
**ADR:** 0006 (ACCEPTED)  

---

## 1. Test Suite Verification Totals

| Test Suite | Total Tests | Passed | Result |
|---|---|---|---|
| **Database & RLS pgTAP** (7 files) | 377 | 377 | **PASS** |
| - *Phase 5.1 Mastery Foundation* (`07_learning_mastery_foundation_test.sql`) | 135 | 135 | **PASS** |
| - *Phase 4 Reward & Wheel* (`06_reward_economy_wheel_test.sql`) | 114 | 114 | **PASS** |
| - *Phase 3 Growth Engine* (`05_growth_engine_ledger_test.sql`) | 71 | 71 | **PASS** |
| - *Phase 1–2 Tests* (`01`–`04`) | 57 | 57 | **PASS** |
| **Domain Tests** (`packages/learnward_domain`) | 134 | 134 | **PASS** |
| **Application Tests** (`packages/learnward_application`) | 40 | 40 | **PASS** |
| **Data Tests** (`packages/learnward_data`) | 28 | 28 | **PASS** |
| **Test Support Tests** (`packages/learnward_test_support`) | 1 | 1 | **PASS** |
| **Design System Tests** (`packages/learnward_design_system`) | 2 | 2 | **PASS** |
| **Flutter Widget Tests** (`apps/mobile`) | 51 | 51 | **PASS** |
| **Cross-Platform Parity Fixtures** (PostgreSQL <-> Dart) | 13 | 13 | **PASS** |
| **Concurrency Regressions** (Last-owner, Assessment review, Growth ledger, Wheel spin, Learning mastery) | All | All | **PASS** |
| **Vertical Slice Integrations** (Assessment, Growth, Wheel, Learning) | All | All | **PASS** |

---

## 2. Frozen Phase 5.1 Contract Summary

1. **Catalog Registry + Platform-Only Lifecycle:**
   - Dedicated `learning_catalog_versions` table with partial unique index enforcing exactly one active version.
   - Zero caller-settable GUCs. Authorization enforced via role privileges and dedicated `SECURITY DEFINER` routines.
   - Platform-only authoring: draft creation isolated in `public.create_learning_catalog_draft(...)` and version promotion in `public.promote_learning_catalog_version(...)`.
   - Direct `INSERT`, `UPDATE`, and `DELETE` on the registry are revoked from application roles and `service_role`.
   - Strict lifecycle: `draft -> active -> retired`, where `retired` is terminal.

2. **Five Canonical Subject Roots:**
   - Strictly validated root nodes: `math`, `reading`, `writing`, `science`, `social_studies`.
   - Pilot content seeded under version `pilot-v0.1` and promoted to `active`.

3. **Immutable Catalog Provenance:**
   - Assessments and verified learning events snapshot the authoritative active catalog version (`learning_catalog_version`) at creation.
   - Foreign key relations prevent catalog corruption or orphaned curriculum nodes.

4. **Assessment Learning Mappings:**
   - Authoritative mapping identity: `(family_id, child_id, assessment_id, learning_node_id, component_key)`.
   - Mandatory `component_key NOT NULL` enforced with `UNIQUE(assessment_id, learning_node_id, component_key)`.
   - Reserved canonical `assessment_total` key for whole-assessment node bindings.
   - System stamped `child_id` (copied from assessment) and `confirmed_by_user_id` (authenticated active adult).

5. **Effective Learning Evidence:**
   - Derived evidence events resolve node-level specificity weights (Skill 1.0, Topic 0.75, Domain 0.50, Subject 0.35) and assessment level weights (Standard 1.0, Above-level 1.25, Below-level 0.50 with 100% ceiling constraint).

6. **Canonical Deterministic Mastery Rebuild:**
   - Out-of-order and historical evidence arrival handled deterministically by rebuilding node state from the complete immutable evidence set sorted in canonical academic chronology:
     `ORDER BY effective_occurred_at ASC, verified_at ASC, verified_learning_event_id ASC`.

7. **Option A Initialization ($M_1 = P_1$):**
   - The first chronological observation directly initializes the node mastery score ($M_1 = P_1$).

8. **EWMA Subsequent Updates:**
   - Subsequent observations update score via EWMA:
     $M_t = (1 - \alpha_t) \cdot M_{t-1} + \alpha_t \cdot P_t$
     where $\alpha_t = \alpha_{\text{base}} \cdot W_{\text{spec}} \cdot W_{\text{lvl}}$ with $\alpha_{\text{base}} = 0.35$.

9. **Confidence Engine v0.1:**
   - Confidence units calculated across a rolling 60-day window:
     $\text{Units} = \sum (W_{\text{spec}} \cdot W_{\text{lvl}})$.
   - Bands: Low (<1.5 units), Medium (1.5–3.5 units), High (>3.5 units AND $\ge 2$ distinct verified learning events).

10. **Server-Authoritative Declaration Instant (`as_of`):**
    - Mastered attainment evaluated at server declaration instant `v_processing_as_of := transaction_timestamp()`.
    - Criteria for attainment: `mastery_score >= 85 AND confidence = High AND >= 2 distinct verified assessments within 60 days of v_processing_as_of`.

11. **Sticky `mastery_attained_at`:**
    - Upon declaration, `mastery_attained_at` is permanently fixed to the server declaration timestamp and retained across subsequent lower scores.

12. **Stale Historical Evidence Cannot Manufacture Mastered:**
    - Evidence occurring >60 days prior to declaration instant updates numeric mastery score but cannot satisfy rolling confidence criteria; `mastery_attained_at` remains `NULL` and band reports `mastery_candidate`.

13. **Historical Reads Obey Point-in-Time Constraint:**
    - Read projections require `mastery_attained_at <= as_of` to report Mastered. Reads before attainment (`as_of < mastery_attained_at`) do not report Mastered.

14. **Dual State Persistence (Revisions & Projections):**
    - Full calculation snapshots appended to immutable `mastery_state_revisions`.
    - Read-optimized current projections upserted in `child_mastery_states`.

15. **Idempotent `process_learning_event`:**
    - Enforced via `command_receipts` table with operation `process_learning`.
    - Per-VLE serialization lock (`pg_advisory_xact_lock`) with post-lock recheck returning committed snapshots on replay.

16. **Catch-Up Processing:**
    - `public.catch_up_unprocessed_learning(p_family_id uuid)` discovers and processes all unlinked family VLEs in chronological order.

17. **Strict Tenant & Security Boundaries:**
    - Authenticated active adult authorization required for mapping and event processing.
    - Child profiles and paired child devices permitted read-only access to their own mastery projections.
    - Cross-family and unauthenticated access denied with SQL state `42501`.

18. **Reward/Economy Independence:**
    - Learning Engine operates purely on academic mastery and skill progression, strictly decoupled from XP/RP balance inflation or reward economy rules.

19. **Dart/PostgreSQL Exact Parity:**
    - 13 cross-platform test fixtures verified across `packages/learnward_domain` and PostgreSQL database RPCs, covering all EWMA alphas, difficulty levels, confidence windows, and temporal read semantics.

---

## 3. Scope Deferred to Future Phases

- **Phase 5.2 (Skill Trees & Curated Pilot Content):** Full prerequisite graph traversal, unlocked status resolution, and curriculum tree visualization.
- **Phase 5.3 (Recommendation Engine & Next Challenge):** Next-challenge recommendation ranking, zone of proximal development scoring, and parent/child dashboard cards.
