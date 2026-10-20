#!/bin/zsh
# Build the visionOS app for the "Apple Vision Pro" simulator.
# Usage: scripts/build.sh [extra xcodebuild args]
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild \
  -project SoundVision.xcodeproj \
  -scheme SoundVision \
  -configuration Debug \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' \
  -derivedDataPath build/DerivedData \
  "$@" \
  build 2>&1 | tee build/last-build.log | grep -E "error:|warning:|\*\* BUILD" || true
grep -q "\*\* BUILD SUCCEEDED" build/last-build.log
