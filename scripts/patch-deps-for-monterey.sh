#!/bin/bash
set -euo pipefail
# Lower dependency deployment floors to 12.7 so Monterey builds succeed.
# Covers both SPM-CLI (.build/checkouts) and Xcode (DerivedData/SourcePackages/checkouts)
# layouts. Only touches macOS platform lines; safe to re-run; idempotent.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT_ROOTS=(
  "$ROOT/.build/checkouts"
  "$ROOT/DerivedData/SourcePackages/checkouts"
)

PATCHED_ANY=0
for root in "${CHECKOUT_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r -d '' f; do
    if grep -qE '\.macOS\(\.v1[3-9]\)|\.macOS\("1[3-9][^"]*"\)' "$f" 2>/dev/null; then
      echo "Patching $f"
      perl -i -pe 's/\.macOS\(\.v1[3-9]\)/.macOS("12.7")/g; s/\.macOS\("1[3-9][^"]*"\)/.macOS("12.7")/g; s/\.macOS\(15\.0\)/.macOS("12.7")/g; s/\.macOS\(14\.0\)/.macOS("12.7")/g; s/\.macOS\(13\.0\)/.macOS("12.7")/g' "$f"
      PATCHED_ANY=1
    fi
    # Legacy catch-all from the original script: bare 15.0 strings in dep manifests.
    if grep -q '\.macOS(15\.0)' "$f" 2>/dev/null; then
      perl -i -pe 's/\.macOS\(15\.0\)/.macOS("12.7")/g' "$f"
      PATCHED_ANY=1
    fi
  done < <(find "$root" \( -name "Package.swift" \) -print0 2>/dev/null)
done

if [ "$PATCHED_ANY" -eq 0 ]; then
  echo "No dependency manifests needed patching."
fi
echo "Done."
