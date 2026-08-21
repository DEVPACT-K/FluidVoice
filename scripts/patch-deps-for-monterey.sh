#!/bin/bash
set -euo pipefail
# Patch SPM checkouts to 12.7 deployment so `swift build` / Xcode 14.3 on Monterey 12.7 succeeds.
# Only needed if a dependency pins 15.0 — safe to re-run; idempotent.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
find "$ROOT/.build/checkouts" -name "*.pbxproj" -o -name "Package.swift" 2>/dev/null | while read -r f; do
  if grep -q "15\.0" "$f" 2>/dev/null; then
    echo "Patching $f: 15.0 -> 12.7"
    perl -i -pe 's/15\.0/12.7/g' "$f"
  fi
done
echo "Done. Re-run: swift package resolve && xcodebuild ..."
