// Top-level 5-tab shell + the shared building blocks used across tabs:
// typed numeric boxes, the file-management header (Load/Edit/Save/Rename),
// project settings, step-button rows, and the beat / slots timelines.
import SwiftUI
import MGMKit

struct ContentView: View {
    @StateObject private var store = Store(audio: AudioEngine())
    @State private var demoStarted = false

    var body: some View {
        TabView(selection: $store.tab) {
            WelcomeView().tabItem { Label("Welcome", systemImage: "house") }.tag(0)
            STTFullView().tabItem { Label(".STT full", systemImage: "list.bullet.rectangle") }.tag(1)
            STTBeatsView().tabItem { Label(".STT beats", systemImage: "slider.horizontal.3") }.tag(2)
            MGMView().tabItem { Label(".MGM", systemImage: "square.grid.2x2") }.tag(3)
            GenerateView().tabItem { Label("Generate", systemImage: "square.and.arrow.up.on.square") }.tag(4)
        }
        .environmentObject(store)
        .onAppear {
            if !demoStarted, ProcessInfo.processInfo.environment["DEMO"] == "1" {
                demoStarted = true
                store.runDemo()
            }
            if !demoStarted, ProcessInfo.processInfo.environment["SELFTEST"] == "1" {
                demoStarted = true
                store.runRemoteSelfTest()
            }
        }
    }
}

// MARK: - Typed numeric boxes

struct IntBox: View {
    @Binding var value: Int
    var width: CGFloat = 56
    var id: String? = nil
    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .accessibilityIdentifier(id ?? "")
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
    }
}

struct DoubleBox: View {
    @Binding var value: Double
    var width: CGFloat = 84
    var id: String? = nil
    var body: some View {
        TextField("", value: $value, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .accessibilityIdentifier(id ?? "")
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }
}

// MARK: - File-management header (shared by the editing tabs)

struct FileHeader: View {
    @Binding var name: String
    let ext: String
    @Binding var editable: Bool
    var showEdit: Bool = true
    var onLoad: () -> Void
    var onSave: () -> Void
    @State private var renaming = false

    var body: some View {
        HStack(spacing: 10) {
            if renaming {
                TextField("name", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Text(ext).foregroundStyle(.secondary)
            } else {
                Text(name + ext).font(.title3.bold())
            }
            Spacer()
            Button("Load", action: onLoad).buttonStyle(.bordered)
            if showEdit {
                Button(editable ? "Editing" : "Edit") { editable.toggle() }
                    .buttonStyle(.bordered).tint(editable ? .green : nil)
            }
            Button("Save", action: onSave).buttonStyle(.bordered)
            Button(renaming ? "Done" : "Rename") { renaming.toggle() }.buttonStyle(.bordered)
        }
    }
}

// MARK: - Project settings (TS / tempo / beat resolution)

struct ProjectSettings: View {
    @EnvironmentObject var store: Store
    var showResolution = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Time Signature").frame(width: 130, alignment: .leading)
                IntBox(value: $store.tsNumerator, id: "tsNum"); Text("/")
                IntBox(value: $store.tsDenominator, id: "tsDen")
            }
            HStack {
                Text("Tempo").frame(width: 130, alignment: .leading)
                DoubleBox(value: $store.tempoBPM, id: "tempo"); Text("BPM")
            }
            if showResolution {
                HStack {
                    Text("Beat Resolution").frame(width: 130, alignment: .leading)
                    IntBox(value: $store.beatResolution, id: "beatRes"); Text("Beats")
                }
            }
            if !store.gridValid {
                Text("⚠︎ time signature and beat resolution don't form a valid grid")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onChange(of: store.beatResolution) { _ in store.resizeLanes() }
    }
}

// MARK: - Step-button row

struct StepRow: View {
    let label: String
    let steps: [(String, Double)]
    let action: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 44, alignment: .leading)
            ForEach(steps.indices, id: \.self) { i in
                Button(steps[i].0) { action(steps[i].1) }
                    .buttonStyle(.bordered)
                    .font(.caption.monospacedDigit())
                    .disabled(steps[i].1 == 0)
            }
        }
    }
}

// MARK: - Charts

/// "Select Current Beat" timeline: one mark per slot, grouped by the time
/// signature, the selected slot highlighted; tap to select.
struct BeatTimeline: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let n = max(1, store.beatResolution)
        let groups = max(1, store.tsNumerator)
        let perGroup = max(1, n / groups)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(0..<n), id: \.self) { i in
                    let selected = i == store.selectedBeat
                    let groupStart = i % perGroup == 0
                    Button { store.selectedBeat = i } label: {
                        VStack(spacing: 2) {
                            if selected { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.tint) }
                            Rectangle()
                                .fill(selected ? Color.accentColor : Color.secondary)
                                .frame(width: selected ? 4 : 2, height: groupStart ? 36 : 22)
                            Text(groupStart ? "\(i / perGroup + 1)" : " ")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("beat-\(i)")
                }
            }.padding(.vertical, 4)
        }
    }
}

/// "Slots" timeline 0–127: filled slots highlighted.
struct SlotsTimeline: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Spread the 128 slots across the full width (equal share each) so the
            // filled bars line up with the 0–127 tick labels below.
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<128, id: \.self) { s in
                    let filled = store.slotGroove[s] != nil
                    Rectangle()
                        .fill(filled ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: filled ? 4 : 2, height: filled ? 42 : 16)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack {
                ForEach([0, 15, 31, 47, 63, 79, 95, 111, 127], id: \.self) { v in
                    Text("\(v)").font(.caption2).foregroundStyle(.secondary)
                    if v != 127 { Spacer() }
                }
            }
        }
    }
}
