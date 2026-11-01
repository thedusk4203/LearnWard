# ADR 0004 — Phase 3 Growth Engine and XP/RP Ledger Foundation Decisions

- **Status:** Accepted
- **Date:** 2026-11-01
- **Context:** Phase 3 transforms each immutable `VerifiedLearningEvent` into an auditable, deterministic economic award (Reward Points / RP and Study XP). This establishes the pure Growth Engine, double-entry append-only ledgers, balance projections, and tamper-proof concurrency control while explicitly deferring reward redemption, spinning wheels, and mastery graphs.

---

## Decision 1 — Pure Dart Growth Engine (`growth-v0.1`)

The core Growth Engine algorithm lives in `packages/learnward_domain` as a zero-dependency, pure Dart implementation (`GrowthEngine`):
- It depends strictly on standard library Dart primitives.
- It contains no Flutter, Drift, Supabase, or Riverpod dependencies.
- It is identified by the immutable version string `growth-v0.1`.
- Any future revision to reward calculations will define a new version (e.g. `growth-v0.2`), preserving historical auditability of prior events.

**Consequence:** The calculation logic is fully isolated, ultra-fast to test, reproducible offline, and guaranteed deterministic across mobile clients and backend runtimes.

---

## Decision 2 — Rolling baseline selection and longitudinal comparability rules

A child's performance baseline must be objective, individualized, and resistant to manipulation:
1. **Longitudinal Comparability:** A prior result is comparable if and only if it shares:
   - the identical `subject_key` (`math`, `english`, `literature`, `science`, `other`);
   - matching **Grade Level Snapshot**: results must share identical `grade_level_snapshot`;
   - a compatible **Assessment Type Band**:
     - *Evaluative band*: `quiz`, `exam`
     - *Formative band*: `homework`, `practice`
     - *Other band*: `other`
   - a compatible **Difficulty Band**:
     - *Standard band*: `normal`, `hard` (core curriculum)
     - *Challenge band*: `challenge` (advanced enrichment)
     - *Below-level band*: `below_level` (isolated anti-farming)
2. **Immutable Server-Side Grade Snapshot:** `child_profiles.school_grade` is mutable as children advance in school. To prevent historical results from older grades contaminating future grade baselines, each assessment snapshots the child's school grade server-side upon creation (`grade_level_snapshot`), which is preserved immutably into `verified_learning_events`.
   - `set_assessment_grade_snapshot` derives the grade authoritatively server-side on INSERT from `child_profiles.school_grade`; caller-supplied snapshots are never trusted.
   - `set_vle_grade_snapshot` copies the assessment's immutable snapshot; it never falls back to current child profile.
   - Database constraint enforces: `grade_level_snapshot IS NULL OR grade_level_snapshot BETWEEN 1 AND 12`.
   - Fail-closed unknown grade policy: if grade snapshot is NULL, no grade is inferred, unknown history is never longitudinally comparable, baseline remains unavailable, and longitudinal bonuses (Growth, High Performer, Personal Best) are strictly withheld ($0$). Base score RP and difficulty bonus operate independently.
   - Legacy Phase 2 rows without trustworthy grade provenance remain `NULL` (no fabricated backfill).
3. **Topic Behavior in Growth v0.1:** `docs/03-growth-engine-v0.1.md` notes that topic-specific comparison requires reliable, standardized topic taxonomy. Because Phase 2 captures assessments with unstructured titles without formal taxonomy tags, Growth v0.1 deterministically applies the documented subject-level fallback rather than fabricating an ad-hoc topic taxonomy.
4. **Strict Chronological Precedence:** Only results occurring strictly before the current event are eligible: `occurred_at < current_event.occurred_at` OR (`occurred_at == current_event.occurred_at` AND `verified_at < current_event.verified_at`).
5. **Self-Exclusion:** The current event ID is strictly excluded from its own baseline calculation.
6. **Rolling Window Size:** The baseline is the unweighted arithmetic mean of the last 3 prior comparable results (rounded to 2 decimal places: `round(mean * 100) / 100`).
7. **Cold-Start Handling:** If fewer than 3 prior comparable results exist, the baseline score is `null`, and no growth or high-performer maintenance bonus is awarded (`baseline_sample_count` is recorded for progress transparency).
8. **Baseline Integrity & Auditability:** The calculation snapshot in `inputs_snapshot` records the current grade level, assessment type, and difficulty band, as well as the exact comparators used (including their `id`, `normalized_score`, `grade_level`, `occurred_at`, `assessment_type`, and `difficulty`).

---

## Decision 3 — Integer minor-unit convention for Reward Points (`rp_minor`)

To completely eliminate floating-point representation drift and rounding discrepancies:
- All database columns, ledger entries, and balance projections store RP as non-negative integer minor units:
  $$1.00\text{ RP} = 100\text{ rp\_minor}$$
- Value object `RpMinor` wraps the integer in the domain layer and provides formatted display (`formatRp()`).
- Conversions between normalized score ($0.00$ to $10.00$) and base RP scale:
  $$\text{score\_rp\_minor} = \text{round}(\text{normalized\_score} \times 100)$$
- Integer math is used across all additive components.

---

## Decision 4 — Deterministic RP and Study XP formula (`growth-v0.1`)

$$\text{RP} = \text{Score} + \text{Growth} + \text{High Performer} + \text{Goal} + \text{Personal Best} + \text{Difficulty} + \text{Recovery}$$

1. **Score RP:** Direct reward proportional to normalized score:
   - Standard assessment: `round(normalized_score * 100)` minor units ($10.00 \rightarrow 1000\text{ minor} = 10.00\text{ RP}$).
   - Below-level activity: $25\%$ of standard base RP (`round(normalized_score * 25)` minor units).
2. **Growth Bonus (Standard only):** Awarded if $\text{growth\_delta} = \text{normalized\_score} - \text{baseline\_score} \ge 0.50$:
   - $+0.50 \le \Delta < +1.00 \implies +1.00\text{ RP}$ ($100\text{ minor}$)
   - $+1.00 \le \Delta < +1.50 \implies +2.00\text{ RP}$ ($200\text{ minor}$)
   - $+1.50 \le \Delta < +2.00 \implies +3.00\text{ RP}$ ($300\text{ minor}$)
   - $\Delta \ge +2.00 \implies +4.00\text{ RP}$ ($400\text{ minor}$)
3. **High-Performer Maintenance (Mastery):** If $\text{baseline\_score} \ge 8.50$ AND $\text{normalized\_score} \ge 8.50$, award $+1.00\text{ RP}$ ($100\text{ minor}$).
4. **Personal Best:** Awarded if $\text{normalized\_score} \ge \text{historical\_best} + 0.25$: $+1.00\text{ RP}$ ($100\text{ minor}$).
5. **Difficulty / Challenge Bonus:**
   - `difficulty == 'hard'`: $+1.00\text{ RP}$ ($100\text{ minor}$).
   - `difficulty == 'challenge'` AND $\text{normalized\_score} \ge 5.00$: $+2.00\text{ RP}$ ($200\text{ minor}$). No bonus if score $< 5.00$ to avoid low-effort farming.
6. **Study XP:** Permanent effort points calculated as:
   $$\text{XP} = 10 + \text{round}(2.0 \times \frac{\text{total\_rp\_minor}}{100})$$
   Study XP is cumulative and never deducted or spent.

---

## Decision 5 — Below-level anti-farming safeguards

When an assessment is flagged with `difficulty == 'below_level'`:
- Base RP is curtailed to $25\%$ ($10.00/10$ yields $2.50\text{ RP}$ instead of $10.00\text{ RP}$).
- Growth, Mastery Maintenance, Personal Best, and Challenge bonuses are strictly zeroed out ($0\text{ RP}$).
- Legitimate Study XP is preserved ($10 + \text{round}(2.0 \times 2.50) = 15\text{ XP}$) to acknowledge effort without distorting the incentive economy.
- UI explicitly explains this adjustment to prevent child confusion.

---

## Decision 6 — Server state transitions, concurrency serialization, and idempotency

Direct client `INSERT`, `UPDATE`, and `DELETE` on `growth_events`, `xp_ledger`, `rp_ledger`, and `child_balances` are strictly revoked from `authenticated` and `anon`.
All economic mutations must execute through the trusted `SECURITY DEFINER` function:
`public.process_verified_learning_event(p_verified_event_id, p_command_id)`

1. **Row-level Serialization:** The RPC locks the target `verified_learning_events` record using `SELECT ... FOR UPDATE`. Concurrent calls on the same verified event queue up sequentially.
2. **Exactly-Once Processing:** Once the first transaction inserts into `growth_events`, any subsequent concurrent transaction unblocks, detects the existing `growth_events` record, and returns it immediately without re-appending to ledgers.
3. **Idempotency Keys:** Ledger rows use natural unique idempotency keys (`xp:growth_event:<id>` and `rp:growth_event:<id>`) enforced by unique constraints.
4. **Command Receipts:** The operation is recorded in `public.command_receipts` with `operation = 'process_growth'`.

---

## Decision 7 — Append-only ledgers, `child_balances` projection, and reconciliation authorization

1. **Immutable Ledgers:** `xp_ledger` and `rp_ledger` are strictly append-only. A PostgreSQL trigger `prevent_ledger_mutation` blocks any `UPDATE` or `DELETE` attempt (`LW102`).
2. **Projection Table:** `public.child_balances` caches current balances (`xp_total`, `rp_balance_minor`) for fast mobile queries.
3. **Ledger is Source of Truth:** `child_balances` is purely a derived projection.
4. **Read-Only Reconciliation Integrity Check:** The function `public.reconcile_child_balance(p_child_id)`:
   - Acts strictly as a **read-only audit / integrity verification check** rather than a mutative repair function; it returns verification status (`is_in_sync`, projected vs ledger sums) without modifying rows or acquiring exclusive table-level locks.
   - Enforces authentication (`auth.uid() is not null`, error `42501`).
   - Resolves the target child's family from `child_profiles` (`LW105`).
   - Strictly authorizes the caller: requires active adult membership in the child's family or the exact paired child device identity (`42501`).
   - Cross-family calls, sibling child devices, and anonymous callers are rejected.
   - Evaluates the projected `child_balances` values and the exact `SUM(xp_ledger.amount)` and `SUM(rp_ledger.amount_minor)` within a **single SQL statement / single MVCC snapshot**. This guarantees point-in-time consistency and prevents transient false drift detections during concurrent Growth event commits.

---

## Decision 8 — Verify → Growth Delivery Reliability and Catch-Up

1. **Separation of Concerns:** `verify_assessment` finalizes the immutable verification of academic work independently from Growth Engine calculation.
2. **Resilience to Interruption:** If network or client failures occur after `verify_assessment` but before `process_verified_learning_event`, the verification is not rolled back. The mobile UI catches the error and surfaces that calculation is queued.
3. **Discoverability and Self-Healing:** The function `public.get_unprocessed_verified_learning_events(p_family_id)` identifies all verified events lacking corresponding `growth_events`.
4. **Batch Catch-Up:** `public.catch_up_unprocessed_growth(p_family_id)` processes any unprocessed verified learning events sequentially. This runs automatically on parent family dashboard load.

---

## Decision 9 — Explicit deferrals

To maintain strict Phase 3 scope boundaries:
1. **Goal and Recovery Bonuses:** Goal commitment and Recovery Quest engines are not yet implemented. In `growth-v0.1`, their bonuses are evaluated to `0 minor` and documented as not applicable in calculation breakdowns.
2. **Reward Economy & Wheel:** The Reward Store, reward redemption, prize fulfillment, and spinning wheels are explicitly deferred to Phase 4.
3. **Mastery Graph:** The dynamic skill graph and fine-grained prerequisite mastery tracking are deferred to Phase 5.
