# ADR 0005 — Phase 4 Reward Economy and Wheel Experience Architectural Decisions

- **Status:** ACCEPTED  
- **Date:** 2026-11-01 (Accepted: 2026-11-02)  
- **Context:** Phase 3 established immutable verified learning events, deterministic RP/XP generation via the Growth Engine (`growth-v0.1`), dual append-only authoritative ledgers (`xp_ledger` and `rp_ledger`), and cached balance projections (`child_balances`). Phase 4 provides the consumption half of the economy: empowering children to spend earned RP on parent-defined family rewards through either the **Reward Store** (certainty, delayed gratification) or the **Celebration Wheel** (surprise, celebration), while strictly preventing gambling mechanics, balance corruption, or child exploitation. This ADR was accepted following the successful implementation, independent review approval, and green post-merge CI verification of Phase 4.1 (merge SHA `8ca9bbc47aa45b96e8ae441671ec57d57ce95dea`) and Phase 4.2 (merge SHA `6f1057409942a564691fac41509c17d6b602a3af`, post-merge CI `41380026423`).

---

## Decision 1 — Unified Spendable RP Currency (Model C)

The reward economy maintains **exactly one spendable reward currency**: **Reward Points (RP)**, represented as integer minor units (`amount_minor`, where $100\text{ minor units} = 1.00\text{ RP}$).
- Study XP remains permanent and strictly non-spendable.
- We reject Model B (separate spin ticket currency), which would violate our dual-currency product constitution and add unnecessary cognitive overhead for children and parents.
- Children choose how to allocate their single RP balance between Store items (fixed cost, guaranteed outcome) and the Wheel (fixed low spin cost, guaranteed positive surprise outcome).

**Consequences:** Simplifies state management, eliminates multi-currency exchange friction, and forces a direct, developmentally healthy self-regulation choice between saving for a specific goal or celebrating with immediate variety.

---

## Decision 2 — Server-Authoritative Pseudorandom Selection with Auditable Selection Snapshot

The mobile client is treated as an untrusted presentation layer:
1. The client issues an RPC request (`spin_reward_wheel`) containing a client-generated UUID command ID.
2. The server executes a strict, fail-closed ordering:
   - Input validation (`p_command_id`, `p_child_id` non-null)
   - Authenticate (`auth.uid() is not null`)
   - Child lookup & authoritative family derivation
   - Authorize caller (active family adult or paired child device) evaluated strictly before inspecting configuration or timezone to prevent oracle side channels
   - Inspect `command_receipts`: if valid replay, return committed historical outcome immediately (survives subsequent timezone corruption)
   - NEW command only: validate family timezone fail-closed (`LW004`)
   - Lock `family_wheel_settings FOR SHARE` (fails with `LW206` if disabled)
   - Acquire `LOCK TABLE public.rewards IN SHARE MODE` to stabilize catalog mutations and prevent statement-snapshot skew
   - Materialize one authoritative child-eligible pool; validate pool count $\ge 3$ (`LW203` if fewer)
   - Lock `child_balances FOR UPDATE`; validate sufficient balance $\ge \text{spin\_cost\_minor}$ (`LW201` if insufficient)
   - Evaluate family-local calendar day spin cap (`LW202` if reached)
   - Server-authoritative pseudorandom draw (PostgreSQL `random()`)
   - Atomic writes (`reward_redemptions`, `wheel_spins`, `rp_ledger` debit, `child_balances` decrement, `command_receipts`)
   - Return committed result
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

**Threat Model & Randomness Clarification:** Selection uses server pseudorandom selection (`random()`). It is not claimed to be a cryptographically secure RNG. It prevents client manipulation or outcome prediction while remaining sufficiently unbiased for family reward celebration. It is not intended for real-money gambling or regulated gaming.

**Consequences:** Client modification cannot influence prize outcomes. If the app crashes or disconnects during the spin animation, the winning reward is already immutably stored in the child's redemption history. Historical spins can be mathematically verified at any time without reading mutable catalog state.

---

## Decision 3 — Tier-Based Relative Weights (Not Fixed Percentages)

Rather than forcing parents to calculate percentages that must sum to 100%, parents assign each Wheel-eligible reward a categorical tier:
- **Common:** Base relative weight = 60
- **Special:** Base relative weight = 30
- **Rare:** Base relative weight = 10

The server calculates probability dynamically as:
$$P(\text{reward}_i) = \frac{w_i}{\sum_{j=1}^{N} w_j}$$
- **Parent Wheel Settings:** The family-level screen displays configured rewards and relative tier weights:
  ```text
  Configured Wheel Rewards
  N active Wheel rewards configured

  Common — weight 60 — N configured items
  Special — weight 30 — N configured items
  Rare — weight 10 — N configured items
  ```
  It explains: *"Actual probability depends on which rewards are eligible for each child."* and adds: *"Each child needs at least 3 active rewards that are eligible for them before they can spin. Child-targeted rewards count only for that child."* It does **not** display one family-wide computed percentage because `target_child_id` makes eligible pools child-specific.
- **Child Wheel Presentation:** The child's actual Wheel wedges and probabilities are derived from that child's current eligible pool / server-committed `selection_snapshot`. The mobile UI maps these weights directly to visual wedge widths on the wheel without deceptive visuals.

**Consequences:** Parents can add or remove rewards without broken percentage mathematics. Children see honest visual wedges that accurately reflect underlying mathematical odds without deception.

---

## Decision 4 — Append-Only Ledger Spending, Compensating Refunds, and No Rerolls

In accordance with Phase 3 immutability invariant `LW102`:
1. **Spending:** Store redemptions and Wheel spins insert a negative `amount_minor` row into `public.rp_ledger` with reason codes `'store_redemption'` and `'wheel_spin'`. For both Store and Wheel operations, `source_type` is `'reward_redemption'` and `source_id` is the `redemption_id`, with `metadata` capturing `spin_id` for Wheel spins.
   - *Rationale:* The RP economic transaction is anchored to the immutable `reward_redemption`, while `wheel_spins` remains the selection/audit object linked through metadata and composite foreign key (`fk_wheel_spins_redemption_composite`). This ensures all reward debits and their corresponding cancellation refunds share the exact same source entity identity (`reward_redemption`).
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

1. **Shared Child Mode:** In Phase 1 architecture, shared device mode operates under the parent's Supabase Auth session (`auth.uid() = parent_uid`). The database enforces family boundaries (`private.is_active_family_adult(family_id)`). The server **cannot** distinguish between siblings holding the shared phone. An adult session has server authority to act for any child profile in the family. Local Child Mode and PIN protection provide **UX containment, not a cryptographic server authorization boundary**.
2. **Paired Child Devices (Future):** When dedicated child devices are authenticated via `child_device_grants`, the server restricts `auth.uid()` to exactly its linked `child_id`.

**Consequences:** Clarifies the exact security boundary. The system never relies on client-reported active child state or Riverpod state for backend authorization.

---

## Decision 7 — Database-Level Composite Tenant Integrity & Relational Wheel-Redemption Consistency

To defend against cross-family foreign key contamination and data mismatch:
- `rewards(id, family_id)`: `target_child_id` is constrained via `FOREIGN KEY (target_child_id, family_id) REFERENCES child_profiles(id, family_id) ON DELETE RESTRICT`.
- `reward_redemptions`: has composite unique constraint `uq_reward_redemptions_wheel_link (id, family_id, child_id, reward_id, origin, rp_cost_minor)`.
- `wheel_spins`: constrained via composite foreign key `fk_wheel_spins_redemption_composite` referencing `reward_redemptions(id, family_id, child_id, reward_id, origin, spin_cost_minor)`.

**Consequences:**
1. Impossible for a Wheel spin to reference a Store redemption (`origin = 'wheel'` enforced).
2. Impossible for a Wheel spin to claim one reward while its redemption claims another (`reward_id` matches).
3. Impossible for a Wheel spin to charge a different RP amount than its redemption (`spin_cost_minor == rp_cost_minor` enforced).
4. Impossible for rewards or redemptions to cross family or child boundaries.

---

## Decision 8 — Family Timezone-Aware Daily Spin Cap Across DST

1. **Daily Cap:** Evaluated against the family's registered `timezone` from `public.families.timezone`:
   ```sql
   v_local_date := (now() at time zone v_family_tz)::date;
   v_today_start := (v_local_date::timestamp at time zone v_family_tz);
   v_today_end := ((v_local_date + 1)::timestamp at time zone v_family_tz);
   ```
2. **DST Invariant:** Both boundaries are derived directly from local calendar dates. The daily cap window is strictly `[local midnight today, local midnight tomorrow)`, correctly accommodating 23-hour spring-forward and 25-hour fall-back days without boundary drift. If timezone is missing or unrecognized, the RPC fails closed (`LW004: Invalid family timezone`) before any debit.
3. **Aligned Configuration Ranges & Canonical Error Codes:**
   - Wheel spin cost: Default = 10 RP (1,000 minor units). Parent range = 5–50 RP ($500 \le \text{cost} \le 5000$).
   - Daily spin cap: Default = 3 spins/day. Parent range = 1–5 spins/day.
   - Minimum active eligible Wheel pool: Exactly 3 distinct items required before spinning is allowed (`LW203`).
   - Canonical Error Code Mapping:
     - `LW004`: Missing or invalid family timezone
     - `LW201`: Insufficient spendable RP balance
     - `LW202`: Daily spin cap reached for child's local calendar day
     - `LW203`: Active eligible Wheel pool has fewer than 3 items
     - `LW204`: Invalid redemption state transition (already terminal)
     - `LW206`: Celebration Wheel is disabled for family

---

## Decision 9 — Strict SECURITY DEFINER Execution, Authorization, and Replay Order

Every public Phase 4 RPC enforces:
```sql
SECURITY DEFINER
SET search_path = ''
```
With permissions:
```text
REVOKE ALL FROM PUBLIC, anon;
GRANT EXECUTE TO authenticated;
```
And an immutable fail-closed execution order:
1. Input validation (`p_command_id`, `p_child_id` non-null -> `22000`).
2. Authentication check: `auth.uid() is not null` (fail closed `42501` if unauthenticated).
3. Authoritative child lookup and family derivation from database state (`P0002`).
4. Authorize caller against resolved family (adult or paired child device -> `42501`) strictly BEFORE any timezone or configuration inspection to prevent oracle side channels.
5. ONLY AFTER authorization succeeds: inspect `command_receipts` for replay. Valid replays return committed historical results immediately (surviving subsequent timezone corruption).
6. NEW commands only: validate family timezone fail-closed (`LW004`).
7. Lock settings (`family_wheel_settings FOR SHARE` -> `LW206` if disabled) and stabilize catalog (`LOCK TABLE public.rewards IN SHARE MODE`).
8. Materialize authoritative child-eligible pool ($\ge 3$ items required -> `LW203`).
9. Precondition verification: lock `child_balances FOR UPDATE` and validate sufficient balance $\ge \text{cost}$ (`LW201`).
10. Check family-local calendar day cap (`LW202`).
11. State mutation: pseudorandom selection, write redemption, spin snapshot, negative ledger debit, balance decrement, and command receipt.
12. Commit and return.

**Consequences:** Callers from Family B can never probe receipts or view another family's replay data. Replays are authorized prior to data return.

---

## Decision 10 — Phased Migration & Implementation Sequencing: Store Foundation (4.1) then Wheel (4.2)

Phase 4 implementation was split into two sequential PR gates:
- **PR 4.1 (Store Foundation) — COMPLETE:**
  - Merge SHA: `8ca9bbc47aa45b96e8ae441671ec57d57ce95dea` (Post-merge CI: `41332029263`)
  - Migration: `rewards`, `reward_redemptions`, composite FKs, RLS policies.
  - Operation CHECK Migration: Extended `command_receipts_operation_check` to include: `'redeem_reward', 'fulfill_reward', 'cancel_reward'`.
  - RPCs: `redeem_store_reward`, `fulfill_reward_redemption`, `cancel_reward_redemption`.
- **PR 4.2 (Celebration Wheel) — COMPLETE:**
  - Merge SHA: `6f1057409942a564691fac41509c17d6b602a3af` (Post-merge CI: `41380026423`)
  - Migration: `family_wheel_settings`, `wheel_spins`, composite consistency FK to `reward_redemptions`.
  - Operation CHECK Migration: Extended `command_receipts_operation_check` to add: `'spin_wheel'`.
  - RPCs: `spin_reward_wheel`, `get_wheel_status`.
- **Outcome:** Both PRs successfully implemented and verified their respective scopes against all database, concurrency, and client integration gates. Phase 4 is now FROZEN.
