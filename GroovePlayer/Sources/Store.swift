// Shared app state for the 5-tab MGM editor (Welcome / .STT full / .STT beats /
// .MGM / Generate). Holds project settings, the current .STT (single timing
// template) being edited, the current .MGM (128-slot map), and all the glue to
// MGMKit: fbu == bf (beat fractions), conversions, .stt/.mgm I/O, render.
import Foundation
import MGMKit
import SwiftUI

/// MIDI velocity precision. 1.0 = 7-bit (0–127), 2.0 = 16-bit (0–65535).
/// Per Sebastian this affects velocity only, never timing or gate.
enum MIDIMode: String, CaseIterable, Identifiable {
    case v1 = "MIDI 1.0", v2 = "MIDI 2.0"
    var id: String { rawValue }
    var maxVelocity: Int { self == .v1 ? 127 : 65535 }
}

/// The three interchangeable units a timing offset is shown / typed in.
enum DisplayUnit: String, CaseIterable, Identifiable { case fbu, ms, note; var id: String { rawValue } }

/// A note value for the "notes" step row, expressed as an fbu size (1/N beat).
struct NoteUnit: Identifiable, Hashable {
    let name: String
    let fbu: Double
    var id: String { name }
    static let all: [NoteUnit] = [
        .init(name: "whole",       fbu: 196608),    // 1 beat
        .init(name: "half",        fbu: 98304),     // 1/2 beat
        .init(name: "quarter",     fbu: 49152),     // 1/4 beat
        .init(name: "8th",         fbu: 24576),     // 1/8 beat
        .init(name: "16th",        fbu: 12288),
        .init(name: "32nd",        fbu: 6144),
        .init(name: "64th",        fbu: 3072),       // 3072 fbu = 15.63 ms @60bpm
        .init(name: "8th triplet", fbu: 16384),     // 1/12 beat (exact, ÷3)
    ]
}

@MainActor
final class Store: ObservableObject {
    // MARK: project settings
    @Published var tsNumerator = 4
    @Published var tsDenominator = 4
    @Published var tempoBPM: Double = 60
    @Published var beatResolution = 16          // total slots in the bar
    @Published var midiMode: MIDIMode = .v1

    // MARK: current .STT (the single timing template being edited)
    @Published var sttName = "Amen Break"
    @Published var timing: [Double] = []        // per-slot offset, fbu (== bf)
    @Published var velocity: [Double] = []       // per-slot velocity, 0...maxVelocity
    @Published var gate: [Double] = []           // per-slot gate length, fbu
    @Published var selectedBeat = 0
    @Published var noteUnitIndex = 6             // default "64th"
    @Published var adjustUnit: DisplayUnit = .fbu

    // MARK: current .MGM (128 slots)
    @Published var mgmName = "No swing – Amen Break"
    @Published var mgmEditable = false
    @Published var slotName: [Int: String] = [:]      // slot -> display name
    @Published var slotGroove: [Int: Groove] = [:]    // slot -> template

    @Published var status = ""

    // Full-song "apply target" (song B) + the last analysis report.
    @Published var renderTargetName = "straight drums"
    @Published var targetIsSong = false
    @Published var lastReport: SongReport?
    @Published var lastEngine = ""                 // "Spark · htdemucs+librosa" / "on-device" / "MIDI" / "AGR"
    @Published var clip: ClipGroove?               // lossless event-list source of truth (.agr import)
    @Published var tab = Int(ProcessInfo.processInfo.environment["TAB"] ?? "0") ?? 0

    // Remote analysis (Spark) settings — persisted across launches.
    @Published var useRemote = true { didSet { UserDefaults.standard.set(useRemote, forKey: "gp.useRemote") } }
    @Published var serverURL = "http://100.73.106.98:8001" { didSet { UserDefaults.standard.set(serverURL, forKey: "gp.serverURL") } }

    let audio: AudioEngine
    private var target: (samples: [Float], sr: Int)?

    init(audio: AudioEngine) {
        self.audio = audio
        // Restore persisted Spark settings (didSet does not fire inside init).
        if let s = UserDefaults.standard.string(forKey: "gp.serverURL") { serverURL = s }
        if UserDefaults.standard.object(forKey: "gp.useRemote") != nil {
            useRemote = UserDefaults.standard.bool(forKey: "gp.useRemote")
        }
        seedBundledSongs()
        target = audio.loadMono("straight_drums")
        resizeLanes()
        // Seed a light swing so the editor/overview show real data (off-beats
        // pushed +3072 fbu = 15.63 ms = a 1/64 beat at 60 BPM, per the sketch).
        for i in 0..<beatResolution where i % 2 == 1 { timing[i] = 3072 }
        selectedBeat = min(3, beatResolution - 1)
        // A couple of default .mgm slots, matching the sketch.
        slotName[0] = "No Swing"; slotGroove[0] = straightGroove()
        slotName[74] = "Random Groove.STT"; slotGroove[74] = currentGroove()
        slotName[127] = "Amen Break.STT"; slotGroove[127] = currentGroove()
    }

    /// Copy bundled sample songs into Documents so they show in the file picker
    /// alongside the user's own songs (so they're analyzed via "Analyze song…").
    private func seedBundledSongs() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let seeds = [(resource: "amen", filename: "Amen Break.wav")]
        for s in seeds {
            let dest = docs.appendingPathComponent(s.filename)
            guard !FileManager.default.fileExists(atPath: dest.path),
                  let src = Bundle.main.url(forResource: s.resource, withExtension: "wav") else { continue }
            try? FileManager.default.copyItem(at: src, to: dest)
        }
    }

    var noteUnit: NoteUnit { NoteUnit.all[min(max(noteUnitIndex, 0), NoteUnit.all.count - 1)] }

    // MARK: grid helpers

    var timeSignature: TimeSignature { TimeSignature(tsNumerator, tsDenominator) }

    /// Engine subdivision so that slotCount(ts, subdivision) == beatResolution.
    var subdivision: Int { max(1, beatResolution * tsDenominator / max(1, tsNumerator)) }

    /// Whether the current TS + beat-resolution form a valid engine grid.
    var gridValid: Bool {
        tsNumerator > 0 && tsDenominator > 0 && beatResolution > 0
            && (beatResolution * tsDenominator) % tsNumerator == 0
            && subdivision % tsDenominator == 0
    }

    /// Resize the per-slot lanes to `beatResolution`, preserving existing values.
    func resizeLanes() {
        func fit(_ a: [Double], _ fill: Double) -> [Double] {
            if a.count == beatResolution { return a }
            if a.count > beatResolution { return Array(a.prefix(beatResolution)) }
            return a + [Double](repeating: fill, count: beatResolution - a.count)
        }
        timing = fit(timing, 0)
        velocity = fit(velocity, Double(min(100, midiMode.maxVelocity)))
        gate = fit(gate, 0)
        if selectedBeat >= beatResolution { selectedBeat = max(0, beatResolution - 1) }
    }

    // MARK: groove construction

    func currentGroove() -> Groove {
        Groove(timeSignature: timeSignature, subdivision: gridValid ? subdivision : beatResolution,
               unit: .bf, timing: timing, velocity: velocity, gate: gate)
    }

    func straightGroove() -> Groove {
        Groove(timeSignature: timeSignature, subdivision: gridValid ? subdivision : beatResolution,
               unit: .bf, timing: [Double](repeating: 0, count: beatResolution),
               velocity: [Double](repeating: 0, count: beatResolution),
               gate: [Double](repeating: 0, count: beatResolution))
    }

    // MARK: selected-beat offset, in the three units

    var selectedFBU: Double {
        get { timing.indices.contains(selectedBeat) ? timing[selectedBeat] : 0 }
        set { if timing.indices.contains(selectedBeat) { timing[selectedBeat] = newValue } }
    }
    var selectedMs: Double {
        get { bfToMs(selectedFBU, bpm: tempoBPM) }
        set { selectedFBU = msToBF(newValue, bpm: tempoBPM) }
    }
    var selectedNoteLabel: String { bfToNoteValue(selectedFBU) }
    /// The offset as a count of the current note unit, so the "note" box is
    /// directly typeable like fbu/ms (6144 fbu ÷ 64th[3072] = 2.0).
    var selectedNoteCount: Double {
        get { noteUnit.fbu != 0 ? selectedFBU / noteUnit.fbu : 0 }
        set { selectedFBU = clampBF(newValue * noteUnit.fbu) }
    }

    /// Nudge the selected beat's offset by `deltaFBU` (used by the fbu row).
    func stepFBU(_ deltaFBU: Double) { selectedFBU = clampBF(selectedFBU + deltaFBU) }
    /// Nudge by milliseconds (ms row): convert to fbu at the current tempo.
    func stepMs(_ deltaMs: Double) { selectedFBU = clampBF(selectedFBU + msToBF(deltaMs, bpm: tempoBPM)) }
    /// Nudge by a fraction of the selected note unit (notes row).
    func stepNote(_ fraction: Double) { selectedFBU = clampBF(selectedFBU + fraction * noteUnit.fbu) }

    // MARK: snap-to-grid (drag handlers only)

    @Published var snapEnabled = false
    @Published var snapStep = 128       // fbu; variable 16…1024

    /// Snap a (continuous) offset to the nearest multiple of `snapStep` when
    /// snapping is on. Used only by the drag gestures, not typed/step values.
    func snapped(_ v: Double) -> Double {
        (snapEnabled && snapStep > 0) ? (v / Double(snapStep)).rounded() * Double(snapStep) : v
    }

    // MARK: per-beat display (for the .STT full overview)

    func beatTriplet(_ i: Int) -> (fbu: Double, ms: Double, note: String) {
        let v = timing.indices.contains(i) ? timing[i] : 0
        return (v, bfToMs(v, bpm: tempoBPM), bfToNoteValue(v))
    }

    // MARK: source playback / preview

    func previewPlay() {
        guard let t = target else { status = "no apply target loaded"; return }
        guard gridValid else { status = "invalid grid: adjust time signature / beat resolution"; return }
        let g = currentGroove(), bpm = tempoBPM, perc = targetIsSong
        let name = sttName, res = beatResolution, targetName = renderTargetName
        status = "rendering…"
        Task.detached(priority: .userInitiated) {
            let out = Render.grooved(target: t.samples, sampleRate: t.sr,
                                     groove: g, tempoBpm: bpm, percussive: perc)
            await MainActor.run {
                self.audio.play(out, sr: t.sr, label: name)
                self.status = "playing \(name) onto \(targetName) (\(res) slots, \(Int(bpm)) bpm)"
            }
        }
    }

    func playTarget() {
        guard let t = target else { status = "target missing"; return }
        audio.play(t.samples, sr: t.sr, label: renderTargetName)
        status = "playing \(renderTargetName)"
    }

    // MARK: MIDI import (Generate tab)

    func importMIDI(_ url: URL) {
        access(url) { data in
            let (notes, bpm) = try MIDIImport.parse(data)
            // Exact single-bar extraction (musical domain, auto-grid, no averaging/rejection).
            let g = try MIDIImport.extractGrooveExact(from: data, timeSignature: timeSignature, bpm: bpm)
            // swing ratio from off-beat note positions (same convention as the audio analyzer)
            let offbeats = notes.map { ($0.timeSeconds * bpm / 60).truncatingRemainder(dividingBy: 1.0) }
                                .filter { $0 > 0.4 && $0 < 0.8 }.sorted()
            let swing = offbeats.isEmpty ? 0.5 : offbeats[offbeats.count / 2]
            tempoBPM = bpm
            loadGroove(g, name: url.deletingPathExtension().lastPathComponent)
            lastReport = SongReport(tempoBPM: bpm, swingRatio: swing, confidence: 1.0,
                                    beatsDetected: timeSignature.numerator, onsetsUsed: notes.count)
            lastEngine = "MIDI"
            status = "imported MIDI \(url.lastPathComponent) — \(notes.count) notes, \(Int(bpm)) bpm"
        }
    }

    /// Import an Ableton .agr groove: parse to the lossless ClipGroove (kept in
    /// `clip`) and load its per-slot projection into the bar editor.
    func importAGR(_ url: URL) {
        access(url) { data in
            let parsed = try AGRImport.parse(data)
            loadGroove(parsed.groove(), name: url.deletingPathExtension().lastPathComponent)
            self.clip = parsed                                  // lossless source of truth (set after loadGroove clears it)
            let offb = parsed.notes.filter(\.enabled)
                             .map { $0.startBeats.truncatingRemainder(dividingBy: 1.0) }
                             .filter { $0 > 0.4 && $0 < 0.8 }.sorted()
            let swing = offb.isEmpty ? 0.5 : offb[offb.count / 2]
            lastReport = SongReport(tempoBPM: tempoBPM, swingRatio: swing, confidence: 1.0,
                                    beatsDetected: timeSignature.numerator, onsetsUsed: parsed.notes.count)
            let np = parsed.pitches.count
            lastEngine = "AGR · \(np) pitch\(np == 1 ? "" : "es")"
            status = "imported .agr \(url.lastPathComponent) — \(parsed.notes.count) notes, \(np) pitch(es), \(parsed.bars) bar(s)"
        }
    }

    // MARK: full-song analyze (song A) / apply target (song B)

    /// Analyze an arbitrary audio file's swing into the current .STT. Tries the
    /// Spark service first (Demucs source separation) and falls back to on-device
    /// analysis when remote is off or the Spark is unreachable.
    func analyzeSong(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try? Data(contentsOf: url)             // bytes to POST to the Spark
        let samples = audio.loadMono(url: url)            // kept for the on-device fallback
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard data != nil || samples != nil else {
            status = "couldn't read \(url.lastPathComponent)"; return
        }
        runAnalysis(name: url.deletingPathExtension().lastPathComponent,
                    filename: url.lastPathComponent, audioData: data, fallback: samples)
    }

    /// Remote-first analysis with an on-device fallback. Updates the .STT, tempo,
    /// report, and `lastEngine` when done.
    func runAnalysis(name: String, filename: String,
                     audioData: Data?, fallback: (samples: [Float], sr: Int)?) {
        let ts = timeSignature, sub = gridValid ? subdivision : 16
        let remote = useRemote, server = serverURL
        status = "analyzing \(name)…"
        Task { [weak self] in
            guard let self else { return }
            if remote, let data = audioData {
                do {
                    let r = try await RemoteAnalyzer.analyze(audio: data, filename: filename, serverURL: server)
                    self.applyAnalysis(groove: r.groove, report: r.report, name: name, engine: "Spark · \(r.engine)")
                    return
                } catch {
                    self.status = "Spark unavailable (\(RemoteAnalyzer.describe(error))) — analyzing on-device…"
                }
            }
            guard let a = fallback else {
                self.status = "couldn't analyze \(name): Spark unreachable and no local audio"; return
            }
            let res = await Task.detached(priority: .userInitiated) {
                SongAnalyzer.analyzeSong(a.samples, sampleRate: a.sr, timeSignature: ts, subdivision: sub)
            }.value
            self.applyAnalysis(groove: res.groove, report: res.report, name: name, engine: "on-device")
        }
    }

    private func applyAnalysis(groove: Groove, report: SongReport, name: String, engine: String) {
        tempoBPM = report.tempoBPM
        loadGroove(groove, name: name)
        lastReport = report
        lastEngine = engine
        status = String(format: "analyzed %@ — %@ · %.0f bpm · swing %.0f%% · conf %.0f%%",
                        name, engine, report.tempoBPM, swingPercent(report.swingRatio), report.confidence * 100)
    }

    /// Set an arbitrary audio file as the apply target (song B).
    func setRenderTarget(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let t = audio.loadMono(url: url) else {
            status = "couldn't read \(url.lastPathComponent)"; return
        }
        target = t
        targetIsSong = true
        renderTargetName = url.deletingPathExtension().lastPathComponent
        status = "apply target set to \(renderTargetName) — Preview to hear the groove stamped on"
    }

    /// 0.5 → 0%, ~0.667 → 100% (straight … triplet swing).
    func swingPercent(_ ratio: Double) -> Double {
        max(0, min(150, (ratio - 0.5) / (2.0 / 3.0 - 0.5) * 100))
    }

    /// Built-in end-to-end demo: extract bundled song A's swing, show it, then
    /// stamp it onto bundled song B. Walks the tabs + status like a guided demo.
    func runDemo() {
        guard let aURL = Bundle.main.url(forResource: "demoSongA", withExtension: "wav"),
              let a = audio.loadMono(url: aURL),
              let bURL = Bundle.main.url(forResource: "demoSongB", withExtension: "wav") else {
            status = "demo songs missing from the bundle"; return
        }
        Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.tab = 4; self.status = "Demo ①  analyzing song A (a swung groove)…" }
            let res = await Task.detached(priority: .userInitiated) {
                SongAnalyzer.analyzeSong(a.samples, sampleRate: a.sr,
                                         timeSignature: TimeSignature(4, 4), subdivision: 16)
            }.value
            await MainActor.run {
                self.tempoBPM = res.report.tempoBPM
                self.loadGroove(res.groove, name: "demoSongA")
                self.lastReport = res.report
                self.status = String(format: "Demo ②  extracted A’s swing — %.0f bpm · swing %.0f%% · confidence %.0f%%",
                                     res.report.tempoBPM, self.swingPercent(res.report.swingRatio),
                                     res.report.confidence * 100)
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run { self.tab = 1 }                 // .STT full: show the extracted offsets
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            await MainActor.run {
                self.setRenderTarget(bURL)
                self.tab = 4
                self.status = "Demo ③  apply target = song B (straight)"
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                self.status = "Demo ④  stamping A’s swing onto song B…"
                self.previewPlay()
            }
        }
    }

    /// Headless end-to-end check (launch with SELFTEST=1): analyze every available
    /// song through the Spark and stamp each resulting groove onto the sample drum
    /// beat (straight_drums). Writes Documents/selftest_results.json for the Mac
    /// test harness to read back. Bundled WAVs + any audio dropped in Documents.
    func runRemoteSelfTest() {
        let server = serverURL
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let target = audio.loadMono("straight_drums") else {
            status = "SELFTEST: straight_drums.wav missing from bundle"; return
        }
        var songs: [(name: String, url: URL)] = []
        for r in ["demoSongA", "demoSongB"] {   // amen is seeded into Documents and picked up below
            if let u = Bundle.main.url(forResource: r, withExtension: "wav") { songs.append((r, u)) }
        }
        let exts: Set<String> = ["mp3", "m4a", "wav", "flac", "aif", "aiff"]
        if let items = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            for u in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where exts.contains(u.pathExtension.lowercased()) {
                songs.append((u.deletingPathExtension().lastPathComponent, u))
            }
        }
        status = "SELFTEST: \(songs.count) songs → Spark → apply to straight_drums…"
        Task { [weak self] in
            guard let self else { return }
            var results: [[String: Any]] = []
            for (i, song) in songs.enumerated() {
                self.status = "SELFTEST \(i + 1)/\(songs.count): \(song.name)…"
                var row: [String: Any] = ["song": song.name]
                do {
                    let data = try Data(contentsOf: song.url)
                    let r = try await RemoteAnalyzer.analyze(audio: data, filename: song.url.lastPathComponent,
                                                             serverURL: server)
                    let rendered = await Task.detached(priority: .userInitiated) {
                        Render.grooved(target: target.samples, sampleRate: target.sr,
                                       groove: r.groove, tempoBpm: r.report.tempoBPM, percussive: false)
                    }.value
                    let ok = rendered.count >= target.samples.count && r.groove.timing.count >= 16
                    row["engine"] = r.engine
                    row["tempoBpm"] = r.report.tempoBPM
                    row["swingRatio"] = r.report.swingRatio
                    row["confidence"] = r.report.confidence
                    row["slots"] = r.groove.timing.count
                    row["renderedSamples"] = rendered.count
                    row["ok"] = ok
                } catch {
                    row["ok"] = false
                    row["error"] = RemoteAnalyzer.describe(error)
                }
                results.append(row)
            }
            let passed = results.filter { ($0["ok"] as? Bool) == true }.count
            let summary: [String: Any] = ["server": server, "passed": passed,
                                          "total": results.count, "results": results]
            if let d = try? JSONSerialization.data(withJSONObject: summary,
                                                   options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: docs.appendingPathComponent("selftest_results.json"))
            }
            self.status = "SELFTEST done: \(passed)/\(results.count) passed → selftest_results.json"
        }
    }

    // MARK: .stt / .mgm files

    func loadSTT(_ url: URL) {
        access(url) { data in
            let g = try MGMIO.decodeSTT(data)
            loadGroove(g, name: url.deletingPathExtension().lastPathComponent)
            status = "loaded \(url.lastPathComponent)"
        }
    }

    func saveSTT() {
        guard gridValid else { status = "invalid grid; can't save"; return }
        do {
            let url = documents("\(safe(sttName)).stt")
            try MGMIO.saveSTT(currentGroove(), to: url)
            status = "saved \(url.lastPathComponent) to Documents"
        } catch { status = "save failed: \(error)" }
    }

    func loadMGM(_ url: URL) {
        access(url) { data in
            let doc = try MGMIO.decodeMGM(data)
            tsNumerator = doc.timeSignature.numerator
            tsDenominator = doc.timeSignature.denominator
            slotName.removeAll(); slotGroove.removeAll()
            for pos in doc.populatedPositions {
                slotGroove[pos] = doc.slots[pos]
                slotName[pos] = pos == 0 ? "No Swing" : "slot \(pos).STT"
            }
            mgmName = url.deletingPathExtension().lastPathComponent
            status = "loaded \(url.lastPathComponent) (\(doc.populatedPositions.count) slots)"
        }
    }

    func saveMGM() {
        do {
            var doc = try MGMDocument(timeSignature: timeSignature,
                                      subdivision: gridValid ? subdivision : beatResolution, unit: .bf)
            for (pos, g) in slotGroove where pos != 0 { try doc.setSlot(pos, g) }
            let url = documents("\(safe(mgmName)).mgm")
            try MGMIO.saveMGM(doc, to: url)
            status = "saved \(url.lastPathComponent) to Documents"
        } catch { status = "save failed: \(error)" }
    }

    /// Put the current .STT into an .mgm slot (the "+" / add-to-slot action).
    func assignCurrentToSlot(_ pos: Int) {
        guard (0...127).contains(pos) else { status = "slot must be 0–127"; return }
        slotGroove[pos] = currentGroove()
        slotName[pos] = "\(sttName).STT"
        status = "added \(sttName).STT to slot \(pos)"
    }

    // MARK: helpers

    private func loadGroove(_ g: Groove, name: String) {
        tsNumerator = g.timeSignature.numerator
        tsDenominator = g.timeSignature.denominator
        beatResolution = g.timing.count
        timing = g.timing
        velocity = g.velocity ?? [Double](repeating: Double(min(100, midiMode.maxVelocity)), count: g.timing.count)
        gate = g.gate ?? [Double](repeating: 0, count: g.timing.count)
        selectedBeat = 0
        sttName = name
        clip = nil                          // any plain-groove load drops the lossless .agr source
    }

    private func access(_ url: URL, _ body: (Data) throws -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try body(try Data(contentsOf: url)) }
        catch { status = "failed: \(error)" }
    }

    private func documents(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    private func safe(_ s: String) -> String {
        let c = String(s.map { ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return c.isEmpty ? "groove" : c
    }
}
