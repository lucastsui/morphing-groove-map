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
    @Published var sttEditable = false
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

    let audio: AudioEngine
    private var target: (samples: [Float], sr: Int)?

    init(audio: AudioEngine) {
        self.audio = audio
        target = audio.loadMono("straight_target")
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

    /// Nudge the selected beat's offset by `deltaFBU` (used by the fbu row).
    func stepFBU(_ deltaFBU: Double) { selectedFBU = clampBF(selectedFBU + deltaFBU) }
    /// Nudge by milliseconds (ms row): convert to fbu at the current tempo.
    func stepMs(_ deltaMs: Double) { selectedFBU = clampBF(selectedFBU + msToBF(deltaMs, bpm: tempoBPM)) }
    /// Nudge by a fraction of the selected note unit (notes row).
    func stepNote(_ fraction: Double) { selectedFBU = clampBF(selectedFBU + fraction * noteUnit.fbu) }

    // MARK: per-beat display (for the .STT full overview)

    func beatTriplet(_ i: Int) -> (fbu: Double, ms: Double, note: String) {
        let v = timing.indices.contains(i) ? timing[i] : 0
        return (v, bfToMs(v, bpm: tempoBPM), bfToNoteValue(v))
    }

    // MARK: source playback / preview

    func previewPlay() {
        guard let t = target else { status = "straight_target.wav missing"; return }
        guard gridValid else { status = "invalid grid: adjust time signature / beat resolution"; return }
        let out = Render.grooved(target: t.samples, sampleRate: t.sr,
                                 groove: currentGroove(), tempoBpm: tempoBPM)
        audio.play(out, sr: t.sr, label: sttName)
        status = "playing \(sttName) (\(beatResolution) slots, \(Int(tempoBPM)) bpm)"
    }

    func playTarget() {
        guard let t = target else { status = "target missing"; return }
        audio.play(t.samples, sr: t.sr, label: "straight target")
        status = "playing straight target"
    }

    // MARK: extract (Generate tab)

    func analyzeAmen() {
        guard let a = audio.loadMono("amen") else { status = "amen.wav missing"; return }
        let g = Onset.extractGroove(a.samples, sampleRate: a.sr, bpm: tempoBPM,
                                    timeSignature: timeSignature,
                                    subdivision: gridValid ? subdivision : beatResolution, unit: .bf)
        loadGroove(g, name: "Amen Break")
        status = "analyzed amen.wav into \(sttName) (timing + velocity)"
    }

    func importMIDI(_ url: URL) {
        access(url) { data in
            let (_, bpm) = try MIDIImport.parse(data)
            let g = try MIDIImport.extractGroove(from: data, timeSignature: timeSignature,
                                                 subdivision: gridValid ? subdivision : beatResolution,
                                                 unit: .bf, bpm: bpm)
            tempoBPM = bpm
            loadGroove(g, name: url.deletingPathExtension().lastPathComponent)
            status = "imported MIDI \(url.lastPathComponent) (\(Int(bpm)) bpm)"
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
