// The .mgm document model: up to 128 slots (0–127), each holding one .stt
// (a `Groove`). It stores its own time signature, beats, subdivision and unit,
// and enforces that any .stt loaded into a slot is compatible. Empty slots 0
// and 127 default to "no swing" (all-zero offsets) when morphing.
import Foundation

public struct MGMDocument {
    public let timeSignature: TimeSignature
    public let subdivision: Int
    public let unit: Unit
    public private(set) var slots: [Int: Groove]

    public var beats: Int { timeSignature.numerator }
    public var populatedPositions: [Int] { slots.keys.sorted() }

    public init(timeSignature: TimeSignature, subdivision: Int, unit: Unit = .bf,
                slots: [Int: Groove] = [:]) throws {
        self.timeSignature = timeSignature
        self.subdivision = subdivision
        self.unit = unit
        self.slots = [:]
        for pos in slots.keys.sorted() { try setSlot(pos, slots[pos]!) }
    }

    /// Load one .stt (`Groove`) into a slot. Enforces slot range, grid/unit
    /// compatibility (blocking an incompatible .stt), spec validation, and that
    /// all populated slots agree on which optional lanes exist.
    public mutating func setSlot(_ position: Int, _ groove: Groove) throws {
        guard (0...127).contains(position) else { throw MGMError.slotOutOfRange(position) }
        if groove.timeSignature != timeSignature { throw MGMError.incompatibleWithMap(field: "time signature") }
        if groove.subdivision != subdivision { throw MGMError.incompatibleWithMap(field: "subdivision") }
        if groove.unit != unit { throw MGMError.incompatibleWithMap(field: "unit") }
        try groove.validate()
        if let existing = slots.values.first {
            if (groove.velocity != nil) != (existing.velocity != nil)
                || (groove.gate != nil) != (existing.gate != nil) {
                throw MGMError.lanePresenceMismatch
            }
        }
        slots[position] = groove
    }

    public mutating func clearSlot(_ position: Int) { slots[position] = nil }

    /// An all-zero ("no swing") groove with this document's geometry, matching
    /// the optional-lane presence of the populated slots.
    public func noSwingGroove() -> Groove {
        let n = slotCount(timeSignature, subdivision: subdivision)
        let ref = slots.values.first
        return Groove(timeSignature: timeSignature, subdivision: subdivision, unit: unit,
                      timing: [Double](repeating: 0, count: n),
                      velocity: ref?.velocity != nil ? [Double](repeating: 0, count: n) : nil,
                      gate: ref?.gate != nil ? [Double](repeating: 0, count: n) : nil)
    }

    /// Build the morph engine, defaulting empty slots 0 and 127 to no-swing so
    /// the dial endpoints are always defined.
    public func grooveMap() -> GrooveMap {
        var anchors = slots
        if anchors[0] == nil { anchors[0] = noSwingGroove() }
        if anchors[127] == nil { anchors[127] = noSwingGroove() }
        return GrooveMap(anchors)
    }

    /// Resolve the morph dial (0...127) to a single Groove.
    public func resolve(_ dial: Double) -> Groove { grooveMap().resolve(dial) }
}
