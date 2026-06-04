// Gap-fill + robustness tests for MGMKit: model edges, .stt/.mgm I/O error
// paths + disk round-trips, the 128-slot document rules, fold/offset/render
// correctness, the groove library, and MIDI parser detail + malformed/fuzz
// safety. Runs under `swift test` (with Xcode's toolchain for XCTest).
import Foundation
import XCTest
@testable import MGMKit

private func bfGroove(_ n: Int = 16, ts: TimeSignature = TimeSignature(4, 4),
                      vel: Bool = false, gate: Bool = false) -> Groove {
    let count = slotCount(ts, subdivision: n)
    return Groove(timeSignature: ts, subdivision: n, unit: .bf,
                  timing: [Double](repeating: 0, count: count),
                  velocity: vel ? [Double](repeating: 100, count: count) : nil,
                  gate: gate ? [Double](repeating: 0, count: count) : nil)
}

// MARK: - Model edges

final class ModelEdgeTests: XCTestCase {
    func testBFRangeAndClamp() {
        XCTAssertTrue(bfInRange(Double(bfMax)))
        XCTAssertTrue(bfInRange(Double(-bfMax)))
        XCTAssertFalse(bfInRange(Double(bfMax) + 1))
        XCTAssertFalse(bfInRange(Double(-bfMax) - 1))
        XCTAssertEqual(clampBF(300_000), Double(bfMax))
        XCTAssertEqual(clampBF(-300_000), Double(-bfMax))
        XCTAssertEqual(clampBF(1000), 1000)
    }

    func testIsCompatible() {
        let a = bfGroove(16)
        XCTAssertTrue(a.isCompatible(with: bfGroove(16)))
        XCTAssertFalse(a.isCompatible(with: bfGroove(16, ts: TimeSignature(3, 4)))) // diff TS + length
        XCTAssertFalse(a.isCompatible(with: bfGroove(8)))                            // diff subdivision
        let ms = Groove(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .ms,
                        timing: [Double](repeating: 0, count: 16))
        XCTAssertFalse(a.isCompatible(with: ms))                                     // diff unit
    }

    func testGrooveCodableRoundTrip() throws {
        let g = bfGroove(16, vel: true, gate: true)
        let data = try JSONEncoder().encode(g)
        let back = try JSONDecoder().decode(Groove.self, from: data)
        XCTAssertEqual(back, g)
    }

    func testFineAndTripletResolutions() {
        XCTAssertEqual(slotCount(TimeSignature(4, 4), subdivision: 256), 256) // 64ths
        XCTAssertEqual(slicesPerBeat(TimeSignature(4, 4), subdivision: 256), 64)
        XCTAssertEqual(slotCount(TimeSignature(3, 4), subdivision: 512), 384) // ¾ fine grid
        XCTAssertEqual(slotCount(TimeSignature(4, 4), subdivision: 24), 24)   // 16th triplets
    }
}

// MARK: - MGMDocument rules

final class DocumentEdgeTests: XCTestCase {
    func testSlotRange() throws {
        var doc = try MGMDocument(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf)
        XCTAssertThrowsError(try doc.setSlot(-1, bfGroove(16)))
        XCTAssertThrowsError(try doc.setSlot(128, bfGroove(16)))
        XCTAssertNoThrow(try doc.setSlot(0, bfGroove(16)))
        XCTAssertNoThrow(try doc.setSlot(127, bfGroove(16)))
    }

    func testLanePresenceMustAgree() throws {
        var doc = try MGMDocument(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf)
        try doc.setSlot(127, bfGroove(16, vel: true))
        XCTAssertThrowsError(try doc.setSlot(64, bfGroove(16, vel: false)))
    }

    func testEmptyEndpointsDefaultToNoSwingWithMatchingLanes() throws {
        var doc = try MGMDocument(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf)
        try doc.setSlot(127, bfGroove(16, vel: true))
        let zero = doc.resolve(0)
        XCTAssertTrue(zero.timing.allSatisfy { $0 == 0 })
        XCTAssertNotNil(zero.velocity)                      // matches populated-slot lane presence
        XCTAssertTrue(zero.velocity?.allSatisfy { $0 == 0 } ?? false)
    }

    func testClearAndPopulatedOrder() throws {
        var doc = try MGMDocument(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf)
        try doc.setSlot(127, bfGroove(16)); try doc.setSlot(10, bfGroove(16)); try doc.setSlot(64, bfGroove(16))
        XCTAssertEqual(doc.populatedPositions, [10, 64, 127])
        doc.clearSlot(64)
        XCTAssertEqual(doc.populatedPositions, [10, 127])
    }
}

// MARK: - .stt / .mgm I/O

final class MGMIOTests: XCTestCase {
    func testSTTDiskRoundTrip() throws {
        let g = bfGroove(16, vel: true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt_\(UUID().uuidString).stt")
        defer { try? FileManager.default.removeItem(at: url) }
        try MGMIO.saveSTT(g, to: url)
        let back = try MGMIO.loadSTT(from: url)
        XCTAssertEqual(back.timing, g.timing)
        XCTAssertEqual(back.velocity, g.velocity)
        XCTAssertEqual(back.unit, .bf)
    }

    func testMGMDiskRoundTrip() throws {
        var doc = try MGMDocument(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf)
        let swung = Groove(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .bf,
                           timing: (0..<16).map { $0 % 2 == 1 ? 3072 : 0 })
        try doc.setSlot(127, swung)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt_\(UUID().uuidString).mgm")
        defer { try? FileManager.default.removeItem(at: url) }
        try MGMIO.saveMGM(doc, to: url)
        let back = try MGMIO.loadMGM(from: url)
        XCTAssertEqual(back.populatedPositions, [127])
        XCTAssertEqual(back.resolve(127).timing, swung.timing)
    }

    func testDecodeErrors() {
        XCTAssertThrowsError(try MGMIO.decodeSTT(Data("{}".utf8)))                       // missing fields
        let zeros = "[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]"
        let wrongFormat = Data(#"{"format":"XXX","version":1,"timeSignature":"4/4","beats":4,"subdivision":16,"unit":"bf","timing":\#(zeros)}"#.utf8)
        XCTAssertThrowsError(try MGMIO.decodeSTT(wrongFormat))                            // bad format tag
        let badTS = Data(#"{"format":"STT","version":1,"timeSignature":"oops","beats":4,"subdivision":16,"unit":"bf","timing":\#(zeros)}"#.utf8)
        XCTAssertThrowsError(try MGMIO.decodeSTT(badTS))                                  // unparseable TS
    }
}

// MARK: - Library

final class LibraryTests: XCTestCase {
    func testDecodeAndConvert() throws {
        let json = #"[{"name":"Test","style":"funk","bpm":120,"subdivision":16,"time_signature":"4/4","unit":"ms","timing":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]}]"#
        let lib = try Library.load(from: Data(json.utf8))
        XCTAssertEqual(lib.count, 1)
        let g = lib[0].groove()
        XCTAssertEqual(g.subdivision, 16)
        XCTAssertEqual(g.unit, .ms)
        XCTAssertEqual(g.timing.count, 16)
        XCTAssertEqual(g.timeSignature, TimeSignature(4, 4))
        XCTAssertTrue(lib[0].straightCounterpart().timing.allSatisfy { $0 == 0 })
    }
}

// MARK: - fold / offsets / render

final class FoldOffsetRenderTests: XCTestCase {
    func testFoldPerSlotAveragesAndWraps() {
        let out = Onset.foldPerSlot(times: [0.0, 0.25, 2.0], values: [100, 80, 60], bpm: 120,
                                    timeSignature: TimeSignature(4, 4), subdivision: 16)
        XCTAssertEqual(out[0], 80, accuracy: 1e-9)  // (100 + 60)/2, second hit wraps to bar 0
        XCTAssertEqual(out[2], 80, accuracy: 1e-9)
        XCTAssertEqual(out[1], 0, accuracy: 1e-9)
    }

    func testOffsetsInThreeUnits() {
        let ms = Onset.offsets(fromOnsetTimes: [0.01], bpm: 120, timeSignature: TimeSignature(4, 4),
                               subdivision: 16, unit: .ms)
        XCTAssertEqual(ms[0], 10, accuracy: 1e-6)
        let samp = Onset.offsets(fromOnsetTimes: [0.01], bpm: 120, timeSignature: TimeSignature(4, 4),
                                 subdivision: 16, unit: .samples, sampleRate: 48000)
        XCTAssertEqual(samp[0], 480, accuracy: 1e-6)
        let bf = Onset.offsets(fromOnsetTimes: [0.01], bpm: 120, timeSignature: TimeSignature(4, 4),
                               subdivision: 16, unit: .bf)
        XCTAssertEqual(bf[0], 3932.16, accuracy: 0.01)
    }

    func testVelocitiesEmpty() {
        let v = Onset.velocities([], sampleRate: 48000, onsetTimes: [], bpm: 120,
                                 timeSignature: TimeSignature(4, 4), subdivision: 16)
        XCTAssertEqual(v.count, 16)
        XCTAssertTrue(v.allSatisfy { $0 == 0 })
    }

    func testRenderPaddingAndGuards() {
        // Output length is deterministic: y.count + maxShift + xfade + 1.
        let y = [Float](repeating: 0, count: 2000)
        let g = Groove(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .samples,
                       timing: [Double](repeating: 1000, count: 16))
        let out = Render.grooved(target: y, sampleRate: 48000, groove: g)  // xfade default 64
        XCTAssertEqual(out.count, 2000 + 1000 + 64 + 1)
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max() ?? 0, 1.0001)
        // Guards: empty timing / empty audio return the input unchanged.
        let noTiming = Groove(timeSignature: TimeSignature(4, 4), subdivision: 16, unit: .ms, timing: [])
        XCTAssertEqual(Render.grooved(target: y, sampleRate: 48000, groove: noTiming).count, y.count)
        XCTAssertTrue(Render.grooved(target: [], sampleRate: 48000, groove: g).isEmpty)
    }
}

// MARK: - MIDI parser detail + fuzz

/// Build a minimal format-0 SMF from raw track-event bytes (480 tpq).
private func smf(_ track: [UInt8]) -> Data {
    let len = track.count
    var d: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
    d += [0x4D, 0x54, 0x72, 0x6B,
          UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
    d += track
    return Data(d)
}

final class MIDIDetailTests: XCTestCase {
    func testNoteOffAndZeroVelocityIgnored() throws {
        let track: [UInt8] = [
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,  // tempo 120
            0x00, 0x90, 0x3C, 0x64,                     // note on vel 100   (kept)
            0x00, 0x90, 0x3C, 0x00,                     // note on vel 0     (ignored)
            0x00, 0x80, 0x3C, 0x40,                     // note off          (ignored)
            0x81, 0x70, 0x90, 0x40, 0x50,               // dt240 note on 80  (kept)
            0x00, 0xFF, 0x2F, 0x00,                     // end of track
        ]
        let (notes, bpm) = try MIDIImport.parse(smf(track))
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(bpm, 120, accuracy: 1e-6)
        XCTAssertEqual(notes.map(\.velocity), [100, 80])
        XCTAssertEqual(notes[1].timeSeconds, 0.25, accuracy: 1e-6)
    }

    func testRunningStatus() throws {
        // Two note-ons sharing one 0x90 status byte (running status).
        let track: [UInt8] = [
            0x00, 0x90, 0x3C, 0x64,   // note on (status 0x90)
            0x10, 0x3E, 0x55,         // running status: note on D vel 0x55
            0x00, 0xFF, 0x2F, 0x00,
        ]
        let (notes, _) = try MIDIImport.parse(smf(track))
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.map(\.velocity), [100, 85])
    }
}

final class MIDIFuzzTests: XCTestCase {
    func testEmptyAndGarbageThrow() {
        XCTAssertThrowsError(try MIDIImport.parse(Data()))
        XCTAssertThrowsError(try MIDIImport.parse(Data([0x00, 0x01, 0x02, 0x03, 0x04])))
    }

    func testTruncatedAndRandomDoNotCrash() {
        let valid = smf([0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
                         0x00, 0x90, 0x3C, 0x64, 0x00, 0xFF, 0x2F, 0x00])
        for cut in 1...min(12, valid.count - 1) {
            _ = try? MIDIImport.parse(valid.prefix(valid.count - cut))   // must not crash
        }
        var rng = SplitMix64(seed: 99)
        for _ in 0..<40 {
            var bytes: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
            bytes += Array("MTrk".utf8) + [0, 0, 0, 32]
            for _ in 0..<32 { bytes.append(UInt8(rng.next() & 0xFF)) }   // random track body
            _ = try? MIDIImport.parse(Data(bytes))                       // must not crash
        }
    }
}
