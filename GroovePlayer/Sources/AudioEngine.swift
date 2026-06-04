// AVFoundation glue: load bundled WAVs into Float buffers, play Float buffers,
// and run the MGMKit render/analyze on them. This is the only platform layer;
// all the DSP lives in MGMKit (which is unit-tested without Xcode).
import AVFoundation
import Foundation
import MGMKit

@MainActor
final class AudioEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var sampleRate: Double = 48000

    @Published var nowPlaying: String = ""

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        try? engine.start()
    }

    // MARK: load / cache

    /// Load a bundled mono WAV into [Float] + its sample rate.
    func loadMono(_ resource: String) -> (samples: [Float], sr: Int)? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              (try? file.read(into: buf)) != nil,
              let ch = buf.floatChannelData else { return nil }
        let n = Int(buf.frameLength)
        // average channels down to mono
        var mono = [Float](repeating: 0, count: n)
        let chans = Int(fmt.channelCount)
        for c in 0..<chans {
            let p = ch[c]
            for i in 0..<n { mono[i] += p[i] / Float(chans) }
        }
        return (mono, Int(fmt.sampleRate))
    }

    // MARK: playback

    /// Play a mono Float buffer at `sr`, labeled for the now-playing line.
    func play(_ samples: [Float], sr: Int, label: String) {
        guard !samples.isEmpty,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: Double(sr), channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: samples.count) }
        }
        // Reconnect the player to the mixer with THIS buffer's (mono) format.
        // The mixer upmixes mono->stereo for output; without matching the
        // player's output format to the buffer, scheduleBuffer asserts on a
        // channel-count mismatch and crashes.
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buf, at: nil, options: .interrupts)
        player.play()
        nowPlaying = label
    }

    func stop() { player.stop(); nowPlaying = "" }
}
