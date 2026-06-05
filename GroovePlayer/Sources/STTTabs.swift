// The Welcome tab (global settings incl. MIDI 1.0/2.0) and the two .STT tabs:
// "full" (display-only overview of every beat) and "beats" (single-beat editor
// with fbu / ms / note readouts and step buttons).
import SwiftUI
import MGMKit
import UniformTypeIdentifiers

// Custom document types for the file pickers (module-wide).
let sttType = UTType(filenameExtension: "stt") ?? .data
let mgmType = UTType(filenameExtension: "mgm") ?? .data
let agrType = UTType(filenameExtension: "agr") ?? .data   // Ableton groove

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Morphing Groove Map").font(.largeTitle.bold())
                Text("Capture swing as tempo-independent beat-fraction (fbu) offsets, "
                     + "morph between grooves, and stamp them onto audio. Edit single "
                     + "templates (.STT) and arrange them across 128 slots (.MGM).")
                    .foregroundStyle(.secondary)

                GroupBox("Global settings") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("MIDI version").frame(width: 130, alignment: .leading)
                            Picker("", selection: $store.midiMode) {
                                ForEach(MIDIMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented).frame(maxWidth: 280)
                        }
                        Text("Velocity range: 0–\(store.midiMode.maxVelocity) "
                             + "(\(store.midiMode == .v1 ? "7-bit" : "16-bit")). "
                             + "Affects velocity only — not timing or gate.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        ProjectSettings()
                    }
                }

                Text(store.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }
}

// MARK: - .STT full (all beats, display only)

struct STTFullView: View {
    @EnvironmentObject var store: Store
    @State private var showLoader = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FileHeader(name: $store.sttName, ext: ".STT", editable: .constant(false), showEdit: false,
                           onLoad: { showLoader = true }, onSave: { store.saveSTT() })
                ProjectSettings()
                Divider()
                Text("All beats (display only)").font(.headline)

                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(0..<store.beatResolution), id: \.self) { i in
                            let t = store.beatTriplet(i)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(i + 1)").font(.caption.bold())
                                Rectangle()
                                    .fill(t.fbu < 0 ? Color.orange : Color.blue)
                                    .frame(width: 28, height: 4 + CGFloat(min(60, abs(t.fbu) / 1000)))
                                Text(String(format: "%+.0f fbu", t.fbu)).font(.caption2.monospacedDigit())
                                Text(String(format: "%+.2f ms", t.ms)).font(.caption2.monospacedDigit())
                                Text(t.note).font(.caption2).foregroundStyle(.secondary)
                                if store.velocity.indices.contains(i) {
                                    Text("vel \(Int(store.velocity[i]))").font(.caption2.monospacedDigit()).foregroundStyle(.green)
                                }
                                if store.gate.indices.contains(i) {
                                    Text(String(format: "gate %+.0f", store.gate[i])).font(.caption2.monospacedDigit()).foregroundStyle(.purple)
                                }
                            }
                            .frame(width: 92)
                        }
                    }
                }

                Text(store.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .fileImporter(isPresented: $showLoader, allowedContentTypes: [sttType, mgmType],
                      allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first {
                u.pathExtension.lowercased() == "mgm" ? store.loadMGM(u) : store.loadSTT(u)
            }
        }
    }
}

// MARK: - .STT beats (single-beat editor)

// MARK: - Tall symlog per-beat slider

/// A tall vertical slider for the selected beat's offset. Symlog scale (offsets
/// cluster near 0, so small ones get most of the travel), bipolar (up = late/blue,
/// down = early/orange), with the magnitude ladder labelled down the side. Drag
/// anywhere on the track to set the offset.
struct BeatSlider: View {
    @EnvironmentObject var store: Store
    private let trackH: CGFloat = 300
    private let trackW: CGFloat = 40
    private static let ticks: [(String, Double)] = [
        ("+196k", 196608), ("+64k", 65536), ("+16k", 16384), ("+4k", 4096),
        ("+1k", 1024), ("+256", 256), ("+64", 64), ("0", 0),
        ("−64", -64), ("−256", -256), ("−1k", -1024), ("−4k", -4096),
        ("−16k", -16384), ("−64k", -65536), ("−196k", -196608),
    ]

    var body: some View {
        let halfH = trackH / 2
        let t = store.selectedFBU
        let thumbY = halfH - CGFloat(symlogNorm(t)) * halfH
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.10))
                    .frame(width: trackW, height: trackH)
                ForEach(BeatSlider.ticks, id: \.1) { tick in
                    Rectangle().fill(Color.secondary.opacity(tick.1 == 0 ? 0.5 : 0.18))
                        .frame(width: trackW, height: tick.1 == 0 ? 1.5 : 1)
                        .offset(y: halfH - CGFloat(symlogNorm(tick.1)) * halfH - 0.5)
                }
                Rectangle()
                    .fill(t < 0 ? Color.orange : (t > 0 ? Color.blue : Color.clear))
                    .frame(width: trackW, height: abs(thumbY - halfH))
                    .offset(y: min(thumbY, halfH))
                Capsule().fill(t < 0 ? Color.orange : Color.blue)
                    .frame(width: trackW + 10, height: 7)
                    .offset(y: thumbY - 3.5)
            }
            .frame(width: trackW, height: trackH, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let y = min(max(0, g.location.y), trackH)
                    store.selectedFBU = clampBF(store.snapped(symlogInv(Double((halfH - y) / halfH)))).rounded()
                }
            )
            .accessibilityIdentifier("beatSlider")
            ZStack(alignment: .topLeading) {
                ForEach(BeatSlider.ticks, id: \.1) { tick in
                    Text(tick.0).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                        .offset(y: halfH - CGFloat(symlogNorm(tick.1)) * halfH - 6)
                }
            }
            .frame(width: 46, height: trackH, alignment: .topLeading)
        }
    }
}

struct STTBeatsView: View {
    @EnvironmentObject var store: Store
    @State private var showLoader = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FileHeader(name: $store.sttName, ext: ".STT", editable: .constant(false), showEdit: false,
                           onLoad: { showLoader = true }, onSave: { store.saveSTT() })
                ProjectSettings()
                Divider()

                Text("Select Current Beat").font(.headline)
                BeatTimeline()
                HStack(spacing: 16) {
                    readout("\(Int(store.selectedFBU)) fbu")
                    readout(String(format: "%.2f ms", store.selectedMs))
                    readout(store.selectedNoteLabel)
                }

                Divider()
                Text("Tune offset (drag the slider)").font(.headline)
                BeatSlider()
                HStack(spacing: 12) {
                    Toggle("Snap", isOn: $store.snapEnabled)
                        .toggleStyle(.switch)
                        .fixedSize()
                        .accessibilityIdentifier("snapToggle")
                    Picker("", selection: $store.snapStep) {
                        ForEach([16, 32, 64, 128, 256, 512, 1024], id: \.self) { v in
                            Text(String(v)).tag(v)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!store.snapEnabled)
                    .accessibilityIdentifier("snapStep")
                    Text("fbu").font(.caption2).foregroundStyle(.secondary)
                }

                Divider()
                Text("Adjust Current Beat").font(.headline)
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(spacing: 2) {
                        DoubleBox(value: Binding(get: { store.selectedFBU }, set: { store.selectedFBU = $0 }), width: 90)
                        Text("fbu").font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 2) {
                        DoubleBox(value: Binding(get: { store.selectedMs }, set: { store.selectedMs = $0 }), width: 90)
                        Text("ms").font(.caption2).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 2) {
                        DoubleBox(value: Binding(get: { store.selectedNoteCount }, set: { store.selectedNoteCount = $0 }), width: 90)
                        Text("× \(store.noteUnit.name)").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    StepRow(label: "fbu", steps: [("−1024", -1024), ("−128", -128), ("−16", -16), ("−1", -1),
                                                  ("0", 0), ("+1", 1), ("+16", 16), ("+128", 128), ("+1024", 1024)]) { store.stepFBU($0) }
                    StepRow(label: "ms", steps: [("−10", -10), ("−1", -1), ("−.1", -0.1), ("0", 0),
                                                 ("+.1", 0.1), ("+1", 1), ("+10", 10)]) { store.stepMs($0) }
                    HStack {
                        StepRow(label: "notes", steps: [("−1", -1), ("−1/2", -0.5), ("−1/4", -0.25), ("0", 0),
                                                        ("+1/4", 0.25), ("+1/2", 0.5), ("+1", 1)]) { store.stepNote($0) }
                        Picker("", selection: $store.noteUnitIndex) {
                            ForEach(NoteUnit.all.indices, id: \.self) { Text(NoteUnit.all[$0].name).tag($0) }
                        }.pickerStyle(.menu)
                    }
                }

                Divider()
                HStack {
                    Button { store.previewPlay() } label: { Label("Preview", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    Button { store.playTarget() } label: { Label("Play target", systemImage: "play") }
                        .buttonStyle(.bordered)
                }
                Text(store.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .fileImporter(isPresented: $showLoader, allowedContentTypes: [sttType, mgmType],
                      allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first {
                u.pathExtension.lowercased() == "mgm" ? store.loadMGM(u) : store.loadSTT(u)
            }
        }
    }

    private func readout(_ s: String) -> some View {
        Text(s).font(.title3.monospacedDigit())
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }
}
