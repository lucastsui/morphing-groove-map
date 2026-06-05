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

                GroupBox("Remote analysis (Spark)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Use Spark for full-song analysis", isOn: $store.useRemote)
                        HStack {
                            Text("Server").frame(width: 80, alignment: .leading)
                            TextField("http://host:8001", text: $store.serverURL)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .accessibilityIdentifier("serverURL")
                        }
                        Text("Uploads the song to your Spark for Demucs source separation; "
                             + "falls back to on-device analysis if it's unreachable.")
                            .font(.caption2).foregroundStyle(.secondary)
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
