# Phase 6 Freeze Receipt — Immediate Local Evidence Safety & Data Loss Prevention (Slice 4B-0)

**Implementation Status:** MERGED & FROZEN  
**Documentation Status:** RECORDED (tracked in documentation PR #27; see GitHub for authoritative merge status and commit SHA)  
**Target:** Phase 6 Slice 4B-0 — Immediate Local Evidence Safety & Data Loss Prevention (`Conservative Physical Evidence Retention, Atomic CAS Local Draft Deletion, Full 30-Field State Conflict Rejection, Path Traversal Sanitization & Containment, Exclusive Non-Overwriting File Creation, Fail-Closed Draft Attachment Restoration, Resilient Evidence Picker Persistence, Drift Schema v6 Immutability Preservation, Acceptance Criteria B01–B05, Review Dispositions R26-01 through R26-6-01`)  
**Implementation PR:** [#26 — fix(phase-6): prevent unsafe local assessment evidence deletion (Slice 4B-0)](https://github.com/thedusk4203/LearnWard/pull/26)  
**Approved Implementation HEAD:** `e0588ddf286602daa2752baaadc5da92c4752aa3`  
**PR CI Run ID:** [`42631837987`](https://github.com/thedusk4203/LearnWard/actions/runs/42631837987) — **SUCCESS (4/4 green)**  
**Implementation Merge SHA:** `f921bb67b67e4e0d528911f0da2b90f7b693fc00`  
**Post-Merge Main SHA:** `f921bb67b67e4e0d528911f0da2b90f7b693fc00`  
**Post-Merge Main CI:** Run ID [`42643730956`](https://github.com/thedusk4203/LearnWard/actions/runs/42643730956) — **SUCCESS (4/4 green)**  
**Merge Timestamp:** `2026-11-09T15:20:46Z`  
**Freeze Date:** `2026-11-09`  
**Documentation PR:** [#27 — docs(phase-6): record Slice 4B-0 local evidence safety freeze receipt](https://github.com/thedusk4203/LearnWard/pull/27)  
**ADR:** [ADR 0008 — Phase 6 Pilot Hardening](../adr/0008-phase-6-pilot-hardening.md) (`ACCEPTED`)  
**Upstream Contracts:**
- [ADR 0001–0007](../adr/)
- [Phase 1–5.2 Freeze Receipts](.)
- [Phase 6 Drift v5 Foundation Freeze](phase-6-drift-v5-foundation-freeze.md)
- [Phase 6 Slice 4A-0 Drift v6 Foundation Freeze](phase-6-slice-4a-0-drift-v6-foundation-freeze.md)
- [Phase 6 Slice 4A-1 Recovery Dispatcher Freeze](phase-6-slice-4a-1-recovery-dispatcher-freeze.md)
- [Phase 6 Master Delivery and Pilot Gates](../21-phase-6-master-delivery-and-pilot-gates.md)

---

## 1. Verified CI & Test Suite Totals

Final verified test totals from post-merge main CI run [`42643730956`](https://github.com/thedusk4203/LearnWard/actions/runs/42643730956) on exact merge commit `f921bb67b67e4e0d528911f0da2b90f7b693fc00`:

| Test Suite / Job | Total Tests | Passed | Result | Duration |
|---|---|---|---|---|
| **Format, analyze and test** | All suites | All | **PASS** | 2m 34s |
| - *learnward_domain* | 196 | 196 | **PASS** | — |
| - *learnward_application* | 75 | 75 | **PASS** | — |
| - *learnward_data* (incl. 27 SQLite reference & CAS safety tests) | 138 | 138 | **PASS** | — |
| - *learnward_test_support* | 14 | 14 | **PASS** | — |
| - *learnward_design_system* | 2 | 2 | **PASS** | — |
| - *apps/mobile* widget & flow tests (incl. 50 local evidence safety tests) | 131 | 131 | **PASS** | — |
| - *Drift build_runner diff assertion* | Clean (0 diff) | Clean | **PASS** | — |
| **Supabase migrations & RLS security** | 659 pgTAP + 19 scripts | All | **PASS** | 2m 28s |
| - *pgTAP Test Files* (11 files) | 659 | 659 | **PASS** | — |
| - *Concurrency & Integration Scripts* | 19 | 19 | **PASS** | — |
| **iOS simulator compile** | Flutter build ios --simulator | Success | **PASS** | 3m 34s |
| **Android debug build** | Gradle assembleDebug | Success | **PASS** | 5m 01s |

---

## 2. Verified Acceptance Criteria Matrix (B01–B05)

Every acceptance requirement defined for Phase 6 Slice 4B-0 in `docs/21-phase-6-master-delivery-and-pilot-gates.md` is covered by deterministic regression tests in `apps/mobile/test/local_evidence_safety_test.dart` and `packages/learnward_data/test/local_draft_reference_safety_test.dart`:

| ID | Specification Requirement | Verification Evidence / Test Assertion | Status |
|---|---|---|---|
| **B01** | Removing photo and navigating back without Save preserves physical file and original draft on disk and SQLite. | Verified: When a user removes photo attachment or navigates back without pressing Save, the underlying evidence file remains intact on disk, and the persisted SQLite draft maintains its original reference. | **PASS** |
| **B02** | Replacing photo followed by failed draft save preserves original evidence file on disk and keeps SQLite draft row unchanged. | Verified: If durable photo copy fails, the replacement is not accepted and prior attachment is preserved; if durable photo copy succeeds but subsequent SQLite draft save fails, the new file remains safely on disk, but the original persisted draft row and references remain unchanged. | **PASS** |
| **B03** | Remote submission succeeds; local evidence bytes are preserved on disk. | Verified: After remote submission commit succeeds, local evidence bytes are conservatively retained on disk without premature unlinking, ensuring evidence survives until formal reconciliation. | **PASS** |
| **B04** | Draft deletion requires confirmation; delete attempt against `unknown_legacy` or `possibly_dispatched` is blocked / fails closed. | Verified: `ChildModeScreen` requires explicit confirmation; `LocalDraftStore.deleteDraftSafely()` verifies CAS predicate and rejects deletion of drafts marked `possibly_dispatched`, `unknown_legacy`, or with active leases, failing closed with user-friendly error. | **PASS** |
| **B05** | Concurrent draft referencing same file prevents unlinking; safe cleanup under conservative retention. | Verified: `LocalDraftStore.countDraftReferencesToFile()` proves multiple drafts referencing the same photo file prevent deletion while references exist; to eliminate time-of-check to time-of-delete races across independent connections, physical unlinking is completely disabled across normal user workflows under conservative retention. | **PASS** |

---

## 3. Independent Review Findings & Dispositions (R26-01 through R26-6-01)

During independent review rounds 1 through 6, all data-safety edge cases were systematically hardened and regression-tested:

| Finding ID | Severity | Root Cause / Risk | Corrective Implementation & Fencing | Verification Status |
|---|---|---|---|---|
| **R26-01** | **P1** | Check-then-delete race: UI draft snapshot passed to unconditional `deleteLocalDraft()`. | Added `LocalDraftStore.deleteDraftSafely()` and SQLite CAS in `AppDatabase.deleteDraftSafely()`. Deletion executes inside a SQLite transaction, revalidates that the draft is safe to delete (blocking active leases, `possibly_dispatched`, `unknown_legacy`, etc.), checks for concurrent modification, and deletes via conditional CAS. | **PASS** |
| **R26-02** | **P1** | Time-of-check to time-of-delete gap allowed premature physical unlinking of shared evidence. | Introduced SQLite reference-count check `countDraftReferencesToFile()` in `LocalDraftStore` and pre-unlink re-check. Because reference checking alone cannot eliminate cross-connection check-to-unlink gaps, the final implementation enforces conservative retention in `deleteEvidenceIfUnreferenced`, disabling physical unlinking and returning `EvidenceFileDeletionStatus.preservedConservative`. | **PASS** |
| **R26-03** | **P2** | Potential path traversal in user-supplied or picker file names. | Added strict path sanitization in `LocalEvidenceFileStore.saveEvidence` via `p.basename(fileName).replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')` and validated `localDraftId` in `saveDurableEvidence` against `RegExp(r'^[a-zA-Z0-9_-]+$')`. Enforces directory boundary containment via `p.isWithin(canonicalEvidenceDir, canonicalFilePath)`. | **PASS** |
| **R26-3-01** | **P1** | Deletion conflict check omitted identity, recovery, and evidence fields; `updatedAt` alone insufficient. | Implemented complete 30-field persisted state comparison `LocalAssessmentDraft.hasConflictWith()` in application layer. In `AppDatabase.deleteDraftSafely()`, revalidation occurs inside a SQLite transaction, and the SQL DELETE statement applies a multi-field conditional CAS predicate (covering identity, ownership, command, evidence, revision, and lease fields). | **PASS** |
| **R26-3-02** | **P1** | Automatic physical unlinking in normal UI deletion could destroy referenced evidence on client. | Adopted strictly conservative evidence retention policy across mobile presentation layer: draft deletion removes SQLite draft row but disables automatic physical unlinking. | **PASS** |
| **R26-3-03** | **P2** | Gradle `mavenLocal()` could leak unreviewed host dependencies into builds. | Enforced environment fencing in `apps/mobile/android/build.gradle.kts` and `settings.gradle.kts`: `mavenLocal()` is enabled strictly when `CI == "true"`. | **PASS** |
| **R26-4-01** | **P1** | Unsafe `allowPhysicalUnlink` public parameter remained in API. | Completely removed `allowPhysicalUnlink` parameter and unlinking branch from `LocalEvidenceFileStore.deleteEvidenceIfUnreferenced`. Physical deletion methods `deleteDurableEvidence` and `deleteEvidence` are safe no-ops under conservative retention. | **PASS** |
| **R26-4-02** | **P2** | Collision risk on evidence file save could overwrite existing evidence file. | Enforced non-overwriting exclusive file creation `file.createSync(exclusive: true)` in `saveDurableEvidence` and `saveEvidence`. If target exists, retries with unique UUID suffix; throws typed `EvidenceStorageException` on collision exhaustion without overwriting existing files. | **PASS** |
| **R26-5-01** | **P1** | Picker persistence failure fell back to temporary native cache path as valid evidence. | Hardened `AddAssessmentScreen._pickEvidence()`: persistence failure displays actionable in-form error message, never accepts temporary cache path as durable evidence, and preserves previous valid attachment instead of clearing or overwriting it. Draft saving and submission are blocked if newly selected attachment failed durable persistence. | **PASS** |
| **R26-6-01** | **P1** | Missing or unreadable existing evidence silently dropped attachment on Save/Submit. | Explicit state tracking via enum `ExistingEvidenceRestorationStatus` (`none`, `loading`, `restored`, `missingOrUnreadable`, `removed`) and generation counter `_restorationGeneration`. Save and Submit fail closed while loading or missing; UI displays actionable recovery card with "Attach Replacement" and "Remove Attachment"; generation token prevents stale async overwrite. | **PASS** |

---

## 4. Zero-Diff Contracts & Schema Immutability Confirmation

| Asset / Boundary | Verification Result | Confirmation Details |
|---|---|---|
| **Drift Schema v6** | **0 diff (100% frozen)** | `packages/learnward_data/lib/src/database/app_database.dart` generated schema `app_database.g.dart` matches baseline identically. Zero schema mutations, zero migration files added. |
| **SQLite Migrations** | **0 diff (100% frozen)** | Multi-version migration matrix (`v1..v5 -> v6`) remains structurally unchanged. |
| **Supabase Migrations** | **0 diff (100% frozen)** | `supabase/migrations/` has zero diff; no new tables, triggers, functions, or storage policies. |
| **Server-Authoritative Economics** | **0 diff (100% frozen)** | All reward, assessment, and ledger RPC contracts remain 100% unchanged. |
| **RLS Policies** | **0 diff (100% frozen)** | 659 pgTAP tests and 19 concurrency scripts pass with zero modifications. |

---

## 5. Conservative Physical Evidence Retention Policy

1. **No Automatic Physical Deletion:**
   - Under Phase 6 Slice 4B-0, normal UI user workflows (draft deletion, photo removal, photo replacement, remote submission) **never** physically unlink or delete evidence files from disk.
   - Deleting a local draft safely removes the SQLite draft record via atomic CAS, while the underlying JPEG bytes remain safely preserved in the app's evidence directory.
2. **Safe Direct-Delete APIs:**
   - Public physical deletion methods (`LocalEvidenceFileStore.deleteEvidenceIfUnreferenced`, `deleteDurableEvidence`, `deleteEvidence`) enforce conservative retention and do not physically unlink files during active app workflows.
   - `deleteEvidenceIfUnreferenced` returns `EvidenceFileDeletionStatus.preservedConservative` when zero references remain.
   - Background garbage collection and physical storage reclamation are explicitly deferred pending an approved design and require explicit parent export / administrative confirmation.

---

## 6. Deferred Scopes & Operational Boundaries

1. **Background Garbage Collection:**
   - Automatic physical file unlinking and background garbage collection are out of scope for Slice 4B-0 and deferred.
2. **Storage 409 Resumability & Byte Reconciliation (Slice 4B-1):**
   - Resuming partial uploads, handling remote HTTP 409 conflict, comparing private Storage bytes with local SHA-256, and draft-state reconciliation belong strictly to Slice 4B-1 (`PR: TBD / not allocated`).
3. **Adult Fulfill/Cancel Reliability (Slice 4A-2):**
   - Expanding the recovery coordinator to handle adult `fulfill_reward` and `cancel_reward` commands belongs to Slice 4A-2 (`PR: TBD / not allocated`).
4. **Auth, Child Mode & Device Containment (Slice 4C-0):**
   - Session generation binding for drafts, Riverpod invalidation, and parent PIN lockouts belong to Slice 4C-0 (`PR: TBD / not allocated`).
5. **Feature Flag Default:**
   - `RECOVERY_DISPATCHER_ENABLED=false` remains enforced by default.
6. **Zero Deployment Authorization:**
   - No production deployment, store release, or external pilot has been executed or authorized.
