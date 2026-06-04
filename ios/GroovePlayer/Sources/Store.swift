// App state: the bundled Google library, the user's analyzed swing files, and
// the actions (analyze the Amen, render+play the target with a groove).
import Foundation
import MGMKit
import SwiftUI

/// A selectable groove from either list.
struct GrooveItem: Identifiable {
    let id: String
    let name: String
    let style: String
    let bpm: Int
    let groove: Groove
    let isUser: Bool
}

@MainActor
final class Store: ObservableObject {
    @Published var google: [GrooveItem] = []
    @Published var user: [GrooveItem] = []
    @Published var selectedID: String?
    @Published var dial: Double = 127
    @Published var status: String = ""

    private let audio: AudioEngine
    private var target: (samples: [Float], sr: Int)?

    init(audio: AudioEngine) {
        self.audio = audio
        loadLibrary()
        target = audio.loadMono("straight_target")
        if let first = google.first { selectedID = first.id }
    }

    var selected: GrooveItem? {
        (google + user).first { $0.id == selectedID }
    }

    private func loadLibrary() {
        let lib = Library.loadBundled()
        google = lib.enumerated().map { i, g in
            GrooveItem(id: "g\(i)", name: g.name, style: g.style, bpm: g.bpm,
                       groove: g.groove(), isUser: false)
        }
    }

    // MARK: actions

    func playAmen() {
        guard let a = audio.loadMono("amen") else { status = "amen.wav missing"; return }
        audio.play(a.samples, sr: a.sr, label: "Amen break")
        status = "playing source: Amen break"
    }

    func playTarget() {
        guard let t = target else { status = "target missing"; return }
        audio.play(t.samples, sr: t.sr, label: "straight target")
        status = "playing source: straight target"
    }

    /// Analyze the bundled Amen into a new user swing file (on-device, vDSP).
    func analyzeAmen() {
        guard let a = audio.loadMono("amen") else { status = "amen.wav missing"; return }
        status = "analyzing amen.wav…"
        let times = Onset.accurateOnsetTimes(a.samples, sampleRate: a.sr)
        let offsets = Onset.offsets(fromOnsetTimes: times, bpm: 137.2,
                                    timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .ms)
        let groove = Groove(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .ms, timing: offsets)
        let item = GrooveItem(id: "u\(user.count)", name: "Amen swing #\(user.count + 1)",
                              style: "user", bpm: 137, groove: groove, isUser: true)
        user.append(item)
        selectedID = item.id
        status = "added \(item.name) to My Swing Files"
    }

    /// Render the target with the selected groove at the current dial, then play.
    func playWithGroove() {
        guard let item = selected else { status = "pick a groove first"; return }
        guard let t = target else { status = "target missing"; return }
        status = "rendering…"
        let straight = Groove(timeSignature: item.groove.timeSignature,
                              subdivision: item.groove.subdivision, unit: .ms,
                              timing: [Double](repeating: 0, count: item.groove.timing.count))
        let map = GrooveMap([0: straight, 127: item.groove])
        let resolved = map.resolve(dial)
        let out = Render.grooved(target: t.samples, sampleRate: t.sr, groove: resolved)
        audio.play(out, sr: t.sr, label: item.name)
        status = "playing: \(item.name)  (dial \(Int(dial)))"
    }
}
