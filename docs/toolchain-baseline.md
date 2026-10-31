# Toolchain and platform baseline

Detected on **2026-10-31** for the Phase 0 bootstrap and Phase 1 implementation.
Record actual versions, not aspirational ones; update this file when the pinned toolchain changes.

## Local development toolchain

| Tool | Version |
|---|---|
| Flutter | 3.47.1 (stable, framework revision `6655482ec0`) |
| Dart | 3.13.1 |
| Java (system) | 26.0.2.1 |
| Java (Flutter-configured JDK) | Android Studio JBR 25.0.3 |
| Android SDK | Platform 36.0.0, build-tools 36.0.0 |
| Gradle | 9.3.1 (wrapper) |
| Android Gradle Plugin | 9.1.0 |
| Kotlin | 2.4.0 |
| Supabase CLI | 2.122.0 (run through `npx supabase`) |
| Node.js | 24.17.0 |
| Docker | 29.6.1 |
| GitHub CLI | 2.96.0 |

## Application platform baseline

| Platform | Value | Source |
|---|---|---|
| Android `minSdk` | 24 (Android 7.0) | Flutter 3.47.1 default |
| Android `compileSdk` | 36 | Flutter 3.47.1 default |
| Android `targetSdk` | 36 | Flutter 3.47.1 default |
| iOS deployment target | 15.0 | generated Xcode project |
| App identifier | `com.learnward.app` | Phase 0/1 baseline |
| Dart SDK constraint | `^3.13.0` | workspace |

The Android and iOS floors follow `docs/08-mobile-architecture-v0.1.md`
(Android 7.0 / API 24, iOS 15). Do not raise them without a concrete dependency
requirement.

## iOS requirements

A macOS host with Xcode and CocoaPods is required for iOS compilation and
signing. The current development machine is Windows, so iOS was structurally
generated but not compiled locally. CI covers simulator compilation on
`macos-latest`; signed archives remain a later release concern.

## Version pinning policy

- The Flutter version is pinned in CI via `FLUTTER_VERSION` and documented here.
- Supabase CLI is pinned in CI to `2.122.0` (`supabase/setup-cli@v1` with `version: "2.122.0"`)
  to guarantee deterministic database migrations and pgTAP test runs.
  Upgrade procedure:
  1. Test locally: `npx supabase db reset && npx supabase test db`.
  2. Validate in CI on a test branch.
  3. Update the pin in `.github/workflows/ci.yml` and record in this document.
- FVM is not used. A single stable Flutter SDK plus the committed workspace
  lockfile is sufficient.
- `pubspec.lock` is committed and CI fails on generated-code drift.
- `test`/`build_runner` compatibility pins are explained in
  `docs/adr/0001-phase-0-foundation-decisions.md`.

## Local Supabase ports

`45321` API, `45322` database, `45323` Studio and `45324` Mailpit. Analytics is
disabled in Phase 0. The CLI defaults collided with Windows reserved/ephemeral
ports on the bootstrap machine; see ADR 0001.
