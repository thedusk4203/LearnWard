# LearnWard Phase 6 — Pilot Hardening Detailed Design (v0.1)

- **Target Phase:** Phase 6 — Pilot Hardening
- **Reviewed Baseline:** `main` @ `462a17e603b69456b9eb2e000cfa7a7424e0c719`
- **Associated ADR:** [ADR 0008 — Phase 6 Pilot Hardening Decisions](adr/0008-phase-6-pilot-hardening.md) (`PROPOSED`)
- **Readiness Authority:** [Phase 6 Dependency & Readiness Review](16-phase-6-pilot-hardening-dependency-readiness-review.md) (`FROZEN`)
- **Author:** LearnWard Agentic Engineering Team
- **Status:** DRAFT / PROPOSED FOR AUDIT (Implementation **NOT AUTHORIZED** until audit pass and merge)

---

## 1. Executive Summary & Design Scope

Phase 6 hardens LearnWard's mobile and backend architecture to achieve the authoritative pilot exit gate:

> **Authoritative Pilot Exit Gate:**
> *"A small family pilot can run for four consecutive weeks without engineering intervention for normal daily usage."*

Phases 1 through 5 delivered a mathematically and cryptographically verified learning engine:
1. Multi-tenant family identity, child profile management, and shared-device PIN containment (Phase 1);
2. Secure assessment draft capture, score normalization, photographic evidence attachment, and parental review (Phase 2);
3. Integer append-only Study XP and Reward Point (RP) ledgers with the single-snapshot Growth calculation engine (Phase 3);
4. Guaranteed Reward Store and non-losing Celebration Wheel with calendar-day timezone containment (Phases 4.1 & 4.2);
5. Exponentially Weighted Moving Average (EWMA) learning mastery engine with 60-day confidence decay (Phase 5.1);
6. Next Challenge candidate recommendations presenting clear, deterministic choices across recovery, refresh, developing, unlock, and explore (Phase 5.2).

Phase 6 provides the operational, reliability, resilience, accessibility, and distribution hardening required for real family pilots, divided across three sequenced implementation milestones:
- **Phase 6.1 — Offline Resilience, Bounded Outbox & Actor-Aware Command Recovery:** Durable SQLite command queues, actor identity binding, local containment lifecycle, camera permissions, evidence resumability, and failure/retry presentation.
- **Phase 6.2 — Notifications, Privacy-Preserving Telemetry & Data Retention:** In-app coordination alerts, authoritative reconciliation, canonical VLPE derivation, 12/16 metric instrumentation, right-to-erasure archival, and data portability.
- **Phase 6.3 — Accessibility, Reduced-Motion Wheel & Release Operations:** Semantics labeling, minimum touch targets, dynamic type font scaling, reduced-motion wheel safety, signed release packaging, and diagnostic observability.

---

## 2. Architecture Map & Subsystem Decomposition

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                             LEARNWARD MOBILE APP                            │
├─────────────────────────────────────────────────────────────────────────────┤
│ Presentation Layer (Riverpod + Flutter Design System)                       │
│  - Child Wheel Screen (Instant Reduced-Motion Celebration Guarantee)        │
│  - Parent & Child Accessibility Semantics, Live Announcements & Touch Target│
│  - Offline / Retry Diagnostic Cards & Actionable Error States               │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 6.1: Offline Resilience, Outbox & Actor-Aware Recovery                │
│  - Drift Schema v5 (Safe v4 Backward Compatibility, Quarantined v4 Outbox)  │
│  - Bounded Outboxes: PendingRewardCommands & LocalAssessmentDrafts          │
│  - Actor-Aware Command Binding (family_id, actor_user_id)                  │
│  - PostgreSQL 42501 Error Disambiguation & Positive Grant Revocation Proof  │
│  - Response-Lost Recovery via Authoritative Idempotent Server RPC Replays   │
│  - Deterministic Evidence Path, HTTP 409 Integrity Check, Idempotent Regis. │
│  - Platform Camera & Photo Library Permissions (iOS Info.plist)             │
│  - Adaptive Compression (Max 2048x1536, JPEG 85%, Legibility-First)         │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 6.2: Notifications, Privacy Telemetry & Data Retention                │
│  - In-App Realtime Notification Transport + Authoritative Query Reconcil.   │
│  - Abstract NotificationService Port (FCM / APNs Out of Scope)              │
│  - Canonical VLPE Derivation (Growth + Learning Dual-Processed)             │
│  - SQL-Derivable Pilot Metrics (12 of 16 in DB; Metric 4 Goals Deferred)    │
│  - Privacy-Preserving UX Telemetry Envelope (Zero PII, Scrubbed Context)    │
│  - Comprehensive 19-Table + Storage Inventory & RLS Read-Boundary Hardening │
│  - Four-Tier Erasure Lifecycle (Policy Status: UNRESOLVED / Pilot Minimize) │
│  - Schema-Verified Data Portability RPC: public.export_family_data_json     │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 6.3: Accessibility, Motion Safety & Release Operations                │
│  - Semantics Widget Tree Pass (Labels, Live Announcements, Dynamic Type)    │
│  - Bounded Touch Targets (>= 48x48 dp)                                      │
│  - Vestibular-Safe Celebration Reveal (Identical Math/RP/Cap/Tier Guarantees)│
│  - Manual Signed App Bundle (AAB) & TestFlight IPA Packaging Workflows      │
│  - Redacted Client-Side Diagnostics & Correlation ID Ingestion              │
└─────────────────────────────────────────────────────────────────────────────┘
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
   - Existing v4 rows with `actorUserId = NULL` enter `quarantined_legacy_v4`.
   - **Strict Reassignment Prohibition:** The background queue will **never** silently reassign a legacy command to whichever user happens to log in and replay it! Replaying an already-committed operation under a new actor causes server `42501: Invalid command replay` (actor mismatch), while replaying an uncommitted operation with a new command ID risks double-charging or double-submitting.
   - **Reconciliation Procedure:**
     a. An authenticated adult accesses the quarantine manager in Parent Settings.
     b. The client first inspects authoritative domain state (e.g. queries `public.reward_redemptions` for matching `child_id`, `reward_id`, and approximate timestamp; queries `public.assessments` for matching `child_id`, `title`, and `occurred_at`).
     c. If the entity already exists remotely, the local command is marked reconciled and removed from SQLite without network mutation.
     d. If confirmed absent remotely and the adult explicitly re-authorizes the action, the command is bound to the adult's identity (`actorUserId = auth.uid()`), a *new* unique `command_id` is generated, and it is submitted.
     e. If the adult rejects or cancels, the command is safely deleted from SQLite, and the client refetches balances from the server.
3. **Assessment Drafts Backfill:**
   - Pre-existing drafts retain `submissionStatus = 'draft'` and their local photo paths. When the learner or parent re-opens, edits, or submits the draft, `actorUserId` and `actorRole` are bound to the active session performing the submission.

---

### 3.3 Actor-Aware Command Recovery & Error Classification

#### 3.3.1 Error Classification & Backend SQLSTATE `42501` Disambiguation
The server returns SQLSTATE `42501 (insufficient_privilege)` across diverse authorization conditions. The client **MUST NOT** treat all `42501` errors as device revocation.

| Server Condition | Error Code / Message | Client Classification | Client Recovery Action |
|---|---|---|---|
| Replayed command submitted under different user | `42501: Command caller mismatch` or `Invalid command replay` | `CALLER_MISMATCH` | Halt replay; pause command in `pending_original_actor`; do not reassign actor |
| Device pairing grant revoked on server | `42501: Device grant revoked or inactive` | `DEVICE_REVOKED` | Confirm via dedicated `child_device_grants` query; transition to unlinked shell; retain drafts |
| Sibling device calling another child's RPC | `42501: Sibling access denied` | `CROSS_CHILD_VIOLATION` | Halt replay; mark command `terminal_error`; display boundary error |
| Non-parent attempting adult-only RPC | `42501: Parent authorization required` | `ROLE_MISMATCH` | Pause command in `pending_original_actor`; display permission notice |
| Transient network disconnect / timeout | `SocketException` / HTTP 5xx / timeout | `TRANSIENT_NETWORK` | Retain command in `active`; schedule exponential backoff retry |
| Terminal business failure (`LW202`, `LW203`, `LW206`) | `LW202: Insufficient RP`, `LW203: Daily cap` | `TERMINAL_BUSINESS_ERROR` | Purge command from journal; display friendly error; refetch balances |

#### 3.3.2 Reliable Revocation Detection Protocol
When an API request from a paired child device receives `42501`:
1. **No Speculative Revocation:** The client does **NOT** infer revocation solely from a `42501` status code, a failed SELECT, a missing row, or a network timeout.
2. **Positive Evidence Requirement:** Under the frozen `child_device_grants_select` policy, a paired-child session can always query its own grant:
   ```sql
   select id, status, revoked_at from public.child_device_grants where auth_user_id = auth.uid();
   ```
3. If and only if the server query returns an explicit row with `status = 'revoked'` AND `revoked_at IS NOT NULL`, the client confirms `DEVICE_REVOKED`.
4. If the query fails due to network disconnect, timeout, or general token expiration, the device treats it as an unknown or transient state, preserving local pending drafts and commands in an offline paused state.
5. Upon confirmed positive revocation:
   - Device credentials and active child session are cleared.
   - Child Mode is locked to an unlinked state displaying: *"Device access has been revoked by a family parent."*
   - Local drafts and pending commands are quarantined under the revoked grant ID rather than permanently deleted, allowing an adult who later signs into the hardware to review or export unsynced schoolwork.

#### 3.3.3 Authoritative Idempotent RPC Replay Contracts & Response-Lost Recovery
When an operation is dispatched but the network drops before receiving the response:
1. **RLS Read-Boundary Reality on Command Receipts:** In the frozen schema, `command_receipts_select` is restricted to active family adults (`private.is_active_family_adult(family_id)`). Paired-child devices **CANNOT** read from `public.command_receipts` (returns 0 rows under RLS). Furthermore, an absent or invisible receipt does not prove non-execution.
2. **Authoritative Idempotent Server Contract:** Every state-mutating RPC (`create_assessment_draft`, `submit_assessment`, `redeem_store_reward`, `spin_reward_wheel`) is `SECURITY DEFINER` and takes `p_command_id`. Internally, each RPC inspects `public.command_receipts`:
   - If `p_command_id` is already recorded with matching operation, family, and actor, the RPC returns the existing committed entity idempotently without side effects.
   - If `p_command_id` was not committed, the RPC executes normally and commits.
3. **Safe Recovery Protocol Across Actor Classes:**
   - **Adult Actors:** May query domain tables (`assessments`, `reward_redemptions`, `wheel_spins`) or call the idempotent RPC with original `command_id`.
   - **Shared-Child Actors:** Commands bound to specific `actor_user_id`; replayed via the idempotent RPC under that actor.
   - **Paired-Child Actors:** Recover exclusively by re-invoking the idempotent RPC with original `command_id` or querying child-accessible domain tables (`public.assessments` where `child_id = currentChildId`).
4. **Replay Invariant:** Replays must always execute under the original `actor_user_id`. Replaying under a different actor causes server rejection with `42501: Invalid command replay` (actor mismatch).

#### 3.3.4 Multi-Actor Session Recovery (`pending_original_actor`)
On a shared family device:
1. Adult A queues a reward fulfillment command (`C1`). Network times out.
2. Adult A logs out. Adult B (co-parent) logs in.
3. Background command processor inspects `C1.actorUserId`. Since `C1.actorUserId != Adult_B.uid`, execution is **halted**.
4. Command `C1` is assigned `recoveryState = 'pending_original_actor'`.
5. Command `C1` is **preserved in SQLite** without data loss. It is not deleted and not replayed under Adult B.
6. When Adult A logs back in, `C1` transitions back to `'active'` and replays safely.

---

### 3.4 Per-Data-Class Local Security & Device Containment Lifecycle

Blanket `clearAllTables()` wipe on sign-out is rejected. Local data classes are partitioned into distinct lifecycles:

| Data Class | Local Storage Medium | User Sign-Out | Family Switch | Child Mode Exit | Paired Child Revoked | Account Deletion |
|---|---|---|---|---|---|---|
| **Parent PIN Hash & Salt** | `local_metadata_entries` | **Retained** (device security) | **Retained** | **Purged** | **Retained** | **Purged** |
| **Active Child Session** | `local_metadata_entries` | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** |
| **Assessment Drafts** | `local_assessment_drafts` | **Retained** (if same family) | **Retained** | **Purged** | **Quarantined** | **Purged** |
| **Pending Reward Commands** | `pending_reward_commands`| **Paused** (`pending_actor`) | **Paused** | **Purged** | **Quarantined** | **Purged** |
| **Local Evidence Photos** | App Documents Dir | **Retained** (pending draft) | **Retained** | **Purged** | **Quarantined** | **Purged** |
| **Cached Read Models** | SQLite Read Tables | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** |

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
  - Target Payload Size: $\le 1.5\text{ MB}$ (treated as an adaptive engineering target, not a hard-fail rejection cap);
  - If output exceeds $1.5\text{ MB}$, the compressor evaluates whether compression to 75% preserves contrast. If size remains between $1.5\text{ MB}$ and $2.5\text{ MB}$, the file is accepted as-is to prevent legibility degradation.
  - Image processing operates on byte buffers in memory or temporary files, never blocking the UI isolate.

#### 3.5.3 Resumable Storage Protocol via Supabase Dart Storage SDK
LearnWard uses `supabase_flutter: ^2.18.3` and `supabase: ^2.16.5` (`storage_client`). AWS S3 methods (`headBucket`, `getObject`) are not supported.
- **Deterministic Storage Path:** `{family_id}/{child_id}/{assessment_id}/{client_evidence_uuid}.jpg` matching regex:
  `^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png)$`
- **Mapping Deterministic Client UUID to Database PK:**
  - Table `public.assessment_evidence` has primary key `id` (UUID) and unique `storage_path` (text). There is **no** `evidence_id` column.
  - The client maps its deterministic `client_evidence_uuid` to the database record via `storage_path`.
- **Upload & Resumption Protocol:**
  1. Client checks if the object already exists remotely by listing the assessment folder:
     ```dart
     final files = await supabase.storage
         .from('assessment-evidence')
         .list(path: '$familyId/$childId/$assessmentId');
     final existing = files.where((f) => f.name == '$clientEvidenceUuid.jpg').firstOrNull;
     ```
  2. If file exists and `metadata['size'] == compressedBytes.length`:
     - File upload already completed. Proceed directly to `register_assessment_evidence` RPC.
  3. If file does not exist or size differs:
     - Upload binary data:
       ```dart
       await supabase.storage.from('assessment-evidence').uploadBinary(
         storagePath,
         compressedBytes,
         fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false),
       );
       ```
  4. If upload returns HTTP 409 Conflict:
     - Do **not** blindly treat 409 as success.
     - Query `list(path: ...)` to verify the remote file exists and verify that its byte size matches `compressedBytes.length` (non-zero). If size is corrupted or 0 bytes, flag as upload failure for retry.
  5. Authoritative Database Registration:
     - Invoke frozen idempotent RPC:
       ```dart
       final response = await supabase.rpc('register_assessment_evidence', params: {
         'p_assessment_id': assessmentId,
         'p_storage_path': storagePath,
         'p_media_type': 'image/jpeg',
         'p_file_size_bytes': compressedBytes.length,
       });
       ```
     - Capture returned `public.assessment_evidence.id` (database UUID) into `LocalAssessmentDrafts.serverEvidenceId`.

---

### 3.6 Failure & Retry Presentation Primitives
The design system introduces standard user-facing error and retry components in `packages/learnward_design_system`:
- `AppErrorStateWidget`: Standard card rendering user-friendly explanation, recovery guidance, and a primary retry button.
- `AppOfflineBanner`: Non-intrusive persistent status bar appearing when network is lost, indicating that work is saved locally.
- `RetryActionCard`: Dedicated card rendered in inbox and history screens for pending/recovering transactions.
- **Error Mapping Rule:** Raw database exceptions (`PostgrestException`, `SocketException`, `HttpException`, `LW...` database error codes) must never be displayed raw to users. All errors pass through `DomainErrorMapper.toUserFriendlyMessage(error)`.

---

## 4. Phase 6.2 — Notifications, Privacy-Preserving Telemetry & Data Retention

### 4.1 In-App Coordination Notifications & Abstract Service Port

#### 4.1.1 Anti-Compulsion Boundary Rules
In accordance with LearnWard core philosophy, notification triggers are strictly bounded:
- **Allowed Triggers:**
  - Assessment submitted for parent review;
  - Parent verified or rejected assessment;
  - Child redeemed a reward requiring parent fulfillment;
  - Parent marked reward fulfilled.
- **Prohibited Triggers (Hard Architecture Block):**
  - Daily streak warnings or broken streak shaming;
  - Inactivity reminders or time-decay nag notifications;
  - Sibling comparison or leaderboard alerts;
  - Unsolicited promotional or store teasers.

#### 4.1.2 Transport & Authoritative Reconnect Reconciliation
- **Realtime WebSocket Transport:** Ephemeral transport via Supabase Realtime channel `family_notifications:{family_id}`.
- **Authoritative Reconciliation Guarantee:** Because Realtime connections are transient (app backgrounding, sleep, poor connectivity), parent inbox counters and child review badges must **never** rely exclusively on Realtime events. On app launch, resume from background, and WebSocket reconnect, the app queries authoritative tables (`assessments` with `status = 'pending_review'`, `reward_redemptions` with `status = 'pending_fulfillment'`).
- **Abstract Service Port:** Application logic interacts solely through `NotificationService`:
  ```dart
  abstract class NotificationService {
    Stream<FamilyCoordinationEvent> get coordinationEvents;
    Future<void> initialize();
    Future<void> markRead(String eventId);
  }
  ```

---

### 4.2 Canonical VLPE Derivation & Privacy Telemetry Envelope

#### 4.2.1 Canonical Definition of Verified Learning Progress Event (VLPE)
The North Star metric **VLPE** is canonically defined as:
> *A verified assessment event that has completed both Growth Engine processing (`public.growth_events`) and Learning Mastery processing (`public.learning_processing_events` with `status = 'processed'`).*

```sql
select count(distinct vle.id) as canonical_vlpe_count
from public.verified_learning_events vle
join public.growth_events ge on ge.verified_learning_event_id = vle.id
join public.learning_processing_events lpe on lpe.verified_learning_event_id = vle.id
where lpe.status = 'processed'
  and vle.family_id = :family_id;
```

#### 4.2.2 Exact 12/16 Pilot Metric Derivation Matrix
Exactly 12 of the 16 pilot metrics are directly derivable from PostgreSQL without external analytics SDKs:

1. **Active pilot families:** Active count in `public.families` with verified activity in window:
   `select count(distinct family_id) from public.verified_learning_events where verified_at >= :start;`
2. **Weekly VLPE count:** Canonical VLPE query aggregated per 7-day calendar window.
3. **Assessment verification turnaround:** Median duration between submission and verification:
   `percentile_cont(0.5) within group (order by extract(epoch from (vle.verified_at - a.occurred_at)) / 3600);`
4. **Reward store redemption rate:** Count of `reward_redemptions` where `origin = 'store'` over time.
5. **Wheel spin engagement:** Count of `wheel_spins` per active child per calendar week.
6. **Personal-best frequency:** Filtered aggregate over authoritative Growth awards:
   `select count(*) from public.growth_events where personal_best_rp_minor > 0;`
7. **Mastery score trajectory:** Mean and trend of `child_mastery_states.mastery_score` per node over time.
8. **Recommendation acceptance rate:** Ratio of recommended nodes selected in next assessment.
9. **Parent verification fidelity:** Percentage of pending assessments reviewed vs. auto-expired.
10. **Evidence attachment percentage:** Percentage of submitted assessments with `evidence_count > 0`.
11. **RP balance circulation:** Ratio of total RP earned vs. total RP redeemed in `rp_ledger`.
12. **Study XP total progression:** Aggregate XP growth in `xp_ledger`.

*(Note: Metric 4 "% goals chosen by child" remains DEFERRED. No Goals subsystem is authorized for Phase 6).*

#### 4.2.3 Privacy-Preserving UX Telemetry Envelope
Telemetry events sent from mobile use an audited envelope strictly scrubbed of PII:
```json
{
  "event_id": "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d",
  "client_timestamp": "2026-11-04T12:00:00Z",
  "event_name": "screen_view",
  "session_id": "a3b2c1...",
  "actor_role": "child",
  "app_version": "1.0.0",
  "platform": "ios",
  "properties": {
    "screen": "child_wheel",
    "theme": "space",
    "network_type": "wifi"
  }
}
```
**Strict Prohibition:** Child real names, parent emails, school names, geographic location coordinates, camera images, or auth JWTs are strictly prohibited in telemetry payloads.

---

### 4.3 Data Retention, Archival & Right-to-Erasure Architecture

#### 4.3.1 Inventory of Child-Linked Tables & Storage Assets
The LearnWard backend manages 20 relational tables and 1 Storage bucket containing child-associated data across Phases 1 through 5:
1. `public.child_profiles` (identifying metadata: display name, grade, birth year, avatar)
2. `public.child_device_grants` (device auth records, pairing status)
3. `private.child_pairing_requests` (ephemeral pairing codes)
4. `public.assessments` (raw scores, titles, context)
5. `public.assessment_evidence` (storage references, file sizes)
6. `public.assessment_review_events` (review audit logs, parent review notes)
7. `public.assessment_learning_mappings` (catalog node mappings)
8. `public.verified_learning_events` (immutable academic event records)
9. `public.learning_evidence_events` (immutable mastery evidence atoms)
10. `public.learning_processing_events` (processing audit status)
11. `public.mastery_state_revisions` (immutable EWMA snapshots)
12. `public.child_mastery_states` (current mastery scores)
13. `public.growth_events` (Growth engine calculation inputs and outputs)
14. `public.xp_ledger` (immutable Study XP transaction ledger)
15. `public.rp_ledger` (immutable Reward Point transaction ledger)
16. `public.child_balances` (cached balance projections)
17. `public.rewards` (`target_child_id` nullable foreign key)
18. `public.reward_redemptions` (redemption claims, status)
19. `public.wheel_spins` (immutable wheel spin outcomes)
20. `public.command_receipts` (idempotency audit logs)
21. Storage bucket `assessment-evidence` (object paths `{family_id}/{child_id}/{assessment_id}/{client_evidence_uuid}.jpg`)

#### 4.3.2 RLS Read-Boundary Hardening for Archived Child Profiles
Existing RLS policies across the codebase (`assessments_select`, `verified_learning_events_select`, `growth_events_select`, `child_mastery_states_select`, `child_balances_select`) evaluate access using:
```sql
exists (
  select 1 from public.family_memberships fm
  where fm.family_id = table.family_id
    and fm.auth_user_id = auth.uid()
    and fm.status = 'active'
)
```
**Architectural Flaw in Naive Archival:** Setting `child_profiles.status = 'archived'` does **NOT** filter these tables, meaning archived children's assessments and mastery remain visible to family adults under current policies.

**Phase 6 RLS Policy Updates:**
1. Introduce a fast security helper:
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
   - `child_profiles_select`: Adults view active children by default; archived children require an explicit archive filter. Paired child devices only query active profiles matching their own `child_id`.
   - `assessments_select`, `child_mastery_states_select`, `child_balances_select`, `reward_redemptions_select`, `wheel_spins_select`, `xp_ledger_select`, `rp_ledger_select`: Enforce `private.is_child_active_in_family(table.child_id, table.family_id)` for normal application sessions.

#### 4.3.3 Right-to-Erasure Resolution, Policy Status & Technical Constraints
- **Policy & Legal Validation Status:**
  > **STATUS: UNRESOLVED — REQUIRES FORMAL LEGAL & POLICY VALIDATION PRIOR TO GENERAL COMMERCIAL AVAILABILITY.**
  > Retaining child-linked immutable ledger rows (`xp_ledger`, `rp_ledger`, `verified_learning_events`), even with direct names removed, does not automatically guarantee statutory anonymization or legitimate-interest retention under GDPR / COPPA / CCPA. Remaining UUID relationships, timestamps, assessment titles, and review notes can still enable re-identification.
- **Operational Pilot Data Minimization Policy (4-Week Pilot Scope):**
  For the closed family pilot, LearnWard implements a strict four-tier operational minimization lifecycle:
  1. **Tier 1 (Access Revocation):** Child device grants are immediately marked `'revoked'`. Active sessions cannot access child data.
  2. **Tier 2 (Soft Deletion & RLS Exclusion):** `child_profiles.status` transitions to `'archived'`. The child is excluded from daily learning flows, recommendations, and active parent dashboards via RLS.
  3. **Tier 3 (Child Profile Pseudonymization):** Identifying fields in `child_profiles` are scrubbed: `display_name = 'Archived Learner'`, `avatar_key = null`, `school_grade = null`, `birth_year = null`.
  4. **Tier 4 (Evidence Storage Purging):** All photographic evidence in Storage bucket `assessment-evidence` under path `{family_id}/{child_id}/` is permanently deleted. Draft assessments not yet finalized are purged.
- **Technical Constraint on Review Notes:** `assessment_review_events` is protected by the immutable trigger `trg_prevent_assessment_review_event_mutation`, which prohibits UPDATE or DELETE of `review_notes`. Modifying historical review notes in-place would violate this frozen trigger. For Phase 6, access to historical review events for archived children is severed at the RLS read boundary.

#### 4.3.4 Schema-Verified Family Data Portability RPC
Before requesting child or family archival, parents can retrieve a structured JSON export of their family's learning records.
Every table, column, join, and authorization predicate in this function is **strictly verified against frozen migrations (Phases 1–5)**:

```sql
create or replace function public.export_family_data_json(p_family_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_export jsonb;
begin
  -- 1. Authorization check: caller must be an active adult/owner in the target family
  if not private.is_active_family_adult(p_family_id) then
    raise exception 'Unauthorized to export family data' using errcode = '42501';
  end if;

  -- 2. Construct structured export payload using strictly verified columns
  select jsonb_build_object(
    'export_version', 1,
    'exported_at', now(),
    'family', (
      select jsonb_build_object(
        'id', id,
        'name', name,
        'timezone', timezone,
        'locale', locale,
        'created_at', created_at,
        'archived_at', archived_at
      )
      from public.families
      where id = p_family_id
    ),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'display_name', display_name,
        'school_grade', school_grade,
        'birth_year', birth_year,
        'avatar_key', avatar_key,
        'status', status,
        'created_at', created_at,
        'archived_at', archived_at
      ) order by created_at)
      from public.child_profiles
      where family_id = p_family_id
    ), '[]'::jsonb),
    'child_balances', coalesce((
      select jsonb_agg(jsonb_build_object(
        'child_id', child_id,
        'xp_total', xp_total,
        'rp_balance_minor', rp_balance_minor,
        'updated_at', updated_at
      ) order by child_id)
      from public.child_balances
      where family_id = p_family_id
    ), '[]'::jsonb),
    'assessments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'subject_key', subject_key,
        'subject', subject,
        'title', title,
        'assessment_type', assessment_type,
        'difficulty', difficulty,
        'raw_score', raw_score,
        'max_score', max_score,
        'normalized_score', normalized_score,
        'entry_context', entry_context,
        'status', status,
        'occurred_at', occurred_at,
        'version', version,
        'created_at', created_at
      ) order by occurred_at)
      from public.assessments
      where family_id = p_family_id and status != 'draft'
    ), '[]'::jsonb),
    'assessment_evidence', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'assessment_id', assessment_id,
        'storage_path', storage_path,
        'media_type', media_type,
        'file_size_bytes', file_size_bytes,
        'created_at', created_at
      ) order by created_at)
      from public.assessment_evidence
      where family_id = p_family_id
    ), '[]'::jsonb),
    'verified_learning_events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'assessment_id', assessment_id,
        'subject_key', subject_key,
        'subject', subject,
        'title', title,
        'assessment_type', assessment_type,
        'difficulty', difficulty,
        'raw_score', raw_score,
        'max_score', max_score,
        'normalized_score', normalized_score,
        'evidence_count', evidence_count,
        'entry_context', entry_context,
        'occurred_at', occurred_at,
        'verified_at', verified_at
      ) order by occurred_at)
      from public.verified_learning_events
      where family_id = p_family_id
    ), '[]'::jsonb),
    'mastery_states', coalesce((
      select jsonb_agg(jsonb_build_object(
        'child_id', child_id,
        'learning_node_id', learning_node_id,
        'engine_version', engine_version,
        'mastery_score', mastery_score,
        'effective_evidence_count', effective_evidence_count,
        'distinct_assessment_count', distinct_assessment_count,
        'last_evidence_occurred_at', last_evidence_occurred_at,
        'last_verified_at', last_verified_at,
        'mastery_attained_at', mastery_attained_at,
        'updated_at', updated_at
      ) order by child_id, learning_node_id)
      from public.child_mastery_states
      where family_id = p_family_id
    ), '[]'::jsonb),
    'growth_events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'assessment_id', assessment_id,
        'normalized_score', normalized_score,
        'baseline_score', baseline_score,
        'growth_delta', growth_delta,
        'historical_best', historical_best,
        'total_rp_minor', total_rp_minor,
        'xp_awarded', xp_awarded,
        'created_at', created_at
      ) order by created_at)
      from public.growth_events
      where family_id = p_family_id
    ), '[]'::jsonb),
    'xp_ledger', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'amount', amount,
        'reason_code', reason_code,
        'source_type', source_type,
        'source_id', source_id,
        'created_at', created_at
      ) order by created_at)
      from public.xp_ledger
      where family_id = p_family_id
    ), '[]'::jsonb),
    'rp_ledger', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'amount_minor', amount_minor,
        'reason_code', reason_code,
        'source_type', source_type,
        'source_id', source_id,
        'created_at', created_at
      ) order by created_at)
      from public.rp_ledger
      where family_id = p_family_id
    ), '[]'::jsonb),
    'reward_redemptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'reward_id', reward_id,
        'origin', origin,
        'rp_cost_minor', rp_cost_minor,
        'status', status,
        'reward_snapshot', reward_snapshot,
        'cancellation_reason', cancellation_reason,
        'fulfilled_at', fulfilled_at,
        'created_at', created_at
      ) order by created_at)
      from public.reward_redemptions
      where family_id = p_family_id
    ), '[]'::jsonb),
    'wheel_spins', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id,
        'child_id', child_id,
        'reward_id', reward_id,
        'redemption_id', redemption_id,
        'origin', origin,
        'spin_cost_minor', spin_cost_minor,
        'selection_snapshot', selection_snapshot,
        'created_at', created_at
      ) order by created_at)
      from public.wheel_spins
      where family_id = p_family_id
    ), '[]'::jsonb)
  ) into v_export;

  return v_export;
end;
$$;

-- Revoke public privileges; allow authenticated execution
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
   - The 4-second physical wheel spinning animation is completely bypassed.
   - An instantaneous celebratory reveal card appears with the winning slice and reward title.
2. **Identical Server Invariants:**
   - Both animated and reduced-motion paths invoke the exact same server RPC `public.spin_reward_wheel(p_command_id, p_child_id)`.
   - Both evaluate the exact same server-authoritative pseudorandom tier selection.
   - Both debit the exact same RP cost (`spin_cost_minor`).
   - Both consume the exact same daily spin cap.
   - Both guarantee the exact same positive reward outcome.

---

### 5.3 Release Operations & Distribution Packaging

#### 5.3.1 Application ID & Metadata Pinning
- Android Application ID: `com.learnward.app`
- iOS Bundle Identifier: `com.learnward.app`
- Version Format: Semantic versioning `1.0.0+1` (Version Name + Build Number).

#### 5.3.2 Manual Signed Release Artifact Distribution
Manual distribution workflows satisfy the 4-week pilot exit gate without requiring automated cloud CI deployment secrets:
- **Android Release:**
  - Build command: `flutter build appbundle --release`
  - Signed with upload keystore specified via `key.properties`.
  - Manually uploaded to Google Play Console: **Internal Testing Track**.
- **iOS Release:**
  - Build command: `flutter build ipa --release`
  - Signed with Apple Distribution Certificate & App Store Provisioning Profile.
  - Manually uploaded to Apple App Store Connect: **TestFlight Internal Testing**.

#### 5.3.3 Client Diagnostics & Redacted Logging
1. **Parent Diagnostics Screen:**
   - Hidden diagnostic screen accessible by tapping version string 5 times in Parent Settings:
   - Displays device OS, Flutter SDK version;
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

### Static Schema-Contract Validation Obligation
Every detailed design, ADR, or implementation specification that references database tables, column names, constraints, RPC signatures, or RLS policies **must** be statically verified against the authoritative schema definitions in `supabase/migrations/` before submission. Proposing speculative, unverified, or renamed SQL identifiers is strictly prohibited.

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
