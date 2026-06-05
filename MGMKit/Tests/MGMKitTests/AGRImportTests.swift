// .agr (Ableton groove) import -> lossless ClipGroove, and the lossy per-slot view.
import XCTest
@testable import MGMKit

final class AGRImportTests: XCTestCase {
    // Real KAB1_137_AmenBreak_Cut_02.agr (gzipped Ableton groove), base64-encoded.
    private let agrBase64 = "H4sIAAAAAAAAA61Y3U/jOBB/Ln9FlPdN/RU7lgKrUmAPLQWu5TjpXpBp3JIjsSs37bL716+TNGkKSctK7UOUzNfPMx7PjBt+fUsTZy3NMtbq1IUecB2ppjqK1fzU/efh6kvgfj07CQfPicy0ckbif20eK3HiOqNYNQjcA08Y+K4zmb7IVAxfhJrLoV6p7NTFrjM0UmTanLqVuZt4LR2r5EHXGct1XFqZBlEkKJpSwdkzYJISTlg0Y3KGn7GAM4BEgCkH7tlJL/xmtF5L+9YLb0UqnUeRrOSp+31wDp8gZk+DVKpzi/v6NFxlTwC5Tr8QHibxIn/phYVG8doLR3EU5xznIU6tlQKiYNzo9DqqjIONkZrxGMsfbcx/hVmMhHm18dmQmjRnIqcVjnNuQ1N/9PdLewBD5O/oVKQauv8RO9x8fpNKGpHJ2p+ZSJayoTtcGSNVNsmEydrc2vAvVW0B7kREL+r15x9ddkpuwwpp8gqtsUxElidJl/adqliZWckm926VbQLXZv2vOIqk2r+6rUz7GsN+w9U/yr5cfqCUzqxzuvagGWGdaHOtIvlWR7ipeyNWavoy0lFbYDbcv1dCZfFyB6EplSfOJJ4rka2MrH3eodZJ2wvHMtWZFPbcturl/q/SPKt0a7wt/0IqncZqj0RuuW0jbKAPwIf91nW/I1fUS7WWiV5s3dtSGnv7XiqcTI1OEmlym/cWRBpbN7fJKGdZlwPhOJ6/dHHD/j7D5YbIRE7zfawNDuwGa7Nj0QMQQx9CBhkhHNmn7++ch+xF7mhgL8CQBZQQxBDmZLd8tOFaJ+d2/7rKxlikXayySk9kltnGso17Sd4W1i/NOtJvVQovbE7bPOgsXo9216Zx9nOQ5n2nLeBXNtr6RzMU5AN3UPg96FYvBc67BfLmN5WDtgrZFGi18M3EUR2kq/hNRh9OF2zubSHScsAgbUrlVq9VZtNLJPdWI6nE0E6y3mY6sSeh4u3UZCUWDzq301V1i5W0M/MNrd0Kr4yUv2RniynZjbrbZF4vJ1rNH2S60COxzLYl/n0uXC/zLti5oFtbU7bJ+F3+fDBi+tqoehWpWeaaOr3NyJATL9e2JTp1O247jBcrU5TjQoDm561K1ry+M9e5m822FGqz8np5qYps/xDpbmgfIk4ICBikKMAMInoAGRAPw4BAfJQF2BkSUEghCijFAGDKDsEjj9leSY+E7ltfOA4ChimimOH96DjwAupjxo/lPAsIItxWVQYDCskB533gMZ7/0FHgkQdQEGBuM4AiYL0K9sMT7jHCfbvkI8EjElDGGfAZBNw/lPOEeJBD7KPgSPDWF+bb+G+eBxPf5iokgMMjwQcQAsqpz33AoM/JAXgI7bljlPpHgueBjwjmCLHyech77hGfU3Kc4GPPBxyAgPuccYAAPwCf7z2gAT/SwcMeoxztDjMHzj32MaaU/yF82H/XAYrl2EZRj1XNnmvF3/eQLWU7pjZNhudCvZaT11ALs5Stw9FW6CpW7SL3Rs+NSMtLeKtEEcQotgODnUjsaPCf1umnBMuJ9ROi9hL2SaNWstNq2K/u5eWNvV9f2cN+RQ2bUwmubvnlJehXkQbtA2E+YNvxcpcJQc0eCxXptEN3/6zZfcUL68m6ZTIJJ3plpnKo7aj2lhW0ahY+Own7m/9Ozk5+A8S5qAu8EQAA"

    private func loadClip() throws -> ClipGroove {
        let data = try XCTUnwrap(Data(base64Encoded: agrBase64))
        return try AGRImport.parse(data)
    }

    func testAGRParsesLosslessly() throws {
        let clip = try loadClip()
        XCTAssertEqual(clip.timeSignature.numerator, 4)
        XCTAssertEqual(clip.timeSignature.denominator, 4)
        XCTAssertEqual(clip.lengthBeats, 4, accuracy: 1e-9)
        XCTAssertEqual(clip.notes.count, 12)
        XCTAssertEqual(clip.pitches, [36])                                  // single lane
        // exact values preserved (lossless capture of timing + velocity)
        XCTAssertEqual(clip.notes[0].startBeats, 0.0131511717449217455, accuracy: 1e-12)
        XCTAssertEqual(clip.notes[0].velocity, 127, accuracy: 1e-9)
        XCTAssertEqual(clip.notes[1].velocity, 104.318413, accuracy: 1e-5)
        XCTAssertEqual(clip.notes[11].startBeats, 3.7692864427239425, accuracy: 1e-12)
        XCTAssertEqual(clip.notes[11].velocity, 38.3533669, accuracy: 1e-5)
        XCTAssertTrue(clip.notes.allSatisfy { $0.pitch == 36 && abs($0.durationBeats - 0.0625) < 1e-9 })
    }

    func testProjectionToSlotGroove() throws {
        let clip = try loadClip()
        let g = clip.groove()
        XCTAssertEqual(g.unit, .bf)
        XCTAssertGreaterThanOrEqual(g.timing.count, 16)
        try g.validate()
        // the 12 notes separate cleanly at the auto grid -> 12 non-zero velocity slots
        XCTAssertEqual(g.velocity!.filter { $0 > 0 }.count, 12)
    }

    func testContainerKeepsWhatTheSlotViewDrops() throws {
        // Two simultaneous notes, different pitches (polyphony) — unrepresentable in
        // a single-lane slot groove, but the event list keeps both, losslessly.
        let clip = ClipGroove(timeSignature: TimeSignature(4, 4), lengthBeats: 4, notes: [
            NoteEvent(pitch: 36, startBeats: 1.0, durationBeats: 0.25, velocity: 100),
            NoteEvent(pitch: 42, startBeats: 1.0, durationBeats: 0.25, velocity: 60),
        ])
        XCTAssertEqual(clip.notes.count, 2)                 // both kept
        XCTAssertEqual(clip.pitches, [36, 42])
        // the slot view collapses them onto one slot, averaging velocity (80)
        let nonzero = clip.groove().velocity!.filter { $0 > 0 }
        XCTAssertEqual(nonzero.count, 1)
        XCTAssertEqual(nonzero.first!, 80, accuracy: 1e-9)
    }
}
