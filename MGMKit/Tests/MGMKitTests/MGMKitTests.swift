import Foundation
import XCTest
@testable import MGMKit

final class MorphTests: XCTestCase {
    func g(_ timing: [Double]) -> Groove {
        Groove(timeSignature: TimeSignature(4, 4), subdivision: 8, unit: .ms, timing: timing)
    }

    func testUnitsSpecExample() {
        XCTAssertEqual(msToSamples(30, sampleRate: 48000), 1440, accuracy: 1e-6)
        XCTAssertEqual(rescaleSamples(1440, from: 48000, to: 96000), 2880, accuracy: 1e-6)
    }

    func testGrid() {
        XCTAssertEqual(slotCount(TimeSignature(4, 4), subdivision: 8), 8)
        XCTAssertEqual(slotCount(TimeSignature(4, 4), subdivision: 16), 16)
        XCTAssertEqual(slotCount(TimeSignature(3, 4), subdivision: 8), 6)
    }

    func testMorphMidpoint() {
        // dial 63 of [0,0,..] -> [0,30,..] gives [0, 30*63/127, ..]
        let map = GrooveMap([0: g([0,0,0,0,0,0,0,0]), 127: g([0,30,0,30,0,30,0,30])])
        let out = map.resolve(63)
        XCTAssertEqual(out.timing[0], 0, accuracy: 1e-9)
        XCTAssertEqual(out.timing[1], 30 * 63 / 127, accuracy: 1e-6)
        XCTAssertEqual(out.timing[1], 14.88, accuracy: 0.05)
    }

    func testMultiAnchorBracket() {
        let map = GrooveMap([0: g([0,0,0,0,0,0,0,0]),
                             47: g(Array(repeating: 10, count: 8)),
                             127: g(Array(repeating: 100, count: 8))])
        XCTAssertEqual(map.resolve(23.5).timing[0], 5, accuracy: 1e-6)
        let expected = 10.0 + (100.0 - 10.0) * (87.0 - 47.0) / (127.0 - 47.0)
        XCTAssertEqual(map.resolve(87).timing[0], expected, accuracy: 1e-6)
    }

    func testEndpointsReturnAnchor() {
        let swung = g([0,40,0,40,0,40,0,40])
        let map = GrooveMap([0: g(Array(repeating: 0, count: 8)), 127: swung])
        XCTAssertEqual(map.resolve(127).timing, swung.timing)
    }
}

/// The important one: prove the vDSP onset port recovers a KNOWN swing from
/// synthesized audio, mirroring the Python ground-truth harness (< 2 ms MAE).
final class OnsetAccuracyTests: XCTestCase {
    let sr = 48000
    let bpm = 120.0
    let N = 16
    var slotS: Double { (60.0 / bpm) / 4.0 }
    let leadS = 0.25

    /// Render a noise burst on every 16th, each nudged by its known offset (ms).
    func synth(_ offsetsMs: [Double], seed: UInt64 = 0) -> [Float] {
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
                             timeSignature: TimeSignature(4, 4), subdivision: N, unit: .ms)
    }

    func mae(_ got: [Double], _ truth: [Double]) -> Double {
        zip(got, truth).map { abs($0 - $1) }.reduce(0, +) / Double(truth.count)
    }

    func testRecoversKnownSwing() {
        let cases: [String: [Double]] = [
            "straight": Array(repeating: 0, count: N),
            "swing":   (0..<N).map { $0 % 2 == 1 ? 22 : 0 },
            "large":   (0..<N).map { $0 % 2 == 1 ? 40 : 0 },
        ]
        for (name, truth) in cases {
            let got = extract(synth(truth))
            let e = mae(got, truth)
            XCTAssertLessThan(e, 2.0, "\(name): MAE \(e) ms exceeds 2 ms")
        }
    }
}

/// Beat-fraction (bf) tests -- the spec's tempo-independent unit. Mirrors the
/// Python tests/test_bf.py: the UC-6 example and the triplet-exactness property.
final class BeatFractionTests: XCTestCase {
    func testBFPerBeatIs2pow16Times3() {
        XCTAssertEqual(bfPerBeat, 65536 * 3)
        XCTAssertEqual(bfPerBeat, 196608)
        XCTAssertEqual(bfPerBeat % 3, 0)
    }

    func testUC6SpecExample() {
        // 3072 bf @ 60 BPM = 1/64 beat = 15.625 ms.
        XCTAssertEqual(bfToMs(3072, bpm: 60), 15.625, accuracy: 1e-9)
        XCTAssertEqual(bfToNoteValue(3072), "1/64 beat")
    }

    func testTempoIndependence() {
        let quarter = Double(bfPerBeat / 4)
        XCTAssertEqual(bfToNoteValue(quarter), "1/4 beat")
        XCTAssertEqual(bfToMs(quarter, bpm: 60), 250.0, accuracy: 1e-9)
        XCTAssertEqual(bfToMs(quarter, bpm: 120), 125.0, accuracy: 1e-9)
    }

    func testTripletLandsOnExactInteger() {
        // One eighth-note triplet = 1/3 beat -> exact integer, no rounding.
        XCTAssertEqual(Double(bfPerBeat) / 3, 65536, accuracy: 1e-9)
        XCTAssertEqual(bfToNoteValue(65536), "1/3 beat (triplet)")
    }

    func testMsRoundTrip() {
        for bpm in [60.0, 120.0, 137.2] {
            XCTAssertEqual(msToBF(bfToMs(12345, bpm: bpm), bpm: bpm), 12345, accuracy: 1e-6)
        }
    }

    func testSamplesRoundTrip() {
        for bpm in [90.0, 120.0] {
            let got = samplesToBF(bfToSamples(9999, bpm: bpm, sampleRate: 48000),
                                  bpm: bpm, sampleRate: 48000)
            XCTAssertEqual(got, 9999, accuracy: 1e-6)
        }
    }

    func testDescribeBF() {
        let d = describeBF(3072, bpm: 60, sampleRate: 48000)
        XCTAssertEqual(d.noteValue, "1/64 beat")
        XCTAssertEqual(d.ms, 15.625, accuracy: 1e-9)
        XCTAssertEqual(d.samples ?? -1, 750, accuracy: 1e-9)
        XCTAssertEqual(d.beats, 0.015625, accuracy: 1e-12)
    }

    func testNoteValueSignAndZero() {
        XCTAssertEqual(bfToNoteValue(0), "0 (on grid)")
        XCTAssertEqual(bfToNoteValue(-3072), "-1/64 beat")
    }

    func testBFGrooveMorphsLikeAnyUnit() {
        // The morph is unit-agnostic, so bf grooves interpolate with no change.
        let straight = Groove(timeSignature: TimeSignature(4, 4), subdivision: 12,
                              unit: .bf, timing: [Double](repeating: 0, count: 12))
        let swung = Groove(timeSignature: TimeSignature(4, 4), subdivision: 12, unit: .bf,
                           timing: (0..<12).map { $0 % 2 == 1 ? Double(bfPerBeat / 12) : 0 })
        let map = GrooveMap([0: straight, 127: swung])
        XCTAssertEqual(map.resolve(127).timing, swung.timing)
        XCTAssertEqual(map.resolve(0).timing, straight.timing)
        XCTAssertEqual(map.resolve(127).unit, .bf)
    }
}

/// Triplet-grid tests -- swing is representable exactly only on a triplet grid.
final class TripletGridTests: XCTestCase {
    func testTripletSubdivisions() {
        let ts = TimeSignature(4, 4)
        XCTAssertEqual(slicesPerBeat(ts, subdivision: 12), 3)
        XCTAssertEqual(slotCount(ts, subdivision: 12), 12)
        XCTAssertEqual(slotCount(ts, subdivision: 24), 24)
        XCTAssertEqual(slotCount(ts, subdivision: 96), 96)
    }

    func testTripletDetection() {
        XCTAssertTrue(isTripletSubdivision(12))
        XCTAssertTrue(isTripletSubdivision(24))
        XCTAssertTrue(isTripletSubdivision(96))
        XCTAssertFalse(isTripletSubdivision(8))
        XCTAssertFalse(isTripletSubdivision(16))
        XCTAssertFalse(isTripletSubdivision(64))
    }

    func testSwingExactOnTripletGridButOffsetOnStraight() {
        // On an eighth-triplet grid the swung note sits ON a slot -> zero offset.
        let triplet = Groove(timeSignature: TimeSignature(4, 4), subdivision: 12,
                             unit: .bf, timing: [Double](repeating: 0, count: 12))
        XCTAssertTrue(triplet.timing.allSatisfy { $0 == 0 })
        // On a straight eighth grid the same feel must be a +1/6-beat offset.
        let swingOffset = Double(bfPerBeat / 6)
        let straight = Groove(timeSignature: TimeSignature(4, 4), subdivision: 8, unit: .bf,
                              timing: (0..<8).map { $0 % 2 == 1 ? swingOffset : 0 })
        XCTAssertEqual(straight.timing[1], swingOffset)
    }
}

/// Deterministic RNG so tests are reproducible without Foundation's random.
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
        // Box-Muller
        let u1 = max(nextUniform(), 1e-7), u2 = nextUniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// Minimal format-0 SMF for the MIDI-import tests: 480 tpq, 120 BPM,
/// two note-ons (C vel100 @0s, C vel80 @0.25s).
private func makeSMF() -> Data {
    var t: [UInt8] = []
    t += [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]
    t += [0x00, 0x90, 0x3C, 0x64]
    t += [0x81, 0x70, 0x90, 0x3C, 0x50]
    t += [0x00, 0xFF, 0x2F, 0x00]
    let len = t.count
    var d: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
    d += [0x4D, 0x54, 0x72, 0x6B,
          UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
    d += t
    return Data(d)
}

/// .stt / .mgm file formats + spec enforcement.
final class FileFormatTests: XCTestCase {
    private func swung(_ n: Int = 16) -> Groove {
        Groove(timeSignature: TimeSignature(4, 4), subdivision: n, unit: .bf,
               timing: (0..<n).map { $0 % 2 == 1 ? Double(bfPerBeat / 12) : 0 },
               velocity: (0..<n).map { _ in 100.0 })
    }

    func testSTTRoundTrip() throws {
        let g = swung()
        let back = try MGMIO.decodeSTT(MGMIO.encodeSTT(g))
        XCTAssertEqual(back.timing, g.timing)
        XCTAssertEqual(back.velocity, g.velocity)
        XCTAssertEqual(back.unit, .bf)
    }

    func testMGMRoundTripAndEmptyDefaults() throws {
        var doc = try MGMDocument(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf)
        try doc.setSlot(127, swung())
        XCTAssertTrue(doc.resolve(0).timing.allSatisfy { $0 == 0 })  // empty slot 0 -> no swing
        XCTAssertEqual(doc.resolve(127).timing, swung().timing)
        let back = try MGMIO.decodeMGM(MGMIO.encodeMGM(doc))
        XCTAssertEqual(back.populatedPositions, [127])
        XCTAssertEqual(back.resolve(127).timing, swung().timing)
    }

    func testCompatibilityBlocked() throws {
        var doc = try MGMDocument(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf)
        let n = slotCount(TimeSignature(3, 4), subdivision: 16)
        let wrong = Groove(timeSignature: TimeSignature(3, 4), subdivision: 16, unit: .bf,
                           timing: [Double](repeating: 0, count: n))
        XCTAssertThrowsError(try doc.setSlot(64, wrong))
    }

    func testMinResolutionEnforced() {
        let g = Groove(timeSignature: TimeSignature(4, 4), subdivision: 8, unit: .bf,
                       timing: [Double](repeating: 0, count: 8))
        XCTAssertThrowsError(try g.validate())
    }

    func testVelocityRangeEnforced() {
        var v = [Double](repeating: 100, count: 16); v[0] = 200
        let g = Groove(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf,
                       timing: [Double](repeating: 0, count: 16), velocity: v)
        XCTAssertThrowsError(try g.validate())
    }
}

/// Extraction of timing + velocity from MIDI and audio.
final class ExtractionTests: XCTestCase {
    func testMIDIImport() throws {
        let (notes, bpm) = try MIDIImport.parse(makeSMF())
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(bpm, 120, accuracy: 1e-6)
        XCTAssertEqual(notes.first?.velocity, 100)
        XCTAssertEqual(notes.last?.velocity, 80)
        let g = try MIDIImport.extractGroove(from: makeSMF(), timeSignature: TimeSignature(4, 4),
                                             subdivision: 16, unit: .bf)
        XCTAssertEqual(g.velocity?[0], 100)
        XCTAssertEqual(g.velocity?[2], 80)
        XCTAssertTrue(g.timing.allSatisfy { abs($0) < 1e-6 })
    }

    func testAudioVelocityExtraction() {
        let sr = 48000, n = 16
        let slotS = (60.0 / 120.0) / 4.0
        var rng = SplitMix64(seed: 7)
        let lead = 0.05
        let total = Int((lead + slotS * Double(n) + 0.1) * Double(sr)) + sr / 2
        var y = [Float](repeating: 0, count: total)
        let burst = Int(Double(sr) * 0.018)
        let amps: [Float] = (0..<n).map { $0 == 8 ? 0.9 : 0.3 }
        for i in 0..<n {
            let s = Int((lead + Double(i) * slotS) * Double(sr))
            for k in 0..<burst where s + k < total {
                let env = pow(1 - Float(k) / Float(burst), 2)
                y[s + k] += rng.nextGaussian() * env * amps[i]
            }
        }
        let g = Onset.extractGroove(y, sampleRate: sr, bpm: 120,
                                    timeSignature: TimeSignature(4, 4), subdivision: n, unit: .bf)
        XCTAssertEqual(g.velocity?.count, n)
        let v = g.velocity!
        XCTAssertTrue(v.allSatisfy { $0 >= 0 && $0 <= 127 })
        XCTAssertEqual(v.indices.max(by: { v[$0] < v[$1] }), 8)
    }
}
