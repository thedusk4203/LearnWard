# ADR 0005 — Phase 4 Reward Economy and Wheel Experience Architectural Decisions

- **Status:** PROPOSED  
- **Date:** 2026-11-01  
- **Context:** Phase 3 established immutable verified learning events, deterministic RP/XP generation via the Growth Engine (`growth-v0.1`), dual append-only authoritative ledgers (`xp_ledger` and `rp_ledger`), and cached balance projections (`child_balances`). Phase 4 provides the consumption half of the economy: empowering children to spend earned RP on parent-defined family rewards through either the **Reward Store** (certainty, delayed gratification) or the **Celebration Wheel** (surprise, celebration), while strictly preventing gambling mechanics, balance corruption, or child exploitation.

---

## Decision 1 — Unified Spendable RP Currency (Model C)

The reward economy maintains **exactly one spendable reward currency**: **Reward Points (RP)**, represented as integer minor units (`amount_minor`, where $100\text{ minor units} = 1.00\text{ RP}$).
- Study XP remains permanent and strictly non-spendable.
- We reject Model B (separate spin ticket currency), which would violate our dual-currency product constitution and add unnecessary cognitive overhead for children and parents.
- Children choose how to allocate their single RP balance between Store items (fixed cost, guaranteed outcome) and the Wheel (fixed low spin cost, guaranteed positive surprise outcome).

**Consequences:** Simplifies state management, eliminates multi-currency exchange friction, and forces a direct, developmentally healthy self-regulation choice between saving for a specific goal or celebrating with immediate variety.

---

## Decision 2 — Server-Authoritative Random Selection with Decoupled Presentation

The mobile client is treated as an untrusted presentation layer:
1. The client issues an RPC request (`spin_reward_wheel`) containing a client-generated UUID command ID.
2. The server acquires a row-level lock on `child_balances`, validates balance $\ge \text{spin\_cost}$, checks the daily spin cap, snapshots the active reward pool, evaluates selection weights, generates secure server-side randomness, selects the winner, writes the debit and redemption records, and commits atomically.
3. The server returns the already-decided winning reward to the client.
4. The client's sole role is animating the physical wheel to land on the pre-determined wedge.

**Consequences:** Client modification, reverse-engineering, or packet manipulation cannot influence prize outcomes. If the app crashes or disconnects during the spin animation, the winning reward is already immutably stored in the child's redemption history.

---

## Decision 3 — Tier-Based Relative Weighting for Wheel Odds

Rather than forcing parents to calculate percentages that must sum to 100%, parents assign each Wheel-eligible reward a categorical tier:
- **Common:** Base weight = 60 (~60% of pool)
- **Special:** Base weight = 30 (~30% of pool)
- **Rare:** Base weight = 10 (~10% of pool)

The server calculates probability dynamically as:
$$P(\text{reward}_i) = \frac{w_i}{\sum_{j=1}^{N} w_j}$$
The mobile UI maps these weights directly to visual wedge widths on the wheel and displays transparent odds ("Likely", "Occasional", "Rare") to parents.

**Consequences:** Parents can add or remove rewards without broken percentage mathematics. Children see honest visual wedges that accurately reflect underlying mathematical odds without deception.

---

## Decision 4 — Append-Only Ledger Spending and Compensating Refunds

In accordance with Phase 3 immutability invariant `LW102`:
1. **Spending:** Store redemptions and Wheel spins insert a negative `amount_minor` row into `public.rp_ledger` with reason codes `'store_redemption'` and `'wheel_spin'`.
2. **Immutability:** Existing ledger rows are never edited or deleted.
3. **Refunds:** If a parent cancels an unfulfilled redemption, the original debit row remains intact. A new compensating positive row (`amount_minor = +cost`) is appended to `public.rp_ledger` with `reason_code = 'redemption_refund'`.
4. **Reconciliation Invariant:** The invariant $\text{rp\_balance\_minor} = \sum \text{rp\_ledger.amount\_minor}$ continues to hold across all spending and refund operations.

**Consequences:** Provides a permanent, tamper-proof financial audit trail for all reward spending. Reversals are fully transparent and auditable.

---

## Decision 5 — Row-Locked Concurrency & Strict Non-Negative Balance Enforcement

To eliminate race conditions and negative balances under rapid user taps or multi-device concurrency:
1. All spending mutations execute through trusted `SECURITY DEFINER` RPCs (`redeem_store_reward`, `spin_reward_wheel`).
2. The RPC locks the child's balance record via `SELECT rp_balance_minor FROM public.child_balances WHERE child_id = p_child_id FOR UPDATE`.
3. If `rp_balance_minor < cost_minor`, the transaction aborts with error code `LW201` (`Insufficient RP balance`).
4. Balance deduction and ledger append commit atomically in the same transaction.

**Consequences:** Guarantees that children cannot overdraw their balance or duplicate a spin, even under high concurrency or simulated latency.

---

## Decision 6 — Anti-Compulsion Safeguards: Daily Spin Cap & Guaranteed Positive Outcomes

To prevent celebratory gamification from drifting into compulsive slot-machine behavior:
1. **Guaranteed Positive Value:** Every wheel spin must award a positive, parent-approved treat or privilege. Zero-reward outcomes, "try again" slots, and near-miss animations are strictly prohibited.
2. **Minimum Pool Size:** A spin is rejected before debits if fewer than 2 active Wheel rewards exist (`LW203`).
3. **Daily Spin Cap:** Each family can configure a daily spin cap per child (default: 3 spins/day, range: 1–10). Attempts to exceed the cap fail closed with `LW202`.

**Consequences:** Reinforces the celebration ritual after real study without enabling repetitive dopamine-chasing sessions.

---

## Decision 7 — Phased Implementation Sequencing

Phase 4 implementation is decoupled into three vertical slices:
- **Slice 4.1 (Foundation):** Catalog management, Store redemptions, ledger spending, fulfillment lifecycle, and parent cancellation/refunds.
- **Slice 4.2 (Celebration):** Wheel settings, server random selection, daily caps, and celebratory wheel UI.
- **Slice 4.3 (Hardening):** Multi-session concurrency test scripts, pgTAP test suites, and cross-platform verification.

**Consequences:** Delivers a functional reward loop early, isolating economic and ledger correctness before introducing animation and randomness layers.
