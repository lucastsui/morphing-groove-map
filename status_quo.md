# Status Quo — Morphing Groove Map (handoff for context pickup)

_Last updated: 2026-06-04 (Spark-assisted remote analysis built, integrated, verified live, committed + pushed). This file is a self-handoff so a fresh context can resume fast._

## What this project is now
A **pure-Swift / Xcode-only iPad app** ("Groove Player") that captures the swing of a
drum beat as data, morphs between grooves, and stamps a groove onto other audio.
It started as a Python prototype; the whole thing was rewritten to Swift and the
Python was removed. Repo root: `/Users/tsuimingleong/Desktop/music_hackathon`.

Two parts:
- **`MGMKit/`** — pure-Swift Swift Package (no UIKit): the DSP + model + file formats. Builds & tests via the CLI.
- **`GroovePlayer/`** — SwiftUI iPad app (XcodeGen project) on top of MGMKit.

## Spark-assisted analysis (remote Demucs) — NEW, working
The dense-mix limitation is fixed by offloading analysis to the user's **DGX Spark**:
- **Service**: a FastAPI app on the Spark, `POST /analyze` (multipart audio) → htdemucs **drums stem** → librosa beat/tempo (with an octave-sanity guard) → fold → returns `{stt, report}` JSON. Lives in `/home/anaclast/groove-service/` (server.py, run.sh, venv); runs as a **systemd user unit `groove.service`** (Restart=always, linger on), htdemucs on **cuda**, alongside the unrelated `vllm-mxfp4` LLM container on :8000. Built by the Spark's own Claude from the spec in the chat.
- **Reach**: LAN peer-to-peer is blocked (Wi-Fi client isolation — even SSH), so use **Tailscale**: `http://100.73.106.98:8001`. mDNS `spark-4a7e.local` is broken (resolves to the docker bridge). SSH works over Tailscale: `anaclast@100.73.106.98`.
- **App side**: `RemoteAnalyzer.swift` POSTs the song and decodes the envelope via `MGMIO.decodeSTT` (reuses the exact .stt validation; plus a `subdivision % denominator` crash-guard). `Store.analyzeSong` is **remote-first with automatic on-device fallback**. Welcome tab has a **server-URL field + "Use Spark" toggle** (persisted via UserDefaults). Generate tab shows the engine used (`Spark · htdemucs+librosa` vs `on-device`).
- **ATS gotcha**: `Info.plist` uses **`NSAllowsArbitraryLoads` ALONE** — do NOT also add `NSAllowsLocalNetworking`, or iOS ignores arbitrary-loads and blocks the Tailscale (100.x) HTTP call.
- **Verified live in the sim**: *Fly Me to the Moon* → **120 bpm** via Spark (on-device read it as 60), stamped onto `straight_drums` and played. The Mac-side harness `tools/test_spark_analyze.py` passed all 8 songs against the service.
- **Headless app check**: launch with `SIMCTL_CHILD_SELFTEST=1` → analyzes bundled WAVs + any audio in Documents, applies each to `straight_drums`, writes `Documents/selftest_results.json`.

## Layout
```
MGMKit/Sources/MGMKit/
  Model.swift        units (ms↔samples↔bf), grid (straight+triplet), Groove, GrooveMap morph, MGMError+validation
  Onset.swift        vDSP onset detection + fold-to-offsets + velocity extraction
  Render.swift       slice/shift/overlap-add groove onto audio (percussive: option)
  Document.swift     MGMDocument — 128-slot .mgm, empty 0/127→no-swing, compatibility enforcement
  MGMIO.swift        .stt / .mgm JSON read/write
  MIDIImport.swift   Standard MIDI File parser → Groove (timing+velocity)
  SongAnalyzer.swift FULL-SONG analysis: median-filter HPSS + tempo/beat-track + fold→one bar + confidence
  Library.swift      load bundled groove_library.json
MGMKit/Sources/MGMValidate/main.swift   no-Xcode CLI checks (Tier-0 smoke)
MGMKit/Tests/MGMKitTests/   MGMKitTests + EngineGapTests + SongAnalyzerTests  (48 tests)
GroovePlayer/Sources/
  GroovePlayerApp.swift, ContentView.swift (5-tab TabView + shared components/charts)
  STTTabs.swift (Welcome / .STT full / .STT beats), MGMTabs.swift (.MGM / Generate)
  Store.swift (app model), AudioEngine.swift (AVFoundation glue)
GroovePlayer/Tests/StoreTests.swift, GroovePlayer/UITests/AppUITests.swift
GroovePlayer/Resources/  amen.wav, demoSongA.wav, demoSongB.wav, groove_library.json, straight_drums.wav
GroovePlayer/project.yml  (XcodeGen spec; regenerate after adding files)
run_tests.sh, TESTING.md, README.md, .github/workflows/ci.yml
```

## Key concepts
- **bf == fbu** (the spec's "fractional beat unit"): one beat = `196608 = 2¹⁶×3`. The ×3 makes triplets exact. `3072 fbu = 15.63 ms @60bpm = 1/64 beat`.
- **5 tabs:** Welcome (MIDI 1.0/2.0 toggle + project settings) · .STT full (display) · .STT beats (single-beat editor) · .MGM (128 slots) · Generate (export/import + full-song analyze/apply + demo).
- **Apply target sample** is now `straight_drums.wav` (a 16-bit straight drum loop). "Play target" plays it; "Preview" stamps the current groove onto it.

## Verified state (all green)
- `./run_tests.sh` → **ALL TIERS PASSED**: Tier-0 MGMValidate (~31 checks), Tier-1 MGMKit **48 tests**, Tier-2 Store **9 tests**, Tier-3 XCUITest **5 tests** (incl. crash-smoke).
- Built-in demo (`SIMCTL_CHILD_DEMO=1`) runs end-to-end: analyze bundled song A → show → apply to song B → play. No crashes.
- The 4 user songs are preloaded into the simulator app's Documents (see below) and selectable in the pickers.

## Git state  ✅ committed + pushed this session
- Branch **`main`**; remote `origin` = `github.com/lucastsui/morphing-groove-map`.
- Previously `origin/main` was at `8471947` (the rewrite + base test suite). The previously-uncommitted **on-device full-song feature** (`SongAnalyzer`, built-in demo, Generate file-picker fix, Files-sharing, target-sample swap) **and** the new **Spark-assisted remote analysis** were committed together (commingled across `Store.swift`/`SongAnalyzer.swift`, so a clean split wasn't possible) and **pushed to `origin/main`**.
- New since the rewrite: `RemoteAnalyzer.swift`, `tools/test_spark_analyze.py`, `SongAnalyzer.swift` (+ `SongReport` public init), `SongAnalyzerTests.swift`, `demoSongA/B.wav`, `straight_drums.wav`. Deleted: `straight_target.wav`.

## Recent work (this session, all uncommitted)
1. Full-song analysis (`SongAnalyzer`) + arbitrary-audio import (Generate: "Analyze song…" / "Apply to song…") + percussive-retime render. Decisions made by user: **on-device best-effort** analysis, **percussive re-time** apply, **one representative bar** output.
2. Built-in demo (`Store.runDemo()`, purple button on Generate, or `DEMO=1` env).
3. Bug fixes found by manual emulator QA: removed dead **Edit** on .STT full; **.MGM Edit** now gates slot add/remove; **Play target** status names the real target; **Generate file pickers were all broken** (4 stacked `.fileImporter`s → consolidated to one Bool+enum importer) — then a second fix (optional state cleared by dismiss before completion → switched to non-cleared enum).
4. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` so the app's Documents shows in Files → On My iPad → Groove Player (makes preloaded songs selectable in the picker).
5. Replaced the bundled apply-target sample with `straight_drums.wav`.

## Known limitations (honest)
- **Full-mix song analysis is rough** (HPSS, no source separation). `Fly Me to the Moon` analyzed to **60 bpm (a half-tempo octave error) · swing 9% · "confidence 100%"**. Drum-forward material / clean drum stems read well; dense vocal+orchestra mixes don't.
- **The confidence score is over-optimistic** — it only measures beat-grid energy concentration, not tempo-octave or swing accuracy. Worth improving.
- `precondition` crash paths (e.g. `Render.grooved` bf-without-tempo) aren't unit-tested (XCTest can't catch a `precondition`).
- Onset accuracy validated only vs synthetic ground truth.

## Open threads / next steps (offered, NOT built)
1. **Commit + push** the 18 uncommitted changes (highest priority — big unsaved feature set).
2. **Demucs on DGX Spark, remote — ✅ BUILT + INTEGRATED + VERIFIED (this session).** See "Spark-assisted analysis (remote Demucs)" above. Remaining polish: a **bearer token** (the service is currently unauthenticated, tailnet-only), a real **`downbeatSec`** (madmom didn't build on aarch64 → bar phase falls back to beat[0]), a less-saturated **confidence heuristic** (reads 1.0 for everything), and a **DHCP reservation / fixed `.local`** so the URL survives lease changes.
3. **"Use built-in sample" reset button** on Generate — once a song is set as the apply target there's no way back to the bundled sample without relaunch.
4. **Tap-tempo + a 0–127 swing-amount dial** on the apply/preview screen (currently Preview applies the groove at 100%; partial swing needs the .MGM morph).
5. Improve the **confidence heuristic**.

## How to build / run / test
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # needed: xcode-select points at CLT
./run_tests.sh                                   # all 4 tiers
swift test --package-path MGMKit                 # engine only (48 tests)
swift run  --package-path MGMKit MGMValidate     # no-Xcode smoke
xcodegen generate --spec GroovePlayer/project.yml --project GroovePlayer   # after adding/removing files
# build + run the app on the sim:
UDID=$(cat /tmp/gp_udid.txt)   # GP-iPad = F69AF2F8-6354-44FA-9B9D-2457B9C21AD1 (iOS 26.5)
xcodebuild build -project GroovePlayer/GroovePlayer.xcodeproj -scheme GroovePlayer \
  -destination "platform=iOS Simulator,id=$UDID" -configuration Debug CODE_SIGNING_ALLOWED=NO -derivedDataPath /tmp/gp_dd
xcrun simctl install "$UDID" /tmp/gp_dd/Build/Products/Debug-iphonesimulator/GroovePlayer.app
SIMCTL_CHILD_TAB=4 SIMCTL_CHILD_DEMO=1 xcrun simctl launch "$UDID" com.lucastsui.GroovePlayer
```

## Environment gotchas
- **`xcode-select` points at Command Line Tools**, not Xcode. `swift test` (XCTest) and `xcodebuild` (iOS SDK) need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. MGMValidate runs on CLT alone.
- **`xcodegen`** is installed at `/opt/homebrew/bin/xcodegen`.
- Launch env: `SIMCTL_CHILD_TAB=<0–4>` sets the initial tab; `SIMCTL_CHILD_DEMO=1` auto-runs the demo.
- The trailing `xcrun: error: unable to find utility "simctl"` after `xcodebuild test` is **benign** (post-test step using CLT xcrun); tests still pass. Won't happen on CI (Xcode selected there).
- A second app icon **"GroovePlayerUITests-Runner"** on the sim is the normal **XCUITest runner**, not a duplicate.
- **Xcode IS installed and open** — closing/moving the project while Xcode has it open re-materialises stale `ios/`-style folders (cosmetic).
- User's source songs: `~/Downloads/music/*.mp3` (Sinatra "Fly Me to the Moon", Louis Armstrong "All of Me", Nat King Cole "Autumn Leaves", "Don't Get Around Much Anymore"). Straight drum samples: `~/Downloads/straight_drums.{mid,wav}` (wav is 16-bit PCM, Music-playable).
- Preloaded into the sim's app Documents (via `xcrun simctl get_app_container <udid> com.lucastsui.GroovePlayer data` → `Documents/`); reinstalling the app preserves them.

## Policy note
I will **not** download copyrighted audio from YouTube etc. (declined this session). Copying the user's **own local files** into their simulator for testing is fine and was done. Running Demucs on the user's own audio (locally or on their own DGX) is fine.

## Narrative arc
The session opened with "can it extract the swing of *Fly Me to the Moon*?" — answer then: not reliably (no source separation, t=0/constant-tempo assumptions). After building the whole Swift app + on-device `SongAnalyzer`, we ran it on that exact song in the emulator: it works end-to-end but honestly shows the dense-mix limitation (60 bpm / 9%). The Demucs-on-DGX path (next step #2) is the way to actually close that gap.
