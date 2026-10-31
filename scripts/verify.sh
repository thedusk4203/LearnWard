#!/usr/bin/env bash
# Full local verification for the LearnWard workspace.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

flutter pub get
dart format --output=none --set-exit-if-changed .
flutter analyze

(cd packages/learnward_domain && dart test)
(cd packages/learnward_application && dart test)
(cd packages/learnward_data && dart test)
(cd packages/learnward_test_support && dart test)
(cd packages/learnward_design_system && flutter test)
(cd apps/mobile && flutter test)

if command -v npx >/dev/null 2>&1; then
  npx supabase test db
fi
