// iPad UI -- a native mirror of the web Groove Player: two scrollable groove
// lists on the left (Google dataset / My Swing Files), source-audio buttons, a
// swing dial, a play-with-groove button, and a bar chart of the offsets.
import SwiftUI
import MGMKit

struct ContentView: View {
    @StateObject private var audio = AudioEngine()
    @StateObject private var store: Store

    init() {
        let a = AudioEngine()
        _audio = StateObject(wrappedValue: a)
        _store = StateObject(wrappedValue: Store(audio: a))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
    }

    // MARK: sidebar (the two lists)

    private var sidebar: some View {
        List {
            Section("Google Groove Dataset") {
                ForEach(store.google) { item in row(item) }
            }
            Section("My Swing Files") {
                if store.user.isEmpty {
                    Text("Analyze the Amen to create one.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(store.user) { item in row(item) }
            }
        }
        .navigationTitle("Grooves")
    }

    private func row(_ item: GrooveItem) -> some View {
        Button { store.selectedID = item.id } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.callout)
                    Text(item.bpm > 0 ? "\(item.style) · \(item.bpm) bpm" : item.style)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if store.selectedID == item.id {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: detail (controls)

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Groove Player").font(.largeTitle.bold())
                Text("Stamp a groove onto the straight target and play it.")
                    .foregroundStyle(.secondary)

                GroupBox("Source audio") {
                    HStack {
                        Button { store.playAmen() } label: { Label("Play Amen", systemImage: "play.fill") }
                        Button { store.playTarget() } label: { Label("Play target", systemImage: "play") }
                        Button { store.analyzeAmen() } label: { Label("Analyze Amen → swing", systemImage: "gearshape.fill") }
                            .tint(.green)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }

                GroupBox("Selected: \(store.selected?.name ?? "— none —")") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Swing amount").foregroundStyle(.secondary)
                            Slider(value: $store.dial, in: 0...127)
                            Text("\(Int(store.dial))").monospacedDigit().frame(width: 38)
                        }
                        Button { store.playWithGroove() } label: {
                            Label("Play with groove", systemImage: "waveform")
                        }.buttonStyle(.borderedProminent).controlSize(.large)

                        BarChart(timing: store.selected?.groove.timing ?? [])
                            .frame(height: 90)
                    }
                }

                Text(store.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }
}

/// Simple offset bar chart: blue = late, orange = early.
struct BarChart: View {
    let timing: [Double]
    var body: some View {
        GeometryReader { geo in
            let maxV = max(30, timing.map { abs($0) }.max() ?? 30)
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(timing.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(v < 0 ? Color.orange : Color.blue)
                        .frame(height: 4 + CGFloat(abs(v) / maxV) * (geo.size.height - 8))
                        .opacity(0.85)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
