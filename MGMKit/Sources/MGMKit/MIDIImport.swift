// Standard MIDI File (SMF) import — parse note onsets + velocities and fold
// them into a `Groove` (timing + velocity). No external dependencies.
//
// Handles format 0 and 1, metrical timing (ticks-per-quarter), running status,
// and Set-Tempo meta events. A single/initial tempo is honoured exactly; a
// mid-file tempo map spread across separate tracks is approximated by the
// latest tempo seen (fine for the typical single-tempo groove file).
import Foundation

public enum MIDIImport {
    public struct Note: Equatable, Sendable {
        public let timeSeconds: Double
        public let velocity: Int   // 0–127, straight from the MIDI event
    }

    /// Parse note-on events (velocity > 0) and the file's tempo (BPM).
    public static func parse(_ data: Data) throws -> (notes: [Note], bpm: Double) {
        let b = [UInt8](data)
        func u16(_ p: Int) -> Int { (Int(b[p]) << 8) | Int(b[p + 1]) }
        func u32(_ p: Int) -> Int {
            (Int(b[p]) << 24) | (Int(b[p + 1]) << 16) | (Int(b[p + 2]) << 8) | Int(b[p + 3])
        }

        guard b.count >= 14, b[0] == 0x4D, b[1] == 0x54, b[2] == 0x68, b[3] == 0x64 else {
            throw MGMError.badMIDI("missing MThd header")
        }
        let headerLen = u32(4)
        let division = u16(12)
        guard division & 0x8000 == 0, division != 0 else {
            throw MGMError.badMIDI("SMPTE timing not supported")
        }
        let ticksPerQuarter = Double(division)

        var tempoUsPerQuarter = 500_000.0  // default = 120 BPM
        var notes: [Note] = []
        var i = 8 + headerLen

        while i + 8 <= b.count {
            guard b[i] == 0x4D, b[i + 1] == 0x54, b[i + 2] == 0x72, b[i + 3] == 0x6B else { break } // MTrk
            let len = u32(i + 4)
            var p = i + 8
            let end = min(p + len, b.count)
            var seconds = 0.0
            var running: UInt8 = 0

            func vlq() -> Int {
                var v = 0
                while p < end {
                    let x = b[p]; p += 1
                    v = (v << 7) | Int(x & 0x7F)
                    if x & 0x80 == 0 { break }
                }
                return v
            }

            while p < end {
                let dt = vlq()
                seconds += Double(dt) * (tempoUsPerQuarter / 1_000_000.0) / ticksPerQuarter
                guard p < end else { break }
                var status = b[p]
                if status & 0x80 != 0 { p += 1; running = status } else { status = running }

                switch status & 0xF0 {
                case 0x90:  // note on
                    guard p + 1 < end else { p = end; break }
                    let vel = b[p + 1]; p += 2
                    if vel > 0 { notes.append(Note(timeSeconds: seconds, velocity: Int(vel))) }
                case 0x80:  // note off
                    p += 2
                case 0xA0, 0xB0, 0xE0:  // two data bytes
                    p += 2
                case 0xC0, 0xD0:  // one data byte
                    p += 1
                default:  // 0xF0: meta / sysex / system
                    if status == 0xFF {
                        guard p < end else { break }
                        let metaType = b[p]; p += 1
                        let mlen = vlq()
                        if metaType == 0x51, mlen == 3, p + 2 < end {
                            tempoUsPerQuarter = Double((Int(b[p]) << 16) | (Int(b[p + 1]) << 8) | Int(b[p + 2]))
                        }
                        p += mlen
                    } else if status == 0xF0 || status == 0xF7 {
                        let slen = vlq(); p += slen
                    } else {
                        p += 1
                    }
                }
            }
            i = end
        }
        return (notes, 60_000_000.0 / tempoUsPerQuarter)
    }

    /// Extract a `Groove` (timing + velocity) from MIDI data, mapping note
    /// onsets to the grid and averaging MIDI velocities per slot.
    public static func extractGroove(from data: Data, timeSignature ts: TimeSignature,
                                     subdivision: Int, unit: Unit = .bf,
                                     bpm overrideBpm: Double? = nil,
                                     sampleRate: Int? = nil) throws -> Groove {
        let (notes, fileBpm) = try parse(data)
        let bpm = overrideBpm ?? fileBpm
        let times = notes.map(\.timeSeconds)
        let timing = Onset.offsets(fromOnsetTimes: times, bpm: bpm, timeSignature: ts,
                                   subdivision: subdivision, unit: unit,
                                   sampleRate: unit == .samples ? sampleRate : nil)
        let velocity = Onset.foldPerSlot(times: times, values: notes.map { Double($0.velocity) },
                                         bpm: bpm, timeSignature: ts, subdivision: subdivision)
        return Groove(timeSignature: ts, subdivision: subdivision, unit: unit,
                      sampleRate: unit == .samples ? sampleRate : nil,
                      timing: timing, velocity: velocity)
    }

    // MARK: Exact single-bar extraction

    /// Exact extraction of ONE bar: place each onset on a fine grid at its true
    /// offset, keep the exact MIDI velocity, with NO cross-bar averaging and NO
    /// off-grid rejection. Works in the musical (beat) domain, so it's tempo-exact
    /// at constant tempo. Lossless for a monophonic onset stream; genuinely
    /// simultaneous hits still collapse to one value per slot (the model's limit).
    public static func extractGrooveExact(from data: Data, timeSignature ts: TimeSignature,
                                          subdivision fixedSub: Int? = nil,
                                          bpm overrideBpm: Double? = nil,
                                          bar: Int? = nil) throws -> Groove {
        let (notes, fileBpm) = try parse(data)
        let bpm = overrideBpm ?? fileBpm
        let beatsPerBar = Double(ts.numerator) * 4.0 / Double(ts.denominator)
        let positions = notes.map { $0.timeSeconds * bpm / 60.0 }          // onset positions, in beats

        func emptyGroove(_ sub: Int) -> Groove {
            let n = slotCount(ts, subdivision: sub)
            return Groove(timeSignature: ts, subdivision: sub, unit: .bf,
                          timing: [Double](repeating: 0, count: n),
                          velocity: [Double](repeating: 0, count: n))
        }
        guard let firstOnset = positions.min() else { return emptyGroove(fixedSub ?? 16) }

        // default to the bar with the most onsets (most representative single bar)
        let chosenBar: Int
        if let bar { chosenBar = bar }
        else {
            var counts: [Int: Int] = [:]
            for p in positions where p >= 0 { counts[Int(p / beatsPerBar), default: 0] += 1 }
            chosenBar = counts.max { $0.value < $1.value }?.key ?? Int(firstOnset / beatsPerBar)
        }
        let barStart = Double(chosenBar) * beatsPerBar
        let inBar: [(pos: Double, vel: Int)] = zip(positions, notes).compactMap { p, n in
            let local = p - barStart
            return (local >= 0 && local < beatsPerBar) ? (local, n.velocity) : nil
        }
        guard !inBar.isEmpty else { return emptyGroove(fixedSub ?? 16) }

        let sub = fixedSub ?? autoSubdivision(forOnsetsInBeats: inBar.map(\.pos),
                                              timeSignature: ts, beatsPerBar: beatsPerBar)
        let nSlots = slotCount(ts, subdivision: sub)
        let beatsPerSlot = beatsPerBar / Double(nSlots)

        var tSum = [Double](repeating: 0, count: nSlots)
        var vSum = [Double](repeating: 0, count: nSlots)
        var cnt = [Int](repeating: 0, count: nSlots)
        for (pos, vel) in inBar {
            let slot = (Int((pos / beatsPerSlot).rounded()) % nSlots + nSlots) % nSlots
            tSum[slot] += (pos - Double(slot) * beatsPerSlot) * Double(bfPerBeat)
            vSum[slot] += Double(vel)
            cnt[slot] += 1
        }
        let timing = (0..<nSlots).map { cnt[$0] > 0 ? tSum[$0] / Double(cnt[$0]) : 0 }
        let velocity = (0..<nSlots).map { cnt[$0] > 0 ? vSum[$0] / Double(cnt[$0]) : 0 }
        return Groove(timeSignature: ts, subdivision: sub, unit: .bf, timing: timing, velocity: velocity)
    }

    /// Smallest grid (multiple of the beat unit, ≥ 16 slots) on which no two onsets
    /// share a slot — covering straight (×2) and triplet (×3) families. Falls back
    /// to the finest candidate if the onsets can't be fully separated.
    static func autoSubdivision(forOnsetsInBeats positions: [Double],
                                timeSignature ts: TimeSignature, beatsPerBar: Double) -> Int {
        let den = ts.denominator
        let candidates = [4, 6, 8, 12, 16, 24, 32, 48]
            .map { $0 * den }
            .filter { ts.numerator * ($0 / den) >= minimumResolution }
            .sorted()
        for sub in candidates {
            let nSlots = ts.numerator * (sub / den)
            let beatsPerSlot = beatsPerBar / Double(nSlots)
            var used = Set<Int>(); var ok = true
            for p in positions {
                let slot = (Int((p / beatsPerSlot).rounded()) % nSlots + nSlots) % nSlots
                if !used.insert(slot).inserted { ok = false; break }
            }
            if ok { return sub }
        }
        return candidates.last ?? 16
    }
}
