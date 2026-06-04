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

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
