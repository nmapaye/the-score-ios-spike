import Foundation

public enum ArrangementControllerError: Error, Sendable, Equatable {
    case invalidAdaptationPolicy
    case unsupportedManualEnergy(EnergyTier)
}

extension ArrangementControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAdaptationPolicy:
            return "Adaptation thresholds and durations must be finite, ordered, and positive."
        case let .unsupportedManualEnergy(energy):
            return "The manual control cannot select \(energy.rawValue)."
        }
    }
}

public struct ArrangementController: Sendable {
    public private(set) var state: ArrangementState
    public let pack: ScorePack
    public let policy: AdaptationPolicy

    private let clock: any ScoreClock
    private let planner: LegalTransitionPlanner
    private var cadenceSamples: [CadenceSample]
    private var lastObservationAt: Date?
    private var lastActivity: MotionActivityClassification?
    private var lastConfidence: MotionConfidence?
    private var observationWasExplicitlyStale: Bool
    private var candidateEnergy: EnergyTier?
    private var candidateStartedAt: Date?
    private var runningCandidateStartedAt: Date?
    private var lastEnergyChangeAt: Date
    private var preSurgeEnergy: EnergyTier
    private var surgeIsArmed: Bool

    public init(
        pack: ScorePack,
        clock: any ScoreClock = SystemScoreClock(),
        policy: AdaptationPolicy = .standard,
        initialSectionID: String? = nil,
        initialEnergy: EnergyTier = .steady
    ) throws {
        guard Self.isValid(policy) else {
            throw ArrangementControllerError.invalidAdaptationPolicy
        }
        let firstBarFrame = try pack.grid.nextBoundary(afterFrame: 0, boundary: .bar)
        let maximumSurgeFrames = policy.surgeMaximumDuration * Double(pack.grid.sampleRate)
        guard Double(firstBarFrame) <= maximumSurgeFrames else {
            throw ArrangementControllerError.invalidAdaptationPolicy
        }

        let selectedSectionID = initialSectionID ?? pack.initialSectionID ?? ""
        guard pack.sections.contains(where: { $0.id == selectedSectionID }) else {
            throw ScoreCoreError.unknownSection(selectedSectionID)
        }

        self.pack = pack
        self.clock = clock
        self.policy = policy
        self.planner = LegalTransitionPlanner(pack: pack)
        self.state = ArrangementState(
            transportFrame: 0,
            sectionID: selectedSectionID,
            currentEnergy: initialEnergy,
            requestedEnergy: initialEnergy,
            currentMusicalBoundary: MusicalBoundaryPoint(kind: .phrase, frame: 0),
            queuedTransition: nil,
            adaptationMode: .automatic,
            inputIsStale: true
        )
        self.cadenceSamples = []
        self.lastObservationAt = nil
        self.lastActivity = nil
        self.lastConfidence = nil
        self.observationWasExplicitlyStale = false
        self.candidateEnergy = nil
        self.candidateStartedAt = nil
        self.runningCandidateStartedAt = nil
        self.lastEnergyChangeAt = clock.now
        self.preSurgeEnergy = initialEnergy
        self.surgeIsArmed = true
    }

    @discardableResult
    public mutating func observe(
        _ observation: MotionObservation,
        atTransportFrame transportFrame: Int64
    ) throws -> ArrangementState {
        try advance(toTransportFrame: transportFrame)

        let now = clock.now
        lastObservationAt = observation.timestamp
        lastActivity = observation.activity
        lastConfidence = observation.confidence
        observationWasExplicitlyStale = observation.freshness == .stale
        let age = max(0, now.timeIntervalSince(observation.timestamp))
        state.inputIsStale = observationWasExplicitlyStale || age > policy.staleAfter

        pruneCadenceSamples(now: now)
        if let cadence = observation.cadenceStepsPerMinute,
           cadence.isFinite,
           cadence >= 0,
           !state.inputIsStale {
            cadenceSamples.append(CadenceSample(timestamp: observation.timestamp, cadence: cadence))
            pruneCadenceSamples(now: now)
        }

        guard state.adaptationMode == .automatic, !state.inputIsStale else {
            clearCandidate()
            runningCandidateStartedAt = nil
            return state
        }

        let isConfidentRun = observation.activity == .running
            && (observation.confidence == .medium || observation.confidence == .high)
        if isConfidentRun {
            clearCandidate()
            try evaluateRunningCandidate(afterFrame: transportFrame, now: now)
            return state
        }

        runningCandidateStartedAt = nil
        surgeIsArmed = true
        if state.currentEnergy == .surge {
            updateSurgeFallback(activity: observation.activity)
            return state
        }

        try evaluateCadence(activity: observation.activity, afterFrame: transportFrame, now: now)
        return state
    }

    @discardableResult
    public mutating func advance(
        toTransportFrame transportFrame: Int64
    ) throws -> ArrangementState {
        guard transportFrame >= 0 else {
            throw ScoreCoreError.negativeFrameOrIndex
        }

        state.transportFrame = transportFrame
        try applyDueTransitions(throughFrame: transportFrame)
        state.currentMusicalBoundary = try planner.boundaryPoint(atFrame: transportFrame)

        let now = clock.now
        pruneCadenceSamples(now: now)
        if state.adaptationMode == .automatic {
            if let lastObservationAt {
                state.inputIsStale = observationWasExplicitlyStale
                    || max(0, now.timeIntervalSince(lastObservationAt)) > policy.staleAfter
            } else {
                state.inputIsStale = true
            }

            if state.inputIsStale {
                clearCandidate()
                runningCandidateStartedAt = nil
            } else if state.currentEnergy != .surge,
                      state.queuedTransition == nil,
                      !lastObservationWasConfidentRun {
                try evaluateCadence(
                    activity: lastActivity ?? .unknown,
                    afterFrame: transportFrame,
                    now: now
                )
            }
        }

        if state.queuedTransition == nil,
           (state.adaptationMode == .manual || !state.inputIsStale),
           candidateEnergy == nil,
           runningCandidateStartedAt == nil {
            try queueComposerMappedSection(afterFrame: transportFrame)
        }

        return state
    }

    @discardableResult
    public mutating func motionPermissionDenied(
        atTransportFrame transportFrame: Int64
    ) throws -> ArrangementState {
        try advance(toTransportFrame: transportFrame)
        state.adaptationMode = .manual
        state.inputIsStale = true
        cadenceSamples.removeAll(keepingCapacity: true)
        lastObservationAt = nil
        lastActivity = nil
        lastConfidence = nil
        observationWasExplicitlyStale = true
        clearCandidate()
        runningCandidateStartedAt = nil
        try queueManualEnergy(
            .steady,
            afterFrame: transportFrame,
            reason: .motionPermissionDenied
        )
        return state
    }

    @discardableResult
    public mutating func selectManualEnergy(
        _ energy: EnergyTier,
        atTransportFrame transportFrame: Int64
    ) throws -> ArrangementState {
        guard energy == .easy || energy == .steady || energy == .brisk else {
            throw ArrangementControllerError.unsupportedManualEnergy(energy)
        }
        try advance(toTransportFrame: transportFrame)
        state.adaptationMode = .manual
        clearCandidate()
        runningCandidateStartedAt = nil
        if state.queuedTransition?.reason == .authoredSectionChange {
            state.queuedTransition = nil
        }
        try queueManualEnergy(
            energy,
            afterFrame: transportFrame,
            reason: .manualSelection
        )
        return state
    }

    @discardableResult
    public mutating func enableAutomatic(
        atTransportFrame transportFrame: Int64
    ) throws -> ArrangementState {
        try advance(toTransportFrame: transportFrame)
        state.adaptationMode = .automatic
        state.inputIsStale = true
        if let transition = state.queuedTransition,
           case .energy = transition.target,
           transition.reason == .manualSelection
               || transition.reason == .motionPermissionDenied {
            state.queuedTransition = nil
            state.requestedEnergy = state.currentEnergy
        }
        lastObservationAt = nil
        lastActivity = nil
        lastConfidence = nil
        observationWasExplicitlyStale = false
        cadenceSamples.removeAll(keepingCapacity: true)
        clearCandidate()
        runningCandidateStartedAt = nil
        return state
    }

    @discardableResult
    public mutating func requestSection(
        _ destinationSectionID: String,
        atTransportFrame transportFrame: Int64
    ) throws -> ArrangementState {
        try advance(toTransportFrame: transportFrame)
        if state.queuedTransition?.reason == .authoredSectionChange {
            state.queuedTransition = nil
        }
        guard state.queuedTransition == nil else {
            throw ScoreCoreError.queuedTransitionAlreadyExists
        }
        state.queuedTransition = try planner.planSectionTransition(
            from: state.sectionID,
            to: destinationSectionID,
            afterFrame: transportFrame
        )
        return state
    }

    /// Reconciles a runtime transition that had to move later to preserve the
    /// audio scheduling window. Only the frame may change, and it must remain on
    /// the same kind of musical boundary.
    @discardableResult
    public mutating func adoptAcceptedTransition(
        expected: QueuedTransition,
        accepted: QueuedTransition
    ) throws -> ArrangementState {
        guard state.queuedTransition == expected,
              accepted.target == expected.target,
              accepted.boundary == expected.boundary,
              accepted.reason == expected.reason,
              accepted.executeAtFrame >= expected.executeAtFrame,
              accepted.executeAtFrame > state.transportFrame,
              try pack.grid.previousBoundary(
                  atOrBeforeFrame: accepted.executeAtFrame,
                  boundary: accepted.boundary
              ) == accepted.executeAtFrame else {
            throw ScoreCoreError.invalidAcceptedTransition
        }
        state.queuedTransition = accepted
        return state
    }

    public var smoothedCadenceStepsPerMinute: Double? {
        guard !cadenceSamples.isEmpty else {
            return nil
        }
        return cadenceSamples.reduce(0) { $0 + $1.cadence } / Double(cadenceSamples.count)
    }

    private mutating func evaluateCadence(
        activity: MotionActivityClassification,
        afterFrame frame: Int64,
        now: Date
    ) throws {
        guard state.queuedTransition == nil else {
            return
        }
        guard let target = automaticTarget(activity: activity) else {
            clearCandidate()
            return
        }
        guard target != state.currentEnergy else {
            clearCandidate()
            return
        }

        if candidateEnergy != target {
            candidateEnergy = target
            candidateStartedAt = now
            return
        }

        guard let candidateStartedAt,
              now.timeIntervalSince(candidateStartedAt) >= policy.stabilizationDuration,
              now.timeIntervalSince(lastEnergyChangeAt) >= policy.minimumDwellDuration else {
            return
        }

        state.queuedTransition = try planner.planEnergyTransition(
            to: target,
            afterFrame: frame,
            reason: .adaptiveCadence
        )
        state.requestedEnergy = target
        clearCandidate()
    }

    private func automaticTarget(
        activity: MotionActivityClassification
    ) -> EnergyTier? {
        if activity == .stationary {
            return .still
        }
        guard let cadence = smoothedCadenceStepsPerMinute else {
            return nil
        }

        let margin = policy.hysteresisStepsPerMinute
        switch state.currentEnergy {
        case .still:
            return cadence > policy.stillCadenceUpperBound + margin ? .easy : .still
        case .easy:
            if cadence <= policy.stillCadenceUpperBound - margin {
                return .still
            }
            if cadence >= policy.steadyCadenceLowerBound + margin {
                return .steady
            }
            return .easy
        case .steady:
            if cadence < policy.steadyCadenceLowerBound - margin {
                return .easy
            }
            if cadence >= policy.briskCadenceLowerBound + margin {
                return .brisk
            }
            return .steady
        case .brisk:
            return cadence < policy.briskCadenceLowerBound - margin ? .steady : .brisk
        case .surge:
            return rawCadenceTier(cadence)
        }
    }

    private func rawCadenceTier(_ cadence: Double) -> EnergyTier {
        if cadence <= policy.stillCadenceUpperBound {
            return .still
        }
        if cadence < policy.steadyCadenceLowerBound {
            return .easy
        }
        if cadence < policy.briskCadenceLowerBound {
            return .steady
        }
        return .brisk
    }

    private mutating func requestSurgeIfPossible(afterFrame frame: Int64) throws {
        guard surgeIsArmed,
              state.currentEnergy != .surge,
              state.queuedTransition == nil else {
            return
        }
        preSurgeEnergy = state.currentEnergy
        state.queuedTransition = try planner.planEnergyTransition(
            to: .surge,
            afterFrame: frame,
            reason: .runningSurge
        )
        state.requestedEnergy = .surge
        surgeIsArmed = false
        runningCandidateStartedAt = nil
        clearCandidate()
    }

    private mutating func evaluateRunningCandidate(
        afterFrame frame: Int64,
        now: Date
    ) throws {
        guard surgeIsArmed,
              state.currentEnergy != .surge,
              state.queuedTransition == nil else {
            runningCandidateStartedAt = nil
            return
        }

        guard let runningCandidateStartedAt else {
            self.runningCandidateStartedAt = now
            return
        }
        guard now.timeIntervalSince(runningCandidateStartedAt)
                >= policy.stabilizationDuration else {
            return
        }
        try requestSurgeIfPossible(afterFrame: frame)
    }

    private mutating func updateSurgeFallback(activity: MotionActivityClassification) {
        guard var transition = state.queuedTransition,
              transition.reason == .surgeExpired else {
            return
        }
        let fallback: EnergyTier
        if activity == .stationary {
            fallback = .still
        } else if let cadence = smoothedCadenceStepsPerMinute {
            fallback = rawCadenceTier(cadence)
        } else {
            fallback = preSurgeEnergy
        }
        transition.target = .energy(fallback)
        state.queuedTransition = transition
        state.requestedEnergy = fallback
    }

    private mutating func queueManualEnergy(
        _ energy: EnergyTier,
        afterFrame frame: Int64,
        reason: ArrangementTransitionReason
    ) throws {
        if let queuedTransition = state.queuedTransition,
           case .section = queuedTransition.target {
            throw ScoreCoreError.queuedTransitionAlreadyExists
        }

        if energy == state.currentEnergy {
            state.queuedTransition = nil
            state.requestedEnergy = energy
            return
        }
        state.queuedTransition = try planner.planEnergyTransition(
            to: energy,
            afterFrame: frame,
            reason: reason
        )
        state.requestedEnergy = energy
    }

    private mutating func queueComposerMappedSection(afterFrame frame: Int64) throws {
        guard let destination = pack.sectionID(for: state.currentEnergy),
              destination != state.sectionID else {
            return
        }
        state.queuedTransition = try planner.planSectionTransition(
            from: state.sectionID,
            to: destination,
            afterFrame: frame
        )
    }

    private mutating func applyDueTransitions(throughFrame frame: Int64) throws {
        while let transition = state.queuedTransition,
              transition.executeAtFrame <= frame {
            state.queuedTransition = nil
            switch transition.target {
            case let .energy(energy):
                state.currentEnergy = energy
                state.requestedEnergy = energy
                lastEnergyChangeAt = clock.now

                if energy == .surge {
                    try scheduleSurgeExpiry(startFrame: transition.executeAtFrame)
                }
            case let .section(sectionID):
                guard pack.sections.contains(where: { $0.id == sectionID }) else {
                    throw ScoreCoreError.unknownSection(sectionID)
                }
                state.sectionID = sectionID
            }
        }
    }

    private mutating func scheduleSurgeExpiry(startFrame: Int64) throws {
        let durationFramesDouble = policy.surgeMaximumDuration * Double(pack.grid.sampleRate)
        guard durationFramesDouble.isFinite,
              durationFramesDouble > 0,
              durationFramesDouble <= Double(Int64.max) else {
            throw ArrangementControllerError.invalidAdaptationPolicy
        }
        let durationFrames = Int64(durationFramesDouble.rounded(.down))
        let maximumEnd = startFrame.addingReportingOverflow(durationFrames)
        guard !maximumEnd.overflow else {
            throw ScoreCoreError.arithmeticOverflow
        }

        let expiryFrame = try pack.grid.previousBoundary(
            atOrBeforeFrame: maximumEnd.partialValue,
            boundary: .bar
        )
        if expiryFrame <= startFrame {
            throw ArrangementControllerError.invalidAdaptationPolicy
        }
        state.queuedTransition = QueuedTransition(
            target: .energy(preSurgeEnergy),
            boundary: .bar,
            executeAtFrame: expiryFrame,
            reason: .surgeExpired
        )
        state.requestedEnergy = preSurgeEnergy
    }

    private mutating func pruneCadenceSamples(now: Date) {
        let cutoff = now.addingTimeInterval(-policy.smoothingWindow)
        cadenceSamples.removeAll { $0.timestamp < cutoff }
    }

    private mutating func clearCandidate() {
        candidateEnergy = nil
        candidateStartedAt = nil
    }

    private var lastObservationWasConfidentRun: Bool {
        lastActivity == .running && (lastConfidence == .medium || lastConfidence == .high)
    }

    private static func isValid(_ policy: AdaptationPolicy) -> Bool {
        let values = [
            policy.stillCadenceUpperBound,
            policy.steadyCadenceLowerBound,
            policy.briskCadenceLowerBound,
            policy.hysteresisStepsPerMinute,
            policy.smoothingWindow,
            policy.stabilizationDuration,
            policy.minimumDwellDuration,
            policy.staleAfter,
            policy.surgeMaximumDuration,
        ]
        return values.allSatisfy { $0.isFinite && $0 > 0 }
            && policy.stillCadenceUpperBound < policy.steadyCadenceLowerBound
            && policy.steadyCadenceLowerBound < policy.briskCadenceLowerBound
    }
}

private struct CadenceSample: Sendable {
    var timestamp: Date
    var cadence: Double
}
