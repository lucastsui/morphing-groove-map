// Lossless, event-based representation of a clip / groove — the source of truth
// an .agr (an Ableton groove == a MIDI clip) or a MIDI file maps to WITHOUT loss.
// The per-slot `Groove` is a derived VIEW of this (folding events onto a bar grid):
// the view is a lossy reduction, but the events keep everything.
import Foundation
import Compression

/// One note carrying everything a clip event holds (so nothing is dropped).
public struct NoteEvent: Equatable, Sendable {
    public var pitch: Int            // MIDI key — lane / drum identity (preserves polyphony)
    public var startBeats: Double    // exact onset, in beats from clip start
    public var durationBeats: Double
    public var velocity: Double      // 0...127, kept as a float (not rounded)
    public var offVelocity: Double
    public var enabled: Bool

    public init(pitch: Int, startBeats: Double, durationBeats: Double,
                velocity: Double, offVelocity: Double = 64, enabled: Bool = true) {
        self.pitch = pitch; self.startBeats = startBeats; self.durationBeats = durationBeats
        self.velocity = velocity; self.offVelocity = offVelocity; self.enabled = enabled
    }
}

/// Lossless clip groove: time signature, length (multi-bar), and the raw notes.
/// `.agr -> ClipGroove -> .agr` is lossless by construction — the events hold at
/// least as much as the source clip (no grid, no one-value-per-slot reduction).
public struct ClipGroove: Equatable, Sendable {
    public var timeSignature: TimeSignature
    public var lengthBeats: Double
    public var notes: [NoteEvent]

    public init(timeSignature: TimeSignature, lengthBeats: Double, notes: [NoteEvent]) {
        self.timeSignature = timeSignature
        self.lengthBeats = lengthBeats
        self.notes = notes
    }

    public var pitches: [Int] { Array(Set(notes.map(\.pitch))).sorted() }

    private var beatsPerBar: Double { Double(timeSignature.numerator) * 4.0 / Double(timeSignature.denominator) }
    public var bars: Int { max(1, Int((lengthBeats / beatsPerBar).rounded(.up))) }

    /// Derive the per-slot editable VIEW: fold one bar's notes (all pitches) onto a
    /// grid at their true offsets (bf). A lossy projection of the lossless events —
    /// the `Groove` carries one timing + one velocity per slot.
    public func groove(subdivision fixedSub: Int? = nil, bar: Int? = nil) -> Groove {
        let bpb = beatsPerBar
        let on = notes.filter(\.enabled)

        func empty(_ s: Int) -> Groove {
            let n = slotCount(timeSignature, subdivision: s)
            return Groove(timeSignature: timeSignature, subdivision: s, unit: .bf,
                          timing: [Double](repeating: 0, count: n),
                          velocity: [Double](repeating: 0, count: n))
        }
        guard !on.isEmpty else { return empty(fixedSub ?? 16) }

        // default: the bar with the most onsets (most representative single bar)
        let chosenBar: Int
        if let bar { chosenBar = bar }
        else {
            var counts: [Int: Int] = [:]
            for nt in on where nt.startBeats >= 0 { counts[Int(nt.startBeats / bpb), default: 0] += 1 }
            chosenBar = counts.max { $0.value < $1.value }?.key ?? 0
        }
        let barStart = Double(chosenBar) * bpb
        let inBar: [(pos: Double, vel: Double)] = on.compactMap { nt in
            let local = nt.startBeats - barStart
            return (local >= 0 && local < bpb) ? (local, nt.velocity) : nil
        }
        guard !inBar.isEmpty else { return empty(fixedSub ?? 16) }

        let sub = fixedSub ?? MIDIImport.autoSubdivision(forOnsetsInBeats: inBar.map(\.pos),
                                                         timeSignature: timeSignature, beatsPerBar: bpb)
        let nSlots = slotCount(timeSignature, subdivision: sub)
        let beatsPerSlot = bpb / Double(nSlots)
        var tSum = [Double](repeating: 0, count: nSlots)
        var vSum = [Double](repeating: 0, count: nSlots)
        var cnt = [Int](repeating: 0, count: nSlots)
        for (pos, vel) in inBar {
            let slot = (Int((pos / beatsPerSlot).rounded()) % nSlots + nSlots) % nSlots
            tSum[slot] += (pos - Double(slot) * beatsPerSlot) * Double(bfPerBeat)
            vSum[slot] += vel
            cnt[slot] += 1
        }
        let timing = (0..<nSlots).map { cnt[$0] > 0 ? tSum[$0] / Double(cnt[$0]) : 0 }
        let velocity = (0..<nSlots).map { cnt[$0] > 0 ? vSum[$0] / Double(cnt[$0]) : 0 }
        return Groove(timeSignature: timeSignature, subdivision: sub, unit: .bf,
                      timing: timing, velocity: velocity)
    }
}

// MARK: - .agr import (gzipped Ableton XML -> ClipGroove)

public enum AGRImport {
    /// Parse a (gzipped) Ableton `.agr` groove file into a lossless `ClipGroove`.
    public static func parse(_ data: Data) throws -> ClipGroove {
        let xml: Data
        if data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b {
            guard let unzipped = gunzip(data) else { throw MGMError.badFileFormat(".agr: gunzip failed") }
            xml = unzipped
        } else {
            xml = data   // already plain XML
        }
        let p = AGRParser()
        guard p.run(xml) else { throw MGMError.badFileFormat(".agr: XML parse failed") }
        guard !p.notes.isEmpty else { throw MGMError.badFileFormat(".agr: no notes found") }
        let num = p.numerator ?? 4, den = p.denominator ?? 4
        let length = p.loopEnd ?? (Double(num) * 4.0 / Double(den))
        return ClipGroove(timeSignature: TimeSignature(num, den), lengthBeats: length, notes: p.notes)
    }
}

/// SAX parser for the relevant bits of an Ableton groove/clip XML.
final class AGRParser: NSObject, XMLParserDelegate {
    var numerator: Int?
    var denominator: Int?
    var loopEnd: Double?
    var notes: [NoteEvent] = []
    private var pending: [NoteEvent] = []   // notes in the current KeyTrack (pitch resolved at <MidiKey>)

    func run(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        switch el {
        case "Numerator":   if numerator == nil, let v = a["Value"] { numerator = Int(v) }
        case "Denominator": if denominator == nil, let v = a["Value"] { denominator = Int(v) }
        case "LoopEnd":     if loopEnd == nil, let v = a["Value"] { loopEnd = Double(v) }
        case "MidiNoteEvent":
            pending.append(NoteEvent(
                pitch: 0,
                startBeats: Double(a["Time"] ?? "") ?? 0,
                durationBeats: Double(a["Duration"] ?? "") ?? 0,
                velocity: Double(a["Velocity"] ?? "") ?? 0,
                offVelocity: Double(a["OffVelocity"] ?? "") ?? 64,
                enabled: (a["IsEnabled"] ?? "true") != "false"))
        case "MidiKey":
            if let v = a["Value"], let key = Int(v) {
                for var nt in pending { nt.pitch = key; notes.append(nt) }
                pending.removeAll(keepingCapacity: true)
            }
        default: break
        }
    }
}

// MARK: - gunzip (Compression framework; works on iOS + macOS)

/// Inflate gzip (RFC 1952): strip the header/optional fields, then raw DEFLATE.
func gunzip(_ data: Data) -> Data? {
    let b = [UInt8](data)
    guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 0x08 else { return nil }
    let flags = b[3]
    var i = 10
    if flags & 0x04 != 0 {                                   // FEXTRA
        guard i + 1 < b.count else { return nil }
        i += 2 + (Int(b[i]) | (Int(b[i + 1]) << 8))
    }
    if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }   // FNAME
    if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }   // FCOMMENT
    if flags & 0x02 != 0 { i += 2 }                          // FHCRC
    guard i < b.count - 8 else { return nil }
    let deflate = Array(b[i..<(b.count - 8)])
    let isize = Int(b[b.count - 4]) | (Int(b[b.count - 3]) << 8)
              | (Int(b[b.count - 2]) << 16) | (Int(b[b.count - 1]) << 24)
    let cap = isize > 0 ? isize : deflate.count * 8
    var dst = [UInt8](repeating: 0, count: cap)
    let n = compression_decode_buffer(&dst, cap, deflate, deflate.count, nil, COMPRESSION_ZLIB)
    guard n > 0 else { return nil }
    return Data(dst[0..<n])
}
