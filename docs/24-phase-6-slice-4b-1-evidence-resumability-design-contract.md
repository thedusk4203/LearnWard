# LearnWard — Phase 6 Slice 4B-1: Evidence Resumability & Storage 409 Reconciliation

**Document status:** DESIGN DRAFT FOR INDEPENDENT APPROVAL — NOT IMPLEMENTED / NOT FROZEN  
**Proposed canonical repository path:** `docs/24-phase-6-slice-4b-1-evidence-resumability-design-contract.md` (check filename availability before creating)  
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

**I07 — Auth:** Validate the current authenticated actor/grant, family, child and session generation before each server-mutating stage and before any remote reconciliation that reads private bytes. Preserve the original bound actor; a different authenticated adult cannot adopt a prior actor's command.

**I08 — Crash before dispatch:** Write durable state and stable IDs before each network mutation, with `possiblyDispatched` marker before calls with an uncertain commit boundary.

**I09 — Race fencing:** One lease owner per `localDraftId` across two independent SQLite connections; transitions after a network response must be lease-token-fenced. Late responses cannot overwrite the new owner's state. Never mutate a command owned by another actor/family.

**I10 — Editing isolation:** Existing `saveLocalDraft` cannot overwrite a claimed or remote-dispatched draft, immutable IDs or evidence snapshot. Use an explicit expected-state/CAS API for normal edits and recovery transitions; do not rely only on `updatedAt` or an unconditional UPSERT.

**I11 — Server authoritative:** Existing frozen server RPCs alone create, register and submit assessments. Client does not infer server commit from local messages or claim a receipt the RPC does not expose.

**I12 — RPC order:** A `LW109` from registration after assessment leaves draft is not evidence that registration never happened. Reconcile by authorized SELECT for both assessment state and evidence row first.

**I13 — No duplicate submission:** Preserve the original `submitCommandId`. On version change, check server state, target identity, evidence and command outcome; never silently substitute a newer version and resubmit modified work.

**I14 — Conservative retention:** Keep canonical local bytes and recoverable journal information through uncertain outcomes and even confirmed success until an independently approved safe-GC/export lifecycle. Do not route through `deleteLocalDraft`/`deleteDraftSafely` as a shortcut that loses recovery metadata.

**I15 — Compatibility:** Drift `schemaVersion` stays 6. If extending `DraftSubmissionStatus`, ensure old/unknown wire values cannot be silently parsed as editable `draft`. Prefer existing states plus typed machine-readable recovery detail if compatible; demonstrate serialization roundtrip and fail-closed interpretation. No schema/RPC changes.

**I16 — Secrets/privacy:** No full paths, child content, private bytes, access tokens, signed URLs or raw image in logs, telemetry or exceptions. Hash may be logged only if explicitly needed and redacted/minimized.

## 3. Durable Intent and Canonical Byte Preparation

1. **Capture and freeze:** Use immutable output bytes from the picker or a single approved deterministic encoder. The existing picker can emit JPEG or PNG; preserve PNG as PNG. Do **not** assume JPEG transcoding where no codec exists. If future JPEG normalization is desired, specify/test a stable encoder before changing the persisted byte contract.
2. **Write once:** Create a new canonical app-private file with exclusive non-overwriting creation and durability checks. Re-read, verify its byte length and SHA-256 before binding. Preserve original `localPhotoPath` and previous file; `localCompressedPhotoPath` identifies the *frozen upload bytes*. After restart, recompute the hash, reject a missing/truncated/mutated file. Do not silently fall back to mutable original bytes.
3. **Intent binding:** Persist SHA-256 lowercase hex in `sha256Checksum`; persist original `evidenceId`, `createCommandId`, `submitCommandId`, original actor and local path. Determine MIME from validated file signature/recorded suffix; never trust an extension alone. Because no dedicated MIME/size columns exist, derive these strictly from the canonical immutable file on every resume and validate against Storage path/DB evidence metadata. Do not smuggle opaque state into unrelated columns.
4. **Path:** Construct `${familyId}/${childId}/${serverAssessmentId}/${evidenceId}.jpg|png` only after `serverAssessmentId` is positively known; verify the exact path components and extension. Do not generate new UUIDs on retries.
5. **Existing drafts:** Require an explicit migration-in-place strategy for drafts with `localPhotoPath` but no frozen snapshot/hash. Reconcile their dispatch history first. For `possiblyDispatched`/`unknownLegacy`, do not silently create a different canonical snapshot or upload ID; retain and quarantine pending proof. For definitely never-dispatched drafts, a one-time canonical snapshot can be staged under actor and CAS guards.

## 4. Drift v6 Transaction and Lease Contract

Extend `LocalDraftStore` with clearly named operations rather than calling general-purpose UPSERT for recovery:

- `registerOrUpdateDraftIfUnchanged(expected, desired)` — atomic insert/CAS update using all identity, command, file, actor, version and recovery fields necessary to block stale edits. Return a typed result: `saved`, `conflict`, `unsafeState`, `missing`.
- `acquireDraftClaim(localDraftId, actorUserId, familyId, childId, now, leaseDuration)` — atomic single-winner claim if actor/family/child/status/dispatch eligibility, due time and no active unexpired lease match; return unique opaque lease token or no claim.
- `markDraftStageAndDispatch(...)` — token + actor + state + unexpired lease CAS *before* a remote call; preserve original IDs and byte binding; set `uploadingEvidence`/`submittingAssessment` and `possiblyDispatched` as appropriate.
- `persistServerAssessmentId`, `persistServerEvidenceId`, `scheduleDraftRetry`, `quarantineDraftOutcome`, `completeDraftSubmission` — each token-fenced, read/compare immutable target and byte binding; no unconditional overwrite. Never mark authoritative ID unless server evidence positively matches.
- `releaseDraftClaim` and `resumeDraftClaimAfterExpiry` — fenced release/reclaim with bounded backoff; a stale token cannot delete or finalize after takeover.

Use existing 30 columns without changing schema. Any operation that cannot prove the expected pre-state must return a typed conflict rather than rewriting the row. Clearly document which transitions change `dispatchState`, `submissionStatus`, `retryCount`, `nextAttemptAt` and `lastErrorMessage`; model unknown outcome separately from permanent hash mismatch. All in-memory/test store implementations must have equivalent atomic behavior (with deterministic barriers), not just mocked happy-path states.

**Important subtlety:** SQLite lease does not guarantee server-side idempotency for a Storage upload or evidence registration lacking command receipts. Stability of path, strict remote-byte reconciliation, and server RPC contract are still mandatory.

## 5. Evidence Stage State Machine and Decision Table

The orchestrator resumes at the earliest **unverified** stage, never by restarting and assuming remote absence.

| Stage / observation | Required action | Durable result | Forbidden behavior |
|---|---|---|---|
| Local bytes absent / hash different | Retain journal, fail closed, mark manual recovery | Non-replayable until correct bytes restored | Read arbitrary replacement bytes / upload |
| Fresh upload acknowledged (frozen bytes) | Persist acknowledged outcome, proceed to authorized metadata registration | Stage progress under lease | Unconditional remote delete on later failure |
| Storage 409 or uncertain response | Authorized download of exact private path, hash and length comparison | Matching = verified, mismatching = conflict quarantine, unreadable = unknown/retry/pause | Treat 409 as success; overwrite; new UUID |
| Storage download 401/403/404/RLS-hidden/timeout | Retain local bytes; retry only after safe authorization/state check; escalate if persistent | Unknown outcome, not negative proof | Assume absent, delete or bypass Storage RLS |
| Registration succeeds and response is verified | Persist `serverEvidenceId` and matching record under lease | Evidence registered | Assume registered on exception alone |
| Registration response lost | Authorized read of assessment and evidence row; compare identity, path, MIME, byte count, Storage byte hash | Exact match = confirmed; incomplete visibility = unknown | Retry with different path/ID |
| RPC `LW109` after server assessment non-draft | Read assessment and evidence row; reconcile prior registration | Exact match = registration confirmed; absent/ambiguous = manual unresolved | Repeatedly call RPC requiring draft |
| Server evidence path exists with differing byte hash | Persist explicit conflict, disable automatic retries | Quarantined/manual review; preserve local bytes | Upsert, delete, rotate evidence UUID |
| Server draft still draft and evidence not confirmed registered | After positive auth and sufficient reconciliation, retry original registration for same path | Preserve original intent | Recreate assessment under new UUID |
| Assessment already submitted | Verify authorized assessment identity/status and registered evidence; use original submit ID if receipt semantics permit | Confirmed or ambiguous/manual | Duplicate submission or optimistic 'success' |
| Concurrent editor / another actor / lease conflict | Return in-flight/conflict/pause; no RPC | No mutation except fenced disposition | Force update / steal active lease |
| Definitely terminal invalid input | Preserve evidence, record typed terminal state | Manual remediation required | Delete local photo by cleanup |

Represent *retryable transient*, *unknown commit*, *verified byte mismatch*, *actor waiting*, *terminal policy denial*, and *confirmed committed* as distinct typed application outcomes. If persisted wire enums stay unchanged, define a canonical versioned `lastErrorMessage` marker mapping and tests; do not parse arbitrary free-text to drive destructive/replay decisions. A conflict state must never satisfy `canAutoSubmit`.

## 6. Registration and Submission Reconciliation Rules

**6.1 Authorized positive proof** requires: current actor/grant verified, assessment `id/familyId/childId` matches the journal, evidence metadata `assessmentId/familyId/storagePath/mediaType/fileSizeBytes` matches, and remote object bytes match frozen SHA-256 and length. Do not confuse the opaque path `evidenceId` with the DB-assigned `serverEvidenceId`.

**6.2 Unknown != absent:** PostgREST `maybeSingle() == null`, empty evidence lists or inaccessible Storage bytes may reflect RLS. Never use only a null SELECT as permission to change identity, delete data, or declare final failure. If a server-side definitive denial is positively proven, record denial without RPC retry and preserve unsynced data.

**6.3 Registration:** While assessment is authoritatively in `draft` and full identity/byte conditions hold, the original `register_assessment_evidence` may safely be retried for the same exact path. Its idempotent path read is behind the `draft` guard, so after the assessment becomes non-draft always reconcile via read rather than calling the RPC again.

**6.4 Submission:** Use original `submitCommandId` and expected assessment version. On a `version` conflict, read the live assessment and compare immutable fields, command attribution, required evidence and status before deciding whether to retry. Do not just read the newest version and submit to bypass a concurrent edit. Preserve a conflict requiring manual review when identity/intent cannot be proved. All authoritative state transitions still execute via frozen RPCs.

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
| B1-05 | Successful upload followed by successful registration stores validated server evidence ID. |
| B1-06 | 409 with same remote bytes and size reconciles and succeeds after authorized download. |
| B1-07 | 409 with same length but different digest quarantines with no overwrite, delete or UUID rotation. |
| B1-08 | 409 with different length fails closed and preserves both objects and local file. |
| B1-09 | 409 followed by download 401/403/RLS denial remains unknown and retains evidence. |
| B1-10 | 409 followed by remote 404 does not authorize destructive cleanup or identity rotation. |
| B1-11 | Upload committed but response timed out; later byte download proves exact match; no duplicate upload. |
| B1-12 | Registration committed but response lost; authorized SELECT plus exact object-byte match restores `serverEvidenceId`. |
| B1-13 | Registration committed, assessment became non-draft, `LW109` on retry; read-only reconciliation succeeds without re-registering. |
| B1-14 | Non-draft assessment with no positively proven evidence row remains unresolved; no re-register. |
| B1-15 | Assessment/evidence read yields RLS-null; no inferred absence, no deletion, no new command IDs. |
| B1-16 | Revoked or changed actor/session/family causes safe pause and zero RPC until original authorized actor returns. |
| B1-17 | Child archived before dispatch; fail closed and retain local evidence without unauthorized RPC. |
| B1-18 | Crash before upload marker, after marker, during upload, after upload and before registration all resume deterministically. |
| B1-19 | Crash after evidence registration but before ID persistence reconciles exact same row and bytes. |
| B1-20 | Crash after submit request / lost submit response preserves `submitCommandId` and verifies authoritative outcome. |
| B1-21 | Multi-connection same-draft contention with explicit barriers dispatches at most one stage RPC while lease held. |
| B1-22 | Expired lease takeover: stale worker cannot overwrite successor result or delete journal. |
| B1-23 | Concurrent UI editor / autosave cannot overwrite immutable IDs/hash/evidence path or active lease. |
| B1-24 | Cross-family, cross-child and cross-assessment Storage or evidence row mismatch rejects without mutation. |
| B1-25 | Server assessment version changed: do not bypass conflict by adopting latest version; reconcile or quarantine. |
| B1-26 | Existing legacy/possibly-dispatched draft without checksum never silently snapshots new evidence bytes. |
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

## 10. Merge and Release Gates

**Design approval:** docs-only PR, exact-head CI green, independent source review; implementation not permitted before sign-off.  
**Implementation approval:** B1-01–B1-30 + frozen-slice regressions, authentic Storage/Postgres security proof, deterministic races, complete CI; no unreviewed merge.  
**Post-merge freeze:** successful `main` CI followed by docs-only freeze receipt, separate review.  
**Production/pilot:** CLOSED pending 4C-0, 4C-1, Slices 5 and 6, real device and signing validation.