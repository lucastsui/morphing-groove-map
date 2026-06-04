// The .MGM tab (128-slot map + slot-files list) and the Generate tab
// (export / import .STT / .MGM / MIDI, analyze, preview).
import SwiftUI
import MGMKit
import UniformTypeIdentifiers

/// One file-picker kind for the Generate tab. SwiftUI only supports a single
/// active `.fileImporter` per view, so the four import buttons share one,
/// selected by this enum.
private enum ImportKind {
    case grooveFile, analyzeOrMIDI, targetSong
    var types: [UTType] {
        switch self {
        case .grooveFile: return [sttType, mgmType]
        case .analyzeOrMIDI: return [.audio, .midi]   // one button handles songs AND MIDI
        case .targetSong: return [.audio]
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
    @State private var dragStart: Double? = nil        // timing[i] captured when a bar drag begins
    @State private var editBars = false                // Analyzed-values strip: scroll (off) vs drag-edit (on)
    private let bfPerPoint = 350.0                      // bf per point of vertical drag (also the bar's visual scale)
    private let trackHeight: CGFloat = 90

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
                    }.buttonStyle(.bordered)
                }

                GroupBox("Full song — analyze A → apply to B") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button { pendingKind = .analyzeOrMIDI; showImporter = true } label: { Label("Analyze song / MIDI file", systemImage: "waveform") }
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

                GroupBox("Analyzed values") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(store.sttName).font(.headline)
                            Spacer()
                            Button(editBars ? "Done" : "Edit") { editBars.toggle() }
                                .buttonStyle(.bordered).font(.caption).tint(editBars ? .green : nil)
                            if !store.lastEngine.isEmpty {
                                Text(store.lastEngine).font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                        }
                        if let r = store.lastReport {
                            HStack(spacing: 18) {
                                valueStat("Tempo", "\(Int(r.tempoBPM)) bpm")
                                valueStat("Swing", String(format: "%.0f%%", store.swingPercent(r.swingRatio)))
                                valueStat("Ratio", String(format: "%.3f", r.swingRatio))
                                valueStat("Slots", "\(store.timing.count)")
                                valueStat("Conf", String(format: "%.0f%%", r.confidence * 100))
                            }
                        } else {
                            Text("Analyze a song (or load a groove) to populate these.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(editBars
                             ? "Drag a bar up/down to adjust its timing (+ = late, − = early), then Play current groove."
                             : "Scroll horizontally to see all \(store.timing.count) slots; tap Edit to adjust bars.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: true) {
                            HStack(alignment: .top, spacing: 6) {
                                ForEach(Array(0..<store.timing.count), id: \.self) { i in
                                    let t = store.timing[i]
                                    let h = min(trackHeight / 2 - 3, CGFloat(abs(t) / bfPerPoint))
                                    let cell = VStack(spacing: 3) {
                                        Text("\(i + 1)").font(.caption2.bold())
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(editBars ? 0.15 : 0.08))
                                            Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1)
                                            Rectangle()
                                                .fill(t < 0 ? Color.orange : (t > 0 ? Color.blue : Color.secondary))
                                                .frame(width: 12, height: max(2, h))
                                                .offset(y: t >= 0 ? -h / 2 : h / 2)
                                        }
                                        .frame(width: 26, height: trackHeight)
                                        Text(String(format: "%+.0f", t))
                                            .font(.system(size: 9).monospacedDigit())
                                            .lineLimit(1).minimumScaleFactor(0.5)
                                        if store.velocity.indices.contains(i) {
                                            Text("v\(Int(store.velocity[i]))")
                                                .font(.system(size: 9).monospacedDigit()).foregroundStyle(.green)
                                                .lineLimit(1).minimumScaleFactor(0.5)
                                        }
                                    }
                                    .frame(width: 40)
                                    // Only attach the drag gesture in Edit mode, so otherwise the
                                    // ScrollView pans freely (192 per-cell gestures would block it).
                                    if editBars {
                                        cell.contentShape(Rectangle()).gesture(
                                            DragGesture(minimumDistance: 2)
                                                .onChanged { g in
                                                    if dragStart == nil { dragStart = store.timing[i] }
                                                    let v = clampBF(dragStart! + Double(-g.translation.height) * bfPerPoint)
                                                    store.timing[i] = v.rounded()
                                                }
                                                .onEnded { _ in dragStart = nil }
                                        )
                                    } else {
                                        cell
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
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
            case .analyzeOrMIDI:
                let ext = u.pathExtension.lowercased()
                if ext == "mid" || ext == "midi" { store.importMIDI(u) } else { store.analyzeSong(u) }
            case .targetSong:  store.setRenderTarget(u)
            }
        }
    }

    private func valueStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
