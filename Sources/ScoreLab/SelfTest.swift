import Foundation
import ScoreAudioEngine
import ScoreCore

struct ScoreLabSelfTestReport: Sendable, Equatable {
    var passedChecks: [String]

    var passedCount: Int {
        passedChecks.count
    }
}

enum ScoreLabSelfTest {
    static func run() throws -> ScoreLabSelfTestReport {
        let loaded = try EngineeringScoreFixture.load()
        var checks = CheckCollector()

        try checkContracts(pack: loaded.pack, checks: &checks)
        try checkGrid(pack: loaded.pack, checks: &checks)
        try checkValidation(pack: loaded.pack, checks: &checks)
        try checkTransitions(pack: loaded.pack, checks: &checks)
        try checkAdaptation(pack: loaded.pack, checks: &checks)
        try checkSession(checks: &checks)
        try checkAssets(loaded: loaded, checks: &checks)
        try checkMotionTraceFixtures(pack: loaded.pack, checks: &checks)

        return ScoreLabSelfTestReport(passedChecks: checks.passed)
    }

    private static func checkContracts(
        pack: ScorePack,
        checks: inout CheckCollector
    ) throws {
        let encoded = try JSONEncoder().encode(pack)
        let decoded = try JSONDecoder().decode(ScorePack.self, from: encoded)
        try checks.expect(decoded == pack, "ScorePack Codable round trip")
        try checks.expect(
            EnergyTier.allCases == [.still, .easy, .steady, .brisk, .surge],
            "EnergyTier contract cases"
        )

        let summary = SessionSummary(
            packID: pack.id,
            duration: 42,
            date: Date(timeIntervalSince1970: 10),
            adaptationMode: .automatic
        )
        let summaryData = try JSONEncoder().encode(summary)
        let object = try cast(
            JSONSerialization.jsonObject(with: summaryData),
            as: [String: Any].self,
            check: "SessionSummary JSON object"
        )
        try checks.expect(
            Set(object.keys) == Set(["packID", "duration", "date", "adaptationMode"]),
            "SessionSummary privacy fields"
        )
    }

    private static func checkGrid(
        pack: ScorePack,
        checks: inout CheckCollector
    ) throws {
        let firstBeatFrame = try pack.grid.frame(atBeat: 1)
        let firstBarFrame = try pack.grid.frame(atBar: 1)
        let firstPhraseBoundary = try pack.grid.nextBoundary(
            afterFrame: 1,
            boundary: .phrase
        )
        try checks.expect(
            firstBeatFrame == 24_000,
            "120 BPM beat frame"
        )
        try checks.expect(
            firstBarFrame == 96_000,
            "4/4 bar frame"
        )
        try checks.expect(
            firstPhraseBoundary == 384_000,
            "Phrase quantization"
        )

        let hourGrid = try MusicalGrid(
            sampleRate: 48_000,
            beatsPerMinute: Rational(numerator: 123, denominator: 1),
            beatsPerBar: 4,
            barsPerPhrase: 4,
            exactLoopFrames: 172_800_000
        )
        let oneHourFrame = try hourGrid.frame(atBeat: 123 * 60)
        try checks.expect(
            oneHourFrame == 172_800_000,
            "One-hour rational frame calculation"
        )
    }

    private static func checkValidation(
        pack: ScorePack,
        checks: inout CheckCollector
    ) throws {
        try checks.expect(
            ScorePackValidator.validate(
                pack,
                availableResourceNames: pack.allResourceNames
            ).isEmpty,
            "Valid engineering manifest"
        )

        var invalid = pack
        invalid.stems[0].asset.resourceName = "missing.wav"
        invalid.stems[0].asset.exactFrameCount -= 1
        let codes = Set(
            ScorePackValidator.validate(
                invalid,
                availableResourceNames: pack.allResourceNames
            ).map(\.code)
        )
        try checks.expect(
            codes.contains(.missingResource) && codes.contains(.stemLengthMismatch),
            "Missing resource and frame mismatch rejection"
        )

        invalid = pack
        invalid.integrityHash = "bad"
        try checks.expect(
            ScorePackValidator.validate(invalid).contains { $0.code == .invalidIntegrityHash },
            "Malformed integrity hash rejection"
        )
    }

    private static func checkTransitions(
        pack: ScorePack,
        checks: inout CheckCollector
    ) throws {
        let planner = LegalTransitionPlanner(pack: pack)
        let transition = try planner.planSectionTransition(
            from: "foundation",
            to: "ascent",
            afterFrame: 1
        )
        try checks.expect(
            transition.target == .section("ascent")
                && transition.boundary == .phrase
                && transition.executeAtFrame == 384_000,
            "Authorized phrase transition"
        )

        do {
            _ = try planner.planSectionTransition(
                from: "foundation",
                to: "missing",
                afterFrame: 1
            )
            throw ScoreLabSelfTestError.failed("Unknown section rejection")
        } catch ScoreCoreError.unknownSection {
            checks.pass("Unknown section rejection")
        }

        let clock = SelfTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        var controller = try ArrangementController(pack: pack, clock: clock)
        let queued = try controller.selectManualEnergy(.easy, atTransportFrame: 1)
        let requested = try require(
            queued.queuedTransition,
            check: "Runtime transition request"
        )
        var accepted = requested
        accepted.executeAtFrame = try pack.grid.nextBoundary(
            afterFrame: requested.executeAtFrame,
            boundary: requested.boundary
        )
        _ = try controller.adoptAcceptedTransition(
            expected: requested,
            accepted: accepted
        )
        try checks.expect(
            controller.state.queuedTransition == accepted,
            "Accepted runtime boundary reconciliation"
        )
    }

    private static func checkAdaptation(
        pack: ScorePack,
        checks: inout CheckCollector
    ) throws {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SelfTestClock(now: epoch)
        var controller = try ArrangementController(
            pack: pack,
            clock: clock,
            initialEnergy: .easy
        )

        for second in 0...12 {
            let date = epoch.addingTimeInterval(TimeInterval(second))
            clock.set(date)
            _ = try controller.observe(
                observation(cadence: 112, activity: .walking, at: date),
                atTransportFrame: Int64(second) * pack.grid.sampleRate
            )
        }
        let steadyTransition = try require(
            controller.state.queuedTransition,
            check: "Stable cadence queues a transition"
        )
        try checks.expect(
            steadyTransition.target == .energy(.steady),
            "Five-second stabilization and twelve-second dwell"
        )
        _ = try controller.advance(toTransportFrame: steadyTransition.executeAtFrame)
        try checks.expect(controller.state.currentEnergy == .steady, "Queued energy applies")

        let staleClock = SelfTestClock(now: epoch)
        var staleController = try ArrangementController(pack: pack, clock: staleClock)
        _ = try staleController.observe(
            observation(cadence: 110, activity: .walking, at: epoch),
            atTransportFrame: 0
        )
        staleClock.set(epoch.addingTimeInterval(10))
        _ = try staleController.advance(toTransportFrame: 10 * pack.grid.sampleRate)
        try checks.expect(!staleController.state.inputIsStale, "Ten-second input remains fresh")
        staleClock.set(epoch.addingTimeInterval(10.1))
        _ = try staleController.advance(toTransportFrame: 10 * pack.grid.sampleRate + 4_800)
        try checks.expect(staleController.state.inputIsStale, "Input stales after ten seconds")

        var manualController = try ArrangementController(
            pack: pack,
            clock: SelfTestClock(now: epoch),
            initialEnergy: .brisk
        )
        _ = try manualController.motionPermissionDenied(atTransportFrame: 1)
        try checks.expect(
            manualController.state.adaptationMode == .manual
                && manualController.state.requestedEnergy == .steady,
            "Denied Motion selects Manual Steady"
        )

        let runClock = SelfTestClock(now: epoch)
        var runController = try ArrangementController(
            pack: pack,
            clock: runClock,
            initialEnergy: .steady
        )
        for second in 0...4 {
            let date = epoch.addingTimeInterval(TimeInterval(second))
            runClock.set(date)
            _ = try runController.observe(
                observation(
                    cadence: 150,
                    activity: .running,
                    confidence: .high,
                    at: date
                ),
                atTransportFrame: Int64(second) * pack.grid.sampleRate
            )
            try checks.expect(
                runController.state.queuedTransition == nil,
                "Surge waits through running second \(second)"
            )
        }
        let surgeDate = epoch.addingTimeInterval(5)
        runClock.set(surgeDate)
        _ = try runController.observe(
            observation(
                cadence: 150,
                activity: .running,
                confidence: .high,
                at: surgeDate
            ),
            atTransportFrame: 5 * pack.grid.sampleRate
        )
        let surgeStart = try require(
            runController.state.queuedTransition,
            check: "Stable running queues Surge"
        )
        try checks.expect(
            surgeStart.target == .energy(.surge),
            "Five-second running stabilization"
        )
        _ = try runController.advance(toTransportFrame: surgeStart.executeAtFrame)
        let surgeEnd = try require(
            runController.state.queuedTransition,
            check: "Surge expiry transition"
        )
        try checks.expect(
            surgeEnd.executeAtFrame - surgeStart.executeAtFrame
                <= Int64(AdaptationPolicy.standard.surgeMaximumDuration)
                    * pack.grid.sampleRate,
            "Surge is capped at twelve seconds"
        )
    }

    private static func checkSession(checks: inout CheckCollector) throws {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SelfTestClock(now: epoch)
        var session = SessionController(clock: clock)
        try session.beginSession(packID: "engineering-score-v1", adaptationMode: .automatic)
        try session.playbackDidStart()
        clock.set(epoch.addingTimeInterval(30))
        try session.pause()
        clock.set(epoch.addingTimeInterval(40))
        try session.resume()
        clock.set(epoch.addingTimeInterval(60))
        try session.requestEnd()
        let summary = try session.outroDidFinish()

        try checks.expect(summary.duration == 50, "Paused time excluded from duration")
        try checks.expect(session.phase == .completed, "Session completes after outro")
        try session.reset()
        try checks.expect(session.phase == .idle, "Completed session resets")
    }

    private static func checkAssets(
        loaded: LoadedScorePack,
        checks: inout CheckCollector
    ) throws {
        let inspections = try AudioAssetInspector.inspect(
            pack: loaded.pack,
            resourceRoot: loaded.resourceRoot
        )
        try checks.expect(inspections.count == 6, "Six fixture assets inspect")
        try checks.expect(
            inspections.allSatisfy {
                $0.sampleRate == 48_000 && $0.sha256.count == 64
            },
            "Fixture format, file hashes, and asset-set hash"
        )
    }

    private static func checkMotionTraceFixtures(
        pack: ScorePack,
        checks: inout CheckCollector
    ) throws {
        let fixtureURLs = try MotionTraceRunner.developmentAcceptanceFixtureURLs()
        for fixtureURL in fixtureURLs {
            let result = try MotionTraceRunner.run(traceURL: fixtureURL, pack: pack)
            try checks.expect(
                !result.events.isEmpty,
                "Motion trace \(fixtureURL.deletingPathExtension().lastPathComponent) acceptance"
            )
        }
    }

    private static func observation(
        cadence: Double?,
        activity: MotionActivityClassification,
        confidence: MotionConfidence = .high,
        at date: Date
    ) -> MotionObservation {
        MotionObservation(
            cadenceStepsPerMinute: cadence,
            activity: activity,
            confidence: confidence,
            timestamp: date,
            source: .combined,
            freshness: .fresh
        )
    }

    private static func require<Value>(_ value: Value?, check: String) throws -> Value {
        guard let value else {
            throw ScoreLabSelfTestError.failed(check)
        }
        return value
    }

    private static func cast<Value>(
        _ value: Any,
        as type: Value.Type,
        check: String
    ) throws -> Value {
        guard let cast = value as? Value else {
            throw ScoreLabSelfTestError.failed(check)
        }
        return cast
    }
}

private struct CheckCollector {
    var passed: [String] = []

    mutating func expect(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else {
            throw ScoreLabSelfTestError.failed(name)
        }
        passed.append(name)
    }

    mutating func pass(_ name: String) {
        passed.append(name)
    }
}

private final class SelfTestClock: ScoreClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: Date

    init(now: Date) {
        storedNow = now
    }

    var now: Date {
        lock.withLock { storedNow }
    }

    func set(_ date: Date) {
        lock.withLock { storedNow = date }
    }
}

private enum ScoreLabSelfTestError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(name):
            return "Compiled self-test failed: \(name)"
        }
    }
}
