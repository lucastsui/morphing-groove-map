// Human-readable JSON file formats:
//   .stt — a single timing template (one `Groove`)
//   .mgm — a morphing groove map (a 128-slot `MGMDocument`)
//
// Both store time signature, beats, subdivision and unit; the .mgm lists only
// its populated slots (empty slots are implied, with 0/127 defaulting to
// no-swing on load via `MGMDocument`).
import Foundation

// MARK: - .stt

struct STTFile: Codable {
    var format: String = "STT"
    var version: Int = 1
    var timeSignature: String
    var beats: Int
    var subdivision: Int
    var unit: Unit
    var timing: [Double]
    var velocity: [Double]?
    var gate: [Double]?

    init(_ g: Groove) {
        timeSignature = g.timeSignature.description
        beats = g.timeSignature.numerator
        subdivision = g.subdivision
        unit = g.unit
        timing = g.timing
        velocity = g.velocity
        gate = g.gate
    }

    func groove() throws -> Groove {
        guard format == "STT" else { throw MGMError.badFileFormat("not an .stt (format=\(format))") }
        guard let ts = TimeSignature(timeSignature) else {
            throw MGMError.badFileFormat("time signature \(timeSignature)")
        }
        let g = Groove(timeSignature: ts, subdivision: subdivision, unit: unit,
                       timing: timing, velocity: velocity, gate: gate)
        try g.validate()
        return g
    }
}

// MARK: - .mgm

struct MGMSlotFile: Codable {
    var position: Int
    var timing: [Double]
    var velocity: [Double]?
    var gate: [Double]?
}

struct MGMFile: Codable {
    var format: String = "MGM"
    var version: Int = 1
    var timeSignature: String
    var beats: Int
    var subdivision: Int
    var unit: Unit
    var slots: [MGMSlotFile]

    init(_ doc: MGMDocument) {
        timeSignature = doc.timeSignature.description
        beats = doc.beats
        subdivision = doc.subdivision
        unit = doc.unit
        slots = doc.populatedPositions.map { pos in
            let g = doc.slots[pos]!
            return MGMSlotFile(position: pos, timing: g.timing, velocity: g.velocity, gate: g.gate)
        }
    }

    func document() throws -> MGMDocument {
        guard format == "MGM" else { throw MGMError.badFileFormat("not an .mgm (format=\(format))") }
        guard let ts = TimeSignature(timeSignature) else {
            throw MGMError.badFileFormat("time signature \(timeSignature)")
        }
        var doc = try MGMDocument(timeSignature: ts, subdivision: subdivision, unit: unit)
        for s in slots {
            let g = Groove(timeSignature: ts, subdivision: subdivision, unit: unit,
                           timing: s.timing, velocity: s.velocity, gate: s.gate)
            try doc.setSlot(s.position, g)
        }
        return doc
    }
}

// MARK: - Public API

public enum MGMIO {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // Data <-> value (no disk; handy for tests on Command Line Tools).
    public static func encodeSTT(_ groove: Groove) throws -> Data { try encoder.encode(STTFile(groove)) }
    public static func decodeSTT(_ data: Data) throws -> Groove {
        try JSONDecoder().decode(STTFile.self, from: data).groove()
    }
    public static func encodeMGM(_ document: MGMDocument) throws -> Data { try encoder.encode(MGMFile(document)) }
    public static func decodeMGM(_ data: Data) throws -> MGMDocument {
        try JSONDecoder().decode(MGMFile.self, from: data).document()
    }

    // Disk helpers.
    public static func saveSTT(_ groove: Groove, to url: URL) throws { try encodeSTT(groove).write(to: url) }
    public static func loadSTT(from url: URL) throws -> Groove { try decodeSTT(Data(contentsOf: url)) }
    public static func saveMGM(_ document: MGMDocument, to url: URL) throws { try encodeMGM(document).write(to: url) }
    public static func loadMGM(from url: URL) throws -> MGMDocument { try decodeMGM(Data(contentsOf: url)) }
}
