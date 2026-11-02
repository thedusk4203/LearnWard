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
   - Authorize caller (active family adult or paired child device) before inspecting family configuration or command-receipt replay data
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

**Threat Model & Randomness Clarification:** Selection uses server-authoritative pseudorandom selection (`random()`). It is not claimed to be a cryptographically secure RNG and does not claim cryptographic unpredictability. The security property frozen here is that the client cannot supply or choose the committed winner. The mechanism is not intended for real-money gambling or regulated gaming.

**Consequences:** Client modification cannot directly select prize outcomes. If the app crashes or disconnects during the spin animation, the winning reward is already immutably stored in the child's redemption history. Historical spins can be mathematically verified at any time without reading mutable catalog state.

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

**Consequences:** Provides a permanent, tamper-resistant audit trail for all reward spending. Prevents gaming where families cancel "disappointing" prizes to fish for rarer ones.

---

## Decision 5 — Row-Locked Concurrency & Terminal Fulfillment States

To eliminate race conditions and double-spending:
1. All spending mutations execute through trusted `SECURITY DEFINER` RPCs (`redeem_store_reward`, `spin_reward_wheel`).
2. Each spending path locks the child's balance row with `FOR UPDATE` before applying the debit.
3. If `rp_balance_minor < cost_minor`, the transaction aborts with error code `LW201` (`Insufficient RP balance`).
4. Both `fulfill_reward_redemption` and `cancel_reward_redemption` acquire a row lock on `reward_redemptions` before authorization/replay/state-transition handling.
5. Lifecycle states: `pending_fulfillment` $\rightarrow$ `fulfilled` or `cancelled`. States `fulfilled` and `cancelled` are strictly **terminal**. Concurrent fulfill/cancel attempts race for the row lock, resulting in exactly one terminal transition.
6. Core redemption fields are immutable after creation.
7. Retries using the same `p_command_id` return the existing logical outcome without re-executing debits or refunds after replay validation succeeds.

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
- `wheel_spins`: constrained via composite foreign key `fk_wheel_spins_redemption_composite` on `(redemption_id, family_id, child_id, reward_id, origin, spin_cost_minor)` referencing `reward_redemptions(id, family_id, child_id, reward_id, origin, rp_cost_minor)`.

**Consequences:**
1. Impossible for a Wheel spin to reference a Store redemption (`origin = 'wheel'` enforced and included in the composite link).
2. Impossible for a Wheel spin to claim one reward while its redemption claims another (`reward_id` matches).
3. Impossible for a Wheel spin to charge a different RP amount than its redemption (`spin_cost_minor == rp_cost_minor` enforced).
4. Impossible for the linked Wheel spin/redemption tuple to cross family or child boundaries.

---

## Decision 8 — Family Timezone-Aware Daily Spin Cap Across DST

1. **Daily Cap:** Evaluated against the family's registered `timezone` from `public.families.timezone`:
   ```sql
   v_local_date := (now() at time zone v_family_tz)::date;
   v_today_start := (v_local_date::timestamp at time zone v_family_tz);
   v_today_end := ((v_local_date + 1)::timestamp at time zone v_family_tz);
   ```
2. **DST Invariant:** Both boundaries are derived directly from local calendar dates. The daily cap window is strictly `[local midnight today, local midnight tomorrow)`, correctly accommodating 23-hour spring-forward and 25-hour fall-back days without boundary drift. If timezone is missing or unrecognized, a new Wheel command fails closed (`LW004: Invalid family timezone`) before any debit.
3. **Aligned Configuration Ranges & Canonical Error Codes:**
   - Wheel spin cost: Default = 10 RP (1,000 minor units). Parent range = 5–50 RP (500–5,000 minor units).
   - Daily spin cap: Default = 3 spins/day. Parent range = 1–5 spins/day.
   - Minimum active eligible Wheel pool: At least 3 distinct items required before spinning is allowed (`LW203`).
   - Canonical Error Code Mapping:
     - `LW004`: Missing or invalid family timezone
     - `LW201`: Insufficient spendable RP balance
     - `LW202`: Daily spin cap reached for child's local calendar day
     - `LW203`: Active eligible Wheel pool has fewer than 3 items
     - `LW204`: Invalid redemption state transition (already terminal)
     - `LW205`: Reward unavailable for Store redemption
     - `LW206`: Celebration Wheel is disabled for family

---

## Decision 9 — Strict SECURITY DEFINER Execution, Authorization, and Replay Contracts

All public Phase 4 functions are `SECURITY DEFINER` with `SET search_path = ''`. Execution is revoked from `PUBLIC`/`anon` and granted to `authenticated` using the function's exact signature.

Phase 4 has two execution models: **command-based trusted economic mutations** and the **read-only Wheel status query**.

### A. Common Security and Idempotency Invariants for Trusted Economic Mutations

The command-based mutation functions are:
- `redeem_store_reward`
- `fulfill_reward_redemption`
- `cancel_reward_redemption`
- `spin_reward_wheel`

They do **not** share one identical statement ordering. Their frozen common guarantees are:
1. An authenticated caller is required.
2. Target resources and authoritative `family_id` values are derived from database state rather than caller-supplied family identity.
3. Caller authorization occurs before any `command_receipts` replay data is returned and, for Wheel, before target-family timezone/settings are inspected.
4. Existing command receipts are validated against the operation, `actor_user_id`, `family_id`, and the operation-specific `resource_id`/resource binding before replay returns a result.
5. A valid replay returns the already-committed logical outcome without repeating economic effects.
6. New commands acquire operation-specific locks and validate operation-specific preconditions.
7. State mutation and command-receipt insertion occur in the same database transaction.
8. `public.command_receipts` stores exactly: `command_id`, `operation`, `actor_user_id`, `resource_id`, `family_id`, and `created_at`. It does not store a generic payload column.

These guarantees do **not** claim that target-resource existence is hidden. Current RPCs may load a target resource before authorization, so an authenticated caller can receive `P0002` for a missing resource and `42501` for an existing but unauthorized resource. Hiding resource existence is a separate future hardening concern, not a frozen Phase 4 property.

### B. Exact Operation-Specific Ordering

#### Store Redemption — `redeem_store_reward`

```text
authenticate
→ validate command_id / child_id / reward_id
→ load child and derive child family
→ load reward
→ reject cross-family child/reward mismatch
→ authorize active family adult OR exact paired child device
→ inspect and validate command receipt replay
→ lock target reward row FOR UPDATE
→ validate active/store-enabled/child eligibility/cost
→ lock child_balances FOR UPDATE
→ validate sufficient RP (LW201)
→ create store redemption + append negative RP ledger debit + decrement balance
→ insert command_receipt
→ return redemption
```

#### Fulfillment — `fulfill_reward_redemption`

```text
authenticate
→ validate command_id / redemption_id
→ lock reward_redemptions row FOR UPDATE
→ derive family from locked redemption
→ authorize active family adult
→ inspect and validate command receipt replay
→ validate pending_fulfillment (LW204 if terminal)
→ transition to fulfilled
→ insert command_receipt
→ return redemption
```

#### Cancellation — `cancel_reward_redemption`

```text
authenticate
→ validate command_id / redemption_id / cancellation_reason
→ lock reward_redemptions row FOR UPDATE
→ derive family from locked redemption
→ authorize active family adult
→ inspect and validate command receipt replay
→ validate pending_fulfillment (LW204 if terminal)
→ lock child_balances FOR UPDATE
→ transition to cancelled
→ append positive redemption_refund ledger row
→ restore child balance projection
→ insert command_receipt
→ return redemption
```

#### Celebration Wheel Spin — `spin_reward_wheel`

```text
validate command_id / child_id
→ authenticate
→ load child and derive family
→ authorize active family adult OR exact paired child device
→ inspect and validate command receipt replay
→ NEW command only: validate family timezone (LW004)
→ lock family_wheel_settings FOR SHARE (LW206 if disabled)
→ LOCK TABLE public.rewards IN SHARE MODE
→ materialize one child-eligible pool (LW203 if < 3)
→ lock child_balances FOR UPDATE
→ validate sufficient RP (LW201)
→ enforce family-local daily cap using wheel_spins (LW202)
→ server-authoritative pseudorandom selection from stabilized pool
→ create reward_redemption + wheel_spin + negative RP ledger debit + decrement balance
→ insert command_receipt
→ return committed spin result
```

### C. Read-Only Status Contract — `get_wheel_status`

`get_wheel_status` does **not** consume a command ID, create a command receipt, acquire the Wheel catalog table lock, debit RP, create `wheel_spins`, or mutate economy state.

Its frozen implementation sequence is:
```text
validate child_id
→ authenticate
→ load active child and derive family
→ authorize active family adult OR exact paired child device
→ validate families.timezone (LW004)
→ read family_wheel_settings, or use the function's defaults if no row exists
→ calculate family-local [midnight, next midnight) bounds
→ count wheel_spins for the child inside that local-day window
→ count active child-eligible wheel rewards
→ return status
```

The returned status includes `spins_today`, `spins_remaining`, `spin_cost_minor`, `daily_spin_cap`, `is_enabled`, `local_day_start`, `local_day_end`, and `eligible_reward_count`.

**Consequences:** Command replay data and Wheel family configuration are protected by authorization before return/inspection as described above. The read-only status function is explicitly separate from command-receipt mutation semantics.

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
- **Outcome:** Both PRs successfully implemented and verified their respective scopes against all database, concurrency, and client integration gates. Phase 4 is FROZEN.
