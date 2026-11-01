# Phase 3 Freeze Receipt — Growth Engine + XP/RP Ledger Foundation

**Status:** FROZEN  
**Frozen code baseline (Merge SHA):** `c6721497bfbde7cb436467cccaad5b2234d23cc4`  
**Approved PR HEAD:** `443eb5ec81e09711c31cb1ce37c5deaa3a783bcc`  
**Merged PR:** [PR #4 — Phase 3: Growth engine + XP/RP ledger foundation](https://github.com/thedusk4203/LearnWard/pull/4)  
**Independent Review ID:** `6556188920` (APPROVED)  
**Post-merge CI Run ID:** `41293964415` — **SUCCESS**  
**Freeze date:** 2026-11-01  
**Engine Version:** `growth-v0.1`  

---

## 1. Scope Frozen

Phase 3 establishes the deterministic Growth Engine v0.1 calculation, integer minor-unit reward conventions, immutable append-only economic ledgers, fast balance projections, single-MVCC-snapshot balance reconciliation, and recoverable exactly-once event processing.

Frozen capabilities:
- Pure Dart Growth Engine v0.1 in `learnward_domain` with zero external flutter/platform dependencies.
- Strict dual currency convention:
  - **Study XP:** Permanent progression resource represented as non-negative integer amount (`amount` in `xp_ledger`, `xp_total` in `child_balances`).
  - **Reward Points (RP):** Spendable reward resource represented as integer minor units (`amount_minor` in `rp_ledger`, `rp_balance_minor` in `child_balances`), where $100\text{ minor units} = 1.00\text{ RP}$.
- Canonical Growth award rules (`growth-v0.1`):
  - **Base Score RP:** $\text{round}(\text{normalized\_score} \times 100)$ minor units (scale 0–1000).
  - **Growth Bonus RP:** Evaluated against a 3-sample rolling baseline of prior comparable assessments:
    - $\Delta < 0.50 \implies 0\text{ minor units}$
    - $0.50 \le \Delta < 1.00 \implies +100\text{ minor units}$ ($+1.00\text{ RP}$)
    - $1.00 \le \Delta < 1.50 \implies +200\text{ minor units}$ ($+2.00\text{ RP}$)
    - $1.50 \le \Delta < 2.00 \implies +300\text{ minor units}$ ($+3.00\text{ RP}$)
    - $\Delta \ge 2.00 \implies +400\text{ minor units}$ ($+4.00\text{ RP}$)
  - **High Performer Bonus RP:** $+100\text{ minor units}$ ($+1.00\text{ RP}$) when both baseline $\ge 8.50$ AND current normalized score $\ge 8.50$.
  - **Personal Best (PB) Bonus RP:** $+100\text{ minor units}$ ($+1.00\text{ RP}$) when current normalized score $\ge \text{historical\_best} + 0.25$.
  - **Difficulty Bonus RP:**
    - `hard` $\implies +100\text{ minor units}$ ($+1.00\text{ RP}$)
    - `challenge` $\implies +200\text{ minor units}$ ($+2.00\text{ RP}$) if normalized score $\ge 5.00$ (0 if $< 5.00$).
  - **Anti-Farming Below-Level Protection:** If difficulty is `below_level`, base RP is reduced to $25\%$ of normal ($\text{round}(\text{raw\_base} \times 0.25)$), and all bonus RP (Growth, High Performer, PB, Difficulty) are clamped to $0$.
  - **Study XP Formula:** Deterministic linear function of total RP minor units:
    $$\text{XP} = 10 + \text{round}\left(2 \times \frac{\text{total\_rp\_minor}}{100}\right)$$
- Server-authoritative, immutable grade provenance:
  - `grade_level_snapshot` is derived server-side on assessment INSERT from the child's `school_grade` and copied immutably into `verified_learning_events`.
  - Database constraint: `grade_level_snapshot is null or (grade_level_snapshot >= 1 and grade_level_snapshot <= 12)`.
  - Fail-closed behavior: assessments with unknown (`null`) grade snapshot do not infer a grade, are excluded from longitudinal comparability, cannot compute baselines, and award $0$ for Growth, High Performer, and PB bonuses.
- Longitudinal comparability rules:
  - Two results are comparable if and only if they share:
    1. Same `child_id`
    2. Same canonical `subject_key`
    3. Same known `grade_level_snapshot`
    4. Compatible assessment type band (`quiz`/`exam` vs `homework`/`practice`)
    5. Compatible difficulty band (`normal`/`hard` vs `challenge` vs `below_level`)
    6. Strictly prior chronological timestamp (`occurred_at < current.occurred_at` OR `(occurred_at == current.occurred_at AND verified_at < current.verified_at)`)
  - Subject-level fallback applies cleanly while topic taxonomies remain unstandardized.
- Rolling baseline calculation:
  - Arithmetic mean of the most recent 3 prior comparable assessments, rounded to 2 decimal places.
  - Requires $\ge 3$ prior comparable assessments; otherwise baseline is unavailable and longitudinal bonuses are not evaluated.
- Dual append-only authoritative economic ledgers (`xp_ledger` and `rp_ledger`):
  - Source tracking (`source_type`, `source_id`, `engine_version`).
  - Natural unique idempotency keys (`idempotency_key`).
  - Immutability triggers reject all application `UPDATE` and `DELETE` operations (`LW102`); trusted future corrections must use compensating ledger entries rather than rewriting history.
  - Amount constraint on `xp_ledger`: `amount >= 0 or reason_code = 'correction'`.
- Balance projections and concurrency serialization:
  - `public.child_balances` caches current balances (`xp_total`, `rp_balance_minor`) for fast client queries.
  - `process_verified_learning_event` acquires a row-level lock (`SELECT ... FOR UPDATE`) on the target `verified_learning_events` record, serializing processing of the same verified learning event.
  - Ledger writes and balance projection updates occur in the same database transaction; `child_balances` is updated through atomic `INSERT ... ON CONFLICT DO UPDATE`.
  - Ledgers are the sole source of truth; projections are derived.
- Read-only single-snapshot balance reconciliation:
  - `reconcile_child_balance` executes within a single SQL statement / single MVCC snapshot.
  - Validates caller authorization (active adult membership in the child's family or exact paired child identity).
  - Verifies projection integrity against ledger sums without side-effects or mutative repairs, returning structured tabular verification columns (`out_child_id`, `out_family_id`, `is_reconciled`, `projected_xp`, `ledger_xp`, `projected_rp_minor`, `ledger_rp_minor`).
- Exactly-once delivery & recovery:
  - 1 `VerifiedLearningEvent` produces at most 1 `GrowthEvent`, enforced by unique constraint `growth_events.verified_learning_event_id`. Furthermore, `growth_events.assessment_id` is unique.
  - `get_unprocessed_verified_learning_events(p_family_id)` discovers verified events lacking corresponding `growth_events`.
  - `catch_up_unprocessed_growth(p_family_id)` sequentially processes unhandled Growth events per family after network or client interruptions.
- Mobile UI:
  - `GrowthResultScreen` presenting celebratory XP/RP animations, itemized breakdown cards, baseline comparison chips, and updated balances.

---

## 2. Frozen Database Surface

### Tables

- `public.growth_events`:
  - `id uuid primary key default gen_random_uuid()`
  - `family_id uuid not null references public.families(id) on delete cascade`
  - `child_id uuid not null references public.child_profiles(id) on delete cascade`
  - `verified_learning_event_id uuid not null unique references public.verified_learning_events(id) on delete restrict`
  - `assessment_id uuid not null unique references public.assessments(id) on delete restrict`
  - `engine_version text not null`
  - `normalized_score numeric(4, 2) not null`
  - `baseline_score numeric(4, 2) null`
  - `baseline_sample_count integer not null default 0 check (baseline_sample_count >= 0)`
  - `growth_delta numeric(4, 2) null`
  - `historical_best numeric(4, 2) null`
  - `score_rp_minor bigint not null check (score_rp_minor >= 0)`
  - `growth_rp_minor bigint not null default 0 check (growth_rp_minor >= 0)`
  - `high_performer_rp_minor bigint not null default 0 check (high_performer_rp_minor >= 0)`
  - `goal_rp_minor bigint not null default 0 check (goal_rp_minor >= 0)`
  - `personal_best_rp_minor bigint not null default 0 check (personal_best_rp_minor >= 0)`
  - `difficulty_rp_minor bigint not null default 0 check (difficulty_rp_minor >= 0)`
  - `recovery_rp_minor bigint not null default 0 check (recovery_rp_minor >= 0)`
  - `below_level_adjustment boolean not null default false`
  - `total_rp_minor bigint not null check (total_rp_minor >= 0)`
  - `xp_awarded integer not null check (xp_awarded >= 0)`
  - `inputs_snapshot jsonb not null`
  - `created_at timestamptz not null default now()`
  - Foreign key: `(child_id, family_id) references public.child_profiles(id, family_id) on delete cascade`
  - Indexes: `(child_id, created_at desc)`, `(family_id)`
  - Immutability trigger: `trg_prevent_growth_event_mutation` rejects `UPDATE` and `DELETE` (`LW102`)

- `public.xp_ledger`:
  - `id uuid primary key default gen_random_uuid()`
  - `family_id uuid not null references public.families(id) on delete cascade`
  - `child_id uuid not null references public.child_profiles(id) on delete cascade`
  - `amount integer not null`
  - `reason_code text not null`
  - `source_type text not null`
  - `source_id uuid null`
  - `engine_version text null`
  - `idempotency_key text not null unique`
  - `metadata jsonb not null default '{}'::jsonb`
  - `created_at timestamptz not null default now()`
  - Constraint: `chk_xp_ledger_amount check (amount >= 0 or reason_code = 'correction')`
  - Foreign key: `(child_id, family_id) references public.child_profiles(id, family_id) on delete cascade`
  - Index: `(child_id, created_at asc)`
  - Immutability trigger: `trg_prevent_xp_ledger_mutation` rejects `UPDATE` and `DELETE` (`LW102`)

- `public.rp_ledger`:
  - `id uuid primary key default gen_random_uuid()`
  - `family_id uuid not null references public.families(id) on delete cascade`
  - `child_id uuid not null references public.child_profiles(id) on delete cascade`
  - `amount_minor bigint not null`
  - `reason_code text not null`
  - `source_type text not null`
  - `source_id uuid null`
  - `engine_version text null`
  - `idempotency_key text not null unique`
  - `metadata jsonb not null default '{}'::jsonb`
  - `created_at timestamptz not null default now()`
  - Foreign key: `(child_id, family_id) references public.child_profiles(id, family_id) on delete cascade`
  - Index: `(child_id, created_at asc)`
  - Immutability trigger: `trg_prevent_rp_ledger_mutation` rejects `UPDATE` and `DELETE` (`LW102`)

- `public.child_balances`:
  - `family_id uuid not null references public.families(id) on delete cascade`
  - `child_id uuid primary key references public.child_profiles(id) on delete cascade`
  - `xp_total bigint not null default 0 check (xp_total >= 0)`
  - `rp_balance_minor bigint not null default 0 check (rp_balance_minor >= 0)`
  - `updated_at timestamptz not null default now()`
  - Foreign key: `(child_id, family_id) references public.child_profiles(id, family_id) on delete cascade`
  - Index: `(family_id)`

### Schema Alterations

- `public.assessments`:
  - Added `grade_level_snapshot integer null check (grade_level_snapshot is null or (grade_level_snapshot >= 1 and grade_level_snapshot <= 12))`
- `public.verified_learning_events`:
  - Added `grade_level_snapshot integer null check (grade_level_snapshot is null or (grade_level_snapshot >= 1 and grade_level_snapshot <= 12))`
- `public.command_receipts`:
  - Extended `operation` check constraint: `check (operation in ('create_draft', 'submit', 'verify', 'reject', 'process_growth'))`

### Trusted SECURITY DEFINER Functions

- `public.process_verified_learning_event(p_verified_event_id uuid, p_command_id uuid default null) returns public.growth_events`
- `public.reconcile_child_balance(p_child_id uuid) returns table (out_child_id uuid, out_family_id uuid, is_reconciled boolean, projected_xp bigint, ledger_xp bigint, projected_rp_minor bigint, ledger_rp_minor bigint)`
- `public.get_unprocessed_verified_learning_events(p_family_id uuid) returns setof public.verified_learning_events`
- `public.catch_up_unprocessed_growth(p_family_id uuid) returns integer`
- `private.set_assessment_grade_snapshot()` (trigger on `assessments` before insert)
- `private.set_vle_grade_snapshot()` (trigger on `verified_learning_events` before insert)
- `private.prevent_growth_event_mutation()` (trigger on `growth_events` before update or delete)
- `private.prevent_xp_ledger_mutation()` (trigger on `xp_ledger` before update or delete)
- `private.prevent_rp_ledger_mutation()` (trigger on `rp_ledger` before update or delete)

---

## 3. Explicitly Frozen Invariants

1. **Deterministic Double Parity:** The Dart domain Growth Engine and the PostgreSQL `process_verified_learning_event` function produce bitwise-identical results across all award dimensions for any given input. This is continuously verified by shared 17-fixture canonical parity suites (`growth_v01_parity_fixtures.json`).
2. **Integer Minor Unit Currency Representation:** All Reward Point calculations and ledger records use integer minor units ($100\text{ minor units} = 1.00\text{ RP}$). No fractional points or floating-point approximations are stored.
3. **Immutable Grade Provenance:** Grade level is captured server-side upon assessment creation via trigger and copied immutably into `verified_learning_events`. Client-supplied grade overrides are discarded. Mutable profile updates never alter historical assessment grade provenance.
4. **Fail-Closed Missing Grade:** If an assessment or historical comparator lacks a grade snapshot, it fails closed: it cannot establish longitudinal comparability or baseline, and awards zero longitudinal bonuses.
5. **Strict Comparability Boundaries:** Comparisons are restricted to identical child, identical canonical `subject_key`, identical known `grade_level_snapshot`, compatible assessment type bands, compatible difficulty bands, and strictly prior timestamps (`occurred_at < current.occurred_at` OR `(occurred_at == current.occurred_at AND verified_at < current.verified_at)`).
6. **Append-Only Ledgers (LW102):** Ordinary application/client mutation is prohibited. `UPDATE` and `DELETE` on `public.xp_ledger`, `public.rp_ledger`, and `public.growth_events` are blocked by immutability triggers (raising exception code `LW102`). Trusted future corrections must use compensating ledger entries rather than rewriting history.
7. **Projection Subservience:** `public.child_balances` is a derived read cache. The ledgers are the authoritative source of truth.
8. **Concurrency Serialization & Atomic Updates:** `process_verified_learning_event` acquires a row-level lock (`SELECT ... FOR UPDATE`) on the target `verified_learning_events` record, serializing concurrent processing of the same VerifiedLearningEvent. Ledger writes and `child_balances` projection updates occur in the same database transaction; `child_balances` is updated through atomic `INSERT ... ON CONFLICT DO UPDATE`.
9. **Single-Snapshot Authoritative Reconciliation:** `reconcile_child_balance` is strictly read-only, executes within a single SQL statement / single MVCC snapshot, requires family authorization (active adult of the child's family or exact paired child identity), and compares projection against ledger sums without side-effects or table-level locks.
10. **Exactly-Once Processing:** 1 `VerifiedLearningEvent` produces at most 1 `GrowthEvent` (enforced by unique constraint on `growth_events.verified_learning_event_id`, with `assessment_id` also uniquely constrained), exactly 1 XP ledger entry, and exactly 1 RP ledger entry. Repeated invocations return the existing record idempotently.
11. **Recoverable Delivery:** If client connectivity fails after verification but before Growth presentation, `get_unprocessed_verified_learning_events(p_family_id)` identifies pending events and `catch_up_unprocessed_growth(p_family_id)` safely processes them sequentially.

---

## 4. Intentionally Deferred Scope

The following capabilities are explicitly deferred to subsequent phases:
- **Phase 4:** Reward Economy & Wheel Experience (Reward Store, Wheel spin mechanics, probability bands, RP redemption, fulfillment tracking, daily spin caps).
- **Phase 5:** Learning Engine & Mastery Model (knowledge skill graph, Bayesian/decayed confidence scoring, next challenge generation).
- **Deferred Growth Engine v0.1 Rules:**
  - Goal bonus ($0\text{ RP}$ in v0.1)
  - Recovery bonus ($0\text{ RP}$ in v0.1)
- **Future:** Dedicated child-device pairing/activation, OCR/AI photo score extraction, custom achievements and levels.

---

## 5. Verification Receipt

### Post-Merge CI Execution on `main`
- **Commit SHA:** `c6721497bfbde7cb436467cccaad5b2234d23cc4`
- **GitHub Actions Run ID:** `41293964415`
- **Status:** **SUCCESS**

| Job | Result | Duration |
| :--- | :---: | :---: |
| **Format, analyze and test** | `pass` | 2m 36s |
| **Supabase migrations & RLS security** | `pass` | 3m 07s |
| **iOS simulator compile** | `pass` | 2m 28s |
| **Android debug build** | `pass` | 7m 55s |

### Test Baseline at Freeze
- **Domain tests (`packages/learnward_domain`):** 83 passed
- **Application tests (`packages/learnward_application`):** 18 passed
- **Data tests (`packages/learnward_data`):** 9 passed
- **Test support tests (`packages/learnward_test_support`):** 1 passed
- **Design system tests (`packages/learnward_design_system`):** 2 passed
- **Mobile widget tests (`apps/mobile`):** 31 passed
- **pgTAP database tests (`supabase/tests/database`):** 126 passed
- **Cross-language canonical parity fixtures:** 17/17 passed
- **Growth concurrency regression test:** PASS
- **Growth delivery recovery integration test:** PASS
- **Growth vertical slice integration test:** PASS
- **Last-owner concurrency regression:** PASS
- **Assessment verification concurrency regression:** PASS
- **Storage evidence security suite:** PASS
- **Android debug APK artifact:** Built and uploaded (`learnward-debug-apk`)
- **iOS simulator build:** Compiled successfully

---

## 6. Documentation Correction

- **Original Freeze Commit:** `73a871b03474d5c470f73103e54f1cd504247067`
- **Correction Date:** 2026-11-01
- **Reason:** Corrected freeze receipt terminology, schema column names, RPC signatures, and concurrency descriptions to match the already-frozen implementation.
- **Explicit Statement:** No Phase 3 code, migration, formula, security rule, or runtime behavior changed.
- **Frozen Code Baseline Remains:** `c6721497bfbde7cb436467cccaad5b2234d23cc4`
