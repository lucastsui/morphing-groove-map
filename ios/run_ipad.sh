#!/usr/bin/env bash
# Build + run GroovePlayer on an iPad simulator in one shot.
# Requires full Xcode (not just Command Line Tools).
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$HERE/GroovePlayer/GroovePlayer.xcodeproj"
BUNDLE_ID="com.lucastsui.GroovePlayer"
DEVICE_NAME="iPad-Groove"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
DEVTYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"

# Reuse the device if it exists, else create it.
UDID=$(xcrun simctl list devices | grep "$DEVICE_NAME" | grep -oE '[0-9A-F-]{36}' | head -1 || true)
if [ -z "${UDID:-}" ]; then
  UDID=$(xcrun simctl create "$DEVICE_NAME" "$DEVTYPE" "$RUNTIME")
  echo "created simulator $UDID"
fi

echo "Building…"
xcodebuild build -project "$PROJ" -scheme GroovePlayer \
  -destination "id=$UDID" -configuration Debug \
  CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/gp_dd >/dev/null

APP=/tmp/gp_dd/Build/Products/Debug-iphonesimulator/GroovePlayer.app
open -a Simulator
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
echo "Launched GroovePlayer on $DEVICE_NAME."
