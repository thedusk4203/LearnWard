# Phase 2 Freeze Receipt — Secure Assessment Capture Vertical Slice

**Status:** FROZEN  
**Frozen code baseline (Merge SHA):** `9acfdc8009c0f8438bfd57207ce66bf052dc671c`  
**Approved PR HEAD:** `70b25590e6a9597e626ed624ea1ec298c015d094`  
**Merged PR:** [PR #3 — Phase 2: Secure assessment capture vertical slice](https://github.com/thedusk4203/LearnWard/pull/3)  
**Independent Review ID:** `5726443783` (APPROVED)  
**Post-merge CI Run ID:** `41276377749` — **SUCCESS**  
**Freeze date:** 2026-11-01  

---

## 1. Scope Frozen

Phase 2 establishes the secure, server-authoritative assessment ingestion pipeline and evidence verification loop before any reward economy or mastery logic is introduced.

Frozen capabilities:
- Assessment domain entity with server-normalized score value objects.
- Longitudinal canonical `subject_key` (`math`, `english`, `literature`, `science`, `other`) paired with custom user title/details.
- Ingestion provenance `entry_context` (`adult`, `shared_child`, `paired_child`) recorded in assessment and verified events.
- Server-authoritative score normalization on a 0.00–10.00 scale via PostgreSQL stored generated column (`normalized_score`).
- Server-enforced assessment lifecycle state machine (`draft` -> `pending_review` -> `verified` / `rejected`).
- Terminal status locking: verified and rejected assessments cannot be updated or deleted.
- Append-only `public.verified_learning_events` table rejecting all update/delete triggers even for administrative roles.
- Exactly one `VerifiedLearningEvent` generated per verified assessment.
- Private evidence storage bucket (`assessment-evidence`) restricted to max 10 MiB, JPEG/PNG format, with full-path Storage RLS.
- Storage path hierarchy: `<family_id>/<child_id>/<assessment_id>/<evidence_id>.<ext>`.
- Draft-bound evidence mutation: evidence upload and deletion require the assessment to exist in `draft` status. Evidence cannot be added or deleted once submitted.
- Immutable storage object identity: non-upsert (`upsert: false`) and omission of `UPDATE` storage policies.
- Pessimistic row locking (`SELECT ... FOR UPDATE`) and optimistic version checking on `verify_assessment` and `reject_assessment` preventing concurrent double-verification or double-events.
- Command receipts table (`public.command_receipts`) binding each command to its caller, family, resource, and operation type.
- Distinct command IDs for distinct operations (`createCommandId` vs `submitCommandId`).
- Durable offline draft storage in Drift SQLite (`LocalAssessmentDraft`) persisting `createCommandId`, `submitCommandId`, `evidenceId`, and `serverAssessmentId` to guarantee retry/restart idempotency without duplicate assessments or evidence.
- Native photo evidence picker (`image_picker`) and durable app-private local storage (`LocalEvidenceFileStore`) surviving app death and device reboot.
- Parent review screen with signed thumbnail URLs (10-minute expiry) and friendly error mapping.

---

## 2. Frozen Database Surface

### Tables
- `public.assessments`:
  - `id uuid primary key`
  - `family_id uuid not null references public.families(id)`
  - `child_id uuid not null references public.child_profiles(id)`
  - `subject_key text not null check (subject_key in ('math', 'english', 'literature', 'science', 'other'))`
  - `subject text not null`
  - `title text not null`
  - `assessment_type text not null check (assessment_type in ('quiz', 'exam', 'homework', 'practice', 'other'))`
  - `difficulty text not null check (difficulty in ('below_level', 'normal', 'hard', 'challenge'))`
  - `raw_score numeric(6, 2) not null check (raw_score >= 0 and raw_score <= max_score)`
  - `max_score numeric(6, 2) not null check (max_score > 0)`
  - `normalized_score numeric(4, 2) generated always as (round((raw_score / max_score) * 10.0, 2)) stored`
  - `entry_context text not null default 'adult' check (entry_context in ('adult', 'shared_child', 'paired_child'))`
  - `status text not null default 'draft' check (status in ('draft', 'pending_review', 'verified', 'rejected'))`
  - `occurred_at timestamptz not null default now()`
  - `version integer not null default 1`
  - `created_by_user_id uuid not null references auth.users(id)`
  - `created_at timestamptz not null default now()`
  - `updated_at timestamptz not null default now()`
- `public.assessment_evidence`:
  - `id uuid primary key default gen_random_uuid()`
  - `family_id uuid not null references public.families(id)`
  - `assessment_id uuid not null`
  - `storage_path text not null unique check (char_length(trim(storage_path)) > 0)`
  - `media_type text not null check (media_type in ('image/jpeg', 'image/png'))`
  - `file_size_bytes integer not null check (file_size_bytes > 0 and file_size_bytes <= 10485760)`
  - `uploaded_by_user_id uuid not null references auth.users(id)`
  - `created_at timestamptz not null default now()`
- `public.command_receipts`:
  - `command_id uuid primary key`
  - `operation text not null check (operation in ('create_draft', 'submit', 'verify', 'reject'))`
  - `actor_user_id uuid not null references auth.users(id)`
  - `resource_id uuid not null`
  - `family_id uuid not null references public.families(id)`
  - `created_at timestamptz not null default now()`
- `public.assessment_review_events`:
  - `id uuid primary key default gen_random_uuid()`
  - `command_id uuid not null unique references public.command_receipts(command_id)`
  - `family_id uuid not null references public.families(id)`
  - `assessment_id uuid not null`
  - `event_type text not null check (event_type in ('submitted', 'verified', 'rejected'))`
  - `from_status text not null`
  - `to_status text not null`
  - `actor_user_id uuid not null references auth.users(id)`
  - `review_notes text null check (review_notes is null or char_length(review_notes) <= 1000)`
  - `created_at timestamptz not null default now()`
- `public.verified_learning_events`:
  - `id uuid primary key default gen_random_uuid()`
  - `family_id uuid not null references public.families(id)`
  - `child_id uuid not null references public.child_profiles(id)`
  - `assessment_id uuid not null unique`
  - `subject_key text not null check (subject_key in ('math', 'english', 'literature', 'science', 'other'))`
  - `subject text not null`
  - `title text not null`
  - `assessment_type text not null`
  - `difficulty text not null`
  - `raw_score numeric(6, 2) not null`
  - `max_score numeric(6, 2) not null`
  - `normalized_score numeric(4, 2) not null`
  - `evidence_count integer not null default 0`
  - `entry_context text not null check (entry_context in ('adult', 'shared_child', 'paired_child'))`
  - `verified_by_user_id uuid not null references auth.users(id)`
  - `occurred_at timestamptz not null`
  - `verified_at timestamptz not null default now()`

### Trusted SECURITY DEFINER Functions
- `public.create_assessment_draft(...)`
- `public.update_assessment_draft(...)`
- `public.register_assessment_evidence(...)`
- `public.remove_draft_assessment_evidence(...)`
- `public.submit_assessment(...)`
- `public.verify_assessment(...)`
- `public.reject_assessment(...)`
- `private.validate_storage_evidence_access(...)`

---

## 3. Explicitly Frozen Invariants

1. **Tenant-bound Assessments:** Assessments are bound strictly to `(family_id, child_id)`. Cross-family access is denied at database and Storage levels.
2. **Server-Authoritative Score Normalization:** Normalization is computed server-side via PostgreSQL generated column (`normalized_score`). Client scores are never trusted directly.
3. **Longitudinal Subject Identity:** `subject_key` is constrained to canonical values (`math`, `english`, `literature`, `science`, `other`), decoupling longitudinal progress from free-text subject descriptions.
4. **Audit-Only Ingestion Provenance:** `entry_context` (`adult`, `shared_child`, `paired_child`) is purely an audit/provenance field and is never used to grant or elevate authorization.
5. **Server-Enforced Lifecycle State Machine:** Assessment transitions follow `draft -> pending_review -> verified / rejected`. No illegal transitions are permitted.
6. **Terminal Locking:** Assessments in `verified` or `rejected` status are immutable. Database triggers block all subsequent `UPDATE` and `DELETE` queries (`LW103`), and `Assessment.copyWith` throws `StateError`.
7. **Append-Only Review and Learning Records:** `public.assessment_review_events` and `public.verified_learning_events` reject all `UPDATE` and `DELETE` operations unconditionally (`LW102`).
8. **Single Verified Learning Event:** One assessment can produce at most one `verified_learning_events` record, guaranteed by unique constraint on `assessment_id` and serialized row locking (`SELECT ... FOR UPDATE`).
9. **Private Evidence Storage:** Bucket `assessment-evidence` is strictly private (`public = false`). Direct public URLs return 400. Previews use short-lived signed URLs (10-minute expiry).
10. **Storage Hierarchy & Draft-Bound Upload/Delete:** Storage paths must strictly match `<family>/<child>/<assessment>/<evidence_uuid>.<ext>`. Uploads and deletions require the assessment to exist in `draft` status. Post-draft evidence mutation is rejected.
11. **Immutable Storage Objects:** `storage.objects` has no `UPDATE` policy. Clients upload with `upsert: false`.
12. **Idempotency with Pre-Authorization:** All mutating RPCs authenticate (`auth.uid()`) and authorize family/child tenancy before inspecting `command_receipts`. Operation or actor mismatches raise `42501 (insufficient_privilege)`.
13. **Distinct Operation Command IDs:** `create_draft` and `submit` operations use distinct command IDs (`createCommandId` vs `submitCommandId`). Reusing a create command ID for submission is rejected.
14. **Durable Local Draft Idempotency Across Retries:** Local offline drafts persist `createCommandId`, `submitCommandId`, `evidenceId`, and `serverAssessmentId` in Drift SQLite. Retrying after partial network drops or app restarts guarantees zero duplicate assessments, zero duplicate evidence rows, and zero duplicate events.
15. **Strict Phase 2 Boundary:** Phase 2 does NOT award XP/RP, compute streaks, update mastery confidence, or award wheel spins.

---

## 4. Intentionally Deferred Scope

The following capabilities are intentionally deferred to subsequent phases:
- **Phase 3:** Growth Engine, rolling baselines, Personal Best, Goal bonus, Recovery scoring, Study XP, Reward Points (RP) ledger.
- **Phase 4:** Mastery Engine, confidence scoring, freshness decay, next challenge generation.
- **Phase 5:** Reward Store, Wheel mechanics, anti-farming constraints.
- **Future:** Dedicated child-device pairing/activation, anonymous child sign-in, OCR/AI photo score extraction.

---

## 5. Verification Receipt

### Post-Merge CI Execution on `main`
- **Commit SHA:** `9acfdc8009c0f8438bfd57207ce66bf052dc671c`
- **GitHub Actions Run ID:** `41276377749`
- **Status:** **SUCCESS**

| Job | Result | Duration |
| :--- | :---: | :---: |
| **Supabase migrations & RLS security** | `pass` | 2m 42s |
| **Format, analyze and test** | `pass` | 2m 25s |
| **iOS simulator compile** | `pass` | 1m 41s |
| **Android debug build** | `pass` | 8m 09s |

### Test Baseline at Freeze
- **Domain tests (`packages/learnward_domain`):** 35 passed
- **Application tests (`packages/learnward_application`):** 14 passed
- **Data tests (`packages/learnward_data`):** 7 passed
- **Test support tests (`packages/learnward_test_support`):** 1 passed
- **Design system tests (`packages/learnward_design_system`):** 2 passed
- **Mobile widget tests (`apps/mobile`):** 26 passed
- **pgTAP database tests (`supabase/tests/database`):** 80 passed
- **Last-owner concurrency regression:** PASS
- **Assessment verification concurrency regression:** PASS
- **Storage evidence security suite (Tests A–M):** PASS
- **Assessment vertical slice & retry integration test:** PASS
- **Android debug APK artifact:** Built and uploaded (`learnward-debug-apk`)
- **iOS simulator build:** Compiled successfully
