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
1. **Longitudinal Comparability:** A prior result is comparable if and only if it shares the identical `subject_key` (`math`, `english`, `literature`, `science`, `other`).
2. **Strict Chronological Precedence:** Only results occurring strictly before the current event are eligible: `occurred_at < current_event.occurred_at` OR (`occurred_at == current_event.occurred_at` AND `verified_at < current_event.verified_at`).
3. **Self-Exclusion:** The current event ID is strictly excluded from its own baseline calculation.
4. **Rolling Window Size:** The baseline is the unweighted arithmetic mean of the last 3 prior comparable results (rounded to 2 decimal places: `round(mean * 100) / 100`).
5. **Cold-Start Handling:** If fewer than 3 prior comparable results exist, the baseline score is `null`, and no growth or high-performer maintenance bonus is awarded (`baseline_sample_count` is recorded for progress transparency).
6. **Baseline Integrity:** Activities marked `below_level` are excluded from serving as baseline samples for standard assessments to prevent artificial deflation of the learner's baseline.

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

## Decision 4 — Deterministic RP and Study XP formula

$$\text{RP} = \text{Score} + \text{Growth} + \text{Goal} + \text{Personal Best} + \text{Challenge} + \text{Recovery}$$

1. **Score RP:** Direct reward proportional to normalized score:
   - Standard assessment: `round(normalized_score * 100)` minor units ($10.00 \rightarrow 1000\text{ minor} = 10.00\text{ RP}$).
   - Below-level activity: $25\%$ of standard base RP (`round(normalized_score * 25)` minor units).
2. **Growth Bonus (Standard only):** Awarded if $\text{growth\_delta} = \text{normalized\_score} - \text{baseline\_score} \ge 0.50$:
   - $+0.50 \le \Delta < +1.00 \implies +1.00\text{ RP}$ ($100\text{ minor}$)
   - $+1.00 \le \Delta < +1.50 \implies +2.00\text{ RP}$ ($200\text{ minor}$)
   - $+1.50 \le \Delta < +2.00 \implies +3.00\text{ RP}$ ($300\text{ minor}$)
   - $\Delta \ge +2.00 \implies +4.00\text{ RP}$ ($400\text{ minor}$)
3. **High-Performer Maintenance (Mastery):** If $\text{baseline\_score} \ge 8.50$ AND $\text{normalized\_score} \ge 8.50$, award $+0.50\text{ RP}$ ($50\text{ minor}$).
4. **Personal Best:** Awarded if $\text{normalized\_score} \ge \text{historical\_best} + 0.25$: $+1.00\text{ RP}$ ($100\text{ minor}$).
5. **Difficulty / Challenge Bonus:**
   - `difficulty == 'hard'`: $+1.00\text{ RP}$ ($100\text{ minor}$).
   - `difficulty == 'challenge'` AND $\text{normalized\_score} \ge 5.00$: $+2.00\text{ RP}$ ($200\text{ minor}$). No bonus if score $< 5.00$ to avoid low-effort farming.
6. **Study XP:** Permanent effort points calculated as:
   $$\text{XP} = 10 + \text{round}(2 \times \text{total\_rp})$$
   Study XP is cumulative and never deducted or spent.

---

## Decision 5 — Below-level anti-farming safeguards

When an assessment is flagged with `difficulty == 'below_level'`:
- Base RP is curtailed to $25\%$ ($10.00/10$ yields $2.50\text{ RP}$ instead of $10.00\text{ RP}$).
- Growth, Mastery Maintenance, Personal Best, and Challenge bonuses are strictly zeroed out ($0\text{ RP}$).
- Legitimate Study XP is preserved ($10 + 2 \times 2.50 = 15\text{ XP}$) to acknowledge effort without distorting the incentive economy.
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

## Decision 7 — Append-only ledgers and `child_balances` projection

1. **Immutable Ledgers:** `xp_ledger` and `rp_ledger` are strictly append-only. A PostgreSQL trigger `prevent_ledger_mutation` blocks any `UPDATE` or `DELETE` attempt (`LW102`).
2. **Projection Table:** `public.child_balances` caches current balances (`xp_total`, `rp_balance_minor`) for fast mobile queries.
3. **Ledger is Source of Truth:** `child_balances` is purely a derived projection. The trusted function `public.reconcile_child_balance(p_child_id)` recalculates the projection from `SUM(xp_ledger.amount)` and `SUM(rp_ledger.amount_minor)` under an exclusive advisory lock.

---

## Decision 8 — Explicit deferrals

To maintain strict Phase 3 scope boundaries:
1. **Goal and Recovery Bonuses:** Goal commitment and Recovery Quest engines are not yet implemented. In `growth-v0.1`, their bonuses are evaluated to `0 minor` and documented as not applicable in calculation breakdowns.
2. **Reward Economy & Wheel:** The Reward Store, reward redemption, prize fulfillment, and spinning wheels are explicitly deferred to Phase 4.
3. **Mastery Graph:** The dynamic skill graph and fine-grained prerequisite mastery tracking are deferred to Phase 5.
