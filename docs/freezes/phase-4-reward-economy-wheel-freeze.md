# Phase 4 Freeze Receipt — Reward Economy + Celebration Wheel

**Status:** FROZEN  
**Frozen Code Baseline (Merge SHA):** `6f1057409942a564691fac41509c17d6b602a3af`  
**Phase 4.1 Merge SHA:** `8ca9bbc47aa45b96e8ae441671ec57d57ce95dea`  
**Phase 4.2 Merge SHA:** `6f1057409942a564691fac41509c17d6b602a3af`  
**Approved PR #7 HEAD:** `e7364becdcca6d26414b042c72b027b52933ccaa`  
**Merged PR:** [PR #7 — feat(phase-4.2): implement celebration wheel and parent controls](https://github.com/thedusk4203/LearnWard/pull/7)  
**Independent Review ID:** `6567851782` (APPROVED)  
**Post-merge CI Run ID:** `41380026423` — **SUCCESS**  
**Freeze Date:** 2026-11-02  
**Wheel Config Version:** `wheel-v0.1`  

---

## 1. Scope & Vertical Slices Frozen

Phase 4 establishes the consumption half of LearnWard's reward economy: empowering children to spend earned Reward Points (RP) on parent-defined family rewards through either the **Reward Store** (deterministic delayed gratification) or the **Celebration Wheel** (positive celebration and surprise), while strictly preventing gambling mechanics, balance corruption, or child exploitation.

### Implemented Vertical Slices

1. **Phase 4.1 — Reward Store Vertical Slice:**
   ```text
   Parent configures reward
   → child views Store
   → explicit confirmation dialog (pure RP, zero dollar symbols)
   → durable client command journal (SQLite file)
   → atomic server RPC (public.redeem_store_reward)
   → atomic RP ledger debit (-cost_minor)
   → child_balances row decrement
   → reward_redemptions created (status = 'pending_fulfillment')
   → parent fulfills (public.fulfill_reward_redemption -> status = 'fulfilled')
   OR
   → parent cancels (public.cancel_reward_redemption -> status = 'cancelled')
   → compensating positive RP ledger refund (+cost_minor)
   → child balance restored, fully reconciled
   ```

2. **Phase 4.2 — Celebration Wheel Vertical Slice:**
   ```text
   Parent configures Wheel parameters (enable toggle, spin cost 5–50 RP, daily cap 1–5 spins, catalog items with tiers)
   → child views eligible pool with truthful probability breakdown
   → explicit RP confirmation dialog
   → durable client command journal (SQLite file)
   → trusted server RPC (public.spin_reward_wheel)
   → table-level catalog stabilization (LOCK TABLE public.rewards IN SHARE MODE)
   → server-authoritative pseudorandom draw (PostgreSQL random())
   → immutable selection snapshot generated and committed
   → reward_redemptions created (status = 'pending_fulfillment', origin = 'wheel')
   → wheel_spins record created (composite FK consistency to redemption)
   → atomic RP ledger debit (-spin_cost_minor, reason_code = 'wheel_spin')
   → child_balances row decrement
   → committed result returned to mobile client
   → client celebration animation renders pre-determined winner
   → shared fulfillment/cancellation lifecycle (parent fulfills or cancels with refund)
   ```

---

## 2. Authoritative Economy Invariants

### A. Currency Model (Model C)
- **Permanent Progression:** Study XP is permanent and strictly non-spendable. It accumulates indefinitely to reflect longitudinal learning effort.
- **Unified Spendable Currency:** Reward Points (RP) is the **only** spendable family reward currency.
- **Integer Representation & Ledger Signedness:**
  - `rp_ledger.amount_minor`: A **signed** integer economic delta representing changes to the child's balance. Positive amounts represent credits (e.g. Growth awards, cancellation refunds), while negative amounts represent debits (e.g. Store redemptions, Wheel spins).
  - `child_balances.rp_balance_minor`: The cached spendable balance projection, strictly constrained to non-negative integers ($\ge 0$).
  - Minor unit ratio: $100\text{ minor units} = 1.00\text{ RP}$.
- **Zero Real-Money Value:** RP has no cash value, cannot be purchased with real currency, cannot be cashed out, and is never displayed with real-world currency symbols (`$`, `USD`) in child prompts.
- **No Direct Mutation:** Neither children nor parents can directly mutate balance tables. Balances change exclusively via audited ledger events.

### B. Reward Store Invariants
- **Deterministic Outcome:** Redemptions are 100% deterministic; children receive exactly the item selected.
- **Parent-Governed Pricing:** Cost is defined by parents in minor RP (`store_cost_minor`).
- **Pre-Debit Confirmation:** UI enforces explicit child confirmation showing cost and balance delta before RPC dispatch.
- **Strictly One-to-One:** Exactly one logical redemption produces exactly one ledger debit.
- **Non-Negative Balance:** Database checks and row-level locks prevent balances from ever going negative (`LW201`).
- **Historical Snapshot Resilience:** Redemptions snapshot title, description, category, and icon at purchase time; future catalog edits never alter historical redemptions.

### C. Celebration Wheel Invariants
- **Spin Cost:** Default = `1000 rp_minor` ($10.00\text{ RP}$). Configurable by parents within `500–5000 rp_minor` ($5.00–50.00\text{ RP}$).
- **Daily Cap:** Default = `3 spins/day/child`. Configurable by parents within `1–5 spins/day/child`.
- **Minimum Active Pool:** The Wheel strictly requires $\ge 3$ distinct active eligible rewards configured for that child (`LW203` fail-closed).
- **Fixed Relative Tier Weights:**
  - Common = `60`
  - Special = `30`
  - Rare = `10`
- **Weights vs Probabilities:** Tier weights are fixed relative weights, **not percentages**. The effective probability for reward $i$ is dynamically derived from the child's active eligible pool:
  $$P(i) = \frac{\text{weight}_i}{\sum_{j \in \text{pool}} \text{weight}_j}$$
- **Zero-Loss Guarantee:** Every successful spin produces exactly one positive, parent-approved family reward. Zero rewards, penalties, and "try-again" wedges are architecturally impossible.
- **No Rerolls:** Cancellation of a Wheel reward refunds the RP cost but does **not** grant a reroll; the spin remains permanently counted against that local calendar day's quota.

### D. Server Randomness & Cryptographic Clarification
- **Canonical Terminology:** `server-authoritative pseudorandom selection` using PostgreSQL `random()`.
- **Strict Framing:** It is **NOT** claimed to be a cryptographically secure RNG and is not intended for real-money gambling.
- **Prohibited Terminology:** Do not use `cryptographic randomness`, `cryptographic draw`, `cryptographic snapshot`, or `secure gambling RNG`.
- **Auditable Record:** Every spin commits an immutable, server-authoritative selection snapshot to `wheel_spins.selection_snapshot`.

---

## 3. Wheel Selection Contract

The selection algorithm inside `public.spin_reward_wheel` executes deterministically as follows:
1. Materialize active, eligible rewards for the target child under catalog share lock.
2. Sort candidate rewards deterministically by `id ASC` (`reward_id_asc`).
3. Assign canonical tier weight ($W_i \in \{60, 30, 10\}$) to each reward.
4. Compute total weight:
   $$W_{\text{total}} = \sum_{i=1}^N W_i$$
5. Construct contiguous half-open intervals $[S_i, E_i)$ where $S_0 = 0$, $E_i = S_i + W_i$, and $E_N = W_{\text{total}}$.
6. Generate pseudorandom draw:
   $$R = \lfloor \text{random}() \times W_{\text{total}} \rfloor \in [0, W_{\text{total}})$$
7. Select winning reward $k$ where $S_k \le R < E_k$.

### Selection Snapshot Schema (`wheel-v0.1`)
The committed `selection_snapshot` JSONB captures:
```json
{
  "wheel_config_version": "wheel-v0.1",
  "spin_cost_minor": 1000,
  "deterministic_ordering": "reward_id_asc",
  "total_weight": 100,
  "random_draw": 42,
  "winning_reward_id": "fdd517bf-...",
  "ordered_pool": [
    {
      "reward_id": "7f6ab7b5-...",
      "title": "Choice of Dessert",
      "category": "treat",
      "icon_key": "default_star",
      "tier": "special",
      "weight": 30,
      "interval_start": 0,
      "interval_end": 30,
      "probability_pct": 30.00
    },
    {
      "reward_id": "e4c31d08-...",
      "title": "Trip to Trampoline Park",
      "category": "experience",
      "icon_key": "default_star",
      "tier": "rare",
      "weight": 10,
      "interval_start": 30,
      "interval_end": 40,
      "probability_pct": 10.00
    },
    {
      "reward_id": "fdd517bf-...",
      "title": "15m Video Game Time",
      "category": "privilege",
      "icon_key": "default_star",
      "tier": "common",
      "weight": 60,
      "interval_start": 40,
      "interval_end": 100,
      "probability_pct": 60.00
    }
  ]
}
```
**Client Presentation Rule:** The mobile client's animation is strictly a presentation layer for the server-committed outcome. The animation controller reads `winning_reward_id` from the RPC response and eases into the corresponding wedge.

---

## 4. Catalog Serialization & Concurrency Contract

To prevent statement-snapshot skew in PostgreSQL READ COMMITTED transactions without deadlocking against Store redemptions, `spin_reward_wheel` executes:
```sql
LOCK TABLE public.rewards IN SHARE MODE;
```
- **Serialization Guarantee:**
  - `SHARE` mode conflicts with `ROW EXCLUSIVE` (`INSERT`, `UPDATE`, `DELETE`), serializing concurrent parent catalog mutations.
  - If parent mutation commits first $\implies$ spin waits and materializes the **complete NEW pool**.
  - If spin snapshot acquires lock first $\implies$ parent mutation waits and spin materializes the **complete OLD pool**.
  - Hybrid/skewed catalog pools are mathematically prohibited.
- **Store Concurrency Compatibility:**
  - `SHARE` mode is fully compatible with `ROW SHARE` (`SELECT ... FOR SHARE`), ensuring concurrent Store redemptions proceed without lock contention.
- **Architectural Scope & Backlog Note:**
  - This is a v0.1 correctness-first global table lock.
  - *Backlog:* Replace global reward catalog SHARE locking with a scalable family-scoped coordination mechanism only if production multi-tenant contention justifies it, preserving OLD-or-NEW snapshot semantics and Store/Wheel deadlock safety.

---

## 5. Daily-Cap Timezone Semantics

The Celebration Wheel daily spin cap is evaluated strictly against the family's configured timezone (`families.timezone`):
- **Local Calendar Day Boundaries:** Bounded by local calendar midnight:
  $$[\text{local midnight today}, \text{local midnight tomorrow})$$
- **Rolling Window Rejection:** Fixed rolling 24-hour windows are rejected; quota resets cleanly at local midnight.
- **Daylight Saving Time (DST) Resilience:**
  - Standard day (e.g. `Asia/Ho_Chi_Minh`): spans exactly 24.0 hours.
  - Spring-forward transition (e.g. `America/New_York` 2026-03-08): spans exactly 23.0 hours.
  - Fall-back transition (e.g. `America/New_York` 2026-11-01): spans exactly 25.0 hours.
  - Calendar day start and end timestamps match local midnight across all transitions.
- **Fail-Closed Validation:** Missing or corrupted timezones fail closed with `LW004` on any new spin command.
- **Replay Resilience:** Committed historical spin replays are validated prior to timezone inspection and remain replayable even if family settings or timezones are corrupted later.

---

## 6. Strict Authorization, Replay, and Execution Ordering

Every Phase 4 economic RPC enforces a strict, fail-closed ordering:
```text
1. Input Validation: Check non-null UUIDs (p_command_id, p_child_id) -> 22000
2. Authentication Check: auth.uid() cannot be null -> 42501
3. Authoritative Child Lookup & Family Derivation: Derive v_family_id from database under RLS -> P0002
4. Authorization Verification (BEFORE configuration inspection):
   - Verify caller is active adult (private.is_active_family_adult) OR paired child device (private.is_active_child_device)
   - If unauthorized -> 42501 immediately
   - Invariant: Eliminates target-family configuration state oracles (unauthorized callers cannot distinguish valid from corrupt timezones).
5. Command Receipt Replay Inspection (BEFORE new-command validation):
   - If valid replay found -> return committed historical result immediately
   - Replay survives subsequent timezone corruption or catalog deletion.
6. NEW COMMAND ONLY Validation:
   - Validate family timezone fail-closed -> LW004
7. Preconditions & Concurrency Locks:
   - Load & lock family_wheel_settings FOR SHARE -> LW206 if disabled
   - Acquire LOCK TABLE public.rewards IN SHARE MODE
   - Materialize eligible pool -> LW203 if < 3 items
   - Lock child_balances FOR UPDATE
   - Check balance >= cost -> LW201
   - Check local daily cap -> LW202
8. Pseudorandom Draw:
   - Server-authoritative draw from stabilized in-memory pool
9. Atomic Commits:
   - Insert reward_redemptions (status = 'pending_fulfillment')
   - Insert wheel_spins (composite FK consistency)
   - Append rp_ledger debit (reason_code = 'wheel_spin', source_type = 'reward_redemption')
   - Update child_balances (decrement balance)
   - Insert command_receipts (operation = 'spin_wheel')
10. Return result payload
```

---

## 7. Durable Client Command Journaling & Recovery UX

To guarantee client-side idempotency across network drops, timeouts, and app process crashes:
- **Local SQLite Journaling:**
  - `SpinRewardWheel` and `RedeemStoreReward` use cases record pending command intents to local SQLite (`pending_reward_commands` table) **before** network dispatch.
  - Pending records store `operation`, `command_id`, `family_id`, `child_id`, `reward_id`, and `created_at`.
- **Process Restart Persistence:**
  - **Verified Automated Evidence:** Automated tests prove file-backed persistence across database close/reopen and reconstruction of application/data-layer instances on a real SQLite file, modeling process-restart recovery.
  - **Architectural Expectation:** Because the journal is stored in persistent SQLite on the filesystem, it is designed to survive normal device restarts, but an actual hardware/device reboot was not part of the automated Phase 4 CI evidence.
  - On retry, the application reuses the exact same journaled `command_id`, preventing duplicate debits or multi-spin balance corruption.
- **Neutral Recovery UX:**
  - In `ChildWheelScreen`, if an uncertain failure occurs and a pending journaled command remains, definite error wording (`Could not spin`, `Spin failed`) is suppressed.
  - Renders a neutral recovery card:
    > *"We're checking whether your spin was completed. A previous spin was interrupted by a network issue. Check now to see your reward without spending extra RP."* with `[Check / Retry Spin]`.
  - Tapping retry replays the journaled command, resolves the server-committed outcome, and clears the journal row upon confirmed resolution.

---

## 8. Ledger Provenance & Reconcilability Contract

The canonical ledger provenance for all Phase 4 economic operations:

| Operation | `source_type` | `source_id` | `reason_code` | `amount_minor` | `metadata` |
|:---|:---|:---|:---|:---|:---|
| Store Redemption Debit | `reward_redemption` | `redemption_id` | `store_redemption` | `-cost_minor` | `{ "reward_id": "..." }` |
| Celebration Wheel Debit | `reward_redemption` | `redemption_id` | `wheel_spin` | `-spin_cost_minor` | `{ "spin_id": "...", "reward_id": "..." }` |
| Redemption Cancellation Refund | `reward_redemption` | `redemption_id` | `redemption_refund` | `+rp_cost_minor` | `{ "cancellation_reason": "...", "reward_id": "..." }` |

- **Architectural Rationale:** Anchoring debits and cancellation refunds to `reward_redemption` ensures that the financial entity identity is preserved identically across debits and refunds. Cancellation refunds use natural idempotency key `idempotency_key = 'rp:refund:' || redemption_id`. `wheel_spins` provides the immutable draw audit snapshot, linked via composite foreign key.
- **Reconciliation Invariant:**
  $$\text{child\_balances.rp\_balance\_minor} == \sum \text{rp\_ledger.amount\_minor}$$
  Verified via single-MVCC-snapshot `public.reconcile_child_balance(child_id)` across all integration scenarios.

---

## 9. Redemption Lifecycle Contract

The redemption lifecycle is unified across both Store and Wheel:
```text
pending_fulfillment ────► fulfilled (terminal)
        │
        └───────────────► cancelled (terminal, triggers compensating refund)
```
- Both transitions are terminal; once fulfilled or cancelled, no further state change is permitted (`LW204`).
- Concurrent fulfill vs. cancel races are serialized under row lock (`FOR UPDATE`); exactly one transaction wins, and the other is rejected with `LW204`.
- Wheel redemptions follow the identical fulfillment lifecycle as Store redemptions; no separate Wheel fulfillment system exists.

---

## 10. Security & Relational Invariants

- **Tenant Isolation:** All operations enforce `family_id` boundary via PostgreSQL Row Level Security (RLS) and security-definer helper functions.
- **Role Permissions:**
  - Children cannot create, update, or delete rewards (`public.rewards`), nor alter wheel settings (`public.family_wheel_settings`).
  - Adults have full catalog management and redemption fulfillment authority within their family.
  - Direct client `INSERT`, `UPDATE`, `DELETE` on ledgers (`rp_ledger`, `xp_ledger`), balances (`child_balances`), command receipts (`command_receipts`), and spin records (`wheel_spins`) is strictly revoked.
- **Table Immutability:**
  - `command_receipts` is strictly immutable (trigger rejects UPDATE/DELETE with `LW102`).
  - `wheel_spins` is strictly immutable (trigger rejects UPDATE/DELETE with `LW102`).
- **Composite Consistency Foreign Keys:**
  - `fk_wheel_spins_redemption_composite` enforces that `wheel_spins` and `reward_redemptions` match on:
    `(redemption_id, family_id, child_id, reward_id, spin_cost_minor)`.
  - Database rejects cross-entity mismatch even if application or RPC logic is flawed.

---

## 11. Anti-Compulsion & Child Welfare Rules

The Celebration Wheel strictly enforces child-welfare guardrails:
1. **Zero-Loss Guarantee:** Every spin awards a tangible, parent-approved reward.
2. **No Real-Money Cash-Out:** RP cannot be redeemed for fiat currency.
3. **No Purchased Spins:** Spins cannot be bought with money, in-app purchases, or ads.
4. **No Near-Miss Manipulation:** Visual animations never artificially linger on high-tier wedges before sliding to low-tier wedges.
5. **No Paid Rerolls:** Once spun, outcomes are final.
6. **No Academic Confiscation:** Study XP is never deducted or gambled.
7. **No Compulsive Friction:** Confirmation dialogs require conscious tap confirmation with clear RP cost disclosure.

---

## 12. Verification & Test Evidence

### Merged Codebase Test Counts
- **Database pgTAP Test Suite:** **242 tests passing** across 6 test files:
  - `01_auth_simulation_test.sql`
  - `02_family_rls_security_test.sql`
  - `03_assessment_security_test.sql`
  - `04_growth_ledger_test.sql`
  - `05_reward_store_test.sql`
  - `06_celebration_wheel_test.sql` (**67 tests passing**)
- **Dart & Flutter Tests:**
  - `learnward_domain`: **106 tests passing**
  - `learnward_application`: **36 tests passing**
  - `learnward_data`: **18 tests passing** (including file-backed SQLite restart recovery)
  - `learnward_design_system`: **2 tests passing**
  - `learnward_test_support`: **1 test passing**
  - `mobile`: **50 widget tests passing** (including 11 wheel widget tests)

### Concurrency & Integration Regressions (100% Green)
- `scripts/test_last_owner_concurrency.mjs` — PASS
- `scripts/test_assessment_verification_concurrency.mjs` — PASS
- `scripts/test_assessment_evidence_storage_security.mjs` — PASS
- `scripts/test_assessment_vertical_slice_retry.mjs` — PASS
- `scripts/test_growth_concurrency.mjs` — PASS
- `scripts/test_growth_vertical_slice.mjs` — PASS
- `scripts/test_growth_delivery_recovery.mjs` — PASS
- `scripts/test_growth_parity.mjs` — PASS
- `scripts/test_reward_store_concurrency.mjs` — PASS
- `scripts/test_reward_store_vertical_slice.mjs` — PASS
- `scripts/test_reward_wheel_concurrency.mjs` — PASS (4 scenarios: double-spin race, daily cap race, Store-vs-Wheel race, deterministic Case 4A and 4B lock wait assertions)
- `scripts/test_reward_wheel_vertical_slice.mjs` — PASS
- `scripts/test_reward_wheel_timezone.mjs` — PASS (DST spring-forward 23h, fall-back 25h, standard 24h, corrupt fail-closed)

### Platform Builds in CI
- **Android Debug APK Build:** SUCCESS
- **iOS Simulator Compilation:** SUCCESS

---

## 13. Known Non-Blocking Backlog Items

The following items are deferred to future hardening and do not block Phase 4 freeze:
1. **Actor-Aware Pending Command Journal:**
   Pending client commands currently index by `(familyId, childId)`. Server command receipts are actor-bound and fail closed. Future enhancement: persist `auth_user_id` in SQLite journal for explicit multi-user shared device journal cleanup.
2. **Family-Scoped Catalog Stabilization Lock:**
   The v0.1 implementation uses a global `LOCK TABLE public.rewards IN SHARE MODE`. Optimize to a family-scoped coordination lock only if production multi-tenant contention justifies it.
3. **Exact-Timestamp Growth Comparator Tie:**
   Existing Phase 3 backlog item remains unchanged.
4. **Android Release Signing:**
   Release keystores and signing configurations deferred to release hardening.
