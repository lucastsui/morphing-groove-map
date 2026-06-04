// The .MGM tab (128-slot map + slot-files list) and the Generate tab
// (export / import .STT / .MGM / MIDI, analyze, preview).
import SwiftUI
import MGMKit
import UniformTypeIdentifiers

/// One file-picker kind for the Generate tab. SwiftUI only supports a single
/// active `.fileImporter` per view, so the four import buttons share one,
/// selected by this enum.
private enum ImportKind {
    case grooveFile, midi, analyzeSong, targetSong
    var types: [UTType] {
        switch self {
        case .grooveFile: return [sttType, mgmType]
        case .midi: return [.midi]
        case .analyzeSong, .targetSong: return [.audio]
        }
    }
}

// MARK: - .MGM (slots)

struct MGMView: View {
    @EnvironmentObject var store: Store
    @State private var showLoader = false
    @State private var newSlot = 64

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FileHeader(name: $store.mgmName, ext: ".MGM", editable: $store.mgmEditable,
                           onLoad: { showLoader = true }, onSave: { store.saveMGM() })
                ProjectSettings()
                Divider()

                Text("Slots (0–127)").font(.headline)
                SlotsTimeline()

                Divider()
                Text("Slot files").font(.headline)
                ForEach(store.slotGroove.keys.sorted(), id: \.self) { pos in
                    HStack {
                        Text("\(pos)").font(.body.monospacedDigit()).frame(width: 44, alignment: .trailing)
                        Text("–").foregroundStyle(.secondary)
                        Text(store.slotName[pos] ?? "slot \(pos)")
                        Spacer()
                        if pos != 0 {
                            Button(role: .destructive) {
                                store.slotGroove[pos] = nil; store.slotName[pos] = nil
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("deleteSlot")
                            .disabled(!store.mgmEditable)
                        }
                    }
                }

                if !store.mgmEditable {
                    Text("Tap Edit to add or remove slots").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Add current .STT to slot").font(.caption)
                    IntBox(value: $newSlot)
                    Button { store.assignCurrentToSlot(newSlot) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("addToSlot")
                }
                .disabled(!store.mgmEditable)

                Text(store.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .fileImporter(isPresented: $showLoader, allowedContentTypes: [mgmType, sttType],
                      allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first {
                u.pathExtension.lowercased() == "stt" ? store.loadSTT(u) : store.loadMGM(u)
            }
        }
    }
}

// MARK: - Generate (export / import)

struct GenerateView: View {
    @EnvironmentObject var store: Store
    @State private var showImporter = false
    @State private var pendingKind: ImportKind = .grooveFile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Generate — Export / Import").font(.largeTitle.bold())

                Button { store.runDemo() } label: {
                    Label("Run built-in demo  (analyze song A → apply to song B)", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                .accessibilityIdentifier("runDemo")

                GroupBox("Export (to app Documents)") {
                    HStack {
                        Button { store.saveSTT() } label: { Label("Export .STT", systemImage: "square.and.arrow.up") }
                        Button { store.saveMGM() } label: { Label("Export .MGM", systemImage: "square.and.arrow.up.on.square") }
                    }.buttonStyle(.bordered)
                }

                GroupBox("Import") {
                    HStack {
                        Button { pendingKind = .grooveFile; showImporter = true } label: { Label(".STT / .MGM", systemImage: "square.and.arrow.down") }
                        Button { pendingKind = .midi; showImporter = true } label: { Label("MIDI file", systemImage: "pianokeys") }
                        Button { store.analyzeAmen() } label: { Label("Analyze Amen", systemImage: "gearshape.fill") }.tint(.green)
                    }.buttonStyle(.bordered)
                }

                GroupBox("Full song — analyze A → apply to B") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button { pendingKind = .analyzeSong; showImporter = true } label: { Label("Analyze song…", systemImage: "waveform") }
                            Button { pendingKind = .targetSong; showImporter = true } label: { Label("Apply to song…", systemImage: "music.note") }
                        }.buttonStyle(.bordered)
                        Text("Apply target: \(store.renderTargetName)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let r = store.lastReport {
                            Text(String(format: "Last analysis%@: %.0f bpm · swing %.0f%% · confidence %.0f%%  (%d beats, %d onsets)",
                                        store.lastEngine.isEmpty ? "" : " (\(store.lastEngine))",
                                        r.tempoBPM, store.swingPercent(r.swingRatio), r.confidence * 100,
                                        r.beatsDetected, r.onsetsUsed))
                                .font(.caption).foregroundStyle(r.confidence < 0.4 ? .orange : .secondary)
                        }
                        Text(store.useRemote
                             ? "Analyzed on the Spark (Demucs source separation) when reachable; falls back to on-device."
                             : "On-device analysis — best on drum-forward songs; dense/ballad mixes are rough.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                GroupBox("Preview") {
                    HStack {
                        Button { store.previewPlay() } label: { Label("Play current groove", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                        Button { store.playTarget() } label: { Label("Play target", systemImage: "play") }
                            .buttonStyle(.bordered)
                    }
                }

                Text(store.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: pendingKind.types,
                      allowsMultipleSelection: false) { res in
            guard case .success(let urls) = res, let u = urls.first else { return }
            switch pendingKind {
            case .grooveFile: u.pathExtension.lowercased() == "mgm" ? store.loadMGM(u) : store.loadSTT(u)
            case .midi:        store.importMIDI(u)
            case .analyzeSong: store.analyzeSong(u)
            case .targetSong:  store.setRenderTarget(u)
            }
        }
    }
}
