// CLI validator for MGMKit -- runs without Xcode/XCTest (`swift run MGMValidate`).
// Verifies the morph spec examples and, crucially, the vDSP onset port's
// accuracy against synthetic ground truth (mirrors the Python harness).
import Foundation
import MGMKit

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print((cond ? "  ok   " : "  FAIL ") + msg)
    if !cond { failures += 1 }
}
func checkThrows(_ msg: String, _ body: () throws -> Void) {
    do { try body(); check(false, msg + " (expected an error)") }
    catch { check(true, msg) }
}
func checkNoThrow(_ msg: String, _ body: () throws -> Void) {
    do { try body(); check(true, msg) }
    catch { check(false, msg + " — threw \(error)") }
}
/// Minimal format-0 SMF: 480 tpq, 120 BPM, two note-ons (C vel100 @0s, C vel80 @0.25s).
func makeSMF() -> Data {
    var t: [UInt8] = []
    t += [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]   // tempo = 500000 µs/qtr (120 BPM)
    t += [0x00, 0x90, 0x3C, 0x64]                       // dt 0   note-on  C, vel 100
    t += [0x81, 0x70, 0x90, 0x3C, 0x50]                // dt 240 note-on  C, vel 80
    t += [0x00, 0xFF, 0x2F, 0x00]                       // dt 0   end of track
    let len = t.count
    var d: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]  // MThd fmt0 ntrks1 div480
    d += [0x4D, 0x54, 0x72, 0x6B,
          UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
    d += t
    return Data(d)
}

// ---- morph spec checks ----------------------------------------------------
func g(_ t: [Double]) -> Groove { Groove(timeSignature: TimeSignature(4,4), subdivision: 8, unit: .ms, timing: t) }

print("Morph / units / grid:")
check(abs(msToSamples(30, sampleRate: 48000) - 1440) < 1e-6, "30ms @48k = 1440 samples")
check(slotCount(TimeSignature(4,4), subdivision: 16) == 16, "4/4 sixteenths = 16 slots")
check(slotCount(TimeSignature(3,4), subdivision: 8) == 6, "3/4 eighths = 6 slots")
let map = GrooveMap([0: g([0,0,0,0,0,0,0,0]), 127: g([0,30,0,30,0,30,0,30])])
check(abs(map.resolve(63).timing[1] - 30*63/127) < 1e-6, "dial 63 midpoint interpolation")
let m3 = GrooveMap([0: g(Array(repeating:0,count:8)), 47: g(Array(repeating:10,count:8)), 127: g(Array(repeating:100,count:8))])
check(abs(m3.resolve(23.5).timing[0] - 5) < 1e-6, "multi-anchor bracket picks 0..47 pair")

// ---- beat fractions (bf) + triplets ---------------------------------------
print("\nBeat fractions / triplets:")
check(bfPerBeat == 196608 && bfPerBeat % 3 == 0, "bfPerBeat = 196608 = 2^16*3 (triplet-exact)")
check(abs(bfToMs(3072, bpm: 60) - 15.625) < 1e-9, "UC-6: 3072 bf @60bpm = 15.625 ms")
check(bfToNoteValue(3072) == "1/64 beat", "3072 bf -> '1/64 beat'")
check(bfToNoteValue(65536) == "1/3 beat (triplet)", "65536 bf -> '1/3 beat (triplet)'")
check(abs(bfToMs(Double(bfPerBeat/4), bpm: 120) - 125) < 1e-9, "tempo-independent: 1/4 beat @120bpm = 125 ms")
check(slotCount(TimeSignature(4,4), subdivision: 12) == 12, "triplet grid: 4/4 subdiv 12 = 12 slots")
check(isTripletSubdivision(12) && !isTripletSubdivision(16), "isTripletSubdivision(12)=true, (16)=false")

// ---- deterministic RNG ----------------------------------------------------
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUniform() -> Float { Float(next() >> 11) * Float(1.0 / 9007199254740992.0) }
    mutating func nextGaussian() -> Float {
        let u1 = max(nextUniform(), 1e-7), u2 = nextUniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

// ---- onset accuracy vs synthetic ground truth -----------------------------
let sr = 48000, N = 16
let bpm = 120.0
let slotS = (60.0 / bpm) / 4.0
let leadS = 0.25

func synth(_ offsetsMs: [Double], seed: UInt64) -> [Float] {
    var rng = SplitMix64(seed: seed)
    let total = Int((leadS + slotS * Double(N) * 4) * Double(sr)) + sr / 2
    var y = [Float](repeating: 0, count: total)
    let burst = Int(Double(sr) * 0.018)
    for bar in 0..<4 {
        for i in 0..<N {
            let t = leadS + Double(bar * N + i) * slotS + offsetsMs[i] / 1000.0
            let s = Int(t * Double(sr))
            for k in 0..<burst where s + k < total {
                let env = pow(1 - Float(k) / Float(burst), 2)
                y[s + k] += rng.nextGaussian() * env * 0.6
            }
        }
    }
    return y
}

func extract(_ y: [Float]) -> [Double] {
    let times = Onset.accurateOnsetTimes(y, sampleRate: sr).map { $0 - leadS }
    return Onset.offsets(fromOnsetTimes: times, bpm: bpm,
                         timeSignature: TimeSignature(4,4), subdivision: N, unit: .ms)
}

print("\nOnset accuracy (synthetic ground truth, MAE must be < 2 ms):")
let cases: [(String, [Double])] = [
    ("straight", Array(repeating: 0, count: N)),
    ("swing+22", (0..<N).map { $0 % 2 == 1 ? 22 : 0 }),
    ("large+40", (0..<N).map { $0 % 2 == 1 ? 40 : 0 }),
]
for (name, truth) in cases {
    let got = extract(synth(truth, seed: 1))
    let mae = zip(got, truth).map { abs($0 - $1) }.reduce(0, +) / Double(N)
    check(mae < 2.0, String(format: "%-9@ MAE = %.2f ms", name as NSString, mae))
}

// ---- render smoke test ----------------------------------------------------
print("\nRender:")
let target = synth(Array(repeating: 0, count: N), seed: 2)
let groove = Groove(timeSignature: TimeSignature(4,4), subdivision: N, unit: .ms,
                    timing: (0..<N).map { $0 % 2 == 1 ? 30 : 0 })
let out = Render.grooved(target: target, sampleRate: sr, groove: groove)
check(out.count >= target.count, "render output produced (\(out.count) samples)")
check((out.map { abs($0) }.max() ?? 0) <= 1.0001, "render output not clipping")

// A bf groove renders only when a tempo is supplied to realise it as samples.
let bfGroove = Groove(timeSignature: TimeSignature(4,4), subdivision: 12, unit: .bf,
                      timing: (0..<12).map { $0 % 2 == 1 ? Double(bfPerBeat/12) : 0 })
let bfOut = Render.grooved(target: target, sampleRate: sr, groove: bfGroove, tempoBpm: 120)
check(bfOut.count >= target.count, "bf groove render produced output (tempoBpm: 120)")

// ---- .stt / .mgm file formats + enforcement -------------------------------
print("\nFile formats / documents / enforcement:")
do {
    let n = 16
    let swung = Groove(timeSignature: TimeSignature(4,4), subdivision: n, unit: .bf,
                       timing: (0..<n).map { $0 % 2 == 1 ? Double(bfPerBeat / 12) : 0 },
                       velocity: (0..<n).map { _ in 100.0 })
    checkNoThrow(".stt encode→decode round-trip") {
        let back = try MGMIO.decodeSTT(MGMIO.encodeSTT(swung))
        check(back.timing == swung.timing && back.velocity == swung.velocity,
              ".stt preserves timing + velocity")
    }
    var doc = try MGMDocument(timeSignature: TimeSignature(4,4), subdivision: n, unit: .bf)
    try doc.setSlot(127, swung)
    check(doc.resolve(0).timing.allSatisfy { $0 == 0 }, "empty slot 0 → no-swing (all zero)")
    check(doc.resolve(127).timing == swung.timing, "slot 127 resolves to its .stt")
    checkNoThrow(".mgm encode→decode round-trip") {
        let back = try MGMIO.decodeMGM(MGMIO.encodeMGM(doc))
        check(back.resolve(127).timing == swung.timing, ".mgm preserves slot 127")
        check(back.populatedPositions == [127], ".mgm stores only populated slots")
    }
    let n34 = slotCount(TimeSignature(3,4), subdivision: n)
    let wrongTS = Groove(timeSignature: TimeSignature(3,4), subdivision: n, unit: .bf,
                         timing: [Double](repeating: 0, count: n34),
                         velocity: [Double](repeating: 0, count: n34))
    checkThrows("incompatible time-signature .stt is blocked") { var d2 = doc; try d2.setSlot(64, wrongTS) }
    checkThrows("below-minimum resolution (8 slots) rejected") {
        try Groove(timeSignature: TimeSignature(4,4), subdivision: 8, unit: .bf,
                   timing: [Double](repeating: 0, count: 8)).validate()
    }
    checkThrows("velocity > 127 rejected") {
        var v = [Double](repeating: 100, count: n); v[0] = 200
        try Groove(timeSignature: TimeSignature(4,4), subdivision: n, unit: .bf,
                   timing: [Double](repeating: 0, count: n), velocity: v).validate()
    }
} catch { check(false, "document setup threw \(error)") }

// ---- velocity extraction from audio ---------------------------------------
print("\nVelocity extraction (audio):")
do {
    let n = 16
    var rng = SplitMix64(seed: 7)
    let lead = 0.05
    let total = Int((lead + slotS * Double(n) + 0.1) * Double(sr)) + sr / 2
    var y = [Float](repeating: 0, count: total)
    let burst = Int(Double(sr) * 0.018)
    let amps: [Float] = (0..<n).map { $0 == 8 ? 0.9 : 0.3 }   // slot 8 loudest
    for i in 0..<n {
        let s = Int((lead + Double(i) * slotS) * Double(sr))
        for k in 0..<burst where s + k < total {
            let env = pow(1 - Float(k) / Float(burst), 2)
            y[s + k] += rng.nextGaussian() * env * amps[i]
        }
    }
    let gx = Onset.extractGroove(y, sampleRate: sr, bpm: 120,
                                 timeSignature: TimeSignature(4,4), subdivision: n, unit: .bf)
    check(gx.velocity?.count == n, "extracted groove has a velocity lane")
    if let v = gx.velocity {
        check(v.allSatisfy { $0 >= 0 && $0 <= 127 }, "extracted velocities within 0...127")
        let argmax = v.indices.max(by: { v[$0] < v[$1] })!
        check(argmax == 8, "loudest hit (slot 8) gets the highest velocity (got slot \(argmax))")
    }
}

// ---- MIDI import ----------------------------------------------------------
print("\nMIDI import:")
do {
    let (notes, midiBpm) = try MIDIImport.parse(makeSMF())
    check(notes.count == 2, "parsed 2 note-ons (got \(notes.count))")
    check(abs(midiBpm - 120) < 1e-6, "parsed tempo = 120 BPM")
    check(notes.first?.velocity == 100 && notes.last?.velocity == 80, "note velocities 100 & 80")
    check(abs((notes.last?.timeSeconds ?? 0) - 0.25) < 1e-6, "2nd note at t = 0.25 s")
    let gm = try MIDIImport.extractGroove(from: makeSMF(), timeSignature: TimeSignature(4,4),
                                          subdivision: 16, unit: .bf)
    check(gm.velocity?[0] == 100 && gm.velocity?[2] == 80, "MIDI → per-slot velocity (slots 0 & 2)")
    check(gm.timing.allSatisfy { abs($0) < 1e-6 }, "MIDI notes land on-grid (timing ≈ 0)")
} catch { check(false, "MIDI import threw \(error)") }

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
