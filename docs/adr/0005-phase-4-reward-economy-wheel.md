# ADR 0005 — Phase 4 Reward Economy and Wheel Experience Architectural Decisions

- **Status:** PROPOSED  
- **Date:** 2026-11-01  
- **Context:** Phase 3 established immutable verified learning events, deterministic RP/XP generation via the Growth Engine (`growth-v0.1`), dual append-only authoritative ledgers (`xp_ledger` and `rp_ledger`), and cached balance projections (`child_balances`). Phase 4 provides the consumption half of the economy: empowering children to spend earned RP on parent-defined family rewards through either the **Reward Store** (certainty, delayed gratification) or the **Celebration Wheel** (surprise, celebration), while strictly preventing gambling mechanics, balance corruption, or child exploitation. This ADR reflects resolved product decisions from independent design review `6557968748`.

---

## Decision 1 — Unified Spendable RP Currency (Model C)

The reward economy maintains **exactly one spendable reward currency**: **Reward Points (RP)**, represented as integer minor units (`amount_minor`, where $100\text{ minor units} = 1.00\text{ RP}$).
- Study XP remains permanent and strictly non-spendable.
- We reject Model B (separate spin ticket currency), which would violate our dual-currency product constitution and add unnecessary cognitive overhead for children and parents.
- Children choose how to allocate their single RP balance between Store items (fixed cost, guaranteed outcome) and the Wheel (fixed low spin cost, guaranteed positive surprise outcome).

**Consequences:** Simplifies state management, eliminates multi-currency exchange friction, and forces a direct, developmentally healthy self-regulation choice between saving for a specific goal or celebrating with immediate variety.

---

## Decision 2 — Server-Authoritative Random Selection with Auditable Selection Snapshot

The mobile client is treated as an untrusted presentation layer:
1. The client issues an RPC request (`spin_reward_wheel`) containing a client-generated UUID command ID.
2. The server acquires a row-level lock on `child_balances`, validates balance $\ge \text{spin\_cost}$, checks the daily spin cap (family-local calendar day), snapshots the active reward pool ($\ge 3$ distinct items required), evaluates selection weights, generates secure server-side randomness, selects the winner, writes the debit and redemption records, and commits atomically.
3. The server persists a complete `selection_snapshot` in `wheel_spins`, capturing:
   - Config version (`wheel-v0.1`)
   - Spin cost
   - Ordered eligible rewards with tiers and relative weights
   - Total weight ($W$)
   - Deterministic ordering rule (`reward_id_asc`)
   - Random draw value ($R$)
   - Winning interval and selected reward ID
4. The server returns the already-decided winning reward to the client.
5. The client's sole role is animating the physical wheel to land on the pre-determined wedge.

**Consequences:** Client modification, reverse-engineering, or packet manipulation cannot influence prize outcomes. If the app crashes or disconnects during the spin animation, the winning reward is already immutably stored in the child's redemption history. Historical spins can be mathematically verified at any time without reading mutable catalog state.

---

## Decision 3 — Tier-Based Relative Weights (Not Fixed Percentages)

Rather than forcing parents to calculate percentages that must sum to 100%, parents assign each Wheel-eligible reward a categorical tier:
- **Common:** Base relative weight = 60
- **Special:** Base relative weight = 30
- **Rare:** Base relative weight = 10

The server calculates probability dynamically as:
$$P(\text{reward}_i) = \frac{w_i}{\sum_{j=1}^{N} w_j}$$
- The parent UI displays tier labels and the computed probability for the current active pool. It **does not** display static fake percentages attached to tier definitions.
- The mobile UI maps these weights directly to visual wedge widths on the wheel without deceptive visuals.

**Consequences:** Parents can add or remove rewards without broken percentage mathematics. Children see honest visual wedges that accurately reflect underlying mathematical odds without deception.

---

## Decision 4 — Append-Only Ledger Spending, Compensating Refunds, and No Rerolls

In accordance with Phase 3 immutability invariant `LW102`:
1. **Spending:** Store redemptions and Wheel spins insert a negative `amount_minor` row into `public.rp_ledger` with reason codes `'store_redemption'` and `'wheel_spin'`.
2. **Immutability:** Existing ledger rows are never edited or deleted.
3. **Refunds:** If a parent cancels an unfulfilled redemption, the original debit row remains intact. A new compensating positive row (`amount_minor = +cost`) is appended to `public.rp_ledger` with `reason_code = 'redemption_refund'`.
4. **Reconciliation Invariant:** The invariant $\text{rp\_balance\_minor} = \sum \text{rp\_ledger.amount\_minor}$ continues to hold across all spending and refund operations.
5. **No-Reroll Rule on Wheel Cancellation:** Cancelling a Wheel redemption returns the spent RP, but **does NOT** erase the spin from history, does not grant an automatic redraw, and **does NOT** restore the child's daily spin count.

**Consequences:** Provides a permanent, tamper-proof financial audit trail for all reward spending. Prevents gaming where families cancel "disappointing" prizes to fish for rarer ones.

---

## Decision 5 — Row-Locked Concurrency & Terminal Fulfillment States

To eliminate race conditions and double-spending:
1. All spending mutations execute through trusted `SECURITY DEFINER` RPCs (`redeem_store_reward`, `spin_reward_wheel`).
2. The RPC locks the child's balance record via `SELECT rp_balance_minor FROM public.child_balances WHERE child_id = p_child_id FOR UPDATE`.
3. If `rp_balance_minor < cost_minor`, the transaction aborts with error code `LW201` (`Insufficient RP balance`).
4. Both `fulfill_reward_redemption` and `cancel_reward_redemption` acquire a row lock on `reward_redemptions`.
5. Lifecycle states: `pending_fulfillment` $\rightarrow$ `fulfilled` or `cancelled`. States `fulfilled` and `cancelled` are strictly **terminal**. Concurrent fulfill/cancel attempts race for the row lock, resulting in exactly one terminal transition.
6. Core redemption fields are immutable after creation.
7. Retries using the same `p_command_id` return the existing terminal state without re-executing debits or refunds.

---

## Decision 6 — Shared Child Mode Security Contract vs. Cryptographic Paired Device

1. **Shared Child Mode:** In Phase 1 architecture, shared device mode operates under the parent's Supabase Auth session (`auth.uid() = parent_uid`). The database enforces family boundaries (`private.is_active_family_adult(family_id)`). The server **cannot** distinguish between siblings holding the shared phone. An active adult session has server authority to act for any child profile in the family. Local Child Mode and PIN protection provide **UX containment, not a cryptographic server authorization boundary**.
2. **Paired Child Devices (Future):** When dedicated child devices are authenticated via `child_device_grants`, the server restricts `auth.uid()` to exactly its linked `child_id`.

**Consequences:** Clarifies the exact security boundary. The system never relies on client-reported active child state or Riverpod state for backend authorization.

---

## Decision 7 — Database-Level Composite Tenant Integrity

To defend against cross-family foreign key contamination, all Phase 4 tables use composite unique constraints and composite foreign keys:
- `rewards(id, family_id)`: `target_child_id` is constrained via `FOREIGN KEY (target_child_id, family_id) REFERENCES child_profiles(id, family_id) ON DELETE RESTRICT`.
- `reward_redemptions(id, family_id, child_id)`: constrained via `FOREIGN KEY (child_id, family_id) REFERENCES child_profiles(id, family_id)` and `FOREIGN KEY (reward_id, family_id) REFERENCES rewards(id, family_id)`.
- `wheel_spins`: constrained via `FOREIGN KEY (child_id, family_id) REFERENCES child_profiles(id, family_id)`, `FOREIGN KEY (reward_id, family_id) REFERENCES rewards(id, family_id)`, and `FOREIGN KEY (redemption_id, family_id, child_id) REFERENCES reward_redemptions(id, family_id, child_id)`.

**Consequences:** Impossible for a bug in application code or RPC arguments to cross-link rewards or redemptions across different families or siblings.

---

## Decision 8 — Family Timezone-Aware Daily Spin Cap & Configuration Ranges

1. **Daily Cap:** Evaluated against the family's registered `timezone` from `public.families.timezone`:
   ```sql
   v_today_start := (date_trunc('day', now() at time zone v_family_tz) at time zone v_family_tz);
   v_today_end := v_today_start + interval '1 day';
   ```
2. **Aligned Configuration Ranges:**
   - Wheel spin cost: Default = 10 RP (1,000 minor units). Parent range = 5–50 RP ($500 \le \text{cost} \le 5000$).
   - Daily spin cap: Default = 3 spins/day. Parent range = 1–5 spins/day.
   - Minimum active eligible Wheel pool: Exactly 3 distinct items required before spinning is allowed (`LW203`).

**Consequences:** Fair daily limits that reset at local family midnight rather than UTC, and strictly bounded economy dials.

---

## Decision 9 — Decoupled Phased Implementation: Store Foundation (4.1) then Wheel (4.2)

Phase 4 implementation is split into two sequential PR gates:
- **PR 4.1 (Store Foundation):** Catalog management, Store redemptions, ledger spending, fulfillment lifecycle, and parent cancellation/refunds.
- **PR 4.2 (Celebration Wheel):** Wheel configuration, server-authoritative random selection, selection snapshots, daily cap, and celebratory wheel UI.
- **Gating Rule:** PR 4.2 implementation will not begin until PR 4.1 passes independent review and CI on `main`.

**Consequences:** Delivers a fully verified, non-random economic redemption slice before introducing randomness and visual animation layers.
