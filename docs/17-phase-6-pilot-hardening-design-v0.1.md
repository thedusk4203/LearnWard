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
Phase 6 delivers **Pilot Hardening** for LearnWard, transforming the verified, sealed algorithmic and economic engine into a production-grade mobile client and backend capable of supporting real families in a 4-week closed pilot.

### 1.2 Pilot Exit Gate
Per `docs/05-pilot-plan-v0.1.md` and `docs/10-implementation-plan-v0.1.md` Section 19:
> **A small family pilot (20–50 families) can run for four consecutive weeks without engineering intervention for normal daily usage.**

Normal daily usage includes:
1. Children capturing assessment scores and evidence photos offline or online;
2. Parents reviewing and approving/rejecting submitted assessments;
3. Verified learning events automatically triggering Growth Engine calculations, append-only ledger entries, and EWMA mastery updates;
4. Children redeeming earned RP for guaranteed store rewards or spinning the celebration wheel within parent-configured daily caps;
5. Parents fulfilling pending reward claims and tracking longitudinal mastery progression;
6. Next Challenge candidate recommendations presenting clear, deterministic choices across recovery, refresh, developing, unlock, and explore.

### 1.3 Sub-Phase Decomposition
To ensure rigorous reviewability, Phase 6 is partitioned into three sequential slices:
- **Phase 6.1 — Offline Resilience, Bounded Outbox & Actor-Aware Command Recovery:** Durable SQLite command queues, actor identity binding, local containment lifecycle, camera permissions, and failure/retry presentation.
- **Phase 6.2 — Notifications, Privacy-Preserving Telemetry & Data Retention:** In-app coordination alerts, canonical VLPE derivation, 12/16 metric instrumentation, right-to-erasure soft archival, and data portability.
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
│  - Bounded Assessment Outbox & Idempotent Evidence Upload               │
│  - Local Security Boundary (per-class purge lifecycle)                  │
│  - iOS NSCameraUsageDescription & NSPhotoLibraryUsageDescription        │
│  - Reusable Failure & Retry UX Primitives                               │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Phase 6.2: Notifications, Privacy Telemetry & Data Retention            │
│  - In-App Coordination Notifications (Approval, Fulfillment)            │
│  - Provider-Agnostic Notification Port & Anti-Spam Invariants           │
│  - Canonical VLPE Engine (Growth + Learning processed)                  │
│  - 12/16 Authoritative Metric Queries & Minimal Telemetry Envelope      │
│  - Soft-Delete Archival & Parent Data Portability JSON RPC              │
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

### 3.2 Drift Database Schema Migration (v4 $\to$ v5)
The local database schema (`packages/learnward_data/lib/src/database/app_database.dart`) migrates to `schemaVersion = 5`.

#### 3.2.1 `pending_reward_commands` Schema Evolution
Adds `actor_user_id`, `actor_role`, and `schema_version`:
```dart
class PendingRewardCommands extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get operation => text()(); // 'redeemReward' | 'spinWheel' | 'fulfillReward' | 'cancelReward'
  TextColumn get commandId => text().unique()();
  TextColumn get familyId => text()();
  TextColumn get childId => text()();
  TextColumn get rewardId => text().nullable()();
  TextColumn get redemptionId => text().nullable()();
  TextColumn get cancellationReason => text().nullable()();
  TextColumn get actorUserId => text()(); // auth.uid() of authenticated caller
  TextColumn get actorRole => text()();   // 'owner' | 'parent' | 'child_device'
  IntColumn get schemaVersion => integer().withDefault(const Constant(1))();
  DateTimeColumn get createdAt => dateTime()();
}
```

#### 3.2.2 `local_assessment_drafts` Status Lifecycle Evolution
Adds `submission_status`, `retry_count`, and `last_error_message`:
```dart
class LocalAssessmentDrafts extends Table {
  TextColumn get localDraftId => text()();
  TextColumn get familyId => text()();
  TextColumn get childId => text()();
  TextColumn get createCommandId => text()();
  TextColumn get submitCommandId => text()();
  TextColumn get evidenceId => text().nullable()();
  TextColumn get serverAssessmentId => text().nullable()();
  TextColumn get subjectKey => text()();
  TextColumn get subject => text()();
  TextColumn get title => text()();
  TextColumn get assessmentType => text()();
  TextColumn get difficulty => text()();
  RealColumn get rawScore => real()();
  RealColumn get maxScore => real()();
  TextColumn get localPhotoPath => text().nullable()();
  TextColumn get entryContext => text()();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
  
  // Phase 6.1 additions:
  TextColumn get submissionStatus => text().withDefault(const Constant('draft'))();
  // 'draft' | 'uploading_evidence' | 'submitting_assessment' | 'failed_retryable' | 'terminal_error'
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get lastErrorMessage => text().nullable()();
  TextColumn get actorUserId => text()();
  TextColumn get actorRole => text()();

  @override
  Set<Column> get primaryKey => {localDraftId};
}
```

### 3.3 Actor-Aware Command Recovery Contract
When offline commands are replayed upon network reconnection:
1. **Identity Verification:** The command processor inspects `actorUserId` of each pending command row against the currently authenticated `supabase.auth.currentUser?.id`.
2. **Actor Mismatch Handling:**
   - If `actorUserId != activeSession.uid`, the command is **NOT** executed.
   - If the active session is a different adult in the same family, execution is paused and marked `pending_original_actor`.
   - If the device switched families, the command is immediately segregated or evicted according to the Local Security Boundary Policy.
3. **Revoked Device Handling:**
   - When the server returns `42501 (Device grant revoked or inactive)`, the client immediately clears the pending queue for that `childId` and transitions the app shell to unlinked state.

### 3.4 Local Data Security & Revocation Lifecycle
A blanket `clearAllTables()` wipe on sign-out is explicitly rejected. Local data classes possess distinct operational lifecycles:

| Local Data Class | Storage Engine | Adult Sign-Out | Identity Switch (Co-Parent) | Family Switch | Child Mode Exit | Paired Child Revoked | Account Deletion |
|---|---|---|---|---|---|---|---|
| **Parent PIN Hash & Salt** | `local_metadata_entries` | **Retained** (device security) | **Retained** | **Purged** | **Retained** | **Retained** | **Purged** |
| **Active Child Session** | `local_metadata_entries` | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** |
| **Assessment Drafts** | `local_assessment_drafts` | **Retained** (if same family) | **Retained** | **Purged** | **Retained** | **Purged for Child** | **Purged** |
| **Pending Reward Commands** | `pending_reward_commands`| **Paused** (actor bound) | **Paused** | **Purged** | **Retained** | **Purged for Child** | **Purged** |
| **Local Evidence Photos** | App Documents Dir | **Retained** (pending draft) | **Retained** | **Purged** | **Retained** | **Purged for Child** | **Purged** |
| **Cached Read Models** | SQLite Read Tables | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** | **Purged** |

### 3.5 Evidence Reliability & Camera Hardening
1. **Platform Permissions:** Add the required usage strings to `apps/mobile/ios/Runner/Info.plist`:
   ```xml
   <key>NSCameraUsageDescription</key>
   <string>LearnWard uses the camera to capture photos of worksheets, quizzes, and tests for verified learning progress.</string>
   <key>NSPhotoLibraryUsageDescription</key>
   <string>LearnWard accesses your photo library to allow selecting photos of completed academic work.</string>
   ```
2. **Client-Side Image Optimization:** Before uploading to Supabase Storage, raw camera images (often 5–15 MB) are resized client-side:
   - Maximum resolution: $1920 \times 1080$ pixels (maintaining aspect ratio);
   - Compression format: JPEG @ 80% quality;
   - Target payload size: $< 1.5\text{ MB}$;
   - Memory management: Byte stream processing to avoid out-of-memory exceptions on low-end devices.
3. **Idempotent Storage Resumption Protocol:**
   - Client generates deterministic storage object path: `{family_id}/{child_id}/{assessment_id}/{evidence_id}.jpg`.
   - On retry after network timeout, client issues a lightweight `headBucket/getObject` check. If object exists and byte size matches, client skips re-upload and directly proceeds to `register_assessment_evidence` RPC.

### 3.6 Failure & Retry Presentation Primitives
The design system introduces standard user-facing error and retry components in `packages/learnward_design_system`:
- `AppErrorStateWidget`: Standard card rendering user-friendly explanation, recovery guidance, and a primary retry button.
- `AppOfflineBanner`: Non-intrusive persistent status bar appearing when network is lost, indicating that work is saved locally.
- `RetryActionCard`: Dedicated card rendered in inbox and history screens for pending/recovering transactions (analogous to `ChildWheelScreen` retry banner).
- **Error Mapping Rule:** Raw database exceptions (`PostgrestException`, `SocketException`, `HttpException`, `LW...` database error codes) must never be displayed raw to users. All errors pass through `DomainErrorMapper.toUserFriendlyMessage(error)`.

---

## 4. Phase 6.2 — Notifications, Privacy-Preserving Telemetry & Data Retention

### 4.1 Pilot Notification Architecture
Notifications in LearnWard serve family coordination exclusively.

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

#### 4.1.3 Delivery Mechanism & Provider Abstraction
For the closed 4-week pilot:
- **In-App Realtime Channel:** Subscriptions to Supabase Realtime changes on `assessments` (where `status = 'pending_review'`) and `reward_redemptions` (where `status = 'fulfilled'`) update local badges and render in-app alert cards.
- **Provider-Agnostic Port:** `NotificationService` interface defined in `learnward_application`:
  ```dart
  abstract class NotificationService {
    Future<void> sendLocalNotification({required String title, required String body, required String route});
    Stream<NotificationPayload> get onNotificationTapped;
  }
  ```
  This isolates Flutter presentation from third-party push infrastructure (FCM/APNs), which remains deferred post-pilot.

#### 4.1.4 Deep-Link Routing Contract
Notifications carry structured payload routing:
- Parent approval: `learnward://family/{family_id}/review/{assessment_id}` $\to$ navigates directly to `ReviewAssessmentScreen`.
- Reward fulfilled: `learnward://family/{family_id}/child/{child_id}/rewards` $\to$ navigates directly to `ChildRedemptionHistoryScreen`.

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

### 4.3 Data Retention & Right-to-Erasure Architecture

#### 4.3.1 Resolving Immutable Ledger Tension
The database schema intentionally enforces immutable triggers on ledgers and verified events:
- `trg_prevent_verified_learning_event_mutation`
- `trg_prevent_assessment_review_event_mutation`
- `trg_prevent_growth_event_mutation`
- `trg_prevent_xp_ledger_mutation`
- `trg_prevent_rp_ledger_mutation`
- `trg_enforce_wheel_spins_immutability`
- `trg_prevent_learning_evidence_events_mutation`
- `trg_prevent_learning_processing_events_mutation`
- `trg_prevent_mastery_state_revisions_mutation`

**Architectural Decision:** To respect parental privacy requests without violating immutable ledger integrity, Phase 6 implements **Strategy C: Soft-Delete Archival + Strict RLS Revocation**:
1. When a parent requests child profile deletion:
   - `child_profiles.status` transitions to `'archived'`.
   - All active device grants for that child transition to `'revoked'`.
   - RLS policies immediately deny all SELECT/INSERT/UPDATE access to archived child profiles for child devices and parent client roles.
   - Associated storage evidence photos in `assessment-evidence` are permanently deleted from Supabase Storage.
   - Immutable numerical ledger rows (`xp_ledger`, `rp_ledger`, `verified_learning_events`) remain intact on disk for cryptographic mathematical integrity, stripped of active tenancy references.
2. When a family requests account termination:
   - Adult auth account is disabled.
   - All child profiles transition to `'archived'`.
   - Evidence photos are deleted.

#### 4.3.2 Parental Data Portability RPC
To ensure parents can retrieve their child's academic record before archival:
```sql
create or replace function public.export_family_data_json(p_family_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
-- Exports full JSON archive of assessments, mastery states, and ledger entries for verified family adult
$$;
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
   - Drift schema v4 $\to$ v5 migration tests; file-backed SQLite restart recovery tests for outbox queues.
4. **Design System & Widget Tests (`apps/mobile`):**
   - Semantics widget tree verification; minimum touch target size checks ($48 \times 48\text{ dp}$); dynamic type font scaling tests (200% scaling); reduced-motion instant wheel reveal tests.
5. **Database pgTAP Tests (`supabase/tests/database/`):**
   - Verify RLS on archived child profiles, data export RPC, and command receipt operational retention. All 438 existing pgTAP assertions must remain green.

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
