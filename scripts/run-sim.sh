#!/bin/zsh
# Build, boot the "Apple Vision Pro" simulator, install and launch the app.
# Extra args are passed to the app as launch arguments, e.g.
#   scripts/run-sim.sh -autostart game -autoplay YES -glassVariant C
#   scripts/run-sim.sh -autostart glassLab -glassVariant B
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="Apple Vision Pro"
BUNDLE_ID="com.devgrec.SoundVision"
scripts/build.sh
APP="build/DerivedData/Build/Products/Debug-xrsimulator/SoundVision.app"
UDID=$(xcrun simctl list devices available | grep -m1 "$DEVICE (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
xcrun simctl boot "$UDID" 2>/dev/null || true
open -a Simulator --args -CurrentDeviceUDID "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID" "$@"
echo "Launched on $DEVICE ($UDID)"
