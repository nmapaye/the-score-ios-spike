import Foundation

public enum SessionPhase: String, Codable, Sendable, Equatable, CaseIterable {
    case idle
    case previewing
    case starting
    case active
    case paused
    case interrupted
    case ending
    case completed
}

public enum SessionControllerError: Error, Sendable, Equatable {
    case invalidTransition(from: SessionPhase, action: String)
    case invalidPackID
    case missingSessionContext
}

extension SessionControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidTransition(from, action):
            return "Cannot \(action) while the session is \(from.rawValue)."
        case .invalidPackID:
            return "A session needs a nonempty score pack ID."
        case .missingSessionContext:
            return "The session is missing the information needed to create a summary."
        }
    }
}

public struct SessionController: Sendable {
    public private(set) var phase: SessionPhase

    private let clock: any ScoreClock
    private var packID: String?
    private var adaptationMode: AdaptationMode?
    private var sessionDate: Date?
    private var activeSegmentStartedAt: Date?
    private var accumulatedActiveDuration: TimeInterval
    private var wasActiveBeforeInterruption: Bool

    public init(clock: any ScoreClock = SystemScoreClock()) {
        self.clock = clock
        self.phase = .idle
        self.packID = nil
        self.adaptationMode = nil
        self.sessionDate = nil
        self.activeSegmentStartedAt = nil
        self.accumulatedActiveDuration = 0
        self.wasActiveBeforeInterruption = false
    }

    public var activeDuration: TimeInterval {
        guard phase == .active, let activeSegmentStartedAt else {
            return accumulatedActiveDuration
        }
        return accumulatedActiveDuration
            + max(0, clock.now.timeIntervalSince(activeSegmentStartedAt))
    }

    public mutating func beginPreview() throws {
        guard phase == .idle else {
            throw invalidTransition("begin preview")
        }
        phase = .previewing
    }

    public mutating func endPreview() throws {
        guard phase == .previewing else {
            throw invalidTransition("end preview")
        }
        phase = .idle
    }

    public mutating func beginSession(
        packID: String,
        adaptationMode: AdaptationMode
    ) throws {
        guard phase == .idle || phase == .previewing else {
            throw invalidTransition("begin session")
        }
        guard !packID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionControllerError.invalidPackID
        }

        self.packID = packID
        self.adaptationMode = adaptationMode
        self.sessionDate = clock.now
        self.activeSegmentStartedAt = nil
        self.accumulatedActiveDuration = 0
        self.wasActiveBeforeInterruption = false
        self.phase = .starting
    }

    public mutating func playbackDidStart() throws {
        guard phase == .starting else {
            throw invalidTransition("mark playback started")
        }
        activeSegmentStartedAt = clock.now
        phase = .active
    }

    public mutating func pause() throws {
        guard phase == .active else {
            throw invalidTransition("pause")
        }
        closeActiveSegment()
        phase = .paused
    }

    public mutating func resume() throws {
        guard phase == .paused else {
            throw invalidTransition("resume")
        }
        activeSegmentStartedAt = clock.now
        phase = .active
    }

    public mutating func interruptionBegan() throws {
        guard phase == .active || phase == .paused else {
            throw invalidTransition("begin interruption")
        }
        wasActiveBeforeInterruption = phase == .active
        if phase == .active {
            closeActiveSegment()
        }
        phase = .interrupted
    }

    public mutating func interruptionEnded(shouldResume: Bool) throws {
        guard phase == .interrupted else {
            throw invalidTransition("end interruption")
        }
        if shouldResume && wasActiveBeforeInterruption {
            activeSegmentStartedAt = clock.now
            phase = .active
        } else {
            phase = .paused
        }
        wasActiveBeforeInterruption = false
    }

    public mutating func requestEnd() throws {
        guard phase == .starting
            || phase == .active
            || phase == .paused
            || phase == .interrupted else {
            throw invalidTransition("end session")
        }
        if phase == .active {
            closeActiveSegment()
        }
        activeSegmentStartedAt = nil
        wasActiveBeforeInterruption = false
        phase = .ending
    }

    @discardableResult
    public mutating func outroDidFinish() throws -> SessionSummary {
        guard phase == .ending else {
            throw invalidTransition("complete session")
        }
        guard let packID, let adaptationMode, let sessionDate else {
            throw SessionControllerError.missingSessionContext
        }
        let summary = SessionSummary(
            packID: packID,
            duration: accumulatedActiveDuration,
            date: sessionDate,
            adaptationMode: adaptationMode
        )
        phase = .completed
        return summary
    }

    public mutating func reset() throws {
        guard phase == .completed else {
            throw invalidTransition("reset")
        }
        phase = .idle
        packID = nil
        adaptationMode = nil
        sessionDate = nil
        activeSegmentStartedAt = nil
        accumulatedActiveDuration = 0
        wasActiveBeforeInterruption = false
    }

    private mutating func closeActiveSegment() {
        guard let activeSegmentStartedAt else {
            return
        }
        accumulatedActiveDuration += max(
            0,
            clock.now.timeIntervalSince(activeSegmentStartedAt)
        )
        self.activeSegmentStartedAt = nil
    }

    private func invalidTransition(_ action: String) -> SessionControllerError {
        .invalidTransition(from: phase, action: action)
    }
}
