#!/usr/bin/env bash
#
# redaction-grep.sh — static gate (CI: .github/workflows/macos-app.yml, job `redaction-grep`).
#
# A clipboard manager captures everything the user copies, so three lightweight, fast, build-free
# invariants are enforced on every change:
#   1. Logging discipline — no raw print/debugPrint/NSLog (incl. module-qualified Swift.print /
#      Foundation.NSLog) in app sources. All logging goes through os.Logger with privacy markers
#      (security-guidance.md §5). Raw stdout/stderr bypasses redaction.
#   2. The typed diagnostics layer carries no free-form String/Data payload — DiagnosticEvent's
#      associated values must stay enums, so no caller can smuggle clipboard content into a
#      diagnostic. (The authoritative check is the Mirror test in DiagnosticsRedactionTests; this is
#      a cheap source-level belt that runs without a build. The enum scan is multi-line aware.)
#   3. The sync layer never logs the passphrase or sync folder path.
#
# The shared Rust core's own logging discipline (it must never print values, verdicts, keys, or
# passphrases) is enforced in the clipy-si-core repository's CI, not here.
#
# Exits non-zero (failing CI) on any violation.
#
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

echo "→ [1/3] logging discipline (no print/debugPrint/NSLog, incl. Swift.print, in Clipy/)"
# Real calls, optionally module-qualified (Swift.print / Foundation.NSLog / Glibc.print). A bare
# `expr.print` method call is excluded by the leading boundary; ignore comment lines.
if grep -RnE '(^|[^A-Za-z0-9_.])((Swift|Foundation|Glibc)\.)?(print|debugPrint|NSLog)[[:space:]]*\(' \
     Clipy --include='*.swift' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//'; then
  echo "❌ Found print/debugPrint/NSLog in Clipy/ — use os.Logger with privacy markers (security-guidance.md §5)."
  fail=1
else
  echo "✓ none"
fi

echo "→ [2/3] typed diagnostics carry no free-form String/Data (multi-line aware)"
# Whole-file (-0777) scan so a case split across lines can't slip past. `[^)]` matches newlines in
# Perl, so this catches `case foo(\n  FeatureArea,\n  String\n)`. Only enum `case`s with parens
# match — struct String fields (e.g. DiagnosticEnvironment.appVersion) are not flagged.
if perl -0777 -ne 'exit 1 if /\bcase\s+\w+\s*\([^)]*\b(?:String|Data)\b/' \
     Clipy/Diagnostics/DiagnosticTypes.swift; then
  echo "✓ none"
else
  echo "❌ A DiagnosticEvent case has a String/Data payload — diagnostics must stay enum-only (redaction)."
  fail=1
fi

echo "→ [3/3] sync layer never logs the passphrase or sync folder path"
# A Logger interpolation containing `passphrase`/`folderPath`/`syncFolderPath` would leak the
# vault credential or the user's folder location into the unified log. (The content/key non-leak
# of sync payloads themselves is machine-checked by the folder-bytes E2E assertion.)
if grep -RnE 'logger\.[a-z]+\(' Clipy --include='*.swift' -i \
     | grep -iE '\\\((self\.)?(passphrase|folderPath|syncFolderPath)' ; then
  echo "❌ A log line interpolates the passphrase or sync folder path."
  fail=1
else
  echo "✓ none"
fi

if [ "$fail" -ne 0 ]; then
  echo "redaction-grep: FAILED"
  exit 1
fi
echo "redaction-grep: OK"
