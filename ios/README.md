# Groove Player — native iPad app

A fully-offline Swift/SwiftUI port of the Groove Player. All DSP (groove morph,
audio render, Accelerate/vDSP onset detection) lives in the **MGMKit** Swift
package; the SwiftUI app is a thin layer on top.

```
ios/
├── MGMKit/            pure-Swift core (no UIKit) — builds & tests without Xcode
│   ├── Sources/MGMKit/   Model, Onset (vDSP), Render, Library
│   └── Sources/MGMValidate/  CLI checks (morph + onset accuracy)
└── GroovePlayer/      SwiftUI iPad app (needs Xcode to build)
    ├── project.yml       XcodeGen spec
    └── GroovePlayer.xcodeproj
```

## Verify the core without Xcode (works with Command Line Tools)

```bash
cd ios/MGMKit
swift run MGMValidate     # morph spec checks + onset MAE < 2 ms on ground truth
```

Expected: `ALL CHECKS PASSED` — onset MAE ~0.7 ms, matching the Python pipeline.

## Build & run the iPad app (needs full Xcode)

1. Install **Xcode** from the Mac App Store (Command Line Tools alone is not enough —
   the iPad Simulator and iOS SDK ship only with Xcode).
2. Point the toolchain at it once:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
3. Open the project:
   ```bash
   open ios/GroovePlayer/GroovePlayer.xcodeproj
   ```
   (To regenerate it after editing `project.yml`: `cd ios/GroovePlayer && xcodegen generate`.)
4. Pick an **iPad** simulator in the scheme bar and press **▶ Run**.

### Run on a real iPad
Plug it in, select it as the destination, and set **Signing & Capabilities →
Team** to your Apple ID (a free account works for on-device install). Trust the
developer cert on the iPad under Settings → General → VPN & Device Management.

## What it does (offline)
- Browse the 35 grooves extracted from the Google Groove MIDI Dataset.
- **Analyze the Amen break** on-device into your own swing file (vDSP onset detection).
- Dial swing 0–127 and **play** the target loop with the groove stamped on — rendered natively.
