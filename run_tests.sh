#!/usr/bin/env bash
# Full test suite for Morphing Groove Map — see TESTING.md.
# Runs all four tiers; exits non-zero if any tier fails.
set -uo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
fail=0
hr() { printf '\n========== %s ==========\n' "$1"; }

hr "Tier 0 — MGMValidate (no-Xcode smoke)"
swift run --package-path MGMKit MGMValidate || fail=1

hr "Tier 1 — MGMKit unit tests"
swift test --package-path MGMKit || fail=1

hr "Tier 2+3 — app unit + UI tests (simulator)"
xcodegen generate --spec GroovePlayer/project.yml --project GroovePlayer >/dev/null
RT=$(xcrun simctl list runtimes | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]+' | tail -1)
DT=$(xcrun simctl list devicetypes | grep -oE 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M[0-9]-[0-9]+GB' | head -1)
[ -z "${DT:-}" ] && DT=$(xcrun simctl list devicetypes | grep -oE 'com.apple.CoreSimulator.SimDeviceType.iPad[^ )]*' | head -1)
UDID=$(xcrun simctl list devices | grep "GP-iPad (" | grep -oE '[0-9A-F-]{36}' | head -1)
[ -z "${UDID:-}" ] && UDID=$(xcrun simctl create "GP-iPad" "$DT" "$RT")
xcodebuild test \
  -project GroovePlayer/GroovePlayer.xcodeproj -scheme GroovePlayer \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath /tmp/gp_dd \
  CODE_SIGNING_ALLOWED=NO -quiet || fail=1

hr "RESULT"
if [ "$fail" -eq 0 ]; then echo "✅ ALL TIERS PASSED"; else echo "❌ SOME TIERS FAILED"; fi
exit "$fail"
