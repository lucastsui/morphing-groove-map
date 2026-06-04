// Audio render -- Swift port of mgm/render.py. Operates on in-memory Float
// buffers (the AVFoundation file <-> buffer glue lives in the app layer), so it
// stays pure and unit-testable.
//
// Detect onsets in the target, slice into one chunk per hit, shift each chunk
// by its slot's groove offset, and overlap-add with short fades to hide seams.
import Foundation

public enum Render {

    private static func offsetToSamples(_ value: Double, groove: Groove, sr: Int,
                                        bpm: Double?) -> Double {
        switch groove.unit {
        case .ms: return msToSamples(value, sampleRate: sr)
        case .bf:
            // bf is tempo-independent; realise it with the render tempo.
            return bfToSamples(value, bpm: bpm ?? 0, sampleRate: sr)
        case .samples:
            if let stored = groove.sampleRate, stored != sr {
                return value * Double(sr) / Double(stored)
            }
            return value
        }
    }

    private static func applyFades(_ chunk: inout [Float], xfade: Int) {
        let n = chunk.count
        let f = min(xfade, n / 2)
        guard f > 0 else { return }
        for i in 0..<f {
            let g = Float(i) / Float(f)
            chunk[i] *= g
            chunk[n - 1 - i] *= g
        }
    }

    /// Apply `groove` to `target` (mono Float at `sampleRate`). Onsets are
    /// detected from the audio. Returns the new mono buffer.
    public static func grooved(target y: [Float], sampleRate sr: Int,
                               groove: Groove, xfade: Int = 64,
                               tempoBpm: Double? = nil) -> [Float] {
        guard !y.isEmpty, !groove.timing.isEmpty else { return y }
        precondition(groove.unit != .bf || tempoBpm != nil,
                     "tempoBpm is required to render a beat-fraction (bf) groove")

        // 1. detect onsets (sample indices), always including the start
        var onsets = Onset.accurateOnsetTimes(y, sampleRate: sr).map { Int($0 * Double(sr)) }
        if onsets.first != 0 { onsets.insert(0, at: 0) }
        onsets.append(y.count)  // sentinel end boundary

        let offsets = groove.timing
        let nOff = offsets.count

        let maxShift = Int(offsets.map { abs(offsetToSamples($0, groove: groove, sr: sr, bpm: tempoBpm)) }.max() ?? 0)
        var out = [Float](repeating: 0, count: y.count + maxShift + xfade + 1)

        for i in 0..<(onsets.count - 1) {
            let start = onsets[i], end = onsets[i + 1]
            guard start < end else { continue }
            var chunk = Array(y[start..<end])
            applyFades(&chunk, xfade: xfade)
            let shift = Int(offsetToSamples(offsets[i % nOff], groove: groove, sr: sr, bpm: tempoBpm).rounded())
            let dst = max(0, start + shift)
            for k in 0..<chunk.count where dst + k < out.count {
                out[dst + k] += chunk[k]
            }
        }

        // guard against overlap-induced clipping
        let peak = out.map { abs($0) }.max() ?? 0
        if peak > 1 { for i in 0..<out.count { out[i] /= peak } }
        return out
    }
}
