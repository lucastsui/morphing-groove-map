// Tests the full-song analyzer on a synthetic "song": broadband kicks on every
// beat + swung off-beat hats + a sustained sine (a vocal/harmony stand-in that
// HPSS should suppress). Verifies tempo is recovered and swing is detected.
import Foundation
import XCTest
@testable import MGMKit

private func synthSong(offbeat: Double, bpm: Double = 120, seconds: Double = 8,
                       sr: Int = 44100) -> [Float] {
    var rng = SplitMix64(seed: 5)
    let n = Int(seconds * Double(sr))
    var y = [Float](repeating: 0, count: n)
    // Sustained harmonic distractor (220 Hz) — HPSS should mostly remove it.
    for i in 0..<n { y[i] += 0.15 * Float(sin(2 * Double.pi * 220 * Double(i) / Double(sr))) }

    func burst(_ t: Double, _ dur: Double, _ amp: Float) {
        let s = Int(t * Double(sr)), len = Int(dur * Double(sr))
        for k in 0..<len where s + k < n {
            let env = Float(pow(1 - Double(k) / Double(len), 2))
            y[s + k] += rng.nextGaussian() * env * amp
        }
    }
    let beat = 60.0 / bpm
    var b = 0.0
    while b < seconds {
        burst(b, 0.03, 0.9)                                   // kick on the beat
        let off = b + offbeat * beat
        if off < seconds { burst(off, 0.02, 0.5) }            // off-beat hat
        b += beat
    }
    let peak = y.map { abs($0) }.max() ?? 1
    if peak > 0 { for i in 0..<n { y[i] /= peak } }
    return y
}

final class SongAnalyzerTests: XCTestCase {
    func testRecoversTempoAndSwing() {
        let r = SongAnalyzer.analyzeSong(synthSong(offbeat: 0.63), sampleRate: 44100)
        XCTAssertEqual(r.groove.timing.count, 16)
        XCTAssertNotNil(r.groove.velocity)
        XCTAssertTrue(r.groove.velocity!.allSatisfy { $0 >= 0 && $0 <= 127 })
        XCTAssertGreaterThan(r.report.beatsDetected, 0)
        XCTAssertGreaterThan(r.report.tempoBPM, 50)
        XCTAssertLessThan(r.report.tempoBPM, 250)
        XCTAssertGreaterThan(r.report.swingRatio, 0.55,
                             "swing not detected (ratio \(r.report.swingRatio))")
    }

    func testStraightIsNotSwung() {
        let r = SongAnalyzer.analyzeSong(synthSong(offbeat: 0.5), sampleRate: 44100)
        XCTAssertLessThan(r.report.swingRatio, 0.6)   // straight ≈ 0.5
    }

    func testPercussiveOnsetsFound() {
        // HPSS onset detection should find roughly beat-rate transients.
        let times = SongAnalyzer.percussiveOnsetTimes(synthSong(offbeat: 0.63), sampleRate: 44100)
        XCTAssertGreaterThan(times.count, 5)
    }
}
