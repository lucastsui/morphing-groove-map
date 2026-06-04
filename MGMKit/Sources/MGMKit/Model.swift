// Groove model + morph math -- the Swift port of mgm/groove.py, mgm/grid.py,
// mgm/units.py. Pure value types so it's trivially Codable and testable.
import Foundation

// MARK: - Units

public enum Unit: String, Codable, Sendable {
    case ms
    case samples
    case bf
}

/// samples = seconds * rate  (30 ms @ 48 kHz = 1440 samples)
public func msToSamples(_ ms: Double, sampleRate: Int) -> Double {
    (ms / 1000.0) * Double(sampleRate)
}

public func samplesToMs(_ samples: Double, sampleRate: Int) -> Double {
    (samples / Double(sampleRate)) * 1000.0
}

/// Rescale a sample value across rates: new = old * newRate / oldRate.
public func rescaleSamples(_ value: Double, from oldRate: Int, to newRate: Int) -> Double {
    value * Double(newRate) / Double(oldRate)
}

// MARK: - Beat fractions (bf)
//
// The spec's tempo-independent unit: one beat == bfPerBeat == 196608 == 2^16*3.
// The *3 makes triplets land on EXACT integers (196608 / 3 = 65536), so swing --
// fundamentally a triplet feel -- is representable with no rounding; the 2^16
// gives fine "straight" resolution. A bf keeps its musical meaning at any tempo;
// supply a tempo (and rate) to realise it as ms / samples. Spec range is +/- one
// beat (bfMax); larger offsets (note-order swapping) are out of scope.

public let bfPerBeat = 196608   // 2^16 * 3
public let bfMax = 196608       // +/- one beat

public func bfToBeats(_ bf: Double) -> Double { bf / Double(bfPerBeat) }
public func beatsToBF(_ beats: Double) -> Double { beats * Double(bfPerBeat) }

public func bfToSeconds(_ bf: Double, bpm: Double) -> Double { bfToBeats(bf) * (60.0 / bpm) }
public func secondsToBF(_ seconds: Double, bpm: Double) -> Double { beatsToBF(seconds * bpm / 60.0) }

/// Spec UC-6 example: 3072 bf @ 60 BPM = 1/64 beat = 15.625 ms.
public func bfToMs(_ bf: Double, bpm: Double) -> Double { bfToSeconds(bf, bpm: bpm) * 1000.0 }
public func msToBF(_ ms: Double, bpm: Double) -> Double { secondsToBF(ms / 1000.0, bpm: bpm) }

public func bfToSamples(_ bf: Double, bpm: Double, sampleRate: Int) -> Double {
    bfToSeconds(bf, bpm: bpm) * Double(sampleRate)
}
public func samplesToBF(_ samples: Double, bpm: Double, sampleRate: Int) -> Double {
    secondsToBF(samples / Double(sampleRate), bpm: bpm)
}

public func bfInRange(_ bf: Double) -> Bool { bf >= Double(-bfMax) && bf <= Double(bfMax) }
public func clampBF(_ bf: Double) -> Double { min(max(bf, Double(-bfMax)), Double(bfMax)) }

private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

/// Describe a bf magnitude as a fraction of a beat, e.g. "1/64 beat".
/// Follows the spec's UC-6 convention (a "1/N note" == 1/N of a beat); a
/// denominator divisible by 3 is flagged as a triplet division.
public func bfToNoteValue(_ bf: Double) -> String {
    if bf == 0 { return "0 (on grid)" }
    let sign = bf < 0 ? "-" : ""
    let n = Int(abs(bf).rounded())
    let g = max(gcd(n, bfPerBeat), 1)
    let num = n / g, den = bfPerBeat / g
    var label = "\(num)/\(den) beat"
    if den % 3 == 0 { label += " (triplet)" }
    return sign + label
}

/// UC-6 view of a bf value at a tempo: beats, note value, ms, optional samples.
public struct BFDescription: Equatable, Sendable {
    public let bf: Double
    public let beats: Double
    public let noteValue: String
    public let ms: Double
    public let samples: Double?
}

/// UC-6: translate a beat-fraction value for a chosen tempo. Raw bf numbers
/// aren't legible, so surface beats / note value / ms (and samples if a rate).
public func describeBF(_ bf: Double, bpm: Double, sampleRate: Int? = nil) -> BFDescription {
    BFDescription(bf: bf, beats: bfToBeats(bf), noteValue: bfToNoteValue(bf),
                  ms: bfToMs(bf, bpm: bpm),
                  samples: sampleRate.map { bfToSamples(bf, bpm: bpm, sampleRate: $0) })
}

// MARK: - Grid

public struct TimeSignature: Codable, Equatable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Parse "4/4" -> TimeSignature(4, 4).
    public init?(_ text: String) {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]) else { return nil }
        self.init(n, d)
    }

    public var description: String { "\(numerator)/\(denominator)" }
}

/// Slots per beat = subdivision / beat-unit (must divide evenly).
public func slicesPerBeat(_ ts: TimeSignature, subdivision: Int) -> Int {
    precondition(subdivision % ts.denominator == 0,
                 "subdivision \(subdivision) not a multiple of beat unit \(ts.denominator)")
    return subdivision / ts.denominator
}

/// Total slots in one measure = beats * slicesPerBeat.
public func slotCount(_ ts: TimeSignature, subdivision: Int) -> Int {
    ts.numerator * slicesPerBeat(ts, subdivision: subdivision)
}

/// True for triplet grids (a factor of 3: 12, 24, 48, 96). On a triplet grid a
/// swing feel lands on exact slots; a straight grid (power of two) only
/// approximates it with timing offsets.
public func isTripletSubdivision(_ subdivision: Int) -> Bool { subdivision % 3 == 0 }

// MARK: - Groove

/// One resolved feel: parallel timing / velocity / gate lanes over the slots of
/// one measure. `timing` is required; the other lanes are optional.
public struct Groove: Codable, Equatable, Sendable {
    public var timeSignature: TimeSignature
    public var subdivision: Int
    public var unit: Unit
    public var sampleRate: Int?
    public var timing: [Double]
    public var velocity: [Double]?
    public var gate: [Double]?

    public init(timeSignature: TimeSignature, subdivision: Int, unit: Unit = .ms,
                sampleRate: Int? = nil, timing: [Double],
                velocity: [Double]? = nil, gate: [Double]? = nil) {
        self.timeSignature = timeSignature
        self.subdivision = subdivision
        self.unit = unit
        self.sampleRate = sampleRate
        self.timing = timing
        self.velocity = velocity
        self.gate = gate
    }

    public var slots: Int { timing.count }
}

// MARK: - Morph (the dial)

public let dialMin = 0
public let dialMax = 127

/// out = vLow + (vHigh - vLow) * (pos - pLow) / (pHigh - pLow)
@inline(__always)
func lerp(_ vLow: Double, _ vHigh: Double, _ pos: Double, _ pLow: Int, _ pHigh: Int) -> Double {
    vLow + (vHigh - vLow) * (pos - Double(pLow)) / Double(pHigh - pLow)
}

/// A morphable set of anchors along a 0-127 dial. Resolving a dial position
/// linearly interpolates, slot by slot, between the two bracketing anchors.
public struct GrooveMap {
    public struct Anchor { public let position: Int; public let groove: Groove }
    public let anchors: [Anchor]  // sorted by position

    public init(_ anchorsByPosition: [Int: Groove]) {
        precondition(!anchorsByPosition.isEmpty, "a GrooveMap needs at least one anchor")
        self.anchors = anchorsByPosition
            .sorted { $0.key < $1.key }
            .map { Anchor(position: $0.key, groove: $0.value) }
    }

    public var positions: [Int] { anchors.map(\.position) }

    private func bracket(_ pos: Double) -> (Anchor, Anchor) {
        if pos <= Double(anchors.first!.position) { return (anchors.first!, anchors.first!) }
        if pos >= Double(anchors.last!.position) { return (anchors.last!, anchors.last!) }
        for i in 0..<(anchors.count - 1) {
            if Double(anchors[i].position) <= pos && pos <= Double(anchors[i + 1].position) {
                return (anchors[i], anchors[i + 1])
            }
        }
        return (anchors.last!, anchors.last!)
    }

    /// Resolve the dial to a concrete Groove (interpolates every present lane).
    public func resolve(_ position: Double) -> Groove {
        let (low, high) = bracket(position)
        let ref = low.groove
        if low.position == high.position { return ref }

        func blend(_ a: [Double], _ b: [Double]) -> [Double] {
            zip(a, b).map { lerp($0, $1, position, low.position, high.position) }
        }
        let g0 = low.groove, g1 = high.groove
        return Groove(
            timeSignature: ref.timeSignature, subdivision: ref.subdivision,
            unit: ref.unit, sampleRate: ref.sampleRate,
            timing: blend(g0.timing, g1.timing),
            velocity: (g0.velocity != nil && g1.velocity != nil) ? blend(g0.velocity!, g1.velocity!) : nil,
            gate: (g0.gate != nil && g1.gate != nil) ? blend(g0.gate!, g1.gate!) : nil
        )
    }
}

// MARK: - Errors + validation (spec enforcement)

/// The minimum number of slots a template may have (spec: "minimum 16 notes").
public let minimumResolution = 16

public enum MGMError: Error, CustomStringConvertible {
    case wrongSlotCount(expected: Int, got: Int)
    case belowMinimumResolution(minimum: Int, got: Int)
    case laneLengthMismatch(lane: String, expected: Int, got: Int)
    case velocityOutOfRange(value: Double)
    case incompatibleWithMap(field: String)
    case lanePresenceMismatch
    case slotOutOfRange(Int)
    case emptyDocument
    case badFileFormat(String)
    case badMIDI(String)

    public var description: String {
        switch self {
        case let .wrongSlotCount(e, g): return "timing has \(g) slots but the grid needs \(e)"
        case let .belowMinimumResolution(m, g): return "resolution \(g) is below the minimum of \(m) slots"
        case let .laneLengthMismatch(l, e, g): return "\(l) lane has \(g) slots, expected \(e)"
        case let .velocityOutOfRange(v): return "velocity \(v) is outside the MIDI range 0...127"
        case let .incompatibleWithMap(f): return "incompatible \(f): this .stt does not match the .mgm"
        case .lanePresenceMismatch: return "all slots must agree on whether velocity/gate exist"
        case let .slotOutOfRange(p): return "slot \(p) is outside 0...127"
        case .emptyDocument: return "a morphing groove map needs at least one populated slot"
        case let .badFileFormat(m): return "bad file: \(m)"
        case let .badMIDI(m): return "bad MIDI: \(m)"
        }
    }
}

extension Groove {
    /// Validate against the spec rules: correct slot count, ≥ minimum resolution,
    /// matching optional-lane lengths, and velocity within the MIDI range 0...127.
    public func validate(minSlots: Int = minimumResolution) throws {
        let expected = slotCount(timeSignature, subdivision: subdivision)
        if timing.count != expected {
            throw MGMError.wrongSlotCount(expected: expected, got: timing.count)
        }
        if timing.count < minSlots {
            throw MGMError.belowMinimumResolution(minimum: minSlots, got: timing.count)
        }
        if let v = velocity {
            if v.count != timing.count {
                throw MGMError.laneLengthMismatch(lane: "velocity", expected: timing.count, got: v.count)
            }
            if let bad = v.first(where: { $0 < 0 || $0 > 127 }) {
                throw MGMError.velocityOutOfRange(value: bad)
            }
        }
        if let g = gate, g.count != timing.count {
            throw MGMError.laneLengthMismatch(lane: "gate", expected: timing.count, got: g.count)
        }
    }

    /// True if `other` shares this groove's grid geometry + unit (so both can
    /// live in the same .mgm).
    public func isCompatible(with other: Groove) -> Bool {
        timeSignature == other.timeSignature && subdivision == other.subdivision
            && unit == other.unit && timing.count == other.timing.count
    }
}
