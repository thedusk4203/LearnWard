# Phase 6 Detailed Design v0.1 — Pilot Hardening

- **Status:** PROPOSED (Design Checkpoint — Implementation NOT Authorized)
- **Reviewed Baseline:** `main` @ `462a17e603b69456b9eb2e000cfa7a7424e0c719`
- **Upstream Contracts:**
  - Phase 1 — Family + Child Identity: **FROZEN** ([Phase 1 Freeze Receipt](freezes/phase-1-family-child-identity-freeze.md), [ADR 0002](adr/0002-phase-1-family-child-identity.md))
  - Phase 2 — Secure Assessment Capture: **FROZEN** ([Phase 2 Freeze Receipt](freezes/phase-2-secure-assessment-capture-freeze.md), [ADR 0003](adr/0003-phase-2-secure-assessment-capture.md))
  - Phase 3 — Growth Engine + Ledgers: **FROZEN** ([Phase 3 Freeze Receipt](freezes/phase-3-growth-engine-ledger-freeze.md), [ADR 0004](adr/0004-phase-3-growth-engine-ledger.md))
  - Phase 4 — Reward Economy & Wheel: **FROZEN** ([Phase 4 Freeze Receipt](freezes/phase-4-reward-economy-wheel-freeze.md), [ADR 0005](adr/0005-phase-4-reward-economy-wheel.md))
  - Phase 5.1 — Learning Engine & Mastery: **FROZEN** ([Phase 5.1 Freeze Receipt](freezes/phase-5-1-learning-mastery-foundation-freeze.md), [ADR 0006](adr/0006-phase-5-learning-engine-mastery.md))
  - Phase 5.2 — Skill Graph & Recommendations: **FROZEN** ([Phase 5.2 Freeze Receipt](freezes/phase-5-2-skill-graph-recommendation-foundation-freeze.md), [ADR 0007](adr/0007-phase-5-2-skill-graph-recommendation.md))
  - Phase 5 — Complete Learning Engine: **COMPLETE / SEALED**
- **Readiness Review:** [Phase 6 Dependency & Readiness Review](16-phase-6-pilot-hardening-dependency-readiness-review.md) (`PASS / COMPLETE / FROZEN`, PR #12 merged @ `462a17e603b69456b9eb2e000cfa7a7424e0c719`, Post-merge CI `41700860264`)
- **Companion ADR:** [ADR 0008 — Phase 6 Pilot Hardening Architectural Decisions](adr/0008-phase-6-pilot-hardening.md) (`PROPOSED`)

---

## 1. Scope, Purpose & Pilot Exit Gate

### 1.1 Purpose
Phase 6 delivers **Pilot Hardening** for LearnWard, transforming the verified, sealed algorithmic and economic engine into a production-grade mobile client and backend capable of supporting real families in a closed pilot.

### 1.2 Authoritative Pilot Exit Gate
Per `docs/05-pilot-plan-v0.1.md` and `docs/10-implementation-plan-v0.1.md` Section 19:
> **A small family pilot can run for four consecutive weeks without engineering intervention for normal daily usage.**

*(Note: Cohort scale assumptions such as 20–50 families are planning guidelines only and do not alter the mandatory four-week autonomous operation exit gate).*

Normal daily usage includes:
1. Children capturing assessment scores and evidence photos offline or online;
2. Parents reviewing and approving/rejecting submitted assessments;
3. Verified learning events automatically triggering Growth Engine calculations, append-only ledger entries, and EWMA mastery updates;
4. Children redeeming earned RP for guaranteed store rewards or spinning the celebration wheel within parent-configured daily caps;
5. Parents fulfilling pending reward claims and tracking longitudinal mastery progression;
6. Next Challenge candidate recommendations presenting clear, deterministic choices across recovery, refresh, developing, unlock, and explore.

### 1.3 Sub-Phase Decomposition
Phase 6 is partitioned into three sequential, reviewable slices:
- **Phase 6.1 — Offline Resilience, Bounded Outbox & Actor-Aware Command Recovery:** Durable SQLite command queues, actor identity binding, local containment lifecycle, camera permissions, evidence resumability, and failure/retry presentation.
- **Phase 6.2 — Notifications, Privacy-Preserving Telemetry & Data Retention:** In-app coordination alerts, authoritative reconciliation, canonical VLPE derivation, 12/16 metric instrumentation, right-to-erasure archival, and data portability.
- **Phase 6.3 — Accessibility, Reduced-Motion Wheel & Release Operations:** Semantics labeling, minimum touch targets, dynamic type font scaling, reduced-motion wheel safety, signed release packaging, and diagnostic observability.

### 1.4 Explicit Deferred Post-Pilot Scope
The following items remain strictly out of scope for Phase 6:
- AI chatbot / conversational tutoring interfaces
- Automatic OCR handwriting recognition or grading at scale
- Full national or international curriculum databases (`pilot-v0.1` remains the sole active catalog)
- Social network feeds, peer sharing, and sibling leaderboards
- Third-party commercial e-commerce reward integrations
- Virtual pet worlds, avatar cosmetic items, or gamified meta-universes
- School LMS integrations (Google Classroom, Canvas, Schoology)
- Complex psychometric models (Bayesian Knowledge Tracing, Item Response Theory)
- In-app purchase payment processing, subscription tiers, and paywalls
- Web-based parent or teacher administration portal
- Automated cloud CI deployment credentials (Play Console / App Store Connect API keys); manual signed release upload directly satisfies the pilot gate

---

## 2. Phase 6 Architecture & Dependency Graph

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                    PHASE 5 COMPLETE / SEALED BASELINE                   │
│   (Auth, Capture, Ledgers, Store, Wheel, Mastery, Skill Graph Engine)   │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 6.1: Offline Resilience, Outbox & Actor-Aware Recovery            │
│  - Drift Schema v5 (actor_user_id, actor_role, schema_version)          │
│  - Non-destructive migration from populated v4 databases                │
│  - Quarantine & explicit re-authorization for legacy v4 pending rows    │
│  - Bounded Assessment Outbox & Idempotent Evidence Upload               │
│  - Local Security Boundary (per-class purge lifecycle)                  │
│  - iOS NSCameraUsageDescription & NSPhotoLibraryUsageDescription        │
│  - Adaptive Image Compression preserving handwriting legibility         │
│  - Reusable Failure & Retry UX Primitives                               │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 6.2: Notifications, Privacy Telemetry & Data Retention            │
│  - In-App Coordination Notifications (Approval, Fulfillment)            │
│  - Transient Realtime transport with Authoritative State Reconciliation │
│  - Canonical VLPE Engine (Growth + Learning processed)                  │
│  - 12/16 Authoritative Metric Queries & Minimal Telemetry Envelope      │
│  - Comprehensive Child-Linked Table & Storage Inventory                 │
│  - Soft-Delete Archival with RLS Read-Boundary Exclusion                │
│  - Secure Family Data Portability Export RPC                            │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 6.3: Accessibility, Motion Safety & Release Operations            │
│  - Screen Reader Semantics & 48x48 dp Touch Target Enforcement          │
│  - Dynamic Type Text Scaling without Layout Overflow                    │
│  - Reduced-Motion Wheel Reveal (preserving server-authoritative logic)  │
│  - Release Keystore & Signed Artifact Generation (AAB / TestFlight IPA) │
│  - Diagnostic Support Card & Redacted Structured Logging                │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                   PILOT EXIT GATE VERIFICATION (4 WEEKS)                │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Phase 6.1 — Offline Resilience, Bounded Outbox & Actor-Aware Recovery

### 3.1 Bounded Outbox Architecture
Rather than introducing a fragile, polymorphic generic queue table across all domain operations, Phase 6.1 adopts **bounded, domain-specific outboxes**:
1. **Reward Operations:** Hardened `pending_reward_commands` table handling `redeemReward`, `spinWheel`, `fulfillReward`, and `cancelReward`.
2. **Assessment Capture & Submission:** Extended `local_assessment_drafts` table managing the draft lifecycle and background submission retry.
3. **Read Models:** Stale-while-revalidate local caching in Drift SQLite for `LearningOverview` and `NextChallengeCandidates`, allowing disconnected inspection without write queueing.

---

### 3.2 Drift Database Schema Migration (v4 $\to$ v5) & Backfill Compatibility
The local database schema (`packages/learnward_data/lib/src/database/app_database.dart`) migrates to `schemaVersion = 5`.

#### 3.2.1 Analysis of Frozen v4 Schema vs. v5 Requirements
Comparing existing v4 definitions against v5 requirements:
- In v4 `PendingRewardCommands`: `childId` is `text().nullable()()`. In v5, `childId` **MUST REMAIN NULLABLE** to prevent schema mismatches and migration failures.
- In v4 `LocalAssessmentDrafts`: `createCommandId`, `submitCommandId`, `evidenceId`, `serverAssessmentId`, and `localPhotoPath` are all `text().nullable()()`. In v5, they **MUST REMAIN NULLABLE** because new drafts generate these IDs progressively throughout the draft/upload lifecycle.
- In SQLite, adding non-nullable columns without constant default values via `ALTER TABLE ADD COLUMN` is disallowed by SQLite syntax. Furthermore, assigning fabricated actor identities (such as a hardcoded dummy UUID) violates audit provenance and security invariants.

#### 3.2.2 Corrected Drift v5 Table Declarations
```dart
// packages/learnward_data/lib/src/database/pending_reward_commands.dart
@DataClassName('PendingRewardCommandEntry')
class PendingRewardCommands extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get operation => text()(); // 'redeemReward' | 'spinWheel' | 'fulfillReward' | 'cancelReward'
  TextColumn get commandId => text().unique()();
  TextColumn get familyId => text()();
  TextColumn get childId => text().nullable()(); // Preserved nullable from v4
  TextColumn get rewardId => text().nullable()();
  TextColumn get redemptionId => text().nullable()();
  TextColumn get cancellationReason => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  // Phase 6.1 Additions (nullable in SQLite to guarantee safe non-destructive migration):
  TextColumn get actorUserId => text().nullable()();
  TextColumn get actorRole => text().nullable()();
  IntColumn get schemaVersion => integer().withDefault(const Constant(1))();
  TextColumn get recoveryState => text().withDefault(const Constant('active'))();
  // Valid states: 'active', 'quarantined_legacy_v4', 'pending_original_actor'
}

// packages/learnward_data/lib/src/database/local_assessment_drafts.dart
@DataClassName('LocalAssessmentDraftEntry')
class LocalAssessmentDrafts extends Table {
  TextColumn get localDraftId => text()();
  TextColumn get familyId => text()();
  TextColumn get childId => text()();
  TextColumn get createCommandId => text().nullable()(); // Preserved nullable from v4
  TextColumn get submitCommandId => text().nullable()(); // Preserved nullable from v4
  TextColumn get evidenceId => text().nullable()();      // Preserved nullable from v4
  TextColumn get serverAssessmentId => text().nullable()(); // Preserved nullable from v4
  TextColumn get subjectKey => text().withDefault(const Constant('math'))();
  TextColumn get subject => text()();
  TextColumn get title => text()();
  TextColumn get assessmentType => text()();
  TextColumn get difficulty => text()();
  RealColumn get rawScore => real()();
  RealColumn get maxScore => real()();
  TextColumn get localPhotoPath => text().nullable()();  // Preserved nullable from v4
  TextColumn get entryContext => text().withDefault(const Constant('shared_child'))();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  // Phase 6.1 Additions:
  TextColumn get submissionStatus => text().withDefault(const Constant('draft'))();
  // 'draft' | 'uploading_evidence' | 'submitting_assessment' | 'failed_retryable' | 'terminal_error'
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get lastErrorMessage => text().nullable()();
  TextColumn get actorUserId => text().nullable()();
  TextColumn get actorRole => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localDraftId};
}
```

#### 3.2.3 Safe Migration & Backfill Strategy for Populated v4 Databases
1. **Migration Execution (`onUpgrade`):**
   ```dart
   if (from < 5) {
     await migrator.addColumn(pendingRewardCommands, pendingRewardCommands.actorUserId);
     await migrator.addColumn(pendingRewardCommands, pendingRewardCommands.actorRole);
     await migrator.addColumn(pendingRewardCommands, pendingRewardCommands.schemaVersion);
     await migrator.addColumn(pendingRewardCommands, pendingRewardCommands.recoveryState);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.submissionStatus);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.retryCount);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.lastErrorMessage);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.actorUserId);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.actorRole);

     // Mark existing pre-migration pending commands as quarantined:
     await customStatement(
       "UPDATE pending_reward_commands SET recovery_state = 'quarantined_legacy_v4', schema_version = 1 WHERE actor_user_id IS NULL"
     );
   }
   ```
2. **Quarantine & Explicit Recovery Contract:**
   - Existing v4 rows with `actorUserId = NULL` are placed in `quarantined_legacy_v4`.
   - **Zero Invented Identities:** The background queue will **never** automatically execute a quarantined command under whatever user happens to be logged in.
   - When an authenticated adult opens the application, if `quarantined_legacy_v4` commands exist for their family, the UI presents an explicit reconciliation dialog:
     *"You have an unconfirmed pending action from an earlier version: [Redeem reward 'X' / Spin Wheel]. Confirm to submit under your account, or cancel."*
   - If confirmed by the adult: `actorUserId` is bound to `auth.uid()`, `actorRole` is set to their family role, `recoveryState` transitions to `'active'`, and the command executes.
   - If cancelled: the command is safely deleted from SQLite, and the client refetches balances from the server.
3. **Assessment Drafts Backfill:**
   - Pre-existing drafts retain `submissionStatus = 'draft'` and their local photo paths. When the learner or parent re-opens, edits, or submits the draft, `actorUserId` and `actorRole` are bound to the active session performing the submission.

---

### 3.3 Actor-Aware Command Recovery & Error Classification

#### 3.3.1 Error Classification & Backend SQLSTATE `42501` Disambiguation
The server returns SQLSTATE `42501 (insufficient_privilege)` across diverse authorization conditions. The client **MUST NOT** treat all `42501` errors as device revocation.

| Server Condition | Error Code / Message | Client Classification | Client Recovery Action |
|---|---|---|---|
| Replayed command committed by another user | `42501: Command caller mismatch` | `CALLER_MISMATCH` | Query `command_receipts` or target entity; reconcile local state without re-executing |
| Device pairing grant revoked on server | `42501: Device grant revoked or inactive` | `DEVICE_REVOKED` | Verify grant status out-of-band; purge local child drafts/commands; transition to unlinked shell |
| Sibling device calling another child's RPC | `42501: Sibling access denied` | `CROSS_CHILD_VIOLATION` | Halt replay; mark command `terminal_error`; display boundary error |
| Non-parent attempting adult-only RPC | `42501: Parent authorization required` | `ROLE_MISMATCH` | Pause command in `pending_original_actor`; display permission notice |
| Transient network disconnect / timeout | `SocketException` / HTTP 5xx / timeout | `TRANSIENT_NETWORK` | Retain command in `active`; schedule exponential backoff retry |
| Terminal business failure (`LW202`, `LW203`, `LW206`) | `LW202: Insufficient RP`, `LW203: Daily cap` | `TERMINAL_BUSINESS_ERROR` | Purge command from journal; display friendly error; refetch balances |

#### 3.3.2 Reliable Revocation Detection Protocol
When an API request from a paired child device receives `42501`:
1. The client issues a dedicated query to `public.child_device_grants` for its device grant ID.
2. If and only if the server returns `status = 'revoked'` (or the query is denied because the grant was deleted), the client confirms `DEVICE_REVOKED`.
3. Upon confirmed revocation, the client executes the **Child Device Revocation Cleanup Protocol** (Section 3.4), wiping local drafts and queues for that child.
4. If the grant query succeeds and shows `status = 'active'`, the `42501` was caused by a command-specific permission issue (e.g. caller mismatch or tenant conflict); the device remains paired and the command is paused for parent review.

#### 3.3.3 Recovery When Operation Succeeded Remotely but Response Was Lost
Before retrying any mutating RPC (`redeem_reward`, `spin_reward_wheel`, `submit_assessment`, `verify_assessment`):
1. Client inspects `public.command_receipts` for the command's unique `commandId`.
2. If `command_receipts` contains `commandId`:
   - The operation **already succeeded** on the server.
   - Client queries the target table (`reward_redemptions`, `wheel_spins`, or `assessments`) by `command_id` to retrieve the committed server snapshot.
   - Client updates local state to completed, clears the pending command journal entry, and displays the committed outcome to the user without duplicating debits or spins.
3. If `command_receipts` does not contain `commandId`:
   - The operation never executed on the server. Client proceeds with idempotent RPC invocation.

#### 3.3.4 Multi-Actor Session Recovery (`pending_original_actor`)
On a shared family device:
1. Adult A queues a reward fulfillment command (`C1`). Network times out.
2. Adult A logs out. Adult B (co-parent) logs in.
3. Background command processor inspects `C1.actorUserId`. Since `C1.actorUserId != Adult_B.uid`, execution is **halted**.
4. Command `C1` is assigned `recoveryState = 'pending_original_actor'`.
5. Command `C1` is **preserved in SQLite** without data loss. It is not deleted and not replayed under Adult B.
6. When Adult A logs back in, `C1` transitions back to `'active'` and replays safely.

---

### 3.4 Local Data Security & Revocation Lifecycle

| Local Data Class | Storage Engine | Adult Sign-Out | Identity Switch (Co-Parent) | Family Switch | Child Mode Exit | Paired Child Revoked | Account Deletion |
|---|---|---|---|---|---|---|---|
| **Parent PIN Hash & Salt** | `local_metadata_entries` | **Retained** (device security) | **Retained** | **Purged** | **Retained** | **Retained** | **Purged** |
| **Active Child Session** | `local_metadata_entries` | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** |
| **Assessment Drafts** | `local_assessment_drafts` | **Retained** (if same family) | **Retained** | **Purged** | **Retained** | **Purged for Child** | **Purged** |
| **Pending Reward Commands** | `pending_reward_commands`| **Paused** (`pending_actor`) | **Paused** | **Purged** | **Retained** | **Purged for Child** | **Purged** |
| **Local Evidence Photos** | App Documents Dir | **Retained** (pending draft) | **Retained** | **Purged** | **Retained** | **Purged for Child** | **Purged** |
| **Cached Read Models** | SQLite Read Tables | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** |

---

### 3.5 Evidence Reliability & Storage Resumability

#### 3.5.1 Platform Camera Permissions
The following declarations are added to `apps/mobile/ios/Runner/Info.plist`:
```xml
<key>NSCameraUsageDescription</key>
<string>LearnWard uses the camera to capture photos of worksheets, quizzes, and tests for verified learning progress.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>LearnWard accesses your photo library to allow selecting photos of completed academic work.</string>
```

#### 3.5.2 Adaptive Image Compression Preserving Handwriting Legibility
Aggressive compression destroys the legibility of thin pencil lines, exponents, fractions, and math notation.
- **Adaptive Compression Rules:**
  - Bounding box: Maximum $2048 \times 1536$ pixels (preserving aspect ratio);
  - Format: JPEG;
  - Initial Quality: 85%;
  - Target Payload Size: $\le 1.5\text{ MB}$ (treated as an engineering objective, not an unconditional constraint);
  - If output exceeds $1.5\text{ MB}$, the compressor evaluates whether compression to 75% preserves contrast. If size remains between $1.5\text{ MB}$ and $2.5\text{ MB}$, the file is accepted as-is to prevent legibility degradation.
  - Image processing operates on byte buffers in memory or temporary files, never blocking the UI isolate.

#### 3.5.3 Resumable Storage Protocol via Supabase Dart Storage SDK
LearnWard uses `supabase_flutter: ^2.18.3` and `supabase: ^2.16.5` (`storage_client`). AWS S3 methods (`headBucket`, `getObject`) are not supported.
- **Deterministic Storage Path:** `{family_id}/{child_id}/{assessment_id}/{evidence_id}.jpg`
- **Object-Level Resumption Protocol:**
  1. Client checks if the object already exists remotely by listing the assessment folder:
     ```dart
     final files = await supabase.storage
         .from('assessment-evidence')
         .list(path: '$familyId/$childId/$assessmentId', searchOptions: const SearchOptions(limit: 20));
     final existing = files.where((f) => f.name == '$evidenceId.jpg').firstOrNull;
     ```
  2. If file exists and `metadata['size'] == localCompressedBytes.length`:
     - File upload already completed. Skip upload step.
     - Proceed directly to `register_assessment_evidence` RPC.
  3. If file does not exist or size differs:
     - Upload binary data:
       ```dart
       await supabase.storage.from('assessment-evidence').uploadBinary(
         storagePath,
         compressedBytes,
         fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false),
       );
       ```
  4. If upload returns HTTP 409 Conflict (uploaded concurrently by background task):
     - Treat as success; proceed to registration RPC.
  5. Check if evidence is already registered:
     - Query `public.assessment_evidence` where `assessment_id = :assessment_id AND evidence_id = :evidence_id`.
     - If record exists, update local draft status to `'submitting_assessment'` without re-registering.

---

### 3.6 Failure & Retry Presentation Primitives
The design system introduces standard user-facing error and retry components in `packages/learnward_design_system`:
- `AppErrorStateWidget`: Standard card rendering user-friendly explanation, recovery guidance, and a primary retry button.
- `AppOfflineBanner`: Non-intrusive persistent status bar appearing when network is lost, indicating that work is saved locally.
- `RetryActionCard`: Dedicated card rendered in inbox and history screens for pending/recovering transactions (analogous to `ChildWheelScreen` retry banner).
- **Error Mapping Rule:** Raw database exceptions (`PostgrestException`, `SocketException`, `HttpException`, `LW...` database error codes) must never be displayed raw to users. All errors pass through `DomainErrorMapper.toUserFriendlyMessage(error)`.

---

## 4. Phase 6.2 — Notifications, Privacy-Preserving Telemetry & Data Retention

### 4.1 Pilot Notification Architecture

#### 4.1.1 Approved Pilot Use Cases
1. **Parent Approval Required:** Child submits assessment $\to$ Parent receives notification: *"Alex submitted a Math assessment for review."*
2. **Reward Fulfilled:** Parent fulfills redemption $\to$ Child receives notification: *"Your reward '30 min extra gaming' was approved!"*

#### 4.1.2 Strict Anti-Spam Invariants
> [!CAUTION]
> **Product Rule:** LearnWard strictly prohibits engagement-farming notifications.
> - No streak danger or artificial urgency alerts;
> - No guilt-based reminders or virtual character taunts;
> - No competitive messages between siblings;
> - Notification opens or app launches are **NEVER** counted as learning progress (VLPE).

#### 4.1.3 Transient Realtime Transport with Authoritative State Reconciliation
- Supabase Realtime is a **transient transport signal**, not durable notification storage. If a device is offline, suspended, or killed, Realtime broadcasts are permanently dropped.
- **Authoritative Reconciliation on Launch / Reconnect:**
  - Badge counts and inbox items are **never** incremented solely by transient push/realtime counters.
  - Upon app open, network reconnection, or route navigation:
    - **Parent Inbox:** Reconciled by authoritative query:
      ```sql
      select count(*) from public.assessments where family_id = :family_id and status = 'pending_review';
      ```
    - **Child Rewards:** Reconciled by authoritative query:
      ```sql
      select count(*) from public.reward_redemptions where child_id = :child_id and status = 'fulfilled' and fulfilled_at > :last_viewed_at;
      ```
  - Incoming Realtime events serve only as an invalidation pulse triggering an authoritative background refetch.

#### 4.1.4 Deep-Link Security & Role Enforcement
When a user opens the app via notification deep link:
- `learnward://family/{family_id}/review/{assessment_id}`: Router verifies active session is an authenticated adult (`owner` or `parent`) belonging to `{family_id}`. If the active session is a child or belongs to another family, navigation is blocked and redirected to the default home screen with an access notice.
- `learnward://family/{family_id}/child/{child_id}/rewards`: Router verifies caller is authorized for `{child_id}`.

---

### 4.2 Telemetry & Authoritative Pilot Metrics

#### 4.2.1 Canonical VLPE Derivation
A `verified_learning_event` qualifies as a **Verified Learning Progress Event (VLPE)** if and only if that event has completed both Growth Engine and Learning Engine processing:
```sql
select count(*)
from public.verified_learning_events vle
where vle.child_id = :child_id
  and vle.verified_at >= :start
  and vle.verified_at < :end
  and exists (
    select 1
    from public.growth_events g
    where g.verified_learning_event_id = vle.id
  )
  and exists (
    select 1
    from public.learning_processing_events lp
    where lp.verified_learning_event_id = vle.id
      and lp.status = 'processed'
  );
```
Unprocessed or rejected assessments are strictly excluded.

#### 4.2.2 Authoritative PostgreSQL Metric Derivations (12 of 16 Metrics)
Exactly **12 of 16** metrics defined in `docs/06-metrics-and-hypotheses.md` are directly calculable from PostgreSQL:

1. **VLPE / child / week:** Canonical query above.
2. **Results logged / child / week:** Counts submitted assessment review events (excluding abandoned drafts):
   ```sql
   select count(*)
   from public.assessment_review_events rev
   join public.assessments a on a.id = rev.assessment_id and a.family_id = rev.family_id
   where rev.event_type = 'submitted' and a.child_id = :child_id
     and rev.created_at >= :start and rev.created_at < :end;
   ```
3. **% results logged by child:** Filtered aggregate over submitted assessment review events:
   ```sql
   count(*) filter (where a.entry_context in ('shared_child', 'paired_child'))::numeric / nullif(count(*), 0)
   ```
4. **4-week subject trend:** Grouped trajectory of `verified_learning_events.normalized_score` over 28-day window.
5. **Recovery completion rate:** Replayed weak observations in `learning_evidence_events` reaching $\ge 70\%$ within 30 days.
6. **Personal-best frequency:** Filtered aggregate over authoritative Growth awards:
   ```sql
   count(*) filter (where g.personal_best_rp_minor > 0)
   ```
   *(Score comparison alternative: `normalized_score >= historical_best + 0.25`, subject to Growth Engine eligibility and anti-farming rules).*
7. **Parent approval latency:** Time elapsed between submitted and verified review events:
   ```sql
   extract(epoch from (v_evt.created_at - s_evt.created_at))
   ```
8. **Reward fulfillment rate:** Filtered aggregate from `public.reward_redemptions`:
   ```sql
   count(*) filter (where status = 'fulfilled')::numeric /
   nullif(count(*) filter (where status in ('pending_fulfillment', 'fulfilled', 'cancelled')), 0)
   ```
9. **RP earned / week:** `SUM(amount_minor) FROM public.rp_ledger WHERE amount_minor > 0`.
10. **RP spent / week:** `ABS(SUM(amount_minor)) FROM public.rp_ledger WHERE amount_minor < 0`.
11. **Wheel vs. Store spend share:**
    ```sql
    select
      coalesce((select sum(ws.spin_cost_minor) from public.wheel_spins ws where ws.child_id = :id and ws.created_at >= :start and ws.created_at < :end), 0) as wheel_spend,
      coalesce((select sum(rr.rp_cost_minor) from public.reward_redemptions rr where rr.child_id = :id and rr.origin = 'store' and rr.created_at >= :start and rr.created_at < :end), 0) as store_spend;
    ```
12. **Week 4 / Week 8 retention:** Count of distinct active children with $\ge 1$ canonical VLPE in week 4 and week 8.

*Deferred / Qualitative metrics:*
- Metric 4 (% goals chosen by child): `NOT CURRENTLY MEASURABLE / DEFERRED` (Goals subsystem not authorized in Phase 6).
- Metric 9 (Parent admin minutes/day): Measured via client screen session timing or weekly survey.
- Metric 14 (Self-chosen challenge rate): Tracked via client event when Next Challenge card is launched.
- Metric 16 (Parent study reminders / week): Qualitative weekly interview check-in.

#### 4.2.3 Privacy-Preserving Minimal Telemetry Envelope
For UX interactions (challenge tapped, screen timing), client telemetry emits a minimal, sanitized envelope:
```json
{
  "event_name": "next_challenge_tapped",
  "occurred_at": "2026-11-04T12:00:00Z",
  "family_pseudonym": "f_9a8b7c6d",
  "child_pseudonym": "c_1e2f3a4b",
  "app_version": "0.1.0+1",
  "platform": "android",
  "metadata": {
    "node_type": "skill",
    "recommendation_reason": "developing",
    "subject_key": "math"
  }
}
```
**Strict Prohibition:** Telemetry payloads must **NEVER** contain child real names, parent emails, school names, geographic location, image URLs, raw assessment notes, or auth tokens.

---

### 4.3 Data Retention, Archival & Right-to-Erasure Architecture

#### 4.3.1 Inventory of Child-Linked Tables & Storage Assets
The LearnWard backend manages 19 relational tables and 1 Storage bucket containing child-associated data:
1. `public.child_profiles` (identifying metadata: display name, grade, birth year, avatar)
2. `public.child_device_grants` (device auth secrets, status)
3. `private.child_pairing_requests` (ephemeral pairing codes)
4. `public.assessments` (raw scores, titles, context)
5. `public.assessment_evidence` (storage references, file sizes)
6. `public.assessment_review_events` (review audit logs, notes)
7. `public.assessment_learning_mappings` (catalog node mappings)
8. `public.verified_learning_events` (immutable academic event records)
9. `public.learning_evidence_events` (immutable mastery evidence atoms)
10. `public.learning_processing_events` (processing audit status)
11. `public.mastery_state_revisions` (immutable EWMA snapshots)
12. `public.child_mastery_states` (current mastery scores, bands)
13. `public.growth_events` (Growth engine calculation inputs and outputs)
14. `public.xp_ledger` (immutable Study XP transaction ledger)
15. `public.rp_ledger` (immutable Reward Point transaction ledger)
16. `public.child_balances` (cached balance projections)
17. `public.reward_redemptions` (redemption claims, status)
18. `public.wheel_spins` (immutable wheel spin outcomes)
19. `public.command_receipts` (idempotency audit logs)
20. Storage bucket `assessment-evidence` (object paths `{family_id}/{child_id}/{assessment_id}/{evidence_id}.jpg`)

#### 4.3.2 RLS Limitations & Read-Boundary Hardening
Existing RLS policies across the codebase (`assessments_select`, `verified_learning_events_select`, `growth_events_select`, `child_mastery_states_select`, `child_balances_select`) evaluate access using:
```sql
exists (
  select 1 from public.family_memberships fm
  where fm.family_id = assessments.family_id
    and fm.user_id = auth.uid()
    and fm.status = 'active'
)
```
**Architectural Flaw in Naive Archival:** Setting `child_profiles.status = 'archived'` does **NOT** filter these tables, meaning archived children's assessments and mastery remain visible to family adults under current policies.

**Phase 6 RLS Policy Updates:**
1. Introduce a fast, cached security helper:
   ```sql
   create or replace function private.is_child_active_in_family(p_child_id uuid, p_family_id uuid)
   returns boolean
   language sql
   stable
   security definer
   set search_path = ''
   as $$
     select exists (
       select 1 from public.child_profiles cp
       where cp.id = p_child_id
         and cp.family_id = p_family_id
         and cp.status = 'active'
     );
   $$;
   ```
2. Refactor child-scoped RLS SELECT policies on client-facing tables:
   - `child_profiles_select`: Adults can view active children in standard views; archived children require an explicit archive filter. Paired child devices can only query active profiles matching their own `child_id`.
   - `assessments_select`, `child_mastery_states_select`, `child_balances_select`, `reward_redemptions_select`: Enforce `private.is_child_active_in_family(table.child_id, table.family_id)` for normal application sessions.

#### 4.3.3 Right-to-Erasure Resolution: Conceptual Distinctions & Lawful Basis
To respect parental privacy requests without violating immutable ledger integrity, Phase 6 defines an explicit four-tier lifecycle:
1. **Access Revocation:** Child device grants are immediately marked `'revoked'`. Active sessions cannot access child data.
2. **Soft Deletion / Archival:** `child_profiles.status` transitions to `'archived'`. The child is removed from daily learning flows, recommendations, and active parent dashboards.
3. **Irreversible Anonymization:** Personal identifying fields in `child_profiles` are scrubbed: `display_name = 'Archived Learner'`, `avatar_key = null`, `school_grade = null`, `birth_year = null`. Review notes on assessments are cleared.
4. **Physical Deletion:** All photographic evidence in Storage bucket `assessment-evidence` under path `{family_id}/{child_id}/` is permanently deleted. Draft assessments not yet finalized are purged.

*Lawful Retention Basis:*
Immutable ledgers (`xp_ledger`, `rp_ledger`, `verified_learning_events`) cannot be deleted due to `LW102` database triggers and audit obligations. Once direct identifiers are severed and evidence photos deleted, retaining pseudonymous numerical records is lawfully justified under legitimate interests / legal compliance exemptions for audit trail integrity and dispute resolution.

#### 4.3.4 Hardened Family Data Portability RPC
Before requesting child or family archival, parents can retrieve an export of their family's learning records:
```sql
create or replace function public.export_family_data_json(p_family_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_role text;
  v_export jsonb;
begin
  -- 1. Verify caller is an active adult in the specified family
  select role into v_caller_role
  from public.family_memberships
  where family_id = p_family_id
    and user_id = auth.uid()
    and status = 'active';

  if v_caller_role is null or v_caller_role not in ('owner', 'parent') then
    raise exception 'Unauthorized to export family data' using errcode = '42501';
  end if;

  -- 2. Build structured export with strict field allowlists (omitting salts, PIN hashes, tokens)
  select jsonb_build_object(
    'family', (
      select jsonb_build_object('id', id, 'name', name, 'created_at', created_at)
      from public.families where id = p_family_id
    ),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'display_name', display_name, 'school_grade', school_grade,
        'birth_year', birth_year, 'status', status, 'created_at', created_at
      ))
      from public.child_profiles where family_id = p_family_id
    ), '[]'::jsonb),
    'assessments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'child_id', child_id, 'title', title, 'subject_key', subject_key,
        'assessment_type', assessment_type, 'raw_score', raw_score, 'max_score', max_score,
        'normalized_score', normalized_score, 'status', status, 'occurred_at', occurred_at
      ))
      from public.assessments where family_id = p_family_id and status != 'draft'
    ), '[]'::jsonb),
    'mastery', coalesce((
      select jsonb_agg(jsonb_build_object(
        'child_id', child_id, 'learning_node_id', learning_node_id,
        'mastery_score', mastery_score, 'mastery_band', mastery_band
      ))
      from public.child_mastery_states where family_id = p_family_id
    ), '[]'::jsonb),
    'xp_ledger', coalesce((
      select jsonb_agg(jsonb_build_object(
        'child_id', child_id, 'amount', amount, 'reason', reason, 'created_at', created_at
      ))
      from public.xp_ledger where family_id = p_family_id
    ), '[]'::jsonb),
    'rp_ledger', coalesce((
      select jsonb_agg(jsonb_build_object(
        'child_id', child_id, 'amount_minor', amount_minor, 'reason', reason, 'created_at', created_at
      ))
      from public.rp_ledger where family_id = p_family_id
    ), '[]'::jsonb)
  ) into v_export;

  return v_export;
end;
$$;

-- Revoke default public execution privileges
revoke execute on function public.export_family_data_json(uuid) from public, anon;
grant execute on function public.export_family_data_json(uuid) to authenticated;
```

---

## 5. Phase 6.3 — Accessibility, Reduced-Motion Wheel & Release Operations

### 5.1 Accessibility & Semantics Implementation
1. **Screen Reader Semantics:**
   - Every custom card, progress bar, mastery chip, and wheel section is wrapped with `Semantics(label: '...', button: true/false)`.
   - Screen reader live announcements (`SemanticsService.announce(message, TextDirection.ltr)`) announce critical events:
     - *"Assessment submitted for parent review"*;
     - *"Wheel spin complete: Won 30 minutes extra screen time"*;
     - *"Reward redeemed: Pending parent fulfillment"*.
2. **Touch Targets:**
   - All interactive touch targets throughout `apps/mobile` are audited and enforced to meet minimum $48 \times 48\text{ dp}$ bounding boxes using `InputDecorationTheme`, `IconButton.padding`, and Material `minTargetSize`.
3. **Dynamic Type Font Scaling:**
   - Fixed-height containers (`SizedBox(height: 48)`) enclosing multiline text or labels are refactored to use `ConstrainedBox(minHeight: 48)` and flexible column layouts to prevent overflow crashes when system font size is set to 200%.
4. **Mastery Visual Accessibility:**
   - Mastery badges (`mastered`, `secure`, `developing`, `emerging`) and freshness states (`recent`, `aging`, `needs_refresh`) combine distinct text labels, high-contrast border outlines, and iconic glyphs so information is never conveyed by color alone.

### 5.2 Reduced-Motion Celebration Wheel Safety
`ChildWheelScreen` provides vestibular safety while preserving the core non-compulsion invariant:
1. **Detection:** When `MediaQuery.disableAnimationsOf(context)` is true or system reduced-motion is enabled:
   - The 4-second rotating physics animation is completely bypassed.
   - The screen renders an instantaneous, celebratory reveal dialog / card displaying the outcome.
2. **Invariance Guarantee:**
   - Reduced-motion mode executes the **exact same** server-authoritative RPC (`public.spin_reward_wheel`).
   - Consumes the **exact same** configured RP cost.
   - Debits the **exact same** daily spin cap.
   - Evaluates the **exact same** server-authoritative pseudorandom tier selection.
   - Grants the **exact same** positive, non-losing reward.
   - Under no circumstances does an accessibility setting alter random tier probabilities or reward outcomes.

### 5.3 Mobile Release Distribution
1. **Application Identifiers:**
   - Android: `applicationId = "com.learnward.app"` (`apps/mobile/android/app/build.gradle.kts`)
   - iOS: `CFBundleIdentifier = "com.learnward.app"` (`apps/mobile/ios/Runner/Info.plist`)
2. **Version & Build Numbering:**
   - Managed centrally in `apps/mobile/pubspec.yaml` (`version: 0.1.0+1`).
3. **Android Release Packaging:**
   - Keystore injection via environment variables (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`) in GitHub Actions.
   - Generates release Android App Bundle (AAB): `flutter build appbundle --release --dart-define-from-file=dart_defines.json`.
4. **iOS TestFlight Packaging:**
   - Distribution certificate and provisioning profile handling.
   - Generates signed release IPA archive: `flutter build ipa --release --dart-define-from-file=dart_defines.json`.
5. **Distribution Track:**
   - Manual upload of signed AAB to Google Play Console Internal Testing track and IPA to Apple TestFlight satisfies the pilot gate.
   - Automated deployment service accounts (Google Play API / App Store Connect API keys) remain optional engineering conveniences.

### 5.4 Operational Diagnostics & Pilot Support
1. **Support Diagnostics Screen:** Accessible to parents under Family Settings $\to$ "Support & Diagnostics":
   - App version and build number (`0.1.0+1`);
   - Commit SHA;
   - Active environment (`APP_ENV = staging | production`);
   - Local database version (`schemaVersion = 5`);
   - Pending outbox command count and unsent draft count;
   - Non-sensitive diagnostic correlation ID for parent bug reports.
2. **Redacted Structured Logging:**
   - Structured logs output timestamp, log level, correlation ID, and message.
   - Zero logging of child real names, parent emails, auth tokens, or photo bytes.

---

## 6. Frozen-Contract Regression Obligations

Phase 6 touches cross-cutting concerns (offline persistence, security, UI, distribution). It is strictly bound to preserve all sealed contracts established in Phases 1–5:

| Phase | Contract Domain | Frozen Authority | Invariant Guarantee in Phase 6 |
|---|---|---|---|
| **Phase 1** | Tenancy & Identity | [ADR 0002](adr/0002-phase-1-family-child-identity.md) | Family boundary strictly enforced (`42501`). Shared-device Child Mode lock survives app kill. |
| **Phase 2** | Assessment Capture | [ADR 0003](adr/0003-phase-2-secure-assessment-capture.md) | Generated score normalization; terminal locking on `verified`/`rejected`. Trigger `trg_prevent_assessment_review_event_mutation`. |
| **Phase 3** | Growth Engine & Ledgers | [ADR 0004](adr/0004-phase-3-growth-engine-ledger.md) | Integer minor units; append-only `xp_ledger` & `rp_ledger`; single-snapshot reconciliation; Growth idempotency. |
| **Phase 4** | Reward Store & Wheel | [ADR 0005](adr/0005-phase-4-reward-economy-wheel.md) | Server-authoritative RPCs; non-losing spins; calendar day spin caps; trigger `trg_enforce_wheel_spins_immutability`. |
| **Phase 5.1**| Mastery & Confidence | [ADR 0006](adr/0006-phase-5-learning-engine-mastery.md) | Deterministic EWMA rebuild; rolling 60-day confidence window; sticky `mastery_attained_at`. |
| **Phase 5.2**| Skill Graph & Recs | [ADR 0007](adr/0007-phase-5-2-skill-graph-recommendation.md) | Read-time projections; five-class priority partition (`recovery > refresh > developing > unlock > explore`); max 3 choices. |

---

## 7. Test Strategy & Acceptance Matrix

### 7.1 Automated Test Suites
1. **Pure Dart Domain Tests (`packages/learnward_domain`):**
   - Verify outbox state machines, retry policies, and telemetry envelope validation.
   - Preserve 196 existing domain tests, including 61 Phase 5.2 parity cases and 13 Phase 5.1 parity cases.
2. **Application Use Case Tests (`packages/learnward_application`):**
   - Outbox queue dispatching, actor identity verification, notification routing.
3. **Data Infrastructure Tests (`packages/learnward_data`):**
   - Drift schema v4 $\to$ v5 migration tests covering populated databases with drafts and pending commands; file-backed SQLite restart recovery tests for outbox queues.
4. **Design System & Widget Tests (`apps/mobile`):**
   - Semantics widget tree verification; minimum touch target size checks ($48 \times 48\text{ dp}$); dynamic type font scaling tests (200% scaling); reduced-motion instant wheel reveal tests.
5. **Database pgTAP Tests (`supabase/tests/database/`):**
   - Verify RLS on archived child profiles, data export RPC security, and command receipt operational retention. All 438 existing pgTAP assertions must remain green.

### 7.2 Real-Device Validation Matrix
Before rolling out builds to pilot families, the following real-device matrix must be executed:

| Test Case | Android Physical Device | iPhone Physical Device | Validation Method |
|---|---|---|---|
| Camera capture with image compression | Physical camera hardware | Physical camera hardware | Manual |
| App kill during assessment upload | Force quit in app switcher | Swipe up in app switcher | Manual + Outbox verification |
| Airplane mode draft authoring & reconnect | Offline save $\to$ reconnect | Offline save $\to$ reconnect | Manual |
| Adult logout on shared device | Verify drafts/commands purged | Verify drafts/commands purged | Manual + Automated widget |
| Screen reader navigation | TalkBack enabled | VoiceOver enabled | Manual audio audit |
| Large accessibility font (200%) | Largest font scale | Accessibility Dynamic Type | Manual visual audit |
| Reduced motion wheel spin | Remove animations enabled | Reduce Motion enabled | Manual visual audit |

---

## 8. Implementation Sequencing

1. **Phase 6.1:** Bounded Outbox, Drift Schema v5, Actor Binding, iOS Permissions, Failure/Retry UX.
2. **Phase 6.2:** In-App Coordination Notifications, Canonical VLPE Queries, 12/16 Metrics, Soft-Delete Archival.
3. **Phase 6.3:** Semantics Pass, Touch Targets, Reduced-Motion Reveal, Signed Release Packaging, Diagnostics.
4. **Pilot Deployment Gate:** Staging smoke verification, TestFlight internal build, Google Play internal track build, 4-week pilot launch.
