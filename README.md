# Morphing Groove Map — Groove Player (iPad)

Capture the **swing/groove** of a drum beat as an array of numbers, **morph**
between grooves with a 0–127 dial, and **render new audio** by stamping a groove
onto a different beat — all natively on iPad, fully offline.

This is a pure-Swift project. The DSP (groove model, morph math, audio render,
Accelerate/vDSP onset detection) lives in the **MGMKit** Swift package; the
SwiftUI app is a thin layer on top.

```
MGMKit/            pure-Swift core (no UIKit) — builds & tests without Xcode
├── Sources/MGMKit/      Model (units + grid + groove + morph + validation),
│                        Onset (vDSP detect + velocity), Render, Document (.mgm),
│                        MGMIO (.stt/.mgm files), MIDIImport (SMF), Library
└── Sources/MGMValidate/ CLI checks (morph, bf/triplets, files, extraction)
GroovePlayer/      SwiftUI iPad app (needs Xcode to build)
├── project.yml          XcodeGen spec
├── Sources/             App, ContentView, Store, AudioEngine
├── Resources/           amen.wav, straight_target.wav, groove_library.json
└── GroovePlayer.xcodeproj
run_ipad.sh        one-command build + run on an iPad simulator
```

## Core concepts

- **Groove** — parallel arrays over equal subdivision slots of one measure:
  - `timing` — offset from a perfect grid (`+` late, `−` early, `0` dead-on)
  - `velocity` / `gate` — optional lanes (hit strength, note length)
- **Grid** — array length = `beats × slicesPerBeat`, derived from time signature
  + subdivision. Straight subdivisions `8→128` **and triplets `12/24/48/96`**
  (4/4: 12 = eighth-note triplets → 3 per beat — the grid a swing feel sits on
  *exactly*).
- **Units** — offsets in `ms`, `samples`, or **`bf` (beat fractions)**:
  - **`bf`** is the tempo-independent unit: one beat = `196608 = 2¹⁶ × 3`. The
    `× 3` makes triplets land on **exact integers** (so swing is representable
    with no rounding); the `2¹⁶` gives fine straight resolution. A bf value keeps
    its musical meaning at any tempo — supply a tempo to realise it as ms/samples
    (`describeBF`: 3072 bf @ 60 BPM = 1/64 beat = 15.625 ms). Render bf grooves
    with `Render.grooved(..., tempoBpm:)`.
- **Morph** — a `GrooveMap` holds anchors at integer dial positions (0–127).
  Any dial value linearly interpolates, slot by slot, between its two bracketing
  anchors. The morph is unit-agnostic, so `ms`, `samples`, and `bf` grooves all
  morph identically.

## Spec feature support

All seven items from the use-case spec are implemented in MGMKit and verified by
`MGMValidate` (and the XCTest suite):

1. **`.stt` template** — `Groove` (time signature, beats, per-hit timing / gate /
   velocity) ⇄ `.stt` JSON via `MGMIO`.
2. **`.mgm` map** — `MGMDocument`: ≥1 `.stt` across 128 slots (0–127) with its own
   time signature/beats; empty slots 0 and 127 default to no-swing; ⇄ `.mgm` JSON.
3. **Beat fractions** — tempo-independent `bf`, range ±196,608, one beat = 2¹⁶×3.
4. **Velocity** — a 0–127 (MIDI-range) lane, validated and interpolated; read from
   MIDI and estimated from audio.
5. **Variable resolution** — straight + triplet subdivisions (e.g. 256-position
   64ths, 384-position triplets); the 16-slot minimum is enforced.
6. **Morph** — linear interpolation of timing/gate/velocity across populated slots
   via one dial; **time-signature compatibility is enforced** (an incompatible
   `.stt` is blocked from a slot).
7. **Extraction** — timing **and velocity** from **audio** (vDSP) or a **MIDI
   file** (built-in SMF parser).

> These all live in the **MGMKit** engine (with tests). The SwiftUI app currently
> exposes the analyze-and-morph flow; wiring `.stt`/`.mgm`/MIDI file import into
> the iPad UI is a thin follow-up on top of this API.

## MGMKit module map

| File | Responsibility |
|---|---|
| `Model.swift` | units (ms ↔ samples ↔ **bf**), grid (straight + **triplet**), `Groove`, `GrooveMap` morph, validation/enforcement |
| `Document.swift` | `MGMDocument` — 128-slot `.mgm`, empty 0/127 → no-swing, time-signature compatibility enforcement |
| `MGMIO.swift` | read/write the `.stt` (single template) and `.mgm` (morphing map) JSON file formats |
| `Onset.swift` | vDSP onset detection + per-slot **timing & velocity** extraction (ms / samples / bf) |
| `MIDIImport.swift` | parse a Standard MIDI File → `Groove` (timing + velocity) |
| `Render.swift` | slice / shift / overlap-add a groove onto target audio |
| `Library.swift` | load the bundled `groove_library.json` (35 grooves from the Google Groove MIDI Dataset) |

## Verify the core without Xcode (Command Line Tools is enough)

```bash
swift run --package-path MGMKit MGMValidate
```

Expected: `ALL CHECKS PASSED` — morph spec examples, the **bf + triplet** checks
(incl. the UC-6 example and triplet-exactness), and onset MAE ~0.7 ms on
synthetic ground truth.

> The XCTest suite (`MGMKit/Tests`) requires full Xcode (`swift test` from
> Xcode, or in the IDE) — XCTest does not ship with Command Line Tools. The
> `MGMValidate` executable above is the no-Xcode equivalent.

## Build & run the iPad app (needs full Xcode)

1. Install **Xcode** from the Mac App Store (Command Line Tools alone can't build
   the iPad app — the iOS SDK and Simulator ship only with Xcode).
2. Point the toolchain at it once:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
3. Open the project:
   ```bash
   open GroovePlayer/GroovePlayer.xcodeproj
   ```
   (Regenerate it after editing `project.yml`: `xcodegen generate --spec GroovePlayer/project.yml --project GroovePlayer`.)
4. Pick an **iPad** simulator in the scheme bar and press **▶ Run** — or run the
   whole loop from the terminal:
   ```bash
   ./run_ipad.sh
   ```

### Run on a real iPad
Plug it in, select it as the destination, and set **Signing & Capabilities →
Team** to your Apple ID (a free account works for on-device install). Trust the
developer cert on the iPad under Settings → General → VPN & Device Management.

## What it does (offline)
- Browse the 35 grooves extracted from the Google Groove MIDI Dataset.
- **Analyze the Amen break** on-device into your own swing file (vDSP onset detection).
- Dial swing 0–127 and **play** the target loop with the groove stamped on —
  rendered natively.

## Example (MGMKit)

```swift
import MGMKit

// Triplet grid (subdivision 12 = eighth-note triplets, 3 per beat). A swung
// feel sits ON the slots, so the timing lane can stay all-zero — the grid
// itself carries the swing. bf is tempo-independent.
let straight = Groove(timeSignature: TimeSignature(4, 4), subdivision: 12,
                      unit: .bf, timing: [Double](repeating: 0, count: 12))
let swung = Groove(timeSignature: TimeSignature(4, 4), subdivision: 12, unit: .bf,
                   timing: (0..<12).map { $0 % 2 == 1 ? Double(bfPerBeat / 12) : 0 })
let map = GrooveMap([0: straight, 127: swung])

describeBF(3072, bpm: 60, sampleRate: 48000)
// -> BFDescription(bf: 3072, beats: 0.015625, noteValue: "1/64 beat",
//                  ms: 15.625, samples: 750.0)

// bf needs a tempo to become samples at render time:
let out = Render.grooved(target: targetSamples, sampleRate: 48000,
                         groove: map.resolve(127), tempoBpm: 120)
```
