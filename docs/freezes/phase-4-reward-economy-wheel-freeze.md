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
- **Spin Cost:** Default = `1000 rp_minor` (10 RP). Configurable by parents within `500–5000 rp_minor` (5–50 RP).
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
**Client Presentation Rule:** The mobile client's animation is strictly a presentation layer for the server-committed outcome. The animation controller reads the committed `selection_snapshot`/winner from the RPC result and lands within the recorded winning wedge.

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
  - Hybrid/skewed catalog pools are prohibited by the frozen synchronization contract.
- **Store Concurrency Compatibility:**
  - Store redemption locks its target reward row with `SELECT ... FOR UPDATE`. PostgreSQL uses a `ROW SHARE` table-level lock for that statement, which is compatible with the Wheel's table-level `SHARE` lock. The target Store reward row itself is still row-locked `FOR UPDATE`.
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

## 6. Strict Authorization, Replay, and Execution Contracts

Phase 4 separates execution contracts into **command-based trusted economic mutations** and the **read-only Wheel status query**.

### A. Common Security and Idempotency Invariants

The command-based mutation functions are `redeem_store_reward`, `fulfill_reward_redemption`, `cancel_reward_redemption`, and `spin_reward_wheel`.

They do **not** share one identical statement ordering. Their frozen common guarantees are:
- an authenticated caller is required;
- target resources and authoritative `family_id` values come from database state rather than caller-supplied family identity;
- authorization occurs before command-receipt replay data is returned and, for Wheel, before family timezone/settings are inspected;
- replay validates `operation`, `actor_user_id`, `family_id`, and operation-specific `resource_id`/resource binding;
- valid replay returns the committed logical outcome without repeating economic effects;
- new commands use operation-specific locks and business preconditions;
- mutation and command-receipt insertion are atomic in the same transaction;
- `public.command_receipts` stores exactly `command_id`, `operation`, `actor_user_id`, `resource_id`, `family_id`, and `created_at`; there is no generic `payload` column.

These guarantees do **not** claim target-resource existence confidentiality. Current RPCs may load a resource before authorization, so an authenticated caller can distinguish `P0002` (missing target) from `42501` (existing but unauthorized target). Hiding resource existence is a future hardening concern, not a frozen Phase 4 property.

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
→ enforce family-local daily cap by counting wheel_spins (LW202)
→ server-authoritative pseudorandom selection from stabilized pool
→ create reward_redemption + wheel_spin + negative RP ledger debit + decrement balance
→ insert command_receipt
→ return committed spin result
```

### C. Read-Only Query Contract — `get_wheel_status`

`get_wheel_status` does **not** consume a command ID, create command receipts, acquire the Wheel catalog table lock, debit RP, create spin rows, or mutate economy state.

Its frozen implementation sequence is:
```text
validate child_id
→ authenticate
→ load active child and derive family
→ authorize active family adult OR exact paired child device
→ validate families.timezone (LW004)
→ read family_wheel_settings, or use function defaults if no row exists
→ calculate family-local [midnight, next midnight) bounds
→ count wheel_spins for the child inside that local-day window
→ count active child-eligible wheel rewards
→ return status
```

The returned status includes `spins_today`, `spins_remaining`, `spin_cost_minor`, `daily_spin_cap`, `is_enabled`, `local_day_start`, `local_day_end`, and `eligible_reward_count`.

---

## 7. Durable Client Command Journaling & Recovery UX

To guarantee client-side idempotency across network drops, timeouts, and app process crashes:
- **Local SQLite Journaling Scope:**
  - All four Phase 4 economic use cases persist pending command intents to the local SQLite `pending_reward_commands` table **before** network dispatch:
    1. `RedeemStoreReward` (`operation = 'redeem_reward'`): persists `(command_id, family_id, child_id, reward_id, created_at)`.
    2. `FulfillRewardRedemption` (`operation = 'fulfill_reward'`): persists `(command_id, family_id, redemption_id, created_at)`.
    3. `CancelRewardRedemption` (`operation = 'cancel_reward'`): persists `(command_id, family_id, redemption_id, cancellation_reason, created_at)`.
    4. `SpinRewardWheel` (`operation = 'spin_wheel'`): persists `(command_id, family_id, child_id, created_at)`.
- **Uncertain Failure Retention & Retry Reuse:**
  - If a network drop, timeout, or application crash occurs during execution, the journal record remains persisted in SQLite unless the application classifies the response as a deterministic terminal rejection.
  - On retry, the application reuses the exact same journaled `command_id` and logical payload, ensuring server-side command receipts safely replay or deduplicate the request without duplicate RP debits or duplicate state transitions.
  - The journal row is cleared only upon confirmed resolution or deterministic terminal business rejection.
- **Process Restart Persistence:**
  - **Verified Automated Evidence:** Automated tests prove file-backed persistence across database close/reopen and reconstruction of application/data-layer instances on a real SQLite file, modeling process-restart recovery.
  - **Architectural Expectation:** Because the journal is stored in persistent SQLite on the filesystem, it is designed to survive normal device restarts, but an actual hardware/device reboot was not part of the automated Phase 4 CI evidence.
- **Neutral Recovery UX:**
  - When an economic outcome remains uncertain and a pending journal entry still exists, the client must not present the operation as definitely failed.
  - Wheel recovery explicitly exposes a neutral `Check / Retry Spin` path and replays the persisted command rather than creating a new spin intent.

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

- **Tenant Isolation:** Phase 4 tables and trusted functions enforce family/child boundaries through database constraints, RLS where directly exposed, and trusted authorization helpers.
- **Role Permissions:**
  - Children cannot create, update, or delete rewards (`public.rewards`), nor alter wheel settings (`public.family_wheel_settings`).
  - Adults have catalog management and redemption fulfillment authority only within their authorized family.
  - Direct client `INSERT`, `UPDATE`, `DELETE` on ledgers (`rp_ledger`, `xp_ledger`), balances (`child_balances`), command receipts (`command_receipts`), and spin records (`wheel_spins`) is revoked.
- **Table Immutability:**
  - `command_receipts` is strictly immutable (trigger rejects UPDATE/DELETE with `LW102`).
  - `wheel_spins` is strictly immutable (trigger rejects UPDATE/DELETE with `LW102`).
- **Composite Consistency Foreign Key:**
  - `fk_wheel_spins_redemption_composite` binds the Wheel spin tuple `(redemption_id, family_id, child_id, reward_id, origin, spin_cost_minor)` to `reward_redemptions(id, family_id, child_id, reward_id, origin, rp_cost_minor)`.
  - This enforces the same redemption, family, child, reward, Wheel origin, and RP cost at the database layer.
  - Database rejects relational mismatch even if application or RPC logic is flawed.

---

## 11. Anti-Compulsion & Child Welfare Rules

The Celebration Wheel strictly enforces child-welfare guardrails:
1. **Zero-Loss Guarantee:** Every successful spin awards a tangible, parent-approved reward.
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
- `scripts/test_reward_wheel_concurrency.mjs` — PASS (double-spin race, daily-cap race, Store-vs-Wheel race, deterministic catalog OLD/NEW lock-wait cases)
- `scripts/test_reward_wheel_vertical_slice.mjs` — PASS
- `scripts/test_reward_wheel_timezone.mjs` — PASS (DST spring-forward 23h, fall-back 25h, standard 24h, corrupt fail-closed)

### Platform Builds in CI
- **Android Debug APK Build:** SUCCESS
- **iOS Simulator Compilation:** SUCCESS

---

## 13. Known Non-Blocking Backlog Items

The following items are deferred to future hardening and do not block Phase 4 freeze:
1. **Actor-Aware Pending Command Journal:**
   Pending reward commands do not persist the originating `auth_user_id`. Lookup keys are operation-specific (family/child/reward for Store redemption, redemption for fulfill/cancel, family/child for Wheel spin). Server command receipts remain actor-bound and fail closed. Future enhancement: persist `auth_user_id` for explicit multi-user shared-device journal cleanup/recovery.
2. **Family-Scoped Catalog Stabilization Lock:**
   The v0.1 implementation uses a global `LOCK TABLE public.rewards IN SHARE MODE`. Optimize to a family-scoped coordination lock only if production multi-tenant contention justifies it.
3. **Resource-Existence Confidentiality:**
   Phase 4 trusted mutations may load a target resource before authorization and therefore can distinguish missing (`P0002`) from existing-but-unauthorized (`42501`) targets. Consider existence-hiding lookup/authorization patterns during production security hardening if this becomes a requirement.
4. **Exact-Timestamp Growth Comparator Tie:**
   Existing Phase 3 backlog item remains unchanged.
5. **Android Release Signing:**
   Release keystores and signing configurations deferred to release hardening.
