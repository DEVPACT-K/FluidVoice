#!/bin/bash
set -euo pipefail
# Monterey 12.7 Intel fast path: unsigned, Whisper Tiny, bottom overlay
# Usage: ./scripts/build-monterey.sh
cd "$(dirname "$0")/.."
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode not found — install Xcode 14.3.1 for Monterey (see docs/MONTEREY.md)"
  echo "  https://xcodereleases.com — then: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
echo "Building FluidVoice for Monterey 12.7 Intel (unsigned, Whisper Tiny default)..."
./build.sh unsigned
APP="DerivedData/Build/Products/Debug/FluidVoice Debug.app"
if [[ -d "$APP" ]]; then
  echo "✓ Built $APP"
  echo "  Launch: open \"$APP\""
  echo "  Grant Mic + Accessibility, then dictate — defaults to Whisper Tiny on 4GB"
else
  echo "Build finished but app not at $APP — check DerivedData path"
  exit 1
fi
