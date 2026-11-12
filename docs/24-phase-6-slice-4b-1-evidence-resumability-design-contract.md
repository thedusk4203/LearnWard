# LearnWard — Phase 6 Slice 4B-1: Evidence Resumability & Storage 409 Reconciliation

**Document status:** DESIGN DRAFT FOR INDEPENDENT APPROVAL — NOT IMPLEMENTED / NOT FROZEN  
**Canonical repository path:** `docs/24-phase-6-slice-4b-1-evidence-resumability-design-contract.md`  
**Reviewed baseline:** `main` at `a9cbee7dc2e47c6f792d8adfa7d45cbabb90d90d` (PR #30 merge)  
**Prerequisites:** Slice 4B-0 local evidence safety, Slice 4A-0 Drift v6 CAS foundation, frozen Phase 6 server RPC/RLS/storage contracts.  
**Release:** No pilot, production, background dispatcher enablement or release signing authorization.

## 0. Evidence-Based Starting Point

The following behaviors have been verified against repository source at the baseline:

- `SupabaseAssessmentEvidenceStorage.uploadEvidence` (`packages/learnward_data/lib/src/repositories/supabase_assessment_evidence_storage.dart`) uses `upsert: false` but treats Storage HTTP 409/duplicate responses as success without inspecting remote bytes.
- `UploadAssessmentEvidence` (`packages/learnward_application/lib/src/use_cases/upload_assessment_evidence.dart`) calls `storage.deleteEvidence` after *any* metadata-registration exception, even when remote outcome is ambiguous.
- `SubmitAssessmentDraft` (`packages/learnward_application/lib/src/use_cases/submit_assessment_draft.dart`) persists partial state through `LocalDraftStore.saveLocalDraft`, but does not persist authoritative evidence registration ID, byte hash, or frozen evidence file path; `saveLocalDraft` is currently unconditional UPSERT.
- `AssessmentEvidenceStorage` has upload, signed URL and delete, but no authorized byte-download method. `SupabaseAssessmentRepository` already has `getAssessment` and `listEvidenceForAssessment`.
- `register_assessment_evidence` in `supabase/migrations/20261105120000_phase6_2_child_archive_concurrency.sql` checks `assessment.status='draft'` **before** its existing-row-by-path idempotency query. Re-registration after a remote submission may fail with `LW109` despite successful prior registration.
- Drift v6 already supplies `localCompressedPhotoPath`, `sha256Checksum`, `serverEvidenceId`, `evidenceId`, `serverAssessmentId`, `createCommandId`, `submitCommandId`, `actorUserId`, `actorRole`, `dispatchState`, `submissionStatus`, `retryCount`, `nextAttemptAt`, `leaseToken`, and `leaseExpiresAt`. There is no evidence-specific draft lease API yet.
- Local physical file deletion remains conservatively disabled by Slice 4B-0; preserve this guarantee.
- Storage bucket permits JPEG/PNG up to 10 MiB. The client picker can return PNG. Never claim every existing upload is JPEG.

## 1. Purpose, Scope and Non-Goals

**Purpose:** Preserve the exact authorized evidence bytes and immutable intent across interruptions, safely reconcile Storage upload and DB registration outcomes, and resume an assessment submission without duplicate or destructive side effects.

**In scope:** existing app assessment capture and submission UI; `LocalDraftStore` and Drift v6 operations without migration; application-level evidence orchestration; Storage port/adapter and test fakes; safe server read reconciliation; deterministic error classification; UI outcome messaging; repeatable restart/race tests.

**Out of scope:** new SQL/RPC/RLS/storage policies or tables, Drift schema changes or historical migration changes, automatic physical garbage collection, global background processing, new parent export/destructive recovery UI (4C-1), signing or pilot activation. Do not reuse `PendingRewardCommand` as an assessment draft journal or modify reward/wheel CAS contracts.

## 2. Security and Durability Invariants (I01–I16)

**I01 — Byte identity:** A single evidence intent is defined by one stable `evidenceId`, one canonical local byte snapshot, exact MIME, byte count and SHA-256. Hash bytes **actually sent**, not a different original photo. Same-size/different-content is a conflict.

**I02 — Stable IDs:** `localDraftId`, `createCommandId`, `submitCommandId`, `evidenceId`, `serverAssessmentId` once learned, verified `actorUserId`, family/child and existing cancellation-independent assessment attributes may not be silently regenerated/rebound during retry.

**I03 — No remote overwrite:** Keep `upsert: false`; never auto-overwrite, remove, move, change extension, or mint a different evidence UUID when a path already exists.

**I04 — No uncertain cleanup:** Remove the unconditional `deleteEvidence` compensation path. Never call remote Storage delete on a 409, registration error, response loss, unknown actor, stale session, RLS-null result or ambiguous outcome. No local physical unlink in this slice.

**I05 — Positive byte proof:** A 409/duplicate, ambiguous upload outcome, or evidence-row reconciliation is successful only after authorized download of the private object and exact SHA-256 **and** byte-length comparison. A metadata match or object-exists boolean is insufficient. A normal acknowledged upload of the frozen bytes may be accepted without a second download, provided its exact input and success response are recorded durably.

**I06 — Fail closed on missing visibility:** HTTP 401/403, RLS 0-row, timeout, 404 or network errors do not prove the server object/row never existed; preserve local bytes and IDs. 404 may not justify minting a new path/ID or deletion.

**I07 — Auth & Authoritative Session Validation:** Authoritative identity and authorization must be obtained exclusively from `AuthSessionPort.validateForMutation()` and assessment-scoped target authorization, NEVER from cached UI providers (such as `currentUserIdProvider` or `activeChildModeProvider`). Validate the live session, actor ID, family, child, and session generation before each server-mutating stage (`create_assessment_draft`, Storage byte upload, `register_assessment_evidence`, `submit_assessment`) and before any remote reconciliation that reads private bytes. Revalidate session generation across asynchronous boundaries; if the session generation changes, is expired, or is revoked, fail closed immediately with zero remote dispatch. Preserve the original bound actor; require positive non-null `actorUserId` provenance matching the validated actor (`prior.actorUserId != null && prior.actorUserId == context.userId`), and never allow a different authenticated user to adopt a prior actor's command or an unbound (`actorUserId == null`) draft. On validation failure, preserve original IDs, journal state, and local evidence bytes intact (`R31-08`).

**I08 — Crash before dispatch:** Write durable state and stable IDs before each network mutation, with `possiblyDispatched` marker before calls with an uncertain commit boundary. For a new assessment submitted directly without Save Draft, the complete durable journal row and canonical evidence snapshot must be committed to SQLite before acquiring a lease claim or issuing the first `createDraft` RPC; if persistence fails at any point, fail closed with zero network dispatches.

**I09 — Race fencing:** One lease owner per `localDraftId` across two independent SQLite connections; transitions after a network response must be lease-token-fenced. Late responses cannot overwrite the new owner's state. Never mutate a command owned by another actor/family.

**I10 — Editing isolation:** Existing `saveLocalDraft` cannot overwrite a claimed or remote-dispatched draft, immutable IDs or evidence snapshot. Use an explicit expected-state/CAS API for normal edits and recovery transitions; do not rely only on `updatedAt` or an unconditional UPSERT. All `unknownLegacy`, unbound-actor (`actorUserId == null`), and quarantined drafts derive a strictly read-only disposition in memory upon deserialization without rewriting SQLite, and all storage writes to them are rejected until an authorized recovery/export flow is invoked.

**I11 — Server authoritative:** Existing frozen server RPCs alone create, register and submit assessments. Client does not infer server commit from local messages or claim a receipt the RPC does not expose.

**I12 — RPC order:** A `LW109` from registration after assessment leaves draft is not evidence that registration never happened. Reconcile by authorized SELECT for both assessment state and evidence row first.

**I13 — No duplicate submission:** Preserve the original `submitCommandId`. Only submit with `expectedVersion: 1` when `1` is positively verified as the original expected version; on version change (`version > 1`), never silently substitute or adopt a newer server version and never issue a speculative submission when the original expected version cannot be reconstructed safely from the frozen v6 schema.

**I14 — Conservative retention:** Keep canonical local bytes and recoverable journal information through uncertain outcomes and even confirmed success until an independently approved safe-GC/export lifecycle. Do not route through `deleteLocalDraft`/`deleteDraftSafely` as a shortcut that loses recovery metadata.

**I15 — Compatibility:** Drift `schemaVersion` stays 6. If extending `DraftSubmissionStatus`, ensure old/unknown wire values cannot be silently parsed as editable `draft`. Prefer existing states plus typed machine-readable recovery detail if compatible; demonstrate serialization roundtrip and fail-closed interpretation. No schema/RPC changes.

**I16 — Secrets/privacy:** No full paths, child content, private bytes, access tokens, signed URLs or raw image in logs, telemetry or exceptions. Hash may be logged only if explicitly needed and redacted/minimized.

## 3. Durable Intent and Canonical Byte Preparation

1. **Capture and freeze:** Use immutable output bytes from the picker or a single approved deterministic encoder. The existing picker can emit JPEG or PNG; preserve PNG as PNG. Do **not** assume JPEG transcoding where no codec exists. If future JPEG normalization is desired, specify/test a stable encoder before changing the persisted byte contract.
2. **Write once:** Create a new canonical app-private file with exclusive non-overwriting creation and durability checks. Re-read, verify its byte length and SHA-256 before binding. Preserve original `localPhotoPath` and previous file; `localCompressedPhotoPath` identifies the *frozen upload bytes*. After restart, recompute the hash, reject a missing/truncated/mutated file. Do not silently fall back to mutable original bytes.
3. **Intent binding:** Persist SHA-256 lowercase hex in `sha256Checksum`; persist original `evidenceId`, `createCommandId`, `submitCommandId`, original actor and local path. Determine MIME from validated file signature/recorded suffix; never trust an extension alone. Because no dedicated MIME/size columns exist, derive these strictly from the canonical immutable file on every resume and validate against Storage path/DB evidence metadata. Do not smuggle opaque state into unrelated columns.
4. **Path:** Construct `${familyId}/${childId}/${serverAssessmentId}/${evidenceId}.jpg|png` only after `serverAssessmentId` is positively known; verify the exact path components and extension. Do not generate new UUIDs on retries.
5. **Existing drafts:** Require an explicit migration-in-place strategy for drafts with `localPhotoPath` but no frozen snapshot/hash. Reconcile their dispatch history and actor provenance first. For `possiblyDispatched`, `unknownLegacy`, or any draft lacking positive actor provenance (`actorUserId == null`), do not silently adopt the draft under the current user, do not create a canonical snapshot or upload ID, and do not allow local edits; retain and quarantine read-only pending authorized recovery/export. Only definitely `neverDispatched` drafts in `draft` status with non-null verified original actor provenance (`actorUserId != null && actorUserId == authenticatedActorId`) and no server IDs may stage a one-time canonical snapshot under actor and CAS guards.

## 4. Drift v6 Transaction and Lease Contract

Extend `LocalDraftStore` with clearly named operations rather than calling general-purpose UPSERT for recovery:

- `registerOrUpdateDraftIfUnchanged(expected, desired)` — atomic insert/CAS update using all identity, command, file, actor, version and recovery fields necessary to block stale edits. For new draft registration (including direct submit without Save Draft), `expected` is null and `desired` must include verified non-null `actorUserId`, `familyId`, `childId`, stable `localDraftId`, and initial draft/neverDispatched state. Rejects any edit to `unknownLegacy`, unbound-actor (`actorUserId == null`), leased, dispatched, or quarantined rows. Return a typed result: `saved`, `conflict`, `unsafeState`, `missing`.
- `acquireDraftClaim(localDraftId, actorUserId, familyId, childId, now, leaseDuration)` — atomic single-winner claim on an existing durable draft row if non-null positive `draft.actorUserId == actorUserId`, family/child/status/dispatch eligibility, due time and no active unexpired lease match; return unique opaque lease token or no claim. Requires the durable row to exist in SQLite before claim can succeed (`R31-06`). The `actorUserId` passed to this claim MUST be the verified `context.userId` from `AuthSessionPort.validateForMutation()` (`R31-08`).
- `markDraftStageAndDispatch(...)` — token + actor + state + unexpired lease CAS *before* a remote call; preserve original IDs and byte binding; set `uploadingEvidence`/`submittingAssessment` and `possiblyDispatched` as appropriate.
- `persistServerAssessmentId`, `persistServerEvidenceId`, `scheduleDraftRetry`, `quarantineDraftOutcome`, `completeDraftSubmission` — each token-fenced, read/compare immutable target and byte binding; no unconditional overwrite. `persistServerEvidenceId` persists the DB-generated `public.assessment_evidence.id` (`row.id`) into `serverEvidenceId` (or verifies `serverEvidenceId == row.id` if already set) while preserving the distinct client Storage-path `evidenceId`. Never mark authoritative ID unless server evidence positively matches.
- `releaseDraftClaim` and `resumeDraftClaimAfterExpiry` — fenced release/reclaim with bounded backoff; a stale token cannot delete or finalize after takeover.
- **Derived Read-Only Quarantine:** Drafts with `actorUserId == null` or unknown wire status derive a fail-closed quarantine disposition in memory upon reading the SQLite row without rewriting the database record; all write operations (`registerOrUpdateDraftIfUnchanged`, `acquireDraftClaim`, `saveLocalDraft`) strictly reject mutations on these rows, preserving historical bytes and metadata through app restarts (`R31-07`).

Use existing 30 columns without changing schema. Any operation that cannot prove the expected pre-state must return a typed conflict rather than rewriting the row. Clearly document which transitions change `dispatchState`, `submissionStatus`, `retryCount`, `nextAttemptAt` and `lastErrorMessage`; model unknown outcome separately from permanent hash mismatch. All in-memory/test store implementations must have equivalent atomic behavior (with deterministic barriers), not just mocked happy-path states.

**Important subtlety:** SQLite lease does not guarantee server-side idempotency for a Storage upload or evidence registration lacking command receipts. Stability of path, strict remote-byte reconciliation, and server RPC contract are still mandatory.

## 5. Evidence Stage State Machine and Decision Table

The orchestrator resumes at the earliest **unverified** stage, never by restarting and assuming remote absence.

| Stage / observation | Required action | Durable result | Forbidden behavior |
|---|---|---|---|
| Unbound actor (`actorUserId == null`) or `unknownLegacy` | Retain journal and local bytes, fail closed, disable edits and dispatch | Read-only quarantine (`LW4B1:UNBOUND_ACTOR_PROVENANCE` / `unknownLegacy`) | Adopt under current user; edit; snapshot; upload |
| Local bytes absent / hash different | Retain journal, fail closed, mark manual recovery | Non-replayable until correct bytes restored | Read arbitrary replacement bytes / upload |
| Fresh upload acknowledged (frozen bytes) | Persist acknowledged outcome, proceed to authorized metadata registration | Stage progress under lease | Unconditional remote delete on later failure |
| Storage 409 or uncertain response | Authorized download of exact private path, hash and length comparison | Matching = verified, mismatching = conflict quarantine, unreadable = unknown/retry/pause | Treat 409 as success; overwrite; new UUID |
| Storage download 401/403/404/RLS-hidden/timeout | Retain local bytes; retry only after safe authorization/state check; escalate if persistent | Unknown outcome, not negative proof | Assume absent, delete or bypass Storage RLS |
| Registration succeeds and response is verified | Validate `(assessmentId, familyId, storagePath, mediaType, fileSizeBytes)`; if `serverEvidenceId != null` require `row.id == serverEvidenceId`, else learn `serverEvidenceId = row.id` under lease | Evidence registered (`serverEvidenceId = row.id`, preserving distinct `evidenceId`) | Require `row.id == evidenceId`; assume registered on exception |
| Registration response lost | Authorized read of assessment and evidence row matched by `(assessmentId, familyId, storagePath)`; compare MIME, byte count, Storage byte hash; verify or learn `serverEvidenceId = row.id` | Exact match = confirmed (`serverEvidenceId = row.id`); `row.id` mismatch = conflict quarantine; incomplete visibility = unknown | Require `row.id == evidenceId`; retry with different path/ID |
| RPC `LW109` after server assessment non-draft | Read assessment and evidence row by `(assessmentId, familyId, storagePath)`; verify remote bytes and `row.id` | Exact match = registration confirmed; absent/ambiguous = manual unresolved | Repeatedly call RPC requiring draft |
| Server evidence path exists with differing byte hash or conflicting `row.id` | Persist explicit conflict, disable automatic retries and edits | Quarantined/manual review; preserve local bytes | Upsert, delete, rotate evidence UUID |
| Server draft still `draft` at `version == 1` and evidence not confirmed registered | After positive auth and sufficient reconciliation, retry original registration for same path | Preserve original intent | Recreate assessment under new UUID |
| Server draft in `draft` status with `version > 1` | Original expected version cannot be reconstructed safely in v6; do not call `submit_assessment` | Read-only quarantine (`LW4B1:UNRECONSTRUCTABLE_EXPECTED_VERSION`) | Adopt `remote.version` or speculatively submit with version 1 |
| Assessment submission / replay (`submitCommandId`) | Verify assessment content and registered evidence; call `submit_assessment` with original `submitCommandId` and justified `expectedVersion: 1` | RPC return = `confirmedCommitted`; `LW101`/`LW107` (post-Step-6) = no receipt at that check -> quarantine; `42501` (Steps 3/4/6) = ambiguous -> preserve unknown outcome (`LW4B1:AMBIGUOUS_42501_OUTCOME`) | Treat `42501`/archival/revocation as proof submission never committed; duplicate submit |
| Concurrent editor / another actor / lease conflict | Return in-flight/conflict/pause; no RPC | No mutation except fenced disposition | Force update / steal active lease |
| Auth invalid, session expired, or session-generation changed | Revalidate via `AuthSessionPort.validateForMutation()`; halt execution immediately if invalid or changed (`R31-08`) | Preserve local journal, IDs, and evidence bytes intact (`LW4B1:WAITING_ORIGINAL_ACTOR` or transient pause) | Rely on cached UI providers; dispatch with invalid/stale session; delete local bytes |
| Definitely terminal invalid input | Preserve evidence, record typed terminal state | Manual remediation required | Delete local photo by cleanup |

Represent *retryable transient*, *unknown commit*, *verified byte mismatch*, *actor waiting*, *terminal policy denial*, and *confirmed committed* as distinct typed application outcomes. If persisted wire enums stay unchanged, define a canonical versioned `lastErrorMessage` marker mapping and tests; do not parse arbitrary free-text to drive destructive/replay decisions. A conflict state must never satisfy `canAutoSubmit`.

## 6. Registration and Submission Reconciliation Rules

**6.1 Authorized positive proof & Evidence ID namespaces:** Client `evidenceId` (`LocalAssessmentDraft.evidenceId`) is the immutable UUID embedded in the Storage object path `${familyId}/${childId}/${serverAssessmentId}/${evidenceId}.(jpg|png)`. Server `serverEvidenceId` (`LocalAssessmentDraft.serverEvidenceId`) is the distinct primary key `public.assessment_evidence.id` generated by Postgres (`DEFAULT gen_random_uuid()`). Never require `row.id == evidenceId`. Authorized positive proof requires:
1. Current authenticated actor/grant verified via `AuthSessionPort.validateForMutation()` with non-null `draft.actorUserId == context.userId` and verified matching `sessionGeneration` (`R31-08`).
2. Assessment `id == serverAssessmentId`, `familyId`, `childId`, and `createdByUserId == actorUserId` match the journal.
3. Server evidence row matched by `(row.assessmentId == serverAssessmentId, row.familyId == familyId, row.storagePath == expectedStoragePath)` also matches `row.mediaType == canonicalMediaType` and `row.fileSizeBytes == canonicalFileSizeBytes`.
4. Remote Storage object bytes at `expectedStoragePath` pass authorized download and match `sha256Checksum` and byte length.
5. If `serverEvidenceId != null` is already persisted locally, `row.id == serverEvidenceId` MUST hold (otherwise quarantine as `LW4B1:EVIDENCE_ID_MISMATCH`); if `serverEvidenceId == null`, learn `row.id` from the positively reconciled row and persist `serverEvidenceId = row.id` via lease-token-fenced CAS (`persistServerEvidenceId`).

**6.2 Unknown != absent:** PostgREST `maybeSingle() == null`, empty evidence lists, inaccessible Storage bytes (HTTP 401/403/404/timeout), or SQLSTATE `42501` returned before receipt inspection (such as auth revocation at Step 3 or child archival at Step 4 of `submit_assessment`) do not prove a prior command or object never committed. Never use a null SELECT, `42501`, auth revocation, child archival, or transport failure as negative proof of prior submission or as permission to change identity, delete data, or declare final absence. Preserve original intent, local file, and IDs without performing unauthorized repeat mutations.

**6.3 Registration:** While assessment is authoritatively in `draft` and full identity/byte conditions hold, the original `register_assessment_evidence` may safely be retried for the same exact `storagePath`. Its idempotent `storage_path` lookup is behind the `status = 'draft'` guard (`LW109`), so after the assessment becomes non-draft always reconcile via `listEvidenceForAssessment` matched on `(assessmentId, familyId, storagePath)` + Storage byte verification rather than calling `register_assessment_evidence` again.

**6.4 Submission & Original Expected Version:**
- In the frozen schema, `public.assessments.version` defaults to `1` on `create_assessment_draft`, is not modified by `register_assessment_evidence`, and is incremented by `update_assessment_draft` (which has zero callers in the assessment submission pipeline and MUST NOT be called by the Slice 4B-1 orchestrator). Drift v6 has no column storing post-update server versions.
- Therefore, `expectedVersion: 1` is the original justified expected version if and only if the assessment was created via `create_assessment_draft` and never modified by an external `update_assessment_draft`.
- Before calling `submit_assessment`, read `getAssessment`:
  - If the server row has `status == 'draft'` and `version == 1` with matching immutable content and verified evidence, submit with `expectedVersion: 1` and original `submitCommandId`.
  - If the server row has `status == 'draft'` and `version > 1` (or any content mismatch), the original expected version cannot be reconstructed safely from the frozen v6 schema. Do **not** adopt `remote.version` and do **not** issue a speculative `submit_assessment` call; quarantine the draft in `LW4B1:UNRECONSTRUCTABLE_EXPECTED_VERSION` (or `LW4B1:VERSION_CONFLICT` on content mismatch).
  - If the server row has `status != 'draft'` and all immutable content fields and registered evidence match the local draft, replaying `submit_assessment(p_assessment_id, p_expected_version => 1, p_command_id => submitCommandId)` under the original actor tests Step 6 (`command_receipts` lookup, which executes before Step 7 version check and Step 8 draft-status check without mutating non-draft rows). A positive return proves `submitCommandId` committed; `LW101`/`LW107` establishes only that no matching receipt existed for `submitCommandId` at that Step 6 check (quarantine as `LW4B1:AMBIGUOUS_SUBMIT_OUTCOME`); and `42501` is ambiguous because Steps 3–4 (auth/active-child) precede Step 6 (preserve unknown outcome as `LW4B1:AMBIGUOUS_42501_OUTCOME`).

**6.5 End state:** Persist `confirmedCommitted` outcome and successful server IDs under lease; retain original local evidence file. Reuse existing UI semantics for completed versus quarantined drafts without exposing unsafe deletion or speculative success.

## 7. Work Packages and Strict PR Boundary

- **WP0 (Design-only PR):** Record this contract, exact source inventory, all invariants, stage table, compatibility choice, acceptance matrix and frozen boundaries; no runtime changes. Independent approval required before implementation.
- **WP1 — Safe Storage Port:** Add authenticated private-object byte download and strict 409/uncertain-outcome reconciliation, typed result/error handling, size cap; `upsert:false` and no blind delete. Update fake storage.
- **WP2 — Durable Snapshot & Draft CAS:** Canonical file snapshot/hash and stable IDs, file-backed CAS/lease operations, recovery states, parity with in-memory stores and restart resilience.
- **WP3 — Orchestrator:** Refactor `UploadAssessmentEvidence`, `SubmitAssessmentDraft` and all production UI call sites to use a single durable staged state machine. Reconcile `LW109`, version drift and server read ambiguity. No raw upload without durable intent for 4B-1 production paths.
- **WP4 — UI and Recovery:** Show retryable, waiting-original-actor, transient, ambiguous and conflict states accurately, preserving user evidence; only authorized foreground retries in scope. No new background feature flag activation.
- **WP5 — Tests & CI:** Full acceptance matrix, SQLite multi-connection deterministic barriers, fake Storage byte assertions, server integration and RLS tests, Android/iOS builds. Independent source-review rounds; do not merge implementation without approval.
- **WP6 — After implementation merge:** Exact-head merge, post-merge main CI, docs-only freeze PR and separate approval. No pilot/release.

One implementation PR is acceptable only if all work packages are coherently testable and focused on 4B-1; otherwise split sequentially into storage safety foundation and durable orchestrator PRs, each reviewed. Do not mix in 4C-0 authentication restructuring or 4C-1 garbage collection/export UX.

## 8. Acceptance Matrix — B1-01 through B1-30

All tests must assert server call counts, persisted state, local file retention and no forbidden remote delete, in addition to return types.

| ID | Deterministic scenario / required assertion |
|---|---|
| B1-01 | New JPEG picker bytes frozen once, correct hash and length survive restart. |
| B1-02 | PNG evidence preserved with correct MIME, path extension and byte binding (no fake JPEG conversion). |
| B1-03 | File missing, truncated or mutated since snapshot fails closed with no upload. |
| B1-04 | Canonical path uses stable family/child/assessment/evidence IDs; never rotates UUID on retry. |
| B1-05 | Successful upload followed by successful registration stores validated DB-generated `serverEvidenceId` (`row.id != evidenceId`) while preserving the distinct Storage-path `evidenceId`. |
| B1-06 | 409 with same remote bytes and size reconciles and succeeds after authorized download. |
| B1-07 | 409 with same length but different digest quarantines with no overwrite, delete or UUID rotation. |
| B1-08 | 409 with different length fails closed and preserves both objects and local file. |
| B1-09 | 409 followed by download 401/403/RLS denial remains unknown and retains evidence. |
| B1-10 | 409 followed by remote 404 does not authorize destructive cleanup or identity rotation. |
| B1-11 | Upload committed but response timed out; later byte download proves exact match; no duplicate upload. |
| B1-12 | Registration committed (`row.id != evidenceId`) but response lost; authorized SELECT matched by `(assessmentId, familyId, storagePath)` plus MIME, size and exact object-byte SHA-256 match learns `serverEvidenceId = row.id` via lease-fenced CAS (or enforces `row.id == serverEvidenceId` if already persisted, quarantining on mismatch). |
| B1-13 | Registration committed, assessment became non-draft, `LW109` on retry; read-only reconciliation succeeds without re-registering. |
| B1-14 | Non-draft assessment with no positively proven evidence row remains unresolved; no re-register. |
| B1-15 | Assessment/evidence read yields RLS-null; no inferred absence, no deletion, no new command IDs. |
| B1-16 | Authoritative auth & actor verification: validate exclusively via `AuthSessionPort.validateForMutation()` (rejecting stale UI provider values from `currentUserIdProvider`/`activeChildModeProvider`); account switch from Actor A to Actor B causes safe pause (`waitingOriginalActor`) and zero RPC until Actor A returns; unbound drafts (`actorUserId == null`) derive `LW4B1:UNBOUND_ACTOR_PROVENANCE` read-only quarantine without adopting the active user; expired sessions, revoked family/child permissions, or session-generation change between staging and dispatch halt execution with zero RPC, preserving original IDs, journal state, and evidence bytes intact (`R31-08`). |
| B1-17 | Child archived before dispatch or after committed submit whose response was lost (Step 4 `42501` before Step 6 receipt check): fail closed, preserve unknown outcome (`LW4B1:AMBIGUOUS_42501_OUTCOME`), local evidence and IDs without declaring submission absent or issuing unauthorized RPC. |
| B1-18 | Crash & auth boundary resilience: crash before upload marker, after marker, during upload, after upload and before registration all resume deterministically; direct submit without prior Save Draft commits durable journal row and canonical snapshot via authoritative `validateForMutation()` before any remote call; session expired, revoked, or session generation invalidated between canonical snapshot creation and remote call aborts dispatch immediately, preserving local journal, stable IDs and evidence bytes without orphaned server state (`R31-06`, `R31-08`). |
| B1-19 | Crash after evidence registration (`row.id != evidenceId`) but before ID persistence reconciles exact same row by `(assessmentId, familyId, storagePath)` and bytes, persisting `serverEvidenceId = row.id`. |
| B1-20 | Crash after submit request / lost submit response preserves `submitCommandId`: idempotent return under original actor confirms submission; replay returning `42501` when actor revoked or child archived before Step 6 receipt lookup preserves unknown outcome (`LW4B1:AMBIGUOUS_42501_OUTCOME`) rather than declaring submission absent. |
| B1-21 | Multi-connection same-draft contention with explicit barriers dispatches at most one stage RPC while lease held; direct submit without prior Save Draft enforces atomic journal insertion and single-winner claim acquisition across concurrent taps/connections, preventing duplicate lease claims or duplicate draft creation RPCs (`R31-06`). |
| B1-22 | Expired lease takeover: stale worker cannot overwrite successor result or delete journal. |
| B1-23 | Concurrent UI editor / autosave cannot overwrite immutable IDs/hash/evidence path or active lease; `unknownLegacy` and all quarantined drafts are strictly read-only in both UI and `LocalDraftStore` (rejecting text/score/evidence edits while preserving `NULL` IDs and bytes). |
| B1-24 | Cross-family, cross-child and cross-assessment Storage or evidence row mismatch rejects without mutation. |
| B1-25 | Server assessment version changed: only submit with `expectedVersion: 1` when verified; if remote `draft` has `version > 1`, quarantine as `LW4B1:UNRECONSTRUCTABLE_EXPECTED_VERSION` without adopting `remote.version` or speculatively submitting; if `LW101`/`LW107` occurs after Step 6 receipt check, quarantine without overgeneralizing. |
| B1-26 | Existing `unknownLegacy`, `possiblyDispatched` without checksum, and unbound-actor (`actorUserId == null`) drafts derive a read-only quarantine disposition in memory without rewriting the underlying SQLite row; persist through app restart as strictly read-only, never adopt the active actor, never snapshot mutable bytes, and reject all edits and remote RPC dispatches (`R31-07`). |
| B1-27 | Transient retry backoff is bounded, persisted, and never creates a new evidence/command identity. |
| B1-28 | Confirmed submission retains local photo and durable receipt metadata; no eager physical or remote deletion. |
| B1-29 | Real Postgres/Storage RLS tests: authorized download, forbidden actor, draft/non-draft registration order, Storage no-upsert/no-delete on uncertainty. |
| B1-30 | All existing 4B-0 B01–B05, 4A-1 A01–A24, 4A-2 A2-01–A2-20 and full CI pass; Drift schema v6 and Supabase migrations/RLS/RPC have zero changes. |

**Test environment requirements:** file-backed SQLite with independent connections and `Completer` barriers; injected clock/jitter; fake Storage with exact byte blobs and asynchronous failure barriers; authorized real Supabase integration for RLS/Storage and `LW109` (never replace with mocks only). Confirm direct test IDs for B1-01–B1-30 in final PR evidence; never claim a test passed unless executed.

## 9. Open Design Decisions That Must Be Resolved *in the design PR*, Not During Coding

1. **Strict local status serialization:** Choose a version-compatible representation for verified conflict / unknown outcome / actor pause without unknown wire state silently becoming `draft`; document migration-safe handling and compatibility tests. This is not permission to change Drift schema.
2. **Write protection:** Determine precisely which `saveLocalDraft` call sites may be moved to CAS and how in-flight captures are prevented from overwriting a remote-bound snapshot.
3. **Assessment submit outcome attribution:** Document what existing server receipt/read proves for `submitCommandId`, and which cases must remain ambiguous rather than inferred as success.
4. **File durability:** Choose exact platform-safe write/flush/identity checks for canonical bytes under Android/iOS; never use a rename that can overwrite a different file without exclusive guarantees.
5. **Draft identity for legacy rows:** Spell out safe migration-in-place vs quarantined cases based on `dispatchState`, actual local bytes and actor provenance.

If any decision cannot be implemented safely using only the frozen contracts, return a focused design blocker and a non-destructive fallback. No silent server/schema expansion.

### 9.1 D1 Resolution — Strict Local Status Serialization & Derived Read-Only Quarantine (`R31-07`)

- **Zero Schema Change & Zero Destructive Rewrites:** Drift `schemaVersion => 6` and the 30 columns of `LocalAssessmentDrafts` (`packages/learnward_data/lib/src/database/local_assessment_drafts.dart`) remain unchanged.
- **Wire Values & Derived Fail-Closed Deserialization (`R31-07`):**
  - Persisted `submission_status` SQL values remain restricted to the 5 existing wire tokens (`draft`, `uploading_evidence`, `submitting_assessment`, `failed_retryable`, `terminal_error`).
  - `DraftSubmissionStatus.fromString(String value)` (`packages/learnward_application/lib/src/ports/command_lifecycle_states.dart:L80-L85`) MUST change its fallback from `DraftSubmissionStatus.draft` to `DraftSubmissionStatus.terminalError` (fail-closed).
  - In `AppDatabase._mapRowToDraft` (`packages/learnward_data/lib/src/database/app_database.dart:L642-L678`), if `row.submissionStatus` is not one of the 5 known wire values, map `submissionStatus` to `DraftSubmissionStatus.terminalError` and prefix `lastErrorMessage` with `LW4B1:UNKNOWN_WIRE_STATUS:<raw>`. This mapping is a **derived in-memory fail-closed projection** upon reading the row, NOT a durable SQLite rewrite. The underlying SQLite row remains unmodified so that newer or corrupted data is never overwritten destructively (`B1-30`).
- **Derived Read-Only Quarantine for Unbound Actor Provenance (`R31-07`):**
  - Similarly, when `row.actorUserId == null`, `AppDatabase._mapRowToDraft` projects the draft with a derived quarantine disposition (`LW4B1:UNBOUND_ACTOR_PROVENANCE`) without mutating or rewriting the underlying SQLite record. The stored row's `actor_user_id` remains `NULL`, and its original file paths, command IDs, and scores are preserved intact.
  - Because this quarantine is derived purely upon row deserialization, it survives app restarts deterministically without requiring an asynchronous write or actor session.
- **Structured `LW4B1:` Envelope & `DraftRecoveryDisposition`:**
  - `lastErrorMessage` uses a deterministic machine-readable prefix `LW4B1:<CODE>:<sanitized_message>` paired with `(submissionStatus, dispatchState)` to derive a typed `DraftRecoveryDisposition` enum on `LocalAssessmentDraft`:
    - `editableDraft`: `submissionStatus == draft && dispatchState == neverDispatched && actorUserId != null` and no `LW4B1:` quarantine code.
    - `inFlightStage`: `submissionStatus` in `{uploadingEvidence, submittingAssessment}` with active lease.
    - `retryScheduled`: `submissionStatus == failedRetryable && dispatchState == neverDispatched` (`LW4B1:TRANSIENT_PRE_DISPATCH`).
    - `verificationPending`: `submissionStatus == failedRetryable && dispatchState == possiblyDispatched` (`LW4B1:NEEDS_REMOTE_VERIFICATION`).
    - `waitingOriginalActor`: `submissionStatus == failedRetryable` and `LW4B1:WAITING_ORIGINAL_ACTOR`.
    - `quarantinedEvidenceConflict`: `submissionStatus == terminalError` and `LW4B1:` in `{EVIDENCE_CONFLICT, EVIDENCE_ID_MISMATCH}`.
    - `quarantinedRegistrationUnresolved`: `submissionStatus == terminalError` and `LW4B1:REGISTRATION_UNRESOLVED_REMOTE_RETAINED`.
    - `quarantinedUnknownOutcome`: `submissionStatus == terminalError` (or `dispatchState == unknownLegacy` / derived `actorUserId == null`) and `LW4B1:` in `{UNKNOWN_WIRE_STATUS, VERSION_CONFLICT, UNRECONSTRUCTABLE_EXPECTED_VERSION, AMBIGUOUS_SUBMIT_OUTCOME, AMBIGUOUS_42501_OUTCOME, LEGACY_IN_FLIGHT_UNVERIFIED_BYTES, UNBOUND_ACTOR_PROVENANCE}`.
    - `terminalPolicyDenial`: `submissionStatus == terminalError` and `LW4B1:TERMINAL_POLICY_DENIAL`.
    - `confirmedSubmitted`: `dispatchState == confirmedCommitted`.
- **Deletion & Auto-Submit Guards (`LocalAssessmentDraft`):**
  - `isUnsafeToDelete` (`packages/learnward_application/lib/src/ports/local_draft_store.dart:L99-L106`) MUST return `true` when any of the following hold: `isLeased`, `isLegacyUnknown`, `actorUserId == null`, `submissionStatus != DraftSubmissionStatus.draft` (explicitly including `DraftSubmissionStatus.terminalError`), `dispatchState != CommandDispatchState.neverDispatched`, `serverAssessmentId != null`, `serverEvidenceId != null`, `localCompressedPhotoPath != null`, or `lastErrorMessage` begins with `LW4B1:`.
  - `canAutoSubmit` MUST return `false` for `waitingOriginalActor`, `quarantinedEvidenceConflict`, `quarantinedRegistrationUnresolved`, `quarantinedUnknownOutcome`, `terminalPolicyDenial`, `confirmedSubmitted`, `actorUserId == null`, and `isLegacyUnknown`.

### 9.2 D2 Resolution — Write Protection, Direct Submit Staging & Authoritative Auth Verification (`R31-06`, `R31-07`, `R31-08`)

- **Direct Submit Staging & Production Call-Site Migration (`R31-06`, `R31-08`):**
  Current `AddAssessmentScreen` supports submitting a newly created assessment directly without first clicking "Save Draft", as well as submitting an already-saved local draft. The submission contract explicitly defines the pre-dispatch lifecycle for both paths, using authoritative authentication and target authorization:
  1. `AddAssessmentScreen._saveLocalDraft()` (`apps/mobile/lib/features/assessments/presentation/add_assessment_screen.dart:L412`):
     - Replace `store.saveLocalDraft(draft)` with `store.registerOrUpdateDraftIfUnchanged(expected: prior, desired: draft, now: clock.now())`.
     - Authoritative actor identity must come from `await authSessionPort.validateForMutation()`, obtaining `ValidatedActorContext context`. Never use cached UI providers (`currentUserIdProvider`, `activeChildModeProvider`) as proof of authentication (`R31-08`).
     - For new draft (`prior == null`), `desired.actorUserId` is set to `context.userId`.
     - For existing draft (`prior != null`), require `prior.actorUserId != null && prior.actorUserId == context.userId`. If mismatched or `prior.actorUserId == null`, reject any save. Also reject when `prior` is `unknownLegacy`, leased, dispatched, or quarantined.
  2. `AddAssessmentScreen._submitAssessment()` (`apps/mobile/lib/features/assessments/presentation/add_assessment_screen.dart:L433-L609`):
     - Replace the legacy unconditional `store.saveLocalDraft(localDraft)` call with the strict pre-submission staging sequence below.
     - **Path A — Direct submit of a newly created assessment without prior Save Draft (`prior == null`):**
       a. *Authoritative Actor & Assessment Target Verification (`R31-08`):*
          - Call `await authSessionPort.validateForMutation()`. If `null`, expired (`!context.isValidAt(clock.now())`), or revoked, fail closed immediately. Do NOT rely on cached `ref.read(currentUserIdProvider)` or `ref.read(activeChildModeProvider)` as authorization evidence.
          - Positively verify assessment-scoped target authorization for `(familyId, childId)`: verify that `context.userId` is an active adult in `familyId` or an active child device for `(familyId, childId)`, and that `child_profiles(id = childId, family_id = familyId, status = 'active')` is active. (Do NOT misuse reward-specific authorization operations for assessments). If verification yields definitive denial (not a family member, child archived, grant revoked), fail closed with zero RPC. If unverified due to transient network failure, fail closed without dispatching.
          - Capture `initialSessionGeneration = context.sessionGeneration`.
       b. *Form Validation & Content Freezing:* Validate `_formKey.currentState!.validate()`. Freeze immutable content attributes (`subjectKey`, `subject`, `title`, `type`, `difficulty`, `score`, `occurredAt`, `entryContext`).
       c. *Canonical Evidence Snapshot:* If evidence is selected, create a canonical snapshot via `LocalEvidenceFileStore.saveCanonicalEvidenceSnapshot(localDraftId: _localDraftId, bytes: verifiedBytes)` (`D4`). If byte validation or file write fails, fail closed with user error and execute zero journal writes or remote calls.
       d. *Stable UUID Allocation:* Allocate stable `_localDraftId`, `createCommandId ??= generateUuid()`, `submitCommandId ??= generateUuid()`, and `evidenceId = hasEvidence ? (prior?.evidenceId ?? generateUuid()) : null`.
       e. *Durable Journal Registration:* Insert the initial journal row via `store.registerOrUpdateDraftIfUnchanged(expected: null, desired: initialDraft, now: clock.now())` with `actorUserId = context.userId`, `actorRole = context.role`, `submissionStatus = draft`, `dispatchState = neverDispatched`, frozen content, and canonical evidence path/checksum. If insertion fails, terminate immediately.
       f. *Atomic Lease Acquisition:* Only after the durable row exists in SQLite, call `store.acquireDraftClaim(localDraftId: _localDraftId, actorUserId: context.userId, familyId: familyId, childId: childId, now: clock.now(), leaseDuration: duration)`. If claim fails (lease conflict, concurrent tap), fail closed.
       g. *Session-Generation Revalidation & Pre-Dispatch Marker (`R31-08`):*
          - Verify `authSessionPort.currentSessionGeneration == initialSessionGeneration`. If changed or signed out across the asynchronous snapshot/registration boundaries, abort immediately with zero remote calls.
          - Using the lease token, transition via `store.markDraftStageAndDispatch(...)` to set `submissionStatus` to `uploadingEvidence` (if evidence present) or `submittingAssessment` and `dispatchState = possiblyDispatched` *before* issuing any remote RPC.
     - **Path B — Submission of an existing locally saved draft (`prior != null`):**
       a. *Authoritative Actor & Session Check (`R31-08`):*
          - Call `await authSessionPort.validateForMutation()`, obtaining `context`. If `null` or invalid, fail closed immediately.
          - Require `prior.actorUserId != null && prior.actorUserId == context.userId` with matching target `familyId` and `childId`. Reject if `prior` is `unknownLegacy`, unbound (`actorUserId == null`), foreign-owned, leased, or quarantined.
          - Preflight-verify assessment-scoped target authorization for `(familyId, childId)`.
          - Capture `initialSessionGeneration = context.sessionGeneration`.
       b. *Durable CAS Update:* If form fields or evidence changed, persist updates via `store.registerOrUpdateDraftIfUnchanged(expected: prior, desired: updatedDraft, now: clock.now())`. If `prior` has mutable `localPhotoPath` but no canonical snapshot, stage canonical snapshot and bind via CAS before claim acquisition.
       c. *Atomic Lease Acquisition:* Acquire exclusive lease claim via `store.acquireDraftClaim(...)` using `context.userId`.
       d. *Session-Generation Revalidation & Pre-Dispatch Marker (`R31-08`):*
          - Verify `authSessionPort.currentSessionGeneration == initialSessionGeneration`. If changed across asynchronous CAS updates, abort immediately.
          - Transition via `store.markDraftStageAndDispatch(...)` to set `possiblyDispatched` before the first remote call.
     - **Per-Mutation Session Revalidation & Fail-Closed Invariant (`R31-08`):**
       - Before each remote mutation (`create_assessment_draft`, Storage byte upload, `register_assessment_evidence`, `submit_assessment`) and before authorized Storage byte download, revalidate that `authSessionPort.currentSessionGeneration == initialSessionGeneration`. If the session generation changed, session expired, or permissions were revoked across asynchronous boundaries, abort immediately without dispatching the next RPC, preserving local journal state, stable IDs, and evidence bytes intact.
       - Under both paths, **no remote RPC may execute without durable intent committed to SQLite and positive authoritative authentication**. If any persistence, session check, or claim step fails, the workflow fails closed with zero network mutations.
  3. `SubmitAssessmentDraft.call()` (`packages/learnward_application/lib/src/use_cases/submit_assessment_draft.dart:L55, L87, L126`):
     - Receives the verified durable draft, `ValidatedActorContext`, and active lease token.
     - Revalidates session generation (`currentSessionGeneration == context.sessionGeneration`) before each remote RPC call (`repository.createDraft`, `uploadUseCase`, `repository.submitAssessment`).
     - Replaces `saveLocalDraft` at `L55` and `L87` with token-fenced `markDraftStageAndDispatch` and `persistServerAssessmentId`.
     - Replaces `deleteLocalDraft` at `L126` with token-fenced `completeDraftSubmission` (setting `dispatchState = confirmedCommitted`, clearing lease, preserving the journal row and canonical file on disk per `I14` and `B1-28`, while `ChildModeScreen` filters `confirmedCommitted` rows from the editable unsent-drafts list).
  4. `AppDatabase.saveLocalDraft` (`packages/learnward_data/lib/src/database/app_database.dart:L361`) and `InMemoryLocalDraftStore.saveLocalDraft`:
     - Harden inside a transaction so that if a row with `localDraftId` already exists and holds an active lease (`leaseToken != null && leaseExpiresAt > now`), OR is `possiblyDispatched` / `confirmedCommitted`, OR is `unknownLegacy`, OR has `actorUserId == null` (`R31-07`), OR is in any `LW4B1:` quarantine state, OR already has a non-null `actorUserId`, `localCompressedPhotoPath`, `sha256Checksum`, `serverAssessmentId`, or `serverEvidenceId` that the caller attempts to overwrite or clear, it throws a typed `DraftWriteConflictException` instead of performing an unconditional UPSERT (`I10`, `B1-16`, `B1-23`).
- **UI In-Flight & Read-Only Quarantine Guard (`AddAssessmentScreen`):**
  - Disable `_pickEvidence`, `_removeEvidence`, form field edits, "Save Draft", and "Submit" whenever the draft is leased, in-flight (`uploadingEvidence` / `submittingAssessment`), `possiblyDispatched`, `confirmedCommitted`, `waitingOriginalActor`, `unknownLegacy`, unbound (`actorUserId == null`), or in any `LW4B1:` quarantined state (`R31-04`, `R31-07`, `B1-23`).

### 9.3 D3 Resolution — Evidence ID Namespaces, Original Expected Version & Submit Outcome Attribution

- **Distinct Evidence UUID Namespaces (`R31-01`):**
  - In `supabase/migrations/20261101000000_phase2_secure_assessment_capture.sql:L41-L51` and `20261105120000_phase6_2_child_archive_concurrency.sql:L385-L415`, `public.assessment_evidence.id` is generated by the database (`DEFAULT gen_random_uuid()`), whereas client `LocalAssessmentDraft.evidenceId` is the UUID embedded in `storage_path` (`${familyId}/${childId}/${serverAssessmentId}/${evidenceId}.(jpg|png)`).
  - Never require `row.id == evidenceId`.
  - Match the server evidence row via `(row.assessmentId == serverAssessmentId, row.familyId == familyId, row.storagePath == expectedStoragePath)` and verify `row.mediaType == canonicalMediaType`, `row.fileSizeBytes == canonicalFileSizeBytes`, and the downloaded Storage object's byte length and SHA-256 (`sha256(remoteBytes) == sha256Checksum`).
  - If `serverEvidenceId != null` is already persisted on the local draft, additionally require `row.id == serverEvidenceId` (otherwise quarantine as `LW4B1:EVIDENCE_ID_MISMATCH`); if `serverEvidenceId == null`, learn `row.id` from the positively reconciled row and persist `serverEvidenceId = row.id` via lease-token-fenced CAS (`persistServerEvidenceId`, `B1-05`, `B1-12`, `B1-19`).
- **Verified SQL Ordering & Original Expected Version (`R31-02`, `R31-05`):**
  - Under RLS (`supabase/migrations/20261105000000_phase6_1_child_lifecycle_rls.sql:L233-L297`), direct `SELECT` on `public.command_receipts` and `public.assessment_review_events` is restricted to `private.is_active_family_adult(family_id)` (paired child devices receive 0 rows on direct table reads).
  - In `public.submit_assessment(p_assessment_id, p_expected_version, p_command_id)` (`supabase/migrations/20261105120000_phase6_2_child_archive_concurrency.sql:L480-L600`):
    - Step 1 checks `auth.uid() != null` (`LW001`).
    - Step 2 resolves `(family_id, child_id)` from `public.assessments` (`LW105`).
    - Step 3 checks `is_active_family_adult` or `is_active_child_device` (`42501` — **before** receipt lookup).
    - Step 4 locks `public.child_profiles` `FOR SHARE` with `status = 'active'` (`42501` — **before** receipt lookup).
    - Step 5 locks `public.assessments` `FOR UPDATE`.
    - Step 6 looks up `public.command_receipts` by `p_command_id` (if found and `operation == 'submit' && resource_id == p_assessment_id && actor_user_id == auth.uid()`, returns `v_assessment` idempotently; if mismatched, raises `42501`).
    - Step 7 checks `v_assessment.version != p_expected_version` (`LW101`).
    - Step 8 checks `v_assessment.status != 'draft'` (`LW107`).
    - Step 9 updates `status = 'pending_review', version = version + 1`.
  - `public.assessments.version` defaults to `1` (`create_assessment_draft`), is never incremented by `register_assessment_evidence`, and is only incremented during draft state by `update_assessment_draft` (which has zero callers in the assessment submission pipeline and is never invoked by Slice 4B-1). Because Drift v6 has no column to store post-update server versions, `expectedVersion: 1` is the only reconstructable original expected version.
- **Outcome Attribution Matrix (`R31-02`, `R31-05`):**
  1. Pre-check `getAssessment` and `listEvidenceForAssessment`:
     - Verify assessment `id == serverAssessmentId`, `familyId`, `childId`, `createdByUserId == actorUserId`, and all immutable content fields (`subjectKey`, `subject`, `title`, `type`, `difficulty`, `score.rawScore`, `score.maxScore`, `occurredAt`, `entryContext`) match the local draft, and verify the registered evidence row (`row.storagePath == expectedStoragePath`, `row.id == serverEvidenceId` if set) and remote Storage SHA-256.
     - If any content field mismatches, do not call `submit_assessment`; quarantine as `LW4B1:VERSION_CONFLICT` (`DraftSubmissionStatus.terminalError`).
     - If `remoteAssessment.status == 'draft'` and `remoteAssessment.version > 1`, the original expected version cannot be reconstructed safely using the frozen v6 schema. Do **not** adopt `remoteAssessment.version` and do **not** call `submit_assessment`; quarantine in `LW4B1:UNRECONSTRUCTABLE_EXPECTED_VERSION` (`DraftSubmissionStatus.terminalError`, `B1-25`).
  2. When `remoteAssessment.status == 'draft' && remoteAssessment.version == 1` (or `remoteAssessment.status != 'draft'` with matching content/evidence, where Step 8 prevents any new submission and the call acts strictly as a Step 6 receipt probe), invoke `submitAssessment(assessmentId: serverAssessmentId, expectedVersion: 1, commandId: submitCommandId)` under the original authenticated `actorUserId`:
     - **Positive RPC return:** Confirms `submitCommandId` committed (either via Step 6 idempotent receipt match or Step 9–11 fresh commit); transition to `confirmedCommitted` (`B1-13`, `B1-20`).
     - **`LW101` or `LW107`:** Reached at Steps 7–8 after Step 6 found no `command_receipts` row for `submitCommandId` at that check. Do not overgeneralize this into proof about unrelated commands or future concurrent outcomes; quarantine the draft as `LW4B1:VERSION_CONFLICT` / `LW4B1:AMBIGUOUS_SUBMIT_OUTCOME` (`DraftSubmissionStatus.terminalError`) and retain all local bytes and IDs (`B1-14`, `B1-25`).
     - **`42501` (or `LW001`, `LW105`, HTTP 401/403, RLS 0-row, timeout):** Ambiguous because Steps 3–4 (auth revocation / child archival) execute **before** Step 6 receipt lookup and raise `42501` even if `submitCommandId` already committed prior to response loss. Never interpret `42501`, auth revocation, child archival, RLS filtering, or transport failure as negative proof of prior submission; preserve original intent, local canonical file, and all IDs in `LW4B1:AMBIGUOUS_42501_OUTCOME` without performing repeat mutations (`B1-17`, `B1-20`).

### 9.4 D4 Resolution — Platform-Safe Canonical File Durability & Checksum Binding

- **`saveCanonicalEvidenceSnapshot` Contract (`apps/mobile/lib/features/assessments/services/local_evidence_file_store.dart`):**
  1. Validate byte length (`1 <= bytes.length <= 10 * 1024 * 1024`) and magic-byte header signature:
     - JPEG (`FF D8 FF` prefix) -> `mediaType = 'image/jpeg'`, `ext = 'jpg'`.
     - PNG (`89 50 4E 47 0D 0A 1A 0A` prefix) -> `mediaType = 'image/png'`, `ext = 'png'`.
     - Reject any other byte signature with `EvidenceStorageException` (never trusting file extensions, `I02`, `B1-29`).
  2. Resolve `<app_documents>/draft_evidence/${localDraftId}_canonical_${timestamp}_${uniqueSuffix}.$ext`, verify canonical directory confinement via `p.isWithin`, and create the file using `file.createSync(exclusive: true)` (up to 5 unique-suffix attempts; never using `File.rename` that can overwrite an existing POSIX target).
  3. Write bytes via `RandomAccessFile` (`writeFromSync(bytes)` + `flushSync()` + `closeSync()`).
  4. Re-read the newly written file from disk (`file.readAsBytesSync()`), verify `reRead.length == bytes.length`, compute `sha256.convert(reRead).toString()` (lowercase 64-character hex), and verify exact equality with `sha256.convert(bytes).toString()`.
  5. Return `CanonicalEvidenceSnapshot(canonicalPath, sha256Checksum, fileSizeBytes, mediaType)` for atomic CAS binding into `localCompressedPhotoPath` and `sha256Checksum`.
- **Dependency Alignment:** Declare `crypto: ^3.0.6` (already locked at `3.0.8` in workspace `pubspec.lock` and used by `apps/mobile`) in `packages/learnward_application/pubspec.yaml` and `packages/learnward_data/pubspec.yaml`.

### 9.5 D5 Resolution — Draft Identity & Migration Rules for Legacy Rows (`R31-03`, `R31-04`, `R31-07`)

- **Case A — `dispatchState == unknownLegacy`:**
  - Read-only quarantine (`isLegacyUnknown == true`). Derived in memory without rewriting SQLite. Never stage a canonical snapshot for remote upload, never mint replacement command/evidence UUIDs, never auto-submit, and disallow all UI/storage edits (`AddAssessmentScreen` and `registerOrUpdateDraftIfUnchanged` reject mutations, preserving `unknownLegacy`, `NULL` IDs as `NULL`, and physical bytes untouched until authorized recovery/export in Slice 4C-1; `R31-04`, `B1-23`).
- **Case B — Unbound Actor Provenance (`actorUserId == null`) Across Any `dispatchState` (`R31-07`):**
  - Read-only quarantine via derived in-memory projection (`LW4B1:UNBOUND_ACTOR_PROVENANCE`). Implemented purely as an in-memory fail-closed disposition in `_mapRowToDraft` / `LocalAssessmentDraft` whenever `row.actorUserId == null`, without executing any SQLite update or rewriting the persisted record. Never assume the currently authenticated actor authored an unbound draft, never backfill `actorUserId` from the active session on an existing row, never stage a canonical snapshot or generate remote command/evidence UUIDs, and disallow all edits and remote calls (`R31-03`, `R31-07`, `B1-16`, `B1-26`). All historical metadata, command IDs (`NULL` preserved as `NULL`), and physical evidence bytes remain unmodified on disk. The quarantine survives process restart deterministically because it is re-derived on every read.
- **Case C — `dispatchState == possiblyDispatched` (or `serverAssessmentId != null` / `serverEvidenceId != null`) with `localPhotoPath != null || evidenceId != null` but missing `localCompressedPhotoPath` or `sha256Checksum`:**
  - Read-only quarantine (`LW4B1:LEGACY_IN_FLIGHT_UNVERIFIED_BYTES`, `DraftSubmissionStatus.terminalError`). Never snapshot mutable `localPhotoPath` retroactively to satisfy a remote 409 or registration check (`I01`, `B1-26`).
- **Case D — `dispatchState == neverDispatched && submissionStatus == draft && serverAssessmentId == null && serverEvidenceId == null && actorUserId != null` with `localPhotoPath != null` and missing `localCompressedPhotoPath` or `sha256Checksum`:**
  - Eligible for one-time foreground migration-in-place **only** when positive actor provenance is verified (`draft.actorUserId != null && draft.actorUserId == context.userId` via `AuthSessionPort.validateForMutation()`, with matching active `familyId`/`childId`): read and magic-byte-validate `localPhotoPath`, write an immutable canonical snapshot via `saveCanonicalEvidenceSnapshot`, bind `localCompressedPhotoPath` + `sha256Checksum` + stable UUIDs (`createCommandId ?? newUuid`, `submitCommandId ?? newUuid`, `evidenceId ?? newUuid`), and persist via `registerOrUpdateDraftIfUnchanged(expected: prior, desired: migrated)` before acquiring a claim (`R31-03`, `R31-08`). If `draft.actorUserId != context.userId`, pause as `waitingOriginalActor` with zero mutation (`B1-16`).

**Design Blocker Assessment:** Zero frozen-boundary blockers. All 5 design decisions (`D1–D5`), invariants (`I01–I16`), work packages (`WP0–WP6`), and acceptance tests (`B1-01–B1-30`) are implementable within Drift schema v6 and the frozen Phase 6 server/RLS/Storage contracts.

## 10. Merge and Release Gates

**Design approval:** docs-only PR, exact-head CI green, independent source review; implementation not permitted before sign-off.  
**Implementation approval:** B1-01–B1-30 + frozen-slice regressions, authentic Storage/Postgres security proof, deterministic races, complete CI; no unreviewed merge.  
**Post-merge freeze:** successful `main` CI followed by docs-only freeze receipt, separate review.  
**Production/pilot:** CLOSED pending 4C-0, 4C-1, Slices 5 and 6, real device and signing validation.