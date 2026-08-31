import Foundation
import ScoreCore

final class MotionTraceClock: ScoreClock, @unchecked Sendable {
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

enum MotionTraceCommand: String, Decodable {
    case observe
    case tick
    case denyMotion
    case manualEasy
    case manualSteady
    case manualBrisk
    case enableAutomatic
    case requestSection
}

struct MotionTraceQueuedTransitionSnapshot: Decodable, Equatable {
    var target: String
    var boundary: MusicalBoundary
    var executeAtFrame: Int64
    var reason: ArrangementTransitionReason
}

struct MotionTraceExpectation: Decodable, Equatable {
    var transportFrame: Int64
    var sectionID: String
    var currentEnergy: EnergyTier
    var requestedEnergy: EnergyTier
    var adaptationMode: AdaptationMode
    var inputIsStale: Bool
    var queuedTransition: MotionTraceQueuedTransitionSnapshot?

    private enum CodingKeys: String, CodingKey {
        case transportFrame
        case sectionID
        case currentEnergy
        case requestedEnergy
        case adaptationMode
        case inputIsStale
        case queuedTransition
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transportFrame = try container.decode(Int64.self, forKey: .transportFrame)
        sectionID = try container.decode(String.self, forKey: .sectionID)
        currentEnergy = try container.decode(EnergyTier.self, forKey: .currentEnergy)
        requestedEnergy = try container.decode(EnergyTier.self, forKey: .requestedEnergy)
        adaptationMode = try container.decode(AdaptationMode.self, forKey: .adaptationMode)
        inputIsStale = try container.decode(Bool.self, forKey: .inputIsStale)
        guard container.contains(.queuedTransition) else {
            throw DecodingError.keyNotFound(
                CodingKeys.queuedTransition,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Every trace expectation must state queuedTransition, using null when none is expected."
                )
            )
        }
        queuedTransition = try container.decodeIfPresent(
            MotionTraceQueuedTransitionSnapshot.self,
            forKey: .queuedTransition
        )
    }

    init(state: ArrangementState) {
        transportFrame = state.transportFrame
        sectionID = state.sectionID
        currentEnergy = state.currentEnergy
        requestedEnergy = state.requestedEnergy
        adaptationMode = state.adaptationMode
        inputIsStale = state.inputIsStale
        queuedTransition = state.queuedTransition.map {
            MotionTraceQueuedTransitionSnapshot(
                target: Self.describe($0.target),
                boundary: $0.boundary,
                executeAtFrame: $0.executeAtFrame,
                reason: $0.reason
            )
        }
    }

    func differences(from expected: MotionTraceExpectation) -> [String] {
        var differences: [String] = []
        if transportFrame != expected.transportFrame {
            differences.append("transportFrame expected \(expected.transportFrame), got \(transportFrame)")
        }
        if sectionID != expected.sectionID {
            differences.append("sectionID expected \(expected.sectionID), got \(sectionID)")
        }
        if currentEnergy != expected.currentEnergy {
            differences.append(
                "currentEnergy expected \(expected.currentEnergy.rawValue), got \(currentEnergy.rawValue)"
            )
        }
        if requestedEnergy != expected.requestedEnergy {
            differences.append(
                "requestedEnergy expected \(expected.requestedEnergy.rawValue), got \(requestedEnergy.rawValue)"
            )
        }
        if adaptationMode != expected.adaptationMode {
            differences.append(
                "adaptationMode expected \(expected.adaptationMode.rawValue), got \(adaptationMode.rawValue)"
            )
        }
        if inputIsStale != expected.inputIsStale {
            differences.append(
                "inputIsStale expected \(expected.inputIsStale), got \(inputIsStale)"
            )
        }
        if queuedTransition != expected.queuedTransition {
            differences.append(
                "queuedTransition expected \(Self.describe(expected.queuedTransition)), got \(Self.describe(queuedTransition))"
            )
        }
        return differences
    }

    private static func describe(_ target: ArrangementTransitionTarget) -> String {
        switch target {
        case let .energy(energy):
            return "energy:\(energy.rawValue)"
        case let .section(sectionID):
            return "section:\(sectionID)"
        }
    }

    private static func describe(
        _ transition: MotionTraceQueuedTransitionSnapshot?
    ) -> String {
        guard let transition else {
            return "none"
        }
        return "\(transition.target) at \(transition.executeAtFrame)"
            + " (\(transition.boundary.rawValue), \(transition.reason.rawValue))"
    }
}

struct MotionTraceEvent: Decodable {
    var atSeconds: TimeInterval
    var command: MotionTraceCommand
    var cadenceStepsPerMinute: Double?
    var activity: MotionActivityClassification?
    var confidence: MotionConfidence?
    var freshness: MotionFreshness?
    var sectionID: String?
    var expect: MotionTraceExpectation
}

struct MotionTrace: Decodable {
    var name: String
    var initialEnergy: EnergyTier
    var initialSectionID: String?
    var events: [MotionTraceEvent]
}

struct MotionTraceEventResult {
    var sourceIndex: Int
    var event: MotionTraceEvent
    var state: ArrangementState
}

struct MotionTraceRunResult {
    var name: String
    var events: [MotionTraceEventResult]
}

enum MotionTraceRunner {
    static let acceptanceFixtureNames = [
        "manual-fallback.json",
        "stale.json",
        "steady-walk.json",
        "stop-start.json",
        "surge.json",
    ]

    static func run(traceURL: URL, pack: ScorePack) throws -> MotionTraceRunResult {
        let data = try Data(contentsOf: traceURL)
        let trace: MotionTrace
        do {
            trace = try JSONDecoder().decode(MotionTrace.self, from: data)
        } catch {
            throw MotionTraceRunnerError.invalidTrace(
                file: traceURL.lastPathComponent,
                reason: error.localizedDescription
            )
        }

        guard !trace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MotionTraceRunnerError.invalidTrace(
                file: traceURL.lastPathComponent,
                reason: "name must not be empty"
            )
        }
        guard !trace.events.isEmpty else {
            throw MotionTraceRunnerError.invalidTrace(
                file: traceURL.lastPathComponent,
                reason: "events must not be empty"
            )
        }

        for (sourceIndex, event) in trace.events.enumerated() {
            guard event.atSeconds.isFinite, event.atSeconds >= 0 else {
                throw MotionTraceRunnerError.invalidEventTime(
                    file: traceURL.lastPathComponent,
                    sourceIndex: sourceIndex,
                    value: event.atSeconds
                )
            }
            if let cadence = event.cadenceStepsPerMinute,
               !cadence.isFinite || cadence < 0 {
                throw MotionTraceRunnerError.invalidCadence(
                    file: traceURL.lastPathComponent,
                    sourceIndex: sourceIndex,
                    value: cadence
                )
            }
        }

        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MotionTraceClock(now: epoch)
        var controller = try ArrangementController(
            pack: pack,
            clock: clock,
            initialSectionID: trace.initialSectionID,
            initialEnergy: trace.initialEnergy
        )

        let orderedEvents = trace.events.enumerated().sorted { left, right in
            if left.element.atSeconds == right.element.atSeconds {
                return left.offset < right.offset
            }
            return left.element.atSeconds < right.element.atSeconds
        }

        var results: [MotionTraceEventResult] = []
        results.reserveCapacity(orderedEvents.count)
        for (sourceIndex, event) in orderedEvents {
            let frameValue = (event.atSeconds * Double(pack.grid.sampleRate)).rounded(.down)
            guard frameValue.isFinite,
                  frameValue >= 0,
                  let frame = Int64(exactly: frameValue) else {
                throw MotionTraceRunnerError.invalidTransportFrame(
                    file: traceURL.lastPathComponent,
                    sourceIndex: sourceIndex,
                    atSeconds: event.atSeconds,
                    sampleRate: pack.grid.sampleRate
                )
            }

            let date = epoch.addingTimeInterval(event.atSeconds)
            clock.set(date)
            let state: ArrangementState
            switch event.command {
            case .observe:
                state = try controller.observe(
                    MotionObservation(
                        cadenceStepsPerMinute: event.cadenceStepsPerMinute,
                        activity: event.activity ?? .unknown,
                        confidence: event.confidence ?? .unknown,
                        timestamp: date,
                        source: .combined,
                        freshness: event.freshness ?? .fresh
                    ),
                    atTransportFrame: frame
                )
            case .tick:
                state = try controller.advance(toTransportFrame: frame)
            case .denyMotion:
                state = try controller.motionPermissionDenied(atTransportFrame: frame)
            case .manualEasy:
                state = try controller.selectManualEnergy(.easy, atTransportFrame: frame)
            case .manualSteady:
                state = try controller.selectManualEnergy(.steady, atTransportFrame: frame)
            case .manualBrisk:
                state = try controller.selectManualEnergy(.brisk, atTransportFrame: frame)
            case .enableAutomatic:
                state = try controller.enableAutomatic(atTransportFrame: frame)
            case .requestSection:
                guard let sectionID = event.sectionID else {
                    throw MotionTraceRunnerError.missingSectionID(
                        file: traceURL.lastPathComponent,
                        sourceIndex: sourceIndex
                    )
                }
                state = try controller.requestSection(sectionID, atTransportFrame: frame)
            }

            let snapshot = MotionTraceExpectation(state: state)
            let differences = snapshot.differences(from: event.expect)
            guard differences.isEmpty else {
                throw MotionTraceRunnerError.expectationMismatch(
                    file: traceURL.lastPathComponent,
                    traceName: trace.name,
                    sourceIndex: sourceIndex,
                    atSeconds: event.atSeconds,
                    differences: differences
                )
            }
            results.append(
                MotionTraceEventResult(
                    sourceIndex: sourceIndex,
                    event: event,
                    state: state
                )
            )
        }

        return MotionTraceRunResult(name: trace.name, events: results)
    }

    static func developmentAcceptanceFixtureURLs() throws -> [URL] {
        let sourceRepositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            sourceRepositoryRoot,
        ]

        for root in candidates {
            let directory = root
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent("MotionTraces", isDirectory: true)
            let urls = acceptanceFixtureNames.map { directory.appendingPathComponent($0) }
            if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return urls
            }
        }

        throw MotionTraceRunnerError.acceptanceFixturesNotFound(
            names: acceptanceFixtureNames
        )
    }
}

enum MotionTraceRunnerError: Error, LocalizedError {
    case invalidTrace(file: String, reason: String)
    case invalidEventTime(file: String, sourceIndex: Int, value: Double)
    case invalidCadence(file: String, sourceIndex: Int, value: Double)
    case invalidTransportFrame(
        file: String,
        sourceIndex: Int,
        atSeconds: Double,
        sampleRate: Int64
    )
    case missingSectionID(file: String, sourceIndex: Int)
    case expectationMismatch(
        file: String,
        traceName: String,
        sourceIndex: Int,
        atSeconds: Double,
        differences: [String]
    )
    case acceptanceFixturesNotFound(names: [String])

    var errorDescription: String? {
        switch self {
        case let .invalidTrace(file, reason):
            return "Invalid motion trace \(file): \(reason)"
        case let .invalidEventTime(file, sourceIndex, value):
            return "Invalid event time in \(file) at source event \(sourceIndex): \(value). Times must be finite and nonnegative."
        case let .invalidCadence(file, sourceIndex, value):
            return "Invalid cadence in \(file) at source event \(sourceIndex): \(value). Cadence must be finite and nonnegative."
        case let .invalidTransportFrame(file, sourceIndex, atSeconds, sampleRate):
            return "Event time \(atSeconds) in \(file) at source event \(sourceIndex) cannot be represented as an Int64 frame at \(sampleRate) Hz."
        case let .missingSectionID(file, sourceIndex):
            return "requestSection in \(file) at source event \(sourceIndex) requires sectionID."
        case let .expectationMismatch(file, traceName, sourceIndex, atSeconds, differences):
            return "Trace \(traceName) in \(file) deviated at source event \(sourceIndex) (\(atSeconds) seconds): "
                + differences.joined(separator: "; ")
        case let .acceptanceFixturesNotFound(names):
            return "Could not find the acceptance motion traces: \(names.joined(separator: ", "))."
        }
    }
}
