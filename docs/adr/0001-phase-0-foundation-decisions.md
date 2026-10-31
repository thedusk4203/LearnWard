# ADR 0001 — Phase 0 foundation decisions

- **Status:** Accepted
- **Date:** 2026-10-31
- **Context:** Phase 0 bootstraps LearnWard's engineering foundation without
  implementing product flows.

## Decision 1 — Native Dart pub workspace, no Melos

The root `pubspec.yaml` declares all six workspace packages. One root
`pubspec.lock` is committed and no package keeps its own lockfile. Melos was not
added because pub workspaces already provide shared resolution, path
dependencies and workspace-wide commands.

**Consequence:** run `flutter pub get` once at the repository root. Run commands
inside the package they affect.

## Decision 2 — One app identity in Phase 0

The app uses `com.learnward.app` for Android and iOS. The
`development`/`staging`/`production` environments are selected at build time
with `--dart-define`, not separate native flavors.

`docs/10-implementation-plan-v0.1.md` asks for distinct app identifiers per
environment. That remains the target before store distribution, but adding
three complete Gradle/Xcode configurations now would create untested native
configuration for flows that do not exist yet. Phase 0 therefore documents the
single identity and keeps environment selection in `AppConfig`.

**Consequence:** before the first internal store build, add `dev`/`staging`
flavors and identifiers (`com.learnward.app.dev`, `.staging`) as one focused
change with CI coverage.

## Decision 3 — Generated Drift files are committed

`packages/learnward_data/lib/src/database/app_database.g.dart` is generated with
`dart run build_runner build` and committed. CI regenerates it and fails if the
working tree changes.

**Why:** a fresh clone can run tests and builds without a code-generation step,
and generated output stays reviewable. The trade-off is remembering to commit
regeneration after schema edits; CI enforces it.

**Codegen command** (from `packages/learnward_data`):

```bash
dart run build_runner build
```

## Decision 4 — `learnward_data` stays pure Dart

The Drift database takes a `QueryExecutor` in its constructor. The Flutter app
supplies the platform executor through `drift_flutter`; data tests use
`NativeDatabase.memory()`. Supabase is represented by the Dart `supabase`
client, not `supabase_flutter`.

**Why:** data-layer tests run with `dart test` without a Flutter binding, and
the domain/application packages stay portable.

## Decision 5 — Non-default local Supabase ports

Local Supabase uses `45321`–`45329` instead of the CLI defaults
(`54321`–`54329`). On Windows, the default range collided with Hyper-V excluded
or ephemeral ports, which made `supabase start` fail even with no container
running.

**Consequence:** `apps/mobile/dart_defines.example.json` and the README point at
`http://127.0.0.1:45321`. Keep these values in sync if the local ports change.

## Decision 6 — iOS CI compiles a simulator build

The CI workflow has a `macos-latest` job that runs
`flutter build ios --simulator --debug`. It requires no signing identity and
does not block PRs on App Store credentials. Signed archives remain a later
release workflow.

## Decision 7 — Supabase CI is deferred

Phase 0 has no application tables or RLS policies, so a full Supabase CI job
would only test image startup. The local structure and reset command are
documented and verified manually. Add a Supabase job together with the first
schema/RLS tests, when it validates real security behavior.

## Decision 8 — Toolchain compatibility pins

`test` is pinned to `1.31.1` and `build_runner` to `2.15.1` because Flutter
3.47.1 pins `test_api 0.7.12`. Newer `test`/`build_runner` releases require an
analyzer/test_api combination that conflicts with this Flutter SDK. The lockfile
is the source of exact resolved versions.

**Review trigger:** revisit these constraints when upgrading the Flutter SDK.
