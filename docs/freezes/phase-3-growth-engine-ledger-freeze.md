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
  - **Study XP:** Permanent progression resource represented as non-negative integer amount (`xp_amount`).
  - **Reward Points (RP):** Spendable reward resource represented as integer minor units (`rp_minor`), where $100\text{ minor units} = 1.00\text{ RP}$.
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
  - **Anti-Farming Below-Level Protection:** If difficulty is `below_level`, base RP is reduced to $25\%$ of normal ($\text{round}(\text{raw\_base} \times 0.25)$), and all bonus RP (Growth, High Performer, PB, Challenge) are clamped to $0$.
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
    6. Prior chronological timestamp (`occurred_at < current.occurred_at` or `occurred_at == current.occurred_at` and `id < current.id`)
  - Subject-level fallback applies cleanly while topic taxonomies remain unstandardized.
- Rolling baseline calculation:
  - Arithmetic mean of the most recent 3 prior comparable assessments, rounded to 2 decimal places.
  - Requires $\ge 3$ prior comparable assessments; otherwise baseline is unavailable and longitudinal bonuses are not evaluated.
- Append-only financial ledgers (`xp_ledger` and `rp_ledger`):
  - Source tracking (`source_type`, `source_id`).
  - Running balance checkpoint (`balance_after`).
  - Triggers reject all `UPDATE` and `DELETE` queries unconditionally (`LW102`).
- Balance projections and concurrency serialization:
  - `public.child_balances` caches current balances for sub-millisecond client queries.
  - Row-level lock (`SELECT ... FOR UPDATE`) on `child_balances` serializes concurrent event processing per child, preventing race conditions.
  - Ledgers are the sole source of truth; projections are derived.
- Read-only single-snapshot balance reconciliation:
  - `reconcile_child_balance` executes within a single MVCC snapshot.
  - Validates caller authorization (tenant family membership or exact child identity).
  - Verifies projection integrity against ledger sums without side-effects.
- Exactly-once delivery & recovery:
  - 1 `VerifiedLearningEvent` produces at most 1 `GrowthEvent`, enforced by unique constraint `growth_events.verified_event_id`.
  - `catch_up_unprocessed_growth` recovers unhandled Growth events after network or client interruptions.
- Mobile UI:
  - `GrowthResultScreen` presenting celebratory XP/RP animations, itemized breakdown cards, baseline comparison chips, and updated balances.

---

## 2. Frozen Database Surface

### Tables

- `public.growth_events`:
  - `id uuid primary key default gen_random_uuid()`
  - `family_id uuid not null references public.families(id)`
  - `child_id uuid not null references public.child_profiles(id)`
  - `verified_event_id uuid not null unique references public.verified_learning_events(id)`
  - `assessment_id uuid not null references public.assessments(id)`
  - `engine_version text not null check (engine_version = 'growth-v0.1')`
  - `total_xp integer not null check (total_xp >= 0)`
  - `total_rp_minor integer not null check (total_rp_minor >= 0)`
  - `breakdown jsonb not null`
  - `inputs_snapshot jsonb not null`
  - `occurred_at timestamptz not null`
  - `created_at timestamptz not null default now()`

- `public.xp_ledger`:
  - `id uuid primary key default gen_random_uuid()`
  - `family_id uuid not null references public.families(id)`
  - `child_id uuid not null references public.child_profiles(id)`
  - `source_type text not null check (source_type in ('growth_event', 'reconciliation_adjustment', 'manual_grant'))`
  - `source_id uuid not null`
  - `amount integer not null check (amount >= 0)`
  - `balance_after integer not null check (balance_after >= 0)`
  - `created_at timestamptz not null default now()`

- `public.rp_ledger`:
  - `id uuid primary key default gen_random_uuid()`
  - `family_id uuid not null references public.families(id)`
  - `child_id uuid not null references public.child_profiles(id)`
  - `source_type text not null check (source_type in ('growth_event', 'reconciliation_adjustment', 'manual_grant', 'redemption'))`
  - `source_id uuid not null`
  - `amount integer not null`
  - `balance_after integer not null check (balance_after >= 0)`
  - `created_at timestamptz not null default now()`

- `public.child_balances`:
  - `child_id uuid primary key references public.child_profiles(id)`
  - `family_id uuid not null references public.families(id)`
  - `total_xp integer not null default 0 check (total_xp >= 0)`
  - `available_rp_minor integer not null default 0 check (available_rp_minor >= 0)`
  - `lifetime_rp_minor integer not null default 0 check (lifetime_rp_minor >= 0)`
  - `updated_at timestamptz not null default now()`

### Schema Alterations

- `public.assessments`:
  - Added `grade_level_snapshot integer null check (grade_level_snapshot is null or (grade_level_snapshot >= 1 and grade_level_snapshot <= 12))`
- `public.verified_learning_events`:
  - Added `grade_level_snapshot integer null check (grade_level_snapshot is null or (grade_level_snapshot >= 1 and grade_level_snapshot <= 12))`

### Trusted SECURITY DEFINER Functions

- `public.process_verified_learning_event(p_verified_event_id uuid) returns public.growth_events`
- `public.reconcile_child_balance(p_child_id uuid) returns jsonb`
- `public.catch_up_unprocessed_growth(p_child_id uuid) returns setof public.growth_events`
- `private.set_assessment_grade_snapshot()` (trigger on `assessments` before insert)
- `private.set_vle_grade_snapshot()` (trigger on `verified_learning_events` before insert)

---

## 3. Explicitly Frozen Invariants

1. **Deterministic Double Parity:** The Dart domain Growth Engine and the PostgreSQL `process_verified_learning_event` function produce bitwise-identical results across all award dimensions for any given input. This is continuously verified by shared 17-fixture canonical parity suites (`growth_v01_parity_fixtures.json`).
2. **Integer Minor Unit Currency Representation:** All Reward Point calculations and ledger records use integer minor units ($100\text{ minor units} = 1.00\text{ RP}$). No fractional points or floating-point approximations are stored.
3. **Immutable Grade Provenance:** Grade level is captured server-side upon assessment draft creation and copied immutably. Client-supplied grade overrides are discarded. Mutable profile updates never alter historical assessment grade provenance.
4. **Fail-Closed Missing Grade:** If an assessment or historical comparator lacks a grade snapshot, it fails closed: it cannot establish longitudinal comparability or baseline, and awards zero longitudinal bonuses.
5. **Strict Comparability Boundaries:** Comparisons are restricted to identical child, identical `subject_key`, identical grade snapshot, compatible assessment bands, compatible difficulty bands, and strictly prior timestamps.
6. **Append-Only Ledgers (LW102):** `public.xp_ledger` and `public.rp_ledger` reject all `UPDATE` and `DELETE` operations unconditionally, even for database superusers.
7. **Projection Subservience:** `public.child_balances` is a derived read cache. The ledgers are the authoritative source of truth.
8. **Serialized Concurrency:** Concurrent mutations for a given child are serialized via `SELECT ... FOR UPDATE` row-level locks on `child_balances`, preventing race conditions during ledger appends.
9. **Single-Snapshot Authoritative Reconciliation:** `reconcile_child_balance` is strictly read-only, runs in a single transaction snapshot, requires family authorization, and compares projection against sum of ledgers without out-of-band writes.
10. **Exactly-Once Processing:** 1 `VerifiedLearningEvent` produces at most 1 `GrowthEvent` and exactly 1 XP ledger entry and 1 RP ledger entry. Repeated invocations return the existing record idempotently.
11. **Recoverable Delivery:** If client connectivity fails after verification but before Growth presentation, `catch_up_unprocessed_growth` safely delivers the processed Growth event.

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
