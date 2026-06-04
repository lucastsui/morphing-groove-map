// Unit tests for the app model (`Store`) — the non-UI logic: fbu/ms/note
// conversions, step buttons, lane resizing, grid validity, slot assignment, and
// file load/save / MIDI import round-trips. Hosted by the app so `@testable`
// can reach the internal types.
import AVFoundation
import XCTest
import MGMKit
@testable import GroovePlayer

@MainActor
final class StoreTests: XCTestCase {
    private func makeStore() -> Store { Store(audio: AudioEngine()) }

    func testFbuMsNoteConversions() {
        let s = makeStore()
        s.tempoBPM = 60; s.selectedBeat = 0
        s.selectedFBU = 3072
        XCTAssertEqual(s.selectedMs, 15.625, accuracy: 1e-6)
        XCTAssertEqual(s.selectedNoteLabel, "1/64 beat")
    }

    func testStepFunctions() {
        let s = makeStore()
        s.tempoBPM = 60; s.selectedBeat = 0; s.selectedFBU = 0
        s.stepFBU(128)
        XCTAssertEqual(s.selectedFBU, 128, accuracy: 1e-9)
        s.selectedFBU = 0; s.stepMs(10)                       // msToBF(10, 60) = 1966.08
        XCTAssertEqual(s.selectedFBU, 1966.08, accuracy: 0.01)
        s.selectedFBU = 0; s.noteUnitIndex = 6 /* 64th = 3072 */; s.stepNote(0.5)
        XCTAssertEqual(s.selectedFBU, 1536, accuracy: 1e-9)
        s.selectedFBU = 0; s.stepFBU(1e9)                     // clamps to ±1 beat
        XCTAssertEqual(s.selectedFBU, Double(bfMax))
    }

    func testResizeLanesPreservesAndPads() {
        let s = makeStore()
        s.beatResolution = 8; s.resizeLanes()
        XCTAssertEqual(s.timing.count, 8)
        s.beatResolution = 32; s.resizeLanes()
        XCTAssertEqual(s.timing.count, 32)
        XCTAssertEqual(s.velocity.count, 32)
        XCTAssertEqual(s.gate.count, 32)
    }

    func testGridValidity() {
        let s = makeStore()
        s.tsNumerator = 4; s.tsDenominator = 4; s.beatResolution = 16
        XCTAssertTrue(s.gridValid)
        s.beatResolution = 17
        XCTAssertFalse(s.gridValid)
        s.tsNumerator = 3; s.tsDenominator = 4; s.beatResolution = 12
        XCTAssertTrue(s.gridValid)
    }

    func testCurrentGrooveAndSlotAssign() {
        let s = makeStore()
        s.tsNumerator = 4; s.tsDenominator = 4; s.beatResolution = 16; s.resizeLanes()
        let g = s.currentGroove()
        XCTAssertEqual(g.unit, .bf)
        XCTAssertEqual(g.timing.count, 16)
        s.assignCurrentToSlot(50)
        XCTAssertNotNil(s.slotGroove[50])
        XCTAssertEqual(s.slotName[50], "\(s.sttName).STT")
    }

    func testSTTSaveLoadRoundTrip() {
        let s = makeStore()
        s.tsNumerator = 4; s.tsDenominator = 4; s.beatResolution = 16; s.resizeLanes()
        for i in 0..<16 where i % 2 == 1 { s.timing[i] = 3072 }
        s.sttName = "UnitTestGroove"
        s.saveSTT()
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnitTestGroove.stt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let expected = s.timing
        s.timing = [Double](repeating: 0, count: 16)
        s.loadSTT(url)
        XCTAssertEqual(s.timing, expected)
        try? FileManager.default.removeItem(at: url)
    }

    func testImportMIDIPopulatesTimingAndVelocity() {
        let s = makeStore()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ut_\(UUID().uuidString).mid")
        try? smfData().write(to: url)
        s.importMIDI(url)
        XCTAssertEqual(s.timing.count, 16)
        XCTAssertEqual(s.velocity.count, 16)
        try? FileManager.default.removeItem(at: url)
    }

    func testMIDIModeMaxVelocity() {
        XCTAssertEqual(MIDIMode.v1.maxVelocity, 127)
        XCTAssertEqual(MIDIMode.v2.maxVelocity, 65535)
    }

    private func smfData() -> Data {
        let track: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
                              0x00, 0x90, 0x3C, 0x64,
                              0x81, 0x70, 0x90, 0x3C, 0x50,
                              0x00, 0xFF, 0x2F, 0x00]
        let len = track.count
        var d: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
        d += [0x4D, 0x54, 0x72, 0x6B,
              UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        d += track
        return Data(d)
    }

    // MARK: full-song analyze A -> apply to B (end-to-end)

    func testAnalyzeSongAndApplyToTarget() throws {
        let s = makeStore()
        let songA = try writeWav(synthLoop(offbeat: 0.63))
        let songB = try writeWav(synthLoop(offbeat: 0.50))
        defer {
            try? FileManager.default.removeItem(at: songA)
            try? FileManager.default.removeItem(at: songB)
        }

        // Apply target = song B (synchronous).
        s.setRenderTarget(songB)
        XCTAssertTrue(s.targetIsSong)
        XCTAssertFalse(s.renderTargetName.isEmpty)

        // Analyze song A (async) → wait for the report. Force on-device so the test
        // is deterministic and doesn't depend on the Spark (unreachable in CI).
        s.useRemote = false
        s.analyzeSong(songA)
        waitUntil(timeout: 30) { s.lastReport != nil }
        XCTAssertNotNil(s.lastReport)
        XCTAssertEqual(s.timing.count, 16)
        XCTAssertGreaterThan(s.lastReport?.tempoBPM ?? 0, 0)

        // Apply (percussive re-time render) onto song B (async) → plays, no crash.
        s.previewPlay()
        waitUntil(timeout: 25) { s.status.contains("playing") }
        XCTAssertTrue(s.status.contains("playing"))
    }

    private func waitUntil(timeout: TimeInterval, _ cond: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func synthLoop(offbeat: Double, bpm: Double = 120, seconds: Double = 4,
                           sr: Double = 44100) -> [Float] {
        let n = Int(seconds * sr)
        var y = [Float](repeating: 0, count: n)
        let beat = 60.0 / bpm
        func burst(_ t: Double, _ amp: Float) {
            let st = Int(t * sr), len = Int(0.02 * sr)
            for k in 0..<len where st + k < n {
                let env = Float(pow(1 - Double(k) / Double(len), 2))
                y[st + k] += Float.random(in: -1...1) * env * amp
            }
        }
        var b = 0.0
        while b < seconds {
            burst(b, 0.9)
            let o = b + offbeat * beat
            if o < seconds { burst(o, 0.5) }
            b += beat
        }
        let pk = y.map { abs($0) }.max() ?? 1
        if pk > 0 { for i in 0..<n { y[i] /= pk } }
        return y
    }

    private func writeWav(_ samples: [Float], sr: Double = 44100) throws -> URL {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ut_\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer {
            buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
        return url
    }
}
