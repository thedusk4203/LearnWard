# ADR 0003 — Phase 2 secure assessment capture decisions

- **Status:** Accepted
- **Date:** 2026-11-01
- **Context:** Phase 2 implements a trustworthy, auditable academic-result ingestion pipeline moving from local draft $\rightarrow$ server draft $\rightarrow$ private evidence $\rightarrow$ submission $\rightarrow$ parent review $\rightarrow$ verification $\rightarrow$ server-generated normalized score $\rightarrow$ immutable `VerifiedLearningEvent`.

## Decision 1 — Server-authoritative normalized score (`GENERATED ALWAYS AS`)

The client must not own or submit `normalized_score`.
In PostgreSQL, `normalized_score numeric(4, 2) GENERATED ALWAYS AS (round((raw_score / max_score) * 10.0, 2)) STORED NOT NULL` is enforced at the database level.
Any client attempt to insert or modify `normalized_score` is directly blocked by PostgreSQL (`428C9`). Raw score bounds (`raw_score >= 0` and `raw_score <= max_score`) and maximum denominator (`max_score > 0`) are validated via check constraints.

**Consequence:** Normalization is deterministic, tamper-proof, and independent of client software versions.

## Decision 2 — Server state transitions via `SECURITY DEFINER` RPCs only

Direct client `INSERT`, `UPDATE`, and `DELETE` on `public.assessments`, `public.assessment_evidence`, `public.assessment_review_events`, and `public.verified_learning_events` are revoked from `authenticated` (`42501`).
All state transitions are strictly controlled through trusted `SECURITY DEFINER` functions with `search_path = ''`:
- `create_assessment_draft`
- `update_assessment_draft`
- `register_assessment_evidence`
- `remove_draft_assessment_evidence`
- `submit_assessment`
- `verify_assessment`
- `reject_assessment`

## Decision 3 — Concurrency serialization and operation-bound idempotency (`command_receipts`)

To prevent race conditions during verification and prevent cross-user/cross-operation replay vulnerabilities:
1. `verify_assessment` and `reject_assessment` acquire an exclusive row-level lock (`SELECT ... FOR UPDATE`) on the target assessment row.
2. Optimistic concurrency control verifies `version == p_expected_version` before transitioning; stale concurrent requests are rejected with `LW101`.
3. Every mutating RPC requires authentication and authorization *before* checking idempotency receipts.
4. Receipts are recorded in `public.command_receipts` table with `command_id`, `operation`, `actor_user_id`, `resource_id`, and `family_id`.
5. An idempotent retry returns the existing resource if and only if the `actor_user_id` and `operation` match the original command receipt; caller or operation mismatches are rejected with `42501` to prevent authorization bypass.

## Decision 4 — Terminal state and immutable learning records

Once an assessment is verified or rejected, its status is strictly terminal:
- A database trigger `prevent_terminal_assessment_mutation` blocks any subsequent `UPDATE` or `DELETE` on the assessment (`LW103`).
- In the domain layer, `Assessment.copyWith` throws `StateError` if invoked on any terminal assessment.
- The canonical `verified_learning_events` record is strictly append-only: triggers reject all `UPDATE` and `DELETE` operations even for administrative roles (`LW102`).
- A child may never verify their own assessment; verification requires an active family adult role (`private.is_active_family_adult`).
- Rejection requires a non-empty reason capped at 500 characters; verification approval notes are capped at 1000 characters.

## Decision 5 — Full-path Storage RLS and draft-bound evidence lifecycle

Assessment evidence files (photos, scans) reside in a private Supabase Storage bucket (`assessment-evidence`) with a 10 MiB limit and MIME type restriction (`image/jpeg`, `image/png`).
Storage RLS policies on `storage.objects` strictly validate the entire path hierarchy via a database helper function `private.validate_storage_evidence_access`:
- Hierarchy convention: `<family_id>/<child_id>/<assessment_id>/<evidence_id>.<ext>`
- Uploads and deletions require the target assessment to physically exist in `public.assessments`, belong to `<family_id>` and `<child_id>`, and be in `draft` status (`p_require_draft = true`).
- Evidence uploads or deletions on `pending_review`, `verified`, or `rejected` assessments are blocked by Storage RLS.
- Object identity immutability: no `UPDATE` policy exists on `storage.objects`, and client uploads pass `upsert: false`.
- Read access requires an active adult membership in `<family_id>` or a paired/shared child device for that family.
- Public URLs are blocked (`public = false`). Parent review uses short-lived signed URLs (10-minute expiry).

## Decision 6 — Longitudinal Subject Identity & Entry Context Provenance

- `subject_key`: Canonical academic subject identity (`math`, `english`, `literature`, `science`, `other`) enforced via database check constraint for longitudinal analytics and mastery foundations. Custom subject title/topics (e.g. "Fractions Quiz") are retained in the `subject` and `title` fields.
- `entry_context`: Ingestion channel provenance (`adult`, `shared_child`, `paired_child`) recorded in both `assessments` and `verified_learning_events`. Invariant: `entry_context` is an audit field only and is never used to grant or deny authorization.

## Decision 7 — Durable local offline storage, compensation cleanup, and native picker

- Evidence picker utilizes the official `image_picker` plugin on Android/iOS (with in-memory simulator for headless testing).
- Evidence files attached to offline local drafts are persisted to durable app-private storage (`LocalEvidenceFileStore`) ensuring persistence across process death and device restarts.
- Unsubmitted local drafts can be reopened, edited, and submitted from the Child Mode screen.
- Partial upload compensation cleanup: `UploadAssessmentEvidence` deletes the uploaded storage object if database metadata registration fails.
