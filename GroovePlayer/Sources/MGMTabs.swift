// The .MGM tab (128-slot map + slot-files list) and the Generate tab
// (export / import .STT / .MGM / MIDI, analyze, preview).
import SwiftUI
import MGMKit
import UniformTypeIdentifiers

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
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    Text("Add current .STT to slot").font(.caption)
                    IntBox(value: $newSlot)
                    Button { store.assignCurrentToSlot(newSlot) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderedProminent)
                }

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
    @State private var importGroove = false
    @State private var importMIDIFile = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Generate — Export / Import").font(.largeTitle.bold())

                GroupBox("Export (to app Documents)") {
                    HStack {
                        Button { store.saveSTT() } label: { Label("Export .STT", systemImage: "square.and.arrow.up") }
                        Button { store.saveMGM() } label: { Label("Export .MGM", systemImage: "square.and.arrow.up.on.square") }
                    }.buttonStyle(.bordered)
                }

                GroupBox("Import") {
                    HStack {
                        Button { importGroove = true } label: { Label(".STT / .MGM", systemImage: "square.and.arrow.down") }
                        Button { importMIDIFile = true } label: { Label("MIDI file", systemImage: "pianokeys") }
                        Button { store.analyzeAmen() } label: { Label("Analyze Amen", systemImage: "gearshape.fill") }.tint(.green)
                    }.buttonStyle(.bordered)
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
        .fileImporter(isPresented: $importGroove, allowedContentTypes: [sttType, mgmType],
                      allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first {
                u.pathExtension.lowercased() == "mgm" ? store.loadMGM(u) : store.loadSTT(u)
            }
        }
        .fileImporter(isPresented: $importMIDIFile, allowedContentTypes: [.midi],
                      allowsMultipleSelection: false) { res in
            if case .success(let urls) = res, let u = urls.first { store.importMIDI(u) }
        }
    }
}
