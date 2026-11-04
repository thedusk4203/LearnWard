# LearnWard Phase 6 — Pilot Hardening Detailed Design (v0.1)

- **Target Phase:** Phase 6 — Pilot Hardening
- **Reviewed Baseline:** `main` @ `462a17e603b69456b9eb2e000cfa7a7424e0c719`
- **Associated ADR:** [ADR 0008 — Phase 6 Pilot Hardening Decisions](adr/0008-phase-6-pilot-hardening.md) (`PROPOSED`)
- **Readiness Authority:** [Phase 6 Dependency & Readiness Review](16-phase-6-pilot-hardening-dependency-readiness-review.md) (`FROZEN`)
- **Metrics Contract:** [Metrics & Hypotheses v0.1](06-metrics-and-hypotheses.md) (`FROZEN`)
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
- **Phase 6.1 — Offline Resilience, Bounded Outbox & Actor-Aware Command Recovery:** Durable SQLite command journals, actor identity binding, local containment lifecycle, camera permissions, evidence resumability with content-integrity conflict policies, and failure/retry presentation.
- **Phase 6.2 — Notifications, Privacy-Preserving Telemetry & Data Retention:** In-app coordination alerts, authoritative reconciliation, canonical VLPE derivation, restored authoritative 16-metric contract (12 derivable, 4 deferred), right-to-erasure archival with comprehensive RLS policy refactoring, and schema-verified data portability.
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
│  - Drift Schema v5 (Safe v4 Backward Compatibility, serverEvidenceId, Hash) │
│  - Bounded Outboxes: PendingRewardCommands & LocalAssessmentDrafts          │
│  - Actor-Aware Command Binding (family_id, actor_user_id)                  │
│  - PostgreSQL 42501 Error Disambiguation & Positive Grant Revocation Proof  │
│  - Provably Safe Recovery: Preserved Command IDs & Server RPC Replays       │
│  - Evidence Resumption: SHA-256 Content Equality & Safe 409 Conflict Policy │
│  - Platform Camera & Photo Library Permissions (iOS Info.plist)             │
│  - Adaptive Compression (Max 2048x1536, JPEG 85%, Legibility-First)         │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 6.2: Notifications, Privacy Telemetry & Data Retention                │
│  - In-App Realtime Notification Transport + Authoritative Query Reconcil.   │
│  - NotificationService Port (Transient Badges, markRead Omitted for Pilot)  │
│  - Canonical VLPE Derivation (Growth + Learning Dual-Processed / Child / Wk)│
│  - Authoritative 16-Metric Contract Restored (12 DB-Derivable, 4 Deferred)  │
│  - Privacy-Preserving UX Telemetry Envelope (Zero PII, Scrubbed Context)    │
│  - Complete 20-Table + Storage Inventory & Full RLS Read-Boundary Overhaul  │
│  - Four-Tier Erasure Lifecycle (Legal/Privacy Review Required Pre-Pilot)    │
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
2. **Assessment Capture & Submission:** Extended `local_assessment_drafts` table managing the draft lifecycle, stable local image caching, and background submission retry.
3. **Read Models:** Stale-while-revalidate local caching in Drift SQLite for `LearningOverview` and `NextChallengeCandidates`, allowing disconnected inspection without write queueing.

---

### 3.2 Drift Database Schema Migration (v4 $\to$ v5) & Backfill Compatibility
The local database schema (`packages/learnward_data/lib/src/database/app_database.dart`) migrates to `schemaVersion = 5`.

#### 3.2.1 Analysis of Frozen v4 Schema vs. v5 Requirements
Comparing existing v4 definitions against v5 requirements:
- In v4 `PendingRewardCommands`: `childId` is `text().nullable()()`. In v5, `childId` **MUST REMAIN NULLABLE** to prevent schema mismatches and migration failures.
- In v4 `LocalAssessmentDrafts`: `createCommandId`, `submitCommandId`, `evidenceId`, `serverAssessmentId`, and `localPhotoPath` are all `text().nullable()()`. In v5, they **MUST REMAIN NULLABLE** because drafts generate these values progressively throughout capture and submission.
- In SQLite, adding non-nullable columns without constant default values via `ALTER TABLE ADD COLUMN` is disallowed by SQLite syntax. Furthermore, assigning fabricated actor identities violates audit provenance and security invariants.
- `serverEvidenceId`, `sha256Checksum`, and `localCompressedPhotoPath` are explicitly added to `LocalAssessmentDrafts` as nullable columns to link client-generated evidence to authoritative database records and ensure reproducible content integrity across restarts.

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
  // Valid states: 'active', 'quarantined_legacy_v4', 'quarantined_unknown_outcome', 'pending_original_actor'
}

// packages/learnward_data/lib/src/database/local_assessment_drafts.dart
@DataClassName('LocalAssessmentDraftEntry')
class LocalAssessmentDrafts extends Table {
  TextColumn get localDraftId => text()();
  TextColumn get familyId => text()();
  TextColumn get childId => text()();
  TextColumn get createCommandId => text().nullable()(); // Preserved nullable from v4
  TextColumn get submitCommandId => text().nullable()(); // Preserved nullable from v4
  TextColumn get evidenceId => text().nullable()();      // Preserved nullable from v4 (holds clientEvidenceUuid)
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
  TextColumn get serverEvidenceId => text().nullable()(); // Authoritative public.assessment_evidence.id
  TextColumn get sha256Checksum => text().nullable()();   // Content hash of compressed JPEG
  TextColumn get localCompressedPhotoPath => text().nullable()(); // Path to stably compressed JPEG
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

#### 3.2.3 Provably Safe Migration & Backfill Strategy
1. **Migration Execution (`onUpgrade`):**
   ```dart
   if (from < 5) {
     await migrator.addColumn(pendingRewardCommands, pendingRewardCommands.actorUserId);
     await migrator.addColumn(pendingRewardCommands, pendingRewardCommands.actorRole);
     await migrator.addColumn(pendingRewardCommands, pendingRewardCommands.schemaVersion);
     await migrator.addColumn(pendingRewardCommands, pendingRewardCommands.recoveryState);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.serverEvidenceId);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.sha256Checksum);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.localCompressedPhotoPath);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.submissionStatus);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.retryCount);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.lastErrorMessage);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.actorUserId);
     await migrator.addColumn(localAssessmentDrafts, localAssessmentDrafts.actorRole);

     // Quarantine existing v4 pending commands without invented identities:
     await customStatement(
       "UPDATE pending_reward_commands SET recovery_state = 'quarantined_legacy_v4', schema_version = 1 WHERE actor_user_id IS NULL"
     );
   }
   ```

2. **Provably Safe Legacy v4 Command Recovery:**
   - **Distinguish Unsent Actions from Dispatched Commands:**
     * *Unsent Local Actions:* Local drafts created offline that have never been dispatched (`retryCount == 0`). These contain no ambiguity regarding server outcome and can safely have `actorUserId` assigned upon explicit submission by the current active user.
     * *Dispatched Commands with Unknown Outcomes:* Commands dispatched under v4 that may have reached the server before a crash, disconnect, or upgrade (`retryCount > 0`).
   - **Strict Invariants for Dispatched Commands:**
     1. **Preserve Original Command IDs:** The unique `command_id` generated under v4 MUST NEVER be discarded or replaced. Idempotency on PostgreSQL is keyed strictly on `command_id`.
     2. **Preserve Unknown Outcomes:** The command is assigned `recoveryState = 'quarantined_unknown_outcome'`. It is never assumed to be absent or failed based on heuristic searches.
     3. **No Automatic Command ID Regeneration:** The client will **never** automatically generate a new command ID merely because an approximate search (by child, title, timestamp) yields no result. Doing so would bypass server idempotency and risk duplicate RP spending, duplicate wheel spins, or duplicate assessment submissions if the original command commits late or was in flight.
     4. **Exact Server-Authoritative Reconciliation:**
        - *Adult Commands:* An authenticated family adult has RLS access to query `select * from public.command_receipts where command_id = :original_command_id`. If found, the command definitively committed, and the client reconciles local state from the target entity (`reward_redemptions`, `wheel_spins`, `assessments`) without network re-execution.
        - *Paired Child Commands:* Paired child devices cannot read `command_receipts` directly due to RLS. However, replaying the authoritative mutation RPC with the **EXACT SAME `original_command_id`** executes server-side lookup in `command_receipts`. If already committed, the RPC returns the existing row idempotently.
     5. **Safe Manual Resolution Path:**
        - When the original actor or outcome cannot be determined programmatically (e.g. shared device where original actor is unknown):
        - The Parent Settings UI provides a dedicated "Legacy Outbox Reconciliation" screen.
        - The parent inspects the command details (child, reward, cost, timestamp) alongside recent authoritative family history.
        - If the parent confirms the action is already reflected in history, they tap **"Mark Resolved"** (purges local outbox entry without network calls).
        - If the parent verifies it was never applied and chooses to re-issue, they select **"Re-authorize as [Parent Name]"**. Only then does the parent's action explicitly authorize creating an intentional new command under the parent's authenticated identity.
        - If the parent chooses to abandon, they select **"Discard"** (purges local outbox entry, refreshes remote balances).

---

### 3.3 Actor-Aware Command Recovery & Error Classification

#### 3.3.1 Error Classification & Backend SQLSTATE `42501` Disambiguation
The server returns SQLSTATE `42501 (insufficient_privilege)` across diverse authorization conditions. The client **MUST NOT** treat all `42501` errors as device revocation.

| Server Condition | Error Code / Message | Client Classification | Client Recovery Action |
|---|---|---|---|
| Replayed command submitted under different user | `42501: Command caller mismatch` or `Invalid command replay` | `CALLER_MISMATCH` | Halt replay; pause command in `pending_original_actor`; do not reassign actor |
| Device pairing grant revoked on server | `42501: Device grant revoked or inactive` | `DEVICE_REVOKED` | Confirm via dedicated `child_device_grants` query; transition to unlinked shell; quarantine drafts |
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

#### 3.3.3 Authoritative Idempotent Server RPC Replay Contracts & Response-Lost Recovery
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
| **Pending Reward Commands** | `pending_reward_commands`| **Paused** (`pending_original_actor`) | **Paused** | **Purged** | **Quarantined** | **Purged** |
| **Local Evidence Photos** | App Documents Dir | **Retained** (pending draft) | **Retained** | **Purged** | **Quarantined** | **Purged** |
| **Cached Read Models** | SQLite Read Tables | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** |

---

### 3.5 Evidence Reliability, Persistence & Content-Integrity Conflict Resolution

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

#### 3.5.3 Resumable Storage Protocol, Content Hash & Safe HTTP 409 Conflict Policy
LearnWard uses `supabase_flutter: ^2.18.3` and `supabase: ^2.16.5` (`storage_client`). AWS S3 methods (`headBucket`, `getObject`) are not supported.
- **Persistent Evidence Identity Model:**
  - `evidenceId`: The client-generated deterministic UUID (`clientEvidenceUuid`) stored in `LocalAssessmentDrafts.evidenceId`.
  - `serverEvidenceId`: The authoritative primary key UUID (`id`) in `public.assessment_evidence` returned upon registration, stored in `LocalAssessmentDrafts.serverEvidenceId`.
  - `sha256Checksum`: Cryptographic content hash of the compressed JPEG bytes stored in `LocalAssessmentDrafts.sha256Checksum`.
  - `localCompressedPhotoPath`: Path to the stably compressed image stored in `LocalAssessmentDrafts.localCompressedPhotoPath`.
- **Stable Compression & Deterministic Hash:**
  - When evidence is captured, it is compressed once and saved to `localCompressedPhotoPath`. Its SHA-256 hash is computed and persisted.
  - Across all retries and app restarts, the compressor is **NEVER re-invoked**. Re-compressing produces byte drift, hash divergence, and progressive generation loss.
- **Deterministic Storage Hierarchy:**
  Path: `{family_id}/{child_id}/{assessment_id}/{clientEvidenceUuid}.jpg` matching regex:
  `^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png)$`
- **Safe HTTP 409 Conflict Policy & Content-Integrity Verification:**
  1. Client uploads binary data with custom metadata:
     ```dart
     await supabase.storage.from('assessment-evidence').uploadBinary(
       storagePath,
       compressedBytes,
       fileOptions: FileOptions(
         contentType: 'image/jpeg',
         upsert: false,
         metadata: {'sha256': sha256Checksum, 'client_uuid': clientEvidenceUuid},
       ),
     );
     ```
  2. If upload returns HTTP 409 Conflict (remote object exists at path):
     - The client does **NOT** blindly treat 409 as success!
     - The client lists the directory via `supabase.storage.from('assessment-evidence').list(path: '$familyId/$childId/$assessmentId')` and locates `$clientEvidenceUuid.jpg`.
     - The client verifies content equality:
       * Remote byte size == `compressedBytes.length`;
       * Remote `metadata['sha256']` == `sha256Checksum`.
     - **Conflict Resolution Decision Tree:**
       * **Content Matches (Equal Hash & Size):** The previous upload attempt succeeded before the client received the HTTP response. The upload step is marked complete; proceed to `register_assessment_evidence` RPC.
       * **Content Differs (Mismatched Hash/Size or Corrupted 0-Byte File):**
         The remote object does not match the intended evidence.
         To avoid overwriting unrelated evidence or corrupting data:
         The client generates a fresh, unique `clientEvidenceUuid`, recalculates `storagePath`, updates `LocalAssessmentDrafts.evidenceId`, and uploads to the new distinct path without overwriting.
  3. Authoritative Database Registration:
     - The client invokes the frozen idempotent RPC:
       ```dart
       final response = await supabase.rpc('register_assessment_evidence', params: {
         'p_assessment_id': assessmentId,
         'p_storage_path': storagePath,
         'p_media_type': 'image/jpeg',
         'p_file_size_bytes': compressedBytes.length,
       });
       ```
     - The server returns the authoritative `public.assessment_evidence` record.
     - The client stores the returned database UUID (`id`) into `LocalAssessmentDrafts.serverEvidenceId`.
     - If the app restarts during any stage, Drift SQLite retains `submissionStatus`, `serverEvidenceId`, `localCompressedPhotoPath`, and `sha256Checksum`, allowing seamless resumption without re-compression.

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
- **Authoritative Reconciliation Guarantee:** Because Realtime connections are transient (app backgrounding, sleep, poor connectivity), parent inbox counters and child review badges must **never** rely exclusively on Realtime events. On app launch, resume from background, and WebSocket reconnect, the app queries authoritative tables (`assessments` with `status = 'pending_review'`, `reward_redemptions` with `status = 'pending_fulfillment'`). Badges clear naturally when underlying entity states transition (`verified`, `rejected`, `fulfilled`).
- **Abstract Service Port (Pilot Contract):**
  ```dart
  abstract class NotificationService {
    Stream<FamilyCoordinationEvent> get coordinationEvents;
    Future<void> initialize();
  }
  ```
  *(Note: `markRead(eventId)` is omitted for the pilot because coordination badges are driven authoritatively by domain state transitions in PostgreSQL rather than ad-hoc client read receipts).*

---

### 4.2 Restored Canonical 16-Metric Contract & VLPE Derivation

#### 4.2.1 Canonical Definition of Verified Learning Progress Event (VLPE)
The North Star metric **VLPE** is canonically defined in [Metrics & Hypotheses v0.1](06-metrics-and-hypotheses.md) as:
> **Verified Learning Progress Events / Active Child / Week (VLPE)**
> *A verified assessment event that has completed both Growth Engine processing (`public.growth_events`) and Learning Mastery processing (`public.learning_processing_events` with `status = 'processed'`), measured per active child per calendar week.*

Authoritative SQL derivation:
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

#### 4.2.2 Restored Authoritative 16-Metric Inventory
The authoritative 16-metric contract from `docs/06-metrics-and-hypotheses.md` is restored verbatim, preserving the reviewed classification (12 directly derivable from PostgreSQL, 4 deferred or requiring external/qualitative inputs):

| # | Metric from `docs/06` | Classification | Authoritative Source / Derivation Method |
|---|---|---|---|
| 1 | **VLPE / child / week** | `DERIVABLE FROM AUTHORITATIVE DB` | Canonical query above: VLEs with both `growth_events` and processed `learning_processing_events` per child per week |
| 2 | **Results logged / child / week** | `DERIVABLE FROM AUTHORITATIVE DB` | Immutable submission events (excludes abandoned drafts):<br>`select count(*) from public.assessment_review_events rev join public.assessments a on a.id = rev.assessment_id and a.family_id = rev.family_id where rev.event_type = 'submitted' and a.child_id = :child_id and rev.created_at >= :start and rev.created_at < :end` |
| 3 | **% results logged by child** | `DERIVABLE FROM AUTHORITATIVE DB` | Filtered aggregate over submitted assessment review events (same population as Metric 2):<br>`count(*) filter (where a.entry_context in ('shared_child', 'paired_child'))::numeric / nullif(count(*), 0)` |
| 4 | **% goals chosen by child** | `NOT CURRENTLY MEASURABLE / DEFERRED` | Goals entity not implemented in Phases 1–5; deferred post-pilot. Do not add Goals scope solely for metrics. |
| 5 | **4-week subject trend** | `DERIVABLE FROM AUTHORITATIVE DB` | Grouped `verified_learning_events` score trajectory by `subject_key` over 28-day window |
| 6 | **Recovery completion rate** | `DERIVABLE FROM AUTHORITATIVE DB` | Replayed weak observations in `learning_evidence_events` reaching $\ge 70\%$ score within 30 days |
| 7 | **Personal-best frequency** | `DERIVABLE FROM AUTHORITATIVE DB` | Authoritative Growth result: `count(*) filter (where g.personal_best_rp_minor > 0)` |
| 8 | **Parent approval latency** | `DERIVABLE FROM AUTHORITATIVE DB` | Immutable review events: `EXTRACT(EPOCH FROM (v_evt.created_at - s_evt.created_at))` where `s_evt.event_type = 'submitted'` and `v_evt.event_type = 'verified'`. Excludes draft creation time. |
| 9 | **Parent admin minutes/day** | `NOT CURRENTLY MEASURABLE` | Requires client UI screen session timing or weekly qualitative pilot survey |
| 10 | **Reward fulfillment rate** | `DERIVABLE FROM AUTHORITATIVE DB` | Filtered aggregates: `count(*) filter (where status = 'fulfilled')::numeric / nullif(count(*) filter (where status in ('pending_fulfillment', 'fulfilled', 'cancelled')), 0)` from `public.reward_redemptions` |
| 11 | **RP earned / week** | `DERIVABLE FROM AUTHORITATIVE DB` | `SUM(amount_minor) FROM public.rp_ledger WHERE amount_minor > 0` |
| 12 | **RP spent / week** | `DERIVABLE FROM AUTHORITATIVE DB` | `ABS(SUM(amount_minor)) FROM public.rp_ledger WHERE amount_minor < 0` |
| 13 | **Wheel vs Store spend share** | `DERIVABLE FROM AUTHORITATIVE DB` | Authoritative query separating wheel from store spend:<br>`coalesce((select sum(ws.spin_cost_minor) from public.wheel_spins ws where ws.child_id = :id and ws.created_at >= :start and ws.created_at < :end), 0)` vs.<br>`coalesce((select sum(rr.rp_cost_minor) from public.reward_redemptions rr where rr.child_id = :id and rr.origin = 'store' and rr.created_at >= :start and rr.created_at < :end), 0)` |
| 14 | **Self-chosen challenge rate** | `NEEDS NEW CLIENT/UX EVENT` | Requires client event tracking when an assessment is launched directly from a Next Challenge recommendation card |
| 15 | **Week 4 / Week 8 retention** | `DERIVABLE FROM AUTHORITATIVE DB` | Distinct active children with $\ge 1$ canonical VLPE (both growth + learning processed) in week 4 and week 8 |
| 16 | **Parent study reminders / week** | `NEEDS NEW PRODUCT INPUT / SURVEY` | Parent Intervention Rate baseline vs. weekly qualitative check-in interview |

---

### 4.3 Data Retention, Archival & Complete RLS Coverage Overhaul

#### 4.3.1 Inventory of Child-Linked Tables & Storage Assets
The LearnWard backend manages 20 relational tables and 1 Storage bucket containing child-associated data across Phases 1 through 5:
1. `public.child_profiles` (has `id = child_id`, `family_id`)
2. `public.child_device_grants` (has `child_id`, `family_id`)
3. `private.child_pairing_requests` (has `child_id`, `family_id`)
4. `public.assessments` (has `child_id`, `family_id`)
5. `public.assessment_evidence` (has `assessment_id`, `family_id`; linked via `assessments.child_id`)
6. `public.assessment_review_events` (has `assessment_id`, `family_id`; linked via `assessments.child_id`)
7. `public.assessment_learning_mappings` (has `child_id`, `family_id`)
8. `public.verified_learning_events` (has `child_id`, `family_id`)
9. `public.learning_evidence_events` (has `child_id`, `family_id`)
10. `public.learning_processing_events` (has `child_id`, `family_id`)
11. `public.mastery_state_revisions` (has `child_id`, `family_id`)
12. `public.child_mastery_states` (has `child_id`, `family_id`)
13. `public.growth_events` (has `child_id`, `family_id`)
14. `public.xp_ledger` (has `child_id`, `family_id`)
15. `public.rp_ledger` (has `child_id`, `family_id`)
16. `public.child_balances` (has `child_id`, `family_id`)
17. `public.rewards` (`target_child_id` nullable foreign key, `family_id`)
18. `public.reward_redemptions` (has `child_id`, `family_id`)
19. `public.wheel_spins` (has `child_id`, `family_id`)
20. `public.command_receipts` (operational idempotency audit logs; `family_id`, `resource_id`)
21. Storage bucket `assessment-evidence` (object paths `{family_id}/{child_id}/{assessment_id}/{clientEvidenceUuid}.jpg`)

#### 4.3.2 Complete RLS Read-Boundary Policy Overhaul
In PostgreSQL, multiple permissive policies on the same table combine with `OR`. Merely adding a new policy does **NOT** restrict access if an existing permissive policy (`using (private.is_active_family_adult(family_id))`) remains active!
Therefore, Phase 6 **drops and replaces** the existing SELECT policies on every child-linked table.

1. **Security Helper:**
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

2. **Policy Replacement for Tables With Direct `child_id`:**
   Applied across: `assessments`, `verified_learning_events`, `learning_evidence_events`, `learning_processing_events`, `mastery_state_revisions`, `child_mastery_states`, `assessment_learning_mappings`, `growth_events`, `xp_ledger`, `rp_ledger`, `child_balances`, `reward_redemptions`, `wheel_spins`:
   ```sql
   drop policy if exists <table_name>_select on public.<table_name>;
   create policy <table_name>_select on public.<table_name>
     for select to authenticated
     using (
       (
         private.is_active_family_adult(family_id)
         and private.is_child_active_in_family(child_id, family_id)
       )
       or private.is_active_child_device(family_id, child_id)
     );
   ```

3. **Policy Replacement for Tables Without Direct `child_id`:**
   - **`assessment_evidence`** (authoritative join path through `public.assessments`):
     ```sql
     drop policy if exists assessment_evidence_select on public.assessment_evidence;
     create policy assessment_evidence_select on public.assessment_evidence
       for select to authenticated
       using (
         exists (
           select 1 from public.assessments a
           where a.id = assessment_evidence.assessment_id
             and a.family_id = assessment_evidence.family_id
             and (
               (
                 private.is_active_family_adult(assessment_evidence.family_id)
                 and private.is_child_active_in_family(a.child_id, assessment_evidence.family_id)
               )
               or private.is_active_child_device(assessment_evidence.family_id, a.child_id)
             )
         )
       );
     ```
   - **`assessment_review_events`** (authoritative join path through `public.assessments`):
     ```sql
     drop policy if exists assessment_review_events_select on public.assessment_review_events;
     create policy assessment_review_events_select on public.assessment_review_events
       for select to authenticated
       using (
         exists (
           select 1 from public.assessments a
           where a.id = assessment_review_events.assessment_id
             and a.family_id = assessment_review_events.family_id
             and private.is_active_family_adult(assessment_review_events.family_id)
             and private.is_child_active_in_family(a.child_id, assessment_review_events.family_id)
         )
       );
     ```
   - **`rewards`** (authoritative check on `target_child_id`):
     ```sql
     drop policy if exists rewards_select on public.rewards;
     create policy rewards_select on public.rewards
       for select to authenticated
       using (
         (
           private.is_active_family_adult(family_id)
           and (target_child_id is null or private.is_child_active_in_family(target_child_id, family_id))
         )
         or (
           is_active = true
           and (store_enabled = true or wheel_enabled = true)
           and (
             (target_child_id is null and exists (
               select 1 from public.child_device_grants cdg
               where cdg.family_id = rewards.family_id
                 and cdg.auth_user_id = auth.uid()
                 and cdg.status = 'active'
                 and private.is_child_active_in_family(cdg.child_id, rewards.family_id)
             ))
             or (target_child_id is not null and private.is_active_child_device(family_id, target_child_id)
                 and private.is_child_active_in_family(target_child_id, family_id))
           )
         )
       );
     ```
   - **`child_profiles`**:
     ```sql
     drop policy if exists child_profiles_select on public.child_profiles;
     create policy child_profiles_select on public.child_profiles
       for select to authenticated
       using (
         (private.is_active_family_adult(family_id) and status = 'active')
         or (id = (
           select cdg.child_id from public.child_device_grants cdg
           where cdg.auth_user_id = auth.uid()
             and cdg.status = 'active'
         ) and status = 'active')
       );
     ```

4. **Positive & Negative RLS Regression Obligations:**
   - *Positive adult check on active child:* Adult in Family A CAN select records for active Child A1.
   - *Negative adult check on archived child:* Adult in Family A CANNOT select records for archived Child A2 in standard daily queries (returns 0 rows).
   - *Negative adult check on foreign family:* Adult in Family B CANNOT select records for any child in Family A (returns 0 rows).
   - *Positive child device check on own active record:* Paired child device for Child A1 CAN select its own active records.
   - *Negative child device check on sibling/foreign child:* Paired child device for Child A1 CANNOT select records for Child A2 or any foreign child.
   - *Negative child device check on revoked grant:* Paired child device with `status = 'revoked'` CANNOT select any child records (returns 0 rows).
   - *Negative child device check on archived profile:* Even if a grant row was not explicitly revoked, if child profile is archived, child device is denied access.

#### 4.3.3 Operational Minimization, Legal Validation & Technical Constraints
- **Legal & Privacy Review Obligation:**
  > **MANDATORY LEGAL / PRIVACY REVIEW OBLIGATION:**
  > A formal legal and privacy review (covering COPPA verifiable parental consent, GDPR/CCPA data minimization, and lawful bases) **MUST be completed prior to onboarding external pilot families** and processing real children's personal data. Legal compliance cannot be deferred to commercial launch.
- **Distinction Between Operational Minimization and Statutory Erasure:**
  - *Internal Operational Minimization:* The 4-tier technical lifecycle implemented in application code and PostgreSQL RLS:
    1. **Tier 1 (Access Revocation):** `child_device_grants.status = 'revoked'`.
    2. **Tier 2 (Soft Archival & RLS Exclusion):** `child_profiles.status = 'archived'`. RLS hides all child-linked records from normal adult and child queries.
    3. **Tier 3 (Child Profile Pseudonymization):** Identifying attributes in `child_profiles` are scrubbed (`display_name = '[Archived Learner]'`, `avatar_key = null`, `school_grade = null`, `birth_year = null`).
    4. **Tier 4 (Evidence Storage Purging):** All photographic evidence in Storage bucket `assessment-evidence` under `{family_id}/{child_id}/*` is permanently deleted.
  - *Statutory Erasure Posture:* Retaining child-linked immutable ledger rows (`xp_ledger`, `rp_ledger`, `verified_learning_events`), even with direct names removed, does NOT automatically guarantee statutory anonymization or legitimate-interest retention. Remaining UUID relationships, timestamps, and review notes can still enable re-identification.
- **Technical Constraint on Review Notes:** `assessment_review_events` is protected by the immutable trigger `trg_prevent_assessment_review_event_mutation`, prohibiting in-place UPDATE or DELETE of `review_notes`. Modifying historical notes is blocked by the frozen trigger; access is severed at the RLS read boundary.

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
   - Comprehensive RLS test suite verifying positive adult access on active children, negative adult access on archived children across all 20 tables, cross-tenant denial, and export RPC security. All 438 existing pgTAP assertions must remain green.

### 7.2 Real-Device Validation Matrix
Before rolling out builds to pilot families, the following real-device matrix must be executed:

| Test Case | Android Physical Device | iPhone Physical Device | Validation Method |
|---|---|---|---|
| Camera capture with image compression | Physical camera hardware | Physical camera hardware | Manual |
| App kill during assessment upload | Force quit in app switcher | Swipe up in app switcher | Manual + Outbox verification |
| Airplane mode draft authoring & reconnect | Offline save $\to$ reconnect | Offline save $\to$ reconnect | Manual |
| Adult logout on shared device | Verify drafts/commands preserved | Verify drafts/commands preserved | Manual + Automated widget |
| Screen reader navigation | TalkBack enabled | VoiceOver enabled | Manual audio audit |
| Large accessibility font (200%) | Largest font scale | Accessibility Dynamic Type | Manual visual audit |
| Reduced motion wheel spin | Remove animations enabled | Reduce Motion enabled | Manual visual audit |

---

## 8. Implementation Sequencing

1. **Phase 6.1:** Bounded Outbox, Drift Schema v5, Actor Binding, Evidence Content-Integrity, iOS Permissions, Failure/Retry UX.
2. **Phase 6.2:** In-App Coordination Notifications, Canonical VLPE Queries, Restored 16 Metrics, Complete RLS Overhaul, Legal Pre-Pilot Review.
3. **Phase 6.3:** Semantics Pass, Touch Targets, Reduced-Motion Reveal, Signed Release Packaging, Diagnostics.
4. **Pilot Deployment Gate:** Legal review completion, staging smoke verification, TestFlight internal build, Google Play internal track build, 4-week pilot launch.
