#!/usr/bin/env bash
#
# gate.sh — the local pre-merge gate: lint → redaction-grep → full test suite.
#
# GitHub Actions can be unavailable on this account, so THIS script is the
# authoritative gate: a branch is mergeable only when it exits 0.
# Cheap checks run first so failures surface in seconds, not minutes.
#
#   ./Scripts/gate.sh              # full gate (lint + redaction + tests)
#   SKIP_TEST=1 ./Scripts/gate.sh  # docs/config-only changes: skip the slow test step
#
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
step() { printf '\n━━━ %s\n' "$1"; }

step "[1/3] swiftlint --strict"
if swiftlint lint --strict --quiet; then
  echo "✓ lint clean"
else
  echo "❌ lint violations (warnings fail the gate too)"
  status=1
fi

step "[2/3] redaction-grep (logging/diagnostics/core non-leak invariants)"
if ./Scripts/redaction-grep.sh; then
  echo "✓ redaction invariants hold"
else
  echo "❌ redaction-grep failed"
  status=1
fi

step "[3/3] xcodebuild test (Debug, pinned en-US)"
if [ "${SKIP_TEST:-0}" = "1" ]; then
  echo "⚠ SKIPPED (SKIP_TEST=1) — only acceptable for docs/config-only changes"
else
  # -skipMacroValidation: pointfree macros aren't trusted from xcodebuild.
  # -testLanguage/-testRegion: tests assert exact English strings against the 14-language catalog.
  if xcodebuild \
      -project Clipy.xcodeproj \
      -scheme Clipy \
      -destination 'platform=macOS,arch=arm64' \
      -skipMacroValidation \
      -testLanguage en -testRegion US \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      test 2>&1 | xcbeautify; then
    echo "✓ tests passed"
  else
    echo "❌ tests failed (re-run without xcbeautify for the raw log)"
    status=1
  fi
fi

printf '\n'
if [ "$status" -eq 0 ]; then
  echo "GATE PASSED ✅"
else
  echo "GATE FAILED ❌"
fi
exit "$status"
