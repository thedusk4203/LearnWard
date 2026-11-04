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
  TextColumn get dispatchState => text().withDefault(const Constant('unknown_legacy'))();
  // dispatch: unknown_legacy / never_dispatched / possibly_dispatched / confirmed_committed
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
  IntColumn get retryCount => integer().withDefault(const Constant(0))(); // Not evidence of non-dispatch
  TextColumn get dispatchState => text().withDefault(const Constant('unknown_legacy'))();
  TextColumn get lastErrorMessage => text().nullable()();
  TextColumn get actorUserId => text().nullable()();
  TextColumn get actorRole => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {localDraftId};
}
```

#### 3.2.3 Non-Destructive Drift v4 → v5 Upgrade and Legacy Dispatch Provenance

**Critical historical limit:** Frozen Drift v4 has no `retryCount` nor any persisted dispatch flag on `local_assessment_drafts` or `pending_reward_commands`. A newly added zero-default `retryCount` is **not evidence a historical operation was unsent**. All migrated v4 commands and possibly submitted drafts start with `dispatchState='unknown_legacy'` and remain quarantined until exact server-authorized reconciliation. Preserve original UUIDs, server IDs, drafts and photo files; never invent actor identity or network outcome.

1. **New v5 columns and migration:** In the proposed Drift declarations above, add `dispatchState => text().withDefault(const Constant('unknown_legacy'))()` to **both** journal tables. The v4→v5 `onUpgrade` must add these two columns, together with all already-declared actor/evidence and status columns using `migrator.addColumn`, preserving old column nullability. Mark existing pending commands with unknown actor `recoveryState='quarantined_unknown_outcome'`; do not rewrite original `commandId`, `createCommandId`, `submitCommandId`, `serverAssessmentId` or evidence file paths. An existing server assessment ID proves partial prior server work, not successful or failed submission.
2. **New v5 entries only:** Explicitly insert fresh commands/drafts with `dispatchState='never_dispatched'`. **Before any remote mutating RPC**, atomically commit `dispatchState='possibly_dispatched'` to SQLite. A crash after committing that marker but before the actual network request still counts as unknown, intentionally. Only an authoritative success or exact permitted server receipt advances `confirmed_committed`; retries merely count attempts and cannot prove non-dispatch.
3. **Reconciliation:** For an adult, a matching `command_receipts.command_id` confirms a committed original operation where RLS permits access. A missing/hidden receipt, approximate match by title/reward/timestamp or client timeout **never proves absence**. Same-ID idempotent replay is permitted only when the original authenticated actor is positively established and satisfies the frozen RPC's family/actor/operation authorization. Unknown-actor v4 entries must **never** replay automatically as a different adult or paired child.
4. **Manual fallback:** Present `Keep quarantined`, `Export unsynced work`, and `Abandon local copy` (explicitly warn that a remote effect, if it happened, remains). Do not regenerate command IDs or present another wheel spin/RP debit as safe recovery. A genuinely new operation requires a separate, clearly identified user request and duplicate-risk safeguards.
5. **Migration tests:** Populate real v4 SQLite databases with offline-only drafts, potentially dispatched drafts, committed-before-timeout commands, unknown actors and photo paths. Verify no data loss, all old dispatch states remain UNKNOWN, no automatic legacy replay, and new v5 pre-send state is durable across forced process death. Verify zero double ledger/reward effects.


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
4. **Replay Invariant:** Replays must always execute under the original `actor_user_id`. Replaying under a different actor causes server rejection with `42501: Invalid command replay` (actor mismatch). Migrated v4 rows with unknown original actor cannot be automatically replayed.
5. **Post-Archive Outbox Handling & Explicit Reconciliation Deferral:**
   - When a child profile is archived, subsequent server-side mutation RPC replays fail closed with `42501` (`Child profile is archived`).
   - Dedicated read-only post-archive command reconciliation RPCs are **EXPLICITLY DEFERRED** post-pilot to keep pilot scope strictly bounded.
   - Mobile outbox dispatchers catch the `42501` archive rejection and transition the pending command to `quarantined_unknown_outcome`.
   - Quarantined commands and local assessment drafts/evidence remain safely preserved in local SQLite without automated network retry. Authorized parents review historical records and export all family data via the schema-verified `export_family_data_json` RPC (§4.3.4).

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

#### 3.5.3 Byte-Verified Remote Evidence and HTTP 409 Resolution

Keep `evidenceId` (client UUID in deterministic storage path), `serverEvidenceId` (separate `assessment_evidence.id`), `sha256Checksum` and `localCompressedPhotoPath`. Compress the JPEG once for legibility, persist its bytes and SHA-256, and **never recompress on retry**. Use `uploadBinary` with `upsert: false` and an authenticated client against the existing private `assessment-evidence` bucket.

**A matching path, file size or custom metadata from `storage.list()` is not proof of byte equality.** Supabase Storage [issue #759](https://github.com/supabase/storage/issues/759) documents that user-defined metadata can be missing from `list()`. On HTTP 409, an unknown response or an object already present:

1. With the *original authorized actor*, download the private object using the supported Dart method `supabase.storage.from('assessment-evidence').download(storagePath)`. Calculate SHA-256 from the **downloaded bytes** and compare digest **and** length to the persisted local JPEG. Verify SDK methods and private-bucket RLS behavior in integration tests.
2. **Exact match:** Reuse the object path, but do not assume that a frozen registration RPC can be repeated after assessment submission. Reconcile the authoritative evidence row and assessment status under `3.5.4; call the same-path registration RPC only while assessment is still draft and the original actor remains authorized.
3. **Different SHA-256 or size:** Enter `evidence_conflict` (recovery classification) and preserve original bytes, UUID and path. Do not overwrite, rotate UUIDs or register another file automatically. Investigate DB linkage before manual resolution.
4. **Download forbidden, unavailable, incomplete, or result uncertain:** Enter `verification_pending`, retain all local data and retry with bounded backoff after authorization returns. A failed list/read is not proof that an upload is absent. Only a definitive, authorized object-not-found response permits reattempting the original `upsert:false` upload.
5. **Acceptance tests:** Same-size/different-bytes object, missing custom metadata, 409 exact match, upload-committed/response-lost, registration-committed/response-lost, app restart, revoked/archived actor and private Storage RLS. Never include a service-role credential or grant Storage UPDATE/upsert to the mobile client.

References: [Supabase Dart upload](https://supabase.com/docs/reference/dart/file-buckets-upload), [private Storage buckets](https://supabase.com/docs/guides/storage/buckets/fundamentals), [custom metadata issue](https://github.com/supabase/storage/issues/759).


---

#### 3.5.4 Reconciliation After Evidence Registration Response Loss

**Frozen RPC reality:** `public.register_assessment_evidence(p_assessment_id,p_storage_path,p_media_type,p_file_size_bytes)` checks `assessments.status='draft'` **before** looking up an already-registered `assessment_evidence.storage_path`. If registration committed but its response was lost, and another device then submitted the assessment, a repeat RPC returns `LW109` even for the same path. A successful Storage upload never proves the database registration completed.

1. Preserve original `assessmentId`, client evidence UUID, `storagePath`, stable compressed bytes/checksum and `serverEvidenceId` across restarts. On response loss, use only existing authenticated, same-family **authorized SELECT** on `assessments.id` and `assessment_evidence.storage_path`, also checking linked `assessment_id`, `family_id`, media type and file size. Never infer absence from an RLS-filtered zero-row result.
2. **Matching authoritative row exists:** After `3.5.3` remote-byte integrity checks, store the returned `assessment_evidence.id` as `serverEvidenceId` and mark registration reconciled **without a mutation**, even if assessment is now `pending_review`, `verified` or `rejected`.
3. **No visible row and assessment remains draft:** If authorization and remote bytes have been verified, retry the exact original registration RPC/path. On timeout or `LW109`, re-read authoritative state; do not automatically change UUID, actor or assessment version.
4. **No visible row and assessment is non-draft:** Enter `registration_unresolved` and retain the local photo/UUID. Do not call the frozen registration RPC, reopen terminal assessments, attach evidence after submission or replace the path. An authorized parent can export locally retained evidence and inspect the recorded assessment before any separate remedial decision.
5. **Archived child, changed/revoked actor, or inaccessible record:** Quarantine pending data. Never bypass RLS or expose service-role credentials; only a separately authorized archival/export process may handle archived content.
6. **Acceptance:** Test registration-committed/response-lost followed by remote submission; not-committed before submission; pending_review/verified/rejected; RLS-hidden row; mismatched metadata; same/different SHA-256; actor changes; archived child; and app restart. Require zero duplicate evidence rows, no post-submission evidence attachment and no immutable assessment mutation.

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

#### 4.3.2 Active-Child RLS for Both Roles, Plus Explicit Operational Exceptions

PostgreSQL permissive SELECT policies combine with `OR`. Phase 6 must enumerate `pg_policies` and replace affected policies in **new** migrations without editing frozen Phase 0–5 files. The predicates below are design contracts; use verified real policy names and privileges during implementation.

1. **Required child-state predicate:** `private.is_child_active_in_family(child_id,family_id)` verifies the exact child/family and `child_profiles.status='active'`. It is a narrowly granted, fixed-`search_path` SECURITY DEFINER helper, not itself caller authorization. Across `assessments`, `verified_learning_events`, `learning_evidence_events`, `learning_processing_events`, `mastery_state_revisions`, `child_mastery_states`, `assessment_learning_mappings`, `growth_events`, `xp_ledger`, `rp_ledger`, `child_balances`, `reward_redemptions` and `wheel_spins`, the **active-child condition must be outside the adult/child-device OR**:
   ```sql
   -- Conceptual USING; preserve any stricter frozen role restriction.
   private.is_child_active_in_family(child_id, family_id)
   AND (
     private.is_active_family_adult(family_id)
     OR private.is_active_child_device(family_id, child_id)
   )
   ```
   A still-active device grant **cannot** expose archived learning records.
2. **Indirect relationships:** `assessment_evidence` and `assessment_review_events` join same-family `assessments` and require active linked child; review events remain adult-only. Targeted `rewards` require an active `target_child_id`, while family-wide rewards retain their tenant conditions. `child_profiles_select` requires active profile for **both** adult and child device.
3. **Child profile direct UPDATE policy replacement:** The frozen Phase 1 migration granted broad UPDATE on `public.child_profiles` to authenticated adults. In a new Phase 6 migration, replace `child_profiles_update` to require active child status in both `USING` and `WITH CHECK`:
   ```sql
   drop policy if exists child_profiles_update on public.child_profiles;
   create policy child_profiles_update on public.child_profiles
     for update to authenticated
     using (
       private.is_active_family_adult(family_id)
       and status = 'active'
     )
     with check (
       private.is_active_family_adult(family_id)
       and status = 'active'
     );
   ```
   This prevents ordinary Data API clients from updating already-archived profiles. Combined with the trigger guard `trg_guard_child_profile_lifecycle` (§4.3.2.2.1), direct Data API callers are prohibited from modifying `status` or `archived_at` or reactivating archived profiles (`archived -> active`), while parents retain the ability to update standard editable fields (`display_name`, `avatar_key`, `school_grade`) on active profiles.
4. **Grant-status exception:** Preserve the `child_device_grants` owner's *own-row* read (`auth_user_id=auth.uid()`) even when revoked or archived so positive `status='revoked'` evidence remains available. Restrict parent listing of other grant rows to active child profiles. Example:
   ```sql
   drop policy if exists child_device_grants_select on public.child_device_grants;
   create policy child_device_grants_select on public.child_device_grants
     for select to authenticated using (
       (private.is_active_family_adult(family_id)
        AND private.is_child_active_in_family(child_id,family_id))
       OR auth_user_id = auth.uid()
     );
   ```
   This narrow status exception **does not grant archived assessment, reward or evidence reads**.
5. **`command_receipts`:** There is no direct `child_id`. Keep adult-only SELECT; resolve `resource_id` by operation: `create_draft/submit/verify/reject` → `assessments.id`, `redeem_reward/fulfill_reward/cancel_reward` → `reward_redemptions.id`, `spin_wheel` → `wheel_spins.id`. Require active family adult **and** active child through the operation-specific resource + same family join; unknown operations or missing resources fail closed. Child devices still use server-side idempotent RPCs rather than SELECT on receipts.
6. **Processing command receipts:** Frozen Phase 3 and Phase 5 RPCs also use operations `process_growth` and `process_learning` with `resource_id = verified_learning_events.id`. Their adult-only receipt visibility must be resolved through the VLE's active child/family; unknown operations fail closed. Include these exact operation codes in regression tests.
7. **Private pairing and Storage:** Verify `private.child_pairing_requests` has no client-readable route or grants. The frozen `storage.objects` evidence SELECT policy calls `private.validate_storage_evidence_access(name,false)`, which currently checks actor and assessment **but not child archive status**. Harden that helper in a new Phase 6 migration by requiring `private.is_child_active_in_family(v_child_id,v_family_id)` for SELECT/INSERT/DELETE, while preserving tenant, assessment, draft-only mutation and no-UPDATE invariants. Audit other permissive Storage policies to prevent OR bypass; only authorized backend operations may purge archived evidence.
8. **Required pgTAP:** Adults/paired children/siblings/foreign family; active/archived child with *both active and revoked grants*; every direct/indirect child-linked table, each command receipt operation, positive own-grant status after revocation, private pairing, direct child profile update rejection, and Storage SELECT/INSERT/DELETE. Do not claim complete archived-child isolation without these checks.


#### 4.3.2.1 Family-Wide SELECT and Read-Model Boundary

**Verified existing gap:** Phase 4.2 `family_wheel_settings_select` and the untargeted-reward branch of `rewards_select` allow a device with `child_device_grants.status='active'` to read family-wide content even if its linked `child_profiles.status='archived'`. RLS changes to directly child-linked tables do not close these paths.

1. In a **new Phase 6 migration**, drop/replace those exact policies. Retain adult family authorization; require paired-child sessions to have `cdg.auth_user_id=auth.uid()`, `cdg.status='active'`, same-family matching profile `cp.id=cdg.child_id AND cp.family_id=cdg.family_id` and **`cp.status='active'`**. For targeted rewards additionally require `target_child_id=cdg.child_id`; untargeted rewards may remain available to other active children, never an archived child's grant. Preserve `rewards.is_active` and Store/Wheel eligibility constraints.
2. Illustrative family settings policy (verify current table grants and all competing permissive policies):
   ~~~sql
   drop policy if exists family_wheel_settings_select on public.family_wheel_settings;
   create policy family_wheel_settings_select on public.family_wheel_settings
     for select to authenticated using (
       private.is_active_family_adult(family_id)
       or exists (
         select 1 from public.child_device_grants cdg
         join public.child_profiles cp on cp.id=cdg.child_id and cp.family_id=cdg.family_id
         where cdg.family_id=family_wheel_settings.family_id
           and cdg.auth_user_id=auth.uid() and cdg.status='active' and cp.status='active'
       )
     );
   ~~~
3. Audit every family-wide SELECT policy and **SECURITY DEFINER read RPC**. `get_wheel_status` already checks child active, whereas `reconcile_child_balance` resolves child by ID and checks adult/grant without child status. Require active child for normal paired-client economy/mastery/recommendation reads. Approved parent archival/export access is a distinct explicit allowlisted pathway.
4. Keep `child_device_grants` own-row status introspection to confirm revocation, but do not treat it as permission to read family-wide content. RLS grants **rows, not only selected columns**; verify which grant columns are visible and use a limited status projection if required. Test archived child with active grant, active sibling grant, adult, foreign family and revoked grant across rewards, wheel settings, read RPCs and grant status.

#### 4.3.2.2 Archive Barrier for SECURITY DEFINER Mutations and Catch-up

**Verified existing gap:** SECURITY DEFINER bypasses ordinary RLS. Several frozen RPCs authorize family adult or paired device, but do not check archived child status. A new Phase 6 migration must harden their bodies using the **same existing signatures, domain errors, actor-bound idempotency and immutable event/ledger guarantees**, without changing Phase 0–5 migration files.

| RPC category | Existing authoritative functions | Required Phase 6 behavior |
|---|---|---|
| Assessment create / wheel | `create_assessment_draft`, `spin_reward_wheel` already check child active | Preserve checks and test archive race |
| Assessment draft/evidence | `update_assessment_draft`, `register_assessment_evidence`, `remove_draft_assessment_evidence`, `submit_assessment` | Fail closed on archived child; retain draft-only, version and original actor guards |
| Parent review / mapping | `verify_assessment`, `reject_assessment`, `set_assessment_learning_mappings` | No new review, VLE, mapping rewrite or other downstream mutation for archived child |
| RP economy | `redeem_store_reward` (child lookup currently lacks status filter), `fulfill_reward_redemption`, `cancel_reward_redemption` | No new RP debit/refund, redemption or fulfillment for archived child; preserve existing receipts and ledger immutability |
| Growth / Learning pipelines | `process_verified_learning_event`, `process_learning_event`, `catch_up_unprocessed_growth`, `catch_up_unprocessed_learning` and internal processing helpers | Exclude archived child from new processing, XP/RP ledgers and mastery writes; do not silently process archived historical events |
| Read-only child-scoped RPCs | `reconcile_child_balance`, mastery, recommendation and family-scoped reader RPCs | Require active child on normal client calls; narrowly authorize approved archival data export separately |

##### 4.3.2.2.1 Canonical Child Archival Operation & Direct UPDATE Lifecycle Protection Contract
1. **Preventing Direct Lifecycle Modification via Data API:**
   - The frozen Phase 1 migration permitted authenticated adults direct `UPDATE` access to `public.child_profiles` without restricting column updates. This allowed ordinary Data API clients (`PATCH /rest/v1/child_profiles?id=eq.<id>`) to potentially manipulate `status` or `archived_at` directly, bypassing transactional archival invariants and risking uncoordinated reactivation (`archived -> active`).
   - In a new Phase 6 migration, direct Data API lifecycle manipulation is blocked via a two-layer defense:
     - **RLS Boundary:** The replacement `child_profiles_update` policy enforces `status = 'active'` on both existing rows (`USING`) and updated rows (`WITH CHECK`). Direct updates on already-archived profiles fail closed immediately.
     - **Trigger Invariant Guard (`trg_guard_child_profile_lifecycle`):** A `BEFORE UPDATE` trigger on `public.child_profiles` validates all update operations:
       ```sql
       create or replace function private.guard_child_profile_lifecycle()
       returns trigger
       language plpgsql
       security definer
       set search_path = ''
       as $$
       declare
         v_in_archive_rpc boolean;
       begin
         -- 1. Fail closed on already-archived profiles (no in-place edit, no reactivation)
         if old.status = 'archived' then
           raise exception 'Archived child profile is immutable' using errcode = 'LW011';
         end if;

         -- 2. Detect lifecycle status transition or archived_at modification
         if new.status is distinct from old.status or new.archived_at is distinct from old.archived_at then
           -- Verify that update originates from authorized transactional procedure
           v_in_archive_rpc := nullif(current_setting('learnward.in_archive_child_profile', true), '')::boolean;
           if not coalesce(v_in_archive_rpc, false) then
             raise exception 'Direct child profile lifecycle mutation is prohibited; call public.archive_child_profile()'
               using errcode = '42501';
           end if;

           -- Strict state machine: only active -> archived is allowed
           if old.status != 'active' or new.status != 'archived' or new.archived_at is null then
             raise exception 'Invalid child profile lifecycle transition' using errcode = 'LW012';
           end if;
         end if;

         -- 3. Preserve parent editing of mutable profile fields (display_name, school_grade, avatar_key)
         -- Core identity fields remain immutable
         if new.id != old.id or new.family_id != old.family_id or new.created_at != old.created_at then
           raise exception 'Core child profile fields are immutable' using errcode = 'LW005';
         end if;

         return new;
       end;
       $$;

       create trigger trg_guard_child_profile_lifecycle
         before update on public.child_profiles
         for each row
         execute function private.guard_child_profile_lifecycle();
       ```
2. **Authorized Transactional Archival Procedure (`archive_child_profile`):**
   Archival is routed strictly through the authoritative procedure:
   ```sql
   create or replace function public.archive_child_profile(p_child_id uuid)
   returns public.child_profiles
   language plpgsql
   security definer
   set search_path = ''
   as $$
   declare
     v_user_id uuid;
     v_family_id uuid;
     v_child public.child_profiles;
   begin
     v_user_id := auth.uid();
     if v_user_id is null then
       raise exception 'Unauthenticated' using errcode = '42501';
     end if;

     -- Derive authoritative family_id and check adult authorization
     select family_id into v_family_id
     from public.child_profiles
     where id = p_child_id;

     if not found or not private.is_active_family_adult(v_family_id) then
       raise exception 'Unauthorized to archive child profile' using errcode = '42501';
     end if;

     -- Acquire Order 1 exclusive row lock to serialize against concurrent mutations
     select * into v_child
     from public.child_profiles
     where id = p_child_id and family_id = v_family_id
     for update;

     if v_child.status = 'archived' then
       raise exception 'Child profile is already archived' using errcode = '42501';
     end if;

     -- Set transaction-local flag to authorize trigger transition
     set local learnward.in_archive_child_profile = 'true';

     -- Execute profile archival
     update public.child_profiles
     set status = 'archived',
         archived_at = now()
     where id = p_child_id
     returning * into v_child;

     -- Automatic cascade revocation: revoke all active device grants for this child
     update public.child_device_grants
     set status = 'revoked',
         revoked_at = now()
     where child_id = p_child_id
       and family_id = v_family_id
       and status = 'active';

     return v_child;
   end;
   $$;
   ```
3. **Preserving Ordinary Parent Profile Editing:**
   Parents retain normal Data API capability to update non-lifecycle fields (`display_name`, `avatar_key`, `school_grade`) on active profiles. When an active adult issues `PATCH /rest/v1/child_profiles?id=eq.<id>` with `{"display_name": "New Name"}`, RLS `child_profiles_update` permits the update and `trg_guard_child_profile_lifecycle` confirms `status` is unchanged, allowing the update to commit normally.

##### 4.3.2.2.2 Reconciled System-Wide Concurrency Protocol & Total Lock Acquisition Hierarchy
To guarantee strict serializability, eliminate time-of-check/time-of-use (TOCTOU) races, and prevent deadlocks across all Phase 1–5 subsystems (assessments, rewards catalog, reward redemptions, celebration wheel, integer balances, and mastery pipelines), child-scoped operations **must acquire locks in the following global monotonic hierarchy**:

```text
Order 1: Child Profile Row Lock (public.child_profiles)
   │     - Archival: FOR UPDATE
   │     - Child Mutations (draft, submit, review, redeem, fulfill, spin): FOR SHARE
   ▼
Order 2: Domain Entity & Catalog Locks
   │     - Assessment mutations (submit_assessment, verify_assessment, reject_assessment): public.assessments FOR UPDATE
   │     - Reward store redemption (redeem_store_reward): public.rewards FOR SHARE -> public.reward_redemptions FOR UPDATE
   │     - Reward fulfillment/cancellation (fulfill/cancel_reward_redemption): public.reward_redemptions FOR UPDATE
   │     - Celebration wheel (spin_reward_wheel): LOCK TABLE public.rewards IN SHARE MODE -> public.family_wheel_settings FOR SHARE
   ▼
Order 3: Economic Balance & Mastery Projections
   │     - Economic balance: public.child_balances FOR UPDATE (always locked by target child_id)
   │     - Mastery state: public.child_mastery_states FOR UPDATE (by child_id, learning_node_id)
   ▼
Order 4: Transaction-Level Advisory Locks (Pipelines)
         - Per-VLE serialization: pg_advisory_xact_lock(hashtext('vle_' || v_vle_id::text))
         - Per-child-node serialization: pg_advisory_xact_lock(hashtext('child_node_' || v_child_id::text || '_' || v_node_id::text))
```

1. **Order 1 — Child Profile Row Lock (`public.child_profiles`):**
   - **Child Archival Transaction (`archive_child_profile`):** Acquires `SELECT id, status FROM public.child_profiles WHERE id = p_child_id AND family_id = v_family_id FOR UPDATE`.
   - **Child Mutation Transactions (Draft Update, Submission, Verification, Rejection, Reward Redeem, Fulfill, Cancel, Wheel Spin):** Acquires `SELECT id, status FROM public.child_profiles WHERE id = v_child_id AND family_id = v_family_id FOR SHARE`. If `status != 'active'`, immediately aborts with `42501` before requesting Order 2, 3, or 4 locks.
   - *Concurrency property:* Multiple concurrent mutations on the same child hold `FOR SHARE` simultaneously without mutual contention. Archival (`FOR UPDATE`) waits until all active mutating transactions commit. If archival acquires `FOR UPDATE` first, any incoming mutation blocks on `FOR SHARE` and, upon unblocking, reads `status = 'archived'` and aborts cleanly.
2. **Order 2 — Domain Entity & Catalog Locks:**
   - Acquired only after Order 1 is held and child active status is verified:
     - Assessment review/submission: `SELECT * FROM public.assessments WHERE id = p_assessment_id FOR UPDATE`.
     - Reward store redemption: `SELECT * FROM public.rewards WHERE id = p_reward_id FOR SHARE`, then `INSERT INTO public.reward_redemptions ...`.
     - Reward fulfillment/cancellation: `SELECT * FROM public.reward_redemptions WHERE id = p_redemption_id FOR UPDATE`.
     - Celebration wheel: `LOCK TABLE public.rewards IN SHARE MODE`, then `SELECT * FROM public.family_wheel_settings WHERE family_id = v_family_id FOR SHARE`.
3. **Order 3 — Economic Balance & Mastery Projections:**
   - Acquired after Order 2 locks:
     - `SELECT * FROM public.child_balances WHERE child_id = v_child_id FOR UPDATE`.
     - `SELECT * FROM public.child_mastery_states WHERE child_id = v_child_id AND learning_node_id = v_node_id FOR UPDATE`.
   - Invariant: When locking multiple balance or mastery rows, rows must be acquired in ascending primary key order (`child_id ASC, learning_node_id ASC`).
4. **Order 4 — Transaction-Level Advisory Locks (Pipelines):**
   - Growth Engine: `pg_advisory_xact_lock(hashtext('vle_' || v_vle_id::text))`.
   - Learning Engine: `pg_advisory_xact_lock(hashtext('vle_' || v_vle_id::text))` strictly followed by `pg_advisory_xact_lock(hashtext('child_node_' || v_child_id::text || '_' || v_node_id::text))`.
   - Chained/nested pipeline calls (e.g., synchronous invocation of `process_verified_learning_event` during assessment verification) inherit the transaction's existing Order 1/2 row locks and proceed downward to Order 4 without acquiring locks in reverse order.
   - Total ordering rule: No procedure holding an Order 4 advisory lock is permitted to request an Order 1, 2, or 3 lock.

##### 4.3.2.2.3 Deadlock Freedom Guarantees & Architectural Boundaries
1. **Total Order Invariant:** No transaction holding an Order N lock is permitted to request an Order M lock where M < N.
2. **Acyclic Lock Dependency Graph:** Within the scope of child profile archival versus child-scoped operations, deadlocks between profile lifecycle management and operational mutations are eliminated because all operations acquire Order 1 locks prior to taking Order 2, 3, or 4 locks.
3. **Precise, Testable Engineering Guarantees (Replacing Absolute Claims):** The architecture provides the precise, testable guarantee that *all sanctioned child-scoped transactions strictly adhering to the Order 1 -> Order 2 -> Order 3 -> Order 4 sequence are provably cycle-free*. Concurrency regression tests in pgTAP execute parallel interleaved workloads under load to verify the empirical absence of PostgreSQL error `40P01` (`deadlock_detected`).

##### 4.3.2.2.4 Concurrent Archive and Commit Ordering Guarantees
1. **Case A: Mutation Transaction Commits Before Archival:**
   - Transaction TM (mutation) acquires `FOR SHARE` on `child_profiles` (active) -> acquires Order 2/3 locks -> commits.
   - Transaction TA (archival) attempts `FOR UPDATE` on `child_profiles`, blocks until TM commits -> unblocks, reads active child, archives profile, revokes device grants, commits.
   - *Outcome:* Mutation cleanly committed and recorded in immutable history; subsequent archival succeeds.
2. **Case B: Archival Transaction Commits Before Mutation:**
   - Transaction TA (archival) acquires `FOR UPDATE` on `child_profiles` -> sets `status = 'archived'`, revokes grants -> commits.
   - Transaction TB (mutation) attempts `FOR SHARE` on `child_profiles`, blocks until TA commits -> unblocks, reads `status = 'archived'` -> fails closed with `42501` without taking entity locks or modifying data.
   - *Outcome:* Zero late mutations commit after child archival.
3. **Unprocessed VLEs:**
   - If an assessment was verified before archival, generating a VLE, but Growth or Learning pipeline processing has not completed, background catch-up jobs (`catch_up_unprocessed_growth`, `catch_up_unprocessed_learning`) check `child_profiles.status = 'active'` at Order 1 before processing.
   - Unprocessed events for archived children remain frozen in their pending state without executing late XP/RP ledger credits or mastery mutations.

##### 4.3.2.2.5 Post-Archive Outbox Command Reconciliation (Explicit Deferral Contract)
1. **Mutating Replay Fails Closed:** A client attempting to replay a previously queued mutating RPC (`create_assessment_draft`, `submit_assessment`, `redeem_store_reward`, `spin_reward_wheel`) for an archived child profile receives an immediate `42501` exception. Replay never creates new ledger entries, wheel spins, or drafts.
2. **Explicit Deferral of Custom Read-Only Reconciliation RPCs:** To maintain strict pilot scope boundaries and avoid expanding the backend API surface with bespoke single-use endpoints, custom read-only post-archive command reconciliation RPCs are **EXPLICITLY DEFERRED** post-pilot.
3. **Client Outbox Quarantine Policy:**
   - When a mobile client outbox dispatcher receives a `42501` indicating the target child is archived, the command transitions to `quarantined_unknown_outcome`.
   - Quarantined commands remain safely preserved in local SQLite without automated network retry, preventing infinite retry loops or unexpected state mutation.
   - Local assessment drafts and evidence photos for the archived child are preserved locally in quarantine and are not silently deleted.
4. **Parental Historical Audit & Export:** Parents retain the ability to inspect and export all historical data for archived children through the authorized, schema-verified `export_family_data_json` RPC (§4.3.4) and adult historical reporting views.

##### 4.3.2.2.6 Executable PostgreSQL Concurrency & Lifecycle Regression Test Suite
A formal pgTAP / two-session concurrency test suite (`supabase/tests/database/`) verifies the locking protocol and lifecycle guards using two asynchronous database connections (Session 1: S1, Session 2: S2):
1. **Concurrent Submit vs. Archive:**
   - S1 (Archival): `BEGIN; SELECT public.archive_child_profile(v_child_id);` (holds transaction open before COMMIT).
   - S2 (Submission): Attempts `SELECT public.submit_assessment(p_assessment_id => v_assessment_id, p_expected_version => 1, p_command_id => gen_random_uuid());`. Verifies S2 blocks waiting for Order 1 lock.
   - S1: `COMMIT;`
   - S2: Unblocks. Verifies S2 raises SQLSTATE `42501` ('Child profile is archived'). Verifies assessment row remains `status = 'draft'` with zero side effects.
2. **Concurrent Verify vs. Archive:**
   - S1 (Verification): `BEGIN; SELECT public.verify_assessment(p_assessment_id => v_assessment_id, p_expected_version => 1, p_command_id => gen_random_uuid(), p_notes => 'Verified by parent');` (acquires Order 1 `FOR SHARE`, Order 2 `FOR UPDATE`).
   - S2 (Archival): Attempts `SELECT public.archive_child_profile(v_child_id);`. Verifies S2 blocks waiting for Order 1 exclusive lock.
   - S1: `COMMIT;`
   - S2: Unblocks, successfully archives profile. Verifies VLE, growth event, and ledger entry from S1 exist, but subsequent mutations are rejected.
3. **Concurrent Reward Redeem vs. Archive:**
   - S1: `SELECT public.archive_child_profile(v_child_id);` (commits).
   - S2: Attempts `SELECT public.redeem_store_reward(p_reward_id => v_reward_id, p_command_id => gen_random_uuid(), p_child_id => v_child_id);`.
   - Verifies immediate failure closed with SQLSTATE `42501` ('Child profile is archived'), no RP balance change, and no row created in `reward_redemptions`.
4. **Concurrent Celebration Wheel Spin vs. Archive:**
   - S1: `SELECT public.archive_child_profile(v_child_id);` (commits).
   - S2: Attempts `SELECT public.spin_reward_wheel(p_command_id => gen_random_uuid(), p_child_id => v_child_id);`.
   - Verifies immediate failure closed with SQLSTATE `42501` ('Child profile is archived'), no RP balance change, and zero rows inserted into `wheel_spins`.
5. **Direct UPDATE Lifecycle Bypass Rejection & Field Edit Preservation:**
   - S1 (Adult direct status edit): Attempts direct SQL `UPDATE public.child_profiles SET status = 'archived' WHERE id = v_child_id;`. Verifies failure closed with SQLSTATE `42501` ('Direct child profile lifecycle mutation is prohibited; call public.archive_child_profile()').
   - S2 (Adult direct reactivation edit): Attempts direct SQL `UPDATE public.child_profiles SET status = 'active' WHERE id = v_child_id;` on an archived profile. Verifies failure closed with SQLSTATE `LW011` / `42501` ('Archived child profile is immutable').
   - S3 (Adult valid profile edit): Attempts direct SQL `UPDATE public.child_profiles SET display_name = 'Updated Name' WHERE id = v_child_id;` on an active profile. Verifies successful update and updated `display_name`.
6. **High-Concurrency Deadlock Absence Verification:**
   - 100 interleaved concurrent executions of archival and operational mutations (submissions, verifications, redemptions, wheel spins) executed via parallel runners; verifies zero occurrences of PostgreSQL error `40P01` (`deadlock_detected`).

##### 4.3.2.2.7 Phase 6 Implementation Scope Notice
The transaction-level lock ordering hierarchy, RLS policy replacements, lifecycle trigger guards, and SECURITY DEFINER RPC hardening described in §4.3 are **formal design specifications for implementation during Phase 6.1 and 6.2 migrations**. They are not present in the frozen Phase 0–5 database migrations. PR #13 is strictly documentation-only.

---

#### 4.3.3 Operational Minimization, Legal Validation & Technical Constraints
- **Legal & Privacy Review Obligation:**
  > **MANDATORY LEGAL / PRIVACY REVIEW OBLIGATION:**
  > A formal legal and privacy review (covering COPPA verifiable parental consent, GDPR/CCPA data minimization, and lawful bases) **MUST be completed prior to onboarding external pilot families** and processing real children's personal data. Legal compliance cannot be deferred to commercial launch.
- **Distinction Between Operational Minimization and Statutory Erasure:**
  - *Internal Operational Minimization:* The 4-tier lifecycle **planned for Phase 6 implementation** (not yet in frozen runtime/RLS):
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
   - Drift schema v4 $\to$ v5 migration tests covering populated databases with drafts and pending commands; file-backed SQLite restart recovery plus evidence registration lost-response/concurrent submission, active/archived actor and RLS-hidden reconciliation tests.
4. **Design System & Widget Tests (`apps/mobile`):**
   - Semantics widget tree verification; minimum touch target size checks ($48 \times 48\text{ dp}$); dynamic type font scaling tests (200% scaling); reduced-motion instant wheel reveal tests.
5. **Database pgTAP Tests (`supabase/tests/database/`):**
   - Archived-child SELECT and SECURITY DEFINER RPC matrix tests: family-wide rewards/wheel settings, every child mutation, Growth/Learning catch-up, original-command replay, archive-vs-mutation concurrency and export. Verify side-effect counts and ensure all 438 existing pgTAP assertions remain green.

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
