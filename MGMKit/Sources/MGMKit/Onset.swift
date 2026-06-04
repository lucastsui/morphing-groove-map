// Accelerate (vDSP) onset detection -- the Swift port of mgm/extract.py's
// accurate_onset_times + onsets_to_offsets.
//
// Pipeline (mirrors the Python version that scored ~0.5 ms MAE on synthetic
// ground truth):
//   1. Spectral flux on a FINE hop (sub-frame time resolution).
//   2. Peak-pick the flux envelope (no backtracking -> no early bias).
//   3. Refine each onset to the nearby waveform energy peak (+/- 4 ms).
// Then fold onsets onto one bar and AVERAGE per slot (outliers > half a slot
// are rejected, never clamped) to recover the true per-slot microtiming.
import Accelerate
import Foundation

public enum Onset {

    // MARK: Spectral flux onset strength

    /// Compute a spectral-flux onset-strength envelope and its frame times (s).
    static func onsetStrength(_ y: [Float], sampleRate: Int,
                              fftSize: Int = 1024, hop: Int = 128) -> (env: [Float], times: [Double]) {
        guard y.count >= fftSize else { return ([], []) }
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetup(setup) }

        // Hann window applied to each frame.
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let half = fftSize / 2
        var prevMag = [Float](repeating: 0, count: half)
        var env: [Float] = []
        var times: [Double] = []

        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: fftSize)

        var frameStart = 0
        while frameStart + fftSize <= y.count {
            // window the frame
            vDSP_vmul(Array(y[frameStart..<frameStart + fftSize]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            // real FFT via split-complex packing
            var mag = [Float](repeating: 0, count: half)
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(half))
                }
            }

            // spectral flux = sum of positive magnitude increases vs previous frame
            var flux: Float = 0
            for k in 0..<half {
                let d = mag[k] - prevMag[k]
                if d > 0 { flux += d }
            }
            env.append(flux)
            times.append(Double(frameStart + fftSize / 2) / Double(sampleRate))
            prevMag = mag
            frameStart += hop
        }
        return (env, times)
    }

    // MARK: Peak picking

    /// Pick peaks in an envelope: local maxima above a moving average + delta,
    /// with a minimum spacing of `wait` frames.
    static func peakPick(_ env: [Float], preMax: Int = 3, postMax: Int = 3,
                         preAvg: Int = 3, postAvg: Int = 5, delta: Float = 0.0, wait: Int = 5) -> [Int] {
        guard !env.isEmpty else { return [] }
        // Normalize so `delta` is scale-independent.
        let maxV = env.max() ?? 1
        let norm = maxV > 0 ? env.map { $0 / maxV } : env
        let d: Float = delta > 0 ? delta : 0.12

        var peaks: [Int] = []
        var lastPeak = -1 - wait
        let n = norm.count
        for i in 0..<n {
            let lo = max(0, i - preMax), hi = min(n - 1, i + postMax)
            var isMax = true
            for j in lo...hi where norm[j] > norm[i] { isMax = false; break }
            if !isMax { continue }
            let aLo = max(0, i - preAvg), aHi = min(n - 1, i + postAvg)
            var sum: Float = 0
            for j in aLo...aHi { sum += norm[j] }
            let avg = sum / Float(aHi - aLo + 1)
            if norm[i] >= avg + d && i - lastPeak > wait {
                peaks.append(i)
                lastPeak = i
            }
        }
        return peaks
    }

    // MARK: Accurate onset times

    /// Two-stage accurate onset localization. Returns onset times in seconds.
    public static func accurateOnsetTimes(_ y: [Float], sampleRate: Int) -> [Double] {
        let (env, times) = onsetStrength(y, sampleRate: sampleRate)
        let peaks = peakPick(env)
        let win = Int(Double(sampleRate) * 0.004)  // +/- 4 ms refinement
        var refined: [Double] = []
        for p in peaks {
            guard p < times.count else { continue }
            let c = Int(times[p] * Double(sampleRate))
            let a = max(0, c - win)
            let b = min(y.count, c + win)
            guard a < b else { continue }
            var maxIdx = a
            var maxVal: Float = -1
            for i in a..<b {
                let v = abs(y[i])
                if v > maxVal { maxVal = v; maxIdx = i }
            }
            refined.append(Double(maxIdx) / Double(sampleRate))
        }
        return refined
    }

    // MARK: Fold onsets -> per-slot offsets

    /// Average detected onsets onto one bar's slots. Rejects (does not clamp)
    /// hits more than half a slot away. Returns offsets in `unit`.
    public static func offsets(fromOnsetTimes onsetTimes: [Double], bpm: Double,
                               timeSignature ts: TimeSignature, subdivision: Int,
                               unit: Unit = .ms, sampleRate: Int? = nil) -> [Double] {
        let nSlots = slotCount(ts, subdivision: subdivision)
        let spb = Double(subdivision / ts.denominator)
        let secPerSlot = (60.0 / bpm) / spb
        let measure = secPerSlot * Double(nSlots)
        let halfSlot = secPerSlot * 0.5

        var sums = [Double](repeating: 0, count: nSlots)
        var counts = [Int](repeating: 0, count: nSlots)
        for t in onsetTimes {
            let tb = t.truncatingRemainder(dividingBy: measure)
            let slot = Int((tb / secPerSlot).rounded()) % nSlots
            let delta = tb - Double(slot) * secPerSlot
            if abs(delta) <= halfSlot {
                sums[slot] += delta
                counts[slot] += 1
            }
        }
        return (0..<nSlots).map { i in
            let meanS = counts[i] > 0 ? sums[i] / Double(counts[i]) : 0
            switch unit {
            case .samples: return meanS * Double(sampleRate ?? 0)
            case .ms:      return meanS * 1000.0
            case .bf:      return secondsToBF(meanS, bpm: bpm)
            }
        }
    }

    /// Average arbitrary per-onset `values` onto one bar's slots (same slot
    /// assignment + half-slot rejection as `offsets`). Used to fold velocity.
    public static func foldPerSlot(times: [Double], values: [Double], bpm: Double,
                                   timeSignature ts: TimeSignature, subdivision: Int) -> [Double] {
        let nSlots = slotCount(ts, subdivision: subdivision)
        let spb = Double(subdivision / ts.denominator)
        let secPerSlot = (60.0 / bpm) / spb
        let measure = secPerSlot * Double(nSlots)
        let halfSlot = secPerSlot * 0.5
        var sums = [Double](repeating: 0, count: nSlots)
        var counts = [Int](repeating: 0, count: nSlots)
        for (t, v) in zip(times, values) {
            let tb = t.truncatingRemainder(dividingBy: measure)
            let slot = Int((tb / secPerSlot).rounded()) % nSlots
            if abs(tb - Double(slot) * secPerSlot) <= halfSlot {
                sums[slot] += v
                counts[slot] += 1
            }
        }
        return (0..<nSlots).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
    }

    /// Estimate a 0–127 velocity per slot from local peak amplitude at each
    /// onset (loudest hit → 127). Slots with no onset stay at 0.
    public static func velocities(_ y: [Float], sampleRate sr: Int, onsetTimes: [Double],
                                  bpm: Double, timeSignature ts: TimeSignature,
                                  subdivision: Int) -> [Double] {
        let n = slotCount(ts, subdivision: subdivision)
        guard !onsetTimes.isEmpty else { return [Double](repeating: 0, count: n) }
        let win = max(1, Int(Double(sr) * 0.02))  // 20 ms peak window after onset
        var peaks: [Double] = []
        for t in onsetTimes {
            let c = max(0, Int(t * Double(sr)))
            let b = min(y.count, c + win)
            var pk: Float = 0
            if c < b { for k in c..<b { let v = abs(y[k]); if v > pk { pk = v } } }
            peaks.append(Double(pk))
        }
        let maxPk = peaks.max() ?? 0
        let scaled = peaks.map { maxPk > 0 ? ($0 / maxPk) * 127.0 : 0 }
        return foldPerSlot(times: onsetTimes, values: scaled, bpm: bpm,
                           timeSignature: ts, subdivision: subdivision).map { $0.rounded() }
    }

    /// Full extraction from audio: timing + velocity in one `Groove`.
    public static func extractGroove(_ y: [Float], sampleRate sr: Int, bpm: Double,
                                     timeSignature ts: TimeSignature, subdivision: Int,
                                     unit: Unit = .bf) -> Groove {
        let times = accurateOnsetTimes(y, sampleRate: sr)
        let timing = offsets(fromOnsetTimes: times, bpm: bpm, timeSignature: ts,
                             subdivision: subdivision, unit: unit,
                             sampleRate: unit == .samples ? sr : nil)
        let vel = velocities(y, sampleRate: sr, onsetTimes: times, bpm: bpm,
                             timeSignature: ts, subdivision: subdivision)
        return Groove(timeSignature: ts, subdivision: subdivision, unit: unit,
                      sampleRate: unit == .samples ? sr : nil, timing: timing, velocity: vel)
    }
}
