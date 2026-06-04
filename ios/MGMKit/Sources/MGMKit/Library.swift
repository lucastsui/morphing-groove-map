// Groove library JSON loading -- reads the same groove_library.json produced by
// build_library.py (the 35 grooves extracted from the Google Groove MIDI
// Dataset), so the iPad app ships the identical library.
import Foundation

/// One library entry (matches the JSON schema from build_library.py).
public struct LibraryGroove: Codable, Identifiable, Sendable {
    public let name: String
    public let style: String
    public let bpm: Int
    public let subdivision: Int
    public let time_signature: String
    public let unit: String
    public let timing: [Double]

    public var id: String { "\(name)#\(bpm)" }

    /// Convert to a full Groove value.
    public func groove() -> Groove {
        Groove(timeSignature: TimeSignature(time_signature) ?? TimeSignature(4, 4),
               subdivision: subdivision, unit: Unit(rawValue: unit) ?? .ms,
               timing: timing)
    }

    /// A straight (all-zero) groove with this entry's geometry, for dial 0.
    public func straightCounterpart() -> Groove {
        Groove(timeSignature: TimeSignature(time_signature) ?? TimeSignature(4, 4),
               subdivision: subdivision, unit: Unit(rawValue: unit) ?? .ms,
               timing: [Double](repeating: 0, count: timing.count))
    }
}

public enum Library {
    /// Decode a groove library from JSON data.
    public static func load(from data: Data) throws -> [LibraryGroove] {
        try JSONDecoder().decode([LibraryGroove].self, from: data)
    }

    /// Load the `groove_library.json` bundled with an app target.
    public static func loadBundled(_ bundle: Bundle = .main,
                                   resource: String = "groove_library") -> [LibraryGroove] {
        guard let url = bundle.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let grooves = try? load(from: data) else { return [] }
        return grooves
    }
}
