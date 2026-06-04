// Groove model + morph math -- the Swift port of mgm/groove.py, mgm/grid.py,
// mgm/units.py. Pure value types so it's trivially Codable and testable.
import Foundation

// MARK: - Units

public enum Unit: String, Codable, Sendable {
    case ms
    case samples
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
