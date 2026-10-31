# Phase 1 Freeze Receipt — Family + Child Identity Foundation

**Status:** FROZEN  
**Frozen code baseline:** `2251cf51f47837ec121182f6a0c3d618effd393a`  
**Merged PR:** #2 — `Phase 1: Family and child identity foundation`  
**Post-merge CI:** GitHub Actions run `41218555546` — **SUCCESS**  
**Freeze date:** 2026-10-31

## 1. Scope frozen

Phase 1 establishes the identity, tenancy, authorization, and shared-device boundary required before LearnWard stores learning evidence.

Frozen capabilities:

- Adult authentication foundation using Supabase email Magic Link.
- Mobile callback/deep-link path for Android and iOS.
- Reactive auth routing on session sign-in/sign-out transitions.
- Atomic family creation with the creator becoming the active owner.
- Family-scoped adult memberships (`owner`, `parent`).
- Child profiles that are not automatically Supabase Auth users.
- Family as the primary tenant/security boundary.
- Family-isolated Row Level Security for exposed application data.
- Shared-device Child Mode that survives app restart/process termination.
- Mandatory parent-defined 4-digit Parent PIN before entering Child Mode.
- Parent-route containment while Child Mode is active.
- Child tenant key immutability (`child_profiles.family_id`).
- Concurrency-safe invariant that a family cannot lose its final active owner.
- Child-device authorization schema reserved for later dedicated-device pairing.
- Fail-closed default database privileges and explicit client grants.
- Fail-fast staging/production configuration when Supabase credentials are missing.

## 2. Frozen database surface

Phase 1 introduces:

- `public.families`
- `public.family_memberships`
- `public.child_profiles`
- `public.child_device_grants`
- `private.child_pairing_requests`
- `public.create_family(...)`
- private RLS helper functions for family/owner/child-device authorization
- invariant triggers for final-owner protection and immutable child tenancy

### Important mutation boundary

`public.child_device_grants` is intentionally **read-only to application clients** in Phase 1. Direct client `INSERT`, `UPDATE`, and `DELETE` are not exposed. Dedicated child-device pairing must later use trusted, validated server-side commands/RPCs.

`public.child_profiles` is created/updated/archived through allowed mutations. Direct client `DELETE` is intentionally not part of the Phase 1 contract.

## 3. Security invariants frozen

The following are Phase 1 non-regression requirements:

1. Family A identities cannot read or mutate Family B records without an explicit active adult membership in Family B.
2. An ordinary parent cannot promote itself or another member to owner unless an owner-authorized path permits it.
3. Unauthenticated clients cannot invoke adult-only commands such as family creation.
4. Child-device identities and future anonymous child identities cannot create families or acquire adult authority.
5. Revoked memberships and revoked child-device grants immediately lose their corresponding access.
6. A child profile cannot be moved between families by editing `family_id`.
7. Concurrent owner demotion/revocation cannot leave a family with zero active owners.
8. New public database objects fail closed unless privileges are deliberately granted.
9. RLS, not Flutter route visibility, is the server-side authorization boundary.
10. Shared-device Parent PIN is a local containment mechanism, not a substitute for RLS.

## 4. Verification receipt

The post-merge push workflow ran on exactly:

`2251cf51f47837ec121182f6a0c3d618effd393a`

GitHub Actions run:

`41218555546`

Result: **SUCCESS**.

Blocking jobs passed:

- Format, analyze and test — **SUCCESS**
- Supabase migrations & RLS security — **SUCCESS**
- iOS simulator compile — **SUCCESS**
- Android debug build + artifact upload — **SUCCESS**

The database job includes:

- clean local Supabase startup,
- migration reset from zero,
- pgTAP database/RLS suite,
- multi-connection last-owner concurrency regression test.

## 5. Test baseline at freeze

Validated suites at the Phase 1 merge baseline:

- Domain: **14 passed**
- Application: **4 passed**
- Data: **4 passed**
- Test support: **1 passed**
- Design system: **2 passed**
- Mobile unit/widget tests: **17 passed**
- Mobile integration smoke test: **1 passed**
- pgTAP database/RLS assertions: **38 passed**
- Last-owner multi-connection concurrency regression: **PASS**
- Local Supabase Magic Link → authenticated `create_family` verification: **PASS** during PR validation

## 6. Deferred intentionally

The following are explicitly **not** part of the Phase 1 frozen contract:

- dedicated child-device short-code/QR pairing exchange UI,
- trusted pairing creation/revocation RPCs,
- anonymous child sign-in activation,
- co-parent invitation email workflow,
- assessment capture,
- evidence/photo upload,
- assessment verification workflow,
- score normalization,
- Growth Engine execution,
- Mastery Engine execution,
- XP/RP ledgers,
- reward store,
- wheel/spin mechanics,
- OCR/AI extraction,
- notifications,
- payments/subscriptions.

## 7. Known boundaries carried forward

- The Parent PIN protects casual access on a shared device. Clearing/uninstalling the app or OS-level compromise is outside that boundary.
- Biometric/device-credential unlock can be added later as a convenience/hardening layer.
- Environment-specific native application identifiers/flavors are still deferred before store distribution.
- Android production signing remains a pre-distribution concern; debug artifacts are not release artifacts.
- A production-grade hosted Supabase environment and production redirect configuration must preserve the same RLS/grant invariants as local development.

## 8. Change-control rule

Phase 1 is frozen.

Any future change to the identity/tenancy/security contract above must be treated as one of:

1. a corrective security fix with explicit regression tests, or
2. a deliberate architecture change documented by an ADR and reviewed for backward compatibility.

Phase 2 must consume this contract rather than weaken it.

## 9. Next gate

**Phase 2 — Secure Assessment Capture Vertical Slice**

Target data path:

```text
REAL LEARNING RESULT
        ↓
ASSESSMENT DRAFT
        ↓
EVIDENCE
        ↓
SERVER-SIDE VERIFICATION STATE
        ↓
VERIFIED ASSESSMENT
        ↓
NORMALIZED SCORE
        ↓
IMMUTABLE / AUDITABLE LEARNING EVENT
```

Phase 2 must establish trustworthy academic input before Growth Engine, mastery, XP/RP, or reward mechanics are allowed to consume it.

---

**PHASE 1 — FAMILY + CHILD IDENTITY FOUNDATION — FROZEN**
