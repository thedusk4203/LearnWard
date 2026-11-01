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

## Decision 3 — Concurrency serialization and verification idempotency

To prevent race conditions during verification:
1. `verify_assessment` and `reject_assessment` acquire an exclusive row-level lock (`SELECT ... FOR UPDATE`) on the target assessment row.
2. Optimistic concurrency control verifies `version == p_expected_version` before transitioning; stale concurrent requests are rejected with `LW101`.
3. Every verification call requires a client-generated UUID `p_command_id`. If `command_id` was already processed, the RPC returns the existing assessment record idempotently without creating duplicate review events or duplicate `verified_learning_events`.

## Decision 4 — Terminal state and immutable learning records

Once an assessment is verified or rejected, its status is strictly terminal:
- A database trigger `prevent_terminal_assessment_mutation` blocks any subsequent `UPDATE` or `DELETE` on the assessment (`LW103`).
- The canonical `verified_learning_events` record is strictly append-only: triggers reject all `UPDATE` and `DELETE` operations even for administrative roles (`LW102`).
- A child may never verify their own assessment; verification requires an active family adult role (`private.is_active_family_adult`).

## Decision 5 — Private evidence storage and path isolation

Assessment evidence files (photos, scans) reside in a private Supabase Storage bucket (`assessment-evidence`) with a 10 MiB limit and MIME type restriction (`image/jpeg`, `image/png`).
Storage RLS policies on `storage.objects` strictly enforce family boundary checks:
- Objects must adhere to the hierarchy `<family_id>/<child_id>/<assessment_id>/<filename>`.
- Only active adult members of `<family_id>` can upload, read, or delete evidence objects.
- Public bucket URLs are forbidden; reads use temporary signed URLs or authenticated RLS access.
