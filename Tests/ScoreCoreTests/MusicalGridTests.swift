import Testing
@testable import ScoreCore

@Suite("Musical grid")
struct MusicalGridTests {
    @Test
    func commonTempoHasExactBeatBarAndPhraseFrames() throws {
        let grid = TestFixtures.grid()

        #expect(try grid.frame(atBeat: 1) == 24_000)
        #expect(try grid.frame(atBar: 1) == TestFixtures.barFrames)
        #expect(try grid.frame(atBar: 4) == 384_000)
        #expect(try grid.nextBoundary(afterFrame: 1, boundary: .phrase) == 384_000)
    }

    @Test
    func rationalCalculationLandsExactlyAfterOneHourWithoutDrift() throws {
        let sampleRate: Int64 = 48_000
        let grid = try MusicalGrid(
            sampleRate: sampleRate,
            beatsPerMinute: Rational(numerator: 123, denominator: 1),
            beatsPerBar: 4,
            barsPerPhrase: 4,
            exactLoopFrames: 172_800_000
        )
        let beatsInOneHour: Int64 = 123 * 60

        #expect(try grid.frame(atBeat: beatsInOneHour) == sampleRate * 60 * 60)

        var previous: Int64 = 0
        for beat in 1...beatsInOneHour {
            let current = try grid.frame(atBeat: beat)
            #expect(current > previous)
            previous = current
        }
        #expect(previous == 172_800_000)
    }

    @Test
    func nextBoundaryIsStrictUnlessCurrentBoundaryIsIncluded() throws {
        let grid = TestFixtures.grid()

        #expect(
            try grid.nextBoundary(afterFrame: TestFixtures.barFrames, boundary: .bar)
                == TestFixtures.barFrames * 2
        )
        #expect(
            try grid.nextBoundary(
                afterFrame: TestFixtures.barFrames,
                boundary: .bar,
                includeCurrent: true
            ) == TestFixtures.barFrames
        )
        #expect(
            try grid.previousBoundary(
                atOrBeforeFrame: TestFixtures.barFrames + 42,
                boundary: .bar
            ) == TestFixtures.barFrames
        )
    }

    @Test
    func negativeFramesAndIndexesAreRejected() throws {
        let grid = TestFixtures.grid()
        #expect(throws: ScoreCoreError.self) {
            try grid.frame(atBeat: -1)
        }
        #expect(throws: ScoreCoreError.self) {
            try grid.nextBoundary(afterFrame: -1, boundary: .bar)
        }
    }

    @Test
    func previousBoundaryRecognizesAFrameRoundedDownFromFractionalTime() throws {
        let grid = try MusicalGrid(
            sampleRate: 10,
            beatsPerMinute: Rational(numerator: 64, denominator: 1),
            beatsPerBar: 1,
            barsPerPhrase: 4,
            exactLoopFrames: 90
        )

        #expect(try grid.frame(atBeat: 1) == 9)
        #expect(try grid.previousBoundary(atOrBeforeFrame: 9, boundary: .bar) == 9)
    }
}
