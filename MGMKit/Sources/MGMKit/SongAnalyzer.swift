// Full-song swing analysis (on-device, best-effort — no source separation /
// Demucs needed). Pipeline:
//
//   1. STFT magnitude (vDSP).
//   2. Median-filter HPSS (Fitzgerald 2010): emphasise the PERCUSSIVE layer so
//      drum transients dominate vocals / sustained harmony.
//   3. Tempo + beat-PHASE tracking via autocorrelation of the percussive onset
//      envelope (no "downbeat at t=0" assumption).
//   4. Fold detected onsets onto ONE representative bar, measuring each slot's
//      offset in tempo-independent beat fractions using the LOCAL beat duration
//      (so tempo drift is absorbed), plus a per-slot velocity.
//
// Honesty: this is solid on drum-forward material and rough on dense / ballad
// mixes (no stem separation). `SongReport.confidence` flags shaky results.
import Accelerate
import Foundation

public struct SongReport: Sendable {
    public let tempoBPM: Double
    public let swingRatio: Double      // 0.5 = straight, ~0.667 = triplet swing
    public let confidence: Double      // 0...1 (rough beat-tracking confidence)
    public let beatsDetected: Int
    public let onsetsUsed: Int

    public init(tempoBPM: Double, swingRatio: Double, confidence: Double,
                beatsDetected: Int, onsetsUsed: Int) {
        self.tempoBPM = tempoBPM
        self.swingRatio = swingRatio
        self.confidence = confidence
        self.beatsDetected = beatsDetected
        self.onsetsUsed = onsetsUsed
    }
}

public enum SongAnalyzer {

    // MARK: STFT magnitude

    static func magnitudeSpectrogram(_ y: [Float], sampleRate: Int,
                                     fftSize: Int = 1024, hop: Int = 512)
        -> (mag: [[Float]], times: [Double], half: Int) {
        let half = fftSize / 2
        guard y.count >= fftSize else { return ([], [], half) }
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], [], half) }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: fftSize)
        var mags: [[Float]] = []
        var times: [Double] = []

        var start = 0
        while start + fftSize <= y.count {
            vDSP_vmul(Array(y[start..<start + fftSize]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
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
            mags.append(mag)
            times.append(Double(start + fftSize / 2) / Double(sampleRate))
            start += hop
        }
        return (mags, times, half)
    }

    // MARK: HPSS -> percussive onset envelope

    /// Percussive onset-strength envelope via median-filter HPSS, with frame times.
    static func percussiveOnsetEnvelope(_ y: [Float], sampleRate: Int)
        -> (env: [Float], times: [Double]) {
        let (mag, times, half) = magnitudeSpectrogram(y, sampleRate: sampleRate)
        let frames = mag.count
        guard frames > 2 else { return ([], times) }

        let tHalf = 7, fHalf = 7            // ~15-wide median windows
        var prev = [Float](repeating: 0, count: half)
        var env = [Float](repeating: 0, count: frames)
        var tw = [Float](); tw.reserveCapacity(2 * tHalf + 1)
        var fw = [Float](); fw.reserveCapacity(2 * fHalf + 1)

        for f in 0..<frames {
            var cur = [Float](repeating: 0, count: half)
            let t0 = max(0, f - tHalf), t1 = min(frames - 1, f + tHalf)
            for b in 0..<half {
                // Harmonic estimate: median across time at this bin.
                tw.removeAll(keepingCapacity: true)
                var ti = t0; while ti <= t1 { tw.append(mag[ti][b]); ti += 1 }
                let h = median(&tw)
                // Percussive estimate: median across frequency at this frame.
                let b0 = max(0, b - fHalf), b1 = min(half - 1, b + fHalf)
                fw.removeAll(keepingCapacity: true)
                var bi = b0; while bi <= b1 { fw.append(mag[f][bi]); bi += 1 }
                let p = median(&fw)
                let mask = (p * p) / (p * p + h * h + 1e-9)
                cur[b] = mask * mag[f][b]
            }
            // Spectral flux of the percussive layer.
            if f > 0 {
                var flux: Float = 0
                for b in 0..<half { let d = cur[b] - prev[b]; if d > 0 { flux += d } }
                env[f] = flux
            }
            prev = cur
        }
        return (env, times)
    }

    /// Percussive onset TIMES (peak-pick the percussive envelope, refine to the
    /// nearby waveform energy peak so offsets stay sample-accurate).
    public static func percussiveOnsetTimes(_ y: [Float], sampleRate: Int) -> [Double] {
        let (env, times) = percussiveOnsetEnvelope(y, sampleRate: sampleRate)
        guard !env.isEmpty else { return [] }
        let peaks = Onset.peakPick(env)
        let win = Int(Double(sampleRate) * 0.004)
        var out: [Double] = []
        for p in peaks where p < times.count {
            let c = Int(times[p] * Double(sampleRate))
            let a = max(0, c - win), b = min(y.count, c + win)
            guard a < b else { continue }
            var mi = a; var mv: Float = -1; var i = a
            while i < b { let v = abs(y[i]); if v > mv { mv = v; mi = i }; i += 1 }
            out.append(Double(mi) / Double(sampleRate))
        }
        return out
    }

    // MARK: tempo + beat phase

    static func trackBeats(env: [Float], times: [Double]) -> (bpm: Double, beats: [Double], confidence: Double) {
        let n = env.count
        guard n > 8, times.count == n, times[1] > times[0] else { return (120, [], 0) }
        let dt = times[1] - times[0]
        let mean = env.reduce(0, +) / Float(n)
        let e = env.map { max(0, $0 - mean) }

        let minLag = max(1, Int((60.0 / 200.0) / dt))   // up to 200 BPM
        let maxLag = min(n - 1, Int((60.0 / 60.0) / dt)) // down to 60 BPM
        guard maxLag > minLag else { return (120, [], 0) }

        var bestLag = minLag; var bestCorr: Float = -1
        for lag in minLag...maxLag {
            var c: Float = 0; var i = 0
            while i + lag < n { c += e[i] * e[i + lag]; i += 1 }
            if c > bestCorr { bestCorr = c; bestLag = lag }
        }
        let bpm = 60.0 / (Double(bestLag) * dt)

        var bestPhase = 0; var bestSum: Float = -1
        for off in 0..<bestLag {
            var s: Float = 0; var k = off
            while k < n { s += e[k]; k += bestLag }
            if s > bestSum { bestSum = s; bestPhase = off }
        }
        var beats: [Double] = []; var k = bestPhase
        while k < n { beats.append(times[k]); k += bestLag }

        // Rough confidence: how concentrated energy is on the beat grid vs uniform.
        let total = e.reduce(0, +)
        let expected = total * Float(beats.count) / Float(n)
        let conf = expected > 0 ? min(1.0, Double(bestSum / expected) / 2.0) : 0
        return (bpm, beats, max(0, min(1, conf)))
    }

    // MARK: full analysis -> one representative bar

    public static func analyzeSong(_ y: [Float], sampleRate sr: Int,
                                   timeSignature ts: TimeSignature = TimeSignature(4, 4),
                                   subdivision: Int = 16,
                                   sectionSeconds: Double = 20) -> (groove: Groove, report: SongReport) {
        // Analyse a representative centred section (bounds compute, steadier tempo).
        var seg = y
        let totalSec = Double(y.count) / Double(sr)
        if totalSec > sectionSeconds {
            let a = Int(((totalSec - sectionSeconds) / 2) * Double(sr))
            seg = Array(y[a..<min(y.count, a + Int(sectionSeconds * Double(sr)))])
        }

        let (env, times) = percussiveOnsetEnvelope(seg, sampleRate: sr)
        let (bpm, beats, conf) = trackBeats(env: env, times: times)
        let onsets = percussiveOnsetTimes(seg, sampleRate: sr)

        let nSlots = slotCount(ts, subdivision: subdivision)
        let slotsPerBeat = max(1, subdivision / ts.denominator)
        var sumOff = [Double](repeating: 0, count: nSlots)
        var sumVel = [Double](repeating: 0, count: nSlots)
        var count = [Int](repeating: 0, count: nSlots)
        var ratios: [Double] = []

        if beats.count >= 2 {
            for t in onsets where t >= beats.first! && t <= beats.last! {
                var k = 0
                while k + 1 < beats.count && beats[k + 1] <= t { k += 1 }
                guard k + 1 < beats.count else { continue }
                let dur = beats[k + 1] - beats[k]
                guard dur > 0 else { continue }
                let pos = (t - beats[k]) / dur                       // 0..<1 within the beat
                let sub = Int((pos * Double(slotsPerBeat)).rounded()) % slotsPerBeat
                let ideal = Double(sub) / Double(slotsPerBeat)
                let slot = (k % ts.numerator) * slotsPerBeat + sub
                guard slot < nSlots else { continue }
                sumOff[slot] += (pos - ideal) * Double(bfPerBeat)    // offset in beat fractions
                count[slot] += 1
                // velocity from local peak amplitude
                let c = Int(t * Double(sr)), w = Int(Double(sr) * 0.02)
                let lo = max(0, c), hi = min(seg.count, c + w)
                var pk: Float = 0; var i = lo
                while i < hi { let v = abs(seg[i]); if v > pk { pk = v }; i += 1 }
                sumVel[slot] += Double(pk)
                if pos > 0.4 && pos < 0.8 { ratios.append(pos) }     // candidate swung off-beat
            }
        }

        var timing = [Double](repeating: 0, count: nSlots)
        var velRaw = [Double](repeating: 0, count: nSlots)
        for s in 0..<nSlots where count[s] > 0 {
            timing[s] = sumOff[s] / Double(count[s])
            velRaw[s] = sumVel[s] / Double(count[s])
        }
        let maxV = velRaw.max() ?? 0
        let velocity = velRaw.map { maxV > 0 ? ($0 / maxV * 127).rounded() : 0 }

        let groove = Groove(timeSignature: ts, subdivision: subdivision, unit: .bf,
                            timing: timing, velocity: velocity)
        let report = SongReport(tempoBPM: bpm,
                                swingRatio: ratios.isEmpty ? 0.5 : median(ratios),
                                confidence: conf,
                                beatsDetected: beats.count,
                                onsetsUsed: count.reduce(0, +))
        return (groove, report)
    }

    // MARK: helpers

    @inline(__always)
    static func median(_ a: inout [Float]) -> Float {
        guard !a.isEmpty else { return 0 }
        a.sort(); let n = a.count
        return n & 1 == 1 ? a[n / 2] : 0.5 * (a[n / 2 - 1] + a[n / 2])
    }

    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); let n = s.count
        return n & 1 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }
}
