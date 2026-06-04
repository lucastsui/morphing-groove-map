# Testing — Morphing Groove Map

The suite has four tiers. The first two run on the **MGMKit** Swift package; the
last two run the **GroovePlayer** iPad app on a simulator.

| Tier | What it covers | Command | Count |
|---|---|---|---|
| **0 — smoke** | `MGMValidate` CLI: morph, bf/triplets, files, extraction, render | `swift run --package-path MGMKit MGMValidate` | ~31 checks |
| **1 — engine** | MGMKit units/grid/morph/document/IO/onset/MIDI + fuzz | `swift test --package-path MGMKit` | 45 tests |
| **2 — app model** | `Store`: fbu/ms/note steps, grid, slots, file I/O, MIDI import | `xcodebuild test … -only-testing:GroovePlayerTests` | 8 tests |
| **3 — UI** | XCUITest: tab nav, MIDI toggle, Edit-gating, .MGM slots | `xcodebuild test … -only-testing:GroovePlayerUITests` | 4 tests |

## Prerequisites
- **Xcode 26.5** (for XCTest + the iOS Simulator SDK). Command Line Tools alone can run only Tier 0.
- **XcodeGen** (`brew install xcodegen`) — regenerates the app project after `project.yml` or file changes.

## Run everything
```bash
./run_tests.sh          # runs all four tiers, exits non-zero if any fail
```
`run_tests.sh` sets `DEVELOPER_DIR` to Xcode, runs Tiers 0–1, regenerates the
xcodeproj, finds/creates an iPad simulator, and runs Tiers 2–3.

## Run tiers individually
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Tier 0 — no-Xcode smoke (also works under Command Line Tools)
swift run  --package-path MGMKit MGMValidate

# Tier 1 — engine unit tests (needs Xcode's toolchain for XCTest)
swift test --package-path MGMKit

# Tiers 2+3 — app unit + UI tests on a simulator
xcodegen generate --spec GroovePlayer/project.yml --project GroovePlayer
UDID=$(xcrun simctl list devices | grep "GP-iPad (" | grep -oE '[0-9A-F-]{36}' | head -1)
xcodebuild test \
  -project GroovePlayer/GroovePlayer.xcodeproj -scheme GroovePlayer \
  -destination "platform=iOS Simulator,id=$UDID" \
  CODE_SIGNING_ALLOWED=NO
```
Append `-only-testing:GroovePlayerTests` (model) or `-only-testing:GroovePlayerUITests` (UI) to run one app tier.

## Coverage
```bash
swift test --package-path MGMKit --enable-code-coverage
# app coverage: add `-enableCodeCoverage YES` to xcodebuild test, then:
xcrun xccov view --report /tmp/gp_dd/Logs/Test/*.xcresult
```

## What's covered, by module
- **Model** (units/grid/morph): ms↔samples↔bf, the `2¹⁶×3` triplet-exactness invariant, `bfToNoteValue`, `bfInRange`/`clampBF`, `isCompatible`, `Groove` Codable, fine + triplet resolutions, dial interpolation.
- **Document** (`.mgm`): slot range, compatibility blocking, lane-presence agreement, empty-0/127 → no-swing, clear/order.
- **MGMIO**: `.stt`/`.mgm` disk round-trips + decode error paths (bad format/TS/JSON).
- **Onset**: `foldPerSlot` averaging+wrap, `offsets` in ms/samples/bf, `velocities`, onset accuracy (MAE < 2 ms vs synthetic ground truth).
- **Render**: deterministic output length, no-clipping, empty-input guards.
- **MIDIImport**: note/tempo/velocity parse, running status, note-off/zero-vel ignored, **malformed/truncated/random input never crashes**.
- **Library**: `groove_library.json` decode + conversion.
- **Store** (app model): fbu/ms/note step math + clamp, `resizeLanes`, `gridValid` truth table, `currentGroove`, slot assignment, `.stt` save/load, MIDI import, MIDI 1.0/2.0 velocity range.
- **UI**: 5-tab navigation, MIDI toggle updates the velocity-range text, **Edit** gates the step buttons, `.MGM` shows the seeded slots.

## Fixtures & helpers
- `SplitMix64` — deterministic RNG for reproducible synthetic audio (in `MGMKitTests.swift`).
- Synthetic click-track generators (known offsets/velocities) — in the onset/velocity tests and `MGMValidate`.
- Minimal Standard MIDI File builders — `smf(_:)` in `EngineGapTests.swift`, `smfData()` in `StoreTests.swift`.
- Accessibility identifiers for UI tests: `tsNum`, `tsDen`, `tempo`, `beatRes`, `beat-<i>`.

## Adding tests
- **Engine** → add an `XCTestCase` to `MGMKit/Tests/MGMKitTests/`. No project regen needed; just `swift test`.
- **App model** → add to `GroovePlayer/Tests/` with `@testable import GroovePlayer`.
- **UI** → add to `GroovePlayer/UITests/`; prefer accessibility identifiers, `firstMatch`, and `waitForExistence` (the iPad top tab bar can expose a label as more than one element).
- After adding files under `GroovePlayer/`, regenerate: `xcodegen generate --spec GroovePlayer/project.yml --project GroovePlayer`.

## Known-hard / out of scope
- **`precondition` crash paths** (e.g. `Render.grooved` with a bf groove and no tempo) aren't unit-tested — XCTest can't catch a `precondition`. Convert to `throws` if assertable coverage is needed.
- **Real-recording onset accuracy** — validated only against synthetic ground truth; no labelled real-world corpus.
- **Audio playback** (AVAudioEngine output) — not asserted; logic is tested up to buffer construction.

## CI
`.github/workflows/ci.yml` runs the same four tiers on a macOS runner on every
push/PR (it just calls `run_tests.sh` after installing XcodeGen). GitHub runners
have Xcode pre-selected and `simctl` on PATH.
