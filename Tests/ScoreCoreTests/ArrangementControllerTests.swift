import Foundation
import Testing
@testable import ScoreCore

@Suite("Adaptive arrangement")
struct ArrangementControllerTests {
    @Test
    func cadenceNeedsHysteresisStabilizationAndDwellBeforeQueueing() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .steady
        )

        for second in 0...11 {
            if second > 0 {
                clock.advance(by: 1)
            }
            let frame = Int64(second) * TestFixtures.sampleRate
            try controller.observe(
                TestFixtures.observation(cadence: 140, at: clock.now),
                atTransportFrame: frame
            )
            #expect(controller.state.queuedTransition == nil)
        }

        clock.advance(by: 1)
        let state = try controller.observe(
            TestFixtures.observation(cadence: 140, at: clock.now),
            atTransportFrame: 12 * TestFixtures.sampleRate
        )
        let transition = try #require(state.queuedTransition)

        #expect(transition.target == .energy(.brisk))
        #expect(transition.reason == .adaptiveCadence)
        #expect(transition.boundary == .bar)
        #expect(transition.executeAtFrame > state.transportFrame)
        #expect(state.currentEnergy == .steady)

        let applied = try controller.advance(toTransportFrame: transition.executeAtFrame)
        #expect(applied.currentEnergy == .brisk)
        #expect(applied.queuedTransition?.target == .section("lift"))
        #expect(applied.queuedTransition?.reason == .authoredSectionChange)
    }

    @Test
    func sixStepHysteresisPreventsBoundaryFlutter() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .steady
        )

        for cadence in [105.0, 126.0, 120.0, 130.0, 95.0] {
            try controller.observe(
                TestFixtures.observation(cadence: cadence, at: clock.now),
                atTransportFrame: 0
            )
            clock.advance(by: 1)
        }

        #expect(controller.state.currentEnergy == .steady)
        #expect(controller.state.queuedTransition == nil)
    }

    @Test
    func fiveSecondStabilizationIsMeasuredBeforeQueueing() throws {
        let clock = TestClock()
        let policy = AdaptationPolicy(minimumDwellDuration: 1)
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            policy: policy,
            initialEnergy: .steady
        )

        for second in 0...4 {
            if second > 0 {
                clock.advance(by: 1)
            }
            try controller.observe(
                TestFixtures.observation(cadence: 140, at: clock.now),
                atTransportFrame: Int64(second) * TestFixtures.sampleRate
            )
            #expect(controller.state.queuedTransition == nil)
        }

        clock.advance(by: 1)
        try controller.observe(
            TestFixtures.observation(cadence: 140, at: clock.now),
            atTransportFrame: 5 * TestFixtures.sampleRate
        )
        #expect(controller.state.queuedTransition?.target == .energy(.brisk))
    }

    @Test
    func cadenceAtFiveAboveBriskThresholdRemainsSteadyBecauseMarginIsSix() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .steady
        )

        for second in 0...15 {
            if second > 0 {
                clock.advance(by: 1)
            }
            try controller.observe(
                TestFixtures.observation(cadence: 130, at: clock.now),
                atTransportFrame: Int64(second) * TestFixtures.sampleRate
            )
        }

        #expect(controller.state.currentEnergy == .steady)
        #expect(controller.state.queuedTransition == nil)
    }

    @Test
    func stationaryInputCanSettleIntoStill() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .easy
        )

        for second in 0...12 {
            if second > 0 {
                clock.advance(by: 1)
            }
            try controller.observe(
                TestFixtures.observation(
                    cadence: 0,
                    activity: .stationary,
                    at: clock.now
                ),
                atTransportFrame: Int64(second) * TestFixtures.sampleRate
            )
        }

        #expect(controller.state.queuedTransition?.target == .energy(.still))
    }

    @Test
    func sparseStationaryObservationsRetainTheirCandidateAcrossTicks() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .steady
        )
        try controller.observe(
            TestFixtures.observation(cadence: 112, at: clock.now),
            atTransportFrame: 0
        )

        for second in [12, 15, 18] {
            clock.now = Date(timeIntervalSince1970: 1_000 + TimeInterval(second))
            try controller.observe(
                TestFixtures.observation(
                    cadence: 0,
                    activity: .stationary,
                    at: clock.now
                ),
                atTransportFrame: Int64(second) * TestFixtures.sampleRate
            )
        }

        #expect(controller.state.queuedTransition?.target == .energy(.still))
    }

    @Test
    func inputBecomesStaleOnlyAfterTenSecondsAndHoldsEnergy() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .steady
        )
        try controller.observe(
            TestFixtures.observation(cadence: 110, at: clock.now),
            atTransportFrame: 0
        )

        clock.advance(by: 10)
        var state = try controller.advance(toTransportFrame: 10 * TestFixtures.sampleRate)
        #expect(!state.inputIsStale)
        #expect(state.currentEnergy == .steady)

        clock.advance(by: 0.001)
        state = try controller.advance(toTransportFrame: 10 * TestFixtures.sampleRate + 48)
        #expect(state.inputIsStale)
        #expect(state.currentEnergy == .steady)
        #expect(state.queuedTransition == nil)
    }

    @Test
    func explicitlyStaleObservationDoesNotDriveArrangement() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock
        )

        let state = try controller.observe(
            TestFixtures.observation(
                cadence: 160,
                at: clock.now,
                freshness: .stale
            ),
            atTransportFrame: 0
        )

        #expect(state.inputIsStale)
        #expect(state.queuedTransition == nil)
    }

    @Test
    func deniedMotionSelectsManualSteadyAtNextBoundary() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .brisk
        )

        var state = try controller.motionPermissionDenied(atTransportFrame: 1)
        let transition = try #require(state.queuedTransition)
        #expect(state.adaptationMode == .manual)
        #expect(state.inputIsStale)
        #expect(state.currentEnergy == .brisk)
        #expect(state.requestedEnergy == .steady)
        #expect(transition.reason == .motionPermissionDenied)

        state = try controller.advance(toTransportFrame: transition.executeAtFrame)
        #expect(state.currentEnergy == .steady)
    }

    @Test
    func manualEnergyWaitsForBarAndRejectsStillAndSurge() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .steady
        )

        let queued = try controller.selectManualEnergy(.easy, atTransportFrame: 1)
        let transition = try #require(queued.queuedTransition)
        #expect(queued.adaptationMode == .manual)
        #expect(queued.currentEnergy == .steady)
        #expect(transition.executeAtFrame == TestFixtures.barFrames)

        let applied = try controller.advance(toTransportFrame: transition.executeAtFrame)
        #expect(applied.currentEnergy == .easy)
        #expect(throws: ArrangementControllerError.self) {
            try controller.selectManualEnergy(.still, atTransportFrame: transition.executeAtFrame)
        }
        #expect(throws: ArrangementControllerError.self) {
            try controller.selectManualEnergy(.surge, atTransportFrame: transition.executeAtFrame)
        }
    }

    @Test
    func runtimeCanAdoptOnlyALaterMatchingBoundary() throws {
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: TestClock(),
            initialEnergy: .steady
        )
        let queuedState = try controller.selectManualEnergy(.easy, atTransportFrame: 1)
        let expected = try #require(queuedState.queuedTransition)
        let accepted = QueuedTransition(
            target: expected.target,
            boundary: expected.boundary,
            executeAtFrame: TestFixtures.barFrames * 2,
            reason: expected.reason
        )

        let adopted = try controller.adoptAcceptedTransition(
            expected: expected,
            accepted: accepted
        )
        #expect(adopted.queuedTransition == accepted)
        #expect(
            try controller.advance(toTransportFrame: expected.executeAtFrame).currentEnergy
                == .steady
        )
        #expect(
            try controller.advance(toTransportFrame: accepted.executeAtFrame).currentEnergy
                == .easy
        )
    }

    @Test
    func runtimeRejectsAcceptedTransitionThatIsOffGrid() throws {
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: TestClock(),
            initialEnergy: .steady
        )
        let state = try controller.selectManualEnergy(.easy, atTransportFrame: 1)
        let expected = try #require(state.queuedTransition)
        var invalid = expected
        invalid.executeAtFrame += 1

        #expect(throws: ScoreCoreError.invalidAcceptedTransition) {
            try controller.adoptAcceptedTransition(
                expected: expected,
                accepted: invalid
            )
        }
    }

    @Test
    func confidentRunningNeedsFiveSecondsThenCreatesCappedSurge() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialEnergy: .easy
        )

        var state = controller.state
        for second in 0...5 {
            if second > 0 {
                clock.advance(by: 1)
            }
            state = try controller.observe(
                TestFixtures.observation(
                    cadence: 150,
                    activity: .running,
                    confidence: second < 2 ? .medium : .high,
                    at: clock.now
                ),
                atTransportFrame: Int64(second) * TestFixtures.sampleRate + 1
            )
            if second < 5 {
                #expect(state.queuedTransition == nil)
            }
        }
        let surgeStart = try #require(state.queuedTransition)
        #expect(surgeStart.target == .energy(.surge))
        #expect(surgeStart.reason == .runningSurge)

        state = try controller.advance(toTransportFrame: surgeStart.executeAtFrame)
        #expect(state.currentEnergy == .surge)
        let surgeEnd = try #require(state.queuedTransition)
        #expect(surgeEnd.reason == .surgeExpired)
        #expect(
            surgeEnd.executeAtFrame - surgeStart.executeAtFrame
                <= TestFixtures.sampleRate * 12
        )
        #expect(
            try TestFixtures.grid().isBoundary(
                frame: surgeEnd.executeAtFrame,
                boundary: .bar
            )
        )

        state = try controller.advance(toTransportFrame: surgeEnd.executeAtFrame)
        #expect(state.currentEnergy == .easy)
    }

    @Test
    func nonRunningObservationResetsSurgeStabilization() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock
        )

        for second in 0...3 {
            if second > 0 {
                clock.advance(by: 1)
            }
            try controller.observe(
                TestFixtures.observation(
                    cadence: 150,
                    activity: .running,
                    confidence: .high,
                    at: clock.now
                ),
                atTransportFrame: Int64(second) * TestFixtures.sampleRate
            )
        }
        clock.advance(by: 1)
        try controller.observe(
            TestFixtures.observation(cadence: 110, at: clock.now),
            atTransportFrame: 4 * TestFixtures.sampleRate
        )

        for second in 5...9 {
            clock.advance(by: 1)
            try controller.observe(
                TestFixtures.observation(
                    cadence: 150,
                    activity: .running,
                    confidence: .high,
                    at: clock.now
                ),
                atTransportFrame: Int64(second) * TestFixtures.sampleRate
            )
        }
        #expect(controller.state.queuedTransition == nil)

        clock.advance(by: 1)
        try controller.observe(
            TestFixtures.observation(
                cadence: 150,
                activity: .running,
                confidence: .high,
                at: clock.now
            ),
            atTransportFrame: 10 * TestFixtures.sampleRate
        )
        #expect(controller.state.queuedTransition?.target == .energy(.surge))
    }

    @Test
    func lowConfidenceRunningDoesNotCreateSurge() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock
        )

        let state = try controller.observe(
            TestFixtures.observation(
                cadence: 150,
                activity: .running,
                confidence: .low,
                at: clock.now
            ),
            atTransportFrame: 0
        )

        #expect(state.queuedTransition?.target != .energy(.surge))
    }

    @Test
    func sectionRequestUsesAuthoredTransitionAndAppliesAtBoundary() throws {
        let clock = TestClock()
        var controller = try ArrangementController(
            pack: TestFixtures.pack(),
            clock: clock,
            initialSectionID: "calm"
        )

        var state = try controller.requestSection("lift", atTransportFrame: 1)
        let transition = try #require(state.queuedTransition)
        #expect(state.sectionID == "calm")

        state = try controller.advance(toTransportFrame: transition.executeAtFrame)
        #expect(state.sectionID == "lift")
    }
}
