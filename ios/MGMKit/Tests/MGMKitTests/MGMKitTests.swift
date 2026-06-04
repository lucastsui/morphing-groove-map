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
        let expected = 10 + (100 - 10) * (87.0 - 47) / (127 - 47)
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
