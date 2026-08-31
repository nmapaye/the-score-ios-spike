import Foundation
import Testing
@testable import ScoreCore

@Suite("Session lifecycle")
struct SessionControllerTests {
    @Test
    func completeLifecycleTracksOnlyActivePlaybackTime() throws {
        let initialDate = Date(timeIntervalSince1970: 5_000)
        let clock = TestClock(now: initialDate)
        var controller = SessionController(clock: clock)

        try controller.beginPreview()
        #expect(controller.phase == .previewing)
        try controller.beginSession(
            packID: "engineering.walk.1",
            adaptationMode: .automatic
        )
        #expect(controller.phase == .starting)

        clock.advance(by: 3)
        try controller.playbackDidStart()
        clock.advance(by: 30)
        try controller.pause()
        #expect(abs(controller.activeDuration - 30) < 0.0001)

        clock.advance(by: 20)
        try controller.resume()
        clock.advance(by: 10)
        try controller.interruptionBegan()
        clock.advance(by: 5)
        try controller.interruptionEnded(shouldResume: true)
        clock.advance(by: 15)
        try controller.requestEnd()

        clock.advance(by: 4)
        let summary = try controller.outroDidFinish()
        #expect(controller.phase == .completed)
        #expect(summary.packID == "engineering.walk.1")
        #expect(summary.date == initialDate)
        #expect(abs(summary.duration - 55) < 0.0001)
        #expect(summary.adaptationMode == .automatic)

        try controller.reset()
        #expect(controller.phase == .idle)
        #expect(controller.activeDuration == 0)
    }

    @Test
    func pausedInterruptionDoesNotResumeWithoutAnActivePredecessor() throws {
        let clock = TestClock()
        var controller = SessionController(clock: clock)
        try controller.beginSession(packID: "pack", adaptationMode: .manual)
        try controller.playbackDidStart()
        clock.advance(by: 10)
        try controller.pause()
        try controller.interruptionBegan()
        try controller.interruptionEnded(shouldResume: true)

        #expect(controller.phase == .paused)
        #expect(abs(controller.activeDuration - 10) < 0.0001)
    }

    @Test
    func endingBeforePlaybackProducesZeroDurationSummary() throws {
        let clock = TestClock()
        var controller = SessionController(clock: clock)
        try controller.beginSession(packID: "pack", adaptationMode: .manual)
        clock.advance(by: 20)
        try controller.requestEnd()
        let summary = try controller.outroDidFinish()

        #expect(summary.duration == 0)
        #expect(summary.adaptationMode == .manual)
    }

    @Test
    func invalidLifecycleTransitionIsRejected() {
        var controller = SessionController(clock: TestClock())

        do {
            try controller.pause()
            Issue.record("Expected pause from idle to fail.")
        } catch {
            #expect(
                error as? SessionControllerError
                    == .invalidTransition(from: .idle, action: "pause")
            )
        }
    }
}
