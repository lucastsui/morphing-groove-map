// Compare the two MIDI->groove extractions on a real file:
//   swift run --package-path MGMKit MIDICompare <file.mid> [bar]
//
//   TEMPLATE = MIDIImport.extractGroove  (folds ALL bars, averages per slot,
//              half-slot rejection — the existing app behavior)
//   EXACT    = MIDIImport.extractGrooveExact  (one bar, auto-grid, true offsets,
//              no cross-bar averaging, no rejection)
import Foundation
import MGMKit

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: MIDICompare <file.mid> [bar]"); exit(2)
}
let path = args[1]
let bar = args.count > 2 ? Int(args[2]) : nil
guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
    print("could not read \(path)"); exit(1)
}

let ts = TimeSignature(4, 4)
let (notes, bpm) = try MIDIImport.parse(data)
let beatsPerBar = 4.0
let positions = notes.map { $0.timeSeconds * bpm / 60.0 }
let bars = Int((positions.max() ?? 0) / beatsPerBar) + 1

print("file:   \((path as NSString).lastPathComponent)")
print(String(format: "parsed: %d note-ons · %.1f bpm · ~%d bars", notes.count, bpm, bars))

func dump(_ label: String, _ g: Groove) {
    print("\n\(label)")
    print("  subdivision \(g.subdivision) · \(g.timing.count) slots · unit \(g.unit)")
    print("  timing(bf): [" + g.timing.map { String(format: "%+.0f", $0) }.joined(separator: ", ") + "]")
    print("  velocity:   [" + (g.velocity ?? []).map { String(Int($0.rounded())) }.joined(separator: ", ") + "]")
    let nz = g.timing.filter { $0 != 0 }
    if !nz.isEmpty {
        print(String(format: "  nonzero offsets: %d · range %+.0f … %+.0f bf · |mean| %.0f bf",
                     nz.count, nz.min()!, nz.max()!, nz.map(abs).reduce(0,+) / Double(nz.count)))
    }
}

let template = try MIDIImport.extractGroove(from: data, timeSignature: ts, subdivision: 16, unit: .bf)
let exact = try MIDIImport.extractGrooveExact(from: data, timeSignature: ts, bar: bar)

dump("TEMPLATE  (current: \(bars) bars folded + averaged, 16 slots)", template)
dump("EXACT     (one bar, auto-grid, true per-onset offsets)", exact)
